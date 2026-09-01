import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/delivery/domain/delivery_zone.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';

/// Admin delivery zones from a script.
class FakeAdminDeliveryZoneRepository implements AdminDeliveryZoneRepository {
  FakeAdminDeliveryZoneRepository({List<AdminDeliveryZone>? zones})
    : stored = zones ?? [seeded];

  static const seeded = AdminDeliveryZone(
    zone: DeliveryZone(
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
    ),
    isActive: true,
  );

  List<AdminDeliveryZone> stored;
  ApiFailure? failure;

  int deleteCalls = 0;
  Map<String, Object?>? lastCreate;
  Map<String, Object?>? lastUpdate;

  @override
  Future<List<AdminDeliveryZone>> zones() async {
    if (failure != null) throw failure!;
    return stored;
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
    lastCreate = {
      'name': name,
      'points': polygon.length,
      'min_order_pence': minOrderPence,
      'delivery_fee_pence': deliveryFeePence,
      'color': colorHex,
      'priority': priority,
      'is_active': isActive,
    };
    if (failure != null) throw failure!;

    final created = AdminDeliveryZone(
      zone: DeliveryZone(
        id: 'zone-${stored.length + 1}',
        name: name,
        polygon: polygon,
        minOrderPence: minOrderPence,
        deliveryFeePence: deliveryFeePence,
        priority: priority ?? 0,
        colorHex: colorHex,
      ),
      isActive: isActive,
    );
    stored = [...stored, created];
    return created;
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
    lastUpdate = {
      'id': id,
      'name': name,
      'points': polygon?.length,
      'min_order_pence': minOrderPence,
      'delivery_fee_pence': deliveryFeePence,
      'color': colorHex,
      'priority': priority,
      'is_active': isActive,
    };
    if (failure != null) throw failure!;

    final existing = stored.firstWhere((zone) => zone.id == id);
    final updated = AdminDeliveryZone(
      zone: DeliveryZone(
        id: existing.id,
        name: name ?? existing.name,
        polygon: polygon ?? existing.zone.polygon,
        minOrderPence: minOrderPence ?? existing.zone.minOrderPence,
        deliveryFeePence: deliveryFeePence ?? existing.zone.deliveryFeePence,
        priority: priority ?? existing.zone.priority,
        colorHex: colorHex ?? existing.zone.colorHex,
      ),
      isActive: isActive ?? existing.isActive,
    );
    stored = [
      for (final zone in stored)
        if (zone.id == id) updated else zone,
    ];
    return updated;
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls++;
    if (failure != null) throw failure!;
    stored = [
      for (final zone in stored)
        if (zone.id != id) zone,
    ];
  }
}
