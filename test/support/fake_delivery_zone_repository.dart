import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/delivery/domain/delivery_zone.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';

/// Delivery zones from a script.
///
/// Defaults to the seeded Zone 1 — £30 minimum, £4 fee — because that is what
/// the real backend answers for a Thurso postcode, and most tests only care
/// that *some* zone came back.
class FakeDeliveryZoneRepository implements DeliveryZoneRepository {
  FakeDeliveryZoneRepository({this.deliverable = true, this.failure});

  static const zone1 = DeliveryZone(
    id: 'zone-1',
    name: 'Zone 1',
    polygon: [
      ZonePoint(lat: 58.615, lng: -3.575),
      ZonePoint(lat: 58.618, lng: -3.505),
      ZonePoint(lat: 58.600, lng: -3.470),
    ],
    minOrderPence: 3000,
    deliveryFeePence: 400,
    priority: 1,
    colorHex: '#e8a33d',
  );

  /// Whether the next postcode falls in a zone.
  bool deliverable;

  /// Thrown instead — for `POSTCODE_NOT_FOUND` and the lookup service being
  /// down, which are the only real failures here.
  ApiFailure? failure;

  int checkCalls = 0;
  String? lastPostcode;

  @override
  Future<List<DeliveryZone>> zones() async {
    if (failure != null) throw failure!;
    return const [zone1];
  }

  @override
  Future<PostcodeCheck> check(String postcode) async {
    checkCalls++;
    lastPostcode = postcode;
    if (failure != null) throw failure!;

    return PostcodeCheck(
      deliverable: deliverable,
      postcode: postcode.trim().toUpperCase(),
      message: deliverable
          ? 'Delivery is available to this address.'
          : 'Delivery is not available to this address.',
      zone: deliverable ? zone1 : null,
    );
  }
}
