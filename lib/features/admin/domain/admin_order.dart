import 'package:equatable/equatable.dart';

/// An order's state, exactly as the API names them.
///
/// Seven values, and [unknown] for an eighth the backend might add — the
/// integration guide is explicit that an older app must not crash on a status it
/// has never heard of, and that the raw value should survive for logging.
enum OrderStatus {
  /// Where every order starts. The restaurant has not decided yet.
  ///
  /// Moved with approve/decline, **not** with a status PATCH -- the backend
  /// refuses a transition out of this state and answers
  /// `ORDER_NOT_PENDING_APPROVAL`.
  pendingApproval('pending_approval', 'Needs approval', 'Awaiting approval'),
  awaitingPayment(
    'awaiting_payment',
    'Approved - unpaid',
    'Waiting for payment',
  ),
  placed('placed', 'Placed', 'Order received'),

  /// Accepted, and the card hold is being turned into a charge. The provider
  /// drives this; staff have nothing to do but wait, so no move leads out of it.
  acceptancePending('acceptance_pending', 'Confirming payment', 'Confirming'),
  preparing('preparing', 'Preparing', 'Being prepared'),
  ready('ready', 'Ready', 'Ready'),
  outForDelivery('out_for_delivery', 'Out for delivery', 'On its way'),

  /// Cancelled or rejected, with the card hold being released.
  cancellationPending(
    'cancellation_pending',
    'Releasing payment',
    'Cancelling',
  ),
  completed('completed', 'Completed', 'Completed'),
  cancelled('cancelled', 'Cancelled', 'Cancelled'),
  rejected('rejected', 'Rejected', 'Rejected by the restaurant'),
  unknown('', 'Unknown', 'Unknown');

  const OrderStatus(this.wire, this.label, this.customerLabel);

  /// What the API calls it. Empty for [unknown], which is never sent.
  final String wire;

  /// What staff see.
  final String label;

  /// What a customer would see. Kept here so the two vocabularies cannot drift.
  final String customerLabel;

  static OrderStatus fromApi(String? raw) {
    final value = raw?.trim().toLowerCase();
    for (final status in values) {
      if (status != unknown && status.wire == value) return status;
    }
    return unknown;
  }

  /// Nothing moves out of these.
  bool get isFinal =>
      this == completed || this == cancelled || this == rejected;

  /// Still in the kitchen's hands — what `open_only=true` returns.
  bool get isOpen => !isFinal && this != unknown;

  /// Whether this order is waiting on the restaurant's decision.
  ///
  /// The one state that takes approve/decline rather than a status change.
  bool get needsApproval => this == pendingApproval;

  /// Whether the payment provider is mid-operation on this order.
  ///
  /// Staff decisions are locked while it is true: the accept has already been
  /// recorded and the capture is in flight, so a second tap would be a second
  /// attempt at money that is already moving.
  bool get isSettling =>
      this == acceptancePending || this == cancellationPending;
}

/// Whether an order is collected or delivered.
///
/// It decides the legal path: only a delivery order passes through
/// `out_for_delivery`, and only a collection order completes straight from
/// `ready`.
enum FulfilmentType {
  delivery('delivery', 'Delivery'),
  collection('collection', 'Collection');

  const FulfilmentType(this.wire, this.label);

  final String wire;
  final String label;

  static FulfilmentType fromApi(String? raw) =>
      raw?.trim().toLowerCase() == 'collection' ? collection : delivery;
}

/// Where the money is, as staff need to read it.
///
/// A card order arrives *authorised*, not paid: the hold becomes a charge only
/// when staff accept. The labels say so, because "Unpaid" on an authorised card
/// order would make a kitchen chase money that is already ringfenced.
enum PaymentStatus {
  pending('pending', 'Unpaid'),
  authorized('authorized', 'Card authorised'),
  capturePending('capture_pending', 'Taking payment'),
  captured('captured', 'Paid by card'),
  paid('paid', 'Paid'),
  cancelPending('cancel_pending', 'Releasing hold'),
  cancelled('cancelled', 'Hold released'),
  failed('failed', 'Card declined'),
  refunded('refunded', 'Refunded');

  const PaymentStatus(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentStatus fromApi(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'authorized' || 'authorised' => authorized,
        'capture_pending' || 'capturing' => capturePending,
        'captured' => captured,
        'paid' => paid,
        'cancel_pending' || 'cancelling' || 'releasing' => cancelPending,
        'cancelled' || 'canceled' || 'voided' || 'released' => cancelled,
        'failed' || 'declined' || 'refused' => failed,
        'refunded' => refunded,
        _ => pending,
      };

  /// Whether the provider is mid-operation. Staff controls are disabled while
  /// this is true so one tap cannot become two capture attempts.
  bool get isSettling => this == capturePending || this == cancelPending;

  /// Whether the restaurant is holding the customer's money.
  bool get isCommitted => switch (this) {
    authorized || capturePending || captured || paid => true,
    pending || cancelPending || cancelled || failed || refunded => false,
  };
}

/// The documented state machine.
///
/// Kept in one place, and derived rather than hardcoded per screen: a button
/// that offers an illegal move is a 409 waiting to happen, and the guide says
/// plainly to show only the next valid action for the fulfilment type.
///
///   collection: placed → preparing → ready → completed
///   delivery:   placed → preparing → ready → out_for_delivery → completed
///
/// `rejected` and `cancelled` are available while `placed`; `cancelled` also
/// while `preparing`.
abstract final class OrderTransitions {
  static List<OrderStatus> nextFor(OrderStatus status, FulfilmentType type) =>
      switch (status) {
        // Approve and decline are their own endpoints; a status PATCH out of
        // here is refused. The screen offers those two buttons instead, so
        // there is deliberately no transition to list.
        OrderStatus.pendingApproval => const [],
        // Approved but not paid. Not the kitchen's yet -- staff can call it
        // off, but they cannot start cooking something nobody has paid for.
        OrderStatus.awaitingPayment => [
          OrderStatus.rejected,
          OrderStatus.cancelled,
        ],
        // An approved cash order, already with the kitchen.
        OrderStatus.placed => [
          OrderStatus.preparing,
          OrderStatus.rejected,
          OrderStatus.cancelled,
        ],
        // Nothing leads out of a provider operation. The backend advances the
        // order when Worldpay answers, and offering a button here is how one
        // accept becomes two capture attempts.
        OrderStatus.acceptancePending ||
        OrderStatus.cancellationPending => const [],
        OrderStatus.preparing => [OrderStatus.ready, OrderStatus.cancelled],
        OrderStatus.ready => [
          // The one place the two paths differ. Collection cannot enter
          // out_for_delivery, and delivery cannot complete straight from ready.
          if (type == FulfilmentType.delivery)
            OrderStatus.outForDelivery
          else
            OrderStatus.completed,
        ],
        OrderStatus.outForDelivery => [OrderStatus.completed],
        _ => const [],
      };

  /// The move a busy kitchen wants on one tap: the next step along the path,
  /// ignoring the ways out.
  static OrderStatus? advanceFrom(OrderStatus status, FulfilmentType type) {
    final next = nextFor(status, type);
    return next.isEmpty ? null : next.first;
  }

  /// Whether [next] is a legal move, so a stale screen cannot send one.
  static bool allows(OrderStatus from, OrderStatus next, FulfilmentType type) =>
      nextFor(from, type).contains(next);
}

/// One chosen option on a kitchen ticket.
///
/// No prices. Staff making the food need to know what to put on the plate, and
/// whether an item was inside the customer's allowance or charged extra makes
/// no difference to cooking it.
class AdminLineSelection extends Equatable {
  const AdminLineSelection({required this.name, required this.quantity});

  factory AdminLineSelection.fromJson(Map<String, dynamic> json) =>
      AdminLineSelection(
        name:
            json['option_name']?.toString() ??
            json['name']?.toString() ??
            'Option',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      );

  final String name;
  final int quantity;

  /// "4x Egg Hopper" or "Egg Hopper".
  String get label => quantity > 1 ? '$quantity x $name' : name;

  @override
  List<Object?> get props => [name, quantity];
}

/// One line of an order, as the kitchen reads it.
class AdminOrderLine extends Equatable {
  const AdminOrderLine({
    required this.name,
    required this.quantity,
    required this.linePence,
    this.notes,
    this.variantName,
    this.selections = const [],
  });

  factory AdminOrderLine.fromJson(Map<String, dynamic> json) {
    final selections = json['selections'];
    return AdminOrderLine(
      // A snapshot taken at purchase, not a join to the menu — a dish can be
      // renamed or deleted and an old ticket must still say what was bought.
      name: json['name']?.toString() ?? 'Item',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      linePence: (json['line_total_pence'] as num?)?.toInt() ?? 0,
      notes: (json['notes']?.toString().trim().isEmpty ?? true)
          ? null
          : json['notes'].toString().trim(),
      variantName: (json['variant_name']?.toString().trim().isEmpty ?? true)
          ? null
          : json['variant_name'].toString().trim(),
      selections: selections is List
          ? selections
                .whereType<Map>()
                .map(
                  (s) =>
                      AdminLineSelection.fromJson(Map<String, dynamic>.from(s)),
                )
                .toList()
          : const [],
    );
  }

  final String name;
  final int quantity;
  final int linePence;

  /// What the customer asked for on this line. The kitchen needs it.
  final String? notes;

  /// The size, serving or package ordered — "6 Items", "14-inch".
  final String? variantName;

  /// Every option chosen. The kitchen cooks from this, so unlike the customer's
  /// receipt it keeps the *included* ones too: an egg hopper that cost nothing
  /// still has to be made.
  final List<AdminLineSelection> selections;

  /// The dish and its variant on one line, for the ticket heading.
  String get title => variantName == null ? name : '$name ($variantName)';

  @override
  List<Object?> get props => [
    name,
    quantity,
    linePence,
    notes,
    variantName,
    selections,
  ];
}

/// An order in the staff queue.
///
/// Built from `OrderSummary` for a list row and `OrderAdmin` for the detail, so
/// [lines] is empty until the order has been fetched in full — the list endpoint
/// deliberately sends `item_count` instead.
class AdminOrder extends Equatable {
  const AdminOrder({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.fulfilment,
    required this.paymentStatus,
    required this.totalPence,
    this.isCard = false,
    required this.itemCount,
    required this.isAsap,
    this.placedAt,
    this.requestedFor,
    this.lines = const [],
    this.contactName,
    this.contactPhone,
    this.addressLine1,
    this.addressLine2,
    this.city,
    this.postcode,
    this.deliveryNotes,
    this.customerNote,
    this.cancellationReason,
    this.rawStatus,
  });

  factory AdminOrder.fromJson(Map<String, dynamic> json) {
    final lines = json['items'];
    return AdminOrder(
      id: json['id']?.toString() ?? '',
      orderNumber: json['order_number']?.toString() ?? '',
      status: OrderStatus.fromApi(json['status']?.toString()),
      // Preserved for logging, as the guide asks: a status the app does not know
      // still has to be reportable.
      rawStatus: json['status']?.toString(),
      fulfilment: FulfilmentType.fromApi(json['fulfilment_type']?.toString()),
      paymentStatus: PaymentStatus.fromApi(json['payment_status']?.toString()),
      // Staff need this at the approval step: approving a cash order sends
      // food out, approving a card order only asks for money.
      isCard: json['payment_method']?.toString().toLowerCase() == 'card',
      totalPence: (json['total_pence'] as num?)?.toInt() ?? 0,
      itemCount: (json['item_count'] as num?)?.toInt() ?? 0,
      isAsap: json['is_asap'] != false,
      placedAt: _date(json['placed_at']),
      requestedFor: _date(json['requested_for']),
      lines: lines is List
          ? lines
                .whereType<Map>()
                .map(
                  (l) => AdminOrderLine.fromJson(Map<String, dynamic>.from(l)),
                )
                .toList()
          : const [],
      contactName: json['contact_name']?.toString(),
      contactPhone: json['contact_phone']?.toString(),
      addressLine1: json['address_line1']?.toString(),
      addressLine2: json['address_line2']?.toString(),
      city: json['city']?.toString(),
      postcode: json['postcode']?.toString(),
      deliveryNotes: json['delivery_notes']?.toString(),
      customerNote: json['customer_note']?.toString(),
      cancellationReason: json['cancellation_reason']?.toString(),
    );
  }

  static DateTime? _date(Object? raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString())?.toLocal();

  final String id;
  final String orderNumber;
  final OrderStatus status;
  final String? rawStatus;
  final FulfilmentType fulfilment;
  final PaymentStatus paymentStatus;

  /// Whether the customer chose card. Cash orders never have a payment page.
  final bool isCard;

  final int totalPence;
  final int itemCount;
  final bool isAsap;
  final DateTime? placedAt;

  /// When the customer asked for it. Null for an ASAP order.
  final DateTime? requestedFor;

  /// Empty on a list row — see the class note.
  final List<AdminOrderLine> lines;

  final String? contactName;
  final String? contactPhone;
  final String? addressLine1;
  final String? addressLine2;
  final String? city;
  final String? postcode;
  final String? deliveryNotes;
  final String? customerNote;
  final String? cancellationReason;

  bool get hasLines => lines.isNotEmpty;

  /// Integer pence formatted without touching floating point, as the guide
  /// specifies — money in doubles is how a total ends up a penny out.
  String get formattedTotal {
    final pounds = totalPence ~/ 100;
    final pennies = (totalPence % 100).toString().padLeft(2, '0');
    return '£$pounds.$pennies';
  }

  /// The address on one line, for a delivery ticket.
  String? get address {
    if (fulfilment != FulfilmentType.delivery) return null;
    final parts = [
      addressLine1,
      addressLine2,
      city,
      postcode,
    ].whereType<String>().where((p) => p.trim().isNotEmpty);
    return parts.isEmpty ? null : parts.join(', ');
  }

  List<OrderStatus> get nextStatuses =>
      OrderTransitions.nextFor(status, fulfilment);

  OrderStatus? get advanceTo =>
      OrderTransitions.advanceFrom(status, fulfilment);

  @override
  List<Object?> get props => [
    id,
    orderNumber,
    status,
    fulfilment,
    paymentStatus,
    isCard,
    totalPence,
    itemCount,
    isAsap,
    placedAt,
    requestedFor,
    lines,
    contactName,
    contactPhone,
    addressLine1,
    addressLine2,
    city,
    postcode,
    deliveryNotes,
    customerNote,
    cancellationReason,
  ];
}

/// The dashboard counters from `/admin/orders/stats`.
class OrderStats extends Equatable {
  const OrderStats({
    this.openOrders = 0,
    this.pendingApproval,
    this.placed = 0,
    this.preparing = 0,
    this.ready = 0,
    this.outForDelivery = 0,
    this.completedToday = 0,
    this.revenueTodayPence = 0,
  });

  factory OrderStats.fromJson(Map<String, dynamic> json) => OrderStats(
    openOrders: (json['open_orders'] as num?)?.toInt() ?? 0,
    // Nullable rather than defaulted to zero, because absent and none are
    // different things here: a deployment that does not send this count must
    // show no badge, not a confident "0 waiting" that could be wrong.
    pendingApproval: (json['pending_approval'] as num?)?.toInt(),
    placed: (json['placed'] as num?)?.toInt() ?? 0,
    preparing: (json['preparing'] as num?)?.toInt() ?? 0,
    ready: (json['ready'] as num?)?.toInt() ?? 0,
    outForDelivery: (json['out_for_delivery'] as num?)?.toInt() ?? 0,
    completedToday: (json['completed_today'] as num?)?.toInt() ?? 0,
    revenueTodayPence: (json['revenue_today_pence'] as num?)?.toInt() ?? 0,
  );

  final int openOrders;

  /// How many orders are waiting on the restaurant's decision, where the
  /// backend reports it. Null means it did not.
  final int? pendingApproval;

  final int placed;
  final int preparing;
  final int ready;
  final int outForDelivery;
  final int completedToday;
  final int revenueTodayPence;

  String get formattedRevenue {
    final pounds = revenueTodayPence ~/ 100;
    final pennies = (revenueTodayPence % 100).toString().padLeft(2, '0');
    return '£$pounds.$pennies';
  }

  @override
  List<Object?> get props => [
    openOrders,
    pendingApproval,
    placed,
    preparing,
    ready,
    outForDelivery,
    completedToday,
    revenueTodayPence,
  ];
}
