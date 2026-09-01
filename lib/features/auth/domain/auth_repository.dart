import 'auth_user.dart';
import 'password_reset.dart';

/// What the session needs from the outside world.
///
/// An interface rather than a concrete class so the cubit can be exercised
/// without a server — and so swapping the transport later (or adding a caching
/// layer in front of it) doesn't touch the cubit at all.
abstract interface class AuthRepository {
  /// Whether a refresh token survived the last run, and a session is therefore
  /// worth trying to restore.
  bool get hasStoredSession;

  /// The last profile the server gave, from local storage.
  ///
  /// Null when there has never been one. Used only when the server cannot be
  /// reached at startup -- it says who *was* signed in, never whether they
  /// still are.
  AuthUser? get cachedUser;

  Future<AuthUser> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
  });

  Future<AuthUser> login({required String email, required String password});

  Future<AuthUser> signInWithGoogle(String idToken);

  Future<AuthUser> currentUser();

  /// Revokes [refreshToken] server-side. Best effort: the device has already
  /// forgotten the session by the time this runs.
  Future<void> logout({String? refreshToken});

  /// Closes the account for good and signs this device out.
  ///
  /// Separate from [logout] because it is not a session operation: the server
  /// deletes the user, so there is nothing left to sign back in to.
  ///
  /// The current password is required — a valid access token alone is not
  /// enough to destroy an account, so an unlocked phone left on a table cannot
  /// be used to close someone's account.
  Future<void> deleteAccount(String password);

  /// Updates the signed-in person's own details.
  ///
  /// Only what is passed changes. Email is deliberately absent: the API refuses
  /// to change it here because it needs verification, so offering the field
  /// would be offering a dead end.
  ///
  /// Returns the updated user, so the session can adopt it without a second
  /// call to `/auth/me`.
  Future<AuthUser> updateProfile({String? firstName, String? lastName});

  /// Step 1: asks for a six-digit code by email.
  ///
  /// Succeeds whether or not the address is registered — the API is deliberately
  /// silent about that, and the app must not undo it.
  Future<void> requestPasswordReset(String email);

  /// Step 2: exchanges the emailed code for a reset token.
  ///
  /// Throws [ApiFailure] with an `error.code` the caller branches on — see
  /// [ResetErrorCodes].
  Future<PasswordResetSession> verifyResetCode({
    required String email,
    required String code,
  });

  /// Step 3: sets the new password using the token from step 2.
  ///
  /// Every session on every device is revoked by this, including this one.
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  });

  /// Forgets this device's tokens without calling the server, and hands back
  /// the refresh token it dropped.
  ///
  /// Two callers, one behaviour. After a password reset the token has already
  /// been revoked, so there is nothing to do with it. On sign-out the caller
  /// revokes it afterwards -- the point being that the device forgets *first*:
  /// until the tokens are gone the person is still signed in as far as this
  /// phone is concerned, and a slow round trip leaves a window in which
  /// restarting the app signs them straight back in.
  Future<String?> forgetSession();

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });
}
