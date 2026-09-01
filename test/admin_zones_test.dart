import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/delivery/domain/delivery_zone.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';
import 'package:practice/features/delivery/presentation/admin_zones_cubit.dart';
import 'package:practice/features/delivery/presentation/admin_zones_screen.dart';
import 'package:practice/features/delivery/presentation/zone_editor_screen.dart';

import 'support/fake_admin_delivery_zone_repository.dart';

/// Managing delivery areas.
///
/// What an admin sets here is what every customer is quoted, so the rules
/// pinned below are about not charging somebody the wrong amount: prices are
/// integer pence, a half-drawn shape is never sent, and destructive actions ask
/// first.
void main() {
  late FakeAdminDeliveryZoneRepository repository;

  setUp(() {
    repository = FakeAdminDeliveryZoneRepository();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 2200);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  Widget wrap(Widget child) =>
      RepositoryProvider<AdminDeliveryZoneRepository>.value(
        value: repository,
        child: MaterialApp(theme: AppTheme.light, home: child),
      );

  group('the list', () {
    testWidgets('shows every area, live and paused', (tester) async {
      repository.stored = [
        FakeAdminDeliveryZoneRepository.seeded,
        const AdminDeliveryZone(
          zone: DeliveryZone(
            id: 'zone-2',
            name: 'Zone 2',
            polygon: [
              ZonePoint(lat: 58.7, lng: -3.7),
              ZonePoint(lat: 58.7, lng: -3.3),
              ZonePoint(lat: 58.4, lng: -3.3),
            ],
            minOrderPence: 3500,
            deliveryFeePence: 950,
            priority: 2,
          ),
          isActive: false,
        ),
      ];

      await tester.pumpWidget(wrap(const AdminZonesScreen()));
      await tester.pumpAndSettle();

      // The public list hides paused areas; this one must not, or an admin
      // cannot turn one back on. Zone 1 appears twice -- once in the map's
      // legend and once as a row -- while the paused Zone 2 is a row only.
      expect(find.text('Zone 1'), findsNWidgets(2));
      expect(find.text('Zone 2'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Min £30.00 · Fee £4.00 · Priority 1'), findsOneWidget);

      // Only the live one is drawn: the map is the customer's picture.
      expect(
        tester.widget<PolygonLayer>(find.byType(PolygonLayer)).polygons,
        hasLength(1),
      );
    });

    testWidgets('every area paused is called out, not left to be noticed', (
      tester,
    ) async {
      repository.stored = [
        const AdminDeliveryZone(
          zone: DeliveryZone(
            id: 'z',
            name: 'Zone 1',
            polygon: [],
            minOrderPence: 3000,
            deliveryFeePence: 400,
            priority: 1,
          ),
          isActive: false,
        ),
      ];

      await tester.pumpWidget(wrap(const AdminZonesScreen()));
      await tester.pumpAndSettle();

      // With nothing active the backend falls back to flat pricing and stops
      // checking postcodes — orders keep coming through at a price nobody on
      // this screen set, which is worth saying out loud.
      expect(
        find.textContaining('fallen back to the flat rate'),
        findsOneWidget,
      );
    });

    testWidgets('deleting asks first and says what it costs', (tester) async {
      await tester.pumpWidget(wrap(const AdminZonesScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete area'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot be recovered'), findsOneWidget);
      // Pausing is the reversible alternative, and the sheet points at it.
      expect(find.textContaining('turn it off instead'), findsOneWidget);

      await tester.tap(find.text('Keep the area'));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 0);
      // Still one row: nothing was removed.
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });
  });

  group('the cubit', () {
    test('pausing keeps the area and its prices', () async {
      final cubit = AdminZonesCubit(repository: repository);
      await cubit.load();

      expect(await cubit.setActive('zone-1', false), isNull);

      final zone = cubit.state.zones.single;
      expect(zone.isActive, isFalse);
      // Paused, not emptied: turning it back on must restore the same prices.
      expect(zone.zone.minOrderPence, 3000);
      expect(repository.lastUpdate?['is_active'], false);
      // Only what changed goes in the PATCH.
      expect(repository.lastUpdate?['polygon'], isNull);
      await cubit.close();
    });

    test('a failed refresh keeps the prices on screen', () async {
      final cubit = AdminZonesCubit(repository: repository);
      await cubit.load();

      repository.failure = ApiFailure.offline;
      await cubit.load(silent: true);

      // Blanking them would read as "there are no areas", which is a very
      // different thing for an admin to believe.
      expect(cubit.state.zones, hasLength(1));
      expect(cubit.state.status, AdminZonesStatus.ready);
      await cubit.close();
    });
  });

  group('the editor', () {
    testWidgets('a shape with too few corners is never sent', (tester) async {
      await tester.pumpWidget(wrap(const ZoneEditorScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Zone 1'),
        'Zone 4',
      );
      await tester.enterText(find.widgetWithText(TextField, '30.00'), '25.00');
      await tester.enterText(find.widgetWithText(TextField, '4.00'), '3.50');
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Create area'));
      await tester.tap(find.text('Create area'));
      await tester.pumpAndSettle();

      // Two points cannot enclose anything. Sending it would have the server
      // refuse, and a half-drawn area must never price an order.
      expect(find.textContaining('at least 3 corners'), findsOneWidget);
      expect(repository.lastCreate, isNull);
    });

    testWidgets('prices are sent as integer pence, rounded', (tester) async {
      await tester.pumpWidget(wrap(const ZoneEditorScreen()));
      await tester.pumpAndSettle();

      // Three taps on the map, which is how a corner is placed.
      final map = find.byType(FlutterMap);
      await tester.tapAt(tester.getCenter(map) + const Offset(-40, -40));
      await tester.tapAt(tester.getCenter(map) + const Offset(40, -40));
      await tester.tapAt(tester.getCenter(map) + const Offset(0, 40));
      await tester.pumpAndSettle();

      expect(find.text('3 corners'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Zone 1'),
        'Zone 4',
      );
      await tester.enterText(find.widgetWithText(TextField, '30.00'), '25.50');
      await tester.enterText(find.widgetWithText(TextField, '4.00'), '3.50');
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Create area'));
      await tester.tap(find.text('Create area'));
      await tester.pumpAndSettle();

      // 25.50 in binary floating point is 2549.9999…, and truncating would set
      // the minimum a penny low on every order in this area.
      expect(repository.lastCreate?['min_order_pence'], 2550);
      expect(repository.lastCreate?['delivery_fee_pence'], 350);
      expect(repository.lastCreate?['points'], 3);
      expect(repository.lastCreate?['name'], 'Zone 4');
    });
  });
}
