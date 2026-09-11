import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../../menu/domain/dish.dart';
import '../../menu/domain/menu_repository.dart';

enum DiscoverStatus { loading, ready, failure }

class DiscoverState extends Equatable {
  const DiscoverState({
    this.status = DiscoverStatus.loading,
    this.categories = const [],
    this.dishes = const [],
    this.failure,
  });

  final DiscoverStatus status;
  final List<MenuCategory> categories;

  /// Everything on the live menu. The home screen shows a slice of it — see
  /// [highlights] — and "See All" opens the full list.
  final List<Dish> dishes;

  final ApiFailure? failure;

  /// How many dishes the horizontal strip shows.
  ///
  /// Enough to look like a menu rather than a pair of samples, few enough that
  /// the home screen stays a summary and the strip is worth swiping.
  static const int highlightCount = 6;

  /// How many full-width cards sit above the strip.
  static const int heroCount = 3;

  /// The dishes on the home strip: available ones first, capped.
  ///
  /// Sold-out dishes sink rather than being dropped. The API deliberately keeps
  /// listing them so the menu doesn't appear to shrink through the evening, and
  /// hiding them here while the full menu shows them would make the two
  /// disagree.
  List<Dish> get highlights {
    final ordered = [
      ...dishes.where((d) => d.isAvailable),
      ...dishes.where((d) => !d.isAvailable),
    ];
    return ordered.take(highlightCount).toList();
  }

  /// Newest first, by `created_at`.
  ///
  /// Dishes with no timestamp sink rather than jumping the queue — an unknown
  /// date is not evidence of being new.
  List<Dish> get _newestFirst {
    final sorted = [...dishes];
    sorted.sort((a, b) {
      final at = a.createdAt, bt = b.createdAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return sorted;
  }

  /// The two full-width cards at the top: the latest additions to the menu.
  ///
  /// Available ones first, so a brand-new dish that is already sold out does not
  /// take the most prominent place on the screen. Empty when the menu is empty,
  /// in which case no card is drawn at all rather than a placeholder for a dish
  /// that does not exist.
  List<Dish> get heroes {
    final newest = _newestFirst;
    final ordered = [
      ...newest.where((d) => d.isAvailable),
      ...newest.where((d) => !d.isAvailable),
    ];
    return ordered.take(heroCount).toList();
  }

  /// The strip is what's left once the heroes are lifted out, so no dish is both
  /// a full-width card and a small one beside it.
  List<Dish> get strip {
    final heroIds = {for (final dish in heroes) dish.id};
    final rest = [
      ...dishes.where((d) => d.isAvailable && !heroIds.contains(d.id)),
      ...dishes.where((d) => !d.isAvailable && !heroIds.contains(d.id)),
    ];
    return rest.take(highlightCount).toList();
  }

  DiscoverState copyWith({
    DiscoverStatus? status,
    List<MenuCategory>? categories,
    List<Dish>? dishes,
    ApiFailure? failure,
    bool clearFailure = false,
  }) {
    return DiscoverState(
      status: status ?? this.status,
      categories: categories ?? this.categories,
      dishes: dishes ?? this.dishes,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }

  @override
  List<Object?> get props => [status, categories, dishes, failure];
}

/// The customer home screen's content.
///
/// Categories and dishes together, because the screen shows both and two cubits
/// would mean two loading states on one screen. No featured/popular endpoint
/// exists, so "featured" and the strip are derived here — see [DiscoverState] —
/// and the derivation lives in the state rather than the widget so it is
/// testable without pumping a screen.
class DiscoverCubit extends Cubit<DiscoverState> {
  DiscoverCubit({required MenuRepository repository})
    : _repository = repository,
      super(const DiscoverState());

  final MenuRepository _repository;

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      emit(state.copyWith(status: DiscoverStatus.loading, clearFailure: true));
    }

    try {
      // Awaited in turn and emitted once. `Future.wait` over a list of
      // differently typed futures loses both types, and the casts that stood
      // here were a runtime failure waiting for a signature to change -- which
      // is exactly what happened when the menu became paginated.
      final categories = await _repository.categories();
      final dishes = await _repository.dishes();

      emit(
        state.copyWith(
          status: DiscoverStatus.ready,
          categories: categories,
          // The home screen shows a selection, not the whole menu, so one
          // page is all it ever needed.
          dishes: dishes.items,
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          // A failed silent refresh keeps what is already on screen rather than
          // blanking a home screen the user is reading.
          status: silent && state.dishes.isNotEmpty
              ? DiscoverStatus.ready
              : DiscoverStatus.failure,
          failure: failure,
        ),
      );
    }
  }
}
