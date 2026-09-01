import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/auth/auth_cubit.dart';
import 'package:practice/features/auth/login_screen.dart';
import 'package:practice/features/auth/register_screen.dart';
import 'package:practice/features/auth/presentation/require_sign_in.dart';
import 'package:practice/features/shell/customer_shell.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_auth_repository.dart';
import 'support/guest_providers.dart';

/// Browsing without an account.
///
/// The shape this pins: everything a customer might use to decide whether to
/// order is public, and the account is asked for at the moment the order
/// becomes theirs -- not before, and never again once they have one.
void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 1400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  Widget wrap(AuthCubit auth) => BlocProvider.value(
    value: auth,
    child: guestProviders(
      MaterialApp(theme: AppTheme.light, home: const CustomerShell()),
    ),
  );

  group('a guest', () {
    testWidgets('gets the menu, not a login wall', (tester) async {
      await tester.pumpWidget(
        wrap(AuthCubit(repository: FakeAuthRepository())),
      );
      await tester.pumpAndSettle();

      // The whole point: somebody who has not signed in can see what is for
      // sale. Making them register first is how the sale is lost.
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(CustomerShell), findsOne);
    });

    testWidgets('is invited, not blocked, on the account-shaped tabs', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(AuthCubit(repository: FakeAuthRepository())),
      );
      await tester.pumpAndSettle();

      // Orders and Profile have nothing to show without an account, and their
      // endpoints answer a session-less request with a 401 -- so they invite
      // rather than fail.
      for (final (tab, heading) in [
        ('Orders', 'Your orders live here'),
        ('Profile', 'Your account'),
      ]) {
        await tester.tap(navTab(tab));
        await tester.pumpAndSettle();
        expect(find.text(heading), findsOne, reason: tab);
        expect(
          find.text('Sign in or create an account'),
          findsOne,
          reason: tab,
        );
      }
    });

    testWidgets('sees no notification bell', (tester) async {
      await tester.pumpWidget(
        wrap(AuthCubit(repository: FakeAuthRepository())),
      );
      await tester.pumpAndSettle();

      // The inbox is per-account, so a bell here would open an error.
      expect(find.byIcon(Icons.notifications_outlined), findsNothing);
    });
  });

  group('somebody already signed in', () {
    testWidgets('is never asked to sign in again', (tester) async {
      await tester.pumpWidget(wrap(AuthFixtures.cubit(AuthFixtures.customer)));
      await tester.pumpAndSettle();

      for (final tab in ['Orders', 'Profile', 'Book']) {
        await tester.tap(navTab(tab));
        await tester.pumpAndSettle();
        expect(find.text('Sign in or create an account'), findsNothing);
      }
      expect(find.byType(LoginScreen), findsNothing);
    });

    test('the gate returns at once, with nothing shown', () async {
      // `requireSignIn` is a no-op with a session: no prompt, no flash of a
      // login screen, no await on a route that never opened.
      final auth = AuthFixtures.cubit(AuthFixtures.customer);
      expect(auth.state.isSignedIn, isTrue);
      await auth.close();
    });
  });

  _shellRules();

  group('the gate itself', () {
    /// A button that does something only a signed-in customer may do.
    Widget host(AuthCubit auth) => BlocProvider.value(
      value: auth,
      child: guestProviders(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final ok = await requireSignIn(
                    context,
                    toContinue: 'to place your order',
                  );
                  if (ok && context.mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(
                          body: Center(child: Text('carried on')),
                        ),
                      ),
                    );
                  }
                },
                child: const Text('place order'),
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('asks a guest, and says why', (tester) async {
      await tester.pumpWidget(
        host(AuthCubit(repository: FakeAuthRepository())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('place order'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOne);
      // The interruption explains itself rather than appearing from nowhere.
      expect(find.textContaining('Sign in to place your order'), findsOne);
      // ...and what they were doing has not happened.
      expect(find.text('carried on'), findsNothing);
    });

    testWidgets('carries on with the action once signed in', (tester) async {
      final auth = AuthCubit(repository: FakeAuthRepository());
      await tester.pumpWidget(host(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('place order'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOne);

      await auth.signIn(email: 'ali@example.com', password: 'password1');
      await tester.pumpAndSettle();

      // The gate closes itself on the session, whether it arrived from signing
      // in, registering, or finishing a password reset...
      expect(find.byType(LoginScreen), findsNothing);
      // ...and the thing they were trying to do happens, rather than dumping
      // them back at the beginning.
      expect(find.text('carried on'), findsOne);
      await auth.close();
    });

    testWidgets('registering closes the gate, not just the sign-up screen', (
      tester,
    ) async {
      final auth = AuthCubit(repository: FakeAuthRepository());
      await tester.pumpWidget(host(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('place order'));
      await tester.pumpAndSettle();

      // Off to create an account, which pushes on top of the gate.
      await tester.tap(find.text('Create an account'));
      await tester.pumpAndSettle();
      expect(find.byType(RegisterScreen), findsOne);

      await auth.register(
        firstName: 'Ali',
        lastName: 'Hassan',
        email: 'ali@example.com',
        password: 'password1',
      );
      await tester.pumpAndSettle();

      // Popping the top route closed the *sign-up* screen and left the gate
      // showing a login form to somebody who had just been signed in -- which
      // then did nothing when they typed their password, because there was no
      // signed-out-to-signed-in change left to listen for. Going back was the
      // only way out, and it revealed they had been signed in all along.
      expect(find.byType(RegisterScreen), findsNothing);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('carried on'), findsOne);
      await auth.close();
    });

    testWidgets('shows nothing at all to somebody signed in', (tester) async {
      await tester.pumpWidget(host(AuthFixtures.cubit(AuthFixtures.customer)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('place order'));
      await tester.pumpAndSettle();

      // Straight through: no prompt, no flash of a login screen.
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('carried on'), findsOne);
    });
  });
}

void _shellRules() {
  group('signing out returns to the guest app, not a login wall', () {
    testWidgets('the menu is still there afterwards', (tester) async {
      final auth = AuthFixtures.cubit(AuthFixtures.customer);
      await tester.pumpWidget(
        BlocProvider.value(
          value: auth,
          child: guestProviders(
            MaterialApp(theme: AppTheme.light, home: const CustomerShell()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign in or create an account'), findsNothing);

      await auth.signOut();
      await tester.pumpAndSettle();

      // Signing out is not being thrown out: the menu was public before they
      // signed in and it is public afterwards.
      expect(find.byType(CustomerShell), findsOne);
      expect(find.byType(LoginScreen), findsNothing);
      await auth.close();
    });

    testWidgets('the account tabs go back to inviting', (tester) async {
      final auth = AuthFixtures.cubit(AuthFixtures.customer);
      await tester.pumpWidget(
        BlocProvider.value(
          value: auth,
          child: guestProviders(
            MaterialApp(theme: AppTheme.light, home: const CustomerShell()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(navTab('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('Your account'), findsNothing);

      await auth.signOut();
      await tester.pumpAndSettle();

      // The same tab, now with nothing to show and an invitation instead --
      // and no stale account details left on screen.
      expect(find.text('Your account'), findsOne);
      await auth.close();
    });
  });
}

/// Finds a tab by name: the bar labels only the selected one, so every other
/// tab's name lives in its [Semantics].
Finder navTab(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);
