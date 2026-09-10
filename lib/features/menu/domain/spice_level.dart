/// How hot the customer wants a dish, where the kitchen offers the choice.
///
/// Three levels: **Low, Mild, Hot** — the restaurant's own wording. Note that
/// the label and the wire value deliberately diverge in the middle: the API
/// calls it `mid` and the menu calls it Mild. The wire values are the backend's
/// contract and must not be renamed to match the menu, or every existing order
/// would stop parsing.
///
/// Optional even when a dish offers it — no choice is a legitimate answer, and
/// the backend stores null rather than assuming a default nobody asked for.
///
/// Currently free: the guide is explicit that spice level has no price effect,
/// so nothing here touches money.
enum SpiceLevel {
  low('Low', 'Gentle warmth.'),
  mid('Mild', 'Noticeable heat.'),
  high('Hot', 'Bring water.');

  const SpiceLevel(this.label, this.description);

  final String label;
  final String description;

  /// What goes on the wire. Lowercase, exactly as the API defines it — so
  /// [mid] sends `mid`, even though the menu shows it as Mild.
  String get apiValue => name;

  /// Null for absent, unknown or malformed.
  ///
  /// Tolerant on purpose: an order placed before the backend renamed a value
  /// should show no spice rather than fail the whole receipt.
  static SpiceLevel? tryParse(Object? value) =>
      switch (value?.toString().trim().toLowerCase()) {
        'low' => low,
        // `mild` is accepted alongside `mid` so a backend that ever adopts the
        // menu's wording still parses, without this app changing what it sends.
        'mid' || 'mild' || 'medium' => mid,
        'high' || 'hot' => high,
        _ => null,
      };
}
