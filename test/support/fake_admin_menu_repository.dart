import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/admin/domain/admin_menu_repository.dart';
import 'package:practice/features/admin/domain/dish_configuration_draft.dart';
import 'package:practice/features/menu/domain/dish.dart';

/// An [AdminMenuRepository] that answers from memory and records what it was
/// asked to do.
///
/// The recording is the point. Saving a dish is three chained calls — create any
/// new category, upload the photograph, then create the dish — and the thing
/// worth asserting is that they happened in that order with the ids threaded
/// through. A test that only checked the sheet closed would pass with the
/// category silently dropped.
class FakeAdminMenuRepository implements AdminMenuRepository {
  FakeAdminMenuRepository({List<MenuCategory>? categories, this.failure})
    : _categories = categories ?? [...defaultCategories];

  /// Every configuration that was saved, newest last, so a test can assert on
  /// the exact payload rather than only that the call happened.
  final List<(String dishId, DishConfigurationDraft draft)> configurations = [];

  /// What [setDishConfiguration] returns. Set it to the dish the server would
  /// have answered with.
  Dish? configuredDish;

  @override
  Future<Dish> setDishConfiguration(
    String dishId,
    DishConfigurationDraft draft,
  ) async {
    if (failure != null) throw failure!;
    configurations.add((dishId, draft));
    return configuredDish ??
        const Dish(id: '', name: '', description: '', pricePence: 0);
  }

  static const curries = MenuCategory(
    id: 'cat-1',
    slug: 'curry-dishes',
    name: 'Curry Dishes',
    sortOrder: 1,
  );
  static const vegan = MenuCategory(
    id: 'cat-2',
    slug: 'vegan',
    name: 'Vegan',
    sortOrder: 2,
  );
  static const defaultCategories = [curries, vegan];

  List<MenuCategory> _categories;
  final List<Dish> _dishes = [];

  ApiFailure? failure;

  final createdCategories = <String>[];
  final renamedCategories = <(String, String)>[];
  final deletedCategories = <String>[];
  final uploadedPaths = <String>[];
  Map<String, Object?>? lastCreate;
  Map<String, Object?>? lastUpdate;
  final deletedIds = <String>[];
  int _nextId = 1;

  void _check() {
    final error = failure;
    if (error != null) throw error;
  }

  // Copies, not the internal lists. Handing out a reference made this fake lie
  // about a real behaviour: `createDish` appended to the very list already held
  // in cubit state, so the state mutated in place, Equatable saw no change, and
  // `emit` became a no-op — a screen that looked broken because of the double.
  // Every real HTTP response is a fresh list, and the fake has to match.
  @override
  Future<List<MenuCategory>> categories() async {
    _check();
    return List.of(_categories);
  }

  @override
  Future<MenuCategory> createCategory(String name) async {
    _check();
    createdCategories.add(name);
    final created = MenuCategory(
      id: 'cat-new-${_categories.length + 1}',
      slug: name.toLowerCase().replaceAll(' ', '-'),
      name: name,
    );
    _categories.add(created);
    return created;
  }

  @override
  Future<MenuCategory> renameCategory(String id, String name) async {
    _check();
    renamedCategories.add((id, name));
    final existing = _categories.firstWhere((c) => c.id == id);
    // The slug deliberately stays as it was, exactly as the API behaves.
    final renamed = MenuCategory(
      id: existing.id,
      slug: existing.slug,
      name: name,
      description: existing.description,
      imageUrl: existing.imageUrl,
      sortOrder: existing.sortOrder,
    );
    _categories = [
      for (final c in _categories)
        if (c.id == id) renamed else c,
    ];
    return renamed;
  }

  @override
  Future<void> deleteCategory(String id) async {
    _check();
    deletedCategories.add(id);
    _categories = [..._categories]..removeWhere((c) => c.id == id);
  }

  @override
  Future<List<Dish>> dishes({String? categoryId}) async {
    _check();
    return categoryId == null
        ? List.of(_dishes)
        : _dishes.where((d) => d.categoryIds.contains(categoryId)).toList();
  }

  @override
  Future<List<DishPhoto>> uploadImages(List<String> filePaths) async {
    _check();
    uploadedPaths.addAll(filePaths);
    return [
      for (final path in filePaths)
        DishPhoto(
          publicId: 'public-$path',
          url: 'https://cdn.example.com/$path.jpg',
        ),
    ];
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
    _check();
    lastCreate = {
      'title': title,
      'description': description,
      'category_ids': categoryIds,
      'price_pence': pricePence,
      'images': images,
      'prep_min': prepMinMinutes,
      'prep_max': prepMaxMinutes,
      'is_available': isAvailable,
      'has_spice_levels': hasSpiceLevels,
    };
    final dish = Dish(
      id: 'dish-${_nextId++}',
      name: title,
      description: description ?? '',
      pricePence: pricePence,
      categories: [
        for (final id in categoryIds)
          _categories.firstWhere(
            (c) => c.id == id,
            orElse: () => MenuCategory(id: id, slug: id, name: id),
          ),
      ],
      images: images,
      prepMinMinutes: prepMinMinutes,
      prepMaxMinutes: prepMaxMinutes,
      hasSpiceLevels: hasSpiceLevels,
      isAvailable: isAvailable,
    );
    _dishes.add(dish);
    return dish;
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
    _check();
    lastUpdate = {
      'id': id,
      'title': title,
      'category_ids': categoryIds,
      'price_pence': pricePence,
      'is_available': isAvailable,
    };
    final existing = _dishes.firstWhere(
      (d) => d.id == id,
      orElse: () => Dish(
        id: id,
        name: title ?? 'Dish',
        description: description ?? '',
        pricePence: pricePence ?? 0,
      ),
    );
    final updated = Dish(
      id: id,
      name: title ?? existing.name,
      description: description ?? existing.description,
      pricePence: pricePence ?? existing.pricePence,
      categories: categoryIds == null
          ? existing.categories
          : [
              for (final cid in categoryIds)
                _categories.firstWhere(
                  (c) => c.id == cid,
                  orElse: () => MenuCategory(id: cid, slug: cid, name: cid),
                ),
            ],
      images: images ?? existing.images,
      prepMinMinutes: prepMinMinutes ?? existing.prepMinMinutes,
      prepMaxMinutes: prepMaxMinutes ?? existing.prepMaxMinutes,
      isAvailable: isAvailable ?? existing.isAvailable,
    );
    final index = _dishes.indexWhere((d) => d.id == id);
    if (index >= 0) {
      _dishes[index] = updated;
    } else {
      _dishes.add(updated);
    }
    return updated;
  }

  @override
  Future<void> deleteDish(String id) async {
    _check();
    deletedIds.add(id);
    _dishes.removeWhere((d) => d.id == id);
  }

  /// Seeds a dish without going through [createDish], for tests about the list
  /// rather than about saving.
  void seed(Dish dish) => _dishes.add(dish);

  final List<Map<String, String?>> logoChanges = [];

  @override
  Future<MenuCategory> setCategoryLogo(
    String categoryId,
    String filePath,
  ) async {
    logoChanges.add({'id': categoryId, 'path': filePath});
    final existing = _categories.firstWhere((c) => c.id == categoryId);
    final updated = MenuCategory(
      id: existing.id,
      slug: existing.slug,
      name: existing.name,
      description: existing.description,
      imageUrl: 'https://res.cloudinary.com/demo/$categoryId.jpg',
      sortOrder: existing.sortOrder,
    );
    _categories = [
      for (final c in _categories)
        if (c.id == categoryId) updated else c,
    ];
    return updated;
  }

  @override
  Future<MenuCategory> removeCategoryLogo(String categoryId) async {
    logoChanges.add({'id': categoryId, 'path': null});
    final existing = _categories.firstWhere((c) => c.id == categoryId);
    final updated = MenuCategory(
      id: existing.id,
      slug: existing.slug,
      name: existing.name,
      description: existing.description,
      sortOrder: existing.sortOrder,
    );
    _categories = [
      for (final c in _categories)
        if (c.id == categoryId) updated else c,
    ];
    return updated;
  }
}
