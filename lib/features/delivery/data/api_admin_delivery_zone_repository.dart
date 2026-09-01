import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';

class ApiAdminDeliveryZoneRepository implements AdminDeliveryZoneRepository {
  ApiAdminDeliveryZoneRepository({required ApiClient client})
    : _client = client;

  final ApiClient _client;

  @override
  Future<List<AdminDeliveryZone>> zones() async {
    final data = await _client.list(ApiConstants.adminDeliveryZones);
    return [for (final zone in data) AdminDeliveryZone.fromJson(zone)];
  }

  @override
  Future<AdminDeliveryZone> create({
    required String name,
    required List<ZonePoint> polygon,
    required int minOrderPence,
    required int deliveryFeePence,
    String? colorHex,
    int? priority,
    bool isActive = true,
  }) async {
    final data = await _client.object(
      ApiConstants.adminDeliveryZones,
      method: 'POST',
      body: {
        'name': name.trim(),
        'polygon': [for (final p in polygon) _point(p)],
        'min_order_pence': minOrderPence,
        'delivery_fee_pence': deliveryFeePence,
        'color': ?colorHex,
        'priority': ?priority,
        'is_active': isActive,
      },
    );
    return AdminDeliveryZone.fromJson(data);
  }

  @override
  Future<AdminDeliveryZone> update(
    String id, {
    String? name,
    List<ZonePoint>? polygon,
    int? minOrderPence,
    int? deliveryFeePence,
    String? colorHex,
    int? priority,
    bool? isActive,
  }) async {
    final data = await _client.object(
      ApiConstants.adminDeliveryZone(id),
      method: 'PATCH',
      // Only what changed: a PATCH carrying every field would rewrite values
      // another admin edited a moment ago.
      body: {
        'name': ?name?.trim(),
        if (polygon != null) 'polygon': [for (final p in polygon) _point(p)],
        'min_order_pence': ?minOrderPence,
        'delivery_fee_pence': ?deliveryFeePence,
        'color': ?colorHex,
        'priority': ?priority,
        'is_active': ?isActive,
      },
    );
    return AdminDeliveryZone.fromJson(data);
  }

  @override
  Future<void> delete(String id) =>
      _client.object(ApiConstants.adminDeliveryZone(id), method: 'DELETE');

  Map<String, double> _point(ZonePoint p) => {'lat': p.lat, 'lng': p.lng};
}
