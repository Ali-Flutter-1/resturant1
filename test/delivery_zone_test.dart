import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/delivery/presentation/delivery_zones_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/checkout/presentation/checkout_cubit.dart';
import 'package:practice/features/delivery/domain/delivery_zone.dart';
import 'package:practice/features/menu/domain/dish.dart';

import 'support/fake_delivery_zone_repository.dart';
import 'support/fake_order_repository.dart';

/// Zone-based delivery.
///
/// The rule underneath all of it: **the app never decides what delivery
/// costs**. The fee and the minimum belong to the zone the postcode falls in,
/// the admin can change either without a release, and an address outside every
/// zone cannot have a delivery order at all.
void main() {
  late FakeOrderRepository orders;
  late FakeDeliveryZoneRepository zones;
  late CartCubit cart;

  const dish = Dish(id: 'd1', name: 'Kottu', description: '', pricePence: 895);

  setUp(() {
    orders = FakeOrderRepository();
    zones = FakeDeliveryZoneRepository();
    cart = CartCubit()..addDish(dish, quantity: 2);
  });

  CheckoutCubit build() =>
      CheckoutCubit(repository: orders, cart: cart, zones: zones);

  group('the zone model', () {
    test('reads what the server sent, including the polygon', () {
      final zone = DeliveryZone.fromJson(const {
        'id': 'z1',
        'name': 'Zone 1',
        'color': '#e8a33d',
        'polygon': [
          {'lat': 58.615, 'lng': -3.575},
          {'lat': 58.618, 'lng': -3.505},
          {'lat': 58.600, 'lng': -3.470},
        ],
        'min_order_pence': 3000,
        'delivery_fee_pence': 400,
        'priority': 1,
      });

      expect(zone.name, 'Zone 1');
      expect(zone.polygon, hasLength(3));
      expect(zone.polygon.first.lat, 58.615);
      expect(zone.minOrderPence, 3000);
      expect(zone.deliveryFeePence, 400);
    });

    test('a missing or broken colour still draws', () {
      const fallback = Color(0xFF000000);
      for (final bad in [null, '', 'orange', '#12']) {
        final zone = DeliveryZone.fromJson({'id': 'z', 'color': bad});
        expect(zone.colorOr(fallback), fallback, reason: '$bad');
      }
      // A zone with a typo in its colour should still appear on the map.
      expect(
        DeliveryZone.fromJson(const {
          'id': 'z',
          'color': '#e8a33d',
        }).colorOr(fallback),
        const Color(0xFFE8A33D),
      );
    });
  });

  group('checking a postcode', () {
    test('an address outside every zone is an answer, not an error', () async {
      zones.deliverable = false;
      final cubit = build();

      cubit.setPostcode('IV27 4AB');
      await cubit.checkPostcode();

      // The endpoint answers 200 with `deliverable: false`. Treating that as a
      // failure would put a red error on the screen for a fact.
      expect(cubit.state.postcodeError, isNull);
      expect(cubit.state.outsideDeliveryArea, isTrue);
      expect(
        cubit.state.zoneCheck!.message,
        'Delivery is not available to this address.',
      );
      // ...and it must not be placeable.
      expect(cubit.state.canPlace, isFalse);
      await cubit.close();
    });

    test(
      'a postcode that cannot be looked up is reported on the field',
      () async {
        zones.failure = const ApiFailure(
          kind: ApiFailureKind.invalid,
          message: "We couldn't find that postcode.",
          code: 'POSTCODE_NOT_FOUND',
        );
        final cubit = build();

        cubit.setPostcode('ZZ99 9ZZ');
        await cubit.checkPostcode();

        // Distinct from being outside the area: this one is a typo, and belongs
        // against the field rather than as a screen-wide failure.
        expect(cubit.state.postcodeError, contains("couldn't find"));
        expect(cubit.state.zoneCheck, isNull);
        await cubit.close();
      },
    );

    test('a new postcode drops the previous answer', () async {
      final cubit = build();
      cubit.setPostcode('KW14 7EL');
      await cubit.checkPostcode();
      expect(cubit.state.zone, isNotNull);

      cubit.setPostcode('IV27 4AB');

      // Keeping it would price this address at the last one's zone.
      expect(cubit.state.zoneCheck, isNull);
      await cubit.close();
    });
  });

  group('quoting', () {
    test('delivery is not priced until the zone is known', () async {
      final cubit = build();

      await cubit.quote();

      // Asking anyway returns POSTCODE_REQUIRED, which would show as a failure
      // for the ordinary state of not having typed an address yet.
      expect(orders.quoteCalls, 0);
      expect(cubit.state.failure, isNull);
      expect(cubit.state.canPlace, isFalse);
      await cubit.close();
    });

    test('the postcode goes to the server with the quote', () async {
      final cubit = build();
      cubit.setPostcode('kw14 7el');
      await cubit.checkPostcode();

      expect(orders.quoteCalls, 1);
      expect(orders.lastQuotePostcode, 'KW14 7EL');
      await cubit.close();
    });

    test('collection never needs one', () async {
      final cubit = build();
      await cubit.setDelivery(false);

      expect(orders.quoteCalls, greaterThan(0));
      // Nothing to send: the cubit has no postcode, and the repository drops
      // it for collection anyway -- see the wire test in network_test.dart.
      expect(orders.lastQuotePostcode ?? '', isEmpty);
      expect(cubit.state.canPlace, isTrue);
      await cubit.close();
    });
  });

  group('the delivery map', () {
    Widget wrap(List<DeliveryZone> zones) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: DeliveryZonesMap(zones: zones)),
    );

    testWidgets('draws one polygon per zone and prices them from the API', (
      tester,
    ) async {
      const zone2 = DeliveryZone(
        id: 'z2',
        name: 'Zone 2',
        polygon: [
          ZonePoint(lat: 58.7, lng: -3.7),
          ZonePoint(lat: 58.7, lng: -3.3),
          ZonePoint(lat: 58.4, lng: -3.3),
        ],
        minOrderPence: 3500,
        deliveryFeePence: 950,
        priority: 2,
        colorHex: '#3d7de8',
      );

      await tester.pumpWidget(
        wrap(const [FakeDeliveryZoneRepository.zone1, zone2]),
      );
      await tester.pumpAndSettle();

      final layer = tester.widget<PolygonLayer>(find.byType(PolygonLayer));
      expect(layer.polygons, hasLength(2));

      // Painted largest-first, so the cheap inner zone sits on top of the
      // rings around it rather than under them.
      expect(layer.polygons.first.borderColor, const Color(0xFF3D7DE8));

      // Every figure in the legend is the server's. Nothing about delivery
      // pricing may be written into the app.
      expect(find.text('Min £30.00 · Fee £4.00'), findsOneWidget);
      expect(find.text('Min £35.00 · Fee £9.50'), findsOneWidget);
      expect(find.text('Zone 1'), findsOneWidget);
      expect(find.text('Zone 2'), findsOneWidget);
    });

    testWidgets('a zone too small to be a shape is not drawn', (tester) async {
      const broken = DeliveryZone(
        id: 'z3',
        name: 'Zone 3',
        polygon: [ZonePoint(lat: 58.6, lng: -3.5)],
        minOrderPence: 5500,
        deliveryFeePence: 2000,
        priority: 3,
      );

      await tester.pumpWidget(
        wrap(const [FakeDeliveryZoneRepository.zone1, broken]),
      );
      await tester.pumpAndSettle();

      // Two points cannot enclose anything, and asking the map to draw it
      // would take the screen down. It still earns its legend row, because the
      // prices are real even if the outline is unusable.
      expect(
        tester.widget<PolygonLayer>(find.byType(PolygonLayer)).polygons,
        hasLength(1),
      );
      expect(find.text('Zone 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
