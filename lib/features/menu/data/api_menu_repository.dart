import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../../../core/network/page_data.dart';
import '../domain/dish.dart';
import '../domain/menu_repository.dart';

class ApiMenuRepository implements MenuRepository {
  ApiMenuRepository({required ApiClient client}) : _client = client;

  final ApiClient _client;

  @override
  Future<List<MenuCategory>> categories() async {
    final rows = await _client.list(ApiConstants.categories);
    return rows.map(MenuCategory.fromJson).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<PageData<Dish>> dishes({
    String? categorySlug,
    int page = 1,
    int pageSize = 40,
  }) async {
    final data = await _client.maybePage(
      ApiConstants.dishes,
      query: {
        'category': ?categorySlug,
        'page': page,
        'page_size': pageSize.clamp(1, 100),
      },
    );
    return data.map(Dish.fromJson);
  }

  @override
  Future<Dish> dishById(String id) async =>
      Dish.fromJson(await _client.object(ApiConstants.dish(id)));
}
