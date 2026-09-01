import 'dart:math';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../../cart/cart_cubit.dart';
import '../domain/customer_order.dart';
import '../domain/order_quote.dart';
import '../domain/order_repository.dart';

class ApiOrderRepository implements OrderRepository {
  ApiOrderRepository({required ApiClient client}) : _client = client;

  final ApiClient _client;

  @override
  Future<OrderQuote> quote({
    required bool isDelivery,
    required List<CartLine> lines,
    String? postcode,
  }) async {
    final data = await _client.object(
      ApiConstants.orderQuote,
      method: 'POST',
      body: {
        'fulfilment_type': isDelivery ? 'delivery' : 'collection',
        'items': [for (final line in lines) line.toJson()],
        // Only for delivery, and only when there is one: the server ignores it
        // for collection, and sending an empty string would fail the lookup
        // rather than being treated as absent.
        if (isDelivery && postcode != null && postcode.trim().isNotEmpty)
          'postcode': postcode.trim().toUpperCase(),
      },
    );
    return OrderQuote.fromJson(data);
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
    final data = await _client.object(
      ApiConstants.orders,
      method: 'POST',
      // The key that makes a double tap — or a retry after a timeout — return
      // the first order instead of creating a second.
      headers: {ApiConstants.idempotencyKeyHeader: idempotencyKey},
      body: {
        'fulfilment_type': isDelivery ? 'delivery' : 'collection',
        'payment_method': paymentMethod.wire,
        'items': [for (final line in lines) line.toJson()],
        'is_asap': isAsap,
        // Sent verbatim as the quote gave it, offset included — the API refuses
        // a time with no timezone.
        'requested_for': ?(isAsap ? null : requestedFor),
        'contact_name': contactName.trim(),
        'contact_phone': contactPhone.trim(),
        // Address fields only for delivery. Collection ignores them, but sending
        // them anyway would put a stale address on a collection ticket.
        if (isDelivery) ...{
          'address_line1': ?addressLine1?.trim(),
          'address_line2': ?_orNull(addressLine2),
          'city': ?city?.trim(),
          'postcode': ?postcode?.trim().toUpperCase(),
          'delivery_notes': ?_orNull(deliveryNotes),
        },
        'customer_note': ?_orNull(customerNote),
      },
    );
    return CustomerOrder.fromJson(data);
  }

  /// Blank optional fields are omitted rather than stored as empty strings.
  static String? _orNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<List<CustomerOrder>> myOrders() async {
    // One page, deliberately generous. The endpoint defaults to 20 and caps at
    // 100; a customer with more than fifty past orders would need real
    // pagination, which this screen does not have yet — better to say so than
    // to silently show the newest twenty as if that were all of them.
    final rows = await _client.list(
      ApiConstants.orders,
      query: {'page': 1, 'page_size': 50},
    );
    final orders = rows.map(CustomerOrder.fromJson).toList();
    // Sorted here rather than trusted from the API. The list endpoint is
    // paginated and its default ordering isn't documented, and this screen's
    // whole shape — live order on top, history beneath — depends on newest
    // first. Orders with no timestamp sink rather than jumping the queue.
    orders.sort((a, b) {
      final at = a.placedAt, bt = b.placedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return orders;
  }

  @override
  Future<CustomerOrder> orderById(String id) async =>
      CustomerOrder.fromJson(await _client.object(ApiConstants.order(id)));

  @override
  Future<CustomerOrder> cancel(String id, {String? reason}) async {
    final trimmed = reason?.trim();
    return CustomerOrder.fromJson(
      await _client.object(
        ApiConstants.orderCancel(id),
        method: 'POST',
        // The body is not optional even though every field in it is: the route
        // declares one, so sending nothing at all is a validation error rather
        // than a cancellation.
        body: {
          'reason': ?(trimmed == null || trimmed.isEmpty
              ? null
              : trimmed.substring(0, min(trimmed.length, _reasonLimit))),
        },
      ),
    );
  }

  /// The API's own ceiling. Truncated rather than refused -- losing the tail of
  /// a long explanation is better than refusing to cancel the order.
  static const int _reasonLimit = 500;

  @override
  Future<CustomerOrder> pay(String id) async => CustomerOrder.fromJson(
    await _client.object(ApiConstants.orderPay(id), method: 'POST'),
  );
}
