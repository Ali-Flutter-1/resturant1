import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../../menu/domain/dish.dart';
import '../../menu/domain/dish_configuration.dart';
import '../domain/admin_menu_repository.dart';
import '../domain/dish_configuration_draft.dart';

class DishConfigurationState extends Equatable {
  const DishConfigurationState({
    required this.draft,
    required this.saved,
    this.saving = false,
    this.failure,
  });

  /// What the admin is editing.
  final DishConfigurationDraft draft;

  /// What the server last confirmed, so [isDirty] is a real comparison rather
  /// than a flag somebody has to remember to set.
  final DishConfigurationDraft saved;

  final bool saving;
  final ApiFailure? failure;

  bool get isDirty => draft != saved;

  /// Everything the server would reject, found here first.
  List<String> get problems => draft.problems;

  bool get canSave => isDirty && !saving && problems.isEmpty;

  DishConfigurationState copyWith({
    DishConfigurationDraft? draft,
    DishConfigurationDraft? saved,
    bool? saving,
    ApiFailure? failure,
    bool clearFailure = false,
  }) => DishConfigurationState(
    draft: draft ?? this.draft,
    saved: saved ?? this.saved,
    saving: saving ?? this.saving,
    failure: clearFailure ? null : (failure ?? this.failure),
  );

  @override
  List<Object?> get props => [draft, saved, saving, failure];
}

/// Editing one dish's variants and option groups.
///
/// The whole structure is edited locally and written in one `PUT`, because that
/// is what the endpoint does — it replaces the configuration atomically. There
/// is deliberately no per-field save: a half-applied structure is exactly what
/// the atomic endpoint exists to prevent, and an editor that saved as it went
/// would produce one every time an admin changed their mind halfway.
class DishConfigurationCubit extends Cubit<DishConfigurationState> {
  DishConfigurationCubit({
    required AdminMenuRepository repository,
    required Dish dish,
  }) : _repository = repository,
       _dishId = dish.id,
       super(
         DishConfigurationState(
           draft: DishConfigurationDraft.fromDish(dish),
           saved: DishConfigurationDraft.fromDish(dish),
         ),
       );

  final AdminMenuRepository _repository;
  final String _dishId;

  void _edit(DishConfigurationDraft draft) =>
      emit(state.copyWith(draft: draft, clearFailure: true));

  // ------------------------------------------------------------- variants

  /// Adds a size, serving or package.
  ///
  /// The first one added becomes the default, because exactly one must be and
  /// leaving an admin to discover that from a validation message is a worse
  /// first experience than simply being right.
  void addVariant({required String name, required int pricePence}) {
    final variants = [
      ...state.draft.variants,
      VariantDraft(
        code: _uniqueCode(name, [for (final v in state.draft.variants) v.code]),
        name: name.trim(),
        pricePence: pricePence,
        isDefault: state.draft.variants.isEmpty,
        sortOrder: state.draft.variants.length,
        // A new variant offers every group the dish already defines, on
        // permissive terms. Starting from nothing would mean a new size
        // silently loses the crust choice every other size has.
        rules: [
          for (final group in state.draft.optionGroups)
            GroupRuleDraft(
              groupCode: group.code,
              maxQuantity: group.selectionType == OptionSelectionType.single
                  ? 1
                  : null,
            ),
        ],
      ),
    ];
    _edit(
      DishConfigurationDraft(
        variants: variants,
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  void updateVariant(
    String code, {
    String? name,
    int? pricePence,
    bool? isAvailable,
  }) {
    _edit(
      DishConfigurationDraft(
        variants: [
          for (final variant in state.draft.variants)
            if (variant.code == code)
              VariantDraft(
                code: variant.code,
                name: name?.trim() ?? variant.name,
                pricePence: pricePence ?? variant.pricePence,
                isDefault: variant.isDefault,
                isAvailable: isAvailable ?? variant.isAvailable,
                sortOrder: variant.sortOrder,
                rules: variant.rules,
              )
            else
              variant,
        ],
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  /// Makes one variant the default, clearing whichever held it.
  ///
  /// Modelled as "set" rather than "toggle" precisely because exactly one must
  /// hold it: a toggle can reach zero, and zero is invalid.
  void setDefaultVariant(String code) {
    _edit(
      DishConfigurationDraft(
        variants: [
          for (final variant in state.draft.variants)
            VariantDraft(
              code: variant.code,
              name: variant.name,
              pricePence: variant.pricePence,
              isDefault: variant.code == code,
              isAvailable: variant.isAvailable,
              sortOrder: variant.sortOrder,
              rules: variant.rules,
            ),
        ],
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  void removeVariant(String code) {
    final kept = [
      for (final variant in state.draft.variants)
        if (variant.code != code) variant,
    ];
    // Removing the default leaves none, so the first survivor takes it.
    final needsDefault = kept.isNotEmpty && !kept.any((v) => v.isDefault);
    _edit(
      DishConfigurationDraft(
        variants: [
          for (final (index, variant) in kept.indexed)
            VariantDraft(
              code: variant.code,
              name: variant.name,
              pricePence: variant.pricePence,
              isDefault: needsDefault ? index == 0 : variant.isDefault,
              isAvailable: variant.isAvailable,
              sortOrder: index,
              rules: variant.rules,
            ),
        ],
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  /// Sets how one variant uses one group.
  void setRule(
    String variantCode,
    String groupCode, {
    int? minQuantity,
    int? maxQuantity,
    int? includedQuantity,
    bool clearMaximum = false,
  }) {
    _edit(
      DishConfigurationDraft(
        variants: [
          for (final variant in state.draft.variants)
            if (variant.code == variantCode)
              VariantDraft(
                code: variant.code,
                name: variant.name,
                pricePence: variant.pricePence,
                isDefault: variant.isDefault,
                isAvailable: variant.isAvailable,
                sortOrder: variant.sortOrder,
                rules: [
                  for (final rule in variant.rules)
                    if (rule.groupCode == groupCode)
                      GroupRuleDraft(
                        groupCode: rule.groupCode,
                        minQuantity: minQuantity ?? rule.minQuantity,
                        maxQuantity: clearMaximum
                            ? null
                            : (maxQuantity ?? rule.maxQuantity),
                        includedQuantity:
                            includedQuantity ?? rule.includedQuantity,
                      )
                    else
                      rule,
                ],
              )
            else
              variant,
        ],
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  /// Turns a group on or off for one variant.
  ///
  /// Off means the rule is removed entirely, which is what "this size does not
  /// offer that" means on the wire — a rule with a zero maximum would instead
  /// show the customer a group they cannot choose anything from.
  void setGroupOffered(String variantCode, String groupCode, bool offered) {
    final group = state.draft.optionGroups.firstWhere(
      (g) => g.code == groupCode,
      orElse: () => const OptionGroupDraft(code: '', name: ''),
    );
    _edit(
      DishConfigurationDraft(
        variants: [
          for (final variant in state.draft.variants)
            if (variant.code == variantCode)
              VariantDraft(
                code: variant.code,
                name: variant.name,
                pricePence: variant.pricePence,
                isDefault: variant.isDefault,
                isAvailable: variant.isAvailable,
                sortOrder: variant.sortOrder,
                rules: offered
                    ? [
                        for (final rule in variant.rules)
                          if (rule.groupCode != groupCode) rule,
                        GroupRuleDraft(
                          groupCode: groupCode,
                          maxQuantity:
                              group.selectionType == OptionSelectionType.single
                              ? 1
                              : null,
                        ),
                      ]
                    : [
                        for (final rule in variant.rules)
                          if (rule.groupCode != groupCode) rule,
                      ],
              )
            else
              variant,
        ],
        optionGroups: state.draft.optionGroups,
      ),
    );
  }

  // --------------------------------------------------------------- groups

  void addGroup({
    required String name,
    required OptionSelectionType selectionType,
    required OptionPricingMode pricingMode,
  }) {
    final code = _uniqueCode(name, [
      for (final g in state.draft.optionGroups) g.code,
    ]);
    _edit(
      DishConfigurationDraft(
        // Offered by every variant from the start, on permissive terms. A new
        // group nobody can see is the likeliest way to build a configuration
        // that looks finished and does nothing.
        variants: [
          for (final variant in state.draft.variants)
            VariantDraft(
              code: variant.code,
              name: variant.name,
              pricePence: variant.pricePence,
              isDefault: variant.isDefault,
              isAvailable: variant.isAvailable,
              sortOrder: variant.sortOrder,
              rules: [
                ...variant.rules,
                GroupRuleDraft(
                  groupCode: code,
                  maxQuantity: selectionType == OptionSelectionType.single
                      ? 1
                      : null,
                ),
              ],
            ),
        ],
        optionGroups: [
          ...state.draft.optionGroups,
          OptionGroupDraft(
            code: code,
            name: name.trim(),
            selectionType: selectionType,
            pricingMode: pricingMode,
            sortOrder: state.draft.optionGroups.length,
          ),
        ],
      ),
    );
  }

  void updateGroup(
    String code, {
    String? name,
    OptionSelectionType? selectionType,
    OptionPricingMode? pricingMode,
  }) {
    final groups = [
      for (final group in state.draft.optionGroups)
        if (group.code == code)
          OptionGroupDraft(
            code: group.code,
            name: name?.trim() ?? group.name,
            selectionType: selectionType ?? group.selectionType,
            pricingMode: pricingMode ?? group.pricingMode,
            sortOrder: group.sortOrder,
            options: group.options,
          )
        else
          group,
    ];

    // Becoming a single choice caps every rule that allowed more, so the two
    // cannot contradict each other. Left alone, this is the contradiction a
    // customer meets as OPTION_GROUP_SINGLE_ONLY halfway through ordering.
    final nowSingle = selectionType == OptionSelectionType.single;
    _edit(
      DishConfigurationDraft(
        variants: nowSingle
            ? [
                for (final variant in state.draft.variants)
                  VariantDraft(
                    code: variant.code,
                    name: variant.name,
                    pricePence: variant.pricePence,
                    isDefault: variant.isDefault,
                    isAvailable: variant.isAvailable,
                    sortOrder: variant.sortOrder,
                    rules: [
                      for (final rule in variant.rules)
                        if (rule.groupCode == code)
                          GroupRuleDraft(
                            groupCode: rule.groupCode,
                            minQuantity: rule.minQuantity > 1
                                ? 1
                                : rule.minQuantity,
                            maxQuantity: 1,
                            includedQuantity: rule.includedQuantity,
                          )
                        else
                          rule,
                    ],
                  ),
              ]
            : state.draft.variants,
        optionGroups: groups,
      ),
    );
  }

  void removeGroup(String code) {
    _edit(
      DishConfigurationDraft(
        // The rules pointing at it go too, or they would refer to a group that
        // no longer exists.
        variants: [
          for (final variant in state.draft.variants)
            VariantDraft(
              code: variant.code,
              name: variant.name,
              pricePence: variant.pricePence,
              isDefault: variant.isDefault,
              isAvailable: variant.isAvailable,
              sortOrder: variant.sortOrder,
              rules: [
                for (final rule in variant.rules)
                  if (rule.groupCode != code) rule,
              ],
            ),
        ],
        optionGroups: [
          for (final group in state.draft.optionGroups)
            if (group.code != code) group,
        ],
      ),
    );
  }

  // -------------------------------------------------------------- options

  void addOption(
    String groupCode, {
    required String name,
    required int pricePence,
  }) {
    _edit(
      DishConfigurationDraft(
        variants: state.draft.variants,
        optionGroups: [
          for (final group in state.draft.optionGroups)
            if (group.code == groupCode)
              OptionGroupDraft(
                code: group.code,
                name: group.name,
                selectionType: group.selectionType,
                pricingMode: group.pricingMode,
                sortOrder: group.sortOrder,
                options: [
                  ...group.options,
                  OptionDraft(
                    code: _uniqueCode(name, [
                      for (final o in group.options) o.code,
                    ]),
                    name: name.trim(),
                    pricePence: pricePence,
                    sortOrder: group.options.length,
                  ),
                ],
              )
            else
              group,
        ],
      ),
    );
  }

  void updateOption(
    String groupCode,
    String optionCode, {
    String? name,
    int? pricePence,
    int? maxQuantity,
    bool? isDefault,
    bool? isAvailable,
    bool clearMaximum = false,
  }) {
    _edit(
      DishConfigurationDraft(
        variants: state.draft.variants,
        optionGroups: [
          for (final group in state.draft.optionGroups)
            if (group.code == groupCode)
              OptionGroupDraft(
                code: group.code,
                name: group.name,
                selectionType: group.selectionType,
                pricingMode: group.pricingMode,
                sortOrder: group.sortOrder,
                options: [
                  for (final option in group.options)
                    if (option.code == optionCode)
                      OptionDraft(
                        code: option.code,
                        name: name?.trim() ?? option.name,
                        pricePence: pricePence ?? option.pricePence,
                        maxQuantity: clearMaximum
                            ? null
                            : (maxQuantity ?? option.maxQuantity),
                        isDefault: isDefault ?? option.isDefault,
                        isAvailable: isAvailable ?? option.isAvailable,
                        sortOrder: option.sortOrder,
                      )
                    // A single-choice group can only have one default, so
                    // setting one clears the rest.
                    else if (isDefault == true &&
                        group.selectionType == OptionSelectionType.single)
                      OptionDraft(
                        code: option.code,
                        name: option.name,
                        pricePence: option.pricePence,
                        maxQuantity: option.maxQuantity,
                        isDefault: false,
                        isAvailable: option.isAvailable,
                        sortOrder: option.sortOrder,
                      )
                    else
                      option,
                ],
              )
            else
              group,
        ],
      ),
    );
  }

  void removeOption(String groupCode, String optionCode) {
    _edit(
      DishConfigurationDraft(
        variants: state.draft.variants,
        optionGroups: [
          for (final group in state.draft.optionGroups)
            if (group.code == groupCode)
              OptionGroupDraft(
                code: group.code,
                name: group.name,
                selectionType: group.selectionType,
                pricingMode: group.pricingMode,
                sortOrder: group.sortOrder,
                options: [
                  for (final option in group.options)
                    if (option.code != optionCode) option,
                ],
              )
            else
              group,
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- save

  /// Writes the whole configuration. Returns the saved dish, or null on
  /// failure — the message is then on the state.
  Future<Dish?> save() async {
    if (!state.canSave) return null;
    emit(state.copyWith(saving: true, clearFailure: true));

    try {
      final dish = await _repository.setDishConfiguration(_dishId, state.draft);
      // Re-read from the server's answer rather than keeping the draft: the
      // server resolved codes to ids and may have normalised sort orders, and
      // the editor should be showing what is actually stored.
      final saved = DishConfigurationDraft.fromDish(dish);
      emit(DishConfigurationState(draft: saved, saved: saved));
      return dish;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(saving: false, failure: failure));
      return null;
    }
  }

  /// Throws the edits away.
  void revert() =>
      emit(DishConfigurationState(draft: state.saved, saved: state.saved));

  /// A stable, URL-safe handle built from what the admin typed.
  ///
  /// Codes are identity: the server keeps an option's id — and the order
  /// history pointing at it — across a rename, but only while the code holds
  /// still. So one is minted once, from the first name given, and never
  /// regenerated when the name changes.
  static String _uniqueCode(String name, List<String> taken) {
    final base = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final root = base.isEmpty ? 'item' : base;

    if (!taken.contains(root)) return root;
    for (var suffix = 2; ; suffix++) {
      final candidate = '$root-$suffix';
      if (!taken.contains(candidate)) return candidate;
    }
  }
}
