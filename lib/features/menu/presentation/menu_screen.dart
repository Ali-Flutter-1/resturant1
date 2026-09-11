import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/motion.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_chip.dart';
import '../../../shared/widgets/dish_list_skeleton.dart';
import '../../../shared/widgets/dish_image.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../../../shared/widgets/pressable.dart';
import '../domain/dish.dart';
import '../domain/menu_repository.dart';
import 'menu_cubit.dart';
import '../../auth/session_refresh.dart';
import '../../../shared/widgets/page_body.dart';

/// The full menu — a filterable list of large photographic cards.
///
/// Owns its own [MenuCubit] rather than taking one, because nothing outside
/// this screen needs the menu's load state. The repository comes from the
/// widget tree, so a test can supply a fake without a server.
class MenuScreen extends StatelessWidget {
  const MenuScreen({
    super.key,
    this.onOpenDish,
    this.initialQuery,
    this.initialCategorySlug,
  });

  final ValueChanged<Dish>? onOpenDish;

  /// Pre-fills the search box when arriving from Discover.
  final String? initialQuery;

  /// Opens already filtered to one section, for arriving from a category circle
  /// on the home screen.
  final String? initialCategorySlug;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => MenuCubit(
        repository: context.read<MenuRepository>(),
        initialQuery: initialQuery,
        initialCategorySlug: initialCategorySlug,
      )..load(),
      child: _MenuView(onOpenDish: onOpenDish, initialQuery: initialQuery),
    );
  }
}

class _MenuView extends StatefulWidget {
  const _MenuView({this.onOpenDish, this.initialQuery});

  final ValueChanged<Dish>? onOpenDish;
  final String? initialQuery;

  @override
  State<_MenuView> createState() => _MenuViewState();
}

class _MenuViewState extends State<_MenuView> {
  late final _search = TextEditingController(text: widget.initialQuery ?? '');

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MenuCubit>();

    return Scaffold(
      appBar: AppBar(
        // This screen is always pushed (from Discover), so it needs a way
        // back. Suppressing the implied leading had removed it: the flag
        // was added to keep a hamburger out, but with no Drawer attached
        // what it actually withheld was the back button, leaving the screen
        // escapable only by the Android system gesture.
        title: const Text("T's Cafe"),
        actions: [NotificationBell(onOpen: () => openNotifications(context))],
      ),
      body: BlocBuilder<MenuCubit, MenuState>(
        builder: (context, state) {
          return Column(
            children: [
              Padding(
                padding: pagePadding(context, top: 0, bottom: AppSpacing.x4),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: cubit.search,
                  decoration: InputDecoration(
                    hintText: 'Search the menu...',
                    prefixIcon: const Icon(Icons.search, size: AppIconSize.xl),
                    suffixIcon: state.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: AppIconSize.lg),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _search.clear();
                              cubit.search('');
                            },
                          ),
                  ),
                ),
              ),
              // Only once the sections have arrived: a strip of chips that
              // pops into existence mid-load is worse than one that waits.
              if (state.categories.isNotEmpty)
                _FilterStrip(
                  categories: state.categories,
                  selectedSlug: state.categorySlug,
                  onSelected: cubit.selectCategory,
                ),
              const SizedBox(height: AppSpacing.x4),
              Expanded(
                child: _Body(
                  state: state,
                  onOpenDish: widget.onOpenDish,
                  onClear: () {
                    _search.clear();
                    cubit.clearFilters();
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Chooses between the four things this screen can be: loading, broken, empty,
/// or a menu.
class _Body extends StatelessWidget {
  const _Body({
    required this.state,
    required this.onOpenDish,
    required this.onClear,
  });

  final MenuState state;
  final ValueChanged<Dish>? onOpenDish;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    switch (state.status) {
      case MenuStatus.loading:
        return const DishListSkeleton();

      case MenuStatus.failure:
        return ApiErrorView(
          failure: state.failure!,
          onRetry: context.read<MenuCubit>().load,
        );

      case MenuStatus.ready:
        if (state.dishes.isEmpty) return const _MenuEmpty();

        final visible = state.visible;
        // Only when nothing is narrowing the list -- see the footer note.
        final showMore =
            state.hasMore &&
            state.query.trim().isEmpty &&
            state.categorySlug == null;
        if (visible.isEmpty) {
          return _NoMatches(query: state.query, onClear: onClear);
        }

        return RefreshIndicator(
          // Silent, so pulling to refresh doesn't blank a menu being read.
          onRefresh: () => refreshWithSession(
            context,
            () => context.read<MenuCubit>().load(silent: true),
          ),
          child: ListView.separated(
            padding: pagePadding(
              context,
              top: 0,
              bottom: AppSpacing.x8 + MediaQuery.paddingOf(context).bottom,
            ),
            // One extra row for the footer where the menu runs to another
            // page. A search or a chip narrows what is already loaded, so the
            // footer is hidden then -- fetching a page that would mostly be
            // filtered out again reads as a button that does nothing.
            itemCount: visible.length + (showMore ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x4),
            itemBuilder: (context, index) {
              if (index >= visible.length) {
                return _MenuFooter(
                  loading: state.loadingMore,
                  onLoadMore: context.read<MenuCubit>().loadMore,
                );
              }
              return _MenuCard(
                dish: visible[index],
                onTap: onOpenDish,
              ).revealItem(index);
            },
          ),
        );
    }
  }
}

/// The end of the loaded menu, with a way to fetch more.
class _MenuFooter extends StatelessWidget {
  const _MenuFooter({required this.loading, required this.onLoadMore});

  final bool loading;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: loading
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.x3),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : OutlinedButton(
              onPressed: onLoadMore,
              child: const Text('Load more dishes'),
            ),
    );
  }
}

/// The menu itself is empty — no dishes published at all. Distinct from a
/// filter excluding everything, which [_NoMatches] covers.
class _MenuEmpty extends StatelessWidget {
  const _MenuEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restaurant_menu,
              size: AppIconSize.hero,
              color: context.surfaces.inkSoft,
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              'The menu is being updated',
              style: context.texts.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              'Nothing is published just now. Please check back shortly.',
              style: context.texts.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ).reveal(),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({
    required this.categories,
    required this.selectedSlug,
    required this.onSelected,
  });

  final List<MenuCategory> categories;
  final String? selectedSlug;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        // "All" is the app's own affordance, not a category: the API has no
        // such section, and without it the menu would open already filtered.
        itemCount: categories.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.x2),
        itemBuilder: (context, index) {
          if (index == 0) {
            return SelectableChip(
              label: 'All',
              selected: selectedSlug == null,
              onSelected: () => onSelected(null),
            );
          }
          final category = categories[index - 1];
          return SelectableChip(
            label: category.name,
            selected: category.slug == selectedSlug,
            onSelected: () => onSelected(category.slug),
          );
        },
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.dish, this.onTap});

  final Dish dish;
  final ValueChanged<Dish>? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Pressable(
      // A full-width row: the same 4% as a button would be a much larger
      // absolute movement here.
      scale: Motion.pressScaleLarge,
      // A sold-out dish stays on the menu but does not open: the API keeps
      // listing it so the menu doesn't appear to shrink through the evening.
      onTap: onTap == null || !dish.isAvailable ? null : () => onTap!(dish),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: context.surfaces.cardShadow,
          ),
          child: Column(
            // Stretch, so the photograph spans the card whether it is a real
            // image or the tinted placeholder. Under `start` the image block was
            // only as wide as it chose to be, which is why a dish with a picture
            // and one without did not match.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppRadius.lg),
                    ),
                    // A stated height rather than a ratio. A ratio's size
                    // depends on the width it happens to be handed, which is
                    // exactly what let the two cases differ.
                    child: SizedBox(
                      height: 168,
                      width: double.infinity,
                      child: DishImage(
                        name: dish.name,
                        imageUrl: dish.imageUrl,
                        heroTag: 'dish-${dish.id}',
                      ),
                    ),
                  ),
                  // The dish's section, which is what the API actually carries.
                  // The dietary chip that used to sit here had nothing behind it
                  // once the backend dropped its vegan/vegetarian flags.
                  if (dish.categories.isNotEmpty)
                    Positioned(
                      left: AppSpacing.x3,
                      bottom: AppSpacing.x3,
                      child: AppChip(
                        label: dish.categories.first.name,
                        foreground: scheme.onPrimary,
                        background: scheme.primary.withValues(alpha: 0.9),
                      ),
                    ),
                  if (!dish.isAvailable)
                    Positioned(
                      left: AppSpacing.x3,
                      top: AppSpacing.x3,
                      child: AppChip.status(
                        // "Not available" rather than "Sold out": an admin turns a dish
                        // off, which may be because it is finished for the night
                        // or because it is not being served at all. The app does
                        // not know which, so it should not claim to.
                        label: 'Not available',
                        foreground: context.orderColors.overdue,
                        background: context.orderColors.overdueContainer,
                      ),
                    ),
                  // The favourites heart is gone. The API has no favourites
                  // endpoint, so it only ever held state until the next
                  // restart — a control that looks like it saves something and
                  // does not is worse than no control.
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.x4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            dish.name,
                            style: context.texts.headlineMedium,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Text(
                          dish.formattedPrice,
                          style: AppTypography.money(
                            scheme.primary,
                            size: MoneySize.medium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x1),
                    // Capped at three lines. Uncapped, a dish with a paragraph
                    // of description made its card twice the height of the one
                    // above it and pushed the button off the fold.
                    Text(
                      dish.description,
                      style: context.texts.bodyMedium,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dish.prepTime != null) ...[
                      const SizedBox(height: AppSpacing.x2),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: AppIconSize.sm,
                            color: context.surfaces.inkSoft,
                          ),
                          const SizedBox(width: AppSpacing.x1 + 2),
                          Text(
                            dish.prepTime!,
                            style: context.texts.bodySmall?.copyWith(
                              color: context.surfaces.inkSoft,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpacing.x4),
                    OutlinedButton(
                      onPressed: onTap == null || !dish.isAvailable
                          ? null
                          : () => onTap!(dish),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        side: BorderSide(
                          color: scheme.primary.withValues(alpha: 0.5),
                        ),
                        foregroundColor: scheme.primary,
                      ),
                      child: Text(
                        dish.isAvailable ? 'Add to Order' : 'Not available',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: AppIconSize.hero,
              color: context.surfaces.inkSoft,
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              query.isEmpty ? 'Nothing on this filter' : 'No dishes match',
              style: context.texts.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              query.isEmpty
                  ? 'Try another part of the menu.'
                  : 'Nothing matches “$query”. Try a different search.',
              style: context.texts.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x5),
            OutlinedButton(
              onPressed: onClear,
              child: const Text('Clear filters'),
            ),
          ],
        ),
      ).reveal(),
    );
  }
}
