import 'package:equatable/equatable.dart';

import '../../menu/domain/spice_level.dart';
import 'order_quote.dart';

/// Where an order has got to, as the customer needs to understand it.
///
/// Deliberately separate from the `OrderStatus` the staff screens use. That one
/// is the kitchen's vocabulary — including `overdue`, which exists so staff can
/// see a queue slipping. Telling a customer their food is "overdue" would be a
/// worse experience than saying nothing, so this enum has no such value and the
/// mapping below folds it into the state the customer can act on.
///
/// [fromApi] is tolerant on purpose. A status the app has never heard of maps to
/// [placed] rather than throwing: an unknown value means the backend gained a
/// state, and the right response is to show the order as in progress, not to
/// fail the whole history screen because one row is newer than the app.
enum CustomerOrderStatus {
  /// Where **every** order starts, cash or card.
  ///
  /// The restaurant decides whether to take it before anything else happens.
  /// Nothing is charged here and there is nothing for the customer to do but
  /// wait -- specifically, no Pay button: asking for a payment page at this
  /// point comes back as `ORDER_NOT_APPROVED`.
  pendingApproval(
    'Waiting for approval',
    'Waiting for the restaurant to approve your order.',
  ),

  /// An approved card order that has not been paid for yet.
  ///
  /// This is the only state a card order can be paid in. It is **not** with the
  /// kitchen: the backend holds it until Worldpay's webhook confirms the money.
  awaitingPayment(
    'Approved - payment needed',
    'Approved. Complete payment to submit your order.',
  ),

  /// An approved cash order. This one *is* with the kitchen.
  placed(
    'Order confirmed',
    'We have your order and the kitchen has been told.',
  ),

  /// The money is being captured after a successful payment.
  ///
  /// Approval was the acceptance, so capture is automatic and there is no
  /// second restaurant step to wait for. Transient, and never a state to offer
  /// a Pay button in -- the money is already committed.
  accepting('Confirming', 'We are confirming your payment.'),
  preparing('Being prepared', 'The kitchen is cooking your food now.'),
  ready('Ready', 'Your order is ready and waiting for you.'),
  outForDelivery(
    'On its way',
    'Your rider has your order and is heading over.',
  ),
  completed('Completed', 'Delivered and done. Thanks for ordering.'),

  /// Cancelled, with the card hold still being released.
  cancelling('Cancelling', 'We are releasing the hold on your card.'),
  cancelled('Cancelled', 'This order was cancelled.');

  const CustomerOrderStatus(this.label, this.explanation);

  /// The short form, for a pill.
  final String label;

  /// A sentence for the tracker card, where there is room to be reassuring.
  final String explanation;

  static CustomerOrderStatus fromApi(String? raw) => switch (raw
      ?.trim()
      .toLowerCase()) {
    'pending_approval' || 'awaiting_approval' => pendingApproval,
    'awaiting_payment' || 'awaiting_payment_confirmation' => awaitingPayment,
    'placed' || 'pending' || 'confirmed' || 'accepted' => placed,
    'acceptance_pending' || 'accepting' => accepting,
    'preparing' || 'in_progress' || 'cooking' => preparing,
    'ready' || 'ready_for_collection' || 'ready_for_pickup' => ready,
    'out_for_delivery' || 'delivering' || 'dispatched' => outForDelivery,
    'cancellation_pending' || 'cancelling' => cancelling,
    'completed' ||
    'served' ||
    'collected' ||
    'delivered' ||
    'fulfilled' => completed,
    'cancelled' || 'canceled' || 'rejected' || 'refunded' => cancelled,
    // Includes null and the kitchen-only `overdue`: a late order is still an
    // order being worked on, which is all the customer can do anything with.
    _ => placed,
  };

  /// Whether this order is still happening, and so belongs at the top of the
  /// screen rather than in the history list.
  bool get isLive => switch (this) {
    pendingApproval ||
    awaitingPayment ||
    placed ||
    accepting ||
    preparing ||
    ready ||
    outForDelivery ||
    cancelling => true,
    completed || cancelled => false,
  };

  /// Position along the progress bar, or null for orders that never finish it.
  ///
  /// Cancelled has no place on a track that only moves forwards, and drawing it
  /// at step zero would suggest it was about to start again.
  int? get step => switch (this) {
    // Neither is on the track: an unapproved order and an unpaid card order
    // have both yet to reach the kitchen, and drawing either at step zero
    // would claim they had.
    pendingApproval || awaitingPayment => null,
    placed || accepting => 0,
    preparing => 1,
    ready || outForDelivery => 2,
    completed => 3,
    // A cancellation in progress is leaving the track, not moving along it.
    cancelling || cancelled => null,
  };

  /// How many stops the tracker draws.
  static const int steps = 4;
}

/// One line of an order.
///
/// The name is stored rather than looked up from the menu: a dish can be
/// renamed or withdrawn, and an old receipt should keep saying what was
/// actually bought.
class CustomerOrderItem extends Equatable {
  const CustomerOrderItem({
    required this.dishName,
    required this.quantity,
    required this.linePence,
    this.spiceLevel,
    this.notes,
    this.variantName,
    this.selections = const [],
  });

  factory CustomerOrderItem.fromJson(Map<String, dynamic> json) {
    final quantity = (json['quantity'] as num?)?.toInt() ?? 1;
    // Prefer the server's line total. Falling back to unit × quantity is only
    // for endpoints that send the unit price alone — never recomputed when the
    // server has already done the arithmetic, because the server is the one
    // that has to match the payment.
    final line = json['line_total_pence'] as num?;
    final unit = json['unit_price_pence'] as num?;
    final selections = json['selections'];

    return CustomerOrderItem(
      // `name`, not a nested dish: the API stores the name on the line so an
      // old receipt keeps saying what was actually bought even after the dish
      // has been renamed or withdrawn.
      dishName: json['name']?.toString() ?? 'Item',
      quantity: quantity,
      linePence: line?.toInt() ?? ((unit?.toInt() ?? 0) * quantity),
      // Read from the order, never from the dish. An admin can turn spice
      // choices off later, and a receipt must keep saying what was ordered.
      spiceLevel: SpiceLevel.tryParse(json['spice_level']),
      notes: (json['notes']?.toString().trim().isEmpty ?? true)
          ? null
          : json['notes'].toString().trim(),
      // Snapshots, like the name: what was bought stays on the receipt even
      // after the admin renames the size or withdraws the option.
      variantName: (json['variant_name']?.toString().trim().isEmpty ?? true)
          ? null
          : json['variant_name'].toString().trim(),
      // The same shape the quote returns, so the receipt and the checkout
      // summary render from one widget rather than two that can drift.
      selections: selections is List
          ? selections
                .whereType<Map>()
                .map(
                  (s) => QuoteSelection.fromJson(Map<String, dynamic>.from(s)),
                )
                .toList()
          : const [],
    );
  }

  final String dishName;
  final int quantity;
  final int linePence;
  final SpiceLevel? spiceLevel;
  final String? notes;

  /// The size, serving or package that was bought. Null for a plain dish.
  final String? variantName;

  /// The options that were chosen, with the server's included/charged split.
  final List<QuoteSelection> selections;

  /// The dish and its variant on one line — "Custom Breakfast (6 Items)".
  String get titleWithVariant =>
      variantName == null ? dishName : '$dishName ($variantName)';

  @override
  List<Object?> get props => [
    dishName,
    quantity,
    linePence,
    spiceLevel,
    notes,
    variantName,
    selections,
  ];
}

/// How the customer chose to pay.
enum PaymentMethod {
  cash('cash', 'Cash'),
  card('card', 'Card');

  const PaymentMethod(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentMethod fromApi(String? raw) =>
      raw?.trim().toLowerCase() == 'card' ? card : cash;
}

/// Where the money has got to.
///
/// The only thing that moves an order to [paid] is Worldpay calling the
/// backend's webhook, server to server. The app never decides this -- a closed
/// payment sheet and a success-looking redirect both prove nothing.
enum CustomerPaymentStatus {
  /// Nothing has been taken. For a card order this is the one state that
  /// carries a `payment_url` and the one state a Pay button belongs in.
  pending('pending'),

  /// The card has been authorised: the money is ringfenced but not taken. The
  /// customer must **never** be asked to pay again from here.
  authorized('authorized'),

  /// The restaurant accepted and the hold is being turned into a charge.
  capturePending('capture_pending'),

  /// Taken.
  captured('captured'),

  /// Cash, settled on handover.
  paid('paid'),

  /// The hold is being released after a cancellation or rejection.
  cancelPending('cancel_pending'),

  /// The hold was released. No money moved.
  cancelled('cancelled'),

  /// Declined. The order is kept and a fresh payment page can be asked for.
  failed('failed'),

  refunded('refunded');

  const CustomerPaymentStatus(this.wire);

  final String wire;

  static CustomerPaymentStatus fromApi(String? raw) =>
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

  /// Whether the money is committed -- authorised, being captured, or taken.
  ///
  /// The single check that keeps a second Pay button off the screen. Getting
  /// this wrong is the one bug in this flow that costs a customer money.
  bool get isCommitted => switch (this) {
    authorized || capturePending || captured || paid => true,
    pending || cancelPending || cancelled || failed || refunded => false,
  };

  /// Whether something is in flight at the provider and the app should keep
  /// refreshing rather than settling on what it sees.
  bool get isSettling => this == capturePending || this == cancelPending;
}

/// An order as the customer's own history shows it.
class CustomerOrder extends Equatable {
  const CustomerOrder({
    required this.id,
    required this.reference,
    required this.status,
    required this.totalPence,
    required this.placedAt,
    this.items = const [],
    this.isDelivery = true,
    this.estimatedReadyAt,
    this.canCancel = false,
    this.wasRejected = false,
    this.cancellationReason,
    this.cancelledAt,
    this.itemCountFallback,
    this.paymentMethod = PaymentMethod.cash,
    this.paymentStatus = CustomerPaymentStatus.pending,
    this.paymentUrl,
    this.paidAt,
  });

  factory CustomerOrder.fromJson(Map<String, dynamic> json) {
    final items = json['items'];
    final id = json['id']?.toString() ?? '';
    final status = CustomerOrderStatus.fromApi(json['status']?.toString());
    final fulfilment = json['fulfilment_type']?.toString().toLowerCase();
    final raw = json['status']?.toString().trim().toLowerCase();

    return CustomerOrder(
      id: id,
      // `order_number` is the API's own human-facing reference. The id tail is
      // a fallback rather than a decoration: a customer ringing up needs to be
      // able to read *something* back, and a bare UUID is unreadable aloud.
      reference: json['order_number']?.toString() ?? _shortRef(id),
      status: status,
      totalPence: (json['total_pence'] as num?)?.toInt() ?? 0,
      placedAt: _date(json['placed_at']),
      items: items is List
          ? items
                .whereType<Map>()
                .map(
                  (i) =>
                      CustomerOrderItem.fromJson(Map<String, dynamic>.from(i)),
                )
                .toList()
          : const [],
      // Anything that isn't collection is treated as delivery. The field is a
      // free string in the spec, so matching the one value that changes the
      // wording is safer than enumerating values the backend may add.
      isDelivery: fulfilment != 'collection' && fulfilment != 'pickup',
      // `requested_for` is when the customer asked for it, and is null for an
      // ASAP order — which is exactly when there is no time worth printing.
      estimatedReadyAt: json['is_asap'] == true
          ? null
          : _date(json['requested_for']),
      // The list endpoint omits lines entirely — `item_count` is how many there
      // were, which is all a row needs.
      itemCountFallback: (json['item_count'] as num?)?.toInt(),
      // The server's flag, because it is the only thing that knows the real
      // rule. The guide is explicit: use `can_cancel` rather than reproducing
      // the condition here.
      //
      // This used to be ANDed with `status == placed`, which was right when
      // `placed` was where an order began. It is not any more -- an order now
      // starts at `pending_approval` and may sit there for minutes -- so that
      // check silently took the cancel button away from every customer during
      // the exact window where they are most likely to want it.
      //
      // The local set is now only a fallback for a response that omits the
      // field, and it lists all three states the API accepts a cancellation
      // in. Cancelling is refused from `preparing` onwards, where food and
      // time have been spent.
      canCancel: json['can_cancel'] is bool
          ? json['can_cancel'] as bool
          : _cancellable.contains(status),
      // `rejected` and `cancelled` are one state to a tracker, but not to the
      // person reading it: one is "we could not take this", the other is
      // "you or we called it off". The wording differs, so the raw value is
      // kept even though [status] folds the two together.
      wasRejected: raw == 'rejected' || raw == 'declined',
      // Set by staff when they cancel or reject — the API makes the note
      // mandatory for exactly those two, so there is always something to show.
      cancellationReason: _text(json['cancellation_reason']),
      cancelledAt: _date(json['cancelled_at']),
      paymentMethod: PaymentMethod.fromApi(json['payment_method']?.toString()),
      paymentStatus: CustomerPaymentStatus.fromApi(
        json['payment_status']?.toString(),
      ),
      // Present only while there is something to pay: the server nulls it once
      // an order is paid, and after a decline until a fresh page is asked for.
      paymentUrl: _text(json['payment_url']),
      paidAt: _date(json['paid_at']),
    );
  }

  /// Where the API accepts a cancellation, for a response that does not say.
  static const Set<CustomerOrderStatus> _cancellable = {
    CustomerOrderStatus.pendingApproval,
    CustomerOrderStatus.awaitingPayment,
    CustomerOrderStatus.placed,
  };

  static String _shortRef(String id) {
    final tail = id.replaceAll('-', '');
    return tail.length <= 4
        ? '#$tail'
        : '#${tail.substring(tail.length - 4).toUpperCase()}';
  }

  static DateTime? _date(Object? raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString())?.toLocal();

  static String? _text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  final String id;
  final String reference;
  final CustomerOrderStatus status;
  final int totalPence;

  /// Null where the server sent no timestamp — the screen then omits the "when"
  /// line rather than printing an invented date.
  final DateTime? placedAt;

  final List<CustomerOrderItem> items;

  /// False means collection. Affects wording only: a collection order is never
  /// "on its way".
  final bool isDelivery;

  final DateTime? estimatedReadyAt;

  final bool canCancel;

  /// Whether the restaurant refused the order, as opposed to it being cancelled.
  final bool wasRejected;

  /// Why the restaurant cancelled or rejected it, in their own words.
  ///
  /// Only ever present on a cancelled or rejected order, and only from the
  /// *detail* endpoint — the paginated list sends a summary with no reason, so a
  /// row has to be opened before this can be shown.
  final String? cancellationReason;

  final DateTime? cancelledAt;

  /// `item_count` from the list endpoint, which sends no lines at all. Null on a
  /// fetched order, where [items] is authoritative.
  final int? itemCountFallback;

  final PaymentMethod paymentMethod;
  final CustomerPaymentStatus paymentStatus;

  /// Worldpay's hosted page, when there is one to open.
  final String? paymentUrl;

  final DateTime? paidAt;

  bool get isCard => paymentMethod == PaymentMethod.card;

  bool get isPaid =>
      paymentStatus == CustomerPaymentStatus.paid ||
      paymentStatus == CustomerPaymentStatus.captured;

  /// Whether the restaurant has yet to decide on this order.
  ///
  /// Cash and card alike start here. Nothing has been charged, and there is
  /// nothing for the customer to do.
  bool get awaitingApproval => status == CustomerOrderStatus.pendingApproval;

  /// A card order the customer can pay for right now.
  ///
  /// Deliberately narrow, on two axes. The **status** must be
  /// `awaiting_payment` -- an order still waiting on the restaurant is not
  /// payable, and asking for a page returns `ORDER_NOT_APPROVED`. The
  /// **payment status** must be nothing-attempted-yet or a retryable decline;
  /// authorised, capturing, captured, releasing, released and refunded must
  /// all show no Pay button, because in every one of those the money has
  /// either been committed already or deliberately let go. Getting either axis
  /// wrong is how a customer pays twice for one meal.
  bool get needsPayment {
    if (!isCard || status != CustomerOrderStatus.awaitingPayment) return false;
    return paymentStatus == CustomerPaymentStatus.pending ||
        paymentStatus == CustomerPaymentStatus.failed;
  }

  /// Whether tapping Pay should ask the server for a fresh page first.
  ///
  /// A declined payment cannot reuse its old URL -- Worldpay treats the same
  /// reference as the same attempt -- and a pending order with no URL never got
  /// one. Both are `POST /orders/{id}/pay`.
  bool get needsFreshPaymentPage =>
      needsPayment &&
      (paymentStatus == CustomerPaymentStatus.failed ||
          paymentUrl == null ||
          paymentUrl!.isEmpty);

  /// A card order that has been placed but not paid has **not** reached the
  /// kitchen -- the backend holds it until the payment webhook lands -- so it
  /// must never be described as being cooked.
  bool get awaitingPayment =>
      isCard &&
      status == CustomerOrderStatus.awaitingPayment &&
      paymentStatus == CustomerPaymentStatus.pending;

  /// The card was declined and the order is still there to retry.
  bool get paymentFailed =>
      isCard && paymentStatus == CustomerPaymentStatus.failed;

  /// Money is committed but the provider has not finished. Keep refreshing.
  bool get isSettlingPayment => isCard && paymentStatus.isSettling;

  /// Whether the app should still be polling this order's payment.
  ///
  /// Anything settling, plus a pending card order the customer has just come
  /// back to from the hosted page.
  bool get isPaymentInFlight =>
      isCard && (paymentStatus.isSettling || awaitingPayment);

  /// What to tell the customer about the money, or null when there is nothing
  /// worth saying -- a cash order, or a paid one that speaks for itself.
  ///
  /// This is the state matrix from the payment guide, in one place, so no
  /// screen has to re-derive it and no two screens can disagree.
  String? get paymentMessage {
    if (!isCard) return null;
    // Approval comes first, and until it lands the money is not the subject.
    if (awaitingApproval) {
      return 'Waiting for the restaurant to approve your order. You will be '
          'able to pay once they do.';
    }
    return switch (paymentStatus) {
      CustomerPaymentStatus.pending =>
        'Approved. Complete payment to submit your order.',
      // Approval already happened, so capture follows on its own -- there is
      // no second restaurant step to wait for, and saying there is would have
      // the customer watching for something that never comes.
      CustomerPaymentStatus.authorized => 'Card authorised. Confirming now.',
      CustomerPaymentStatus.capturePending =>
        'Paid - we are preparing your order.',
      CustomerPaymentStatus.captured => null,
      CustomerPaymentStatus.paid => null,
      CustomerPaymentStatus.cancelPending =>
        'Releasing the hold on your card. Nothing has been taken.',
      CustomerPaymentStatus.cancelled =>
        'The hold on your card was released. You have not been charged.',
      CustomerPaymentStatus.failed =>
        'Your card was declined. Your order is saved - try again to confirm '
            'it.',
      CustomerPaymentStatus.refunded => 'This order was refunded.',
    };
  }

  /// Whether the lines are known, or only how many there were.
  ///
  /// The list endpoint deliberately omits them, so a row shows the count and the
  /// receipt fetches the order in full rather than displaying an empty
  /// breakdown and calling it a receipt.
  bool get hasItemDetail => items.isNotEmpty;

  String get formattedTotal => '£${(totalPence / 100).toStringAsFixed(2)}';

  int get itemCount => items.isEmpty
      ? (itemCountFallback ?? 0)
      : items.fold(0, (sum, item) => sum + item.quantity);

  /// The status line, adjusted for collection orders.
  ///
  /// The shared enum can't know the fulfilment method, and "On its way" for an
  /// order the customer is walking in to collect is simply wrong.
  String get statusLabel {
    if (wasRejected) return 'Declined';
    // An unpaid card order has not been sent to the kitchen at all, so no
    // kitchen-facing status describes it honestly.
    if (awaitingApproval) return status.label;
    if (awaitingPayment && status.isLive) return 'Payment needed';
    if (paymentFailed && status.isLive) return 'Payment declined';
    return !isDelivery && status == CustomerOrderStatus.outForDelivery
        ? 'Ready to collect'
        : status.label;
  }

  String get statusExplanation {
    if (wasRejected) {
      return 'The restaurant could not take this order.';
    }
    // The backend holds a card order out of the kitchen until Worldpay's
    // webhook confirms the money, so "we're preparing it" would be false and
    // the customer would stop watching for the thing that still needs doing.
    if (status.isLive) {
      // The payment matrix wins while the order is live: "being prepared" is
      // the wrong thing to read when the card was declined.
      final money = paymentMessage;
      if (money != null &&
          (awaitingPayment || paymentFailed || isSettlingPayment)) {
        return money;
      }
    }
    return !isDelivery && status == CustomerOrderStatus.ready
        ? 'Your order is ready to collect from the counter.'
        : status.explanation;
  }

  @override
  List<Object?> get props => [
    id,
    reference,
    status,
    totalPence,
    placedAt,
    items,
    isDelivery,
    estimatedReadyAt,
    canCancel,
    wasRejected,
    cancellationReason,
    cancelledAt,
    paymentMethod,
    paymentStatus,
    paymentUrl,
    paidAt,
    itemCountFallback,
  ];
}
