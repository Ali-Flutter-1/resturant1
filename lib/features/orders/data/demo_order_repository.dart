import '../../cart/cart_cubit.dart';
import '../../../core/network/page_data.dart';
import '../domain/customer_order.dart';
import '../domain/order_quote.dart';
import '../domain/order_repository.dart';

/// Orders held in memory, for looking at the screen without a backend.
///
/// Switched on by `USE_DEMO_ORDERS=true` in `.env` and off by default, so it can
/// never reach a release build by accident. It is a sibling of
/// `ApiOrderRepository` implementing the same interface rather than a flag
/// inside it: the real path has no idea this exists, so there is no branch in
/// production code that could serve invented orders to a real customer.
///
/// The set below is chosen to exercise the screen rather than to look tidy — a
/// live order at each stage, a cancellable one, a collection order, a
/// cancellation, and an order with no lines, which is the case that used to draw
/// an empty gap.
class DemoOrderRepository implements OrderRepository {
  DemoOrderRepository({this.delay = const Duration(milliseconds: 600)});

  /// Stands in for a round trip, so the skeleton and pull-to-refresh are
  /// actually visible. A repository that answers instantly hides both.
  final Duration delay;

  late List<CustomerOrder> _orders = _seed();

  /// Prices from the basket's own cached prices, with the same delivery fee and
  /// minimum the API defaults to.
  ///
  /// A demo quote is the one place local arithmetic is honest — there is no
  /// server to disagree with.
  @override
  Future<OrderQuote> quote({
    required bool isDelivery,
    required List<CartLine> lines,
    String? postcode,
  }) async {
    await Future<void>.delayed(delay);
    final subtotal = lines.fold(0, (sum, l) => sum + l.displayLinePence);
    final fee = isDelivery ? 299 : 0;
    final minimum = isDelivery ? 1000 : 0;
    final earliest = DateTime.now().add(const Duration(minutes: 45));

    return OrderQuote(
      lines: [
        for (final line in lines)
          QuoteLine(
            name: line.title,
            quantity: line.quantity,
            unitPricePence: line.displayPricePence,
            linePence: line.displayLinePence,
            notes: line.notes,
          ),
      ],
      subtotalPence: subtotal,
      deliveryFeePence: fee,
      totalPence: subtotal + fee,
      minimumOrderPence: minimum,
      meetsMinimum: subtotal >= minimum,
      earliestSlot: earliest,
      availableSlots: [
        for (var i = 0; i < 16; i++)
          earliest.add(Duration(minutes: 15 * i)).toUtc().toIso8601String(),
      ],
    );
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
    await Future<void>.delayed(delay);
    final subtotal = lines.fold(0, (sum, l) => sum + l.displayLinePence);
    final placed = CustomerOrder(
      id: 'demo-${_orders.length + 1}',
      reference: '#01${_orders.length + 10}',
      status: CustomerOrderStatus.placed,
      totalPence: subtotal + (isDelivery ? 299 : 0),
      placedAt: DateTime.now(),
      isDelivery: isDelivery,
      canCancel: true,
      paymentMethod: paymentMethod,
      // A card order starts unpaid with a page to open, exactly as the real one
      // does; cash has nothing to pay online, ever.
      paymentUrl: paymentMethod == PaymentMethod.card
          ? 'https://hpp-sandbox.worldpay.com/demo'
          : null,
      items: [
        for (final line in lines)
          CustomerOrderItem(
            dishName: line.title,
            quantity: line.quantity,
            linePence: line.displayLinePence,
            notes: line.notes,
          ),
      ],
    );
    _orders = [placed, ..._orders];
    return placed;
  }

  @override
  Future<CustomerOrder> pay(String id) async {
    await Future<void>.delayed(delay);
    final order = _orders.firstWhere((o) => o.id == id);
    return order;
  }

  @override
  Future<PageData<CustomerOrder>> myOrders({
    int page = 1,
    int pageSize = 20,
  }) async {
    await Future<void>.delayed(delay);
    // One page of demo data, and honestly labelled as the only one -- the
    // screen then never offers a "load more" that would come back empty.
    return PageData(
      items: _orders,
      page: 1,
      pageSize: pageSize,
      total: _orders.length,
      totalPages: _orders.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<CustomerOrder> orderById(String id) async {
    await Future<void>.delayed(delay);
    return _orders.firstWhere((order) => order.id == id);
  }

  @override
  Future<CustomerOrder> cancel(String id, {String? reason}) async {
    await Future<void>.delayed(delay);
    final existing = _orders.firstWhere((order) => order.id == id);
    final cancelled = _copyWithStatus(existing, CustomerOrderStatus.cancelled);
    _orders = [
      for (final order in _orders)
        if (order.id == id) cancelled else order,
    ];
    return cancelled;
  }

  /// Timestamps are relative to whenever the app started, so the history always
  /// reads as "Today", "Yesterday" and a date — a fixed calendar date would look
  /// stale within a week and stops exercising the date formatting entirely.
  static List<CustomerOrder> _seed() {
    final now = DateTime.now();

    return [
      // Live, and still cancellable.
      CustomerOrder(
        id: 'demo-1',
        reference: '#0106',
        status: CustomerOrderStatus.placed,
        totalPence: 3240,
        placedAt: now.subtract(const Duration(minutes: 4)),
        estimatedReadyAt: now.add(const Duration(minutes: 38)),
        canCancel: true,
        items: const [
          CustomerOrderItem(
            dishName: 'Jaffna Crab Curry',
            quantity: 1,
            linePence: 1850,
          ),
          CustomerOrderItem(
            dishName: 'Egg Hoppers',
            quantity: 2,
            linePence: 900,
            notes: 'Extra sambol on the side',
          ),
          CustomerOrderItem(
            dishName: 'Ginger Beer',
            quantity: 1,
            linePence: 490,
          ),
        ],
      ),

      // Live, mid-track, past the point of cancelling.
      CustomerOrder(
        id: 'demo-2',
        reference: '#0105',
        status: CustomerOrderStatus.outForDelivery,
        totalPence: 2150,
        placedAt: now.subtract(const Duration(minutes: 26)),
        estimatedReadyAt: now.add(const Duration(minutes: 9)),
        items: const [
          CustomerOrderItem(
            dishName: 'Jackfruit Kottu',
            quantity: 1,
            linePence: 1450,
          ),
          CustomerOrderItem(
            dishName: 'Coconut Sambol',
            quantity: 2,
            linePence: 700,
          ),
        ],
      ),

      // Collection, so the tracker's wording changes: "Ready to collect"
      // rather than "On its way".
      CustomerOrder(
        id: 'demo-3',
        reference: '#0104',
        status: CustomerOrderStatus.ready,
        totalPence: 1290,
        placedAt: now.subtract(const Duration(minutes: 41)),
        isDelivery: false,
        items: const [
          CustomerOrderItem(
            dishName: 'Devilled Cashews',
            quantity: 1,
            linePence: 690,
          ),
          CustomerOrderItem(
            dishName: 'Watalappan',
            quantity: 1,
            linePence: 600,
          ),
        ],
      ),

      // History.
      CustomerOrder(
        id: 'demo-4',
        reference: '#0098',
        status: CustomerOrderStatus.completed,
        totalPence: 4680,
        placedAt: now.subtract(const Duration(days: 1, hours: 3)),
        items: const [
          CustomerOrderItem(
            dishName: 'Black Pork Curry',
            quantity: 2,
            linePence: 3300,
          ),
          CustomerOrderItem(
            dishName: 'String Hoppers',
            quantity: 1,
            linePence: 780,
          ),
          CustomerOrderItem(
            dishName: 'Passionfruit Cordial',
            quantity: 1,
            linePence: 600,
          ),
        ],
      ),

      CustomerOrder(
        id: 'demo-5',
        reference: '#0091',
        status: CustomerOrderStatus.cancelled,
        totalPence: 1750,
        placedAt: now.subtract(const Duration(days: 4)),
        items: const [
          CustomerOrderItem(
            dishName: 'Prawn Vadai',
            quantity: 1,
            linePence: 1750,
          ),
        ],
      ),

      // No lines: the list endpoint doesn't always send them, and the receipt
      // sheet has to say so rather than opening on a blank space.
      CustomerOrder(
        id: 'demo-6',
        reference: '#0087',
        status: CustomerOrderStatus.completed,
        totalPence: 2260,
        placedAt: now.subtract(const Duration(days: 11)),
        isDelivery: false,
      ),
    ];
  }

  static CustomerOrder _copyWithStatus(
    CustomerOrder order,
    CustomerOrderStatus status,
  ) => CustomerOrder(
    id: order.id,
    reference: order.reference,
    status: status,
    totalPence: order.totalPence,
    placedAt: order.placedAt,
    items: order.items,
    isDelivery: order.isDelivery,
  );
}
