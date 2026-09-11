import '../../../core/network/page_data.dart';
import '../../cart/cart_cubit.dart';
import 'customer_order.dart';
import 'order_quote.dart';

/// The signed-in customer's own orders.
///
/// Nothing here takes a user id: every endpoint is scoped to the bearer token,
/// so there is no way for this interface to ask for somebody else's history.
abstract interface class OrderRepository {
  /// Prices a basket without creating anything.
  ///
  /// Called when checkout opens and again whenever the basket or the fulfilment
  /// type changes — the returned totals are what the screen renders, and the
  /// slots are what a scheduled order must choose from.
  Future<OrderQuote> quote({
    required bool isDelivery,
    required List<CartLine> lines,

    /// Required for a delivery quote: the zone decides both the fee and the
    /// minimum, and neither is knowable without it. Omitting it on a delivery
    /// quote comes back as `POSTCODE_REQUIRED`. Ignored for collection.
    String? postcode,
  });

  /// Places the order.
  ///
  /// [idempotencyKey] must be generated once per checkout and **reused** on
  /// every retry of that same checkout, including after a timeout — a fresh key
  /// on retry is how a customer ends up with two orders.
  Future<CustomerOrder> place({
    required String idempotencyKey,
    required bool isDelivery,
    required List<CartLine> lines,
    required String contactName,
    required String contactPhone,

    /// Cash is settled on handover; card holds the order out of the kitchen
    /// until Worldpay confirms the money, so this choice changes what the
    /// customer is told after placing.
    PaymentMethod paymentMethod = PaymentMethod.cash,
    bool isAsap = true,
    String? requestedFor,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? postcode,
    String? deliveryNotes,
    String? customerNote,
  });

  /// Newest first, one page at a time.
  ///
  /// Paginated rather than fetched whole: the endpoint caps at 100 a page, and
  /// a regular customer's history outgrows any single request eventually. The
  /// screen appends pages as it is scrolled.
  Future<PageData<CustomerOrder>> myOrders({int page = 1, int pageSize = 20});

  /// A payment page for an unpaid card order.
  ///
  /// Used when the order was placed while Worldpay was unreachable (the order
  /// exists, with no `payment_url`), when a card was declined and the customer
  /// taps "Try again", and when they come back later to an order they never
  /// paid for.
  Future<CustomerOrder> pay(String id);

  /// One order in full, including its lines.
  Future<CustomerOrder> orderById(String id);

  /// Cancels an order the kitchen hasn't started.
  ///
  /// [reason] is what the customer typed, and is stored as the order's
  /// `cancellation_reason` -- staff read it, so it is worth asking for. The
  /// endpoint takes a JSON body even when there is nothing to say, so the key
  /// is always sent, null and all.
  ///
  /// Returns the updated order so the screen shows the server's verdict rather
  /// than assuming the cancellation stuck.
  Future<CustomerOrder> cancel(String id, {String? reason});
}
