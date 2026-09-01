import 'package:equatable/equatable.dart';
import 'package:flutter/painting.dart' show Color;

/// One delivery area, as the admin drew it.
///
/// Everything about what delivery costs lives here rather than in the app: the
/// minimum and the fee are per zone, and an admin can change either at any
/// time without a release. Nothing in this feature may hardcode a price.
class DeliveryZone extends Equatable {
  const DeliveryZone({
    required this.id,
    required this.name,
    required this.polygon,
    required this.minOrderPence,
    required this.deliveryFeePence,
    required this.priority,
    this.colorHex,
  });

  factory DeliveryZone.fromJson(Map<String, dynamic> json) {
    final points = json['polygon'];

    return DeliveryZone(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      polygon: points is List
          ? points
                .whereType<Map>()
                .map((p) => ZonePoint.fromJson(Map<String, dynamic>.from(p)))
                .toList()
          : const [],
      minOrderPence: (json['min_order_pence'] as num?)?.toInt() ?? 0,
      deliveryFeePence: (json['delivery_fee_pence'] as num?)?.toInt() ?? 0,
      // Lower wins where zones overlap. The backend applies this itself; the
      // app only needs it to draw the big ones underneath the small ones.
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      colorHex: json['color']?.toString(),
    );
  }

  final String id;
  final String name;
  final List<ZonePoint> polygon;
  final int minOrderPence;
  final int deliveryFeePence;
  final int priority;

  /// As `#rrggbb`, or null where the admin never chose one.
  final String? colorHex;

  /// The zone's colour, or [fallback] when it has none or it will not parse.
  ///
  /// Parsed defensively: this is free text on the server, and a zone with a
  /// typo in its colour should still appear on the map.
  Color colorOr(Color fallback) {
    final hex = colorHex?.trim().replaceFirst('#', '');
    if (hex == null || (hex.length != 6 && hex.length != 8)) return fallback;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return fallback;
    return Color(hex.length == 6 ? 0xFF000000 | value : value);
  }

  @override
  List<Object?> get props => [
    id,
    name,
    polygon,
    minOrderPence,
    deliveryFeePence,
    priority,
    colorHex,
  ];
}

/// A zone as the admin sees it: the public fields plus whether it is switched
/// on.
///
/// Kept separate from [DeliveryZone] for the same reason the menu is: the
/// public list returns only live zones, and an admin screen has to show the
/// paused ones too. A customer must never receive this shape.
class AdminDeliveryZone extends Equatable {
  const AdminDeliveryZone({required this.zone, required this.isActive});

  factory AdminDeliveryZone.fromJson(Map<String, dynamic> json) =>
      AdminDeliveryZone(
        zone: DeliveryZone.fromJson(json),
        // Defaults to on: a zone the server did not describe is more likely
        // live than paused, and showing it is the safer way to be wrong.
        isActive: json['is_active'] as bool? ?? true,
      );

  final DeliveryZone zone;
  final bool isActive;

  String get id => zone.id;
  String get name => zone.name;

  @override
  List<Object?> get props => [zone, isActive];
}

/// One vertex of a zone's outline.
class ZonePoint extends Equatable {
  const ZonePoint({required this.lat, required this.lng});

  factory ZonePoint.fromJson(Map<String, dynamic> json) => ZonePoint(
    lat: (json['lat'] as num?)?.toDouble() ?? 0,
    lng: (json['lng'] as num?)?.toDouble() ?? 0,
  );

  final double lat;
  final double lng;

  @override
  List<Object?> get props => [lat, lng];
}

/// What the server said about one postcode.
///
/// "Not deliverable" is an answer, not an error: the endpoint returns 200 with
/// `deliverable: false`, and the screen shows [message] and offers collection.
/// Only a malformed or unknown postcode is a failure.
class PostcodeCheck extends Equatable {
  const PostcodeCheck({
    required this.deliverable,
    required this.postcode,
    required this.message,
    this.zone,
  });

  factory PostcodeCheck.fromJson(Map<String, dynamic> json) {
    final zone = json['zone'];

    return PostcodeCheck(
      deliverable: json['deliverable'] == true,
      postcode: json['postcode']?.toString() ?? '',
      // The server's own words, shown verbatim.
      message: json['message']?.toString() ?? '',
      zone: zone is Map
          ? DeliveryZone.fromJson(Map<String, dynamic>.from(zone))
          : null,
    );
  }

  final bool deliverable;

  /// Normalised by the server, so it is worth writing back into the field.
  final String postcode;

  final String message;

  /// The zone this postcode falls in, when it falls in one.
  final DeliveryZone? zone;

  @override
  List<Object?> get props => [deliverable, postcode, message, zone];
}
