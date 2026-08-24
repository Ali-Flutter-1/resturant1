/// Where the restaurant is.
///
/// One address, in one place. The app has exactly one venue, so this is a
/// constant rather than a fetched list — and having it here stops the same
/// street name being retyped on the About screen, the map and a receipt.
///
/// **These are placeholder values.** The address matches what the About screen
/// has always shown; the coordinates are the postcode's centroid. Replace both
/// with the real venue before release — the map will point at the wrong door
/// otherwise, and nothing in the app can detect that.
abstract final class RestaurantLocation {
  static const String name = "T's Café";
  static const String addressLine = '128 Heritage Lane';
  static const String city = 'London';
  static const String postcode = 'SW1A 1AA';
  static const String phone = '+44 20 7946 0958';

  /// Centroid of the postcode above.
  static const double latitude = 51.5010;
  static const double longitude = -0.1416;

  static const String fullAddress = '$addressLine, $city $postcode';

  /// What a maps app should search for. Display and fallback only — see
  /// [directionsUrl], which does not rely on it.
  static String get mapsQuery => '$name, $fullAddress';

  /// A directions link to the venue, for the platform's own maps app.
  ///
  /// Built from **coordinates, not the address**. A text query has to be
  /// geocoded, and when it cannot be — a new venue, a misspelling, or the
  /// placeholder address above — Apple and Google Maps quietly fall back to
  /// showing the user where *they* are, which is exactly the wrong answer from a
  /// button marked Directions. A latitude and longitude always resolve.
  ///
  /// `daddr` / `destination` mean the venue is the destination and the user's
  /// position is the origin, which is what "directions" means to a customer.
  static Uri directionsUrl({required bool isApple}) {
    final point = Uri.encodeComponent('$latitude,$longitude');
    return Uri.parse(
      isApple
          // `dirflg=d` is what opens the driving *route* rather than a map with
          // a pin on it. `q` used to be here as a label, but Apple Maps reads
          // it as a search: given both, it ran the search and showed where the
          // customer was standing instead of the way here, which is precisely
          // the complaint.
          //
          // No `saddr`, deliberately -- leaving the origin out is what makes
          // Apple use "Current Location", and naming one would send people from
          // an address they are not at.
          ? 'https://maps.apple.com/?daddr=$point&dirflg=d'
          // Google's own documented directions form. `travelmode` matters for
          // the same reason `dirflg` does: without it the link can open the
          // place card rather than the route.
          : 'https://www.google.com/maps/dir/?api=1'
                '&destination=$point'
                '&travelmode=driving',
    );
  }
}
