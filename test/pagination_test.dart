import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/network/page_data.dart';
import 'package:practice/features/admin/domain/admin_order.dart';
import 'package:practice/features/admin/presentation/admin_orders_cubit.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/orders/presentation/orders_cubit.dart';

import 'support/fake_admin_order_repository.dart';
import 'support/fake_order_repository.dart';

/// Enough rows to need more than one page at the default size.
List<CustomerOrder> _history(int count) => [
  for (var i = 0; i < count; i++)
    CustomerOrder(
      id: 'o$i',
      reference: 'REF$i',
      status: CustomerOrderStatus.completed,
      totalPence: 1000 + i,
      placedAt: DateTime(2026, 9, 1).subtract(Duration(days: i)),
    ),
];

List<AdminOrder> _queue(int count) => [
  for (var i = 0; i < count; i++)
    AdminOrder(
      id: 'q$i',
      orderNumber: 'Q$i',
      status: OrderStatus.placed,
      fulfilment: FulfilmentType.collection,
      paymentStatus: PaymentStatus.pending,
      totalPence: 1000,
      itemCount: 1,
      isAsap: true,
      placedAt: DateTime(2026, 9, 11, 18, 30),
    ),
];

void main() {
  group('PageData', () {
    test('knows when there is another page', () {
      const first = PageData<int>(items: [1], page: 1, totalPages: 3);
      const last = PageData<int>(items: [1], page: 3, totalPages: 3);
      expect(first.hasMore, isTrue);
      expect(last.hasMore, isFalse);
    });

    test('an empty result never invites a request for page one', () {
      // `total_pages` is 0 for nothing at all, and 1 < 0 is false -- so this
      // has to be false rather than "page 1 of 0 pages, fetch it".
      const empty = PageData<int>(items: [], page: 1, totalPages: 0);
      expect(empty.hasMore, isFalse);
    });
  });

  group('order history', () {
    test('opens on the first page and knows more exists', () async {
      final repository = FakeOrderRepository()..orders = _history(45);
      final cubit = OrdersCubit(repository: repository);

      await cubit.load();

      expect(cubit.state.orders, hasLength(20));
      expect(cubit.state.page, 1);
      expect(cubit.state.hasMore, isTrue);
      await cubit.close();
    });

    test('load more appends rather than replacing', () async {
      final repository = FakeOrderRepository()..orders = _history(45);
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      await cubit.loadMore();

      // Appended: a reader part-way down last month's receipts must not have
      // the list rebuilt under their thumb.
      expect(repository.lastPageAsked, 2);
      expect(cubit.state.orders, hasLength(40));
      expect(cubit.state.orders.first.id, 'o0');
      expect(cubit.state.orders.last.id, 'o39');
      expect(cubit.state.hasMore, isTrue);
      await cubit.close();
    });

    test('the last page ends the sequence', () async {
      final repository = FakeOrderRepository()..orders = _history(25);
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      await cubit.loadMore();

      expect(cubit.state.orders, hasLength(25));
      expect(cubit.state.hasMore, isFalse);
      // And asking again does nothing rather than re-fetching the last page.
      final calls = repository.loadCount;
      await cubit.loadMore();
      expect(repository.loadCount, calls);
      await cubit.close();
    });

    test('a failed page keeps the ones already read', () async {
      final repository = FakeOrderRepository()..orders = _history(45);
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      repository.failure = const ApiFailure(
        kind: ApiFailureKind.offline,
        message: 'Offline.',
      );
      await cubit.loadMore();

      // Failing to fetch page two is no reason to take page one away.
      expect(cubit.state.orders, hasLength(20));
      expect(cubit.state.loadingMore, isFalse);
      expect(cubit.state.failure, isNotNull);
      await cubit.close();
    });

    test('two taps of load more do not fetch the same page twice', () async {
      final repository = FakeOrderRepository()..orders = _history(60);
      final cubit = OrdersCubit(repository: repository);
      await cubit.load();

      await Future.wait([cubit.loadMore(), cubit.loadMore()]);

      expect(cubit.state.orders, hasLength(40));
      await cubit.close();
    });
  });

  group('the staff queue', () {
    test('pages through a long service', () async {
      final repository = FakeAdminOrderRepository(orders: _queue(50));
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();

      expect(cubit.state.orders, hasLength(20));
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();

      expect(repository.lastPageAsked, 2);
      expect(cubit.state.orders, hasLength(40));
      await cubit.close();
    });

    test('a poll does not yank a scrolled queue back to page one', () async {
      final repository = FakeAdminOrderRepository(orders: _queue(50));
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      await cubit.loadMore();
      expect(cubit.state.orders, hasLength(40));

      // The twenty-second poll. Page one is re-read for status changes; the
      // pages already loaded behind it stay where they are.
      await cubit.load(silent: true);

      expect(cubit.state.orders, hasLength(40));
      expect(cubit.state.page, 2);
      await cubit.close();
    });

    test(
      'a poll shows no row twice, even if one moved between pages',
      () async {
        final repository = FakeAdminOrderRepository(orders: _queue(50));
        final cubit = AdminOrdersCubit(repository: repository);
        await cubit.load();
        await cubit.loadMore();

        await cubit.load(silent: true);

        final ids = cubit.state.orders.map((o) => o.id).toList();
        expect(ids.toSet(), hasLength(ids.length));
        await cubit.close();
      },
    );

    test('changing the filter starts again from page one', () async {
      final repository = FakeAdminOrderRepository(orders: _queue(50));
      final cubit = AdminOrdersCubit(repository: repository);
      await cubit.load();
      await cubit.loadMore();

      await cubit.filterBy(OrderStatus.placed);

      // A different question deserves a fresh answer, not the old pages with
      // new ones appended.
      expect(cubit.state.page, 1);
      expect(cubit.state.orders, hasLength(20));
      await cubit.close();
    });
  });
}
