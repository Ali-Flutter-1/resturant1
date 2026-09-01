import 'package:flutter/material.dart';
import '../orders/presentation/orders_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/animations/page_transitions.dart';

import '../menu/domain/dish.dart';
import '../notifications/domain/app_notification.dart';
import '../notifications/presentation/notification_routing.dart';
import '../../shared/shell/tabbed_shell.dart';
import '../about/presentation/about_contact_screen.dart';
import '../auth/presentation/profile_screen.dart';
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

  static void _openCheckout(BuildContext context) {
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
            builder: (context) =>
                BookTableScreen(onSeeBookings: () => _openMyBookings(context)),
          ),
          ShellTab(
            label: 'Orders',
            sfSymbol: 'list.bullet.rectangle',
            icon: Icons.list_alt_outlined,
            selectedIcon: Icons.list_alt,
            builder: (context) => MyOrdersScreen(
              onOpenCheckout: () => _openCheckout(context),
              // An empty history is a dead end otherwise. The menu is the
              // Discover tab's root, so this asks the shell to switch tabs
              // rather than pushing a second copy of it onto this one.
              onBrowseMenu: () => TabbedShell.selectTab(context, 0),
            ),
          ),
          ShellTab(
            label: 'Profile',
            sfSymbol: 'person',
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            builder: (context) => ProfileScreen(
              // About-and-contact is pushed rather than being the tab itself: the
              // tab is the person's account, and the contact form is one thing
              // they might want from it.
              onGetInTouch: () => Navigator.of(context).push(
                AppPageRoute<void>(builder: (_) => const AboutContactScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
