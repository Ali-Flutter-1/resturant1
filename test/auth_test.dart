import 'package:flutter/material.dart';
import 'package:practice/features/legal/presentation/legal_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/menu/domain/dish.dart';

import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/auth/auth_cubit.dart';
import 'package:practice/features/auth/login_screen.dart';
import 'package:practice/features/auth/register_screen.dart';

import 'support/fake_auth_repository.dart';

const _customer = AuthUser(
  id: 'u1',
  email: 'ali@example.com',
  firstName: 'Ali',
  lastName: 'Hassan',
  role: UserRole.customer,
);

const _admin = AuthUser(
  id: 'u2',
  email: 'boss@tscafe.co.uk',
  firstName: 'Sam',
  lastName: 'Owner',
  role: UserRole.admin,
);

/// The input carrying [hint]. Addressed by hint rather than by index so adding
/// a field to a form cannot silently retarget a test.
Finder _field(String hint) =>
    find.ancestor(of: find.text(hint), matching: find.byType(TextField));

void main() {
  group('UserRole', () {
    test('maps the API\'s three roles, unknown ones landing on customer', () {
      expect(UserRole.fromApi('admin'), UserRole.admin);
      expect(UserRole.fromApi('staff'), UserRole.staff);
      expect(UserRole.fromApi('customer'), UserRole.customer);
      // An unrecognised role must get the least-privileged interface.
      expect(UserRole.fromApi('sous_chef'), UserRole.customer);
      expect(UserRole.fromApi(null), UserRole.customer);
    });

    test('staff use the admin shell but may not manage the venue', () {
      expect(UserRole.staff.usesAdminShell, isTrue);
      expect(UserRole.staff.canManageVenue, isFalse);
      expect(UserRole.admin.canManageVenue, isTrue);
      expect(UserRole.customer.usesAdminShell, isFalse);
    });
  });

  group('AuthCubit', () {
    test('starts signed out', () {
      expect(AuthCubit().state.isSignedIn, isFalse);
    });

    test('a successful sign-in adopts the role the server reports', () async {
      final repository = FakeAuthRepository(user: _admin);
      final cubit = AuthCubit(repository: repository);

      await cubit.signIn(email: '  Boss@TsCafe.co.uk ', password: 'secret');

      expect(cubit.state.role, UserRole.admin);
      expect(cubit.state.error, isNull);
      expect(cubit.state.isSubmitting, isFalse);
      // Credentials reach the repository untouched; normalising them is the
      // repository's job and is covered in auth_repository_test.dart.
      expect(repository.lastPassword, 'secret');
    });

    test("a refusal surfaces the API's own message", () async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(
          failure: const ApiFailure(
            kind: ApiFailureKind.unauthorised,
            message: 'That email and password do not match.',
            statusCode: 401,
          ),
        ),
      );

      await cubit.signIn(email: 'a@b.com', password: 'wrong');

      expect(cubit.state.error, 'That email and password do not match.');
      expect(cubit.state.isSignedIn, isFalse);
      expect(cubit.state.isSubmitting, isFalse);
      // Wrong credentials are not worth a retry button.
      expect(cubit.state.errorIsRetryable, isFalse);
    });

    test('an offline attempt is retryable and says nothing was sent', () async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(failure: ApiFailure.offline),
      );

      await cubit.signIn(email: 'a@b.com', password: 'x');

      expect(cubit.state.errorIsRetryable, isTrue);
      expect(cubit.state.error, contains('offline'));
    });

    test('field errors are carried through for the form to point at', () async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(
          failure: const ApiFailure(
            kind: ApiFailureKind.invalid,
            message: 'Enter a valid email address',
            fieldErrors: {'email': 'Enter a valid email address'},
          ),
        ),
      );

      await cubit.signIn(email: 'nope', password: 'x');

      expect(cubit.state.fieldErrors['email'], 'Enter a valid email address');
    });

    test('a failed sign-in does not clear an existing session', () async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(
          failure: const ApiFailure(
            kind: ApiFailureKind.server,
            message: 'The server is having trouble.',
          ),
        ),
        initialUser: _admin,
      );

      await cubit.signIn(email: 'a@b.com', password: 'x');

      // It reports the error but must not silently sign the user out.
      expect(cubit.state.role, UserRole.admin);
      expect(cubit.state.error, isNotNull);
    });

    test('signOut clears locally first, then revokes the token', () async {
      final repository = FakeAuthRepository(user: _admin);
      final cubit = AuthCubit(repository: repository, initialUser: _admin);

      final pending = cubit.signOut();
      // Already signed out before the network call resolves: the user asked to
      // leave, and shouldn't wait on a round trip to do it.
      expect(cubit.state.isSignedIn, isFalse);
      expect(cubit.state.email, isNull);

      await pending;
      expect(repository.logoutCalls, 1);
    });

    group('restore', () {
      test('does nothing when no token was stored', () async {
        // The shared fake reports a stored session by default, which is the
        // common case; this is the other one.
        final repository = FakeAuthRepository(user: _customer)
          ..storedSession = false;
        await AuthCubit(repository: repository).restore();
        expect(repository.currentUserCalls, 0);
      });

      test('signs in from a stored token', () async {
        final cubit = AuthCubit(
          repository: FakeAuthRepository(user: _customer),
        );

        await cubit.restore();

        expect(cubit.state.role, UserRole.customer);
        expect(cubit.state.isRestoring, isFalse);
      });

      test('a rejected token leaves the user signed out, quietly', () async {
        final cubit = AuthCubit(
          repository: FakeAuthRepository(
            failure: const ApiFailure(
              kind: ApiFailureKind.unauthorised,
              message: 'Your session has expired.',
            ),
          ),
        );

        await cubit.restore();

        expect(cubit.state.isSignedIn, isFalse);
        // No banner on first launch: being signed out is a normal state, not an
        // error worth alarming someone about.
        expect(cubit.state.error, isNull);
      });
    });
  });

  group('LoginScreen', () {
    Widget harness(AuthCubit cubit) => BlocProvider.value(
      value: cubit,
      child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
    );

    testWidgets('no demo shortcut remains on the screen', (tester) async {
      await tester.pumpWidget(harness(AuthCubit()));
      await tester.pumpAndSettle();

      // The demo panel signed a user in with no credentials and no server. It
      // is gone, along with the `signInAs` backdoor it called.
      expect(find.text('Demo accounts'), findsNothing);
      expect(find.text('Admin'), findsNothing);
      expect(find.text('Customer'), findsNothing);

      // And nothing is pre-filled: the fields start empty.
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.controller?.text ?? '', isEmpty);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('an empty form is refused without reaching the server', (
      tester,
    ) async {
      final repository = FakeAuthRepository(user: _admin);
      final cubit = AuthCubit(repository: repository);
      await tester.pumpWidget(harness(cubit));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Sign In'));
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      // Nothing was sent — failing locally is instant, and a round trip to
      // learn a field was blank is wasted.
      expect(repository.lastEmail, isNull);
      expect(cubit.state.isSignedIn, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a completed form signs in through the repository', (
      tester,
    ) async {
      final repository = FakeAuthRepository(user: _admin);
      final cubit = AuthCubit(repository: repository);
      await tester.pumpWidget(harness(cubit));
      await tester.pumpAndSettle();

      await tester.enterText(_field('you@example.com'), 'boss@tscafe.co.uk');
      await tester.enterText(_field('Your password'), 'Str0ngPass1');
      await tester.ensureVisible(find.text('Sign In'));
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(repository.lastEmail, 'boss@tscafe.co.uk');
      expect(cubit.state.role, UserRole.admin);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a rejected sign-in surfaces its error on screen', (
      tester,
    ) async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(
          failure: const ApiFailure(
            kind: ApiFailureKind.unauthorised,
            message: 'That email and password do not match.',
          ),
        ),
      );
      await tester.pumpWidget(harness(cubit));
      await tester.pumpAndSettle();

      // Driven through the button, not the cubit. The screen only shows a
      // server error for an attempt made *here*, so calling `signIn` directly
      // would prove nothing about what the user sees.
      await tester.enterText(_field('you@example.com'), 'wrong@example.com');
      await tester.enterText(_field('Your password'), 'whatever1');
      await tester.ensureVisible(find.text('Sign In'));
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('do not match'),
        findsOneWidget,
        reason: "the API's wording must reach the screen unaltered",
      );
      expect(cubit.state.isSignedIn, isFalse);

      // Entrance animations schedule delays on Timers. Tear the tree down and
      // let them expire, or the binding fails the test for a timer that
      // outlived the widget.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('RegisterScreen', () {
    Widget harness(AuthCubit cubit) => BlocProvider.value(
      value: cubit,
      child: MaterialApp(theme: AppTheme.light, home: const RegisterScreen()),
    );

    Future<void> teardown(WidgetTester tester) async {
      // Entrance animations schedule delays on Timers; let them expire.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('states the password rule before it is broken', (tester) async {
      await tester.pumpWidget(harness(AuthCubit()));
      await tester.pumpAndSettle();

      // A rule you only learn by failing is a rule shown too late.
      expect(
        find.text('Use at least 8 characters, with a letter and a number.'),
        findsOneWidget,
      );
      await teardown(tester);
    });

    testWidgets('every missing field is named, and nothing is sent', (
      tester,
    ) async {
      final repository = FakeAuthRepository(user: _customer);
      await tester.pumpWidget(harness(AuthCubit(repository: repository)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your first name.'), findsOneWidget);
      expect(find.text('Enter your last name.'), findsOneWidget);
      expect(find.text('Enter your email address.'), findsOneWidget);
      expect(find.text('Choose a password.'), findsOneWidget);
      expect(repository.lastEmail, isNull);
      await teardown(tester);
    });

    testWidgets('the API\'s password rules are enforced before sending', (
      tester,
    ) async {
      final repository = FakeAuthRepository(user: _customer);
      await tester.pumpWidget(harness(AuthCubit(repository: repository)));
      await tester.pumpAndSettle();

      await tester.enterText(_field('Ali'), 'Ali');
      await tester.enterText(_field('Hassan'), 'Hassan');
      await tester.enterText(_field('you@example.com'), 'ali@example.com');

      // Long enough, but no digit — the API requires a letter and a number.
      await tester.enterText(_field('At least 8 characters'), 'onlyletters');
      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      expect(find.text('Include at least one number.'), findsOneWidget);
      expect(repository.lastEmail, isNull);
      await teardown(tester);
    });

    testWidgets('a complete form registers and signs the user in', (
      tester,
    ) async {
      final cubit = AuthCubit(repository: FakeAuthRepository(user: _customer));
      await tester.pumpWidget(harness(cubit));
      await tester.pumpAndSettle();

      await tester.enterText(_field('Ali'), 'Ali');
      await tester.enterText(_field('Hassan'), 'Hassan');
      await tester.enterText(_field('you@example.com'), 'ali@example.com');
      await tester.enterText(_field('At least 8 characters'), 'Str0ngPass1');
      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      // Registering signs you in: the API returns a token pair, so sending the
      // user back to type the password they just chose would be gratuitous.
      expect(cubit.state.isSignedIn, isTrue);
      expect(cubit.state.role, UserRole.customer);
      await teardown(tester);
    });
  });

  group('the two auth screens do not bleed into each other', () {
    testWidgets("a failed sign-in does not appear on the sign-up screen", (
      tester,
    ) async {
      final cubit = AuthCubit(
        repository: FakeAuthRepository(
          failure: const ApiFailure(
            kind: ApiFailureKind.unauthorised,
            message: 'That email and password do not match.',
          ),
        ),
      );
      // A sign-in was refused first.
      await cubit.signIn(email: 'a@b.com', password: 'wrong');
      expect(cubit.state.error, isNotNull);

      // The user now opens sign-up. Both screens share one cubit, and this used
      // to render the stale error on arrival — which read as sign-up having
      // submitted by itself and failed.
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const RegisterScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('do not match'), findsNothing);
      // And nothing is mid-flight, so no spinner in place of the button.
      expect(find.text('Create Account'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('only the refused field shakes, not the page', (tester) async {
      await tester.pumpWidget(
        BlocProvider.value(
          value: AuthCubit(repository: FakeAuthRepository(user: _customer)),
          child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final headingBefore = tester.getTopLeft(find.text('Welcome back'));

      await tester.enterText(_field('you@example.com'), 'not-an-email');
      await tester.ensureVisible(find.text('Sign In'));
      await tester.tap(find.text('Sign In'));
      // Mid-shake.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The heading is outside the shaken subtree and must not have moved: the
      // shake is scoped to the field that was refused.
      expect(tester.getTopLeft(find.text('Welcome back')), headingBefore);
      expect(find.text('That email address looks incomplete.'), findsOneWidget);

      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('nothing starts without the button', () {
    testWidgets("the keyboard's tick does not sign in", (tester) async {
      final repository = FakeAuthRepository(user: _admin);
      final cubit = AuthCubit(repository: repository);
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_field('you@example.com'), 'boss@tscafe.co.uk');
      await tester.enterText(_field('Your password'), 'Str0ngPass1');

      // The tick on the iOS keyboard. It dismisses and nothing more — a
      // request that starts here begins before the user has re-read the form.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(repository.lastEmail, isNull, reason: 'no request should be sent');
      expect(cubit.state.isSignedIn, isFalse);

      // The button is still the only way in, and it works.
      await tester.ensureVisible(find.text('Sign In'));
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();
      expect(cubit.state.isSignedIn, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets("the keyboard's tick does not create an account", (
      tester,
    ) async {
      final repository = FakeAuthRepository(user: _customer);
      final cubit = AuthCubit(repository: repository);
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const RegisterScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_field('Ali'), 'Ali');
      await tester.enterText(_field('Hassan'), 'Hassan');
      await tester.enterText(_field('you@example.com'), 'ali@example.com');
      await tester.enterText(_field('At least 8 characters'), 'Str0ngPass1');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(cubit.state.isSignedIn, isFalse);
      // No validation errors either: the tick is not a rejected submission,
      // it is not a submission at all.
      expect(find.text('Choose a password.'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('what sign-out has to take with it', () {
    test('per-account state is emptied before the next person signs in', () async {
      // Whatever the app holds in memory for one account must not survive into
      // the next session on the same phone. The wiring lives in main(), so this
      // pins the contract the hook exists for.
      final cart = CartCubit()
        ..addDish(
          const Dish(
            id: 'd1',
            name: 'Kottu',
            description: '',
            pricePence: 1200,
          ),
        );
      expect(cart.state.count, 1);

      final auth = AuthCubit(repository: FakeAuthRepository(user: _admin));
      await auth.signIn(email: 'boss@tscafe.co.uk', password: 'secret');
      auth.onSigningOut = () async => cart.clear();

      await auth.signOut();

      expect(cart.state.count, 0);
      expect(cart.state.lines, isEmpty);
      await cart.close();
      await auth.close();
    });
  });

  group('what creating an account signs you up to', () {
    Widget wrapRegister() => MaterialApp(
      theme: AppTheme.light,
      home: BlocProvider(
        create: (_) => AuthCubit(repository: FakeAuthRepository()),
        child: const RegisterScreen(),
      ),
    );

    testWidgets('both documents are one tap from the button', (tester) async {
      await tester.pumpWidget(wrapRegister());
      await tester.pumpAndSettle();

      // Below the fold on a test surface, and a list only builds what it
      // shows. Dragged on the page's own list -- each text field is a
      // Scrollable too, so asking for "the" scrollable is ambiguous here.
      await tester.drag(find.text('Create Account'), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('By creating an account you agree'),
        findsOneWidget,
      );

      // Openable, and readable in the app -- somebody deciding whether to sign
      // up should not need a working connection to read what they are agreeing
      // to.
      // Asserted on each document's first heading, which is on screen the
      // moment it opens.
      for (final (link, heading) in [
        ('Terms and Conditions', 'Who we are'),
        ('Privacy Policy', 'What we collect'),
      ]) {
        await tester.ensureVisible(find.text(link));
        await tester.pumpAndSettle();
        await tester.tap(find.text(link));
        await tester.pumpAndSettle();

        expect(find.text(heading), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the policy describes what the app really does', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          // `context.surfaces` is a theme extension: without the app's theme
          // it is null and the screen throws on build.
          theme: AppTheme.light,
          home: const LegalScreen(document: LegalDocument.privacy),
        ),
      );
      await tester.pumpAndSettle();

      // Two claims worth pinning, because both would become false if the app
      // changed and nobody thought to reread this: the map hands coordinates
      // to the phone's own maps app, and cards never touch our systems.
      for (final claim in [
        'We do not track your location',
        'never see your card details',
      ]) {
        await tester.dragUntilVisible(
          find.textContaining(claim),
          find.byType(ListView),
          const Offset(0, -200),
        );
        expect(find.textContaining(claim), findsOne);
      }
    });
  });

  group('signing out lets go of the device first', () {
    test('the session is forgotten before anything is sent', () async {
      final repository = FakeAuthRepository();
      final cubit = AuthCubit(repository: repository);
      await cubit.signIn(email: 'ali@example.com', password: 'password1');

      final order = <String>[];
      cubit.onSigningOut = () async => order.add('unregister');

      await cubit.signOut();

      // Clearing last left a window as long as two round trips on a bad
      // connection: restarting the app inside it signed the same person
      // straight back in, and a fresh sign-in had its tokens wiped when the
      // old logout finally finished. Both read as "sign out did not work, but
      // it works if you wait".
      expect(repository.forgetCalls, 1);
      expect(repository.storedRefreshToken, isNull);
      expect(cubit.state.isSignedIn, isFalse);

      // ...and the revoke still happens, with the token that was dropped.
      expect(repository.logoutCalls, 1);
      expect(repository.lastRevokedToken, 'refresh-token');
      await cubit.close();
    });

    test('a refused revoke still leaves the device signed out', () async {
      final repository = FakeAuthRepository();
      final cubit = AuthCubit(repository: repository);
      await cubit.signIn(email: 'ali@example.com', password: 'password1');

      cubit.onSigningOut = () async => throw StateError('no network');

      await cubit.signOut();

      // Leaving somebody signed in for the sake of tidy bookkeeping is the
      // worse failure.
      expect(cubit.state.isSignedIn, isFalse);
      expect(repository.storedRefreshToken, isNull);
      await cubit.close();
    });
  });
}
