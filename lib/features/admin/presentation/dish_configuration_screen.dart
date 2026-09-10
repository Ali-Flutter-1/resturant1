import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/haptics/app_haptics.dart';
import '../../../core/money/pence.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/page_body.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/domain/dish.dart';
import '../../menu/domain/dish_configuration.dart';
import '../domain/admin_menu_repository.dart';
import '../domain/dish_configuration_draft.dart';
import 'dish_configuration_cubit.dart';

/// Editing how one dish is sold: its sizes and its choices.
///
/// One screen for every kind of product. There is no pizza editor and no
/// breakfast editor — a size, a serving, a portion and a package are the same
/// idea, and the backend has one endpoint for all of them precisely so this
/// screen does not fork by category.
///
/// Everything is edited locally and written once. The endpoint replaces the
/// whole configuration atomically, so a save that went field by field could
/// leave a dish half-configured mid-service.
class DishConfigurationScreen extends StatelessWidget {
  const DishConfigurationScreen({super.key, required this.dish});

  final Dish dish;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => DishConfigurationCubit(
        repository: context.read<AdminMenuRepository>(),
        dish: dish,
      ),
      child: _ConfigurationView(dishName: dish.name),
    );
  }
}

class _ConfigurationView extends StatelessWidget {
  const _ConfigurationView({required this.dishName});

  final String dishName;

  Future<void> _save(BuildContext context) async {
    final cubit = context.read<DishConfigurationCubit>();
    final saved = await cubit.save();
    if (!context.mounted) return;

    if (saved != null) {
      AppHaptics.success();
      showAppSnack(context, 'Options saved.');
      Navigator.of(context).pop(saved);
      return;
    }
    AppHaptics.failure();
    final failure = cubit.state.failure;
    if (failure != null) showAppSnack(context, failure.message, isError: true);
  }

  /// Asks before losing edits. The structure can take a while to build, and
  /// there is no draft kept anywhere — a stray back gesture would cost all of
  /// it.
  Future<bool> _confirmDiscard(BuildContext context) async {
    if (!context.read<DishConfigurationCubit>().state.isDirty) return true;

    final leave = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Discard these options?'),
        content: const Text(
          'Nothing has been saved yet. Your sizes and choices will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.orderColors.overdue,
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DishConfigurationCubit, DishConfigurationState>(
      builder: (context, state) {
        final cubit = context.read<DishConfigurationCubit>();

        return PopScope(
          canPop: !state.isDirty,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop || !context.mounted) return;
            if (await _confirmDiscard(context) && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Options & extras'),
              actions: [
                if (state.saving)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                    child: Center(
                      child: SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  TextButton(
                    onPressed: state.canSave ? () => _save(context) : null,
                    child: const Text('Save'),
                  ),
              ],
            ),
            body: ListView(
              padding: pagePadding(
                context,
                top: AppSpacing.x4,
                bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                _Explainer(dishName: dishName),
                const SizedBox(height: AppSpacing.x4),

                if (state.problems.isNotEmpty) ...[
                  _Problems(problems: state.problems),
                  const SizedBox(height: AppSpacing.x4),
                ],

                const SectionHeader(title: 'Sold in'),
                // The line an admin needs: this is the list a customer picks
                // from, and its prices are the ones charged.
                _Caption(
                  text: state.draft.variants.isEmpty
                      ? 'Add at least one size, serving or package.'
                      : 'Each one has its own price.',
                ),
                const SizedBox(height: AppSpacing.x3),
                for (final variant in state.draft.variants) ...[
                  _VariantRow(
                    variant: variant,
                    groups: state.draft.optionGroups,
                    canDelete: state.draft.variants.length > 1,
                  ),
                  const SizedBox(height: AppSpacing.x2),
                ],
                const SizedBox(height: AppSpacing.x2),
                SecondaryButton(
                  label: 'Add a size or serving',
                  onPressed: () => _addVariant(context, cubit),
                ),

                const SizedBox(height: AppSpacing.x8),
                const SectionHeader(title: 'Choice groups'),
                _Caption(
                  text: state.draft.optionGroups.isEmpty
                      ? 'Crusts, fillings, extras — anything a customer picks.'
                      : 'Which sizes offer each group is set on the size.',
                ),
                const SizedBox(height: AppSpacing.x3),
                for (final group in state.draft.optionGroups) ...[
                  _GroupCard(group: group),
                  const SizedBox(height: AppSpacing.x3),
                ],
                SecondaryButton(
                  label: 'Add a choice group',
                  onPressed: () => _addGroup(context, cubit),
                ),

                if (state.isDirty) ...[
                  const SizedBox(height: AppSpacing.x6),
                  TextButton(
                    onPressed: cubit.revert,
                    child: const Text('Undo all changes'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _addVariant(
    BuildContext context,
    DishConfigurationCubit cubit,
  ) async {
    final result = await askNameAndPrice(
      context,
      title: 'Add a size or serving',
      // Neutral examples on purpose: this same field carries "14-inch",
      // "Bottle" and "6 Items", and a hint that says "Large" would push every
      // restaurant towards words their menu does not use.
      hint: '14-inch, Bottle, 6 Items…',
    );
    if (result == null) return;
    cubit.addVariant(name: result.name, pricePence: result.pricePence);
  }

  Future<void> _addGroup(
    BuildContext context,
    DishConfigurationCubit cubit,
  ) async {
    final result = await showAppSheet<_NewGroup>(
      context: context,
      title: 'Add a choice group',
      child: const _GroupForm(),
    );
    if (result == null) return;
    cubit.addGroup(
      name: result.name,
      selectionType: result.selectionType,
      pricingMode: result.pricingMode,
    );
  }
}

/// A quiet line under a section heading.
class _Caption extends StatelessWidget {
  const _Caption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Text(
      text,
      style: context.texts.bodySmall?.copyWith(
        color: context.surfaces.inkMuted,
      ),
    ),
  );
}

/// One choice in a form, drawn as a radio row.
///
/// Hand-rolled rather than [RadioListTile]: the framework's radio API is
/// deprecated in favour of a RadioGroup ancestor, and a tappable row is both
/// simpler and consistent with the option rows on the customer's side.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: AppIconSize.lg,
                color: selected ? scheme.primary : context.surfaces.line,
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.texts.bodyLarge),
                    Text(
                      subtitle,
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer({required this.dishName});

  final String dishName;

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Text(
        'How $dishName is sold. A customer picks one size, then whatever the '
        'choice groups offer for it. Prices here are what they are charged.',
        style: context.texts.bodyMedium?.copyWith(
          color: context.surfaces.inkMuted,
        ),
      ),
    );
  }
}

/// What the server would refuse, said before the round trip.
class _Problems extends StatelessWidget {
  const _Problems({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: colours.overdueContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: AppIconSize.md,
                color: colours.overdue,
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Text(
                  'Fix these before saving',
                  style: context.texts.titleSmall?.copyWith(
                    color: colours.overdue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '• $problem',
                style: context.texts.bodySmall?.copyWith(
                  color: colours.overdue,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VariantRow extends StatelessWidget {
  const _VariantRow({
    required this.variant,
    required this.groups,
    required this.canDelete,
  });

  final VariantDraft variant;
  final List<OptionGroupDraft> groups;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DishConfigurationCubit>();
    final offered = variant.rules.length;

    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x3),
      child: Row(
        children: [
          // Exactly one default, so this reads as a radio rather than a
          // switch: a switch can be turned off and leave none, which is
          // invalid. Set-only for the same reason — there is no "unset".
          IconButton(
            tooltip: variant.isDefault
                ? '${variant.name} is the default'
                : 'Make ${variant.name} the default',
            icon: Icon(
              variant.isDefault
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: variant.isDefault
                  ? Theme.of(context).colorScheme.primary
                  : context.surfaces.line,
            ),
            onPressed: () => cubit.setDefaultVariant(variant.code),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  variant.name,
                  style: context.texts.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    formatPence(variant.pricePence),
                    if (variant.isDefault) 'Default',
                    if (!variant.isAvailable) 'Sold out',
                    if (groups.isNotEmpty)
                      '$offered of ${groups.length} groups',
                  ].join(' · '),
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: variant.isAvailable,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) =>
                cubit.updateVariant(variant.code, isAvailable: value),
          ),
          PopupMenuButton<_VariantAction>(
            tooltip: 'Actions for ${variant.name}',
            icon: Icon(Icons.more_vert, color: context.surfaces.inkSoft),
            onSelected: (action) async {
              switch (action) {
                case _VariantAction.rename:
                  final result = await askNameAndPrice(
                    context,
                    title: 'Edit ${variant.name}',
                    name: variant.name,
                    pricePence: variant.pricePence,
                  );
                  if (result == null) return;
                  cubit.updateVariant(
                    variant.code,
                    name: result.name,
                    pricePence: result.pricePence,
                  );
                case _VariantAction.groups:
                  if (!context.mounted) return;
                  await showAppSheet<void>(
                    context: context,
                    title: '${variant.name}: choices',
                    child: BlocProvider.value(
                      value: cubit,
                      child: _RulesSheet(variantCode: variant.code),
                    ),
                  );
                case _VariantAction.delete:
                  cubit.removeVariant(variant.code);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _VariantAction.rename,
                child: Text('Edit name and price'),
              ),
              if (groups.isNotEmpty)
                const PopupMenuItem(
                  value: _VariantAction.groups,
                  child: Text('Choices for this size'),
                ),
              if (canDelete)
                PopupMenuItem(
                  value: _VariantAction.delete,
                  child: Text(
                    'Remove',
                    style: TextStyle(color: context.orderColors.overdue),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _VariantAction { rename, groups, delete }

/// Which groups one size offers, and on what terms.
class _RulesSheet extends StatelessWidget {
  const _RulesSheet({required this.variantCode});

  final String variantCode;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DishConfigurationCubit, DishConfigurationState>(
      builder: (context, state) {
        final cubit = context.read<DishConfigurationCubit>();
        final variant = state.draft.variants.firstWhere(
          (v) => v.code == variantCode,
          orElse: () => const VariantDraft(code: '', name: '', pricePence: 0),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.x4 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final group in state.draft.optionGroups) ...[
                _RuleEditor(
                  group: group,
                  rule: variant.rules
                      .where((r) => r.groupCode == group.code)
                      .firstOrNull,
                  onOffered: (value) =>
                      cubit.setGroupOffered(variantCode, group.code, value),
                  onChanged:
                      ({included, maximum, minimum, clearMaximum = false}) =>
                          cubit.setRule(
                            variantCode,
                            group.code,
                            minQuantity: minimum,
                            maxQuantity: maximum,
                            includedQuantity: included,
                            clearMaximum: clearMaximum,
                          ),
                ),
                const SizedBox(height: AppSpacing.x3),
              ],
              if (state.draft.optionGroups.isEmpty)
                Text(
                  'No choice groups yet.',
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.surfaces.inkMuted,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RuleEditor extends StatelessWidget {
  const _RuleEditor({
    required this.group,
    required this.rule,
    required this.onOffered,
    required this.onChanged,
  });

  final OptionGroupDraft group;
  final GroupRuleDraft? rule;
  final ValueChanged<bool> onOffered;
  final void Function({
    int? minimum,
    int? maximum,
    int? included,
    bool clearMaximum,
  })
  onChanged;

  @override
  Widget build(BuildContext context) {
    final terms = rule;

    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(group.name, style: context.texts.titleSmall),
              ),
              Switch(
                value: terms != null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onOffered,
              ),
            ],
          ),
          if (terms != null && !group.isSingleChoiceDraft) ...[
            const SizedBox(height: AppSpacing.x2),
            _NumberRow(
              label: 'Must choose at least',
              value: terms.minQuantity,
              onChanged: (value) => onChanged(minimum: value),
            ),
            _NumberRow(
              label: 'Can choose up to',
              value: terms.maxQuantity,
              // Null is a real answer here and means no ceiling, so it needs
              // its own way of being said rather than a zero that would mean
              // "none allowed".
              nullLabel: 'No limit',
              onChanged: (value) => onChanged(maximum: value),
              onClear: () => onChanged(clearMaximum: true),
            ),
            if (group.pricingMode == OptionPricingMode.excessOnly)
              _NumberRow(
                label: 'Included in the price',
                value: terms.includedQuantity,
                onChanged: (value) => onChanged(included: value),
              ),
            if (group.pricingMode == OptionPricingMode.excessOnly) ...[
              const SizedBox(height: AppSpacing.x2),
              Text(
                // The sentence that stops this being set wrong. "Included" is
                // routinely read as a limit; it is an allowance.
                'The first ${terms.includedQuantity} are inside the price. '
                'Anything after that is charged — customers can still choose '
                'more.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.surfaces.inkMuted,
                ),
              ),
            ],
          ],
          if (terms != null && group.isSingleChoiceDraft) ...[
            const SizedBox(height: AppSpacing.x1),
            Text(
              terms.minQuantity > 0
                  ? 'One choice, required.'
                  : 'One choice, optional.',
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkMuted,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('Required', style: context.texts.bodyMedium),
              value: terms.minQuantity > 0,
              onChanged: (value) => onChanged(minimum: value ? 1 : 0),
            ),
          ],
        ],
      ),
    );
  }
}

extension on OptionGroupDraft {
  bool get isSingleChoiceDraft => selectionType == OptionSelectionType.single;
}

/// A label with a small stepper, and optionally a way back to "no limit".
class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.nullLabel,
    this.onClear,
  });

  final String label;
  final int? value;
  final ValueChanged<int> onChanged;
  final String? nullLabel;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final current = value;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.texts.bodyMedium)),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            iconSize: AppIconSize.lg,
            tooltip: 'Fewer',
            onPressed: current == null || current == 0
                ? (onClear != null && current != null ? onClear : null)
                : () => onChanged(current - 1),
          ),
          SizedBox(
            width: 62,
            child: Text(
              current?.toString() ?? (nullLabel ?? '—'),
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            iconSize: AppIconSize.lg,
            tooltip: 'More',
            onPressed: () => onChanged((current ?? 0) + 1),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});

  final OptionGroupDraft group;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DishConfigurationCubit>();

    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name, style: context.texts.titleSmall),
                    Text(
                      [
                        group.selectionType == OptionSelectionType.single
                            ? 'Pick one'
                            : 'Pick several',
                        group.pricingMode == OptionPricingMode.excessOnly
                            ? 'Some included'
                            : 'Each one charged',
                      ].join(' · '),
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_GroupAction>(
                tooltip: 'Actions for ${group.name}',
                icon: Icon(Icons.more_vert, color: context.surfaces.inkSoft),
                onSelected: (action) async {
                  switch (action) {
                    case _GroupAction.edit:
                      final result = await showAppSheet<_NewGroup>(
                        context: context,
                        title: 'Edit ${group.name}',
                        child: _GroupForm(existing: group),
                      );
                      if (result == null) return;
                      cubit.updateGroup(
                        group.code,
                        name: result.name,
                        selectionType: result.selectionType,
                        pricingMode: result.pricingMode,
                      );
                    case _GroupAction.delete:
                      cubit.removeGroup(group.code);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _GroupAction.edit,
                    child: Text('Edit group'),
                  ),
                  PopupMenuItem(
                    value: _GroupAction.delete,
                    child: Text(
                      'Remove group',
                      style: TextStyle(color: context.orderColors.overdue),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Divider(),
          for (final option in group.options)
            _OptionRow(group: group, option: option),
          if (group.options.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
              child: Text(
                'No choices yet — a group with none is never shown.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.surfaces.inkMuted,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.x2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final result = await askNameAndPrice(
                  context,
                  title: 'Add to ${group.name}',
                  hint: 'Egg Hopper, Extra Cheese…',
                );
                if (result == null) return;
                cubit.addOption(
                  group.code,
                  name: result.name,
                  pricePence: result.pricePence,
                );
              },
              icon: const Icon(Icons.add, size: AppIconSize.md),
              label: const Text('Add a choice'),
            ),
          ),
        ],
      ),
    );
  }
}

enum _GroupAction { edit, delete }

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.group, required this.option});

  final OptionGroupDraft group;
  final OptionDraft option;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DishConfigurationCubit>();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.name,
                  style: context.texts.bodyLarge?.copyWith(
                    decoration: option.isAvailable
                        ? null
                        : TextDecoration.lineThrough,
                    color: option.isAvailable ? null : context.surfaces.inkSoft,
                  ),
                ),
                Text(
                  [
                    option.pricePence == 0
                        ? 'Free'
                        : formatPence(option.pricePence),
                    if (option.isDefault) 'Pre-selected',
                    if (option.maxQuantity != null) 'Max ${option.maxQuantity}',
                  ].join(' · '),
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: option.isAvailable,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) =>
                cubit.updateOption(group.code, option.code, isAvailable: value),
          ),
          PopupMenuButton<_OptionAction>(
            tooltip: 'Actions for ${option.name}',
            icon: Icon(
              Icons.more_vert,
              size: AppIconSize.lg,
              color: context.surfaces.inkSoft,
            ),
            onSelected: (action) async {
              switch (action) {
                case _OptionAction.edit:
                  final result = await askNameAndPrice(
                    context,
                    title: 'Edit ${option.name}',
                    name: option.name,
                    pricePence: option.pricePence,
                  );
                  if (result == null) return;
                  cubit.updateOption(
                    group.code,
                    option.code,
                    name: result.name,
                    pricePence: result.pricePence,
                  );
                case _OptionAction.preselect:
                  cubit.updateOption(
                    group.code,
                    option.code,
                    isDefault: !option.isDefault,
                  );
                case _OptionAction.delete:
                  cubit.removeOption(group.code, option.code);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _OptionAction.edit,
                child: Text('Edit name and price'),
              ),
              PopupMenuItem(
                value: _OptionAction.preselect,
                child: Text(
                  option.isDefault ? 'Do not pre-select' : 'Pre-select',
                ),
              ),
              PopupMenuItem(
                value: _OptionAction.delete,
                child: Text(
                  'Remove',
                  style: TextStyle(color: context.orderColors.overdue),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _OptionAction { edit, preselect, delete }

/// What a name-and-price sheet came back with.
class NameAndPrice {
  const NameAndPrice({required this.name, required this.pricePence});

  final String name;
  final int pricePence;
}

/// Asks for a name and a price, in pounds, returning integer pence.
///
/// Pence in, pence out. The pounds only exist in the text field, because
/// typing 1195 for £11.95 is how a menu ends up mispriced by a factor of a
/// hundred — and the conversion rounds rather than truncates, so 11.95 cannot
/// land on 1194.
Future<NameAndPrice?> askNameAndPrice(
  BuildContext context, {
  required String title,
  String? hint,
  String name = '',
  int pricePence = 0,
}) => showAppSheet<NameAndPrice>(
  context: context,
  title: title,
  child: _NameAndPriceForm(hint: hint, name: name, pricePence: pricePence),
);

class _NameAndPriceForm extends StatefulWidget {
  const _NameAndPriceForm({
    required this.name,
    required this.pricePence,
    this.hint,
  });

  final String name;
  final int pricePence;
  final String? hint;

  @override
  State<_NameAndPriceForm> createState() => _NameAndPriceFormState();
}

class _NameAndPriceFormState extends State<_NameAndPriceForm> {
  late final _name = TextEditingController(text: widget.name);
  late final _price = TextEditingController(
    text: widget.pricePence == 0
        ? ''
        : (widget.pricePence / 100).toStringAsFixed(2),
  );

  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give it a name.');
      return;
    }

    final raw = _price.text.trim();
    final pounds = raw.isEmpty ? 0.0 : double.tryParse(raw);
    if (pounds == null || pounds < 0) {
      setState(() => _error = 'Enter a price like 11.95, or leave it blank.');
      return;
    }

    Navigator.of(context).pop(
      // Rounded, never truncated: `(11.95 * 100).toInt()` is 1194 on a binary
      // double, and a penny out on every one of these compounds into a menu
      // nobody can reconcile.
      NameAndPrice(name: name, pricePence: (pounds * 100).round()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.x4 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: widget.hint,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppSpacing.x3),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Price',
              prefixText: '£',
              helperText: 'Leave blank for free',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Text(
              _error!,
              style: context.texts.bodySmall?.copyWith(
                color: context.orderColors.overdue,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.x5),
          PrimaryButton(label: 'Done', onPressed: _submit),
        ],
      ),
    );
  }
}

class _NewGroup {
  const _NewGroup({
    required this.name,
    required this.selectionType,
    required this.pricingMode,
  });

  final String name;
  final OptionSelectionType selectionType;
  final OptionPricingMode pricingMode;
}

class _GroupForm extends StatefulWidget {
  const _GroupForm({this.existing});

  final OptionGroupDraft? existing;

  @override
  State<_GroupForm> createState() => _GroupFormState();
}

class _GroupFormState extends State<_GroupForm> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late var _selection =
      widget.existing?.selectionType ?? OptionSelectionType.single;
  late var _pricing = widget.existing?.pricingMode ?? OptionPricingMode.always;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the group a name.');
      return;
    }
    Navigator.of(context).pop(
      _NewGroup(
        name: name,
        selectionType: _selection,
        // "Some included" only means anything for a group you can pick several
        // from, so a single-choice group is always charged per unit.
        pricingMode: _selection == OptionSelectionType.single
            ? OptionPricingMode.always
            : _pricing,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.x4 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'Crust Style, Choose Your Items…',
            ),
          ),
          const SizedBox(height: AppSpacing.x4),
          Text('How many can they pick?', style: context.texts.titleSmall),
          _ChoiceTile(
            title: 'One',
            subtitle: 'A crust, a spice level',
            selected: _selection == OptionSelectionType.single,
            onTap: () =>
                setState(() => _selection = OptionSelectionType.single),
          ),
          _ChoiceTile(
            title: 'Several',
            subtitle: 'Toppings, breakfast items',
            selected: _selection == OptionSelectionType.multiple,
            onTap: () =>
                setState(() => _selection = OptionSelectionType.multiple),
          ),
          if (_selection == OptionSelectionType.multiple) ...[
            const SizedBox(height: AppSpacing.x3),
            Text('How are they charged?', style: context.texts.titleSmall),
            _ChoiceTile(
              title: 'Each one is charged',
              subtitle: 'Paid extras',
              selected: _pricing == OptionPricingMode.always,
              onTap: () => setState(() => _pricing = OptionPricingMode.always),
            ),
            _ChoiceTile(
              title: 'Some are included',
              subtitle: 'A set number come with the price; extras are charged',
              selected: _pricing == OptionPricingMode.excessOnly,
              onTap: () =>
                  setState(() => _pricing = OptionPricingMode.excessOnly),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Text(
              _error!,
              style: context.texts.bodySmall?.copyWith(
                color: context.orderColors.overdue,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.x5),
          PrimaryButton(label: 'Done', onPressed: _submit),
        ],
      ),
    );
  }
}
