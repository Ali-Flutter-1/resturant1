import 'package:equatable/equatable.dart';

import '../../../core/money/pence.dart' as money;
import '../../menu/domain/spice_level.dart';

/// One chosen option as the server priced it.
///
/// The included/charged split is the server's, and it is the only version worth
/// showing: the app's own preview guesses at selection order, and the wording
/// on a receipt has to match what was actually billed.
class QuoteSelection extends Equatable {
  const QuoteSelection({
    required this.optionName,
    required this.quantity,
    this.optionId,
    this.groupName,
    this.includedQuantity = 0,
    this.chargeableQuantity = 0,
    this.unitPricePence = 0,
    this.totalPence = 0,
  });

  factory QuoteSelection.fromJson(Map<String, dynamic> json) {
    final quantity = (json['quantity'] as num?)?.toInt() ?? 0;
    final included = (json['included_quantity'] as num?)?.toInt();
    final chargeable = (json['chargeable_quantity'] as num?)?.toInt();
    return QuoteSelection(
      optionId: json['option_id']?.toString(),
      groupName: _text(json['group_name']),
      optionName: json['option_name']?.toString() ?? 'Option',
      quantity: quantity,
      // Either side of the split can be derived from the other, so an older
      // response that sends one still renders correctly.
      includedQuantity: included ?? (quantity - (chargeable ?? 0)),
      chargeableQuantity: chargeable ?? (quantity - (included ?? 0)),
      unitPricePence: (json['unit_price_pence'] as num?)?.toInt() ?? 0,
      totalPence: (json['total_pence'] as num?)?.toInt() ?? 0,
    );
  }

  static String? _text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  final String? optionId;

  /// The group it came from — "Choose Your Items" — for grouping a long
  /// breakdown under headings.
  final String? groupName;

  final String optionName;
  final int quantity;

  /// How many units the variant's base price covered.
  final int includedQuantity;

  /// How many were charged for.
  final int chargeableQuantity;

  final int unitPricePence;

  /// What this option added to the line. Zero for a fully included option.
  final int totalPence;

  /// Whether any of this option cost extra.
  bool get isCharged => totalPence > 0;

  /// "4x Egg Hopper" or "Egg Hopper".
  String get label => quantity > 1 ? '$quantity x $optionName' : optionName;

  @override
  List<Object?> get props => [
    optionId,
    groupName,
    optionName,
    quantity,
    includedQuantity,
    chargeableQuantity,
    unitPricePence,
    totalPence,
  ];
}

/// One priced line in a quote.
class QuoteLine extends Equatable {
  const QuoteLine({
    required this.name,
    required this.quantity,
    required this.unitPricePence,
    required this.linePence,
    this.dishId,
    this.spiceLevel,
    this.notes,
    this.variantId,
    this.variantName,
    this.basePricePence = 0,
    this.optionsTotalPence = 0,
    this.selections = const [],
  });

  factory QuoteLine.fromJson(Map<String, dynamic> json) {
    final selections = json['selections'];
    return QuoteLine(
      name: json['name']?.toString() ?? 'Item',
      dishId: json['dish_id']?.toString(),
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      unitPricePence: (json['unit_price_pence'] as num?)?.toInt() ?? 0,
      linePence: (json['line_total_pence'] as num?)?.toInt() ?? 0,
      spiceLevel: SpiceLevel.tryParse(json['spice_level']),
      notes: json['notes']?.toString(),
      variantId: json['variant_id']?.toString(),
      variantName: _text(json['variant_name']),
      basePricePence: (json['base_price_pence'] as num?)?.toInt() ?? 0,
      optionsTotalPence: (json['options_total_pence'] as num?)?.toInt() ?? 0,
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

  static String? _text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  final String name;

  /// Echoed back by the API, which is what lets the checkout pair a priced line
  /// with the basket line it can edit.
  final String? dishId;

  /// The variant, echoed back for the same reason: a basket holding two
  /// differently sized versions of one dish needs both halves to pair them.
  final String? variantId;

  /// "6 Items", "14-inch", "Bottle" — the admin's own words.
  final String? variantName;

  final int quantity;

  /// The variant's base price, before options.
  final int basePricePence;

  /// What the options added to one unit.
  final int optionsTotalPence;

  final int unitPricePence;
  final int linePence;
  final SpiceLevel? spiceLevel;
  final String? notes;

  /// The chosen options as priced, including which units were free.
  final List<QuoteSelection> selections;

  /// The dish and its variant on one line — "Custom Breakfast (6 Items)".
  String get titleWithVariant =>
      variantName == null ? name : '$name ($variantName)';

  /// Only the options that cost something, for a summary that has room for a
  /// couple of lines rather than a full breakdown.
  List<QuoteSelection> get chargedSelections => [
    for (final selection in selections)
      if (selection.isCharged) selection,
  ];

  @override
  List<Object?> get props => [
    name,
    dishId,
    variantId,
    variantName,
    quantity,
    basePricePence,
    optionsTotalPence,
    unitPricePence,
    linePence,
    spiceLevel,
    notes,
    selections,
  ];
}

/// The server's price for a basket.
///
/// Nothing here is calculated in the app. The guide is explicit: render the
/// returned prices, not local arithmetic — a total the app worked out is display
/// information, and the server's is the one that gets charged.
class OrderQuote extends Equatable {
  const OrderQuote({
    this.lines = const [],
    this.subtotalPence = 0,
    this.deliveryFeePence = 0,
    this.totalPence = 0,
    this.minimumOrderPence = 0,
    this.meetsMinimum = true,
    this.earliestSlot,
    this.availableSlots = const [],
    this.deliveryZoneId,
    this.deliveryZoneName,
  });

  factory OrderQuote.fromJson(Map<String, dynamic> json) {
    final lines = json['items'];
    final slots = json['available_slots'];
    return OrderQuote(
      lines: lines is List
          ? lines
                .whereType<Map>()
                .map((l) => QuoteLine.fromJson(Map<String, dynamic>.from(l)))
                .toList()
          : const [],
      subtotalPence: (json['subtotal_pence'] as num?)?.toInt() ?? 0,
      deliveryFeePence: (json['delivery_fee_pence'] as num?)?.toInt() ?? 0,
      totalPence: (json['total_pence'] as num?)?.toInt() ?? 0,
      minimumOrderPence: (json['minimum_order_pence'] as num?)?.toInt() ?? 0,
      meetsMinimum: json['meets_minimum'] != false,
      earliestSlot: _date(json['earliest_slot']),
      // Which zone priced this delivery. Worth showing: a customer who sees
      // "Zone 2 - £3.50" understands the fee, where a bare number reads as
      // arbitrary. Null for collection, and for a flat-rate deployment.
      deliveryZoneId: _text(json['delivery_zone_id']),
      deliveryZoneName: _text(json['delivery_zone_name']),
      // Kept as the API sent them. The guide says to use these rather than
      // rebuilding the slot rules, which is why the raw strings survive
      // alongside the parsed times — `requested_for` must go back exactly as it
      // came, offset included.
      availableSlots: slots is List
          ? slots
                .map((s) => s?.toString())
                .whereType<String>()
                .toList(growable: false)
          : const [],
    );
  }

  static DateTime? _date(Object? raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString());

  static String? _text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  final List<QuoteLine> lines;
  final int subtotalPence;
  final int deliveryFeePence;
  final int totalPence;
  final int minimumOrderPence;

  /// False blocks placing a delivery order. The delivery fee does not count
  /// towards the minimum, so the shortfall is measured on the subtotal.
  final bool meetsMinimum;

  final DateTime? earliestSlot;

  /// ISO strings, verbatim from the API.
  final List<String> availableSlots;

  /// The zone the server used to price delivery, where it used one.
  final String? deliveryZoneId;
  final String? deliveryZoneName;

  /// How much more is needed to reach the minimum, in pence.
  int get shortfallPence {
    final short = minimumOrderPence - subtotalPence;
    return short > 0 ? short : 0;
  }

  /// Kept as a static on the quote because a couple of dozen call sites read
  /// it that way. The implementation is `core/money/pence.dart`.
  static String formatPence(int pence) => money.formatPence(pence);

  String get formattedSubtotal => formatPence(subtotalPence);
  String get formattedFee => formatPence(deliveryFeePence);
  String get formattedTotal => formatPence(totalPence);
  String get formattedShortfall => formatPence(shortfallPence);

  @override
  List<Object?> get props => [
    lines,
    subtotalPence,
    deliveryFeePence,
    totalPence,
    minimumOrderPence,
    meetsMinimum,
    earliestSlot,
    availableSlots,
    deliveryZoneId,
    deliveryZoneName,
  ];
}
