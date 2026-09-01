import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../orders/domain/order_quote.dart';
import '../../venue/domain/restaurant_location.dart';
import '../domain/delivery_zone.dart';

/// Where we deliver, and what it costs.
///
/// The same `flutter_map` and OpenStreetMap tiles as the restaurant's own map
/// card -- no second mapping SDK, no billed key -- with one polygon per zone
/// and a legend built from the same data.
///
/// Every figure here comes from the server. The admin redraws areas and changes
/// fees without an app release, so a price written into this file would quietly
/// become a lie.
class DeliveryZonesMap extends StatelessWidget {
  const DeliveryZonesMap({super.key, required this.zones, this.height = 220});

  final List<DeliveryZone> zones;
  final double height;

  static const LatLng _venue = LatLng(
    RestaurantLocation.latitude,
    RestaurantLocation.longitude,
  );

  /// The zones, largest area first.
  ///
  /// `priority` is the server's tie-breaker where zones overlap: the lowest
  /// number wins, and the backend applies that itself. Drawing in reverse means
  /// the cheap inner zone is painted last, so it sits on top of the rings
  /// around it rather than under them.
  List<DeliveryZone> get _painted =>
      [...zones]..sort((a, b) => b.priority.compareTo(a.priority));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drawable = _painted
        .where((zone) => zone.polygon.length >= 3)
        .toList();

    return AppSurface.row(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: _venue,
                initialZoom: 10,
                // Zones cover miles rather than streets, so unlike the address
                // card this one is worth pinching and panning.
                initialCameraFit: drawable.isEmpty
                    ? null
                    : CameraFit.bounds(
                        bounds: _boundsOf(drawable),
                        padding: const EdgeInsets.all(AppSpacing.x6),
                      ),
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  // OSM's tile policy asks for an identifying agent.
                  userAgentPackageName: 'com.tscafe.app',
                ),
                PolygonLayer(
                  polygons: [
                    for (final zone in drawable)
                      Polygon(
                        points: [
                          for (final p in zone.polygon) LatLng(p.lat, p.lng),
                        ],
                        // A wash rather than a fill: the streets underneath are
                        // what tell somebody whether their address is inside.
                        color: zone
                            .colorOr(scheme.primary)
                            .withValues(alpha: 0.20),
                        borderColor: zone.colorOr(scheme.primary),
                        borderStrokeWidth: 2,
                      ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _venue,
                      width: 36,
                      height: 36,
                      alignment: Alignment.topCenter,
                      child: Icon(
                        Icons.place,
                        size: 36,
                        color: scheme.primary,
                        shadows: const [
                          Shadow(blurRadius: 4, color: Colors.black26),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, zone) in zones.indexed) ...[
                  if (index > 0) const SizedBox(height: AppSpacing.x3),
                  _ZoneLegendRow(zone: zone),
                ],
                const SizedBox(height: AppSpacing.x3),
                Text(
                  // The postcode decides it, not the pin: an address near a
                  // boundary is settled by the check at checkout, and saying so
                  // here avoids an argument at the door.
                  'Your postcode decides the area. We confirm it at checkout.',
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A box containing every zone, so the map opens showing all of them.
  static LatLngBounds _boundsOf(List<DeliveryZone> zones) {
    final points = [
      for (final zone in zones)
        for (final point in zone.polygon) LatLng(point.lat, point.lng),
      _venue,
    ];
    return LatLngBounds.fromPoints(points);
  }
}

/// One line of the legend: the zone's colour, its name, and its prices.
class _ZoneLegendRow extends StatelessWidget {
  const _ZoneLegendRow({required this.zone});

  final DeliveryZone zone;

  @override
  Widget build(BuildContext context) {
    final colour = zone.colorOr(Theme.of(context).colorScheme.primary);

    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.25),
            border: Border.all(color: colour, width: 2),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(child: Text(zone.name, style: context.texts.titleSmall)),
        Text(
          'Min ${OrderQuote.formatPence(zone.minOrderPence)} · '
          'Fee ${OrderQuote.formatPence(zone.deliveryFeePence)}',
          style: context.texts.bodySmall?.copyWith(
            color: context.surfaces.inkMuted,
          ),
        ),
      ],
    );
  }
}
