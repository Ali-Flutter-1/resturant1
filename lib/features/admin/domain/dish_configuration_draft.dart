import 'package:equatable/equatable.dart';

import '../../menu/domain/dish.dart';
import '../../menu/domain/dish_configuration.dart';

/// A whole dish configuration, as an admin would send it.
///
/// `PUT /admin/dishes/{id}/configuration` **replaces** everything atomically —
/// it is not a patch — so this carries the complete desired state and a caller
/// that omits a group deletes it. Building the payload from a draft rather than
/// hand-rolling a map is what makes that safe to say out loud.
///
/// Options and groups are addressed by [code], not id. The codes are what let
/// the server keep an option's identity — and any order history pointing at it
/// — when an admin renames it or changes its price. Changing a code creates a
/// new option; that is the one edit worth warning about in a UI.
class DishConfigurationDraft extends Equatable {
  const DishConfigurationDraft({
    this.variants = const [],
    this.optionGroups = const [],
  });

  /// Reads a dish's live configuration back into an editable draft.
  ///
  /// Round-trips: sending the result of this back unchanged is a no-op, which
  /// is what makes it safe to open an editor on a dish and save without having
  /// touched every field.
  factory DishConfigurationDraft.fromDish(Dish dish) => DishConfigurationDraft(
    variants: [
      for (final variant in dish.variants)
        VariantDraft(
          code: variant.code,
          name: variant.name,
          pricePence: variant.pricePence,
          isDefault: variant.isDefault,
          isAvailable: variant.isAvailable,
          sortOrder: variant.sortOrder,
          rules: [
            for (final rule in variant.groupRules)
              GroupRuleDraft(
                groupCode: rule.groupCode.isNotEmpty
                    ? rule.groupCode
                    : dish.optionGroupById(rule.optionGroupId)?.code ?? '',
                minQuantity: rule.minQuantity,
                maxQuantity: rule.maxQuantity,
                includedQuantity: rule.includedQuantity,
              ),
          ],
        ),
    ],
    optionGroups: [
      for (final group in dish.optionGroups)
        OptionGroupDraft(
          code: group.code,
          name: group.name,
          selectionType: group.selectionType,
          pricingMode: group.pricingMode,
          sortOrder: group.sortOrder,
          options: [
            for (final option in group.options)
              OptionDraft(
                code: option.code,
                name: option.name,
                pricePence: option.pricePence,
                maxQuantity: option.maxQuantity,
                isDefault: option.isDefault,
                isAvailable: option.isAvailable,
                sortOrder: option.sortOrder,
              ),
          ],
        ),
    ],
  );

  final List<VariantDraft> variants;
  final List<OptionGroupDraft> optionGroups;

  /// Everything the server would reject, found before the round trip.
  ///
  /// Checked here rather than left to a 422 because these are structural rules
  /// an editor can point at a field about — "two variants are called
  /// twelve-inch" is a far better thing to read than "validation failed".
  List<String> get problems {
    final problems = <String>[];

    if (variants.isEmpty) {
      problems.add('A dish needs at least one option to be sold in.');
    }

    final defaults = variants.where((v) => v.isDefault).length;
    if (variants.isNotEmpty && defaults != 1) {
      problems.add(
        defaults == 0
            ? 'Exactly one option must be the default. None is set.'
            : 'Exactly one option must be the default. $defaults are set.',
      );
    }

    problems.addAll(_duplicates([for (final v in variants) v.code], 'option'));
    problems.addAll(
      _duplicates([for (final g in optionGroups) g.code], 'group'),
    );

    final groupCodes = {for (final g in optionGroups) g.code};
    for (final group in optionGroups) {
      problems.addAll(
        _duplicates([
          for (final o in group.options) o.code,
        ], 'choice in ${group.name}'),
      );
      for (final option in group.options) {
        if (option.pricePence < 0) {
          problems.add('${option.name} has a negative price.');
        }
        if ((option.maxQuantity ?? 0) < 0) {
          problems.add('${option.name} has a negative maximum.');
        }
      }
    }

    for (final variant in variants) {
      if (variant.pricePence < 0) {
        problems.add('${variant.name} has a negative price.');
      }
      for (final rule in variant.rules) {
        if (!groupCodes.contains(rule.groupCode)) {
          problems.add(
            '${variant.name} refers to a group that does not exist '
            '(${rule.groupCode}).',
          );
          continue;
        }
        if (rule.minQuantity < 0 || (rule.maxQuantity ?? 0) < 0) {
          problems.add('${variant.name} has a negative quantity rule.');
        }
        final max = rule.maxQuantity;
        if (max != null && max < rule.minQuantity) {
          problems.add(
            '${variant.name} allows fewer than it requires from '
            '${rule.groupCode}.',
          );
        }
        final group = optionGroups.firstWhere(
          (g) => g.code == rule.groupCode,
          orElse: () => const OptionGroupDraft(code: '', name: ''),
        );
        // A radio group that allows two is a contradiction the customer would
        // meet as OPTION_GROUP_SINGLE_ONLY halfway through ordering.
        if (group.selectionType == OptionSelectionType.single &&
            (max ?? 1) > 1) {
          problems.add(
            '${group.name} is a single choice but ${variant.name} allows '
            '${max!}.',
          );
        }
      }
    }
    return problems;
  }

  bool get isValid => problems.isEmpty;

  static List<String> _duplicates(List<String> codes, String noun) {
    final seen = <String>{};
    final repeated = <String>{};
    for (final code in codes) {
      if (!seen.add(code)) repeated.add(code);
    }
    return [
      for (final code in repeated)
        'Two or more $noun entries share the code "$code".',
    ];
  }

  Map<String, dynamic> toJson() => {
    'variants': [for (final variant in variants) variant.toJson()],
    'option_groups': [for (final group in optionGroups) group.toJson()],
  };

  @override
  List<Object?> get props => [variants, optionGroups];
}

class VariantDraft extends Equatable {
  const VariantDraft({
    required this.code,
    required this.name,
    required this.pricePence,
    this.isDefault = false,
    this.isAvailable = true,
    this.sortOrder = 0,
    this.rules = const [],
  });

  final String code;
  final String name;
  final int pricePence;
  final bool isDefault;
  final bool isAvailable;
  final int sortOrder;
  final List<GroupRuleDraft> rules;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'price_pence': pricePence,
    'is_default': isDefault,
    'is_available': isAvailable,
    'sort_order': sortOrder,
    'option_groups': [for (final rule in rules) rule.toJson()],
  };

  @override
  List<Object?> get props => [
    code,
    name,
    pricePence,
    isDefault,
    isAvailable,
    sortOrder,
    rules,
  ];
}

class GroupRuleDraft extends Equatable {
  const GroupRuleDraft({
    required this.groupCode,
    this.minQuantity = 0,
    this.maxQuantity,
    this.includedQuantity = 0,
  });

  final String groupCode;
  final int minQuantity;
  final int? maxQuantity;
  final int includedQuantity;

  /// `max_quantity` is sent explicitly as null rather than omitted: null is a
  /// meaningful value here — "no ceiling" — and leaving the key out would let
  /// the server keep a previous limit on a replace.
  Map<String, dynamic> toJson() => {
    'group_code': groupCode,
    'min_quantity': minQuantity,
    'max_quantity': maxQuantity,
    'included_quantity': includedQuantity,
  };

  @override
  List<Object?> get props => [
    groupCode,
    minQuantity,
    maxQuantity,
    includedQuantity,
  ];
}

class OptionGroupDraft extends Equatable {
  const OptionGroupDraft({
    required this.code,
    required this.name,
    this.selectionType = OptionSelectionType.multiple,
    this.pricingMode = OptionPricingMode.always,
    this.sortOrder = 0,
    this.options = const [],
  });

  final String code;
  final String name;
  final OptionSelectionType selectionType;
  final OptionPricingMode pricingMode;
  final int sortOrder;
  final List<OptionDraft> options;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'selection_type': selectionType.wire,
    'pricing_mode': pricingMode.wire,
    'sort_order': sortOrder,
    'options': [for (final option in options) option.toJson()],
  };

  @override
  List<Object?> get props => [
    code,
    name,
    selectionType,
    pricingMode,
    sortOrder,
    options,
  ];
}

class OptionDraft extends Equatable {
  const OptionDraft({
    required this.code,
    required this.name,
    required this.pricePence,
    this.maxQuantity,
    this.isDefault = false,
    this.isAvailable = true,
    this.sortOrder = 0,
  });

  final String code;
  final String name;
  final int pricePence;
  final int? maxQuantity;
  final bool isDefault;
  final bool isAvailable;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'price_pence': pricePence,
    'max_quantity': maxQuantity,
    'is_default': isDefault,
    'is_available': isAvailable,
    'sort_order': sortOrder,
  };

  @override
  List<Object?> get props => [
    code,
    name,
    pricePence,
    maxQuantity,
    isDefault,
    isAvailable,
    sortOrder,
  ];
}
