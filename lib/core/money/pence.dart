/// Money, formatted from the integer pence the API speaks.
///
/// One implementation, because there were three and two of them disagreed about
/// thousands separators — so a £4,310.25 day's takings read as £431025 on one
/// screen and correctly on another.
///
/// Never parses, rounds or arithmetics a server value: the pence are already
/// exact, and putting them through a double is how a total ends up a penny out.
library;

/// Integer pence as pounds — `1195` becomes `£11.95`, `431025` becomes
/// `£4,310.25`.
///
/// Grouped above a thousand. For everything smaller — which is every dish price
/// and nearly every order total — the output is identical to the ungrouped
/// form, so this is a superset rather than a change of style.
String formatPence(int pence) {
  // Negative is not a real price, but a shortfall subtraction can produce one,
  // and `~/` and `%` on a negative would otherwise print something like
  // `£-1.-50`. The sign is lifted out and the magnitude formatted normally.
  final negative = pence < 0;
  final value = negative ? -pence : pence;

  final pounds = value ~/ 100;
  final pennies = (value % 100).toString().padLeft(2, '0');
  final grouped = pounds.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (match) => '${match[1]},',
  );
  return '${negative ? '-' : ''}£$grouped.$pennies';
}

/// The same, with a leading `+` — for an add-on row where the number is a
/// difference rather than a price. Zero comes back empty: "+£0.00" beside a
/// free choice is noise that reads as a charge.
String? formatPenceDelta(int pence) {
  if (pence == 0) return null;
  return pence > 0 ? '+${formatPence(pence)}' : formatPence(pence);
}
