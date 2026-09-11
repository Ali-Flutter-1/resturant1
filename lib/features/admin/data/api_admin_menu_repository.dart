import '../../../core/network/api_client.dart';
import '../../../core/network/api_constants.dart';
import '../../../core/network/page_data.dart';
import '../../menu/domain/dish.dart';
import '../domain/admin_menu_repository.dart';
import '../domain/dish_configuration_draft.dart';
import '../../../core/network/api_failure.dart';

class ApiAdminMenuRepository implements AdminMenuRepository {
  ApiAdminMenuRepository({required ApiClient client}) : _client = client;

  final ApiClient _client;

  @override
  Future<Dish> setDishConfiguration(
    String dishId,
    DishConfigurationDraft draft,
  ) async {
    // Refused before the round trip. The server would answer 422, but it has no
    // way to say "two of your sizes share a code" against a particular field,
    // and a replace that half-applies is not something to find out about after
    // the fact.
    final problems = draft.problems;
    if (problems.isNotEmpty) {
      throw ApiFailure(
        kind: ApiFailureKind.invalid,
        message: problems.first,
        code: 'CONFIGURATION_INVALID',
      );
    }

    final data = await _client.object(
      ApiConstants.adminDishConfiguration(dishId),
      method: 'PUT',
      body: draft.toJson(),
    );
    return Dish.fromJson(data);
  }

  @override
  Future<List<MenuCategory>> categories() async {
    final rows = await _client.list(ApiConstants.adminCategories);
    return rows.map(MenuCategory.fromJson).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<MenuCategory> createCategory(String name) async {
    final data = await _client.object(
      ApiConstants.adminCategories,
      method: 'POST',
      // Only the name. Slug and sort order are omitted rather than sent empty:
      // the API builds a slug from the name and appends to the menu, and sending
      // nulls would risk overwriting those defaults with nothing.
      body: {'name': name.trim()},
    );
    return MenuCategory.fromJson(data);
  }

  @override
  Future<PageData<Dish>> dishes({
    String? categoryId,
    int page = 1,
    int pageSize = 40,
  }) async {
    final data = await _client.maybePage(
      ApiConstants.adminDishes,
      query: {
        'category_id': ?categoryId,
        'page': page,
        'page_size': pageSize.clamp(1, 100),
      },
    );
    return data.map(Dish.fromJson);
  }

  @override
  Future<List<DishPhoto>> uploadImages(List<String> filePaths) async {
    if (filePaths.isEmpty) return const [];
    final rows = await _client.uploadList(
      ApiConstants.adminImageUploads,
      field: 'files',
      filePaths: filePaths,
    );
    return rows.map(DishPhoto.fromJson).toList();
  }

  @override
  Future<Dish> createDish({
    required String title,
    String? description,
    required List<String> categoryIds,
    required int pricePence,
    List<DishPhoto> images = const [],
    int? prepMinMinutes,
    int? prepMaxMinutes,
    bool isAvailable = true,
    bool hasSpiceLevels = false,
  }) async {
    final data = await _client.object(
      ApiConstants.adminDishes,
      method: 'POST',
      body: {
        'title': title.trim(),
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        'category_ids': categoryIds,
        'price_pence': pricePence,
        if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
        'preparation_time_min_minutes': ?prepMinMinutes,
        'preparation_time_max_minutes': ?prepMaxMinutes,
        'is_available': isAvailable,
        // Whether the customer is offered Low/Mid/High. False means no selector
        // at all, and sending a level for such a dish is refused.
        'has_spice_levels': hasSpiceLevels,
      },
    );
    return Dish.fromJson(data);
  }

  @override
  Future<Dish> updateDish(
    String id, {
    String? title,
    String? description,
    List<String>? categoryIds,
    int? pricePence,
    List<DishPhoto>? images,
    int? prepMinMinutes,
    int? prepMaxMinutes,
    bool? isAvailable,
    bool? hasSpiceLevels,
  }) async {
    // Only what was passed. A PATCH that sent every field would turn "make this
    // one sold out" into "overwrite this dish with whatever the screen last
    // read", which is how a stale form quietly reverts somebody else's edit.
    final data = await _client.object(
      ApiConstants.adminDish(id),
      method: 'PATCH',
      body: {
        'title': ?title?.trim(),
        'description': ?description?.trim(),
        'category_ids': ?categoryIds,
        'price_pence': ?pricePence,
        if (images != null) 'images': [for (final i in images) i.toJson()],
        'preparation_time_min_minutes': ?prepMinMinutes,
        'preparation_time_max_minutes': ?prepMaxMinutes,
        'is_available': ?isAvailable,
        'has_spice_levels': ?hasSpiceLevels,
      },
    );
    return Dish.fromJson(data);
  }

  @override
  Future<void> deleteDish(String id) async =>
      _client.send(ApiConstants.adminDish(id), method: 'DELETE');

  @override
  Future<MenuCategory> renameCategory(String id, String name) async =>
      MenuCategory.fromJson(
        await _client.object(
          ApiConstants.adminCategory(id),
          method: 'PATCH',
          // Only the name. `slug`, `sort_order` and `is_active` are all
          // updatable through the same route, and sending the ones nobody
          // edited would let a stale copy overwrite a change made elsewhere.
          body: {'name': name.trim()},
        ),
      );

  @override
  Future<void> deleteCategory(String id) async =>
      _client.send(ApiConstants.adminCategory(id), method: 'DELETE');

  @override
  Future<MenuCategory> setCategoryLogo(
    String categoryId,
    String filePath,
  ) async {
    final data = await _client.upload(
      ApiConstants.adminCategoryLogo(categoryId),
      // The API's field name. Anything else is a 422 that reads as "no file".
      field: 'file',
      filePaths: [filePath],
    );
    if (data is! Map) {
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'The server sent something unexpected. Please try again.',
      );
    }
    return MenuCategory.fromJson(Map<String, dynamic>.from(data));
  }

  @override
  Future<MenuCategory> removeCategoryLogo(String categoryId) async {
    final data = await _client.object(
      ApiConstants.adminCategoryLogo(categoryId),
      method: 'DELETE',
    );
    return MenuCategory.fromJson(data);
  }
}
