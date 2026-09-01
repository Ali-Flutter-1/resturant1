import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/page_transitions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../auth_cubit.dart';
import '../login_screen.dart';

/// Asks for a session, but only when there is not one already.
///
/// The app is browsable without an account: the menu, a dish, the delivery
/// areas and the address are all public, and making somebody register before
/// they can see what is for sale is how a restaurant loses the sale. An account
/// is needed at the point where the order becomes theirs -- so that is where
/// this is called, and nowhere earlier.
///
/// Returns true if there is a session by the time it finishes, whether it was
/// already there or was just created. The caller then carries on with what the
/// customer was doing, which is the whole point: being asked to sign in and
/// then dumped back at the beginning is the thing that makes people give up.
///
/// Nothing is shown to somebody already signed in -- no prompt, no flash of a
/// login screen.
Future<bool> requireSignIn(
  BuildContext context, {

  /// What they were trying to do, as a sentence fragment: "to place your
  /// order", "to book a table". Shown above the form so the interruption
  /// explains itself.
  String? toContinue,
}) async {
  if (context.read<AuthCubit>().state.isSignedIn) return true;

  await Navigator.of(context, rootNavigator: true).push(
    AppPageRoute<void>(builder: (_) => _SignInGate(toContinue: toContinue)),
  );

  if (!context.mounted) return false;
  return context.read<AuthCubit>().state.isSignedIn;
}

/// The sign-in screen, wrapped so it closes itself the moment a session exists.
///
/// Closing on the *state* rather than on the button's callback is deliberate:
/// the session can arrive from sign-in, from registering, or from finishing a
/// password reset, and all three should land the customer back where they were.
class _SignInGate extends StatefulWidget {
  const _SignInGate({this.toContinue});

  final String? toContinue;

  @override
  State<_SignInGate> createState() => _SignInGateState();
}

class _SignInGateState extends State<_SignInGate> {
  @override
  Widget build(BuildContext context) {
    // This gate's own route, captured so the listener can close *it* rather
    // than whatever happens to be on top.
    final gate = ModalRoute.of(context);

    return BlocListener<AuthCubit, AuthState>(
      listenWhen: (was, now) => !was.isSignedIn && now.isSignedIn,
      listener: (context, _) {
        final navigator = Navigator.of(context);
        // Everything the gate opened goes with it. Registering pushes the
        // sign-up screen on top, so a plain `pop()` closed *that* and left the
        // gate showing a login form to somebody who had just been signed in --
        // which then did nothing when they typed their new password, because
        // there was no signed-out-to-signed-in change left to listen for.
        if (gate != null) navigator.popUntil((route) => route == gate);
        navigator.pop();
      },
      child: Scaffold(
        body: Column(
          children: [
            if (widget.toContinue != null)
              _WhyBanner(toContinue: widget.toContinue!),
            Expanded(
              child: LoginScreen(onBack: () => Navigator.of(context).pop()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says why the form appeared.
class _WhyBanner extends StatelessWidget {
  const _WhyBanner({required this.toContinue});

  final String toContinue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: context.surfaces.accentContainer,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        MediaQuery.paddingOf(context).top + AppSpacing.x3,
        AppSpacing.gutter,
        AppSpacing.x3,
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: AppIconSize.lg, color: scheme.primary),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Text(
              'Sign in $toContinue. Everything you have chosen is kept.',
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a tab shows a guest instead of the account-only screen behind it.
///
/// Not an error and not an empty state: there is nothing wrong and nothing
/// missing, they simply have not signed in yet.
class SignedOutPanel extends StatelessWidget {
  const SignedOutPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.toContinue,
    this.onSignedIn,
    this.extraLabel,
    this.extraIcon,
    this.onExtra,
  });

  final IconData icon;
  final String title;
  final String body;

  /// The fragment for [requireSignIn]'s banner.
  final String toContinue;

  /// Called once a session exists, for a screen that needs to load itself.
  final VoidCallback? onSignedIn;

  /// A second, quieter offer for something that needs no account at all.
  final String? extraLabel;
  final IconData? extraIcon;
  final VoidCallback? onExtra;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppIconSize.hero, color: context.surfaces.inkSoft),
            const SizedBox(height: AppSpacing.x4),
            Text(
              title,
              style: context.texts.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              body,
              style: context.texts.bodyMedium?.copyWith(
                color: context.surfaces.inkMuted,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(
              label: 'Sign in or create an account',
              expand: false,
              onPressed: () async {
                final signedIn = await requireSignIn(
                  context,
                  toContinue: toContinue,
                );
                if (signedIn) onSignedIn?.call();
              },
            ),
            // Part of the invitation, under the button it belongs with --
            // rather than a stray link at the foot of the screen with nothing
            // around it to say what it is.
            if (onExtra != null) ...[
              const SizedBox(height: AppSpacing.x3),
              TextButton.icon(
                onPressed: onExtra,
                icon: Icon(
                  extraIcon ?? Icons.open_in_new,
                  size: AppIconSize.md,
                ),
                label: Text(extraLabel ?? 'More'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
