import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';

class ApiDeliveryZoneRepository implements DeliveryZoneRepository {
  ApiDeliveryZoneRepository({required ApiClient client}) : _client = client;

  final ApiClient _client;

  @override
  Future<List<DeliveryZone>> zones() async {
    final data = await _client.list(ApiConstants.deliveryZones);
    return [for (final zone in data) DeliveryZone.fromJson(zone)];
  }

  @override
  Future<PostcodeCheck> check(String postcode) async {
    final data = await _client.object(
      ApiConstants.deliveryZoneCheck,
      method: 'POST',
      body: {'postcode': postcode.trim().toUpperCase()},
    );
    return PostcodeCheck.fromJson(data);
  }
}
