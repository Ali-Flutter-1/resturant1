import 'dart:collection';

import 'package:equatable/equatable.dart';

import 'dish.dart';
import 'dish_configuration.dart';

/// How one group's choices are pricing out, for the "6 included, 1 extra" line.
class GroupPricing extends Equatable {
  const GroupPricing({
    required this.chosen,
    required this.included,
    required this.charged,
    required this.chargedPence,
  });

  /// Units chosen across the whole group.
  final int chosen;

  /// How many of them the variant's base price covers.
  final int included;

  /// How many are being charged for.
  final int charged;

  /// What those charged units come to, in pence.
  final int chargedPence;

  @override
  List<Object?> get props => [chosen, included, charged, chargedPence];
}

/// Why a configuration cannot be added to the basket yet.
///
/// Returned rather than thrown: this is the state of a half-filled form, not an
/// error. The screen turns it into a sentence under the button.
class SelectionProblem extends Equatable {
  const SelectionProblem({required this.message, this.groupId});

  final String message;

  /// The group to scroll to, where one is at fault.
  final String? groupId;

  @override
  List<Object?> get props => [message, groupId];
}

/// A customer's in-progress configuration of one dish.
///
/// Immutable, so the details screen holds one in `setState` and every tap
/// produces a new one. All the awkward rules — which groups a variant offers,
/// what counts as full, which units are free — live here rather than in the
/// widget, because they are the part worth testing and the part that is easy to
/// get subtly wrong.
///
/// The prices it works out are **provisional**. They exist so the button can
/// show a number that moves when a choice is made; the authority is always
/// `POST /orders/quote`, and the guide is explicit that the quote replaces this
/// before checkout.
class DishSelection extends Equatable {
  // Not const: the per-group maps are built as choices are made. Every public
  // entry point returns a fresh instance, so the object is still immutable in
  // the sense that matters -- nothing mutates one that has been handed out.
  // ignore: prefer_const_constructors_in_immutables
  DishSelection._({
    required this.dish,
    required this.variant,
    required Map<String, LinkedHashMap<String, int>> chosen,
  }) : _chosen = chosen;

  /// Starts from the dish's own defaults: the default variant, and any option
  /// flagged `is_default` in a group that variant offers.
  factory DishSelection.forDish(Dish dish) {
    final selection = DishSelection._(
      dish: dish,
      variant: _defaultVariant(dish),
      chosen: {},
    );
    return selection._applyDefaults();
  }

  /// The default variant, or the first available one, or the first at all.
  ///
  /// Three fallbacks because a dish whose default has been marked sold out
  /// still has to open on *something* — an empty selector reads as a broken
  /// screen, and `requires_variant_selection` then makes the customer confirm.
  static DishVariant? _defaultVariant(Dish dish) {
    if (dish.variants.isEmpty) return null;
    for (final variant in dish.variants) {
      if (variant.isDefault && variant.isAvailable) return variant;
    }
    for (final variant in dish.variants) {
      if (variant.isAvailable) return variant;
    }
    return dish.variants.first;
  }

  final Dish dish;

  /// Null for a dish with no variants at all — the ordinary, unconfigured
  /// dish, which is still most of the menu.
  final DishVariant? variant;

  /// Group id → option id → quantity.
  ///
  /// A [LinkedHashMap] per group on purpose: for an `excess_only` group the
  /// backend decides which units are free by **selection order**, and the app's
  /// preview has to agree with it or the price appears to jump on quoting.
  final Map<String, LinkedHashMap<String, int>> _chosen;

  DishSelection _copy({
    DishVariant? variant,
    Map<String, LinkedHashMap<String, int>>? chosen,
    bool clearVariant = false,
  }) => DishSelection._(
    dish: dish,
    variant: clearVariant ? null : (variant ?? this.variant),
    chosen: chosen ?? _chosen,
  );

  Map<String, LinkedHashMap<String, int>> _cloneChosen() => {
    for (final entry in _chosen.entries)
      entry.key: LinkedHashMap<String, int>.of(entry.value),
  };

  /// Ticks the `is_default` options of every group the current variant offers.
  DishSelection _applyDefaults() {
    var next = this;
    for (final group in next.groups) {
      for (final option in group.options) {
        if (!option.isDefault || !option.isAvailable) continue;
        // Routed through [increment] so a default that would break the group's
        // own ceiling is dropped rather than trusted.
        next = next.increment(group, option);
      }
    }
    return next;
  }

  /// The groups this variant offers, in `sort_order`.
  ///
  /// A group the dish defines but the selected variant does not reference is
  /// not part of this meal and must be neither shown nor sent.
  List<DishOptionGroup> get groups {
    final selected = variant;
    if (selected == null) return const [];
    final visible = [
      for (final group in dish.optionGroups)
        if (selected.ruleFor(group.id) != null) group,
    ];
    visible.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return visible;
  }

  /// The rule tying [group] to the selected variant, or null when it does not
  /// apply.
  VariantGroupRule? ruleFor(DishOptionGroup group) =>
      variant?.ruleFor(group.id);

  int quantityOf(DishOptionGroup group, DishOption option) =>
      _chosen[group.id]?[option.id] ?? 0;

  /// Units chosen across a whole group. This — not the number of distinct
  /// options — is what `min_quantity` and `max_quantity` measure.
  int chosenIn(DishOptionGroup group) {
    final inGroup = _chosen[group.id];
    if (inGroup == null) return 0;
    return inGroup.values.fold(0, (sum, quantity) => sum + quantity);
  }

  /// Whether one more of [option] is allowed.
  ///
  /// Three ceilings, all of which must hold: the group's `max_quantity`, the
  /// option's own `max_quantity`, and — for a single-choice group — the one
  /// unit such a group can ever hold.
  bool canIncrement(DishOptionGroup group, DishOption option) {
    if (!option.isAvailable) return false;
    final rule = ruleFor(group);
    if (rule == null) return false;

    if (group.isSingleChoice) return quantityOf(group, option) < 1;

    final groupMax = rule.maxQuantity;
    if (groupMax != null && chosenIn(group) >= groupMax) return false;

    final optionMax = option.maxQuantity;
    if (optionMax != null && quantityOf(group, option) >= optionMax) {
      return false;
    }
    return true;
  }

  /// Adds one of [option].
  ///
  /// For a single-choice group this *replaces* whatever was chosen, which is
  /// what a radio button means. Re-selecting the option already chosen clears
  /// it, so an optional single-choice group can be returned to "no preference"
  /// — the only way back once a choice is made.
  DishSelection increment(DishOptionGroup group, DishOption option) {
    if (!option.isAvailable || ruleFor(group) == null) return this;
    final chosen = _cloneChosen();

    if (group.isSingleChoice) {
      final already = quantityOf(group, option) > 0;
      final rule = ruleFor(group)!;
      if (already) {
        // A required group cannot be emptied by tapping its own answer again;
        // there would be no way back to a valid state except guessing.
        if (rule.isRequired) return this;
        chosen.remove(group.id);
      } else {
        chosen[group.id] = LinkedHashMap<String, int>.of({option.id: 1});
      }
      return _copy(chosen: chosen);
    }

    if (!canIncrement(group, option)) return this;
    final inGroup = chosen[group.id] ??= LinkedHashMap<String, int>();
    inGroup[option.id] = (inGroup[option.id] ?? 0) + 1;
    return _copy(chosen: chosen);
  }

  /// Removes one of [option], dropping the entry at zero so nothing with a
  /// quantity of zero can ever reach the wire.
  DishSelection decrement(DishOptionGroup group, DishOption option) {
    final current = quantityOf(group, option);
    if (current == 0) return this;
    final chosen = _cloneChosen();
    final inGroup = chosen[group.id]!;

    if (current == 1) {
      inGroup.remove(option.id);
      if (inGroup.isEmpty) chosen.remove(group.id);
    } else {
      inGroup[option.id] = current - 1;
    }
    return _copy(chosen: chosen);
  }

  /// Switches variant, keeping whatever choices the new one still offers.
  ///
  /// Keeping them matters: going from a 12-inch to a 14-inch pizza should not
  /// silently forget the stuffed crust. Anything the new variant does not offer
  /// is dropped, and quantities are re-applied one at a time so the new
  /// variant's own ceilings are what decide — a 14-inch that allows fewer
  /// toppings trims rather than overflows.
  DishSelection selectVariant(DishVariant next) {
    if (!next.isAvailable || next.id == variant?.id) return this;

    var rebuilt = _copy(variant: next, chosen: {});
    for (final group in rebuilt.groups) {
      final previous = _chosen[group.id];
      if (previous == null) continue;
      for (final entry in previous.entries) {
        final option = group.optionById(entry.key);
        if (option == null || !option.isAvailable) continue;
        for (var i = 0; i < entry.value; i++) {
          rebuilt = rebuilt.increment(group, option);
        }
      }
    }

    // A group the old variant never showed may have defaults of its own.
    for (final group in rebuilt.groups) {
      if (rebuilt.chosenIn(group) > 0) continue;
      for (final option in group.options) {
        if (!option.isDefault || !option.isAvailable) continue;
        rebuilt = rebuilt.increment(group, option);
      }
    }
    return rebuilt;
  }

  /// How [group] is pricing out under the current variant's rule.
  ///
  /// For an `always` group every unit is charged. For `excess_only` the first
  /// `included_quantity` units — in the order they were chosen — are inside the
  /// base price, and the rest are charged at their own option price.
  GroupPricing pricingFor(DishOptionGroup group) {
    final rule = ruleFor(group);
    final inGroup = _chosen[group.id];
    if (rule == null || inGroup == null || inGroup.isEmpty) {
      return const GroupPricing(
        chosen: 0,
        included: 0,
        charged: 0,
        chargedPence: 0,
      );
    }

    final chosen = chosenIn(group);
    if (group.pricingMode == OptionPricingMode.always) {
      var pence = 0;
      for (final entry in inGroup.entries) {
        pence += (group.optionById(entry.key)?.pricePence ?? 0) * entry.value;
      }
      return GroupPricing(
        chosen: chosen,
        included: 0,
        charged: chosen,
        chargedPence: pence,
      );
    }

    var allowance = rule.includedQuantity;
    var charged = 0;
    var pence = 0;
    // Insertion order is selection order, which is how the backend decides
    // which units the allowance covers.
    for (final entry in inGroup.entries) {
      final free = entry.value < allowance ? entry.value : allowance;
      allowance -= free;
      final paid = entry.value - free;
      if (paid > 0) {
        charged += paid;
        pence += (group.optionById(entry.key)?.pricePence ?? 0) * paid;
      }
    }
    return GroupPricing(
      chosen: chosen,
      included: chosen - charged,
      charged: charged,
      chargedPence: pence,
    );
  }

  /// The base price of the configured meal, before options.
  int get basePricePence => variant?.pricePence ?? dish.pricePence;

  /// What the chosen options add, in pence.
  int get optionsPence {
    var pence = 0;
    for (final group in groups) {
      pence += pricingFor(group).chargedPence;
    }
    return pence;
  }

  /// One configured meal, provisionally. Replaced by the quote at checkout.
  int get unitPricePence => basePricePence + optionsPence;

  /// The first thing stopping this going in the basket, or null when it can.
  ///
  /// Only ever about *this* configuration. Whether the dish is sold out is the
  /// screen's business, not the form's.
  SelectionProblem? get problem {
    final selected = variant;
    if (dish.variants.isNotEmpty) {
      if (selected == null) {
        return const SelectionProblem(message: 'Choose an option to continue.');
      }
      if (!selected.isAvailable) {
        return SelectionProblem(
          message: '${selected.name} is sold out — choose another.',
        );
      }
    }

    for (final group in groups) {
      final rule = ruleFor(group)!;
      final chosen = chosenIn(group);
      if (chosen >= rule.minQuantity) continue;
      final short = rule.minQuantity - chosen;
      return SelectionProblem(
        groupId: group.id,
        message: group.isSingleChoice
            ? 'Choose ${group.name.toLowerCase()} to continue.'
            : 'Choose $short more from ${group.name} to continue.',
      );
    }
    return null;
  }

  bool get isComplete => problem == null;

  /// Exactly what the API accepts: option ids and quantities, each id once,
  /// nothing at zero, and nothing from a group this variant does not offer.
  List<CartOptionSelection> get wireSelections => [
    for (final group in groups)
      for (final entry
          in (_chosen[group.id]?.entries ?? const <MapEntry<String, int>>[]))
        if (entry.value > 0)
          CartOptionSelection(optionId: entry.key, quantity: entry.value),
  ];

  /// A short human summary — "6 Items · 4× Egg Hopper, 3× Crispy Bacon" — for
  /// the basket row and the fly-to-cart confirmation.
  String? get summary {
    final parts = <String>[
      for (final group in groups)
        for (final entry
            in (_chosen[group.id]?.entries ?? const <MapEntry<String, int>>[]))
          if (entry.value > 0)
            entry.value == 1
                ? (group.optionById(entry.key)?.name ?? '')
                : '${entry.value}× ${group.optionById(entry.key)?.name ?? ''}',
    ]..removeWhere((part) => part.isEmpty);
    return parts.isEmpty ? null : parts.join(', ');
  }

  @override
  List<Object?> get props => [
    dish.id,
    variant?.id,
    // Maps compare by identity, so the flattened selections are what makes two
    // states equal — and what makes the screen rebuild when one changes.
    [
      for (final group in groups)
        '${group.id}:${(_chosen[group.id]?.entries ?? const <MapEntry<String, int>>[]).map((e) => '${e.key}=${e.value}').join(',')}',
    ],
  ];
}
