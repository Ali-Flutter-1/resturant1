import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/menu/domain/spice_level.dart';
import 'package:practice/features/checkout/presentation/checkout_cubit.dart';
import 'package:practice/features/checkout/presentation/checkout_screen.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/orders/domain/order_quote.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';
import 'package:practice/features/orders/domain/order_repository.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_delivery_zone_repository.dart';
import 'support/fake_order_repository.dart';

/// Pricing and placing an order.
///
/// The rules worth pinning come straight from the integration guide: render the
/// server's totals, keep one idempotency key per checkout and reuse it on retry,
/// and clear the basket only once the order exists.
void main() {
  late FakeOrderRepository repository;
  late FakeDeliveryZoneRepository zones;
  late CartCubit cart;

  const curry = Dish(
    id: 'd1',
    name: 'Chicken Kottu',
    description: '',
    pricePence: 895,
  );

  setUp(() {
    repository = FakeOrderRepository();
    zones = FakeDeliveryZoneRepository();
    cart = CartCubit()..addDish(curry, quantity: 2, notes: 'No coriander');

    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 2400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  CheckoutCubit buildCubit() =>
      CheckoutCubit(repository: repository, cart: cart, zones: zones);

  /// Gives a cubit a postcode inside a zone.
  ///
  /// Delivery is priced per zone, so a delivery quote is refused until the
  /// postcode is known -- which is the point of the feature, and means any
  /// test about *quoting* has to say where it is delivering to first. Calling
  /// `checkPostcode` directly skips the typing debounce.
  Future<void> primeDelivery(CheckoutCubit cubit) async {
    cubit.setPostcode('KW14 7EL');
    // Confirming a postcode re-prices on its own, which is the behaviour --
    // the fee and the minimum both come from the zone. The counter is reset so
    // each test still counts only the quotes it asked for itself.
    await cubit.checkPostcode();
    repository.quoteCalls = 0;
  }

  /// Types a postcode into the address form and waits for the zone lookup.
  ///
  /// Delivery is priced by zone, so the screen shows no total until this has
  /// happened -- collecting the postcode before the basket total is the whole
  /// point of the feature.
  Future<void> enterPostcode(
    WidgetTester tester, {
    String postcode = 'KW14 7EL',
  }) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'KW14 7EL'),
      postcode,
    );
    // Past the typing debounce.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Widget wrap({void Function(String)? onPlaced}) => MultiBlocProvider(
    providers: [
      BlocProvider(create: (_) => AuthFixtures.cubit(AuthFixtures.customer)),
      BlocProvider.value(value: cart),
    ],
    child: MultiRepositoryProvider(
      providers: [
        RepositoryProvider<OrderRepository>.value(value: repository),
        RepositoryProvider<DeliveryZoneRepository>.value(value: zones),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: CheckoutScreen(onPlaceOrder: onPlaced),
      ),
    ),
  );

  Future<void> fillDelivery(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, '07700 900123'),
      '07700 900123',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '12 Example Street'),
      '12 Example Street',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Manchester'),
      'Manchester',
    );
    // Found by its hint, which is a Caithness example now that delivery is
    // zone-based; the value typed is still the Manchester one the assertions
    // below expect to reach the API.
    await tester.enterText(
      find.widgetWithText(TextField, 'KW14 7EL'),
      'M1 2AB',
    );
    // Past the postcode debounce, so the zone is known and the basket priced
    // before anything tries to place the order.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  group('quoting', () {
    test('prices the basket when the checkout opens', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      expect(repository.quoteCalls, 1);
      expect(cubit.state.stage, CheckoutStage.ready);
      expect(cubit.state.quote?.totalPence, 2089);
    });

    test('re-prices when the fulfilment type changes', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      await cubit.setDelivery(false);

      // The fee and the minimum both depend on it, so the old figures are wrong
      // the instant it changes.
      expect(repository.quoteCalls, 2);
      expect(repository.lastQuoteDelivery, isFalse);
    });

    test('an empty basket is refused before any request', () async {
      final cubit = CheckoutCubit(
        repository: repository,
        cart: CartCubit(),
        zones: zones,
      );
      await primeDelivery(cubit);
      await cubit.quote();

      expect(repository.quoteCalls, 0);
      expect(cubit.state.stage, CheckoutStage.failed);
    });

    test('a failed quote keeps the failure to show', () async {
      repository.quoteFailure = ApiFailure.offline;
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      expect(cubit.state.stage, CheckoutStage.failed);
      expect(cubit.state.failure, ApiFailure.offline);
    });
  });

  group('the minimum', () {
    test('blocks placing, and the shortfall is exact', () async {
      repository.quoteResult = const OrderQuote(
        subtotalPence: 600,
        deliveryFeePence: 299,
        totalPence: 899,
        minimumOrderPence: 1000,
        meetsMinimum: false,
      );
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      expect(cubit.state.canPlace, isFalse);
      // £4.00 short — measured on the subtotal, because the delivery fee does not
      // count towards the minimum.
      expect(cubit.state.quote?.formattedShortfall, '£4.00');
    });

    testWidgets('says how much more is needed', (tester) async {
      repository.quoteResult = const OrderQuote(
        subtotalPence: 600,
        deliveryFeePence: 299,
        totalPence: 899,
        minimumOrderPence: 1000,
        meetsMinimum: false,
      );
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      // "Minimum not met" would leave the customer to do the arithmetic.
      expect(find.textContaining('Add £4.00 more'), findsOne);
    });
  });

  group('placing', () {
    test('sends only dish id, quantity and notes per line', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      expect(repository.lastPlaced?['items'], [
        {'dish_id': 'd1', 'quantity': 2, 'notes': 'No coriander'},
      ]);
      // No prices. Anything a client could set, a client could forge.
      final items = repository.lastPlaced!['items']! as List;
      expect((items.first as Map).containsKey('unit_price_pence'), isFalse);
    });

    test('clears the basket only after the server confirms', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      repository.placeFailure = ApiFailure.offline;
      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      // A basket emptied optimistically and a request that then failed leaves
      // the customer with neither an order nor their choices.
      expect(cart.state.isEmpty, isFalse);

      repository.placeFailure = null;
      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');
      expect(cart.state.isEmpty, isTrue);
    });

    test('a retry reuses the same idempotency key', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      repository.placeFailure = ApiFailure.offline;
      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');
      repository.placeFailure = null;
      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      // A fresh key on retry is exactly how a customer ends up with two orders:
      // the server cannot tell a second attempt from a second order.
      expect(repository.idempotencyKeys, hasLength(2));
      expect(repository.idempotencyKeys.first, repository.idempotencyKeys.last);
    });

    test('a genuinely different basket gets a new key', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();
      final first = cubit.idempotencyKey;

      cart.addDish(
        const Dish(id: 'd2', name: 'Hoppers', description: '', pricePence: 450),
      );
      await primeDelivery(cubit);
      await cubit.quote();

      // Otherwise the second order would be deduplicated against the first.
      expect(cubit.idempotencyKey, isNot(first));
    });

    test('the key rotates after a successful order', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();
      final used = cubit.idempotencyKey;

      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      expect(cubit.idempotencyKey, isNot(used));
    });

    test('a chosen slot is sent verbatim, with is_asap false', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      // Whatever the quote actually offered, rather than a date typed in here —
      // a pinned date stops being selectable the day after it is written.
      final slot = repository.quoteResult.availableSlots.last;
      cubit.setSlot(slot);
      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      // Untouched: the API refuses a time with no offset, and the app must not
      // rebuild the slot grid.
      expect(repository.lastPlaced?['requested_for'], slot);
      expect(repository.lastPlaced?['is_asap'], isFalse);
    });

    test('ASAP sends no time at all', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      expect(repository.lastPlaced?['is_asap'], isTrue);
      expect(repository.lastPlaced?['requested_for'], isNull);
    });

    test('changing the fulfilment type drops a chosen slot', () async {
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();
      cubit.setSlot('2026-08-12T19:15:00Z');

      await cubit.setDelivery(false);

      // The two paths have different lead times, so a slot chosen for one is not
      // necessarily offered for the other.
      expect(cubit.state.requestedFor, isNull);
    });

    test('a 422 lands on the offending field', () async {
      repository.placeFailure = const ApiFailure(
        kind: ApiFailureKind.invalid,
        message: 'Please check the highlighted fields and try again.',
        code: 'VALIDATION_FAILED',
        fieldErrors: {
          'contact_phone': 'Enter a phone number we can reach you on.',
        },
      );
      final cubit = buildCubit();
      await primeDelivery(cubit);
      await cubit.quote();

      await cubit.place(contactName: 'Ali', contactPhone: '1');

      expect(
        cubit.state.fieldErrors['contact_phone'],
        'Enter a phone number we can reach you on.',
      );
      // Back to ready, so the details typed are still usable.
      expect(cubit.state.stage, CheckoutStage.ready);
    });
  });

  group('the screen', () {
    testWidgets('renders the server total, never a local sum', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      // The basket's own arithmetic is 2 x £8.95 = £17.90; the server says
      // £20.89 with the fee. The screen shows the server.
      expect(find.textContaining('£20.89'), findsWidgets);
    });

    testWidgets('will not place a delivery order without an address', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      await tester.tap(find.textContaining('Place order'));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Where are we delivering to?'), findsOne);
      // Nothing left the device.
      expect(repository.placeCalls, 0);
    });

    testWidgets('collection asks for no address at all', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      await tester.tap(find.text('Collection'));
      await tester.pump(const Duration(seconds: 2));

      // The API ignores address fields for collection, so asking would be asking
      // for something that goes nowhere.
      expect(find.widgetWithText(TextField, '12 Example Street'), findsNothing);
    });

    testWidgets('a filled delivery order reaches the API', (tester) async {
      String? placed;
      await tester.pumpWidget(wrap(onPlaced: (number) => placed = number));
      await tester.pump(const Duration(seconds: 2));

      await fillDelivery(tester);
      await tester.tap(find.textContaining('Place order'));
      await tester.pump(const Duration(seconds: 2));

      expect(repository.placeCalls, 1);
      expect(repository.lastPlaced?['postcode'], 'M1 2AB');
      expect(repository.lastPlaced?['city'], 'Manchester');
      expect(placed, 'AB12-CD34');
    });

    testWidgets('a basket line can be stepped down and removed', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);
      final quotesAfterLoad = repository.quoteCalls;

      // Two of one dish, so the first tap reduces rather than removes.
      expect(cart.state.lines.single.quantity, 2);
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pump(const Duration(seconds: 2));

      expect(cart.state.lines.single.quantity, 1);
      // Re-priced by the server, never adjusted locally: removing an item can
      // drop the basket under the delivery minimum or change the fee.
      expect(repository.quoteCalls, quotesAfterLoad + 1);

      // At one, the control becomes a bin and asks before emptying the line.
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Keep it'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      // Backed out, so nothing was lost.
      expect(cart.state.lines, hasLength(1));

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pump(const Duration(seconds: 2));

      expect(cart.state.lines, isEmpty);
    });

    testWidgets('a line shows its spice level and note', (tester) async {
      cart = CartCubit()
        ..addDish(
          const Dish(
            id: 'd1',
            name: 'Chicken Kottu',
            description: '',
            pricePence: 895,
            hasSpiceLevels: true,
          ),
          notes: 'No coriander',
          spiceLevel: SpiceLevel.high,
        );
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      // One line of small print, not two: both are instructions on this item,
      // and stacking them made a two-item basket four lines tall.
      expect(find.text('Hot spice · No coriander'), findsOneWidget);
    });

    testWidgets('offers cash and card, with cash preselected', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      expect(find.text('Cash'), findsOne);
      expect(find.text('Card'), findsOne);

      // Cash until asked otherwise: moving somebody to paying online is not a
      // choice the checkout screen gets to make for them.
      expect(find.textContaining('Place order'), findsOne);
    });

    testWidgets('card can be chosen', (tester) async {
      // This used to assert the opposite -- that card was shown greyed with
      // "Coming soon" -- which was true of one deployment and hardcoded into
      // the app, so a backend that supported card showed it disabled anyway.
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      expect(find.text('Card'), findsOne);
      expect(find.textContaining('Coming soon'), findsNothing);

      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();

      // Chosen, not ignored: the button changes from "Place order" to "Pay".
      // Whether the backend can actually take a card is answered when the
      // order is placed, not guessed at here.
      expect(find.textContaining('Pay'), findsWidgets);
      expect(find.textContaining('Place order'), findsNothing);
    });

    testWidgets('offers two timing choices rather than a wall of chips', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      // Sixteen chips in a Wrap is what this replaced.
      expect(find.text('As soon as possible'), findsOne);
      expect(find.text('Choose a time'), findsOne);
    });

    testWidgets('picking a time opens a list of them', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      await tester.tap(find.text('Choose a time'));
      await tester.pumpAndSettle();

      // The quote offered two slots.
      expect(find.text('Today'), findsNWidgets(2));
    });
  });

  group('the kitchen decides the earliest time', () {
    /// A basket whose slowest dish takes [minutes].
    CartCubit cartTaking(int minutes) => CartCubit()
      ..addDish(
        Dish(
          id: 'slow',
          name: 'Slow dish',
          description: '',
          pricePence: 895,
          prepMinMinutes: minutes - 5,
          prepMaxMinutes: minutes,
        ),
      );

    /// Slots at ten-minute steps from now, so the boundary is easy to name.
    List<String> slotsFromNow(List<int> minutes) => [
      for (final m in minutes)
        DateTime.now().toUtc().add(Duration(minutes: m)).toIso8601String(),
    ];

    test('the basket takes the longest dish, not the sum', () {
      final cart = CartCubit()
        ..addDish(
          const Dish(
            id: 'a',
            name: 'Curry',
            description: '',
            pricePence: 100,
            prepMaxMinutes: 20,
          ),
        )
        ..addDish(
          const Dish(
            id: 'b',
            name: 'Side',
            description: '',
            pricePence: 100,
            prepMaxMinutes: 5,
          ),
        );

      // A kitchen cooks in parallel: twenty minutes, not twenty-five. Adding them
      // up would push every multi-item order absurdly late.
      expect(cart.state.longestPrepMinutes, 20);
    });

    test('a basket with no estimates narrows nothing', () {
      final cart = CartCubit()
        ..addDish(
          const Dish(id: 'a', name: 'Curry', description: '', pricePence: 100),
        );
      expect(cart.state.longestPrepMinutes, isNull);
    });

    test('slots inside the cooking time are not offered', () async {
      repository.quoteResult = OrderQuote(
        totalPence: 895,
        availableSlots: slotsFromNow([10, 20, 30, 40]),
      );
      final cubit = CheckoutCubit(
        repository: repository,
        cart: cartTaking(20),
        zones: zones,
      );
      await primeDelivery(cubit);
      await cubit.quote();

      // A twenty-minute dish cannot be asked for in ten. Twenty is the boundary
      // and a shade of clock drift makes it unreliable, so this checks the two
      // that are unambiguous.
      final offered = cubit.state.selectableSlots;
      expect(offered, hasLength(lessThan(4)));
      expect(offered.last, cubit.state.quote!.availableSlots.last);
    });

    test('a longer estimate offers fewer times', () async {
      repository.quoteResult = OrderQuote(
        totalPence: 895,
        availableSlots: slotsFromNow([10, 20, 30, 40, 50]),
      );

      final quick = CheckoutCubit(
        repository: repository,
        cart: cartTaking(5),
        zones: zones,
      );
      await primeDelivery(quick);
      await quick.quote();
      final slow = CheckoutCubit(
        repository: repository,
        cart: cartTaking(45),
        zones: zones,
      );
      await primeDelivery(slow);
      await slow.quote();

      expect(
        slow.state.selectableSlots.length,
        lessThan(quick.state.selectableSlots.length),
      );
    });

    test('every slot too soon is reported rather than left blank', () async {
      repository.quoteResult = OrderQuote(
        totalPence: 895,
        availableSlots: slotsFromNow([5, 10]),
      );
      final cubit = CheckoutCubit(
        repository: repository,
        cart: cartTaking(120),
        zones: zones,
      );
      await primeDelivery(cubit);
      await cubit.quote();

      expect(cubit.state.selectableSlots, isEmpty);
      // The customer has done nothing wrong, and ASAP still works.
      expect(cubit.state.everySlotTooSoon, isTrue);
    });

    test('a slot the kitchen cannot make is refused, not stored', () async {
      repository.quoteResult = OrderQuote(
        totalPence: 895,
        availableSlots: slotsFromNow([5, 60]),
      );
      final cubit = CheckoutCubit(
        repository: repository,
        cart: cartTaking(30),
        zones: zones,
      );
      await primeDelivery(cubit);
      await cubit.quote();

      final tooSoon = cubit.state.quote!.availableSlots.first;
      cubit.setSlot(tooSoon);

      // Only a stale screen could ask for it, and sending it would earn a
      // TIME_TOO_SOON the customer cannot act on.
      expect(cubit.state.requestedFor, isNull);
    });

    test('a slot the kitchen can make is accepted', () async {
      repository.quoteResult = OrderQuote(
        totalPence: 895,
        availableSlots: slotsFromNow([5, 60]),
      );
      final cubit = CheckoutCubit(
        repository: repository,
        cart: cartTaking(30),
        zones: zones,
      );
      await primeDelivery(cubit);
      await cubit.quote();

      final later = cubit.state.quote!.availableSlots.last;
      cubit.setSlot(later);

      expect(cubit.state.requestedFor, later);
    });

    testWidgets('says why earlier times are missing', (tester) async {
      cart = cartTaking(25);
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));
      await enterPostcode(tester);

      // An unexplained gap in the times reads as a bug.
      expect(find.textContaining('takes about 25 minutes to cook'), findsOne);
    });
  });

  group('choosing how to pay', () {
    test('card is offered by default', () {
      // Whether Worldpay is configured is the backend's business. Hardcoding
      // it off in the app left the option greyed out on a server that
      // supported it perfectly well.
      expect(const CheckoutState().cardUnavailable, isFalse);
    });

    test(
      'a deployment with no provider says so, and cash takes over',
      () async {
        repository.placeFailure = const ApiFailure(
          kind: ApiFailureKind.invalid,
          code: 'CARD_PAYMENT_UNAVAILABLE',
          message: 'Card payment is not available.',
        );
        final cubit = buildCubit()..setPaymentMethod(PaymentMethod.card);
        await cubit.quote();

        final failure = await cubit.place(
          contactName: 'Ali',
          contactPhone: '07700 900123',
        );

        expect(failure?.code, 'CARD_PAYMENT_UNAVAILABLE');
        // Remembered, so the option greys itself out rather than inviting the
        // same refusal again...
        expect(cubit.state.cardUnavailable, isTrue);
        // ...and the choice moves back to cash, so the next tap of Place Order
        // succeeds instead of repeating it.
        expect(cubit.state.paymentMethod, PaymentMethod.cash);
        await cubit.close();
      },
    );

    test('an unrelated failure leaves the card option alone', () async {
      repository.placeFailure = const ApiFailure(
        kind: ApiFailureKind.offline,
        message: 'Offline.',
      );
      final cubit = buildCubit()..setPaymentMethod(PaymentMethod.card);
      await cubit.quote();

      await cubit.place(contactName: 'Ali', contactPhone: '07700 900123');

      expect(cubit.state.cardUnavailable, isFalse);
      expect(cubit.state.paymentMethod, PaymentMethod.card);
      await cubit.close();
    });
  });
}
