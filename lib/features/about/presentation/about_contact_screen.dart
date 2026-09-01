import 'package:flutter/material.dart';
import '../../../core/animations/page_transitions.dart';
import '../../delivery/presentation/delivery_area_screen.dart';
import '../../contact/domain/contact_repository.dart';
import '../../hours/presentation/opening_hours_card.dart';
import '../../venue/domain/restaurant_location.dart';
import '../../venue/presentation/restaurant_map_card.dart';
import '../../auth/presentation/auth_form_parts.dart';
import '../../auth/auth_cubit.dart';
import '../../../core/network/api_failure.dart';
import '../../../core/haptics/app_haptics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/presentation/account_panel.dart';

import '../../../core/animations/reveal.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/app_sheet.dart';

/// Who the restaurant is, when it opens, and how to reach it.
///
/// Transcribed from "About & Contact Us" (`1:2727`), from the frame's
/// *metadata* only — the Figma MCP quota on this plan allows no more than a
/// call or two, so copy and geometry are the design's while every colour and
/// weight is this app's existing token, inferred rather than read off the
/// frame. Treat the styling as unverified.
///
/// From the frame: the "A Legacy of Flavor" hero, the Heritage & Vision bento
/// grid, and the "Get in Touch" contact section. The opening-hours table, map
/// panel and sign-out panel have no counterpart in it — hours and location sit
/// inside the frame's "Contact & Location Split", but as prose rather than the
/// structures used here, and signing out is an app necessity with no frame at
/// all.
class AboutContactScreen extends StatelessWidget {
  const AboutContactScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // As a tab root nothing is behind this screen, and
        // `automaticallyImplyLeading` adds nothing when the route cannot pop —
        // so no control appears here. Pushed instead, it gets either the
        // wired control below or the framework's BackButton. What it must
        // never show is a disabled arrow, which is what a null `onPressed`
        // handed straight to IconButton produces.
        leading: onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
                tooltip: 'Back',
              ),
        title: const Text('About & Contact'),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: AppSpacing.x8 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const _StoryHeader(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.x6),
                // "Hero Section: Our Story" in the frame. The heading and
                // paragraph are the design's own copy; what stood here before
                // was invented while the frame was unreadable.
                Text('A Legacy of Flavor', style: context.texts.headlineLarge),
                const SizedBox(height: AppSpacing.x3),
                Text(
                  'Born from a deep respect for heritage recipes, T\'s Cafe '
                  'bridges the vibrant, aromatic traditions of Sri Lanka with '
                  'the refined cafe culture of modern Britain. Every dish '
                  'tells a story of journey, family, and culinary passion.',
                  style: context.texts.bodyLarge,
                ),
                const SizedBox(height: AppSpacing.x8),

                // "Section - Bento Grid: Heritage & Vision".
                const _BentoGrid(),
                const SizedBox(height: AppSpacing.x8),

                // The real week from `/working-hours`, in place of four
                // hardcoded rows that said the restaurant shut at 22:30 on a
                // Thursday whatever the admin had actually set. Draws nothing
                // at all when no hours are configured, so the heading goes with
                // it rather than standing over an empty box.
                const OpeningHoursSection(),

                Text('Find Us', style: context.texts.headlineLarge),
                const SizedBox(height: AppSpacing.x3),
                // The real map, in place of the painted grid that said "Map to
                // be wired up".
                const RestaurantMapCard(),
                const SizedBox(height: AppSpacing.x3),
                // Beside the venue's own map, because "where are you" and "do
                // you deliver to me" are the same question asked twice.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const DeliveryAreaScreen(),
                      ),
                    ),
                    icon: const Icon(
                      Icons.local_shipping_outlined,
                      size: AppIconSize.md,
                    ),
                    label: const Text('See our delivery areas'),
                  ),
                ),
                const SizedBox(height: AppSpacing.x4),

                // The address is on the map card above; repeating it here was
                // the same street name maintained in two places.
                const _ContactRow(
                  icon: Icons.call_outlined,
                  label: 'Phone',
                  value: RestaurantLocation.phone,
                ),
                const SizedBox(height: AppSpacing.x3),
                const _ContactRow(
                  icon: Icons.mail_outline,
                  label: 'Email',
                  value: 'hello@tscafe.co.uk',
                ),
                const SizedBox(height: AppSpacing.x8),

                Text('Get in Touch', style: context.texts.headlineLarge),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  'We\'d love to hear from you. Whether it\'s a catering '
                  'inquiry or just to say hello.',
                  style: context.texts.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.x4),
                const _ContactForm(),
                const SizedBox(height: AppSpacing.x8),
                const AccountPanel(),
              ],
            ),
          ),
        ].revealStaggered(),
      ),
    );
  }
}

class _StoryHeader extends StatelessWidget {
  const _StoryHeader();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 220,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/welcome_hero.jpg', fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xD9000000), Color(0x40000000)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Heritage in Every Bite',
                  style: context.texts.displayLarge?.copyWith(
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppSpacing.x1),
                Text(
                  'British & Sri Lankan · Est. 2011',
                  style: context.texts.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Section - Bento Grid: Heritage & Vision" — three stacked cards: two with a
/// 48pt icon tile above a heading and a paragraph, and an image-led card in
/// between whose heading sits over the photograph.
///
/// Copy and geometry are the frame's. The photograph is not exported, so the
/// image card falls back to a tinted field, on the same reasoning as the dish
/// cards elsewhere in the app.
class _BentoGrid extends StatelessWidget {
  const _BentoGrid();

  @override
  Widget build(BuildContext context) {
    // Staggered individually. As one block the three cards landed together,
    // which reads as a single slab rather than three ideas.
    return Column(
      children: [
        const _BentoCard(
          icon: Icons.eco_outlined,
          title: 'Sustainable Sourcing',
          body:
              'We partner directly with farmers in Sri Lanka and local growers '
              'in the UK to ensure every ingredient is ethically sourced, '
              'supporting communities and ensuring unparalleled freshness.',
        ),
        const SizedBox(height: AppSpacing.x2),
        const _BentoCard(
          icon: Icons.diversity_3_outlined,
          title: 'Community First',
          body:
              'Beyond serving exceptional food, T\'s Cafe is designed as a '
              'gathering space—a hub for connection, conversation, and '
              'cultural exchange in the heart of the city.',
        ),
      ].revealStaggered(),
    );
  }
}

class _BentoCard extends StatelessWidget {
  const _BentoCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppSurface.panel(
      padding: const EdgeInsets.all(AppSpacing.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.crimson50,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, size: AppIconSize.xl, color: scheme.primary),
          ),
          const SizedBox(height: AppSpacing.x6),
          Text(title, style: context.texts.headlineMedium),
          const SizedBox(height: AppSpacing.x3),
          Text(body, style: context.texts.bodyMedium),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: context.surfaces.accentContainer,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: AppIconSize.lg, color: scheme.primary),
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: AppTypography.caption(context.surfaces.inkSoft),
              ),
              const SizedBox(height: 2),
              Text(value, style: context.texts.bodyLarge),
            ],
          ),
        ),
      ],
    );
  }
}

class _ContactForm extends StatefulWidget {
  const _ContactForm();

  @override
  State<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<_ContactForm> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _subject = TextEditingController();
  final _message = TextEditingController();

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Prefilled for a signed-in person, because asking someone for their own
    // name and email inside an app they are signed in to is a form they have
    // already filled in once. Editable, since a message can be about someone
    // else's booking.
    final user = context.read<AuthCubit>().state.user;
    if (user != null) {
      _name.text = user.displayName;
      _email.text = user.email;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  static String? _blankToNull(String value) =>
      value.trim().isEmpty ? null : value.trim();

  Future<void> _send() async {
    FocusScope.of(context).unfocus();

    // Checked here rather than server-side, so the user is told what is missing
    // before anything is sent.
    if (_name.text.trim().isEmpty || _message.text.trim().isEmpty) {
      AppHaptics.failure();
      showAppSnack(
        context,
        'Add your name and a message so we can reply.',
        isError: true,
      );
      return;
    }
    final emailError = AuthRules.email(_email.text);
    if (emailError != null) {
      AppHaptics.failure();
      showAppSnack(context, emailError, isError: true);
      return;
    }

    setState(() => _sending = true);
    try {
      await context.read<ContactRepository>().send(
        name: _name.text,
        email: _email.text,
        message: _message.text,
        // Null, not empty: absent is what the API means by a missing optional
        // field, and "" would be stored as a subject of nothing.
        phone: _blankToNull(_phone.text),
        subject: _blankToNull(_subject.text),
      );
      if (!mounted) return;

      AppHaptics.success();
      // Only the message is cleared. The name and email are almost certainly
      // right for a second message, and re-typing them is the annoyance that
      // stops people sending one.
      _message.clear();
      _subject.clear();
      setState(() => _sending = false);
      showAppSnack(context, 'Message sent — we usually reply within a day.');
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      AppHaptics.failure();
      setState(() => _sending = false);
      // The API's own words. Nothing here is cleared, so a failed send does not
      // cost the user their message.
      showAppSnack(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _name,
          enabled: !_sending,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Your name'),
        ),
        const SizedBox(height: AppSpacing.x3),
        TextField(
          controller: _email,
          enabled: !_sending,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'Email address'),
        ),
        const SizedBox(height: AppSpacing.x3),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _phone,
                enabled: !_sending,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(hintText: 'Phone (optional)'),
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: TextField(
                controller: _subject,
                enabled: !_sending,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Subject (optional)',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x3),
        TextField(
          controller: _message,
          enabled: !_sending,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'How can we help?'),
        ),
        const SizedBox(height: AppSpacing.x4),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? 'Sending…' : 'Send Message'),
        ),
      ],
    );
  }
}
