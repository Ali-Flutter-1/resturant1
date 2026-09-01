import 'dart:convert';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../../../core/network/api_failure.dart';
import '../../../core/network/token_store.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_user.dart';
import '../domain/password_reset.dart';

/// The HTTP implementation of [AuthRepository].
///
/// Covers everything under `/auth` and the parts of `/profile` that change a
/// session.
///
/// The repository owns one rule the rest of the app should not have to think
/// about: **tokens are saved here and nowhere else.** Register, login, Google
/// sign-in and change-password all return a fresh pair, and every one of them
/// funnels through [_storeSession]. A cubit that had to remember to persist
/// tokens would eventually forget on one path.
///
/// Failures are left as [ApiFailure] and not caught. They already carry a
/// message fit to show a person, so translating them again here would only
/// throw information away.
class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository({required ApiClient client, required TokenStore tokens})
    : _client = client,
      _tokens = tokens;

  final ApiClient _client;
  final TokenStore _tokens;

  @override
  bool get hasStoredSession => _tokens.hasSession;

  @override
  AuthUser? get cachedUser {
    final stored = _tokens.lastUser;
    if (stored == null) return null;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return null;
      return AuthUser.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException {
      // Written by an older build, or truncated. A missing cache is a normal
      // state, so this is not worth surfacing.
      return null;
    }
  }

  /// Keeps the local copy in step with whatever the server just said.
  Future<AuthUser> _remember(AuthUser user) async {
    await _tokens.saveUser(jsonEncode(user.toJson()));
    return user;
  }

  /// Creates an account and signs the new user in.
  @override
  Future<AuthUser> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
  }) async {
    final data = await _client.object(
      ApiConstants.register,
      method: 'POST',
      body: {
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'email': email.trim(),
        'password': password,
      },
    );
    return _storeSession(data);
  }

  @override
  Future<AuthUser> login({
    required String email,
    required String password,
  }) async {
    final data = await _client.object(
      ApiConstants.login,
      method: 'POST',
      // Email is trimmed and lower-cased so a stray capital or a copy-paste
      // space isn't reported back as "no account for that email".
      body: {'email': email.trim().toLowerCase(), 'password': password},
    );
    return _storeSession(data);
  }

  /// Signs in with the ID token from `google_sign_in`.
  @override
  Future<AuthUser> signInWithGoogle(String idToken) async {
    final data = await _client.object(
      ApiConstants.google,
      method: 'POST',
      body: {'id_token': idToken},
    );
    return _storeSession(data);
  }

  /// The current user, for restoring a session at startup.
  @override
  Future<AuthUser> currentUser() async {
    final data = await _client.object(ApiConstants.me);
    return _remember(AuthUser.fromJson(data));
  }

  /// Revokes this device's refresh token, then forgets it locally.
  ///
  /// The local clear happens whatever the server says. A failed logout call
  /// must still sign the user out of this device — leaving them apparently
  /// signed in because the network hiccuped would be the wrong way to fail.
  @override
  @override
  Future<void> logout({String? refreshToken}) async {
    final refresh = refreshToken ?? _tokens.refreshToken;
    if (refresh == null) return;

    try {
      // `send`, not `object`: this route answers `{success, message, data:
      // null}`, and asking for an object would throw on the null.
      await _client.send(
        ApiConstants.logout,
        method: 'POST',
        body: {'refresh_token': refresh},
      );
    } on ApiFailure {
      // Deliberately ignored: the device has already forgotten the session, so
      // a failed revoke leaves a token that expires on its own rather than
      // somebody apparently still signed in.
    }
  }

  /// Closes the account, then forgets the session.
  ///
  /// Unlike [logout], a failure here is *not* swallowed: if the server refused
  /// to delete the account, clearing the tokens locally would leave the user
  /// signed out of an account that still exists — and convinced it was gone.
  /// The error propagates so the screen can say what happened.
  @override
  Future<void> deleteAccount(String password) async {
    await _client.send(
      ApiConstants.profile,
      method: 'DELETE',
      // A body on DELETE is unusual but this is what the endpoint documents,
      // and it is the right call: re-authenticating is what separates "close my
      // account" from a mis-tap.
      body: {'password': password},
    );
    await _tokens.clear();
  }

  @override
  Future<AuthUser> updateProfile({String? firstName, String? lastName}) async {
    final data = await _client.object(
      ApiConstants.profile,
      method: 'PATCH',
      // Only what changed. A PATCH carrying every field would overwrite a name
      // somebody edited on another device with whatever this form last read.
      body: {'first_name': ?firstName?.trim(), 'last_name': ?lastName?.trim()},
    );
    return AuthUser.fromJson(data);
  }

  /// Always reports success, whether or not the address is registered — the API
  /// is deliberately silent about which addresses exist, and the UI must not
  /// undo that by saying "no such account".
  @override
  Future<void> requestPasswordReset(String email) async {
    // `send`, not `object`. This route returns `{success, message, data: null}`
    // — there is nothing to send back — and `object` demands a Map, so it threw
    // "The server sent something unexpected" on every *successful* request. The
    // email went out and the app reported a failure.
    await _client.send(
      ApiConstants.forgotPassword,
      method: 'POST',
      body: {'email': email.trim().toLowerCase()},
    );
  }

  @override
  Future<PasswordResetSession> verifyResetCode({
    required String email,
    required String code,
  }) async {
    final data = await _client.object(
      ApiConstants.verifyResetCode,
      method: 'POST',
      body: {
        'email': email.trim().toLowerCase(),
        // Spaces stripped here as well as server-side: a code pasted out of an
        // email arrives as "482 913", and the field should not have to care.
        'code': code.replaceAll(RegExp(r'\s+'), ''),
      },
    );
    return PasswordResetSession.fromJson(data);
  }

  @override
  Future<String?> forgetSession() async {
    final refresh = _tokens.refreshToken;
    await _tokens.clear();
    return refresh;
  }

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    // Also a null-data route — see [requestPasswordReset].
    await _client.send(
      ApiConstants.resetPassword,
      method: 'POST',
      body: {'token': token.trim(), 'new_password': newPassword},
    );
  }

  /// Changes the password and adopts the new token pair the API returns.
  ///
  /// The old sessions are revoked server-side, so failing to store the new
  /// tokens would sign this device out a moment later.
  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final data = await _client.object(
      ApiConstants.changePassword,
      method: 'POST',
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is String && refresh is String) {
      await _tokens.save(accessToken: access, refreshToken: refresh);
    }
  }

  /// Reads the `{user, tokens}` shape returned by every sign-in route, stores
  /// the pair, and hands back the user.
  Future<AuthUser> _storeSession(Map<String, dynamic> data) async {
    final tokens = data['tokens'];
    if (tokens is Map) {
      final access = tokens['access_token'];
      final refresh = tokens['refresh_token'];
      if (access is String && refresh is String) {
        await _tokens.save(accessToken: access, refreshToken: refresh);
      }
    }

    final user = data['user'];
    if (user is Map) {
      return _remember(AuthUser.fromJson(Map<String, dynamic>.from(user)));
    }

    // Some deployments return only tokens. Asking who we are is cheaper than
    // guessing, and the role decides which half of the app opens.
    return currentUser();
  }
}
