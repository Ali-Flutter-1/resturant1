import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/animations/page_transitions.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/about/presentation/about_contact_screen.dart';
import 'package:practice/features/booking/presentation/book_table_screen.dart';
import 'package:practice/features/auth/auth_cubit.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/checkout/presentation/checkout_screen.dart';
import 'package:practice/features/discover/presentation/discover_screen.dart';
import 'package:practice/features/menu/presentation/dish_details_screen.dart';
import 'package:practice/features/admin/domain/admin_menu_repository.dart';
import 'package:practice/features/admin/domain/admin_order_repository.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';
import 'package:practice/features/orders/domain/order_repository.dart';
import 'package:practice/features/menu/domain/menu_repository.dart';
import 'package:practice/features/menu/presentation/menu_screen.dart';
import 'package:practice/features/shell/admin_shell.dart';
import 'package:practice/features/shell/customer_shell.dart';
import 'package:practice/shared/widgets/app_nav_bar.dart';

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

/// Every screen needs a way out, and no screen may advertise one it doesn't
/// have. These tests pin both halves of that, because both have been wrong:
/// two tab roots shipped a permanently disabled back arrow, and the pushed
/// menu shipped with no back control at all.
Widget _host(Widget home, {TargetPlatform? platform}) {
  final theme = platform == null
      ? AppTheme.light
      : AppTheme.light.copyWith(platform: platform);
  return MultiBlocProvider(
    providers: [
      BlocProvider(create: (_) => AuthFixtures.cubit(AuthFixtures.customer)),
      BlocProvider(create: (_) => CartCubit()),
    ],
    // Screens resolve their repositories from the tree; these tests care about
    // navigation, not about what the menu contains.
    child: MultiRepositoryProvider(
      providers: [
        RepositoryProvider<MenuRepository>(create: (_) => FakeMenuRepository()),
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
      child: MaterialApp(theme: theme, home: home),
    ),
  );
}

/// Pumps [screen] as a pushed route and returns once it has settled.
Future<void> _push(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(AppPageRoute<void>(builder: (_) => screen)),
          child: const Text('origin'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('origin'));
  await tester.pumpAndSettle();
}

/// Finds a tab by name.
///
/// Not by its visible text: the bar shows a label only on the selected tab, so
/// the name of every other one lives in its [Semantics] and nowhere else.
Finder navTab(String label) => find.descendant(
  of: find.byType(AppNavBar),
  matching: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == label,
  ),
);

void main() {
  group('tab roots', () {
    // Nothing sits behind a tab root, so a back control there could only ever
    // be inert.
    final roots = <String, Widget>{
      'Discover': const DiscoverScreen(),
      'BookTable': const BookTableScreen(),
      'AboutContact': const AboutContactScreen(),
    };

    for (final entry in roots.entries) {
      testWidgets('${entry.key} shows no back control', (tester) async {
        await tester.pumpWidget(_host(entry.value));
        await tester.pump(const Duration(seconds: 2));

        expect(
          find.byIcon(Icons.arrow_back),
          findsNothing,
          reason: '${entry.key} is a tab root and must not offer a way back',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('pushed screens', () {
    testWidgets('Menu offers a back control that pops', (tester) async {
      await _push(tester, const MenuScreen());

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('origin'), findsOneWidget);
    });

    testWidgets('DishDetails offers a back control that fires onBack', (
      tester,
    ) async {
      var backs = 0;
      await _push(tester, DishDetailsScreen(onBack: () => backs++));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(backs, 1);
    });

    testWidgets('Checkout offers a back control that fires onBack', (
      tester,
    ) async {
      var backs = 0;
      await _push(tester, CheckoutScreen(onBack: () => backs++));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(backs, 1);
    });
  });

  group('no screen ever shows a disabled back control', () {
    // The failure this guards against is subtle on screen but total in
    // effect: IconButton renders a greyed arrow for a null callback, so the
    // app appears to offer a way back and simply ignores the tap.
    final screens = <String, Widget>{
      'Discover': const DiscoverScreen(),
      'BookTable': const BookTableScreen(),
      'AboutContact': const AboutContactScreen(),
      'Menu': const MenuScreen(),
      'DishDetails': const DishDetailsScreen(),
      'Checkout': const CheckoutScreen(),
    };

    for (final entry in screens.entries) {
      testWidgets('${entry.key}, unwired', (tester) async {
        await tester.pumpWidget(_host(entry.value));
        await tester.pump(const Duration(seconds: 2));

        for (final button in tester.widgetList<IconButton>(
          find.byType(IconButton),
        )) {
          expect(
            button.onPressed,
            isNotNull,
            reason: '${entry.key} renders an IconButton that does nothing',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('pushed without onBack', () {
    // These screens are always wired by CustomerShell today. Should that ever
    // lapse, the framework's implied BackButton must still get the user out.
    final screens = <String, Widget>{
      'DishDetails': const DishDetailsScreen(),
      'Checkout': const CheckoutScreen(),
    };

    for (final entry in screens.entries) {
      testWidgets('${entry.key} still pops', (tester) async {
        await _push(tester, entry.value);
        await tester.pumpAndSettle();

        expect(find.byType(BackButton), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('origin'), findsOneWidget);
      });
    }
  });

  group('platform back gesture', () {
    testWidgets('an edge swipe pops on iOS', (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(AppPageRoute<void>(builder: (_) => const Text('detail'))),
              child: const Text('origin'),
            ),
          ),
          platform: TargetPlatform.iOS,
        ),
      );

      await tester.tap(find.text('origin'));
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);

      // Drag in from the left edge. This only works while the theme routes
      // Apple platforms through CupertinoPageTransitionsBuilder — the gesture
      // detector lives inside it, so substituting another transition silently
      // removes the gesture.
      await tester.dragFrom(const Offset(2, 300), const Offset(500, 0));
      await tester.pumpAndSettle();

      expect(find.text('detail'), findsNothing);
      expect(find.text('origin'), findsOneWidget);
    });
  });

  group('controls clear of the tab bar', () {
    testWidgets('the admin add-dish button is not hidden behind the bar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => AuthFixtures.cubit(AuthFixtures.admin)),
            BlocProvider(create: (_) => CartCubit()),
          ],
          // The Products tab reads the admin menu from the tree.
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
            child: MaterialApp(theme: AppTheme.light, home: const AdminShell()),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(navTab('Products'));
      await tester.pump(const Duration(seconds: 2));

      final fab = tester.getRect(find.byType(FloatingActionButton));
      final bar = tester.getRect(find.byType(AppNavBar));

      // The bar paints over the tab's content, so any overlap at all means the
      // button is invisible — and untappable — rather than merely cramped.
      expect(
        fab.bottom,
        lessThanOrEqualTo(bar.top),
        reason:
            'the add-dish FAB ($fab) is behind the tab bar ($bar); Scaffold '
            'anchors it to its own bottom edge, so it needs lifting by the '
            "shell's reported bottom padding",
      );

      // And it still works.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Add a dish'), findsOneWidget);
    });
  });

  group('what each role may reach', () {
    Widget shellFor(AuthUser user) => MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AuthCubit(initialUser: user)),
        BlocProvider(create: (_) => CartCubit()),
      ],
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
        child: MaterialApp(theme: AppTheme.light, home: const AdminShell()),
      ),
    );

    testWidgets('an admin gets every tab', (tester) async {
      await tester.pumpWidget(shellFor(AuthFixtures.admin));
      await tester.pump(const Duration(seconds: 2));

      expect(navTab('Analytics'), findsOneWidget);
      expect(navTab('Orders'), findsOneWidget);
      expect(navTab('Products'), findsOneWidget);
      expect(navTab('Reservations'), findsOneWidget);
      expect(navTab('Profile'), findsOneWidget);
    });

    testWidgets('staff get neither analytics nor the menu', (tester) async {
      await tester.pumpWidget(shellFor(AuthFixtures.staff));
      await tester.pump(const Duration(seconds: 2));

      // Takings are the owner's view of the business, and managing the menu is
      // `canManageVenue` work — a staff member could open every control on that
      // screen and be refused by the API on each one.
      expect(navTab('Analytics'), findsNothing);
      expect(navTab('Products'), findsNothing);

      // What they do need is untouched.
      expect(navTab('Orders'), findsOneWidget);
      expect(navTab('Reservations'), findsOneWidget);
      expect(navTab('Profile'), findsOneWidget);
    });

    testWidgets('an admin is offered the contact inbox', (tester) async {
      await tester.pumpWidget(shellFor(AuthFixtures.admin));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(navTab('Profile'));
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Messages'), findsOneWidget);
    });

    testWidgets('staff are not', (tester) async {
      // A separate test rather than a second `pumpWidget`: re-pumping the same
      // widget type reuses the element, so the BlocProvider keeps the first
      // role and the assertion passes for the wrong reason.
      await tester.pumpWidget(shellFor(AuthFixtures.staff));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(navTab('Profile'));
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Messages'), findsNothing);
    });
  });

  group('what a role may reach in the customer shell', () {
    testWidgets('an admin never lands in the customer shell', (tester) async {
      // Role decides the whole shape of the app, and staff sharing the admin
      // shell is deliberate -- a waiter with the customer tab bar could not
      // work the queue at all.
      for (final (user, adminShell) in [
        (AuthFixtures.admin, true),
        (AuthFixtures.staff, true),
        (AuthFixtures.customer, false),
      ]) {
        expect(user.role.usesAdminShell, adminShell, reason: user.role.name);
      }
    });

    testWidgets('the customer tabs are the five a customer needs', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const CustomerShell()));
      await tester.pump(const Duration(seconds: 2));

      for (final label in ['Menu', 'Book', 'Orders', 'Profile']) {
        expect(navTab(label), findsOneWidget, reason: label);
      }
      // ...and none of the staff ones, whatever the API would allow.
      for (final label in ['Analytics', 'Products', 'Reservations']) {
        expect(navTab(label), findsNothing, reason: label);
      }
    });
  });
}
