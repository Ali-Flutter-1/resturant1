import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/api_failure.dart';
import 'domain/auth_repository.dart';
import 'domain/password_reset.dart';
import 'domain/auth_user.dart';

export 'domain/auth_user.dart' show AuthUser, UserRole;
export 'domain/password_reset.dart' show PasswordResetSession, ResetErrorCodes;

class AuthState extends Equatable {
  const AuthState({
    this.user,
    this.isSubmitting = false,
    this.isRestoring = false,
    this.hasRestored = false,
    this.error,
    this.errorIsRetryable = false,
    this.fieldErrors = const {},
  });

  /// Null means signed out.
  final AuthUser? user;

  final bool isSubmitting;

  /// True while a stored session is being checked at startup, so the app can
  /// hold the splash rather than flashing the login screen at someone who is
  /// already signed in.
  final bool isRestoring;

  /// Whether startup has finished deciding whether anyone is signed in.
  ///
  /// Distinct from [isRestoring], which is only true while a request is in
  /// flight. A device with no stored session never makes that request, so
  /// `isRestoring` is false both before the question is asked and after — and
  /// the splash needs to tell those apart to know when it may hand over.
  final bool hasRestored;

  /// Safe to show verbatim; it comes from [ApiFailure.message].
  final String? error;

  /// Whether offering "Try again" makes sense for this error.
  final bool errorIsRetryable;

  /// Per-field complaints from the API, keyed by its field names.
  final Map<String, String> fieldErrors;

  UserRole? get role => user?.role;
  String? get email => user?.email;
  bool get isSignedIn => user != null;

  AuthState copyWith({
    AuthUser? user,
    bool? isSubmitting,
    bool? isRestoring,
    bool? hasRestored,
    String? error,
    bool? errorIsRetryable,
    Map<String, String>? fieldErrors,
    bool clearError = false,
    bool signOut = false,
  }) {
    return AuthState(
      user: signOut ? null : (user ?? this.user),
      isSubmitting: isSubmitting ?? this.isSubmitting,
      isRestoring: isRestoring ?? this.isRestoring,
      hasRestored: hasRestored ?? this.hasRestored,
      error: clearError || signOut ? null : (error ?? this.error),
      errorIsRetryable: clearError || signOut
          ? false
          : (errorIsRetryable ?? this.errorIsRetryable),
      fieldErrors: clearError || signOut
          ? const {}
          : (fieldErrors ?? this.fieldErrors),
    );
  }

  @override
  List<Object?> get props => [
    user,
    isSubmitting,
    isRestoring,
    hasRestored,
    error,
    errorIsRetryable,
    fieldErrors,
  ];
}

/// The session.
///
/// Talks to [AuthRepository] and holds nothing the rest of the app doesn't need.
/// Every failure arrives as an [ApiFailure] whose message is already fit to
/// show, so this class never composes error text of its own — doing so is how
/// apps end up telling users about status codes.
class AuthCubit extends Cubit<AuthState> {
  AuthCubit({AuthRepository? repository, AuthUser? initialUser})
    : _repository = repository,
      super(AuthState(user: initialUser));

  /// Null only where sign-in cannot be attempted — a preview, or a test that
  /// starts from [initialUser] and never calls the network.
  final AuthRepository? _repository;

  /// Run once a session exists — after sign-in, sign-up or a restore.
  ///
  /// Used to register this installation for push. Deliberately a callback rather
  /// than a dependency: the session has no business knowing what notifications
  /// are, and a failure here must never keep somebody out of the app.
  Future<void> Function()? onSignedIn;

  /// Run **before** the logout request, while the access token still works.
  ///
  /// Used to remove this device's push registration. The order matters: after
  /// logout the token is gone, and the next person to sign in on this phone
  /// would keep receiving the previous user's alerts.
  Future<void> Function()? onSigningOut;

  /// Fires [onSignedIn] without letting it block or break anything.
  void _announceSignIn() {
    final hook = onSignedIn;
    if (hook == null) return;
    hook().catchError((Object _) {
      // Swallowed on purpose. Registration retries on the next launch, and a
      // notification problem is not a sign-in problem.
    });
  }

  /// Restores a stored session, if there is one.
  ///
  /// Called once at startup. A failure here is not worth showing: being signed
  /// out is a normal state, and an error banner on first launch would be
  /// alarming and useless.
  Future<void> restore() async {
    final repository = _repository;
    // Nothing stored means the answer is already known: signed out. The flag
    // still has to be set, or the splash would wait for a request that is
    // never going to be made.
    if (repository == null || !repository.hasStoredSession) {
      emit(state.copyWith(hasRestored: true));
      return;
    }

    emit(state.copyWith(isRestoring: true));
    try {
      final user = await repository.currentUser();
      emit(AuthState(user: user, hasRestored: true));
      _announceSignIn();
    } on ApiFailure catch (failure) {
      // Only the server can sign somebody out.
      //
      // A 401 here means the refresh token is spent or revoked -- the session
      // is genuinely over, and the stored copy goes with it. Anything else
      // (no network, a timeout, a backend that is down) means we could not
      // *ask*, which is not the same answer. Treating those as "signed out"
      // is what put a customer with a valid token on the login screen every
      // time they opened the app on the underground, where signing in again
      // was equally impossible.
      final cached = repository.cachedUser;
      if (failure.requiresSignIn || cached == null) {
        emit(const AuthState(hasRestored: true));
        return;
      }

      // The last known profile, which is enough to open the right half of the
      // app. Every screen still asks the server for its own data and shows its
      // own offline state; nothing here is presented as fresh.
      emit(AuthState(user: cached, hasRestored: true));
      _announceSignIn();
    }
  }

  /// Drops any error and field complaints left over from a previous attempt.
  ///
  /// Sign-in and sign-up share one cubit, so a failure on one screen was
  /// rendering the moment the other opened — which looked exactly like the
  /// second screen having submitted by itself. Each screen clears on entry.
  void clearError() {
    if (state.error == null && state.fieldErrors.isEmpty) return;
    emit(state.copyWith(clearError: true));
  }

  Future<void> signIn({required String email, required String password}) =>
      _attempt(() => _repository!.login(email: email, password: password));

  Future<void> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
  }) => _attempt(
    () => _repository!.register(
      firstName: firstName,
      lastName: lastName,
      email: email,
      password: password,
    ),
  );

  Future<void> signInWithGoogle(String idToken) =>
      _attempt(() => _repository!.signInWithGoogle(idToken));

  /// Runs a sign-in attempt and reports it uniformly.
  Future<void> _attempt(Future<AuthUser> Function() action) async {
    if (_repository == null) {
      emit(
        state.copyWith(
          error: 'Sign-in is not available in this build.',
          isSubmitting: false,
        ),
      );
      return;
    }

    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      emit(AuthState(user: await action(), hasRestored: true));
      _announceSignIn();
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          isSubmitting: false,
          error: failure.message,
          errorIsRetryable: failure.isRetryable,
          fieldErrors: failure.fieldErrors,
        ),
      );
    }
  }

  /// Signs out of this device.
  ///
  /// The local state clears immediately rather than after the round trip: the
  /// user asked to leave, and making them watch a spinner to do it — or leaving
  /// them signed in because the request failed — would both be wrong.
  Future<void> signOut() async {
    // The screen changes first — the user asked to leave and should not watch a
    // spinner to do it.
    emit(const AuthState(hasRestored: true));

    // Then the device forgets the session, before any network call rather than
    // after them. Clearing last left a window — as long as two round trips on
    // a bad connection — in which the tokens and the cached profile were still
    // on the phone, so restarting the app signed the same person straight back
    // in, and a *new* sign-in during that window had its tokens wiped by the
    // old logout finishing. Both looked like "signing out did not work, but it
    // works if you wait".
    final refreshToken = await _repository?.forgetSession();

    // Then the device is de-registered, and only then the logout call. The
    // order is what matters: it is `logout` that invalidates the access token,
    // and removing this installation needs a valid one. Skip it and the next
    // person to sign in on this phone receives the previous user's alerts.
    try {
      await onSigningOut?.call();
    } on Object {
      // Never blocks signing out. Leaving somebody signed in for the sake of
      // tidy bookkeeping is the worse failure, and the removal is idempotent —
      // the next sign-in on this device transfers the registration anyway.
    }
    // Best effort, and last: the session is already gone from this device, so
    // a refusal here costs nothing but a token that will expire on its own.
    await _repository?.logout(refreshToken: refreshToken);
  }

  /// Closes the account.
  ///
  /// Returns an error message to show, or null on success. Unlike [signOut] the
  /// local state is cleared only once the server confirms: signing someone out
  /// of an account the server refused to delete would tell them it was gone
  /// when it is not.
  Future<String?> deleteAccount(String password) async {
    if (_repository == null) return 'Not available in this build.';

    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      await _repository.deleteAccount(password);
      emit(const AuthState(hasRestored: true));
      return null;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(isSubmitting: false, error: failure.message));
      return failure.message;
    }
  }

  /// Re-reads `/auth/me`.
  ///
  /// For pulling in a change made elsewhere — a role promoted in the admin
  /// panel, a name edited on another device. Quiet on failure: the session
  /// already on screen is still usable, and an error banner for a refresh
  /// nobody asked for would be noise.
  Future<void> refreshUser() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      emit(state.copyWith(user: await repository.currentUser()));
    } on ApiFailure catch (failure) {
      // Quiet on a network failure — the session on screen is still usable, and
      // an error banner for a refresh nobody asked for would be noise.
      //
      // Not quiet on a refusal. On `/auth/me` of all routes, a 401 that survived
      // the token refresh or a 403 can only mean this account may no longer be
      // used: deactivated or closed by an admin. Leaving the user in the app
      // means every screen they open fails one at a time, which reads as the app
      // being broken rather than as their access having been withdrawn.
      if (failure.requiresSignIn || failure.kind == ApiFailureKind.forbidden) {
        await forgetSession();
      }
    }
  }

  /// Updates the signed-in person's own name.
  ///
  /// Returns an error message to show, or null on success. The state adopts the
  /// user the server returned rather than the strings typed in, so what the app
  /// shows afterwards is what was actually saved.
  Future<String?> updateProfile({
    required String firstName,
    required String lastName,
  }) async {
    if (_repository == null) return 'Not available in this build.';

    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      final user = await _repository.updateProfile(
        firstName: firstName,
        lastName: lastName,
      );
      emit(state.copyWith(user: user, isSubmitting: false));
      return null;
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          isSubmitting: false,
          error: failure.message,
          fieldErrors: failure.fieldErrors,
        ),
      );
      return failure.message;
    }
  }

  /// Changes the password on the signed-in account.
  ///
  /// Returns an error message to show, or null on success. The repository adopts
  /// the fresh token pair the API returns — the server revokes the old sessions,
  /// so a device that ignored the new tokens would sign itself out moments
  /// later.
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (_repository == null) return 'Not available in this build.';

    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      await _repository.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      emit(state.copyWith(isSubmitting: false));
      return null;
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          isSubmitting: false,
          error: failure.message,
          fieldErrors: failure.fieldErrors,
        ),
      );
      return failure.message;
    }
  }

  /// Step 2 of the reset: exchanges the emailed code for a token.
  ///
  /// Returns the session on success, or the [ApiFailure] on refusal — the whole
  /// failure rather than just its message, because the flow branches on
  /// `error.code`: a wrong code keeps the user on the same screen, a lockout
  /// sends them back to the start.
  ///
  /// Nothing is stored in state. The token is a bearer credential for changing a
  /// password and lives only as long as the screen holding it.
  Future<(PasswordResetSession?, ApiFailure?)> verifyResetCode({
    required String email,
    required String code,
  }) async {
    if (_repository == null) {
      return (
        null,
        const ApiFailure(
          kind: ApiFailureKind.unknown,
          message: 'Not available in this build.',
        ),
      );
    }

    try {
      final session = await _repository.verifyResetCode(
        email: email,
        code: code,
      );
      return (session, null);
    } on ApiFailure catch (failure) {
      return (null, failure);
    }
  }

  /// Forgets this device's tokens without calling the server.
  ///
  /// Used after a reset, which revokes every session server-side — so a `logout`
  /// call would be a request that cannot succeed.
  Future<void> forgetSession() async {
    await _repository?.forgetSession();
    emit(const AuthState(hasRestored: true));
  }

  /// Completes a reset with the token from the email.
  ///
  /// Returns an error message to show, or null on success. Deliberately does
  /// not sign the user in: the API returns no tokens here, and the reset may
  /// well have been requested because someone else had the old password.
  /// Step 3: sets the new password, then forgets this device's session.
  ///
  /// Returns the failure on refusal so the flow can branch on `error.code` — a
  /// weak password keeps the user on the screen with the token still good, an
  /// invalid token sends them back to the start.
  ///
  /// On success every session everywhere is revoked, so the local tokens are
  /// cleared here rather than being left to expire and fail confusingly later.
  /// The user is deliberately *not* signed in: the API returns no tokens, and a
  /// reset is often requested precisely because somebody else had the old
  /// password.
  Future<ApiFailure?> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    if (_repository == null) {
      return const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'Not available in this build.',
      );
    }

    emit(state.copyWith(isSubmitting: true, clearError: true));
    try {
      await _repository.resetPassword(token: token, newPassword: newPassword);
      await forgetSession();
      return null;
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          isSubmitting: false,
          error: failure.message,
          fieldErrors: failure.fieldErrors,
        ),
      );
      return failure;
    }
  }

  /// Requests a reset email. Reports the API's own wording, which is
  /// deliberately the same whether or not the address exists.
  Future<String?> requestPasswordReset(String email) async {
    try {
      await _repository?.requestPasswordReset(email);
      return null;
    } on ApiFailure catch (failure) {
      return failure.message;
    }
  }
}
