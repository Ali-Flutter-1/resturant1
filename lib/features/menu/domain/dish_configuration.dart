import 'package:equatable/equatable.dart';

/// How many choices a group takes.
///
/// The wire values are the API's own. Anything unrecognised is treated as
/// [multiple], which is the tolerant direction: a group the app renders as
/// checkboxes when the server meant radios earns a `OPTION_GROUP_SINGLE_ONLY`
/// that the customer can recover from, whereas the reverse silently hides
/// choices the kitchen offers.
enum OptionSelectionType {
  single('single'),
  multiple('multiple');

  const OptionSelectionType(this.wire);

  final String wire;

  static OptionSelectionType fromApi(String? raw) =>
      raw?.trim().toLowerCase() == 'single' ? single : multiple;
}

/// Whether every selected unit is charged, or only the ones past the allowance.
///
/// This is the difference between a paid add-on and a 6-item breakfast, and it
/// is the single most misread field in the menu contract: `excess_only` does
/// **not** cap how much can be chosen, it caps how much is free.
enum OptionPricingMode {
  /// Each selected unit costs `option.price_pence`. Extra cheese, stuffed
  /// crust, an extra portion.
  always('always'),

  /// The first `included_quantity` units across the group are inside the
  /// variant's base price; everything after that is charged.
  excessOnly('excess_only');

  const OptionPricingMode(this.wire);

  final String wire;

  static OptionPricingMode fromApi(String? raw) =>
      raw?.trim().toLowerCase() == 'excess_only' ? excessOnly : always;
}

/// One choice inside an option group.
class DishOption extends Equatable {
  const DishOption({
    required this.id,
    required this.name,
    required this.pricePence,
    this.code = '',
    this.maxQuantity,
    this.isDefault = false,
    this.isAvailable = true,
    this.sortOrder = 0,
  });

  factory DishOption.fromJson(Map<String, dynamic> json) => DishOption(
    id: json['id']?.toString() ?? '',
    code: json['code']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    pricePence: (json['price_pence'] as num?)?.toInt() ?? 0,
    // Null means no per-option ceiling. Zero would mean "cannot be chosen",
    // which is a different thing, so absent must not collapse to zero.
    maxQuantity: (json['max_quantity'] as num?)?.toInt(),
    isDefault: json['is_default'] == true,
    isAvailable: json['is_available'] != false,
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
  );

  final String id;

  /// The admin's stable handle. Not shown to a customer and not sent when
  /// ordering — ids go on the wire — but it is what keeps an option's identity
  /// across a rename, so it is worth carrying.
  final String code;

  final String name;

  /// What one unit costs where it is charged at all. Zero is legitimate: a
  /// traditional crust that costs nothing is still a choice worth offering.
  final int pricePence;

  /// This option's own ceiling, independent of the group's.
  final int? maxQuantity;

  final bool isDefault;
  final bool isAvailable;
  final int sortOrder;

  /// Free at the point of choosing, so the row shows no price at all rather
  /// than a distracting "+£0.00".
  bool get isFree => pricePence == 0;

  @override
  List<Object?> get props => [
    id,
    code,
    name,
    pricePence,
    maxQuantity,
    isDefault,
    isAvailable,
    sortOrder,
  ];
}

/// A set of related choices — crusts, breakfast items, spice strengths.
///
/// The group owns the options and how they are chosen. What it does *not* own
/// is whether it applies: that is per variant, and lives in [VariantGroupRule].
/// A 12-inch pizza and a 16-inch pizza can share this crust group while
/// allowing different numbers of them.
class DishOptionGroup extends Equatable {
  const DishOptionGroup({
    required this.id,
    required this.name,
    this.code = '',
    this.selectionType = OptionSelectionType.multiple,
    this.pricingMode = OptionPricingMode.always,
    this.sortOrder = 0,
    this.options = const [],
  });

  factory DishOptionGroup.fromJson(Map<String, dynamic> json) {
    final options = json['options'];
    return DishOptionGroup(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      selectionType: OptionSelectionType.fromApi(
        json['selection_type']?.toString(),
      ),
      pricingMode: OptionPricingMode.fromApi(json['pricing_mode']?.toString()),
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      options: options is List
          ? (options
                .whereType<Map>()
                .map((o) => DishOption.fromJson(Map<String, dynamic>.from(o)))
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
          : const [],
    );
  }

  final String id;
  final String code;
  final String name;
  final OptionSelectionType selectionType;
  final OptionPricingMode pricingMode;
  final int sortOrder;

  /// Already in `sort_order`, so every screen renders them the same way without
  /// remembering to sort.
  final List<DishOption> options;

  bool get isSingleChoice => selectionType == OptionSelectionType.single;

  /// Only the ones that can actually be chosen. An unavailable option is shown
  /// disabled but must never be sent.
  List<DishOption> get available => [
    for (final option in options)
      if (option.isAvailable) option,
  ];

  DishOption? optionById(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  @override
  List<Object?> get props => [
    id,
    code,
    name,
    selectionType,
    pricingMode,
    sortOrder,
    options,
  ];
}

/// How one variant uses one option group.
///
/// The numbers are the whole point of the configurable model:
///
///   * [minQuantity] — the customer cannot order until this many units are
///     chosen across the group. Zero means the group is optional.
///   * [maxQuantity] — the real ceiling. Null means the group itself sets no
///     limit (individual options may still cap themselves).
///   * [includedQuantity] — for an `excess_only` group, how many units the
///     variant's base price already covers. **Not a limit.** A 6-item breakfast
///     can take a seventh item; the seventh is simply charged.
class VariantGroupRule extends Equatable {
  const VariantGroupRule({
    required this.optionGroupId,
    this.groupCode = '',
    this.minQuantity = 0,
    this.maxQuantity,
    this.includedQuantity = 0,
  });

  factory VariantGroupRule.fromJson(Map<String, dynamic> json) =>
      VariantGroupRule(
        optionGroupId: json['option_group_id']?.toString() ?? '',
        groupCode: json['group_code']?.toString() ?? '',
        minQuantity: (json['min_quantity'] as num?)?.toInt() ?? 0,
        maxQuantity: (json['max_quantity'] as num?)?.toInt(),
        includedQuantity: (json['included_quantity'] as num?)?.toInt() ?? 0,
      );

  final String optionGroupId;
  final String groupCode;
  final int minQuantity;
  final int? maxQuantity;
  final int includedQuantity;

  bool get isRequired => minQuantity > 0;

  @override
  List<Object?> get props => [
    optionGroupId,
    groupCode,
    minQuantity,
    maxQuantity,
    includedQuantity,
  ];
}

/// One buyable configuration of a dish: a size, a serving, a portion, a package.
///
/// Deliberately unnamed by kind. The same field carries "14-inch", "Bottle" and
/// "6 Items", and the app must never assume which — no hardcoded Small/Medium/
/// Large, no assumption that a drink has two servings.
class DishVariant extends Equatable {
  const DishVariant({
    required this.id,
    required this.name,
    required this.pricePence,
    this.code = '',
    this.isDefault = false,
    this.isAvailable = true,
    this.sortOrder = 0,
    this.groupRules = const [],
  });

  factory DishVariant.fromJson(Map<String, dynamic> json) {
    final rules = json['option_groups'];
    return DishVariant(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      pricePence: (json['price_pence'] as num?)?.toInt() ?? 0,
      isDefault: json['is_default'] == true,
      isAvailable: json['is_available'] != false,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      groupRules: rules is List
          ? rules
                .whereType<Map>()
                .map(
                  (r) =>
                      VariantGroupRule.fromJson(Map<String, dynamic>.from(r)),
                )
                .toList()
          : const [],
    );
  }

  final String id;
  final String code;
  final String name;

  /// This variant's own base price. The dish's `price_pence` is only the
  /// default variant's, kept for older clients.
  final int pricePence;

  final bool isDefault;
  final bool isAvailable;
  final int sortOrder;

  /// Which groups this variant offers, and on what terms. A group the dish
  /// defines but this variant does not reference must not be shown or sent.
  final List<VariantGroupRule> groupRules;

  VariantGroupRule? ruleFor(String optionGroupId) {
    for (final rule in groupRules) {
      if (rule.optionGroupId == optionGroupId) return rule;
    }
    return null;
  }

  @override
  List<Object?> get props => [
    id,
    code,
    name,
    pricePence,
    isDefault,
    isAvailable,
    sortOrder,
    groupRules,
  ];
}

/// One chosen option and how many of it.
///
/// This is what goes on the wire, and it is all that goes on the wire: an id
/// and a count. No prices — the backend owns every one of them.
class CartOptionSelection extends Equatable {
  const CartOptionSelection({required this.optionId, required this.quantity});

  final String optionId;
  final int quantity;

  Map<String, dynamic> toJson() => {
    'option_id': optionId,
    'quantity': quantity,
  };

  @override
  List<Object?> get props => [optionId, quantity];
}
