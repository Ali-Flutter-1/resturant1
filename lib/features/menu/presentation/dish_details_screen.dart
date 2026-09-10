import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/haptics/app_haptics.dart';
import '../../../core/money/pence.dart';
import '../../../core/animations/motion.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../features/cart/cart_cubit.dart';
import '../domain/dish.dart';
import '../domain/dish_configuration.dart';
import '../domain/dish_selection.dart';
import '../domain/spice_level.dart';
import '../../../shared/animations/fly_to_cart.dart';
import '../../../shared/widgets/cart_icon_button.dart';
import '../../../shared/widgets/dish_image.dart';
import '../../../shared/widgets/quantity_stepper.dart';
import '../../../shared/widgets/page_body.dart';

/// One dish in full: photograph, provenance, required spice level, optional
/// add-ons, and a running total that updates as choices are made.
class DishDetailsScreen extends StatefulWidget {
  const DishDetailsScreen({
    super.key,
    this.dish,
    this.onBack,
    this.onAddToCart,
    this.onOpenCart,
  });

  /// The dish that was tapped, straight from the API.
  ///
  /// It used to arrive as a preview object adapted from the real one, and the
  /// screen filled the gaps with hardcoded copy — so every dish showed the same
  /// description and the same delivery time regardless of what had been tapped.
  final Dish? dish;

  final VoidCallback? onBack;

  /// Fired once the flying copy has landed in the cart.
  final VoidCallback? onAddToCart;

  /// Tapping the cart icon itself.
  final VoidCallback? onOpenCart;

  @override
  State<DishDetailsScreen> createState() => _DishDetailsScreenState();
}

class _DishDetailsScreenState extends State<DishDetailsScreen> {
  SpiceLevel? _spice;
  int _quantity = 1;

  /// The configuration being built: variant, options and the rules that decide
  /// what is allowed. Replaced wholesale on every tap — see [DishSelection].
  late DishSelection _selection;

  /// Set once Add is tapped with an incomplete configuration, so the reason
  /// appears where the customer is looking rather than only as a disabled
  /// button they have to guess about.
  bool _showProblem = false;

  @override
  void initState() {
    super.initState();
    _selection = DishSelection.forDish(_dish);
  }

  @override
  void didUpdateWidget(DishDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different dish, or the same dish re-fetched after a stale-menu error.
    // Rebuilding from scratch is right in both cases: a selection made against
    // the old configuration may reference options that no longer exist.
    if (oldWidget.dish != widget.dish) {
      _selection = DishSelection.forDish(_dish);
      _showProblem = false;
    }
  }

  void _selectVariant(DishVariant variant) {
    AppHaptics.selection();
    setState(() {
      _selection = _selection.selectVariant(variant);
      _showProblem = false;
    });
  }

  void _changeOption(DishOptionGroup group, DishOption option, int delta) {
    final next = delta > 0
        ? _selection.increment(group, option)
        : _selection.decrement(group, option);
    // Nothing moved — a ceiling was hit. Say so with a bump rather than
    // silently ignoring the tap.
    if (next == _selection) {
      AppHaptics.failure();
      return;
    }
    AppHaptics.selection();
    setState(() {
      _selection = next;
      _showProblem = false;
    });
  }

  /// Measured at launch to position the flying copy and its destination.
  final _imageKey = GlobalKey();
  final _cartKey = GlobalKey();

  /// Guards against a second flight while one is mid-air, which would leave
  /// two copies racing to the same point.
  bool _flying = false;

  Future<void> _addToCart() async {
    if (_flying) return;

    // Refused here rather than at the API. A group short of its minimum comes
    // back as OPTION_GROUP_MINIMUM_NOT_MET, and the screen already knows which
    // group and by how many — so it can say so instead of showing an error.
    final problem = _selection.problem;
    if (problem != null) {
      AppHaptics.failure();
      setState(() => _showProblem = true);
      return;
    }

    setState(() => _flying = true);
    AppHaptics.commit();

    await FlyToCart.launch(
      context: context,
      sourceKey: _imageKey,
      targetKey: _cartKey,
      // A copy, not the original — the header image never moves.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: DishImage(name: _dish.name, imageUrl: _dish.imageUrl),
      ),
      onArrive: () {
        if (!mounted) return;
        // Spice level is a real API field, so it is sent as one. Add-ons are
        // now real too: they are configured option groups the server prices,
        // rather than the sample data squeezed into the line's free-text
        // `notes` that this screen used to offer.
        context.read<CartCubit>().addSelection(
          _selection,
          quantity: _quantity,
          spiceLevel: _spice,
        );
        AppHaptics.success();
        widget.onAddToCart?.call();
      },
    );

    if (mounted) setState(() => _flying = false);
  }

  /// Falls back to an empty dish so the screen still renders standalone, in a
  /// test or before a route has anything to hand it.
  Dish get _dish =>
      widget.dish ??
      const Dish(id: '', name: 'Dish', description: '', pricePence: 0);

  /// Provisional, and integer pence throughout. The quote replaces it at
  /// checkout — this exists so the button shows a number that moves when a
  /// choice is made.
  int get _totalPence => _selection.unitPricePence * _quantity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _DishHeader(
            dish: _dish,
            onBack: widget.onBack,
            imageKey: _imageKey,
            cartKey: _cartKey,
            onOpenCart: widget.onOpenCart,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: pagePadding(
                context,
                top: AppSpacing.x5,
                bottom: AppSpacing.x8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                // The hero carries the photograph across from the card, but the
                // body used to arrive all at once beneath it — the flight
                // landed and the page was simply there. Staggering the sections
                // lets the eye follow the same order it reads in.
                children: [
                  // The dish's own sections, not an invented "authenticity"
                  // label — the API carries categories and no such tag.
                  if (_dish.categories.isNotEmpty)
                    _AuthenticityTag(label: _dish.categories.first.name),
                  const SizedBox(height: AppSpacing.x3),
                  Text(_dish.name, style: context.texts.displayLarge),
                  const SizedBox(height: AppSpacing.x2),
                  // The kitchen's own estimate, and only when it sent one. This
                  // was "45-60 min delivery" for every dish on the menu.
                  if (_dish.prepTime != null)
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: AppIconSize.sm,
                          color: context.surfaces.inkSoft,
                        ),
                        const SizedBox(width: AppSpacing.x1 + 2),
                        Text(
                          'Ready in ${_dish.prepTime}',
                          style: context.texts.bodyMedium,
                        ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.x5),
                  Text(
                    // The dish's real description. A dish with none says so
                    // rather than borrowing another dish's paragraph.
                    _dish.description.isEmpty
                        ? 'No description yet.'
                        : _dish.description,
                    style: context.texts.bodyLarge?.copyWith(
                      color: scheme.primary.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x6),
                  const Divider(),
                  const SizedBox(height: AppSpacing.x5),

                  // The sizes, servings or packages this dish is sold in.
                  // Rendered from the API's own names and prices — nothing here
                  // assumes what kind of choice it is.
                  if (_dish.variants.isNotEmpty) ...[
                    _ChoiceSection(
                      title: 'Choose an option',
                      badge: _dish.requiresVariantSelection
                          ? 'Required'
                          : 'Optional',
                      child: _VariantSelector(
                        variants: _dish.variants,
                        selectedId: _selection.variant?.id,
                        onSelect: _selectVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x6),
                  ],

                  // Only the groups the selected variant offers. A group the
                  // dish defines but this variant does not reference is not
                  // part of this meal, and sending one earns an
                  // OPTION_NOT_OFFERED.
                  for (final group in _selection.groups) ...[
                    _OptionGroupSection(
                      group: group,
                      rule: _selection.ruleFor(group)!,
                      selection: _selection,
                      highlight:
                          _showProblem &&
                          _selection.problem?.groupId == group.id,
                      onChange: (option, delta) =>
                          _changeOption(group, option, delta),
                    ),
                    const SizedBox(height: AppSpacing.x6),
                  ],

                  // Only where the kitchen offers it. Sending a level for a dish
                  // with `has_spice_levels` false is a SPICE_LEVEL_NOT_OFFERED,
                  // so the control must not be there to tap.
                  if (_dish.hasSpiceLevels) ...[
                    _ChoiceSection(
                      // Optional, not required: the API accepts no choice, and
                      // forcing one on somebody who does not care is a decision
                      // the backend never asked for.
                      title: 'Spice Level',
                      badge: 'Optional',
                      child: Row(
                        children: [
                          for (final (i, level)
                              in SpiceLevel.values.indexed) ...[
                            if (i > 0) const SizedBox(width: AppSpacing.x3),
                            Expanded(
                              child: _SpiceOption(
                                label: level.label,
                                selected: level == _spice,
                                // Re-tapping clears it, which is the only way
                                // back to "no preference" once one is chosen.
                                onTap: () => setState(
                                  () => _spice = _spice == level ? null : level,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x6),
                  ],
                ].revealStaggered(),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _AddToCartBar(
        quantity: _quantity,
        totalPence: _totalPence,
        // Sold out is the dish's own state, not the form's — a configuration
        // can be perfectly valid for something nobody can buy today.
        soldOut: !_dish.isAvailable,
        problem: _showProblem ? _selection.problem?.message : null,
        onQuantityChanged: (q) => setState(() => _quantity = q),
        onAdd: _dish.isAvailable ? _addToCart : null,
      ),
    );
  }
}

class _DishHeader extends StatelessWidget {
  const _DishHeader({
    required this.dish,
    required this.imageKey,
    required this.cartKey,
    this.onBack,
    this.onOpenCart,
  });

  final Dish dish;
  final GlobalKey imageKey;
  final GlobalKey cartKey;
  final VoidCallback? onBack;
  final VoidCallback? onOpenCart;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 280,
      pinned: true,
      // Overscrolling zooms the photograph, the way a native iOS header does.
      stretch: true,
      stretchTriggerOffset: 120,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      // The disc only earns its place if it does something; without a
      // callback the framework's implied BackButton is the honest fallback.
      leading: onBack == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(AppSpacing.x2),
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.9),
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: onBack,
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.arrow_back, size: AppIconSize.xl),
                  ),
                ),
              ),
            ),
      actions: [
        CartIconButton(targetKey: cartKey, onTap: onOpenCart),
        const SizedBox(width: AppSpacing.x1),
      ],
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground, StretchMode.fadeTitle],
        background: DishImage(
          key: imageKey,
          name: dish.name,
          imageUrl: dish.imageUrl,
          heroTag: 'dish-${dish.name}',
        ),
      ),
    );
  }
}

class _AuthenticityTag extends StatelessWidget {
  const _AuthenticityTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colours.preparingContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label.toUpperCase(),
        style: context.texts.labelSmall
            ?.copyWith(color: colours.preparing)
            .withWeight(FontWeight.w600),
      ),
    );
  }
}

class _ChoiceSection extends StatelessWidget {
  const _ChoiceSection({
    required this.title,
    required this.badge,
    required this.child,
  });

  final String title;
  final String badge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Text(title, style: context.texts.headlineLarge)),
            const SizedBox(width: AppSpacing.x2),
            // Every section is optional now that spice level is — so the badge
            // is a quiet note rather than the boxed "Required" it used to be.
            Text(badge, style: context.texts.bodySmall),
          ],
        ),
        const SizedBox(height: AppSpacing.x3),
        child,
      ],
    );
  }
}

/// The size, serving or package picker.
///
/// A [Wrap] rather than a [Row]: the names come from an admin and can be
/// "12-inch (Classic Regular)". Three of those will not fit across a phone, and
/// a row would overflow rather than wrap.
class _VariantSelector extends StatelessWidget {
  const _VariantSelector({
    required this.variants,
    required this.selectedId,
    required this.onSelect,
  });

  final List<DishVariant> variants;
  final String? selectedId;
  final ValueChanged<DishVariant> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.x2,
      runSpacing: AppSpacing.x2,
      children: [
        for (final variant in variants)
          _VariantChip(
            variant: variant,
            selected: variant.id == selectedId,
            // A sold-out variant is shown and disabled rather than hidden: a
            // menu that silently loses a size looks broken, and the customer
            // deserves to know the 16-inch exists but has gone.
            onTap: variant.isAvailable ? () => onSelect(variant) : null,
          ),
      ],
    );
  }
}

class _VariantChip extends StatelessWidget {
  const _VariantChip({
    required this.variant,
    required this.selected,
    this.onTap,
  });

  final DishVariant variant;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = onTap == null;
    final ink = disabled
        ? context.surfaces.inkSoft
        : (selected ? scheme.primary : scheme.onSurface);

    return Semantics(
      button: true,
      selected: selected,
      enabled: !disabled,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion.fade(Motion.fast),
          curve: context.motion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x4,
            vertical: AppSpacing.x3,
          ),
          decoration: BoxDecoration(
            color: selected
                ? context.surfaces.accentContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: selected ? scheme.primary : context.surfaces.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                variant.name,
                style: context.texts.titleMedium?.copyWith(
                  color: ink,
                  decoration: disabled ? TextDecoration.lineThrough : null,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                // Each variant's own price, straight from the API. The dish's
                // `price_pence` is only the default variant's.
                disabled ? 'Sold out' : formatPence(variant.pricePence),
                style: context.texts.bodySmall?.copyWith(
                  color: disabled ? context.surfaces.inkSoft : ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One group of choices — crusts, breakfast items, extras.
///
/// The heading carries the group's terms in words, because the numbers alone
/// are not guessable: "choose 6" and "6 included, extras charged" are very
/// different offers and `included_quantity` is the one that gets misread as a
/// limit.
class _OptionGroupSection extends StatelessWidget {
  const _OptionGroupSection({
    required this.group,
    required this.rule,
    required this.selection,
    required this.onChange,
    this.highlight = false,
  });

  final DishOptionGroup group;
  final VariantGroupRule rule;
  final DishSelection selection;

  /// Called with the option and +1 or -1.
  final void Function(DishOption option, int delta) onChange;

  /// Drawn with a border when this is the group holding the order up.
  final bool highlight;

  /// The group's terms, as a sentence fragment for the badge.
  String get _badge {
    if (group.isSingleChoice) return rule.isRequired ? 'Required' : 'Optional';
    final max = rule.maxQuantity;
    if (rule.minQuantity > 0 && max != null && rule.minQuantity == max) {
      return 'Choose ${rule.minQuantity}';
    }
    if (rule.minQuantity > 0) return 'Choose ${rule.minQuantity} or more';
    if (max != null) return 'Up to $max';
    return 'Optional';
  }

  @override
  Widget build(BuildContext context) {
    final pricing = selection.pricingFor(group);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: highlight
            ? Border.all(color: context.orderColors.overdue, width: 1.5)
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(highlight ? AppSpacing.x3 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ChoiceSection(
              title: group.name,
              badge: _badge,
              child: Column(
                children: [
                  for (final option in group.options)
                    _OptionRow(
                      option: option,
                      group: group,
                      quantity: selection.quantityOf(group, option),
                      canAdd: selection.canIncrement(group, option),
                      onChange: (delta) => onChange(option, delta),
                    ),
                ],
              ),
            ),
            // The allowance, spelled out. Without this a customer choosing a
            // seventh breakfast item cannot tell whether they have broken a
            // rule or simply bought an extra.
            if (group.pricingMode == OptionPricingMode.excessOnly &&
                pricing.chosen > 0) ...[
              const SizedBox(height: AppSpacing.x3),
              _AllowanceNote(pricing: pricing, rule: rule),
            ],
          ],
        ),
      ),
    );
  }
}

/// "6 included items selected · 1 extra item +£2.00".
class _AllowanceNote extends StatelessWidget {
  const _AllowanceNote({required this.pricing, required this.rule});

  final GroupPricing pricing;
  final VariantGroupRule rule;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;
    final extra = pricing.charged;
    final money = formatPenceDelta(pricing.chargedPence);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2 + 2,
      ),
      decoration: BoxDecoration(
        color: extra > 0
            ? colours.preparingContainer
            : context.surfaces.accentContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(
            extra > 0 ? Icons.add_circle_outline : Icons.check_circle_outline,
            size: AppIconSize.sm,
            color: extra > 0 ? colours.preparing : context.surfaces.inkMuted,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              extra > 0
                  ? '${pricing.included} included, '
                        '$extra extra'
                        '${money == null ? '' : ' $money'}'
                  : '${pricing.included} of ${rule.includedQuantity} '
                        'included items chosen',
              style: context.texts.bodySmall?.copyWith(
                color: extra > 0
                    ? colours.preparing
                    : context.surfaces.inkMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One choosable option: a radio for a single-choice group, a stepper
/// otherwise.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.group,
    required this.quantity,
    required this.canAdd,
    required this.onChange,
  });

  final DishOption option;
  final DishOptionGroup group;
  final int quantity;
  final bool canAdd;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = quantity > 0;
    final disabled = !option.isAvailable;
    // A free choice shows no price at all: "+£0.00" beside a traditional crust
    // reads as a charge for something that costs nothing.
    final price = option.isFree ? null : formatPenceDelta(option.pricePence);

    return Semantics(
      selected: chosen,
      enabled: !disabled,
      child: InkWell(
        onTap: disabled
            ? null
            // Tapping the row is how a radio is chosen. For a stepper group the
            // row adds one, which is what the whole row being tappable implies.
            : () => onChange(chosen && group.isSingleChoice ? -1 : 1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          child: Row(
            children: [
              if (group.isSingleChoice)
                Icon(
                  chosen
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: AppIconSize.lg,
                  color: disabled
                      ? context.surfaces.inkSoft
                      : (chosen ? scheme.primary : context.surfaces.line),
                ),
              if (group.isSingleChoice) const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.name,
                      style: context.texts.bodyLarge?.copyWith(
                        color: disabled ? context.surfaces.inkSoft : null,
                        decoration: disabled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    if (disabled)
                      Text(
                        'Sold out',
                        style: context.texts.bodySmall?.copyWith(
                          color: context.surfaces.inkSoft,
                        ),
                      ),
                  ],
                ),
              ),
              if (price != null && !disabled) ...[
                const SizedBox(width: AppSpacing.x2),
                Text(
                  price,
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.surfaces.inkMuted,
                  ),
                ),
              ],
              if (!group.isSingleChoice && !disabled) ...[
                const SizedBox(width: AppSpacing.x3),
                _MiniStepper(
                  quantity: quantity,
                  canAdd: canAdd,
                  label: option.name,
                  onChange: onChange,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact +/- for one option row.
///
/// Shows a lone "+" until something is chosen, so a group of ten options is a
/// list of names rather than ten zeroes.
class _MiniStepper extends StatelessWidget {
  const _MiniStepper({
    required this.quantity,
    required this.canAdd,
    required this.label,
    required this.onChange,
  });

  final int quantity;
  final bool canAdd;
  final String label;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (quantity > 0) ...[
          _StepperButton(
            icon: Icons.remove,
            semanticLabel: 'One fewer $label',
            onTap: () => onChange(-1),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$quantity',
              textAlign: TextAlign.center,
              style: context.texts.titleMedium,
            ),
          ),
        ],
        _StepperButton(
          icon: Icons.add,
          semanticLabel: 'One more $label',
          // Disabled at the ceiling rather than hidden, so the row does not
          // reflow as the limit is reached.
          onTap: canAdd ? () => onChange(1) : null,
          filled: quantity == 0,
          foreground: quantity == 0 ? scheme.onPrimary : null,
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.semanticLabel,
    this.onTap,
    this.filled = false,
    this.foreground,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool filled;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    return Material(
      color: filled && enabled ? scheme.primary : Colors.transparent,
      shape: CircleBorder(
        side: filled
            ? BorderSide.none
            : BorderSide(color: context.surfaces.line),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            size: AppIconSize.md,
            semanticLabel: semanticLabel,
            color: enabled
                ? (foreground ?? scheme.onSurface)
                : context.surfaces.inkSoft,
          ),
        ),
      ),
    );
  }
}

class _SpiceOption extends StatelessWidget {
  const _SpiceOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () {
        AppHaptics.selection();
        onTap();
      },
      child: AnimatedContainer(
        duration: context.motion.fade(Motion.fast),
        curve: context.motion.standard,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? context.surfaces.accentContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? scheme.primary : context.surfaces.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: context.texts.titleMedium?.copyWith(
            color: selected ? scheme.primary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _AddToCartBar extends StatelessWidget {
  const _AddToCartBar({
    required this.quantity,
    required this.totalPence,
    required this.onQuantityChanged,
    this.onAdd,
    this.soldOut = false,
    this.problem,
  });

  final int quantity;
  final int totalPence;
  final ValueChanged<int> onQuantityChanged;
  final VoidCallback? onAdd;

  /// The dish itself is unavailable. Different from [problem]: nothing the
  /// customer chooses will fix it.
  final bool soldOut;

  /// What is stopping the order — shown above the bar once Add has been tried.
  final String? problem;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: pagePadding(context, top: AppSpacing.x3, bottom: AppSpacing.x3),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: context.surfaces.line)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Above the button, where the thumb already is. A disabled button
            // with no explanation is the version of this that gets abandoned.
            if (problem != null && !soldOut) ...[
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: AppIconSize.sm,
                    color: context.orderColors.overdue,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Text(
                      problem!,
                      style: context.texts.bodySmall?.copyWith(
                        color: context.orderColors.overdue,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x2),
            ],
            Row(
              children: [
                // Proportional rather than a fixed 132pt, so the bar survives a
                // 320pt-wide phone without crushing the price.
                Expanded(
                  flex: 4,
                  child: QuantityStepper(
                    value: quantity,
                    onChanged: onQuantityChanged,
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  flex: 6,
                  // Height and radius follow the stepper beside it, so the two read
                  // as one control bar rather than two unrelated shapes.
                  child: SizedBox(
                    height: QuantityStepper.height,
                    child: Material(
                      color: soldOut ? context.surfaces.line : scheme.primary,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: InkWell(
                        onTap: onAdd == null
                            ? null
                            : () {
                                AppHaptics.commit();
                                onAdd!();
                              },
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.x4,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Text(
                                  soldOut ? 'SOLD OUT' : 'ADD TO CART',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.texts.labelLarge?.copyWith(
                                    color: soldOut
                                        ? context.surfaces.inkMuted
                                        : scheme.onPrimary,
                                  ),
                                ),
                              ),
                              if (!soldOut) ...[
                                const SizedBox(width: AppSpacing.x2),
                                Flexible(
                                  child: AnimatedSwitcher(
                                    duration: context.motion.fade(Motion.fast),
                                    child: FittedBox(
                                      key: ValueKey(totalPence),
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        formatPence(totalPence),
                                        maxLines: 1,
                                        style: AppTypography.money(
                                          scheme.onPrimary,
                                          size: MoneySize.medium,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Sample reviews so the ratings link is a working control. Replaced by the
/// reviews endpoint when it exists.
