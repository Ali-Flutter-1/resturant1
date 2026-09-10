import '../../../core/network/api_failure.dart';

/// What the app should do about an ordering error that names the menu.
///
/// The configurable menu is admin-editable while customers are shopping, so a
/// basket assembled two minutes ago can reference a size that has been marked
/// sold out or an option that has been withdrawn. The API distinguishes those
/// from ordinary validation failures by code, and the recovery is different:
/// a stale basket must be re-read from the server rather than resent, because
/// resending the same payload gets the same rejection forever.
enum MenuStaleness {
  /// The dish itself is gone or off. The whole line has to go.
  dishGone,

  /// The chosen size, serving or package is stale or sold out.
  variantGone,

  /// A chosen option is stale or sold out.
  optionGone,

  /// The configuration broke a rule — too many, too few, or more than one in a
  /// single-choice group. The dish is fine; the choices need adjusting.
  configurationInvalid,

  /// Nothing to do with the menu.
  none;

  /// Classifies an API failure by its `error.code`.
  ///
  /// Unknown codes fall through to [none] deliberately: a code this app has
  /// never heard of should show the server's own message, not trigger a
  /// speculative refresh loop.
  static MenuStaleness of(ApiFailure failure) => switch (failure.code) {
    'DISH_UNAVAILABLE' || 'DISH_SOLD_OUT' => dishGone,
    'VARIANT_NOT_OFFERED' || 'VARIANT_SOLD_OUT' => variantGone,
    'OPTION_NOT_OFFERED' || 'OPTION_SOLD_OUT' => optionGone,
    'OPTION_QUANTITY_EXCEEDED' ||
    'OPTION_GROUP_MINIMUM_NOT_MET' ||
    'OPTION_GROUP_MAXIMUM_EXCEEDED' ||
    'OPTION_GROUP_SINGLE_ONLY' ||
    'SPICE_LEVEL_NOT_OFFERED' => configurationInvalid,
    _ => none,
  };

  /// Whether the dish must be re-fetched before the customer tries again.
  ///
  /// True for everything the server knows and the app does not. False for a
  /// rule the app can already see it broke — re-fetching there would hide the
  /// fix behind a spinner for no reason.
  bool get needsRefresh => switch (this) {
    dishGone || variantGone || optionGone => true,
    configurationInvalid || none => false,
  };

  /// Whether the offending line should be taken out of the basket rather than
  /// corrected in place. Only when the dish itself has gone: a stale variant or
  /// option can be re-chosen from the refreshed dish.
  bool get dropsLine => this == dishGone;

  /// What to tell the customer, on top of the server's own message.
  ///
  /// The server's `message` says what went wrong; this says what happens next,
  /// which the server has no way to know.
  String? get recovery => switch (this) {
    dishGone => 'It has been removed from your basket.',
    variantGone ||
    optionGone => 'We have refreshed the menu — please choose again.',
    configurationInvalid => 'Please adjust your choices and try again.',
    none => null,
  };
}

/// Whether a failure is about delivery rather than the menu — the postcode, the
/// zone, or the minimum spend.
///
/// Separated because the recovery is a different screen area entirely: these
/// belong against the address, not the basket.
bool isDeliveryFailure(ApiFailure failure) => switch (failure.code) {
  'BELOW_MINIMUM_ORDER' ||
  'POSTCODE_REQUIRED' ||
  'OUTSIDE_DELIVERY_AREA' => true,
  _ => false,
};
