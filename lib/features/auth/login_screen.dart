import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/animations/motion.dart';
import '../../core/animations/page_transitions.dart';
import '../../core/animations/reveal.dart';
import '../../core/haptics/app_haptics.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/widgets/app_buttons.dart';
import 'auth_cubit.dart';
import 'presentation/auth_form_parts.dart';
import 'register_screen.dart';
import 'forgot_password_flow.dart';
import '../../shared/widgets/page_body.dart';

/// Sign-in.
///
/// No frame for this exists in the Figma file — it is built from the app's own
/// design language.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  /// Client-side complaints, keyed like the API's own `fieldErrors` so both
  /// sources render through the same slot under each input.
  Map<String, String> _localErrors = const {};

  /// Whether the user has pressed submit on *this* screen.
  ///
  /// Guards against showing the shared cubit's error or spinner for an attempt
  /// made somewhere else. Nothing about a request appears until it was asked
  /// for here.
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    // Belt and braces with [_submitted]: entering the screen also drops
    // whatever the previous one left behind.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthCubit>().clearError();
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();

    final errors = <String, String>{};
    final email = AuthRules.email(_email.text);
    final password = AuthRules.presentPassword(_password.text);
    if (email != null) errors['email'] = email;
    if (password != null) errors['password'] = password;

    setState(() {
      _localErrors = errors;
      _submitted = true;
    });
    // Nothing is sent until the form is plausible. Failing locally is instant;
    // failing at the server costs a round trip to learn the field was blank.
    if (errors.isNotEmpty) {
      AppHaptics.failure();
      return;
    }

    context.read<AuthCubit>().signIn(
      email: _email.text,
      password: _password.text,
    );
  }

  /// Opens the reset flow, which asks for the email itself.
  ///
  /// No longer sends the request from here. The flow is three steps — email,
  /// code, new password — and firing step 1 before the screen exists spent one
  /// of the user's five hourly codes on a screen they might not have reached.
  void _forgotPassword() {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (_) => ForgotPasswordFlow(
          // Prefilled from whatever is already typed, so the common case is one
          // tap to send.
          email: _email.text.trim().isEmpty ? null : _email.text.trim(),
          onFinished: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
                tooltip: 'Back',
              ),
      ),
      body: BlocConsumer<AuthCubit, AuthState>(
        // The outcome of a sign-in is exactly the kind of thing haptics are
        // for: the user is looking at the keyboard, not the screen.
        listenWhen: (a, b) =>
            a.isSignedIn != b.isSignedIn ||
            (b.error != null && a.error != b.error),
        listener: (context, state) {
          if (state.isSignedIn) {
            AppHaptics.success();
          } else if (state.error != null) {
            AppHaptics.failure();
          }
        },
        builder: (context, state) {
          final motion = context.motion;
          // Server complaints win: it knows things the client cannot, and its
          // wording is already fit to show.
          final showServer = _submitted;
          final fieldErrors = {
            ..._localErrors,
            if (showServer) ...state.fieldErrors,
          };
          final formError = showServer ? state.error : null;

          return ListView(
            padding: pagePadding(
              context,
              top: AppSpacing.x4,
              bottom: AppSpacing.x12,
            ),
            children: [
              Text('Welcome back', style: context.texts.displayLarge),
              const SizedBox(height: AppSpacing.x2),
              Text(
                'Sign in to order, book a table, or manage the restaurant.',
                style: context.texts.bodyLarge?.copyWith(
                  color: context.surfaces.inkMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.x8),

              AuthField(
                label: 'Email',
                controller: _email,
                hint: 'you@example.com',
                icon: Icons.mail_outline,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                fieldError: fieldErrors['email'],
              ),
              const SizedBox(height: AppSpacing.x4),

              AuthField(
                label: 'Password',
                controller: _password,
                hint: 'Your password',
                icon: Icons.lock_outline,
                obscure: _obscure,
                autofillHints: const [AutofillHints.password],
                // The keyboard's tick dismisses the keyboard and nothing
                // more. Signing in or creating an account happens only when the
                // button is pressed — submitting from the last field starts the
                // request before the user has looked back over what they typed.
                onSubmitted: (_) => FocusScope.of(context).unfocus(),
                fieldError: fieldErrors['password'],
                suffix: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: AppIconSize.lg,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                ),
              ),

              // One entry point now. "I have a code" is gone: verifying a code
              // needs the email it was sent to, so a screen reached without one
              // could not do anything with it.
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: state.isSubmitting ? null : _forgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ),

              // A permanent slot that grows to fit. Keeping the child count
              // fixed matters: the staggered reveal identifies items by
              // position, so splicing one in would re-run the entrance of
              // everything below it on every failed sign-in.
              AnimatedSize(
                duration: motion.move(Motion.base),
                curve: motion.standard,
                alignment: Alignment.topCenter,
                child: formError == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.x4),
                        child: AuthErrorNote(message: formError),
                      ),
              ),

              // Cross-fade rather than cut, so the button appears to become
              // the spinner and the tap stays connected to its result.
              AnimatedSwitcher(
                duration: motion.fade(Motion.fast),
                child: showServer && state.isSubmitting
                    ? const SubmittingButton()
                    : PrimaryButton(label: 'Sign In', onPressed: _submit),
              ),

              const SizedBox(height: AppSpacing.x6),
              // A Wrap, not a Row: at 390pt -- an ordinary phone -- the
              // prompt and its button together were 41 points wider than the
              // screen, and a Row has nowhere to put the overflow.
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'New here?',
                    style: context.texts.bodyMedium?.copyWith(
                      color: context.surfaces.inkMuted,
                    ),
                  ),
                  TextButton(
                    onPressed: state.isSubmitting
                        ? null
                        : () => Navigator.of(context).push(
                            AppPageRoute<void>(
                              builder: (_) => RegisterScreen(
                                onBack: () => Navigator.of(context).pop(),
                              ),
                            ),
                          ),
                    child: const Text('Create an account'),
                  ),
                ],
              ),
            ].revealStaggered(),
          );
        },
      ),
    );
  }
}
