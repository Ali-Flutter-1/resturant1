import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/motion.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/admin_nav.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_chip.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/dish_image.dart';
import '../../../shared/widgets/dish_list_skeleton.dart';
import '../../menu/domain/dish.dart';
import '../domain/admin_menu_repository.dart';
import 'category_logo_sheet.dart';
import 'admin_menu_cubit.dart';
import '../../../core/animations/page_transitions.dart';
import 'dish_configuration_screen.dart';
import 'dish_editor_sheet.dart';
import '../../auth/session_refresh.dart';
import '../../../shared/widgets/page_body.dart';

/// What's on and what's off tonight.
///
/// Layout transcribed from "Admin Mobile: Menu Management (Polished)"
/// (`1:3368`) — 44pt search row, 38pt category pills, 114pt list items on a
/// 32pt rhythm, 80pt thumbnail, 46pt floating action button.
///
/// Now backed by the API rather than by preview content: categories and dishes
/// come from `/admin/categories` and `/admin/dishes`, the availability switch
/// PATCHes the dish, and delete DELETEs it. Every mutation adopts what the
/// server returned instead of updating locally and hoping — an availability
/// switch that flips on a failed request leaves the kitchen believing a dish is
/// off the menu while customers keep ordering it.
class AdminMenuManagementScreen extends StatelessWidget {
  const AdminMenuManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          AdminMenuCubit(repository: context.read<AdminMenuRepository>())
            ..load(),
      child: const _AdminMenuView(),
    );
  }
}

class _AdminMenuView extends StatefulWidget {
  const _AdminMenuView();

  @override
  State<_AdminMenuView> createState() => _AdminMenuViewState();
}

class _AdminMenuViewState extends State<_AdminMenuView> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Opens the variants-and-choices editor for one dish.
  ///
  /// A separate screen rather than another tab in the dish sheet: the dish
  /// sheet is about what the dish *is*, and this is about how it is sold. They
  /// are edited at different times by different people, and the configuration
  /// is written through its own atomic endpoint.
  Future<void> _openConfiguration(Dish dish) async {
    final cubit = context.read<AdminMenuCubit>();
    final saved = await Navigator.of(context).push<Dish>(
      AppPageRoute<Dish>(builder: (_) => DishConfigurationScreen(dish: dish)),
    );
    if (saved == null || !mounted) return;
    // The server's version, with codes resolved to ids — so the row's price
    // and "from" label follow immediately.
    cubit.adopt(saved);
  }

  Future<void> _openEditor({Dish? dish}) async {
    final cubit = context.read<AdminMenuCubit>();
    final saved = await showDishEditor(
      context: context,
      repository: context.read<AdminMenuRepository>(),
      categories: cubit.state.categories,
      dish: dish,
    );
    if (saved == null || !mounted) return;

    cubit.adopt(saved);
    // A category created inside the editor arrives attached to the dish, which
    // is the only place its id is known — so the chip strip learns about it from
    // here rather than by reloading the whole menu.
    for (final category in saved.categories) {
      cubit.adoptCategory(category);
    }
    showAppSnack(
      context,
      dish == null
          ? '${saved.name} added to the menu.'
          : '${saved.name} updated.',
    );
  }

  Future<void> _setAvailability(Dish dish, bool value) async {
    AppHaptics.toggle();
    final error = await context.read<AdminMenuCubit>().setAvailability(
      dish.id,
      value,
    );
    if (error != null && mounted) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
    }
  }

  /// Confirms, then deletes.
  ///
  /// No undo, and the dialog says so: the API has no restore route for dishes,
  /// and a snackbar offering "Undo" that could not deliver it would be worse
  /// than not offering one.
  Future<void> _deleteDish(Dish dish) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${dish.name}?'),
        content: const Text(
          'It comes off the menu straight away and this cannot be undone. '
          'Past orders keep their own copy, so order history is unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.orderColors.overdue,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    AppHaptics.commit();
    final error = await context.read<AdminMenuCubit>().deleteDish(dish.id);
    if (!mounted) return;

    if (error != null) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
    } else {
      showAppSnack(context, '${dish.name} deleted.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAdminAppBar(context),
      // Lifted clear of the tab bar. Scaffold anchors a FAB to its own bottom
      // edge, and the shell's bar is an overlay in a Stack above this screen
      // rather than a `Scaffold.bottomNavigationBar` — so the FAB sat directly
      // underneath it, invisible and untappable. The shell reports the bar's
      // height as bottom padding, which is exactly the offset needed.
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: SizedBox(
          width: 46,
          height: 46,
          child: FloatingActionButton(
            onPressed: () {
              AppHaptics.commit();
              _openEditor();
            },
            tooltip: 'Add a dish to the menu',
            child: const Icon(Icons.add, size: AppIconSize.xl),
          ),
        ),
      ),
      body: BlocBuilder<AdminMenuCubit, AdminMenuState>(
        builder: (context, state) {
          final cubit = context.read<AdminMenuCubit>();

          final loading = state.status == AdminMenuStatus.loading;
          final visible = state.visible;

          // The search box and the category chips stay put through every state,
          // for the same reason as the inbox: a reload used to take the controls
          // away and put them back, so the filter you had just tapped vanished
          // while the request it started was still running.
          return Column(
            children: [
              _SearchAndFilter(
                controller: _search,
                onChanged: cubit.search,
              ).reveal(),
              const SizedBox(height: AppSpacing.x4),
              _CategoryStrip(
                onLogoChanged: () => cubit.load(silent: true),
                categories: state.categories,
                selectedId: state.categoryId,
                onSelected: cubit.selectCategory,
              ).revealItem(1),
              const SizedBox(height: AppSpacing.x4),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.gutter,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        loading
                            ? 'Loading tonight’s menu…'
                            : '${state.availableCount} of '
                                  '${state.dishes.length} dishes available '
                                  'tonight.',
                        style: context.texts.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ).revealItem(2),
              const SizedBox(height: AppSpacing.x3),
              if (loading)
                // Only the list is a placeholder; everything above it is real.
                const Expanded(
                  child: DishListSkeleton(rows: 4, imageHeight: 80),
                )
              else if (state.status == AdminMenuStatus.failure &&
                  state.failure != null)
                Expanded(
                  child: ApiErrorView(
                    failure: state.failure!,
                    onRetry: () => cubit.load(),
                  ),
                )
              else
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => refreshWithSession(
                      context,
                      () => cubit.load(silent: true),
                    ),
                    child: visible.isEmpty
                        ? _EmptyMenu(filtered: state.isFilteredEmpty)
                        : ListView.separated(
                            padding: pagePadding(
                              context,
                              top: 0,
                              bottom: // Clear the FAB as well as the tab bar.
                                  AppSpacing.x12 +
                                  MediaQuery.paddingOf(context).bottom,
                            ),
                            // One extra row for the footer where the menu
                            // runs to another page.
                            itemCount: visible.length + (state.hasMore ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.x8),
                            itemBuilder: (context, position) {
                              if (position >= visible.length) {
                                return Center(
                                  child: state.loadingMore
                                      ? const Padding(
                                          padding: EdgeInsets.all(
                                            AppSpacing.x3,
                                          ),
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        )
                                      : OutlinedButton(
                                          onPressed: context
                                              .read<AdminMenuCubit>()
                                              .loadMore,
                                          child: const Text('Load more dishes'),
                                        ),
                                );
                              }
                              final dish = visible[position];
                              return _DishCard(
                                // Keyed by id so a delete or a rename cannot hand
                                // this card's state to the dish that took its
                                // place.
                                key: ValueKey(dish.id),
                                dish: dish,
                                busy: state.busyIds.contains(dish.id),
                                onAvailabilityChanged: (value) =>
                                    _setAvailability(dish, value),
                                onEdit: () => _openEditor(dish: dish),
                                onConfigure: () => _openConfiguration(dish),
                                onDelete: () => _deleteDish(dish),
                              ).revealItem(position, duration: Motion.fast);
                            },
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The frame's 44pt row: a search input with a leading glyph, and a separate
/// 36pt filter button set off to the right of it.
class _SearchAndFilter extends StatelessWidget {
  const _SearchAndFilter({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search menu...',
                  prefixIcon: const Icon(Icons.search, size: AppIconSize.lg),
                  suffixIcon: controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: AppIconSize.md),
                          tooltip: 'Clear search',
                          onPressed: () {
                            controller.clear();
                            onChanged('');
                          },
                        ),
                ),
              ),
            ),
          ),
          // The filter icon is gone. It only ever said filters were not
          // designed yet; the category chips below already do the filtering.
        ],
      ),
    );
  }
}

/// The frame's category pills, from the API rather than a hardcoded list.
///
/// "All" is prepended here rather than invented in the state: it is a view
/// affordance, and a null selection already means every section.
class _CategoryStrip extends StatelessWidget {
  const _CategoryStrip({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.onLogoChanged,
  });

  final List<MenuCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  /// Re-reads the menu after a section's picture changed, so the strip and the
  /// customer's home screen agree.
  final VoidCallback? onLogoChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        itemCount: categories.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.x2),
        itemBuilder: (context, index) {
          if (index == 0) {
            return SelectableChip(
              label: 'All',
              selected: selectedId == null,
              onSelected: () => onSelected(null),
            );
          }
          final category = categories[index - 1];
          return SelectableChip(
            label: category.name,
            selected: selectedId == category.id,
            // Tapping the selected section clears it, which is the same
            // gesture as tapping "All" and is what a chip row is expected to
            // do.
            onSelected: () =>
                onSelected(selectedId == category.id ? null : category.id),
            // The pencil manages the section: its picture, its name, or
            // getting rid of it. This was a long press, which nobody finds --
            // the glyph costs a few points of chip width and says what it is.
            onManage: () async {
              final result = await showCategorySheet(context, category);
              // A rename, a new picture or an archive all change what the
              // strip and the customer's menu should show.
              if (result != null && context.mounted) onLogoChanged?.call();
            },
            manageIcon: Icons.edit_outlined,
            manageTooltip: 'Edit ${category.name}',
          );
        },
      ),
    );
  }
}

/// What the overflow menu on a row offers.
enum _DishAction { edit, configure, delete }

/// One dish, laid out as the frame's 114pt item: 80pt thumbnail, then name and
/// price on one line, a single-line description under it, and tag pills below
/// that. The trailing control is an overflow menu, not the pencil this screen
/// used to show — the frame's glyph is a 4×16 vertical ellipsis.
class _DishCard extends StatelessWidget {
  const _DishCard({
    super.key,
    required this.dish,
    required this.busy,
    required this.onAvailabilityChanged,
    required this.onEdit,
    required this.onConfigure,
    required this.onDelete,
  });

  final Dish dish;

  /// True while this row's own request is in flight.
  final bool busy;
  final ValueChanged<bool> onAvailabilityChanged;
  final VoidCallback onEdit;

  /// Sizes, servings and choice groups — how the dish is sold.
  final VoidCallback onConfigure;

  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = dish.isAvailable;

    return AnimatedOpacity(
      duration: context.motion.fade(Motion.fast),
      opacity: available ? 1 : 0.62,
      child: AppSurface.row(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 80,
                height: 80,
                child: DishImage(name: dish.name, imageUrl: dish.imageUrl),
              ),
            ),
            const SizedBox(width: AppSpacing.x4),
            Expanded(
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
                          style: context.texts.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x2),
                      // Flexible so the pair can share a narrow card: the
                      // switch and thumbnail leave this column under 100pt on
                      // a 320pt phone.
                      Flexible(
                        child: Text(
                          dish.formattedPrice,
                          style: AppTypography.money(
                            scheme.primary,
                            size: MoneySize.compact,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  // One line in the frame, so it truncates rather than
                  // reflowing the card to a taller shape.
                  Text(
                    dish.description,
                    style: context.texts.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.x2),
                  _Tags(dish: dish, available: available),
                ],
              ),
            ),
            // Availability is a switch on the row rather than an item in the
            // overflow. The frame has no switch here, but taking a dish off
            // the menu mid-service is the one thing this screen exists to do
            // quickly — burying it behind a menu costs two taps and hides the
            // current state. Stacked above the overflow so it competes with
            // the dish name for height rather than width.
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: available,
                  // Shrink-wrapped so the switch doesn't claim a 48pt tap
                  // target's worth of extra width on a 320pt phone.
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // Disabled mid-request, so a second flick can't queue a
                  // contradictory PATCH behind the first.
                  onChanged: busy ? null : onAvailabilityChanged,
                ),
                // Editing and deleting live behind the overflow. Deleting in
                // particular should not be one stray tap away from a row the
                // kitchen is scrolling past.
                SizedBox(
                  width: 24,
                  height: 28,
                  child: PopupMenuButton<_DishAction>(
                    padding: EdgeInsets.zero,
                    tooltip: 'Actions for ${dish.name}',
                    icon: Icon(
                      Icons.more_vert,
                      size: AppIconSize.lg,
                      color: context.surfaces.inkSoft,
                    ),
                    enabled: !busy,
                    onSelected: (action) => switch (action) {
                      _DishAction.edit => onEdit(),
                      _DishAction.configure => onConfigure(),
                      _DishAction.delete => onDelete(),
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<_DishAction>(
                        value: _DishAction.edit,
                        child: Text('Edit dish'),
                      ),
                      PopupMenuItem<_DishAction>(
                        value: _DishAction.configure,
                        child: Text(
                          dish.isConfigurable
                              ? 'Options & extras'
                              : 'Add options & extras',
                        ),
                      ),
                      PopupMenuItem<_DishAction>(
                        value: _DishAction.delete,
                        child: Text(
                          'Delete dish',
                          style: TextStyle(color: context.orderColors.overdue),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame shows one or two pills per item, the last of them outlined rather
/// than filled.
///
/// Availability used to take the outlined slot; the switch on the row now says
/// it plainly, so repeating it as a pill would be two controls for one fact.
class _Tags extends StatelessWidget {
  const _Tags({required this.dish, required this.available});

  final Dish dish;
  final bool available;

  @override
  Widget build(BuildContext context) {
    // The dish's sections, which is what the API actually carries — it has no
    // dietary flags any more, so a "Vegan" pill would have nothing behind it.
    // The first only: a dish in four sections would wrap the card to twice its
    // height.
    final section = dish.categories.isEmpty ? null : dish.categories.first.name;

    // Both branches flexible: a name like "Authentic Sri Lankan" and the
    // fallback label are each wider than this column gets on a 320pt phone.
    return Row(
      children: [
        Flexible(
          child: section != null
              ? AppChip(
                  label: section,
                  foreground: Theme.of(context).colorScheme.primary,
                  background: AppColors.crimson50,
                )
              : AppChip.outlined(
                  label: available ? 'On the menu' : 'Off tonight',
                ),
        ),
      ],
    );
  }
}

/// The design file has no empty state for any screen; this is invented, on the
/// same reasoning as the one on the customer menu.
class _EmptyMenu extends StatelessWidget {
  const _EmptyMenu({required this.filtered});

  /// True when a filter is hiding everything, rather than the menu being empty.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Scrollable so pull-to-refresh still works on an empty menu, which is
      // exactly when someone will try it.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
        _EmptyBody(filtered: filtered),
      ],
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.filtered});

  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered ? Icons.search_off : Icons.restaurant_menu,
              size: AppIconSize.hero,
              color: context.surfaces.inkSoft,
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              filtered ? 'Nothing on this filter' : 'No dishes yet',
              style: context.texts.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              filtered
                  ? 'Try another category, or clear the search.'
                  : 'Tap the plus button to add the first one.',
              style: context.texts.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
