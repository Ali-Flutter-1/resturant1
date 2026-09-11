import '../../../core/network/page_data.dart';
import '../../menu/domain/dish.dart';
import 'dish_configuration_draft.dart';

/// Managing the menu: what staff can change, as opposed to what customers read.
///
/// Separate from `MenuRepository` because the two answer different questions.
/// The public one returns live dishes in live categories; this one returns
/// everything, including hidden and sold-out, which is precisely what an admin
/// screen needs and a customer must never see.
abstract interface class AdminMenuRepository {
  /// Replaces a dish's variants and option groups in one atomic write.
  ///
  /// This is the single mechanism for every configurable product — pizzas,
  /// drinks, breakfasts and anything the kitchen invents next. There is
  /// deliberately no per-category endpoint, and adding one would be the wrong
  /// shape.
  ///
  /// Returns the dish as it now stands, so the caller renders the server's
  /// version — which carries the ids the codes were resolved to — rather than
  /// its own draft.
  Future<Dish> setDishConfiguration(
    String dishId,
    DishConfigurationDraft draft,
  );

  /// Every category, including hidden ones.
  Future<List<MenuCategory>> categories();

  /// Creates a category and returns it, so the caller has its id.
  ///
  /// The slug and sort order are left to the server: it builds a slug from the
  /// name and puts a new category at the end of the menu, which is the right
  /// default and one fewer thing for an admin to decide.
  Future<MenuCategory> createCategory(String name);

  /// Renames a category.
  ///
  /// The slug is left alone deliberately: the server built it from the original
  /// name, customers may have it in a link, and the API treats the two as
  /// separate fields precisely so a typo fix does not break an address.
  Future<MenuCategory> renameCategory(String id, String name);

  /// Archives a category.
  ///
  /// Not a hard delete -- the API calls it archive, and offers a restore route
  /// -- so dishes that were in it are not orphaned and the decision is
  /// reversible from the backend. It disappears from the app either way.
  Future<void> deleteCategory(String id);

  /// Uploads a section's logo, replacing any previous one.
  ///
  /// Returns the whole category back, so the caller shows the `image_url` the
  /// server produced rather than building a Cloudinary URL of its own — the
  /// guide is explicit that the app must never construct one.
  Future<MenuCategory> setCategoryLogo(String categoryId, String filePath);

  /// Removes it. Safe on a category that never had one.
  Future<MenuCategory> removeCategoryLogo(String categoryId);

  /// Every dish, optionally narrowed to one category.
  /// One page at a time, like the public menu.
  Future<PageData<Dish>> dishes({
    String? categoryId,
    int page = 1,
    int pageSize = 40,
  });

  /// Uploads photographs and returns what to send as a dish's `images`.
  ///
  /// A separate step from creating the dish because that is how the API works:
  /// files go to `/admin/uploads/images`, which hands back a `public_id` and
  /// `url` per file, and those go into the dish. Up to six at a time.
  Future<List<DishPhoto>> uploadImages(List<String> filePaths);

  /// Creates a dish.
  ///
  /// [categoryIds] takes more than one — a dish can appear in several sections.
  /// [pricePence] is an integer because money in floating point is how a total
  /// ends up a penny out.
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
  });

  /// Changes only what is passed.
  ///
  /// Note the one exception the API documents: sending [categoryIds] **replaces**
  /// the whole set of sections rather than adding to it.
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
  });

  /// Removes a dish from the menu.
  ///
  /// Past orders keep their own copy of the title and price, so order history is
  /// unaffected — which is why this is safe to offer without a warning about
  /// receipts.
  Future<void> deleteDish(String id);
}
