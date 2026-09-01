import 'delivery_zone.dart';

/// Where delivery pricing comes from.
///
/// Both routes are public: a customer can see the map and check a postcode
/// before signing in, which is the point -- being told "we do not deliver
/// there" after making an account would be the wrong order of events.
abstract interface class DeliveryZoneRepository {
  /// Every active zone, cheapest first.
  Future<List<DeliveryZone>> zones();

  /// Which zone, if any, a postcode falls in.
  ///
  /// Throws [ApiFailure] only when the postcode itself is the problem --
  /// `POSTCODE_NOT_FOUND`, or the lookup service being down. An address simply
  /// outside every zone comes back as a [PostcodeCheck] with
  /// `deliverable: false`, because that is an answer.
  Future<PostcodeCheck> check(String postcode);
}

/// Managing the areas, as opposed to reading them.
///
/// Everything here is admin-only. The prices an admin sets are the prices
/// every customer is quoted, so a mistake here is a mistake at every till --
/// which is why the editor confirms a delete and prefers pausing.
abstract interface class AdminDeliveryZoneRepository {
  /// Every zone, including the paused ones.
  Future<List<AdminDeliveryZone>> zones();

  /// Draws a new one.
  ///
  /// [polygon] is 3-100 points in order, and must not repeat the first point at
  /// the end -- the server closes the ring itself.
  Future<AdminDeliveryZone> create({
    required String name,
    required List<ZonePoint> polygon,
    required int minOrderPence,
    required int deliveryFeePence,
    String? colorHex,
    int? priority,
    bool isActive,
  });

  /// Changes only what is passed.
  ///
  /// Repricing applies from the next quote; orders already placed keep the
  /// prices they were quoted, because those are snapshots.
  Future<AdminDeliveryZone> update(
    String id, {
    String? name,
    List<ZonePoint>? polygon,
    int? minOrderPence,
    int? deliveryFeePence,
    String? colorHex,
    int? priority,
    bool? isActive,
  });

  /// Permanent. Past orders are safe -- their zone name and fee were
  /// snapshotted -- but there is no undo, so pausing is usually what is meant.
  Future<void> delete(String id);
}
