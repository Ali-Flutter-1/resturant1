import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/page_body.dart';
import '../../venue/domain/restaurant_location.dart';

/// Which document a [LegalScreen] is showing.
enum LegalDocument {
  privacy('Privacy policy'),
  terms('Terms and conditions');

  const LegalDocument(this.title);

  final String title;
}

/// The privacy policy and the terms, as plain reading.
///
/// Held in the app rather than opened on a website on purpose: these have to be
/// readable at the moment somebody is deciding whether to sign up, including on
/// a bad connection, and a link that fails to load at that moment is worse than
/// no link at all.
///
/// **The text below describes what this app actually does** -- the account it
/// creates, the order and booking data it sends, the token it stores, the
/// notification registration -- and nothing it does not. It is written to be
/// accurate rather than to be exhaustive, and it is not legal advice: before
/// launch it should be read by whoever is responsible for the business, and
/// checked against UK GDPR and the Consumer Contracts Regulations. Anything
/// added to the app later that collects or shares data needs a line here too.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(document.title)),
      body: ListView(
        padding: pagePadding(
          context,
          top: AppSpacing.x4,
          bottom: AppSpacing.x8 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text(
            'Last updated 24 August 2026',
            style: context.texts.bodySmall?.copyWith(
              color: context.surfaces.inkSoft,
            ),
          ),
          const SizedBox(height: AppSpacing.x5),
          for (final section in switch (document) {
            LegalDocument.privacy => _privacy,
            LegalDocument.terms => _terms,
          }) ...[
            Text(section.heading, style: context.texts.titleMedium),
            const SizedBox(height: AppSpacing.x2),
            Text(
              section.body,
              style: context.texts.bodyMedium?.copyWith(
                color: context.surfaces.inkMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.x5),
          ],
        ],
      ),
    );
  }
}

class _Section {
  const _Section(this.heading, this.body);

  final String heading;
  final String body;
}

const _contact =
    '${RestaurantLocation.name}, ${RestaurantLocation.addressLine}, '
    '${RestaurantLocation.city} ${RestaurantLocation.postcode}, '
    'or ring ${RestaurantLocation.phone}.';

const List<_Section> _privacy = [
  _Section(
    'What we collect',
    'When you create an account we keep your name, email address and the '
        'password you choose, which is stored scrambled and cannot be read '
        'back by anyone, including us.\n\n'
        'When you order we keep what you ordered, what it cost, the phone '
        'number and name you give for the order, and — for delivery — the '
        'address and any note you add for the driver. When you book a table we '
        'keep the date, time, party size and the contact details you give.',
  ),
  _Section(
    'What we do not collect',
    'We do not track your location. The map on the contact page shows where '
        'the restaurant is; tapping Directions hands the restaurant\'s '
        'coordinates to your phone\'s own maps app, which works out the route '
        'itself. We never see where you are.\n\n'
        'We never see your card details. Card payments happen on Worldpay\'s '
        'own secure page. Your card number does not pass through this app or '
        'our systems at any point.',
  ),
  _Section(
    'Staying signed in',
    'Signing in stores a token on your phone, in the keychain your phone '
        'provides for exactly this. It is what keeps you signed in between '
        'visits. Signing out removes it, along with your basket and your '
        'notifications, so the next person to use the phone starts clean.',
  ),
  _Section(
    'Notifications',
    'If you allow notifications, your phone gives us an anonymous delivery '
        'address so we can tell you when your order is accepted, ready or on '
        'its way. It identifies the app on this device, not you, and it is '
        'removed when you sign out. You can turn notifications off in your '
        'phone\'s settings at any time and everything else keeps working.',
  ),
  _Section(
    'Who else sees it',
    'Restaurant staff see your order or booking and the contact details on '
        'it, because that is how the food reaches you. Worldpay processes card '
        'payments. Google and Apple carry notifications to your phone. Nobody '
        'else. We do not sell your data or use it for advertising.',
  ),
  _Section(
    'How long we keep it',
    'Order and booking records are kept while they are needed for the '
        'business — to answer questions, handle refunds, and meet the tax and '
        'accounting rules we are subject to. Your account stays until you '
        'close it.',
  ),
  _Section(
    'Your rights',
    'You can ask for a copy of what we hold, ask for it to be corrected, or '
        'ask us to delete your account and the data with it. You can close '
        'your account yourself from Profile. To ask for anything else, write '
        'to $_contact\n\n'
        'If you think we have handled your data badly you can complain to the '
        'Information Commissioner\'s Office at ico.org.uk.',
  ),
];

const List<_Section> _terms = [
  _Section('Who we are', 'This app is operated by $_contact'),
  _Section(
    'Your account',
    'You need an account to order or book. Keep your password to yourself — '
        'anything done through your account is treated as done by you. Tell us '
        'straight away if you think someone else has got into it.',
  ),
  _Section(
    'Orders',
    'Prices are set by the restaurant and are shown in the app before you '
        'order; the total you are shown at checkout is the total you pay. An '
        'order is not accepted until the restaurant accepts it, and they may '
        'refuse one — if the kitchen is closing, an ingredient has run out, or '
        'the delivery address is out of range. If a card payment has already '
        'been taken for a refused order, it is refunded.\n\n'
        'You can cancel an order yourself while it is still waiting to be '
        'accepted. Once the kitchen has started cooking, food and time have '
        'been spent, so cancelling is a conversation — ring the restaurant and '
        'they will do what they can.',
  ),
  _Section(
    'Paying',
    'You can pay with cash on collection or delivery, or by card in the app. '
        'Card payments are handled by Worldpay on their own page; we never see '
        'your card details. A card order is not sent to the kitchen until the '
        'payment clears, so an unpaid order is not yet an order.',
  ),
  _Section(
    'Table bookings',
    'A booking is a request until the restaurant confirms it. Tables are held '
        'for a short while past the booked time and may be released after '
        'that. Please tell us if your plans change so the table can go to '
        'somebody else.',
  ),
  _Section(
    'Allergies and dietary needs',
    'Dish descriptions and any spice level are a guide, not a guarantee. Our '
        'kitchen handles nuts, dairy, gluten, shellfish and other allergens, '
        'and we cannot promise any dish is free of them. If you have an '
        'allergy, ring the restaurant before ordering rather than relying on '
        'the app.',
  ),
  _Section(
    'When the app is not working',
    'We keep the app running as well as we can, but we cannot promise it is '
        'always available or always right. If something has gone wrong with an '
        'order, tell the restaurant — nothing in these terms takes away the '
        'rights you have under consumer law.',
  ),
  _Section(
    'Changes',
    'We may change these terms as the app changes. The date at the top says '
        'when they were last updated, and continuing to use the app means the '
        'current version applies.',
  ),
];
