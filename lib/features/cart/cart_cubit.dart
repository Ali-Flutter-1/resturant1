import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../menu/domain/dish.dart';
import '../menu/domain/dish_configuration.dart';
import '../menu/domain/dish_selection.dart';
import '../menu/domain/spice_level.dart';

/// One line in the basket.
///
/// Only [dishId], [quantity] and [notes] are sent to the API. The title and
/// price are cached for display and are **not** authoritative — the server looks
/// prices up from `dish_id`, and the integration guide is explicit that anything
/// a client could set, a client could forge. So a price shown here is
/// information, never a claim.
class CartLine extends Equatable {
  const CartLine({
    required this.dishId,
    required this.title,
    required this.displayPricePence,
    required this.quantity,
    this.notes,
    this.spiceLevel,
    this.prepMaxMinutes,
    this.variantId,
    this.variantName,
    this.selections = const [],
    this.selectionSummary,
  });

  factory CartLine.fromDish(
    Dish dish, {
    int quantity = 1,
    String? notes,
    SpiceLevel? spiceLevel,
  }) => CartLine(
    dishId: dish.id,
    title: dish.name,
    displayPricePence: dish.pricePence,
    quantity: quantity,
    notes: (notes?.trim().isEmpty ?? true) ? null : notes!.trim(),
    // Dropped for a dish that does not offer the choice, rather than sent
    // and refused with SPICE_LEVEL_NOT_OFFERED. A stale selection is the
    // app's problem to discard, not the customer's to see an error for.
    spiceLevel: dish.hasSpiceLevels ? spiceLevel : null,
    // Carried so the checkout can refuse a slot the kitchen cannot make.
    prepMaxMinutes: dish.prepMaxMinutes,
  );

  /// A configured meal: a chosen variant and whatever options went with it.
  ///
  /// The variant name and the provisional unit price are cached for display in
  /// the basket, in the same spirit as [displayPricePence] on a plain line —
  /// information, never a claim. The server prices the line from the ids.
  factory CartLine.fromSelection(
    DishSelection selection, {
    int quantity = 1,
    String? notes,
    SpiceLevel? spiceLevel,
  }) => CartLine(
    dishId: selection.dish.id,
    title: selection.dish.name,
    displayPricePence: selection.unitPricePence,
    quantity: quantity,
    notes: (notes?.trim().isEmpty ?? true) ? null : notes!.trim(),
    spiceLevel: selection.dish.hasSpiceLevels ? spiceLevel : null,
    prepMaxMinutes: selection.dish.prepMaxMinutes,
    variantId: selection.variant?.id,
    variantName: selection.variant?.name,
    selections: selection.wireSelections,
    selectionSummary: selection.summary,
  );

  final String dishId;
  final String title;
  final int displayPricePence;
  final int quantity;

  /// Up to 200 characters, per the API. What the kitchen reads on the ticket.
  final String? notes;

  /// Low, Mid or High, where the dish offers it. Null is a real answer — the
  /// choice is optional even when the selector is shown.
  final SpiceLevel? spiceLevel;

  /// The longest the kitchen says this dish takes, in minutes. Null when the API
  /// sent no estimate for it.
  final int? prepMaxMinutes;

  /// The chosen size, serving or package. Null for a dish sold in one form.
  final String? variantId;

  /// Its name, cached so the basket can say "6 Items" without re-fetching the
  /// dish. Display only.
  final String? variantName;

  /// The chosen options, as ids and counts. Each id appears at most once and
  /// nothing sits at zero — see [DishSelection.wireSelections].
  final List<CartOptionSelection> selections;

  /// "4x Egg Hopper, 3x Crispy Bacon", cached for the basket row. Display only;
  /// the quote's own breakdown replaces it at checkout.
  final String? selectionSummary;

  /// What distinguishes this line from another of the same dish.
  ///
  /// Two 6-item breakfasts with different fillings are two different meals, not
  /// two of one, so the configuration is part of the identity that decides
  /// whether adding merges into an existing line. Sorted so the same choices
  /// made in a different order still merge.
  String get configurationKey {
    final parts = [
      for (final selection in selections)
        '${selection.optionId}=${selection.quantity}',
    ]..sort();
    return '${variantId ?? ''}|${parts.join(',')}';
  }

  /// Display only. The server recalculates every total when the order is placed.
  int get displayLinePence => displayPricePence * quantity;

  /// The dish and its variant on one line — "Custom Breakfast (6 Items)".
  String get titleWithVariant =>
      variantName == null ? title : '$title ($variantName)';

  /// Exactly the fields the API accepts on a line. No prices: the server looks
  /// those up from `dish_id`.
  Map<String, dynamic> toJson() => {
    'dish_id': dishId,
    // Omitted entirely for an unconfigured dish rather than sent as null: the
    // server then prices the dish's single price, which is what it did before
    // variants existed.
    'variant_id': ?variantId,
    'quantity': quantity,
    if (selections.isNotEmpty)
      'selections': [for (final s in selections) s.toJson()],
    'spice_level': ?spiceLevel?.apiValue,
    'notes': ?notes,
  };

  CartLine copyWith({int? quantity, String? notes}) => CartLine(
    dishId: dishId,
    title: title,
    displayPricePence: displayPricePence,
    quantity: quantity ?? this.quantity,
    notes: notes ?? this.notes,
    spiceLevel: spiceLevel,
    prepMaxMinutes: prepMaxMinutes,
    variantId: variantId,
    variantName: variantName,
    selections: selections,
    selectionSummary: selectionSummary,
  );

  @override
  List<Object?> get props => [
    dishId,
    title,
    displayPricePence,
    quantity,
    notes,
    spiceLevel,
    variantId,
    selections,
  ];
}

class CartState extends Equatable {
  const CartState({this.lines = const []});

  final List<CartLine> lines;

  /// What the badge shows: items, not lines. Three of one dish is three items.
  int get count => lines.fold(0, (sum, line) => sum + line.quantity);

  bool get isEmpty => lines.isEmpty;

  /// Display only — the checkout renders the server's quote, not this.
  int get displaySubtotalPence =>
      lines.fold(0, (sum, line) => sum + line.displayLinePence);

  /// How long the whole basket takes the kitchen, in minutes.
  ///
  /// The **longest** dish, not the sum of them. A kitchen cooks in parallel: a
  /// twenty-minute curry alongside a five-minute side is ready in twenty, not
  /// twenty-five. Adding them up would push every multi-item order absurdly far
  /// into the evening.
  ///
  /// Null when no dish in the basket carries an estimate, in which case the
  /// checkout falls back to the server's own lead time and nothing is narrowed.
  int? get longestPrepMinutes {
    final known = lines
        .map((line) => line.prepMaxMinutes)
        .whereType<int>()
        .toList();
    if (known.isEmpty) return null;
    return known.reduce((a, b) => a > b ? a : b);
  }

  /// The API's limits: 1–50 lines, 1–50 per line.
  static const int maxLines = 50;
  static const int maxQuantity = 50;

  @override
  List<Object?> get props => [lines];
}

/// The basket, which lives entirely in the app.
///
/// It was a bare `Cubit<int>` — a counter for the badge — which meant there was
/// nothing to place an order *with*. It now holds real lines, and
/// [CartState.count] preserves what the badge was reading.
class CartCubit extends Cubit<CartState> {
  CartCubit() : super(const CartState());

  /// Adds a dish, merging into an existing line when it is the same dish with
  /// the same note.
  ///
  /// Merging matters: two taps of "add" should read as one line of two, not two
  /// lines of one. A *different* note makes it a genuinely different instruction
  /// to the kitchen, so that stays separate.
  /// A different spice level is as much a different instruction as a different
  /// note, so it keeps its own line too.
  void addDish(
    Dish dish, {
    int quantity = 1,
    String? notes,
    SpiceLevel? spiceLevel,
  }) => _add(
    CartLine.fromDish(
      dish,
      quantity: quantity.clamp(1, CartState.maxQuantity),
      notes: notes,
      spiceLevel: spiceLevel,
    ),
    quantity: quantity,
  );

  /// Adds a configured meal — a chosen variant and its options.
  ///
  /// An incomplete configuration is refused rather than sent: a group short of
  /// its `min_quantity` comes back as `OPTION_GROUP_MINIMUM_NOT_MET`, and the
  /// details screen already knows enough to say so before the basket does.
  bool addSelection(
    DishSelection selection, {
    int quantity = 1,
    String? notes,
    SpiceLevel? spiceLevel,
  }) {
    if (!selection.isComplete) return false;
    _add(
      CartLine.fromSelection(
        selection,
        quantity: quantity.clamp(1, CartState.maxQuantity),
        notes: notes,
        spiceLevel: spiceLevel,
      ),
      quantity: quantity,
    );
    return true;
  }

  /// Merges [candidate] into a matching line, or appends it.
  ///
  /// What counts as matching is the dish, the note, the spice level *and* the
  /// configuration: two identically configured meals are two of one line, and
  /// two differently configured ones are not.
  void _add(CartLine candidate, {required int quantity}) {
    final tidied = candidate.notes;
    final heat = candidate.spiceLevel;
    final existing = state.lines.indexWhere(
      (line) =>
          line.dishId == candidate.dishId &&
          line.notes == tidied &&
          line.spiceLevel == heat &&
          line.configurationKey == candidate.configurationKey,
    );

    if (existing >= 0) {
      final line = state.lines[existing];
      // Capped rather than refused: the API rejects more than fifty of one
      // line, and silently clamping is kinder than an error for a long press.
      final merged = line.copyWith(
        quantity: (line.quantity + quantity).clamp(1, CartState.maxQuantity),
      );
      emit(
        CartState(
          lines: [
            for (final (index, l) in state.lines.indexed)
              if (index == existing) merged else l,
          ],
        ),
      );
      return;
    }

    if (state.lines.length >= CartState.maxLines) return;
    emit(CartState(lines: [...state.lines, candidate]));
  }

  /// Sets a line's quantity. Zero removes it — which is what a customer means by
  /// tapping "minus" on a single item.
  void setQuantity(CartLine line, int quantity) {
    if (quantity <= 0) return remove(line);
    emit(
      CartState(
        lines: [
          for (final l in state.lines)
            if (l == line)
              l.copyWith(quantity: quantity.clamp(1, CartState.maxQuantity))
            else
              l,
        ],
      ),
    );
  }

  void remove(CartLine line) => emit(
    CartState(
      lines: [
        for (final l in state.lines)
          if (l != line) l,
      ],
    ),
  );

  /// Emptied only once the server has confirmed an order — see the checkout.
  void clear() => emit(const CartState());
}
