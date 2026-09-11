import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/config/app_config.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/orders/data/demo_order_repository.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/orders/domain/order_repository.dart';
import 'package:practice/features/orders/presentation/my_orders_screen.dart';
import 'package:practice/features/orders/presentation/orders_cubit.dart';

import 'support/fake_order_repository.dart';

void main() {
  group('CustomerOrderStatus.fromApi', () {
    test('maps the documented statuses', () {
      expect(CustomerOrderStatus.fromApi('placed'), CustomerOrderStatus.placed);
      expect(
        CustomerOrderStatus.fromApi('preparing'),
        CustomerOrderStatus.preparing,
      );
      expect(CustomerOrderStatus.fromApi('ready'), CustomerOrderStatus.ready);
      expect(
        CustomerOrderStatus.fromApi('out_for_delivery'),
        CustomerOrderStatus.outForDelivery,
      );
      expect(
        CustomerOrderStatus.fromApi('completed'),
        CustomerOrderStatus.completed,
      );
      expect(
        CustomerOrderStatus.fromApi('cancelled'),
        CustomerOrderStatus.cancelled,
      );
    });

    test('is case- and whitespace-insensitive', () {
      expect(
        CustomerOrderStatus.fromApi('  PREPARING '),
        CustomerOrderStatus.preparing,
      );
    });

    test('treats an unknown status as in progress rather than throwing', () {
      // A backend that gains a state must not blank the whole history screen.
      expect(
        CustomerOrderStatus.fromApi('quantum_superposition'),
        CustomerOrderStatus.placed,
      );
      expect(CustomerOrderStatus.fromApi(null), CustomerOrderStatus.placed);
    });

    test('folds the kitchen-only "overdue" into a customer-safe state', () {
      // Staff need to see a late order; the customer must never be told their
      // dinner is "overdue".
      expect(
        CustomerOrderStatus.fromApi('overdue'),
        CustomerOrderStatus.placed,
      );
    });

    test('only finished states leave the tracker', () {
      expect(CustomerOrderStatus.completed.isLive, isFalse);
      expect(CustomerOrderStatus.cancelled.isLive, isFalse);
      expect(CustomerOrderStatus.outForDelivery.isLive, isTrue);
    });

    test('a cancelled order has no position on the track', () {
      expect(CustomerOrderStatus.cancelled.step, isNull);
      expect(CustomerOrderStatus.completed.step, CustomerOrderStatus.steps - 1);
    });
  });

  group('CustomerOrder.fromJson', () {
    test('reads the API shape', () {
      final order = CustomerOrder.fromJson({
        'id': 'abc',
        'order_number': '#0042',
        'status': 'preparing',
        'total_pence': 2850,
        'placed_at': '2026-08-01T18:30:00Z',
        'fulfilment_type': 'delivery',
        'items': [
          {'name': 'Hoppers', 'quantity': 2, 'line_total_pence': 1000},
        ],
      });

      expect(order.reference, '#0042');
      expect(order.status, CustomerOrderStatus.preparing);
      expect(order.formattedTotal, '£28.50');
      expect(order.itemCount, 2);
      expect(order.items.single.dishName, 'Hoppers');
      expect(order.isDelivery, isTrue);
    });

    test('falls back to the id tail when the API sends no order number', () {
      final order = CustomerOrder.fromJson({
        'id': '5f1c9e2a-0000-4bcd-9999-abcd0000ef12',
        'status': 'placed',
      });
      // Readable aloud, which a bare UUID is not.
      expect(order.reference, '#EF12');
    });

    test('a missing timestamp is null, not an invented date', () {
      final order = CustomerOrder.fromJson({'id': 'x', 'status': 'placed'});
      expect(order.placedAt, isNull);
    });

    test('prefers the server line total over unit × quantity', () {
      final item = CustomerOrderItem.fromJson({
        'name': 'Curry',
        'quantity': 3,
        'unit_price_pence': 500,
        'line_total_pence': 1400,
      });
      // The server's arithmetic wins — it is the figure the payment matches.
      expect(item.linePence, 1400);
    });

    test('computes the line only when the server sent a unit price alone', () {
      final item = CustomerOrderItem.fromJson({
        'name': 'Curry',
        'quantity': 3,
        'unit_price_pence': 500,
      });
      expect(item.linePence, 1500);
    });

    test('cancellability follows the server when it says', () {
      final locked = CustomerOrder.fromJson({
        'id': 'a',
        'status': 'placed',
        'can_cancel': false,
      });
      // Documented rule says placed is cancellable; the server disagrees, and
      // the server knows whether the kitchen has started.
      expect(locked.canCancel, isFalse);

      final open = CustomerOrder.fromJson({'id': 'b', 'status': 'placed'});
      expect(open.canCancel, isTrue);

      final cooking = CustomerOrder.fromJson({
        'id': 'c',
        'status': 'preparing',
      });
      expect(cooking.canCancel, isFalse);
    });

    test('the server decides whether cancelling is still possible', () {
      // This used to assert the opposite -- that the app refused a cancellation
      // once the status said `preparing`, whatever the server sent. The guide
      // is explicit that `can_cancel` is the rule and the app should not
      // reproduce it, and the approval step proved why: when every order began
      // at `placed` the local check happened to agree, and when orders started
      // at `pending_approval` instead it silently removed the cancel button
      // from the whole window a customer is most likely to use it in.
      final cookingButAllowed = CustomerOrder.fromJson({
        'id': 'd',
        'status': 'preparing',
        'can_cancel': true,
      });
      expect(cookingButAllowed.canCancel, isTrue);

      final placedButRefused = CustomerOrder.fromJson({
        'id': 'e',
        'status': 'placed',
        'can_cancel': false,
      });
      expect(placedButRefused.canCancel, isFalse);
    });

    test('a response with no flag falls back to the documented states', () {
      // Only for a payload that omits the field. The three the API accepts a
      // cancellation in, and nothing after the kitchen has started.
      expect(
        CustomerOrder.fromJson({
          'id': 'f',
          'status': 'pending_approval',
        }).canCancel,
        isTrue,
      );
      expect(
        CustomerOrder.fromJson({'id': 'g', 'status': 'preparing'}).canCancel,
        isFalse,
      );
    });

    test('collection orders are never described as on their way', () {
      final order = CustomerOrder.fromJson({
        'id': 'a',
        'status': 'out_for_delivery',
        'fulfilment_type': 'collection',
      });
      expect(order.isDelivery, isFalse);
      expect(order.statusLabel, 'Ready to collect');
    });
  });

  group('OrdersCubit', () {
    test('splits live from finished orders', () async {
      final cubit = OrdersCubit(
        repository: FakeOrderRepository(
          orders: [
            OrderFixtures.order(id: '1', status: CustomerOrderStatus.preparing),
            OrderFixtures.order(id: '2', status: CustomerOrderStatus.completed),
            OrderFixtures.order(id: '3', status: CustomerOrderStatus.cancelled),
          ],
        ),
      );

      await cubit.load();

      expect(cubit.state.status, OrdersStatus.ready);
      expect(cubit.state.live.map((o) => o.id), ['1']);
      expect(cubit.state.past.map((o) => o.id), ['2', '3']);
    });

    test('reports a failure with the API message', () async {
      final cubit = OrdersCubit(
        repository: FakeOrderRepository(failure: ApiFailure.offline),
      );

      await cubit.load();

      expect(cubit.state.status, OrdersStatus.failure);
      expect(cubit.state.failure, ApiFailure.offline);
    });

    test(
      'a failed silent refresh keeps the orders already on screen',
      () async {
        final repository = FakeOrderRepository(
          orders: [OrderFixtures.order(id: '1')],
        );
        final cubit = OrdersCubit(repository: repository);
        await cubit.load();

        repository.failure = ApiFailure.offline;
        await cubit.load(silent: true);

        // The tracker the user is watching must not blank because one poll
        // happened to land in a tunnel.
        expect(cubit.state.status, OrdersStatus.ready);
        expect(cubit.state.orders, hasLength(1));
      },
    );

    test('cancelling adopts the server status rather than assuming', () async {
      final repository = FakeOrderRepository(
        orders: [
          OrderFixtures.order(
            id: '1',
            status: CustomerOrderStatus.placed,
            canCancel: true,
          ),
        ],
      );
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      final error = await cubit.cancelOrder('1');

      expect(error, isNull);
      expect(repository.cancelled, ['1']);
      expect(cubit.state.orders.single.status, CustomerOrderStatus.cancelled);
      expect(cubit.state.cancellingId, isNull);
    });

    test('a refused cancellation leaves the order alone', () async {
      final repository = FakeOrderRepository(
        orders: [
          OrderFixtures.order(
            id: '1',
            status: CustomerOrderStatus.preparing,
            canCancel: true,
          ),
        ],
        cancelFailure: const ApiFailure(
          kind: ApiFailureKind.conflict,
          message: 'The kitchen has already started this order.',
        ),
      );
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      final error = await cubit.cancelOrder('1');

      // The one lie this screen must not tell: "cancelled" for an order that
      // is still being cooked.
      expect(error, 'The kitchen has already started this order.');
      expect(cubit.state.orders.single.status, CustomerOrderStatus.preparing);
      expect(cubit.state.cancellingId, isNull);
    });
  });

  group('MyOrdersScreen', () {
    Widget wrap(OrderRepository repository) =>
        RepositoryProvider<OrderRepository>.value(
          value: repository,
          // The cubit is app-level now, so an order placed on another tab can
          // reach this screen. Tests provide it the same way main() does.
          child: BlocProvider(
            create: (_) => OrdersCubit(repository: repository),
            child: MaterialApp(
              theme: AppTheme.light,
              home: const MyOrdersScreen(),
            ),
          ),
        );

    testWidgets('shows the tracker for a live order', (tester) async {
      await tester.pumpWidget(
        wrap(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                reference: '#0042',
                status: CustomerOrderStatus.outForDelivery,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Happening now'), findsOne);
      expect(find.text('On its way'), findsWidgets);
      expect(find.textContaining('#0042'), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('separates finished orders into the history list', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                status: CustomerOrderStatus.preparing,
              ),
              OrderFixtures.order(
                id: '2',
                reference: '#0041',
                status: CustomerOrderStatus.completed,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Happening now'), findsOne);
      expect(find.text('Earlier orders'), findsOne);
      expect(find.text('#0041'), findsOne);
    });

    testWidgets('offers no cancel once the kitchen has started', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                status: CustomerOrderStatus.preparing,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Cancel order'), findsNothing);
    });

    testWidgets('offers cancel while the order is only placed', (tester) async {
      await tester.pumpWidget(
        wrap(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '2',
                status: CustomerOrderStatus.placed,
                canCancel: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Cancel order'), findsOne);
    });

    testWidgets('cancelling asks first, and does nothing if declined', (
      tester,
    ) async {
      final repository = FakeOrderRepository(
        orders: [
          OrderFixtures.order(
            id: '1',
            status: CustomerOrderStatus.placed,
            canCancel: true,
          ),
        ],
      );
      await tester.pumpWidget(wrap(repository));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('Cancel order'));
      await tester.pumpAndSettle();
      expect(find.text('Keep my order'), findsOne);

      await tester.tap(find.text('Keep my order'));
      await tester.pumpAndSettle();

      // Nothing irreversible happens behind a sheet the user dismissed.
      expect(repository.cancelled, isEmpty);
    });

    testWidgets('a confirmed cancellation reaches the repository', (
      tester,
    ) async {
      final repository = FakeOrderRepository(
        orders: [
          OrderFixtures.order(
            id: '1',
            status: CustomerOrderStatus.placed,
            canCancel: true,
          ),
        ],
      );
      await tester.pumpWidget(wrap(repository));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('Cancel order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel this order'));
      await tester.pumpAndSettle();

      expect(repository.cancelled, ['1']);
    });

    testWidgets('shows the API message when loading fails', (tester) async {
      await tester.pumpWidget(
        wrap(FakeOrderRepository(failure: ApiFailure.offline)),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text(ApiFailure.offline.message), findsOne);
    });

    testWidgets('an empty history says so and offers the menu', (tester) async {
      await tester.pumpWidget(wrap(FakeOrderRepository(orders: [])));
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('No orders yet'), findsOne);
      // The callback is null here, so the button is absent by design rather
      // than dangling.
      expect(find.text('Browse the menu'), findsNothing);
    });

    testWidgets('polls while an order is live', (tester) async {
      final live = FakeOrderRepository(
        orders: [
          OrderFixtures.order(id: '1', status: CustomerOrderStatus.preparing),
        ],
      );
      await tester.pumpWidget(wrap(live));
      await tester.pump(const Duration(seconds: 2));
      expect(live.loadCount, 1);

      await tester.pump(const Duration(seconds: 31));
      await tester.pump();

      // The tracker moves on its own — nobody should have to pull to refresh
      // to find out whether their food has left the kitchen.
      expect(live.loadCount, 2);
    });

    testWidgets('stops polling once nothing is in progress', (tester) async {
      final settled = FakeOrderRepository(
        orders: [
          OrderFixtures.order(id: '1', status: CustomerOrderStatus.completed),
        ],
      );
      await tester.pumpWidget(wrap(settled));
      await tester.pump(const Duration(seconds: 2));
      expect(settled.loadCount, 1);

      await tester.pump(const Duration(seconds: 61));
      await tester.pump();

      // A history screen with nothing live must not keep waking the network up.
      expect(settled.loadCount, 1);
    });

    testWidgets('taps while the receipt is loading do not stack sheets', (
      tester,
    ) async {
      final repository = FakeOrderRepository(
        orders: [
          OrderFixtures.order(
            id: '1',
            reference: '#0041',
            status: CustomerOrderStatus.completed,
          ),
        ],
      )..detailGate = Completer<void>();

      await tester.pumpWidget(wrap(repository));
      await tester.pump(const Duration(seconds: 2));

      // Three impatient taps while the fetch is still in flight.
      await tester.tap(find.text('#0041'));
      await tester.pump();
      await tester.tap(find.text('#0041'), warnIfMissed: false);
      await tester.pump();
      await tester.tap(find.text('#0041'), warnIfMissed: false);
      await tester.pump();

      // One request, not three.
      expect(repository.orderByIdCalls, 1);

      repository.detailGate!.complete();
      await tester.pumpAndSettle();

      // And one sheet. Three would have stacked, and closing the top one
      // would reveal another underneath.
      expect(find.text('Order #0041'), findsOne);
    });

    testWidgets('tapping a past order opens its receipt', (tester) async {
      await tester.pumpWidget(
        wrap(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                reference: '#0041',
                status: CustomerOrderStatus.completed,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('#0041'));
      await tester.pumpAndSettle();

      expect(find.text('Order #0041'), findsOne);
      expect(find.text('Jaffna Crab'), findsOne);
      expect(find.text('2×'), findsOne);
      expect(find.text('Total'), findsOne);
    });
  });

  group('demo orders', () {
    test('are off unless .env asks for them explicitly', () {
      dotenv.loadFromString(envString: 'API_BASE_URL=https://example.com');
      // A missing key must not enable them: the failure mode is invented orders
      // shown to a real customer.
      expect(AppConfig.useDemoOrders, isFalse);

      dotenv.loadFromString(
        envString: 'API_BASE_URL=https://example.com\nUSE_DEMO_ORDERS=1',
      );
      expect(AppConfig.useDemoOrders, isFalse);

      dotenv.loadFromString(
        envString: 'API_BASE_URL=https://example.com\nUSE_DEMO_ORDERS=TRUE',
      );
      expect(AppConfig.useDemoOrders, isTrue);
    });

    test('cover a live order at each stage plus a full history', () async {
      final page = await DemoOrderRepository(delay: Duration.zero).myOrders();
      final orders = page.items;
      final live = orders.where((o) => o.status.isLive);

      expect(live.map((o) => o.status), contains(CustomerOrderStatus.placed));
      expect(
        live.map((o) => o.status),
        contains(CustomerOrderStatus.outForDelivery),
      );
      expect(orders.any((o) => o.canCancel), isTrue);
      expect(orders.any((o) => !o.isDelivery), isTrue);
      expect(
        orders.map((o) => o.status),
        contains(CustomerOrderStatus.cancelled),
      );
      // The case that used to draw an empty gap in the receipt sheet.
      expect(orders.any((o) => o.items.isEmpty), isTrue);
    });

    test('cancelling one sticks', () async {
      final repository = DemoOrderRepository(delay: Duration.zero);
      final target = (await repository.myOrders()).items.firstWhere(
        (o) => o.canCancel,
      );

      await repository.cancel(target.id);

      final after = (await repository.myOrders()).items.firstWhere(
        (o) => o.id == target.id,
      );
      expect(after.status, CustomerOrderStatus.cancelled);
    });
  });

  group('a cancelled or declined order', () {
    test('keeps the reason and tells the two states apart', () {
      final rejected = CustomerOrder.fromJson(const {
        'id': 'o1',
        'order_number': 'AB12-CD34',
        'status': 'rejected',
        'total_pence': 2089,
        'cancellation_reason': 'The requested dish is unavailable.',
        'cancelled_at': '2026-08-14T15:30:00Z',
      });

      // One state to a tracker, two to the person reading it.
      expect(rejected.status, CustomerOrderStatus.cancelled);
      expect(rejected.wasRejected, isTrue);
      expect(rejected.statusLabel, 'Declined');
      expect(rejected.cancellationReason, 'The requested dish is unavailable.');
      expect(rejected.cancelledAt, isNotNull);

      final cancelled = CustomerOrder.fromJson(const {
        'id': 'o2',
        'status': 'cancelled',
        'cancellation_reason': 'Restaurant closed early.',
      });
      expect(cancelled.wasRejected, isFalse);
      expect(cancelled.statusLabel, 'Cancelled');
    });

    test('a blank reason is no reason', () {
      // Rendering an empty notice box would read as a rendering fault.
      final order = CustomerOrder.fromJson(const {
        'id': 'o3',
        'status': 'cancelled',
        'cancellation_reason': '   ',
      });
      expect(order.cancellationReason, isNull);
    });

    testWidgets('the receipt shows why, in the restaurant\'s own words', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrapOrders(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                reference: '#0044',
                status: CustomerOrderStatus.cancelled,
                wasRejected: true,
                cancellationReason: 'The requested dish is unavailable.',
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('#0044'));
      await tester.pumpAndSettle();

      expect(find.textContaining('declined this order'), findsOneWidget);
      expect(find.text('The requested dish is unavailable.'), findsOneWidget);
    });
  });

  group('the receipt sheet', () {
    testWidgets('is padded and scrolls', (tester) async {
      await tester.pumpWidget(
        _wrapOrders(
          FakeOrderRepository(
            orders: [
              OrderFixtures.order(
                id: '1',
                reference: '#0041',
                status: CustomerOrderStatus.completed,
                items: const [
                  CustomerOrderItem(
                    dishName: 'Jaffna Crab',
                    quantity: 1,
                    linePence: 1850,
                  ),
                  CustomerOrderItem(
                    dishName: 'Hoppers',
                    quantity: 2,
                    linePence: 1000,
                  ),
                  CustomerOrderItem(
                    dishName: 'Kottu',
                    quantity: 3,
                    linePence: 2400,
                  ),
                  CustomerOrderItem(
                    dishName: 'Watalappan',
                    quantity: 2,
                    linePence: 1200,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('#0041'));
      await tester.pumpAndSettle();

      // It was a bare Column: no gutter, so the lines ran to both edges, and no
      // scroll, so a long receipt clipped its own total off the bottom.
      final scroller = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroller, findsOne);

      final sheet = tester.getRect(find.byType(BottomSheet));
      final line = tester.getRect(find.text('Jaffna Crab'));
      expect(
        line.left - sheet.left,
        greaterThanOrEqualTo(16),
        reason: 'the receipt should not run to the sheet edge',
      );
      expect(find.text('Total'), findsOne);
    });
  });

  group('polling costs battery, so it stops when nobody is looking', () {
    testWidgets('the tracker stops polling while backgrounded', (tester) async {
      final repository = FakeOrderRepository(
        orders: [OrderFixtures.order(status: CustomerOrderStatus.preparing)],
      );
      await tester.pumpWidget(_wrapOrders(repository));
      await tester.pump(const Duration(seconds: 2));

      final afterLoad = repository.loadCount;

      // Two poll intervals while foregrounded: the tracker keeps up.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      final whileVisible = repository.loadCount;
      expect(whileVisible, greaterThan(afterLoad));

      // Backgrounded. A suspended app making a request every thirty seconds on
      // mobile data is a battery and data cost for a screen nobody can see.
      // The full sequence a real device produces — resumed, inactive, hidden,
      // paused. `AppLifecycleListener` asserts on any other order.
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      expect(repository.loadCount, whileVisible);

      // Resuming reads once immediately, so the screen is not stale.
      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repository.loadCount, greaterThan(whileVisible));
    });
  });

  group("a customer's first order", () {
    test('appears the moment checkout says it was placed', () async {
      final repository = FakeOrderRepository(orders: const []);
      final orders = OrdersCubit(repository: repository);

      // The customer looks at Orders before ordering anything, which is what a
      // first-time customer does -- and finds it empty.
      await orders.load();
      expect(orders.state.isEmpty, isTrue);

      // They place an order from the Menu tab. The Orders tab is still alive
      // and still holding the empty list it loaded a minute ago.
      await repository.place(
        idempotencyKey: 'key-1',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
      );
      expect(orders.state.orders, isEmpty);

      // Checkout tells it. Silently, so nothing blanks on the way in.
      await orders.load(silent: true);

      expect(orders.state.orders, hasLength(1));
      expect(orders.state.live, hasLength(1));
      expect(orders.state.isEmpty, isFalse);
      await orders.close();
    });

    test('signing out takes the history with it', () async {
      final repository = FakeOrderRepository(
        orders: [OrderFixtures.order(id: '1', reference: '#0041')],
      );
      final orders = OrdersCubit(repository: repository);
      await orders.load();
      expect(orders.state.orders, hasLength(1));

      orders.clear();

      // A receipt carries an address and a phone number. The next person to
      // sign in on this phone must not find somebody else's.
      expect(orders.state.orders, isEmpty);
      await orders.close();
    });
  });
}

/// The orders screen with a repository in scope.
Widget _wrapOrders(OrderRepository repository) =>
    RepositoryProvider<OrderRepository>.value(
      value: repository,
      child: BlocProvider(
        create: (_) => OrdersCubit(repository: repository),
        child: MaterialApp(theme: AppTheme.light, home: const MyOrdersScreen()),
      ),
    );
