import 'dart:math';

import '../../../core/network/api_client.dart';
import '../../../core/network/page_data.dart';
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
  Future<PageData<CustomerOrder>> myOrders({
    int page = 1,
    int pageSize = 20,
  }) async {
    final data = await _client.page(
      ApiConstants.orders,
      // The API's own ceiling is 100. Twenty is a screenful and a bit, which
      // is what makes the first page arrive quickly.
      query: {'page': page, 'page_size': pageSize.clamp(1, 100)},
    );
    final orders = data.map(CustomerOrder.fromJson);
    // Sorted here rather than trusted from the API. Its default ordering is
    // not documented, and this screen's whole shape — live order on top,
    // history beneath — depends on newest first. Orders with no timestamp sink
    // rather than jumping the queue.
    //
    // Within a page only: sorting across appended pages is the server's job,
    // and re-sorting the whole list here would reshuffle rows under a reader's
    // thumb every time another page landed.
    final sorted = [...orders.items]
      ..sort((a, b) {
        final at = a.placedAt, bt = b.placedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    return PageData(
      items: sorted,
      page: orders.page,
      pageSize: orders.pageSize,
      total: orders.total,
      totalPages: orders.totalPages,
    );
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
