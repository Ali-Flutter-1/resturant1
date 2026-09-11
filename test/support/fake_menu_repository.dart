import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/network/page_data.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/features/menu/domain/menu_repository.dart';

/// A menu that answers from memory.
///
/// Shared by every widget test that renders a screen reading the menu, so the
/// fixture stays in one place and a change to the model doesn't have to be
/// chased through four test files.
class FakeMenuRepository implements MenuRepository {
  FakeMenuRepository({
    List<MenuCategory>? categories,
    List<Dish>? dishes,
    this.failure,
    this.delay = Duration.zero,
  }) : _categories = categories ?? defaultCategories,
       _dishes = dishes ?? defaultDishes;

  /// Thrown by every method when set, for exercising the failure path.
  final ApiFailure? failure;

  /// Lets a test observe the loading state before data lands.
  final Duration delay;

  final List<MenuCategory> _categories;
  final List<Dish> _dishes;

  static const curries = MenuCategory(
    id: 'cat-1',
    slug: 'curry-dishes',
    name: 'Curry Dishes',
    sortOrder: 1,
  );

  static const smallPlates = MenuCategory(
    id: 'cat-2',
    slug: 'small-plates',
    name: 'Small Plates',
    sortOrder: 2,
  );

  static const defaultCategories = [curries, smallPlates];

  static const jaffnaCrab = Dish(
    id: 'd1',
    name: 'Jaffna Crab Curry',
    description: 'Fresh mud crab in roasted spices and coconut milk.',
    pricePence: 2800,
    categories: [curries],
  );

  static const jackfruit = Dish(
    id: 'd2',
    name: 'Young Jackfruit Curry',
    description: 'Slow-cooked green jackfruit, entirely plant based.',
    pricePence: 1800,
    categories: [curries],
    isVegan: true,
    isVegetarian: true,
  );

  static const hoppers = Dish(
    id: 'd3',
    name: 'Heritage Hoppers',
    description: 'Fermented rice flour and coconut milk pancakes.',
    pricePence: 950,
    categories: [smallPlates],
    isVegetarian: true,
  );

  /// Turned off by an admin. The API keeps listing these with `is_available`
  /// false so the app greys them out rather than making the menu appear to
  /// shrink.
  static const soldOut = Dish(
    id: 'd4',
    name: 'Black Pork Curry',
    description: 'Dark roasted heritage classic.',
    pricePence: 2200,
    categories: [curries],
    isAvailable: false,
  );

  static const defaultDishes = [jaffnaCrab, jackfruit, hoppers, soldOut];

  Future<T> _answer<T>(T value) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final error = failure;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<List<MenuCategory>> categories() => _answer(_categories);

  @override
  Future<PageData<Dish>> dishes({
    String? categorySlug,
    int page = 1,
    int pageSize = 40,
  }) {
    lastPageAsked = page;
    final rows = categorySlug == null
        ? _dishes
        : _dishes
              .where(
                (d) => d.categoryIds.contains(
                  _categories
                      .firstWhere(
                        (c) => c.slug == categorySlug,
                        orElse: () => _categories.first,
                      )
                      .id,
                ),
              )
              .toList();
    return _answer(_slice(rows, page, pageSize));
  }

  /// The page number of the last request.
  int? lastPageAsked;

  /// A real slice, so a pagination test tests pagination rather than a fake
  /// that returns everything whatever page it is asked for.
  static PageData<Dish> _slice(List<Dish> rows, int page, int pageSize) {
    final start = (page - 1) * pageSize;
    return PageData(
      items: start >= rows.length
          ? const []
          : rows.sublist(start, (start + pageSize).clamp(0, rows.length)),
      page: page,
      pageSize: pageSize,
      total: rows.length,
      totalPages: (rows.length / pageSize).ceil(),
    );
  }

  @override
  Future<Dish> dishById(String id) =>
      _answer(_dishes.firstWhere((d) => d.id == id));
}
