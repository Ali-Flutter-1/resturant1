import 'package:flutter/material.dart';
import '../../core/animations/page_transitions.dart';
import '../legal/presentation/legal_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/animations/motion.dart';
import '../../core/animations/reveal.dart';
import '../../core/haptics/app_haptics.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/widgets/app_buttons.dart';
import 'auth_cubit.dart';
import 'presentation/auth_form_parts.dart';
import '../../shared/widgets/page_body.dart';

/// Create an account.
///
/// No frame for this exists in the Figma file either, so it mirrors sign-in
/// deliberately — same field treatment, same error placement, same button
/// behaviour. An account flow where the second screen looks like a different
/// app is where people abandon.
///
/// Signing up signs you in: the API returns a token pair with the new account,
/// so there is no reason to send someone back to the sign-in screen to type the
/// password they just chose.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

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
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();

    // Keys match the API's field names, so a server complaint lands in the same
    // slot as the client's own and neither has to know about the other.
    final errors = <String, String>{};
    final first = AuthRules.name(_firstName.text, 'first name');
    final last = AuthRules.name(_lastName.text, 'last name');
    final email = AuthRules.email(_email.text);
    final password = AuthRules.password(_password.text);
    if (first != null) errors['first_name'] = first;
    if (last != null) errors['last_name'] = last;
    if (email != null) errors['email'] = email;
    if (password != null) errors['password'] = password;

    setState(() {
      _localErrors = errors;
      _submitted = true;
    });
    if (errors.isNotEmpty) {
      AppHaptics.failure();
      return;
    }

    context.read<AuthCubit>().register(
      firstName: _firstName.text,
      lastName: _lastName.text,
      email: _email.text,
      password: _password.text,
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
              Text('Create an account', style: context.texts.displayLarge),
              const SizedBox(height: AppSpacing.x2),
              Text(
                'To order, book a table, and keep your details for next time.',
                style: context.texts.bodyLarge?.copyWith(
                  color: context.surfaces.inkMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.x8),

              // Side by side: two full-width name fields make the form look
              // twice as long as it is, and length is what deters sign-ups.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AuthField(
                      label: 'First name',
                      controller: _firstName,
                      hint: 'Ali',
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.givenName],
                      fieldError: fieldErrors['first_name'],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(
                    child: AuthField(
                      label: 'Last name',
                      controller: _lastName,
                      hint: 'Hassan',
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.familyName],
                      fieldError: fieldErrors['last_name'],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),

              AuthField(
                label: 'Email',
                controller: _email,
                hint: 'you@example.com',
                icon: Icons.mail_outline,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                fieldError: fieldErrors['email'],
              ),
              const SizedBox(height: AppSpacing.x4),

              AuthField(
                label: 'Password',
                controller: _password,
                hint: 'At least 8 characters',
                icon: Icons.lock_outline,
                obscure: _obscure,
                autofillHints: const [AutofillHints.newPassword],
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
              const SizedBox(height: AppSpacing.x1),
              // Stated up front rather than only on refusal: a rule you learn
              // by failing is a rule shown too late.
              Text(
                'Use at least 8 characters, with a letter and a number.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.surfaces.inkMuted,
                ),
              ),

              AnimatedSize(
                duration: motion.move(Motion.base),
                curve: motion.standard,
                alignment: Alignment.topCenter,
                child: formError == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.x4),
                        child: AuthErrorNote(message: formError),
                      ),
              ),

              const SizedBox(height: AppSpacing.x8),
              AnimatedSwitcher(
                duration: motion.fade(Motion.fast),
                child: showServer && state.isSubmitting
                    ? const SubmittingButton()
                    : PrimaryButton(
                        label: 'Create Account',
                        onPressed: _submit,
                      ),
              ),

              const SizedBox(height: AppSpacing.x4),
              // Above "Sign in" rather than buried under it: this is the
              // sentence somebody is agreeing to by tapping the button just
              // above, so it belongs next to that button.
              const _LegalNotice(),

              const SizedBox(height: AppSpacing.x4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Already have an account?',
                    style: context.texts.bodyMedium?.copyWith(
                      color: context.surfaces.inkMuted,
                    ),
                  ),
                  TextButton(
                    // Pops rather than pushing sign-in: this screen was
                    // reached from there, so going back is the way back.
                    onPressed: state.isSubmitting
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    child: const Text('Sign in'),
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

/// What creating an account signs you up to.
///
/// Built from real widgets rather than one `Text.rich`: a tappable `TextSpan`
/// is invisible to a screen reader, which reads the whole sentence as plain
/// prose with no way into either document, and it cannot be given a hit target
/// of its own. A [Wrap] keeps the sentence flowing across lines.
///
/// Not a tick-box, either. A checkbox adds a step and makes nobody read
/// anything; the documents are one tap away either way.
class _LegalNotice extends StatelessWidget {
  const _LegalNotice();

  void _open(BuildContext context, LegalDocument document) {
    Navigator.of(
      context,
    ).push(AppPageRoute<void>(builder: (_) => LegalScreen(document: document)));
  }

  @override
  Widget build(BuildContext context) {
    final quiet = context.texts.bodySmall?.copyWith(
      color: context.surfaces.inkSoft,
    );

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('By creating an account you agree to our ', style: quiet),
        _LegalLink(
          label: 'Terms and Conditions',
          onTap: () => _open(context, LegalDocument.terms),
        ),
        Text(' and ', style: quiet),
        _LegalLink(
          label: 'Privacy Policy',
          onTap: () => _open(context, LegalDocument.privacy),
        ),
        Text('.', style: quiet),
      ],
    );
  }
}

class _LegalLink extends StatelessWidget {
  const _LegalLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Semantics(
      link: true,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          style: context.texts.bodySmall?.copyWith(
            color: accent,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: accent,
          ),
        ),
      ),
    );
  }
}
