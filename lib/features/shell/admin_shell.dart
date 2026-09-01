import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/animations/page_transitions.dart';

import '../../shared/shell/tabbed_shell.dart';
import '../admin/presentation/admin_dashboard_screen.dart';
import '../admin/presentation/admin_menu_management_screen.dart';
import '../admin/presentation/admin_orders_screen.dart';
import '../admin/presentation/admin_reservations_screen.dart';
import '../admin/presentation/admin_contact_screen.dart';
import '../admin/presentation/admin_users_screen.dart';
import '../booking/presentation/admin_venue_screen.dart';
import '../delivery/presentation/admin_zones_screen.dart';
import '../hours/presentation/admin_working_hours_screen.dart';
import '../auth/auth_cubit.dart';
import '../auth/presentation/profile_screen.dart';
import '../notifications/domain/app_notification.dart';
import '../notifications/presentation/notification_routing.dart';

/// The staff-facing app, tabbed as the Figma dashboard labels it.
class AdminShell extends StatelessWidget {
  const AdminShell({super.key});

  @override
  Widget build(BuildContext context) {
    // Read once here rather than per tab: `canManageVenue` is what separates an
    // administrator from a staff member, and it was declared and never enforced
    // anywhere until now.
    final canManageVenue =
        context.select((AuthCubit c) => c.state.role?.canManageVenue) ?? false;

    return NotificationRouting(
      onFollow: (shell, payload) => _follow(shell, payload, canManageVenue),
      child: TabbedShell(
        tabs: [
          // Analytics is takings and trends — the owner's view of the business,
          // not the kitchen's. Staff work the queue; what the venue earned is not
          // theirs to see.
          if (canManageVenue)
            ShellTab(
              label: 'Analytics',
              sfSymbol: 'chart.bar.fill',
              icon: Icons.assessment_outlined,
              selectedIcon: Icons.assessment,
              builder: (context) => AdminDashboardScreen(
                // The dashboard adds no destinations of its own — it points at
                // tabs that already exist.
                onViewAll: () => TabbedShell.selectTab(context, 1),
                onViewBookings: () => TabbedShell.selectTab(context, 3),
                onViewMessages: () => Navigator.of(context).push(
                  AppPageRoute<void>(
                    builder: (_) => const AdminContactScreen(),
                  ),
                ),
              ),
            ),
          ShellTab(
            label: 'Orders',
            sfSymbol: 'list.bullet.rectangle.fill',
            icon: Icons.list_alt_outlined,
            selectedIcon: Icons.list_alt,
            builder: (context) => const AdminOrdersScreen(),
          ),
          // Managing the menu is `canManageVenue` work. A staff member reaching
          // this tab could open every control on it and be refused by the API on
          // each one — a screen you can enter and not use is worse than one that
          // isn't there.
          if (canManageVenue)
            ShellTab(
              label: 'Products',
              sfSymbol: 'shippingbox.fill',
              icon: Icons.inventory_2_outlined,
              selectedIcon: Icons.inventory_2,
              builder: (context) => const AdminMenuManagementScreen(),
            ),
          // Staff and admin had no way to reach their own account at all — no
          // profile, and sign-out was buried on the customers' About screen,
          // which this shell never shows.
          ShellTab(
            label: 'Reservations',
            sfSymbol: 'chair.fill',
            icon: Icons.chair_outlined,
            selectedIcon: Icons.chair,
            builder: (context) => const AdminReservationsScreen(),
          ),
          ShellTab(
            label: 'Profile',
            sfSymbol: 'person',
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            builder: (context) => ProfileScreen(
              // Admin only. The inbox lives under `/admin/contact`, which the
              // docs group with the administrator's routes rather than the
              // kitchen's.
              onOpenMessages: canManageVenue
                  ? () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const AdminContactScreen(),
                      ),
                    )
                  : null,
              // Also admin only: `/admin/users` is denied to staff, so offering
              // the row to them would be a door onto a 403.
              onManageUsers: canManageVenue
                  ? () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const AdminUsersScreen(),
                      ),
                    )
                  : null,
              // Admin only: creating tables and generating sittings are both
              // denied to staff.
              onManageVenue: canManageVenue
                  ? () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const AdminVenueScreen(),
                      ),
                    )
                  : null,
              // Admin only: zones set what every customer is charged, and
              // the endpoints are denied to staff.
              onDeliveryAreas: canManageVenue
                  ? () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const AdminZonesScreen(),
                      ),
                    )
                  : null,
              // Admin only: the working-hours PUT is denied to staff.
              onOpeningHours: canManageVenue
                  ? () => Navigator.of(context).push(
                      AppPageRoute<void>(
                        builder: (_) => const AdminWorkingHoursScreen(),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  /// Where a staff notification goes.
  ///
  /// Tab indices shift with the role — a staff member has no Analytics or
  /// Products tab — so the shell works them out rather than hardcoding numbers
  /// the notifications feature could not know.
  static void _follow(
    BuildContext context,
    NotificationPayload payload,
    bool canManageVenue,
  ) {
    final orders = canManageVenue ? 1 : 0;
    final reservations = canManageVenue ? 3 : 1;

    switch (payload.target) {
      case NotificationTarget.adminOrder:
        Navigator.of(context).popUntil((route) => route.isFirst);
        TabbedShell.selectTab(context, orders);
      case NotificationTarget.adminBooking:
        Navigator.of(context).popUntil((route) => route.isFirst);
        TabbedShell.selectTab(context, reservations);
      // A customer-addressed notification reaching this shell means a role
      // changed under them. The inbox is the honest place to stop.
      case NotificationTarget.customerOrder:
      case NotificationTarget.customerBooking:
      case NotificationTarget.inbox:
        break;
    }
  }
}
