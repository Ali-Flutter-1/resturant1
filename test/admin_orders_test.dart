import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/admin/domain/admin_order.dart';
import 'package:practice/features/admin/domain/admin_order_repository.dart';
import 'package:practice/features/admin/presentation/admin_orders_cubit.dart';
import 'package:practice/features/admin/presentation/admin_orders_screen.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_admin_order_repository.dart';

/// The kitchen queue and the documented status machine.
///
/// The machine is where a mistake is expensive: an illegal move is a 409, and a
/// row that advanced locally and then failed has the kitchen believing food is
/// on the counter when it is not.
void main() {
  late FakeAdminOrderRepository repository;

  setUp(() {
    repository = FakeAdminOrderRepository();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 1800);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  Widget wrap() => MultiBlocProvider(
    providers: [
      BlocProvider(create: (_) => AuthFixtures.cubit(AuthFixtures.staff)),
    ],
    child: RepositoryProvider<AdminOrderRepository>.value(
      value: repository,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const AdminOrdersScreen(),
      ),
    ),
  );

  group('the approval step', () {
    AdminOrder pending({bool card = false}) => AdminOrder(
      id: 'p1',
      orderNumber: 'ZZ99',
      status: OrderStatus.pendingApproval,
      fulfilment: FulfilmentType.collection,
      paymentStatus: PaymentStatus.pending,
      isCard: card,
      totalPence: 1200,
      itemCount: 1,
      isAsap: true,
      placedAt: DateTime(2026, 9, 11, 18, 30),
      contactName: 'Ali Hassan',
      contactPhone: '07700 900123',
    );

    test(
      'the approvals queue is asked for by status, not filtered locally',
      () async {
        final repository = FakeAdminOrderRepository(
          orders: [pending(), ...FakeAdminOrderRepository.defaults],
        );
        final cubit = AdminOrdersCubit(repository: repository);
        await cubit.load();

        await cubit.filterBy(OrderStatus.pendingApproval);

        // Asked for, because the queue is paginated -- a view built by
        // filtering the loaded page would be missing the orders on page two.
        expect(repository.lastFilter, OrderStatus.pendingApproval);
        expect(repository.lastOpenOnly, isFalse);
        expect(cubit.state.orders.single.status, OrderStatus.pendingApproval);
        await cubit.close();
      },
    );

    test('the chip counts what is waiting', () async {
      final repository = FakeAdminOrderRepository(
        orders: [pending(), ...FakeAdminOrderRepository.defaults],
      );
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      // Counted from the page when the backend reports no figure of its own.
      expect(cubit.state.waitingForApproval, 1);
      await cubit.close();
    });

    test('a backend that reports the count is believed over the page', () {
      const state = AdminOrdersState(
        stats: OrderStats(pendingApproval: 12),
        orders: [],
      );
      // The server's number covers every page; a local count never can.
      expect(state.waitingForApproval, 12);
    });

    test('no count at all is shown as nothing rather than as zero', () {
      const state = AdminOrdersState(stats: OrderStats(), orders: []);
      // Absent and none are different: a confident "0 waiting" that is wrong
      // is worse than no badge.
      expect(state.waitingForApproval, isNull);
    });

    test('an order awaiting approval offers no status moves at all', () {
      // Approve and decline are their own endpoints. A status PATCH out of
      // this state is refused, so a button for one would be a 409 waiting to
      // be tapped.
      for (final type in FulfilmentType.values) {
        expect(
          OrderTransitions.nextFor(OrderStatus.pendingApproval, type),
          isEmpty,
        );
      }
      expect(OrderStatus.pendingApproval.needsApproval, isTrue);
      expect(OrderStatus.pendingApproval.isOpen, isTrue);
    });

    test('approving a cash order sends it to the kitchen', () async {
      final repository = FakeAdminOrderRepository(orders: [pending()]);
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      expect(await cubit.approve('p1'), isNull);

      expect(repository.approved, ['p1']);
      // The dedicated endpoint, not a status change smuggled through PATCH.
      expect(repository.lastStatusChange, isNull);
      expect(cubit.state.orders.single.status, OrderStatus.placed);
      await cubit.close();
    });

    test('approving a card order makes it payable, not cooked', () async {
      final repository = FakeAdminOrderRepository(
        orders: [pending(card: true)],
      );
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      await cubit.approve('p1');

      // The kitchen gets it only once the money clears.
      expect(cubit.state.orders.single.status, OrderStatus.awaitingPayment);
      await cubit.close();
    });

    test('declining sends the reason the customer is shown', () async {
      final repository = FakeAdminOrderRepository(orders: [pending()]);
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      expect(await cubit.decline('p1', reason: 'Kitchen closed early'), isNull);

      expect(repository.lastDecline, {
        'id': 'p1',
        'reason': 'Kitchen closed early',
      });
      // A declined order is finished, so it leaves the open queue the screen
      // defaults to -- the same way a completed one does.
      expect(cubit.state.orders, isEmpty);
      await cubit.close();
    });

    test('an order already decided is refused without a round trip', () async {
      final repository = FakeAdminOrderRepository();
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      // `o1` is already placed. Another member of staff got there first.
      final message = await cubit.approve('o1');

      expect(message, isNotNull);
      expect(repository.approved, isEmpty);
      await cubit.close();
    });

    test('a conflict re-reads the order rather than arguing with it', () async {
      final repository = FakeAdminOrderRepository(orders: [pending()])
        ..statusFailure = const ApiFailure(
          kind: ApiFailureKind.conflict,
          code: 'ORDER_NOT_PENDING_APPROVAL',
          message: 'Somebody already decided this one.',
        );
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      final message = await cubit.approve('p1');

      expect(message, 'Somebody already decided this one.');
      // Nothing is left spinning.
      expect(cubit.state.busyIds, isEmpty);
      await cubit.close();
    });
  });

  group('the documented status machine', () {
    test('a collection order completes straight from ready', () {
      expect(
        OrderTransitions.nextFor(OrderStatus.ready, FulfilmentType.collection),
        [OrderStatus.completed],
      );
      // Collection cannot enter out_for_delivery.
      expect(
        OrderTransitions.allows(
          OrderStatus.ready,
          OrderStatus.outForDelivery,
          FulfilmentType.collection,
        ),
        isFalse,
      );
    });

    test('a delivery order must go out before it completes', () {
      expect(
        OrderTransitions.nextFor(OrderStatus.ready, FulfilmentType.delivery),
        [OrderStatus.outForDelivery],
      );
      // Delivery cannot complete directly from ready.
      expect(
        OrderTransitions.allows(
          OrderStatus.ready,
          OrderStatus.completed,
          FulfilmentType.delivery,
        ),
        isFalse,
      );
      expect(
        OrderTransitions.nextFor(
          OrderStatus.outForDelivery,
          FulfilmentType.delivery,
        ),
        [OrderStatus.completed],
      );
    });

    test('placed can be rejected or cancelled; preparing only cancelled', () {
      expect(
        OrderTransitions.nextFor(OrderStatus.placed, FulfilmentType.delivery),
        containsAll(<OrderStatus>[
          OrderStatus.preparing,
          OrderStatus.rejected,
          OrderStatus.cancelled,
        ]),
      );
      final fromPreparing = OrderTransitions.nextFor(
        OrderStatus.preparing,
        FulfilmentType.delivery,
      );
      expect(fromPreparing, contains(OrderStatus.cancelled));
      expect(fromPreparing, isNot(contains(OrderStatus.rejected)));
    });

    test('nothing moves out of a final status', () {
      for (final status in [
        OrderStatus.completed,
        OrderStatus.cancelled,
        OrderStatus.rejected,
      ]) {
        expect(status.isFinal, isTrue);
        expect(
          OrderTransitions.nextFor(status, FulfilmentType.delivery),
          isEmpty,
        );
      }
    });

    test('skipping a step is not allowed', () {
      expect(
        OrderTransitions.allows(
          OrderStatus.placed,
          OrderStatus.ready,
          FulfilmentType.delivery,
        ),
        isFalse,
      );
    });

    test('an unrecognised status decodes rather than crashing', () {
      final order = AdminOrder.fromJson({
        'id': 'o9',
        'order_number': 'ZZ99',
        'status': 'awaiting_courier',
        'fulfilment_type': 'delivery',
      });

      expect(order.status, OrderStatus.unknown);
      // The raw value survives for logging, as the guide asks.
      expect(order.rawStatus, 'awaiting_courier');
      expect(order.nextStatuses, isEmpty);
    });
  });

  group('AdminOrder.fromJson', () {
    test('reads the documented shape', () {
      final order = AdminOrder.fromJson({
        'id': 'o1',
        'order_number': 'AB12-CD34',
        'status': 'placed',
        'fulfilment_type': 'delivery',
        'payment_status': 'pending',
        'total_pence': 2089,
        'item_count': 2,
        'is_asap': false,
        'requested_for': '2026-08-12T19:15:00Z',
        'placed_at': '2026-08-12T18:30:00Z',
        'address_line1': '12 Example Street',
        'city': 'Manchester',
        'postcode': 'M1 2AB',
        'items': [
          {
            'name': 'Chicken Kottu',
            'quantity': 2,
            'line_total_pence': 1790,
            'notes': 'No coriander',
          },
        ],
      });

      expect(order.status, OrderStatus.placed);
      expect(order.fulfilment, FulfilmentType.delivery);
      // Formatted from integer pence without touching floating point.
      expect(order.formattedTotal, '£20.89');
      expect(order.address, '12 Example Street, Manchester, M1 2AB');
      expect(order.lines.single.notes, 'No coriander');
      expect(order.isAsap, isFalse);
    });

    test('a collection order has no address to show', () {
      final order = AdminOrder.fromJson({
        'id': 'o1',
        'order_number': 'AB12',
        'status': 'placed',
        'fulfilment_type': 'collection',
        'address_line1': 'ignored',
        'city': 'ignored',
      });
      // The API ignores address fields for collection, so the ticket should not
      // print one.
      expect(order.address, isNull);
    });
  });

  group('the queue', () {
    testWidgets('opens on the kitchen queue', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      // `open_only` by default: a completed order is noise on a screen whose
      // job is "what do we cook next".
      expect(repository.lastOpenOnly, isTrue);
      expect(find.text('AB12-CD34'), findsOne);
      expect(find.text('EF56-GH78'), findsOne);
    });

    testWidgets('shows the day counters', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      expect(repository.statsCalls, greaterThanOrEqualTo(1));
      // The strip scrolls, so only the leading tiles are built on a 390pt
      // screen — "Open" is the one that always is.
      expect(find.text('OPEN'), findsOne);
      expect(find.text('2'), findsWidgets);
    });

    test('revenue is formatted from integer pence', () {
      const stats = OrderStats(revenueTodayPence: 4560);
      // No floating point anywhere near money.
      expect(stats.formattedRevenue, '£45.60');
      expect(const OrderStats(revenueTodayPence: 5).formattedRevenue, '£0.05');
    });

    testWidgets('one tap advances an order along its own path', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      // A placed order's next step is preparing.
      await tester.tap(find.text('Mark cooking').first);
      await tester.pump(const Duration(seconds: 2));

      expect(repository.lastStatusChange?['id'], 'o1');
      expect(repository.lastStatusChange?['status'], 'preparing');
    });

    testWidgets('a collection order at ready offers completed, not out', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      // EF56-GH78 is collection and ready.
      expect(find.text('Mark completed'), findsOne);
      expect(find.text('Mark out for delivery'), findsNothing);
    });

    testWidgets('the row shows what the server confirmed, never a guess', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      repository.statusFailure = const ApiFailure(
        kind: ApiFailureKind.server,
        message: 'The kitchen system is not responding.',
        code: 'SERVICE_UNAVAILABLE',
      );
      await tester.tap(find.text('Mark cooking').first);
      await tester.pump(const Duration(seconds: 2));

      // Still placed. A row that flipped locally and then failed would have the
      // kitchen believing an order was being cooked.
      expect(find.text('The kitchen system is not responding.'), findsOne);
      expect(find.text('Mark cooking'), findsWidgets);
    });

    testWidgets('a filter asks the API rather than trimming the page', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      await context(tester).filterBy(OrderStatus.ready);
      await tester.pump(const Duration(seconds: 2));

      expect(repository.lastFilter, OrderStatus.ready);
      expect(find.text('AB12-CD34'), findsNothing);
      expect(find.text('EF56-GH78'), findsOne);
    });

    testWidgets('search narrows what is loaded', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      await tester.enterText(
        find.widgetWithText(TextField, 'Search order number, name or phone...'),
        'priya',
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('AB12-CD34'), findsNothing);
      expect(find.text('EF56-GH78'), findsOne);
    });

    testWidgets('shows the API message when the queue will not load', (
      tester,
    ) async {
      repository.failure = ApiFailure.offline;
      await tester.pumpWidget(wrap());
      await tester.pump(const Duration(seconds: 2));

      expect(find.text(ApiFailure.offline.message), findsOne);
    });

    testWidgets('an empty queue reads as done, not broken', (tester) async {
      await tester.pumpWidget(
        RepositoryProvider<AdminOrderRepository>.value(
          value: FakeAdminOrderRepository(orders: []),
          child: MultiBlocProvider(
            providers: [
              BlocProvider(
                create: (_) => AuthFixtures.cubit(AuthFixtures.staff),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light,
              home: const AdminOrdersScreen(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Nothing waiting'), findsOne);
    });
  });

  group('the cubit', () {
    test('refuses an illegal move without asking the API', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      // o2 is collection and ready — out_for_delivery is not on its path.
      final error = await cubit.changeStatus('o2', OrderStatus.outForDelivery);

      expect(error, isNotNull);
      expect(repository.lastStatusChange, isNull);
    });

    test('a completed order leaves the kitchen queue', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      expect(cubit.state.orders, hasLength(2));

      await cubit.changeStatus('o2', OrderStatus.completed);

      // The queue means "still to do", so a finished order is not in it.
      expect(cubit.state.orders.map((o) => o.id), ['o1']);
    });

    test('a completed order stays in the full history', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      await cubit.showOpenOnly(false);

      await cubit.changeStatus('o2', OrderStatus.completed);

      expect(cubit.state.orders, hasLength(2));
      expect(
        cubit.state.orders.firstWhere((o) => o.id == 'o2').status,
        OrderStatus.completed,
      );
    });

    test('a conflict re-reads the order rather than arguing with it', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      repository.statusFailure = const ApiFailure(
        kind: ApiFailureKind.conflict,
        message: 'Somebody already moved this order on.',
        code: 'INVALID_STATUS_TRANSITION',
      );
      final error = await cubit.changeStatus('o1', OrderStatus.preparing);

      // A 409 means this screen is the stale one, so the fix is to refetch.
      expect(error, 'Somebody already moved this order on.');
      expect(
        cubit.state.orders.firstWhere((o) => o.id == 'o1').status,
        OrderStatus.placed,
      );
    });

    test('the counters are refreshed after a move', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      final before = repository.statsCalls;

      await cubit.changeStatus('o1', OrderStatus.preparing);

      // Completing an order changes the day's revenue, so stale tiles above a
      // fresh queue would contradict it.
      expect(repository.statsCalls, greaterThan(before));
    });

    test('a cancellation carries the reason the customer is told', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      await cubit.changeStatus(
        'o1',
        OrderStatus.rejected,
        note: 'Kitchen closed early',
      );

      expect(repository.lastStatusChange?['note'], 'Kitchen closed early');
    });
  });

  group('the detail sheet survives the queue refreshing under it', () {
    test('a poll that drops the order from the list keeps the sheet', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      final order = cubit.state.orders.first;
      await cubit.openDetail(order);
      expect(cubit.state.detail?.id, order.id);

      // The order leaves the filtered list — completed, or simply past the first
      // page. This is exactly what the 20-second poll does every time.
      repository.replaceListWith(const []);
      await cubit.load(silent: true);

      expect(cubit.state.orders, isEmpty);
      // The ticket is still there. It used to be looked up in `orders`, so this
      // wiped it and the sheet went blank mid-read.
      expect(cubit.state.detail?.id, order.id);
      await cubit.close();
    });

    test('advancing an order updates the open sheet', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      final order = cubit.state.orders.firstWhere(
        (o) => o.status == OrderStatus.placed,
      );
      await cubit.openDetail(order);

      await cubit.changeStatus(order.id, OrderStatus.preparing);
      // Otherwise the ticket keeps showing the status it had when it opened.
      expect(cubit.state.detail?.status, OrderStatus.preparing);
      await cubit.close();
    });

    test('closing drops it, so the next open starts clean', () async {
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      await cubit.openDetail(cubit.state.orders.first);

      cubit.closeDetail();
      expect(cubit.state.detail, isNull);
      await cubit.close();
    });
  });
}

/// Reaches the cubit for the filter test, which has no on-screen control that a
/// 390pt viewport can bring into view reliably.
AdminOrdersCubit context(WidgetTester tester) =>
    BlocProvider.of<AdminOrdersCubit>(
      tester.element(find.byType(RefreshIndicator)),
    );
