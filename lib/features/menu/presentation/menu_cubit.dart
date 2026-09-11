import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../domain/dish.dart';
import '../domain/menu_repository.dart';

enum MenuStatus { loading, ready, failure }

class MenuState extends Equatable {
  const MenuState({
    this.status = MenuStatus.loading,
    this.categories = const [],
    this.dishes = const [],
    this.page = 1,
    this.totalPages = 0,
    this.loadingMore = false,
    this.failure,
    this.categorySlug,
    this.query = '',
  });

  final MenuStatus status;

  /// Sections as the API orders them, with "All" prepended by the UI rather
  /// than invented here.
  final List<MenuCategory> categories;

  /// Everything live, unfiltered. Filtering is a view concern — see [visible] —
  /// so switching a chip doesn't cost a round trip or a loading flicker.
  final List<Dish> dishes;

  /// The last page fetched and how many there are.
  ///
  /// An endpoint that does not paginate answers as a single complete page, so
  /// [hasMore] is false and nothing offers to fetch a second one.
  final int page;
  final int totalPages;
  final bool loadingMore;

  bool get hasMore => page < totalPages;

  /// Set only when [status] is [MenuStatus.failure]; its message is safe to
  /// show verbatim.
  final ApiFailure? failure;

  /// Null means every section.
  final String? categorySlug;

  final String query;

  /// The dishes a chip and a search box currently leave on screen.
  List<Dish> get visible {
    final needle = query.trim().toLowerCase();
    return dishes.where((dish) {
      // A dish can sit in several sections, so this is a membership test rather
      // than an equality one.
      final inCategory =
          categorySlug == null ||
          dish.categoryIds.contains(
            categories
                .firstWhere(
                  (c) => c.slug == categorySlug,
                  orElse: () => const MenuCategory(id: '', slug: '', name: ''),
                )
                .id,
          );

      final matches =
          needle.isEmpty ||
          dish.name.toLowerCase().contains(needle) ||
          dish.description.toLowerCase().contains(needle);

      return inCategory && matches;
    }).toList();
  }

  /// True when the menu loaded but a filter or search excludes everything —
  /// which is a different situation from the menu being empty, and deserves
  /// different words on screen.
  bool get isFilteredEmpty =>
      status == MenuStatus.ready && dishes.isNotEmpty && visible.isEmpty;

  MenuState copyWith({
    int? page,
    int? totalPages,
    bool? loadingMore,
    MenuStatus? status,
    List<MenuCategory>? categories,
    List<Dish>? dishes,
    ApiFailure? failure,
    String? categorySlug,
    String? query,
    bool clearCategory = false,
    bool clearFailure = false,
  }) {
    return MenuState(
      status: status ?? this.status,
      categories: categories ?? this.categories,
      dishes: dishes ?? this.dishes,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      loadingMore: loadingMore ?? this.loadingMore,
      failure: clearFailure ? null : (failure ?? this.failure),
      categorySlug: clearCategory ? null : (categorySlug ?? this.categorySlug),
      query: query ?? this.query,
    );
  }

  @override
  List<Object?> get props => [
    page,
    totalPages,
    loadingMore,
    status,
    categories,
    dishes,
    failure,
    categorySlug,
    query,
  ];
}

/// The menu.
///
/// Categories and dishes are fetched together because a dish carries only its
/// `category_id`: without the sections, a category chip has nothing to match
/// against. Fetching them in parallel costs one round trip rather than two.
class MenuCubit extends Cubit<MenuState> {
  MenuCubit({
    required MenuRepository repository,
    String? initialQuery,
    String? initialCategorySlug,
  }) : _repository = repository,
       super(
         MenuState(
           query: initialQuery ?? '',
           categorySlug: initialCategorySlug,
         ),
       );

  final MenuRepository _repository;

  /// Loads, or reloads after a failure.
  ///
  /// [silent] keeps whatever is already on screen while refetching, so a
  /// pull-to-refresh doesn't blank a menu the user is reading.
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      emit(state.copyWith(status: MenuStatus.loading, clearFailure: true));
    }

    try {
      // Awaited in turn rather than through `Future.wait`: its list form
      // loses both types and needs the casts that used to be here, and its
      // record form wraps a failure in a `ParallelWaitError` the catch below
      // would not recognise.
      final categories = await _repository.categories();
      final page = await _repository.dishes();

      emit(
        state.copyWith(
          status: MenuStatus.ready,
          categories: categories,
          dishes: page.items,
          page: page.page,
          totalPages: page.totalPages,
          loadingMore: false,
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      // A silent refresh that fails keeps the stale menu and says so, rather
      // than throwing away content the user can still read.
      emit(
        state.copyWith(
          status: silent && state.dishes.isNotEmpty
              ? MenuStatus.ready
              : MenuStatus.failure,
          failure: failure,
        ),
      );
    }
  }

  /// Null selects every section.
  /// Fetches the next page of dishes and appends it.
  ///
  /// Appended so the grid a customer is scrolling does not rebuild under them.
  /// Does nothing where the endpoint returned everything in one page, which is
  /// what [MenuState.hasMore] being false means.
  Future<void> loadMore() async {
    if (!state.hasMore || state.loadingMore) return;
    emit(state.copyWith(loadingMore: true, clearFailure: true));

    try {
      final next = await _repository.dishes(page: state.page + 1);
      emit(
        state.copyWith(
          dishes: [...state.dishes, ...next.items],
          page: next.page,
          totalPages: next.totalPages,
          loadingMore: false,
        ),
      );
    } on ApiFailure catch (failure) {
      // What is already listed stays; only the footer reports the problem.
      emit(state.copyWith(loadingMore: false, failure: failure));
    }
  }

  void selectCategory(String? slug) => emit(
    slug == null
        ? state.copyWith(clearCategory: true)
        : state.copyWith(categorySlug: slug),
  );

  void search(String query) => emit(state.copyWith(query: query));

  void clearFilters() => emit(state.copyWith(clearCategory: true, query: ''));
}
