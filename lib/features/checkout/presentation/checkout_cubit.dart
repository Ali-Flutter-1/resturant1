import 'dart:async';
import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../../cart/cart_cubit.dart';
import '../../orders/domain/customer_order.dart';
import '../../orders/domain/order_quote.dart';
import '../../orders/domain/order_repository.dart';
import '../../delivery/domain/delivery_zone.dart';
import '../../delivery/domain/delivery_zone_repository.dart';
import '../../orders/domain/payment_flow.dart';

/// Where a checkout has got to.
///
/// The shape the integration guide suggests: basket → quoting → quote ready →
/// submitting → placed.
enum CheckoutStage { quoting, ready, submitting, placed, failed }

class CheckoutState extends Equatable {
  const CheckoutState({
    this.stage = CheckoutStage.quoting,
    this.isDelivery = true,
    this.quote,
    this.failure,
    this.placedOrder,
    this.fieldErrors = const {},
    this.requestedFor,
    this.prepMinutes,
    this.paymentMethod = PaymentMethod.cash,
    this.paying = false,
    this.postcode = '',
    this.zoneCheck,
    this.checkingPostcode = false,
    this.postcodeError,
  });

  final CheckoutStage stage;

  /// Delivery or collection. Changing it re-quotes: the fee and the minimum both
  /// depend on it.
  final bool isDelivery;

  /// The server's price. Null until the first quote lands.
  final OrderQuote? quote;

  /// Cash on handover, or a card paid on Worldpay's page before the kitchen
  /// ever sees the order.
  final PaymentMethod paymentMethod;

  /// True while the payment sheet is open or the result is being confirmed.
  final bool paying;

  /// The postcode the quote was priced for. Delivery pricing is zone-based, so
  /// until this is known the basket total is unknowable.
  final String postcode;

  /// What the server said about [postcode]. Null before it has been asked.
  final PostcodeCheck? zoneCheck;

  final bool checkingPostcode;

  /// Set when the postcode itself could not be looked up -- unknown, or the
  /// lookup service is down. Distinct from a postcode that is simply outside
  /// every zone, which is a normal answer carried in [zoneCheck].
  final String? postcodeError;

  /// The zone this order will be charged at, when there is one.
  DeliveryZone? get zone => zoneCheck?.zone;

  /// Whether delivery has been ruled out for this address.
  ///
  /// Only true once the server has actually answered: before that, delivery is
  /// merely unpriced, and blocking checkout on "not yet asked" would refuse
  /// every order the moment the screen opened.
  bool get outsideDeliveryArea =>
      isDelivery && zoneCheck != null && !zoneCheck!.deliverable;

  final ApiFailure? failure;

  /// Set once the order exists. Its number is what the customer needs.
  final CustomerOrder? placedOrder;

  /// Per-field complaints from a 422, keyed by the API's field names.
  final Map<String, String> fieldErrors;

  /// The chosen slot, verbatim from `quote.available_slots`, or null for ASAP.
  final String? requestedFor;

  /// The kitchen's estimate for this basket, in minutes — the longest dish, not
  /// the sum. Null when no dish carried one.
  final int? prepMinutes;

  /// The earliest moment the kitchen could have this basket ready.
  ///
  /// Captured when the quote lands rather than recomputed on every build, so the
  /// list of offered times does not shuffle while somebody is looking at it.
  DateTime? get readyFrom => _readyFrom;

  /// Slots the kitchen can actually make.
  ///
  /// A **narrowing** of what the server offered, never an addition: the API's
  /// 45-minute lead time is the floor, and this removes anything inside the
  /// basket's own cooking time on top of that. So a twenty-minute dish cannot be
  /// asked for in fifteen.
  List<String> get selectableSlots {
    final quoted = quote?.availableSlots ?? const <String>[];
    final floor = _readyFrom;
    if (floor == null) return quoted;

    return quoted.where((slot) {
      final when = DateTime.tryParse(slot);
      // A slot that will not parse is kept rather than dropped — the server sent
      // it, and hiding a valid time because of a formatting surprise is worse
      // than offering one.
      return when == null || !when.toUtc().isBefore(floor);
    }).toList();
  }

  /// True when the kitchen's estimate rules out every time the server offered.
  bool get everySlotTooSoon =>
      quote != null &&
      (quote!.availableSlots.isNotEmpty) &&
      selectableSlots.isEmpty;

  DateTime? get _readyFrom {
    final minutes = prepMinutes;
    if (minutes == null) return null;
    return DateTime.now().toUtc().add(Duration(minutes: minutes));
  }

  bool get isAsap => requestedFor == null;

  /// Whether the order can be sent. A delivery below the minimum cannot.
  bool get canPlace =>
      quote != null &&
      quote!.meetsMinimum &&
      // Delivery needs a postcode inside a zone. The server refuses either way
      // -- this only stops the customer filling in a form that cannot be sent.
      !(isDelivery && !(zoneCheck?.deliverable ?? false)) &&
      stage != CheckoutStage.submitting &&
      stage != CheckoutStage.placed;

  bool get isCard => paymentMethod == PaymentMethod.card;

  CheckoutState copyWith({
    CheckoutStage? stage,
    bool? isDelivery,
    OrderQuote? quote,
    ApiFailure? failure,
    CustomerOrder? placedOrder,
    Map<String, String>? fieldErrors,
    String? requestedFor,
    int? prepMinutes,
    PaymentMethod? paymentMethod,
    bool? paying,
    String? postcode,
    PostcodeCheck? zoneCheck,
    bool? checkingPostcode,
    String? postcodeError,
    bool clearFailure = false,
    bool clearSlot = false,
    bool clearZoneCheck = false,
    bool clearPostcodeError = false,
  }) {
    return CheckoutState(
      stage: stage ?? this.stage,
      isDelivery: isDelivery ?? this.isDelivery,
      quote: quote ?? this.quote,
      failure: clearFailure ? null : (failure ?? this.failure),
      placedOrder: placedOrder ?? this.placedOrder,
      fieldErrors: fieldErrors ?? this.fieldErrors,
      requestedFor: clearSlot ? null : (requestedFor ?? this.requestedFor),
      prepMinutes: prepMinutes ?? this.prepMinutes,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      paying: paying ?? this.paying,
      postcode: postcode ?? this.postcode,
      zoneCheck: clearZoneCheck ? null : (zoneCheck ?? this.zoneCheck),
      checkingPostcode: checkingPostcode ?? this.checkingPostcode,
      postcodeError: clearPostcodeError
          ? null
          : (postcodeError ?? this.postcodeError),
    );
  }

  @override
  List<Object?> get props => [
    stage,
    isDelivery,
    quote,
    failure,
    placedOrder,
    paymentMethod,
    paying,
    postcode,
    zoneCheck,
    checkingPostcode,
    postcodeError,
    fieldErrors,
    requestedFor,
    prepMinutes,
  ];
}

/// Pricing and placing one order.
///
/// Two rules from the guide are load-bearing here:
///
///  * **One idempotency key per checkout, reused on every retry.** Generating a
///    fresh key when a request times out is exactly how a customer ends up with
///    two identical orders — the server has no way to tell the second attempt
///    from a second order. The key is made once, in the constructor, and only
///    replaced when the basket meaningfully changes.
///  * **Clear the basket only after the server confirms.** A basket emptied
///    optimistically and a request that then failed leaves the customer with
///    neither an order nor the things they chose.
class CheckoutCubit extends Cubit<CheckoutState> {
  CheckoutCubit({
    required OrderRepository repository,
    required CartCubit cart,
    required DeliveryZoneRepository zones,
    PaymentFlow? paymentFlow,
  }) : _repository = repository,
       _cart = cart,
       _zones = zones,
       _payments = paymentFlow ?? PaymentFlow(repository: repository),
       super(const CheckoutState());

  final OrderRepository _repository;
  final CartCubit _cart;
  final DeliveryZoneRepository _zones;
  final PaymentFlow _payments;

  /// Generated once per checkout attempt. See the class note.
  String _idempotencyKey = _uuidV4();

  /// The basket this key belongs to, so a genuinely different order gets a new
  /// one rather than being deduplicated against the last.
  List<CartLine>? _keyedFor;

  Timer? _quoteDebounce;

  /// Rises with every quote started. A reply whose ticket is no longer the
  /// latest is dropped: taps come faster than the round trip, and responses can
  /// arrive out of order, so the older answer would otherwise land last and
  /// show a total for a basket the customer has already changed.
  int _quoteTicket = 0;

  /// Re-price after the customer stops tapping.
  ///
  /// Every `+` and `-` used to fire its own request, so adjusting a line three
  /// times meant three round trips of half a second or more each, with the
  /// totals flicking through a loading state between them. One burst of taps is
  /// one question for the server: what does this basket cost now.
  void quoteSoon() {
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(const Duration(milliseconds: 350), quote);
  }

  @override
  Future<void> close() {
    _quoteDebounce?.cancel();
    _postcodeDebounce?.cancel();
    return super.close();
  }

  /// Cash or card. Does not re-quote: the price is the same either way -- only
  /// where and when the money moves changes.
  void setPaymentMethod(PaymentMethod method) {
    if (method == state.paymentMethod) return;
    emit(state.copyWith(paymentMethod: method));
  }

  /// Takes a postcode, finds out whether it can be delivered to, and re-prices.
  ///
  /// Debounced like the basket, because this runs while somebody is typing an
  /// address. The zone decides both the fee and the minimum, so the total on
  /// screen means nothing until this has answered -- which is why the quote
  /// follows it rather than running alongside.
  void setPostcode(String value) {
    final trimmed = value.trim().toUpperCase();
    if (trimmed == state.postcode) return;

    emit(
      state.copyWith(
        postcode: trimmed,
        // The previous answer belonged to the previous postcode. Keeping it
        // would price this address at the last one's zone.
        clearZoneCheck: true,
        clearPostcodeError: true,
      ),
    );

    _postcodeDebounce?.cancel();
    if (trimmed.length < 5) return;
    _postcodeDebounce = Timer(const Duration(milliseconds: 500), checkPostcode);
  }

  Timer? _postcodeDebounce;

  /// Asks the server which zone the current postcode falls in.
  Future<void> checkPostcode() async {
    _postcodeDebounce?.cancel();
    final postcode = state.postcode;
    if (postcode.isEmpty) return;

    final ticket = ++_checkTicket;
    emit(state.copyWith(checkingPostcode: true, clearPostcodeError: true));

    try {
      final check = await _zones.check(postcode);
      if (ticket != _checkTicket) return;
      emit(
        state.copyWith(
          zoneCheck: check,
          // The server normalises spacing and case; echoing its version back
          // keeps the field and the quote talking about the same address.
          postcode: check.postcode.isEmpty ? postcode : check.postcode,
          checkingPostcode: false,
        ),
      );

      // Only worth re-pricing when there is a zone to price in.
      if (check.deliverable) await quote();
    } on ApiFailure catch (failure) {
      if (ticket != _checkTicket) return;
      // The postcode itself is the problem -- unknown, or the lookup service
      // is down. Reported against the field, not as a screen-wide failure.
      emit(
        state.copyWith(checkingPostcode: false, postcodeError: failure.message),
      );
    }
  }

  int _checkTicket = 0;

  Future<void> quote() async {
    _quoteDebounce?.cancel();
    final ticket = ++_quoteTicket;
    final lines = _cart.state.lines;
    if (lines.isEmpty) {
      emit(
        state.copyWith(
          stage: CheckoutStage.failed,
          failure: const ApiFailure(
            kind: ApiFailureKind.invalid,
            message: 'Your basket is empty.',
          ),
        ),
      );
      return;
    }

    // Delivery is priced by zone, so there is nothing to ask for until the
    // postcode is known and inside one. Asking anyway returns
    // POSTCODE_REQUIRED or OUTSIDE_DELIVERY_AREA, which would put a red
    // failure on the screen for the perfectly ordinary state of not having
    // typed an address yet.
    if (state.isDelivery && !(state.zoneCheck?.deliverable ?? false)) {
      emit(state.copyWith(stage: CheckoutStage.ready, clearFailure: true));
      return;
    }

    // A changed basket is a new order, so it gets a new key. Same basket,
    // retried — including after a timeout — keeps the old one.
    if (_keyedFor != null && _keyedFor != lines) {
      _idempotencyKey = _uuidV4();
    }
    _keyedFor = List.of(lines);

    emit(state.copyWith(stage: CheckoutStage.quoting, clearFailure: true));
    try {
      final quote = await _repository.quote(
        isDelivery: state.isDelivery,
        lines: lines,
        postcode: state.postcode,
      );
      if (ticket != _quoteTicket) return;
      emit(
        state.copyWith(
          stage: CheckoutStage.ready,
          quote: quote,
          // Recorded from the basket, so the slot list can refuse a time the
          // kitchen could not meet.
          prepMinutes: _cart.state.longestPrepMinutes,
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      if (ticket != _quoteTicket) return;
      emit(state.copyWith(stage: CheckoutStage.failed, failure: failure));
    }
  }

  /// Opens the payment page for the order just placed, then asks the server
  /// what happened.
  ///
  /// Also the "Try again" path after a decline: the flow asks for a fresh page,
  /// which Worldpay requires -- a repeated reference is treated as the same
  /// payment, so retrying the old URL would achieve nothing.
  Future<void> payNow() async {
    final order = state.placedOrder;
    if (order == null || !order.needsPayment || state.paying) return;

    emit(state.copyWith(paying: true, clearFailure: true));
    try {
      final settled = await _payments.payFor(order);
      emit(state.copyWith(placedOrder: settled, paying: false));
    } on ApiFailure catch (failure) {
      // The order still exists and is still payable; only this attempt failed.
      emit(state.copyWith(paying: false, failure: failure));
    }
  }

  /// Switches between delivery and collection, then re-prices.
  Future<void> setDelivery(bool isDelivery) async {
    if (isDelivery == state.isDelivery) return;
    // Turning delivery on with an address already typed: find its zone rather
    // than waiting for the customer to touch the field again.
    if (isDelivery && state.postcode.isNotEmpty && state.zoneCheck == null) {
      emit(state.copyWith(isDelivery: true, clearSlot: true));
      await checkPostcode();
      return;
    }
    // The slot is dropped: the two paths have different lead times, and a slot
    // chosen for one is not necessarily offered for the other.
    emit(state.copyWith(isDelivery: isDelivery, clearSlot: true));
    await quote();
  }

  /// Picks a slot, or null for as soon as possible.
  ///
  /// A slot outside [CheckoutState.selectableSlots] is ignored rather than
  /// stored: the only way to ask for one is a stale screen, and sending it would
  /// earn a TIME_TOO_SOON the customer cannot act on.
  void setSlot(String? slot) {
    if (slot == null) return emit(state.copyWith(clearSlot: true));
    if (!state.selectableSlots.contains(slot)) return;
    emit(state.copyWith(requestedFor: slot));
  }

  /// Sends the order.
  ///
  /// Returns null on success. The basket and the key are cleared only after the
  /// server has answered.
  Future<ApiFailure?> place({
    required String contactName,
    required String contactPhone,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? postcode,
    String? deliveryNotes,
    String? customerNote,
  }) async {
    if (state.stage == CheckoutStage.submitting) return null;
    emit(
      state.copyWith(
        stage: CheckoutStage.submitting,
        clearFailure: true,
        fieldErrors: const {},
      ),
    );

    try {
      final order = await _repository.place(
        idempotencyKey: _idempotencyKey,
        isDelivery: state.isDelivery,
        lines: _cart.state.lines,
        contactName: contactName,
        contactPhone: contactPhone,
        isAsap: state.isAsap,
        requestedFor: state.requestedFor,
        addressLine1: addressLine1,
        addressLine2: addressLine2,
        city: city,
        postcode: postcode,
        deliveryNotes: deliveryNotes,
        customerNote: customerNote,
        paymentMethod: state.paymentMethod,
      );

      // Confirmed, so now the basket goes — and the key with it, since this
      // checkout is over.
      _cart.clear();
      _idempotencyKey = _uuidV4();
      _keyedFor = null;

      emit(state.copyWith(stage: CheckoutStage.placed, placedOrder: order));

      // Straight to the payment page. A card order sits outside the kitchen
      // until the money clears, so there is nothing to wait for and every
      // reason not to make the customer find a "Pay" button.
      if (order.needsPayment) await payNow();
      return null;
    } on ApiFailure catch (failure) {
      // Back to ready, not failed: the entered details are still on screen and
      // still valid, and most of these are worth another try with the same key.
      emit(
        state.copyWith(
          stage: CheckoutStage.ready,
          failure: failure,
          fieldErrors: failure.fieldErrors,
        ),
      );
      return failure;
    }
  }

  /// A version-4 UUID.
  ///
  /// Hand-rolled rather than adding a package for sixteen bytes. `Random.secure`
  /// because a guessable key is a way to collide with somebody else's checkout —
  /// the API scopes keys per user, so the risk is small, but the cost of using
  /// the secure generator is nothing.
  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // Version 4, variant 1, as the spec requires.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-'
        '${hex(10, 16)}';
  }

  /// Exposed for tests: proves the key survives a retry.
  String get idempotencyKey => _idempotencyKey;
}
