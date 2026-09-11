import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/orders/domain/payment_flow.dart';
import 'package:practice/features/orders/presentation/orders_cubit.dart';

import 'support/fake_order_repository.dart';

/// Card payment.
///
/// The rule everything here defends: **a closed sheet is not a payment**. The
/// app never decides that money moved — only the server, told by Worldpay's
/// webhook, can say that. Every test below is a way of getting that wrong.
void main() {
  late FakeOrderRepository repository;
  late List<String> opened;

  setUp(() {
    repository = FakeOrderRepository();
    opened = [];
  });

  PaymentFlow flowFor({CustomerPaymentStatus? settleAs}) => PaymentFlow(
    repository: repository,
    // The real schedule waits about half a minute for the webhook. The
    // behaviour under test is what happens at the end of it, not the waiting.
    pollSchedule: const [Duration.zero, Duration.zero],
    open: (url) async {
      opened.add(url);
      // Stands in for the customer doing something on Worldpay's page and the
      // webhook reaching our backend before the sheet closes.
      if (settleAs != null) repository.settlePayment('new-order', settleAs);
    },
  );

  /// Places a card order and approves it, which is what makes it payable.
  ///
  /// Approval is its own step now, so every payment test has to get past it.
  /// Done here rather than in each test because these tests are about what
  /// happens at the payment page, not about the restaurant's decision -- that
  /// is covered on its own above.
  Future<CustomerOrder> placeCardOrder() async {
    final order = await repository.place(
      idempotencyKey: 'key-1',
      isDelivery: false,
      lines: const [],
      contactName: 'Ali',
      contactPhone: '07700 900123',
      paymentMethod: PaymentMethod.card,
    );
    repository.approve(order.id);
    return repository.orders.firstWhere((o) => o.id == order.id);
  }

  group('the order model', () {
    test('an approved, unpaid card order owes money', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'awaiting_payment',
        'payment_method': 'card',
        'payment_status': 'pending',
        'payment_url': 'https://hpp-sandbox.worldpay.com/x',
      });

      expect(order.isCard, isTrue);
      expect(order.needsPayment, isTrue);
      expect(order.awaitingPayment, isTrue);
      expect(order.awaitingApproval, isFalse);
    });

    test('a brand new order is not payable until the restaurant approves', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'pending_approval',
        'payment_method': 'card',
        'payment_status': 'pending',
      });

      // Every order now starts here. Asking for a page at this point comes
      // back as ORDER_NOT_APPROVED, so there must be no Pay button to tap.
      expect(order.awaitingApproval, isTrue);
      expect(order.needsPayment, isFalse);
      expect(order.statusLabel, 'Waiting for approval');
      expect(order.statusExplanation, contains('approve'));
      expect(order.statusExplanation, isNot(contains('kitchen')));
    });

    test('a cash order waits for approval too, and never offers payment', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'pending_approval',
        'payment_method': 'cash',
        'payment_status': 'pending',
      });

      expect(order.awaitingApproval, isTrue);
      expect(order.needsPayment, isFalse);
      expect(order.statusLabel, 'Waiting for approval');
    });

    test('an approved cash order is with the kitchen', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'placed',
        'payment_method': 'cash',
        'payment_status': 'pending',
      });

      expect(order.awaitingApproval, isFalse);
      expect(order.needsPayment, isFalse);
      expect(order.statusLabel, 'Order confirmed');
      expect(order.statusExplanation, contains('kitchen'));
    });

    test('a refunded order is not asked to pay again', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'payment_method': 'card',
        'payment_status': 'refunded',
      });

      // Money moved and moved back. Showing "Pay" here would be asking for it
      // twice.
      expect(order.needsPayment, isFalse);
    });

    test('a cash order never has anything to pay online', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'payment_method': 'cash',
        'payment_status': 'pending',
      });

      expect(order.needsPayment, isFalse);
      expect(order.awaitingPayment, isFalse);
    });

    test('an unpaid card order is never described as being cooked', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'awaiting_payment',
        'payment_method': 'card',
        'payment_status': 'pending',
      });

      // The backend holds it out of the kitchen until the webhook lands, so
      // the placed-order copy would be a lie the customer acts on.
      expect(order.statusLabel, 'Payment needed');
      expect(
        order.statusExplanation,
        'Approved. Complete payment to submit your order.',
      );
      expect(order.statusExplanation, isNot(contains('kitchen')));
    });

    test('a declined card says so, and keeps the order', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'awaiting_payment',
        'payment_method': 'card',
        'payment_status': 'failed',
      });

      expect(order.statusLabel, 'Payment declined');
      expect(order.needsPayment, isTrue);
    });

    test('a declined card on an unapproved order is still not payable', () {
      // Belt and braces: the status gate wins over the payment gate, so a
      // stale `failed` on an order awaiting approval cannot resurrect Pay.
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'pending_approval',
        'payment_method': 'card',
        'payment_status': 'failed',
      });

      expect(order.needsPayment, isFalse);
    });

    test('a paid card order reads like any confirmed order', () {
      final order = CustomerOrder.fromJson(const {
        'id': '1',
        'status': 'preparing',
        'payment_method': 'card',
        'payment_status': 'paid',
        'paid_at': '2026-08-20T18:30:00Z',
      });

      expect(order.needsPayment, isFalse);
      expect(order.statusLabel, 'Being prepared');
      expect(order.paidAt, isNotNull);
    });
  });

  group('the approval step', () {
    test('a new order is not payable and offers no page', () async {
      final order = await repository.place(
        idempotencyKey: 'key-1',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
        paymentMethod: PaymentMethod.card,
      );

      // The whole point of the change: nothing is payable until a human at the
      // restaurant has said yes.
      expect(order.status, CustomerOrderStatus.pendingApproval);
      expect(order.paymentUrl, isNull);
      expect(order.needsPayment, isFalse);
    });

    test(
      'paying before approval is refused without calling the server',
      () async {
        final order = await repository.place(
          idempotencyKey: 'key-1',
          isDelivery: false,
          lines: const [],
          contactName: 'Ali',
          contactPhone: '07700 900123',
          paymentMethod: PaymentMethod.card,
        );
        final payCallsBefore = repository.payCalls;

        await expectLater(
          flowFor(settleAs: CustomerPaymentStatus.paid).payFor(order),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.code,
              'code',
              'ORDER_NOT_APPROVED',
            ),
          ),
        );
        // Refused locally: the backend would answer the same way, and a request
        // we already know the answer to is one not worth making.
        expect(repository.payCalls, payCallsBefore);
      },
    );

    test('approval makes a card order payable', () async {
      final order = await placeCardOrder();

      expect(order.status, CustomerOrderStatus.awaitingPayment);
      expect(order.needsPayment, isTrue);
      expect(order.paymentUrl, isNotNull);
    });

    test('approval sends a cash order straight to the kitchen', () async {
      final placed = await repository.place(
        idempotencyKey: 'key-2',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
      );
      expect(placed.status, CustomerOrderStatus.pendingApproval);

      repository.approve(placed.id);
      final approved = repository.orders.firstWhere((o) => o.id == placed.id);

      expect(approved.status, CustomerOrderStatus.placed);
      expect(approved.needsPayment, isFalse);
      expect(approved.paymentUrl, isNull);
    });
  });

  group('cancelling', () {
    CustomerOrder at(String status, {bool? canCancel}) =>
        CustomerOrder.fromJson({
          'id': '1',
          'status': status,
          'payment_method': 'card',
          'payment_status': 'pending',
          'can_cancel': ?canCancel,
        });

    test('the server flag is what decides', () {
      // The guide says to use `can_cancel` rather than reproducing the rule,
      // because the server knows things the app cannot.
      expect(at('placed', canCancel: false).canCancel, isFalse);
      expect(at('preparing', canCancel: true).canCancel, isTrue);
    });

    test('an order waiting for approval can still be cancelled', () {
      // This is the regression the approval step introduced: an order now
      // starts here and can sit here for minutes, and the old rule -- cancel
      // only while `placed` -- took the button away for that whole window.
      expect(at('pending_approval').canCancel, isTrue);
      expect(at('awaiting_payment').canCancel, isTrue);
      expect(at('placed').canCancel, isTrue);
    });

    test(
      'cooking has started, so it is a conversation rather than a button',
      () {
        for (final status in ['preparing', 'ready', 'completed', 'cancelled']) {
          expect(at(status).canCancel, isFalse, reason: status);
        }
      },
    );
  });

  group('the payment flow', () {
    test('opens the page the server gave and then asks the server', () async {
      final order = await placeCardOrder();
      final settled = await flowFor(
        settleAs: CustomerPaymentStatus.paid,
      ).payFor(order);

      expect(opened, ['https://hpp-sandbox.worldpay.com/test-page']);
      expect(settled.isPaid, isTrue);
    });

    test('a sheet closed without paying leaves the order unpaid', () async {
      final order = await placeCardOrder();

      // The sheet closes and nothing else happens — no webhook, no payment.
      final settled = await flowFor().payFor(order);

      expect(opened, hasLength(1));
      // This is the whole point: the flow reports what the server says, and
      // the server says nobody paid.
      expect(settled.isPaid, isFalse);
      expect(settled.needsPayment, isTrue);
    });

    test('asks for a page when the order was placed without one', () async {
      repository.payUrl = 'https://hpp-sandbox.worldpay.com/fresh-page';
      // Worldpay was unreachable at placement: the order exists, with no page.
      final order = CustomerOrder.fromJson(const {
        'id': 'new-order',
        'payment_method': 'card',
        'payment_status': 'pending',
      });
      repository.orders = [order];

      await flowFor(settleAs: CustomerPaymentStatus.paid).payFor(order);

      expect(repository.payCalls, 1);
      expect(opened, ['https://hpp-sandbox.worldpay.com/fresh-page']);
    });

    test('a page that cannot be obtained is an error, not a payment', () async {
      repository.payUrl = null;
      final order = CustomerOrder.fromJson(const {
        'id': 'new-order',
        'payment_method': 'card',
        'payment_status': 'pending',
      });
      repository.orders = [order];

      // The message must not blame the customer or send them round the same
      // loop, and must say the order survived -- it did.
      await expectLater(
        flowFor().payFor(order),
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('unavailable'),
              contains('saved'),
              isNot(contains('try again')),
            ),
          ),
        ),
      );
      expect(opened, isEmpty);
      // Asked once for a page before giving up, rather than assuming.
      expect(repository.payCalls, 1);
    });
  });

  test('refuses a payment link that is not https', () async {
    for (final hostile in [
      'javascript:alert(1)',
      'intent://evil#Intent;scheme=http;end',
      'file:///etc/passwd',
      'http://hpp-sandbox.worldpay.com/x',
    ]) {
      repository.payUrl = hostile;
      final order = CustomerOrder.fromJson({
        'id': 'new-order',
        'payment_method': 'card',
        'payment_status': 'pending',
        'payment_url': hostile,
      });
      repository.orders = [order];

      // launchUrl opens whatever scheme it is handed, so a tampered response
      // could otherwise become an arbitrary launch on the customer's phone.
      await expectLater(
        flowFor().payFor(order),
        throwsA(isA<ApiFailure>()),
        reason: hostile,
      );
    }
    expect(opened, isEmpty);
  });

  group('paying from the orders screen', () {
    test('a successful payment updates that order and nothing else', () async {
      await placeCardOrder();
      final cubit = OrdersCubit(
        repository: repository,
        paymentFlow: flowFor(settleAs: CustomerPaymentStatus.paid),
      );
      await cubit.load();

      final message = await cubit.payOrder('new-order');

      expect(message, isNull);
      expect(cubit.state.orders.single.isPaid, isTrue);
      expect(cubit.state.payingId, isNull);
      await cubit.close();
    });

    test('a decline is reported as retryable, not as a lost order', () async {
      await placeCardOrder();
      final cubit = OrdersCubit(
        repository: repository,
        paymentFlow: flowFor(settleAs: CustomerPaymentStatus.failed),
      );
      await cubit.load();

      final message = await cubit.payOrder('new-order');

      expect(message, contains('declined'));
      expect(message, contains('try again'));
      // The order survives a decline — losing it would mean re-entering
      // everything, and the backend keeps it precisely so that is not needed.
      expect(cubit.state.orders.single.needsPayment, isTrue);
      await cubit.close();
    });

    test(
      'an unconfirmed payment says so rather than claiming either',
      () async {
        await placeCardOrder();
        final cubit = OrdersCubit(
          repository: repository,
          paymentFlow: flowFor(),
        );
        await cubit.load();

        final message = await cubit.payOrder('new-order');

        // Neither "paid" nor "failed": the webhook has not landed, and the
        // backend will resolve it either way.
        expect(message, contains('still confirming'));
        await cubit.close();
      },
    );

    test('a cash order is never sent to a payment page', () async {
      await repository.place(
        idempotencyKey: 'key-2',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
      );
      final cubit = OrdersCubit(
        repository: repository,
        paymentFlow: flowFor(settleAs: CustomerPaymentStatus.paid),
      );
      await cubit.load();

      expect(await cubit.payOrder('new-order'), isNull);
      expect(opened, isEmpty);
      expect(repository.payCalls, 0);
      await cubit.close();
    });
  });
}
