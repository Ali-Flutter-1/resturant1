import '../../../core/network/api_client.dart';
import '../../../core/network/page_data.dart';
import '../../../core/network/api_constants.dart';
import '../domain/admin_order.dart';
import '../domain/admin_order_repository.dart';

class ApiAdminOrderRepository implements AdminOrderRepository {
  ApiAdminOrderRepository({required ApiClient client}) : _client = client;

  final ApiClient _client;

  @override
  Future<PageData<AdminOrder>> orders({
    int page = 1,
    int pageSize = 20,
    OrderStatus? status,
    FulfilmentType? fulfilment,
    bool openOnly = false,
  }) async {
    final data = await _client.page(
      ApiConstants.adminOrders,
      query: {
        'page': page,
        // The API's own ceiling is 100.
        'page_size': pageSize.clamp(1, 100),
        // Omitted rather than sent empty: an absent filter and a filter for
        // nothing are different requests.
        'status': ?status?.wire,
        'fulfilment_type': ?fulfilment?.wire,
        if (openOnly) 'open_only': true,
      },
    );
    return data.map(AdminOrder.fromJson);
  }

  @override
  Future<OrderStats> stats() async =>
      OrderStats.fromJson(await _client.object(ApiConstants.adminOrderStats));

  @override
  Future<AdminOrder> orderById(String id) async =>
      AdminOrder.fromJson(await _client.object(ApiConstants.adminOrder(id)));

  @override
  Future<AdminOrder> approve(String id) async => AdminOrder.fromJson(
    await _client.object(ApiConstants.adminOrderApprove(id), method: 'POST'),
  );

  @override
  Future<AdminOrder> decline(String id, {required String reason}) async =>
      AdminOrder.fromJson(
        await _client.object(
          ApiConstants.adminOrderDecline(id),
          method: 'POST',
          body: {'reason': reason.trim()},
        ),
      );

  @override
  Future<AdminOrder> updateStatus(
    String id, {
    required OrderStatus status,
    String? note,
  }) async {
    final data = await _client.object(
      ApiConstants.adminOrderStatus(id),
      method: 'PATCH',
      body: {
        'status': status.wire,
        'note': ?(note?.trim().isEmpty ?? true) ? null : note!.trim(),
      },
    );
    return AdminOrder.fromJson(data);
  }
}
