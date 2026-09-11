import 'dart:async';

import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/network/page_data.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/orders/domain/order_quote.dart';
import 'package:practice/features/orders/domain/order_repository.dart';

/// An [OrderRepository] that answers from memory.
///
/// [failure] makes every call fail, so the error and retry paths can be driven
/// without a network. [cancelFailure] fails only the cancellation, which is the
/// case that matters most: cancelling races the kitchen, so the screen must
/// handle a refusal.
class FakeOrderRepository implements OrderRepository {
  FakeOrderRepository({
    List<CustomerOrder>? orders,
    this.failure,
    this.cancelFailure,
  }) : orders = orders ?? [];

  List<CustomerOrder> orders;
  ApiFailure? failure;
  ApiFailure? cancelFailure;

  int loadCount = 0;
  final cancelled = <String>[];

  /// What the customer typed, in call order. Null where they said nothing.
  final cancelReasons = <String?>[];

  /// What a quote answers with. Set by a test that cares.
  ///
  /// The slots are relative to now, not fixed dates. They used to be pinned to
  /// 2026-08-12, which meant the screen labelled them "Today" only while the
  /// calendar agreed — the timing tests passed on the day they were written and
  /// silently started failing afterwards.
  OrderQuote quoteResult = OrderQuote(
    subtotalPence: 1790,
    deliveryFeePence: 299,
    totalPence: 2089,
    minimumOrderPence: 1000,
    availableSlots: [
      slotIn(const Duration(hours: 2)),
      slotIn(const Duration(hours: 2, minutes: 15)),
    ],
  );

  /// An ISO slot [ahead] from now, with an offset, exactly as the API sends it.
  static String slotIn(Duration ahead) =>
      DateTime.now().toUtc().add(ahead).toIso8601String();

  /// Fails only the quote, so a test can price fine and be refused on placing.
  ApiFailure? quoteFailure;
  ApiFailure? placeFailure;

  int quoteCalls = 0;

  /// What the last quote was priced for. Null for collection, which needs no
  /// postcode and must not send one.
  String? lastQuotePostcode;
  int placeCalls = 0;
  bool? lastQuoteDelivery;

  /// Every key a placement was attempted with, in order. The interesting
  /// assertion is that a retry reuses the first one.
  final idempotencyKeys = <String>[];
  Map<String, Object?>? lastPlaced;

  /// The page a card order is handed, and how many times one was asked for.
  String? payUrl = 'https://hpp-sandbox.worldpay.com/test-page';
  int payCalls = 0;
  ApiFailure? payFailure;

  @override
  Future<CustomerOrder> pay(String id) async {
    payCalls++;
    final error = payFailure ?? failure;
    if (error != null) throw error;
    final existing = orders.firstWhere((o) => o.id == id);
    return existing.paymentUrl != null
        ? existing
        : _replace(existing, paymentUrl: payUrl);
  }

  /// Stands in for the server settling a payment, so a test can say what the
  /// webhook decided.
  /// Skips the approval step, so a test about *payment* does not have to
  /// rehearse the restaurant's decision first.
  ///
  /// Off by default on purpose: the default has to be what the backend
  /// actually does, or the fake quietly re-blesses the behaviour it was
  /// supposed to be checking.
  bool placesAsApproved = false;

  /// Approves an order the way an admin would: a cash order goes to the
  /// kitchen, a card order becomes payable.
  void approve(String id) {
    orders = [
      for (final order in orders)
        if (order.id == id)
          _replace(
            order,
            status: order.isCard
                ? CustomerOrderStatus.awaitingPayment
                : CustomerOrderStatus.placed,
            paymentUrl: order.isCard ? payUrl : null,
          )
        else
          order,
    ];
  }

  void settlePayment(String id, CustomerPaymentStatus status) {
    final existing = orders.firstWhere((o) => o.id == id);
    orders = [
      for (final o in orders)
        if (o.id == id)
          _replace(
            existing,
            paymentStatus: status,
            // The server nulls the page once there is nothing left to pay.
            clearUrl: status != CustomerPaymentStatus.pending,
            paidAt: status == CustomerPaymentStatus.paid
                ? DateTime.now()
                : null,
          )
        else
          o,
    ];
  }

  CustomerOrder _replace(
    CustomerOrder order, {
    String? paymentUrl,
    CustomerPaymentStatus? paymentStatus,
    DateTime? paidAt,
    CustomerOrderStatus? status,
    bool clearUrl = false,
  }) => CustomerOrder(
    id: order.id,
    reference: order.reference,
    status: status ?? order.status,
    totalPence: order.totalPence,
    placedAt: order.placedAt,
    items: order.items,
    isDelivery: order.isDelivery,
    canCancel: order.canCancel,
    paymentMethod: order.paymentMethod,
    paymentStatus: paymentStatus ?? order.paymentStatus,
    paymentUrl: clearUrl ? null : (paymentUrl ?? order.paymentUrl),
    paidAt: paidAt ?? order.paidAt,
  );

  @override
  Future<OrderQuote> quote({
    required bool isDelivery,
    required List<CartLine> lines,
    String? postcode,
  }) async {
    quoteCalls++;
    lastQuoteDelivery = isDelivery;
    lastQuotePostcode = postcode;
    final error = quoteFailure ?? failure;
    if (error != null) throw error;
    return quoteResult;
  }

  @override
  Future<CustomerOrder> place({
    required String idempotencyKey,
    required bool isDelivery,
    required List<CartLine> lines,
    required String contactName,
    required String contactPhone,
    PaymentMethod paymentMethod = PaymentMethod.cash,
    bool isAsap = true,
    String? requestedFor,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? postcode,
    String? deliveryNotes,
    String? customerNote,
  }) async {
    placeCalls++;
    idempotencyKeys.add(idempotencyKey);
    lastPlaced = {
      'is_delivery': isDelivery,
      'items': [for (final line in lines) line.toJson()],
      'contact_name': contactName,
      'contact_phone': contactPhone,
      'payment_method': paymentMethod.wire,
      'is_asap': isAsap,
      'requested_for': requestedFor,
      'address_line1': addressLine1,
      'city': city,
      'postcode': postcode,
      'customer_note': customerNote,
    };

    final error = placeFailure ?? failure;
    if (error != null) throw error;

    // What the real backend does now: every order, cash or card, starts at
    // `pending_approval` with no payment page. The restaurant decides first.
    final placed = CustomerOrder(
      id: 'new-order',
      reference: 'AB12-CD34',
      status: placesAsApproved
          ? (paymentMethod == PaymentMethod.card
                ? CustomerOrderStatus.awaitingPayment
                : CustomerOrderStatus.placed)
          : CustomerOrderStatus.pendingApproval,
      totalPence: quoteResult.totalPence,
      placedAt: DateTime(2026, 8, 12, 18, 30),
      isDelivery: isDelivery,
      canCancel: true,
      paymentMethod: paymentMethod,
      paymentUrl: placesAsApproved && paymentMethod == PaymentMethod.card
          ? payUrl
          : null,
    );
    orders = [placed, ...orders];
    return placed;
  }

  @override
  Future<PageData<CustomerOrder>> myOrders({
    int page = 1,
    int pageSize = 20,
  }) async {
    loadCount++;
    lastPageAsked = page;
    if (failure != null) throw failure!;

    // Sliced for real, so a test about pagination is testing pagination
    // rather than a fake that hands back everything whatever it is asked.
    final start = (page - 1) * pageSize;
    final slice = start >= orders.length
        ? const <CustomerOrder>[]
        : orders.sublist(start, (start + pageSize).clamp(0, orders.length));
    return PageData(
      items: slice,
      page: page,
      pageSize: pageSize,
      total: orders.length,
      totalPages: (orders.length / pageSize).ceil(),
    );
  }

  /// The page number of the last request, so a test can assert that "load
  /// more" asked for the next one rather than re-fetching the first.
  int? lastPageAsked;

  @override
  Future<CustomerOrder> orderById(String id) async {
    orderByIdCalls++;
    // Held open so a test can tap again while the first fetch is in flight,
    // which is exactly when a second sheet used to appear.
    if (detailGate != null) await detailGate!.future;
    if (failure != null) throw failure!;
    return orders.firstWhere((order) => order.id == id);
  }

  int orderByIdCalls = 0;

  /// Completed by the test to let a stalled detail fetch finish.
  Completer<void>? detailGate;

  @override
  Future<CustomerOrder> cancel(String id, {String? reason}) async {
    if (cancelFailure != null) throw cancelFailure!;
    cancelled.add(id);
    cancelReasons.add(reason);
    final order = orders.firstWhere((o) => o.id == id);
    final updated = OrderFixtures.copyCancelled(order);
    orders = [
      for (final o in orders)
        if (o.id == id) updated else o,
    ];
    return updated;
  }
}

/// Orders to build screens from.
abstract final class OrderFixtures {
  static CustomerOrder order({
    String id = 'order-1',
    String reference = '#0042',
    CustomerOrderStatus status = CustomerOrderStatus.preparing,
    int totalPence = 2850,
    DateTime? placedAt,
    List<CustomerOrderItem> items = const [
      CustomerOrderItem(dishName: 'Jaffna Crab', quantity: 1, linePence: 1850),
      CustomerOrderItem(dishName: 'Hoppers', quantity: 2, linePence: 1000),
    ],
    bool isDelivery = true,
    bool canCancel = false,
    bool wasRejected = false,
    String? cancellationReason,
  }) => CustomerOrder(
    id: id,
    reference: reference,
    status: status,
    totalPence: totalPence,
    wasRejected: wasRejected,
    cancellationReason: cancellationReason,
    // Fixed rather than `DateTime.now()`: a test that formats a date should not
    // change its answer at midnight.
    placedAt: placedAt ?? DateTime(2026, 8, 1, 19, 30),
    items: items,
    isDelivery: isDelivery,
    canCancel: canCancel,
  );

  static CustomerOrder copyCancelled(CustomerOrder order) => CustomerOrder(
    id: order.id,
    reference: order.reference,
    status: CustomerOrderStatus.cancelled,
    totalPence: order.totalPence,
    placedAt: order.placedAt,
    items: order.items,
    isDelivery: order.isDelivery,
  );
}
