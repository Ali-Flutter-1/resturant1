import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/admin/domain/admin_menu_repository.dart';
import 'package:practice/features/admin/domain/admin_order_repository.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';
import 'package:practice/features/orders/domain/order_repository.dart';
import 'package:practice/features/menu/domain/menu_repository.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/about/presentation/about_contact_screen.dart';
import 'package:practice/features/admin/presentation/admin_dashboard_screen.dart';
import 'package:practice/features/admin/presentation/admin_menu_management_screen.dart';
import 'package:practice/features/admin/presentation/admin_orders_screen.dart';
import 'package:practice/features/admin/presentation/admin_reservations_screen.dart';
import 'package:practice/features/booking/presentation/book_table_screen.dart';
import 'package:practice/features/checkout/presentation/checkout_screen.dart';
import 'package:practice/features/discover/presentation/discover_screen.dart';
import 'package:practice/features/menu/presentation/dish_details_screen.dart';
import 'package:practice/features/menu/presentation/menu_screen.dart';
import 'package:practice/features/welcome/presentation/welcome_screen.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_admin_menu_repository.dart';
import 'support/fake_admin_order_repository.dart';
import 'support/fake_delivery_zone_repository.dart';
import 'support/fake_order_repository.dart';
import 'support/fake_menu_repository.dart';
import 'package:practice/features/booking/domain/reservation_repository.dart';
import 'support/fake_reservation_repository.dart';
import 'package:practice/features/admin/domain/dashboard_repository.dart';
import 'support/fake_dashboard_repository.dart';

/// Every screen, laid out in both themes at two viewport sizes.
///
/// `flutter build` only compiles — it never runs layout, so overflow and
/// unbounded-constraint errors survive a green build. These tests exist
/// because exactly that happened: `CrossAxisAlignment.stretch` inside a
/// ListView on Discover threw "BoxConstraints forces an infinite height" on
/// first launch, with analyze, tests and build all passing.
void main() {
  final screens = <String, Widget Function()>{
    'Welcome': () => const WelcomeScreen(),
    'Discover': () => const DiscoverScreen(),
    'Menu': () => const MenuScreen(),
    'DishDetails': () => const DishDetailsScreen(),
    'BookTable': () => const BookTableScreen(),
    'Checkout': () => const CheckoutScreen(),
    'AboutContact': () => const AboutContactScreen(),
    'AdminDashboard': () => const AdminDashboardScreen(),
    'AdminOrders': () => const AdminOrdersScreen(),
    'AdminReservations': () => const AdminReservationsScreen(),
    'AdminMenuManagement': () => const AdminMenuManagementScreen(),
  };

  // 390×844 is the design viewport; 320×640 is a small phone, where
  // overflow shows up first.
  const viewports = <String, Size>{
    'design 390x844': Size(390, 844),
    'small 320x640': Size(320, 640),
  };

  for (final entry in screens.entries) {
    group(entry.key, () {
      for (final theme in {
        'light': AppTheme.light,
        'dark': AppTheme.dark,
      }.entries) {
        for (final viewport in viewports.entries) {
          testWidgets('lays out — ${theme.key}, ${viewport.key}', (
            tester,
          ) async {
            tester.view.physicalSize = viewport.value;
            tester.view.devicePixelRatio = 1.0;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

            await tester.pumpWidget(
              // Screens that show session or basket state need their
              // cubits in scope.
              MultiBlocProvider(
                providers: [
                  BlocProvider(
                    create: (_) => AuthFixtures.cubit(AuthFixtures.customer),
                  ),
                  BlocProvider(create: (_) => CartCubit()),
                ],
                // Screens resolve their repositories from the tree, so the
                // layout tests supply both from memory.
                child: MultiRepositoryProvider(
                  providers: [
                    RepositoryProvider<MenuRepository>(
                      create: (_) => FakeMenuRepository(),
                    ),
                    RepositoryProvider<AdminMenuRepository>(
                      create: (_) => FakeAdminMenuRepository(),
                    ),
                    RepositoryProvider<AdminOrderRepository>(
                      create: (_) => FakeAdminOrderRepository(),
                    ),
                    RepositoryProvider<DashboardRepository>(
                      create: (_) => FakeDashboardRepository(),
                    ),
                    RepositoryProvider<ReservationRepository>(
                      create: (_) => FakeReservationRepository(),
                    ),
                    RepositoryProvider<OrderRepository>(
                      create: (_) => FakeOrderRepository(),
                    ),
                    RepositoryProvider<DeliveryZoneRepository>(
                      create: (_) => FakeDeliveryZoneRepository(),
                    ),
                  ],
                  child: MaterialApp(theme: theme.value, home: entry.value()),
                ),
              ),
            );

            // Let entrance animations run to completion — staggered reveals
            // change layout as they land.
            await tester.pump(const Duration(seconds: 2));

            expect(
              tester.takeException(),
              isNull,
              reason:
                  '${entry.key} threw during layout in '
                  '${theme.key} at ${viewport.key}',
            );
          });
        }
      }
    });
  }
}
