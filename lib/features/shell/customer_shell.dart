import 'package:flutter/material.dart';
import '../orders/presentation/orders_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/animations/page_transitions.dart';
import '../../core/theme/app_spacing.dart';

import '../menu/domain/dish.dart';
import '../notifications/domain/app_notification.dart';
import '../notifications/presentation/notification_routing.dart';
import '../../shared/shell/tabbed_shell.dart';
import '../about/presentation/about_contact_screen.dart';
import '../auth/auth_cubit.dart';
import '../auth/presentation/profile_screen.dart';
import '../auth/presentation/require_sign_in.dart';
import '../booking/presentation/book_table_screen.dart';
import '../booking/presentation/my_bookings_screen.dart';
import '../checkout/presentation/checkout_screen.dart';
import '../discover/presentation/discover_screen.dart';
import '../menu/presentation/dish_details_screen.dart';
import '../menu/presentation/menu_screen.dart';
import '../orders/presentation/my_orders_screen.dart';

/// The customer-facing app.
///
/// Detail screens push into the *tab's* navigator — `Navigator.of(context)`
/// inside a tab resolves to that tab's nested navigator, which is exactly
/// what keeps the pushed route from covering the tab bar.
class CustomerShell extends StatelessWidget {
  const CustomerShell({super.key});

  static void _openDish(BuildContext context, Dish dish) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (context) => DishDetailsScreen(
          dish: dish,
          onBack: () => Navigator.of(context).pop(),
          // Adding no longer jumps to checkout — the item flies into the
          // cart and the user stays put, which is the point of the
          // animation. Checkout is reached from the cart icon.
          onOpenCart: () => _openCheckout(context),
        ),
      ),
    );
  }

  static void _openMenu(
    BuildContext context, {
    String? query,
    String? categorySlug,
  }) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (context) => MenuScreen(
          initialQuery: query,
          initialCategorySlug: categorySlug,
          onOpenDish: (dish) => _openDish(context, dish),
        ),
      ),
    );
  }

  /// What a tapped notification does.
  ///
  /// A push carries an id, not state — so each of these lands on a screen that
  /// fetches the record itself. The shell is where this lives because it owns
  /// the tabs; the inbox only validates the payload and hands it over.
  static void followNotification(
    BuildContext context,
    NotificationPayload payload,
  ) {
    switch (payload.target) {
      case NotificationTarget.customerOrder:
        Navigator.of(context).popUntil((route) => route.isFirst);
        TabbedShell.selectTab(context, 2);
      case NotificationTarget.customerBooking:
        _openMyBookings(context);
      // A customer has no admin screens, and a staff notification reaching this
      // shell means a role changed under them. The inbox is the honest place to
      // leave them rather than a screen the API would refuse.
      case NotificationTarget.adminOrder:
      case NotificationTarget.adminBooking:
      case NotificationTarget.inbox:
        break;
    }
  }

  static void _openMyBookings(BuildContext context) {
    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (context) => MyBookingsScreen(
          onBack: () => Navigator.of(context).pop(),
          // From the empty state: popping lands back on the Book tab's root,
          // which is the form itself.
          onBookTable: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// Opens checkout, asking for an account first if there is not one.
  ///
  /// The basket is filled by a guest quite happily -- it lives in the app, not
  /// on the server. This is the point where the order becomes somebody's, so
  /// this is where the account is asked for, and the basket survives the
  /// detour: `requireSignIn` returns and checkout opens with everything still
  /// in it.
  static Future<void> _openCheckout(BuildContext context) async {
    if (!await requireSignIn(context, toContinue: 'to place your order')) {
      return;
    }
    if (!context.mounted) return;

    Navigator.of(context).push(
      AppPageRoute<void>(
        builder: (context) => CheckoutScreen(
          onBack: () => Navigator.of(context).pop(),
          // Back to the tab root, then over to Orders: the order now exists, and
          // the tracker is where the customer wants to be looking at it.
          onPlaceOrder: (_) {
            // Told, not left to notice. The Orders tab is kept alive by the
            // shell, so if the customer had already looked at it -- which a
            // first-time customer usually has, finding it empty -- its list is
            // still the one from before they ordered.
            context.read<OrdersCubit>().load(silent: true);
            Navigator.of(context).popUntil((r) => r.isFirst);
            TabbedShell.selectTab(context, 2);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationRouting(
      onFollow: followNotification,
      child: TabbedShell(
        tabs: [
          ShellTab(
            label: 'Menu',
            sfSymbol: 'fork.knife',
            icon: Icons.restaurant_outlined,
            selectedIcon: Icons.restaurant,
            builder: (context) => DiscoverScreen(
              onOpenDish: (dish) => _openDish(context, dish),
              onOpenMenu: () => _openMenu(context),
              // Search and the filter button both open the full menu, which is
              // where filtering actually lives.
              onSearch: (query) => _openMenu(context, query: query),
              // A category circle opens the menu already filtered to it, rather
              // than only highlighting itself as it used to.
              onOpenCategory: (slug) => _openMenu(context, categorySlug: slug),
            ),
          ),
          ShellTab(
            label: 'Book',
            sfSymbol: 'calendar',
            icon: Icons.calendar_month_outlined,
            selectedIcon: Icons.calendar_month,
            // Gated whole, unlike the menu: the availability endpoint itself
            // needs a session, so a guest would meet an empty slot list and a
            // 401 rather than a form they could fill in. The submit path asks
            // again anyway, for a session that expires while the form is open.
            builder: (context) => _GuestGate(
              icon: Icons.calendar_month_outlined,
              title: 'Book a table',
              body:
                  'Sign in to see what is free and reserve a table. It takes '
                  'a moment.',
              toContinue: 'to book a table',
              child: BookTableScreen(
                onSeeBookings: () => _openMyBookings(context),
              ),
            ),
          ),
          ShellTab(
            label: 'Orders',
            sfSymbol: 'list.bullet.rectangle',
            icon: Icons.list_alt_outlined,
            selectedIcon: Icons.list_alt,
            builder: (context) => _GuestGate(
              icon: Icons.receipt_long_outlined,
              title: 'Your orders live here',
              body:
                  'Sign in to follow an order and to see everything you have '
                  'ordered before.',
              toContinue: 'to see your orders',
              child: MyOrdersScreen(
                onOpenCheckout: () => _openCheckout(context),
                // An empty history is a dead end otherwise. The menu is the
                // Discover tab's root, so this asks the shell to switch tabs
                // rather than pushing a second copy of it onto this one.
                onBrowseMenu: () => TabbedShell.selectTab(context, 0),
              ),
            ),
          ),
          ShellTab(
            label: 'Profile',
            sfSymbol: 'person',
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            builder: (context) => _GuestGate(
              icon: Icons.person_outline,
              title: 'Your account',
              body:
                  'Sign in to keep your details for next time, follow your '
                  'orders and manage your bookings.',
              toContinue: 'to open your account',
              // A guest can still reach the restaurant without an account --
              // the address, the hours and the contact form are public, and
              // hiding them behind a sign-in would be absurd.
              extra: TextButton(
                onPressed: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => const AboutContactScreen(),
                  ),
                ),
                child: const Text('About & contact'),
              ),
              child: ProfileScreen(
                // About-and-contact is pushed rather than being the tab itself:
                // the tab is the person's account, and the contact form is one
                // thing they might want from it.
                onGetInTouch: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => const AboutContactScreen(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [child] to somebody signed in, and an invitation to everybody else.
///
/// Whole tabs rather than individual buttons, because these two are *entirely*
/// account-shaped: an order history and an account page have nothing to show a
/// guest, and their screens would ask the API questions it answers with a 401.
///
/// Rebuilt on the session, so signing in from anywhere -- here, or from the
/// checkout gate -- swaps the real screen in immediately.
class _GuestGate extends StatelessWidget {
  const _GuestGate({
    required this.icon,
    required this.title,
    required this.body,
    required this.toContinue,
    required this.child,
    this.extra,
  });

  final IconData icon;
  final String title;
  final String body;
  final String toContinue;
  final Widget child;

  /// Anything still worth offering without an account.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select((AuthCubit c) => c.state.isSignedIn);
    if (signedIn) return child;

    return Scaffold(
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: SignedOutPanel(
              icon: icon,
              title: title,
              body: body,
              toContinue: toContinue,
            ),
          ),
          ?extra,
          const SizedBox(height: AppSpacing.x8),
        ],
      ),
    );
  }
}
