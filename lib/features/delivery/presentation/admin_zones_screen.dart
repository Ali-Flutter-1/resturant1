import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/page_transitions.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/page_body.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/session_refresh.dart';
import '../../orders/domain/order_quote.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';
import 'admin_zones_cubit.dart';
import 'delivery_zones_map.dart';
import 'zone_editor_screen.dart';

/// The delivery areas an admin manages.
///
/// What is set here is what every customer is quoted, so the screen leans
/// towards the reversible: pausing is a switch, deleting asks first and says
/// plainly that it cannot be undone.
class AdminZonesScreen extends StatelessWidget {
  const AdminZonesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AdminZonesCubit(
        repository: context.read<AdminDeliveryZoneRepository>(),
      )..load(),
      child: const _AdminZonesView(),
    );
  }
}

class _AdminZonesView extends StatelessWidget {
  const _AdminZonesView();

  Future<void> _edit(BuildContext context, {AdminDeliveryZone? zone}) async {
    final cubit = context.read<AdminZonesCubit>();
    final saved = await Navigator.of(context).push<AdminDeliveryZone>(
      AppPageRoute<AdminDeliveryZone>(
        builder: (_) => ZoneEditorScreen(zone: zone),
      ),
    );
    if (saved != null) cubit.adopt(saved);
  }

  Future<void> _delete(BuildContext context, AdminDeliveryZone zone) async {
    final cubit = context.read<AdminZonesCubit>();
    final confirmed = await showAppSheet<bool>(
      context: context,
      title: 'Delete ${zone.name}?',
      child: Builder(
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.x2 + MediaQuery.paddingOf(sheetContext).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                // Both halves matter: nothing already sold is affected, and
                // there is no getting the outline back.
                'Orders already placed keep the price they were quoted. The '
                'area itself cannot be recovered — if you only want to stop '
                'delivering here for now, turn it off instead.',
                style: sheetContext.texts.bodyMedium?.copyWith(
                  color: sheetContext.surfaces.inkMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.x5),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: const Text('Keep the area'),
              ),
              const SizedBox(height: AppSpacing.x2),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: sheetContext.orderColors.overdue,
                ),
                child: const Text('Delete for good'),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;
    final error = await cubit.remove(zone.id);
    if (!context.mounted) return;

    if (error == null) {
      AppHaptics.success();
      showAppSnack(context, '${zone.name} deleted.');
    } else {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
    }
  }

  Future<void> _toggle(
    BuildContext context,
    AdminDeliveryZone zone,
    bool value,
  ) async {
    final cubit = context.read<AdminZonesCubit>();
    final error = await cubit.setActive(zone.id, value);
    if (!context.mounted || error == null) return;
    AppHaptics.failure();
    showAppSnack(context, error, isError: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery areas')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('New area'),
      ),
      body: BlocBuilder<AdminZonesCubit, AdminZonesState>(
        builder: (context, state) {
          final cubit = context.read<AdminZonesCubit>();

          if (state.status == AdminZonesStatus.loading) {
            return const MessageListSkeleton(rows: 3);
          }
          if (state.status == AdminZonesStatus.failure &&
              state.failure != null) {
            return ApiErrorView(failure: state.failure!, onRetry: cubit.load);
          }

          return RefreshIndicator(
            onRefresh: () =>
                refreshWithSession(context, () => cubit.load(silent: true)),
            child: ListView(
              padding: pagePadding(
                context,
                top: AppSpacing.x4,
                bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                if (state.isEmpty)
                  const _NoZones()
                else ...[
                  // Only the live ones are drawn: the map is what a
                  // customer would see, and a paused area is not part of
                  // that picture.
                  DeliveryZonesMap(
                    zones: [
                      for (final zone in state.zones)
                        if (zone.isActive) zone.zone,
                    ],
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  if (state.noneActive) ...[
                    const _AllPausedNotice(),
                    const SizedBox(height: AppSpacing.x4),
                  ],
                  for (final zone in state.zones) ...[
                    _ZoneRow(
                      zone: zone,
                      busy: state.busyId == zone.id,
                      onEdit: () => _edit(context, zone: zone),
                      onDelete: () => _delete(context, zone),
                      onToggle: (value) => _toggle(context, zone, value),
                    ),
                    const SizedBox(height: AppSpacing.x3),
                  ],
                ],
              ].revealStaggered(),
            ),
          );
        },
      ),
    );
  }
}

class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    required this.zone,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final AdminDeliveryZone zone;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final colour = zone.zone.colorOr(Theme.of(context).colorScheme.primary);

    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 38,
            decoration: BoxDecoration(
              color: colour.withValues(alpha: zone.isActive ? 1 : 0.3),
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        zone.name,
                        style: context.texts.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!zone.isActive) ...[
                      const SizedBox(width: AppSpacing.x2),
                      Text(
                        'Paused',
                        style: context.texts.bodySmall?.copyWith(
                          color: context.surfaces.inkSoft,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  'Min ${OrderQuote.formatPence(zone.zone.minOrderPence)} · '
                  'Fee ${OrderQuote.formatPence(zone.zone.deliveryFeePence)} · '
                  'Priority ${zone.zone.priority}',
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: AppIconSize.xl,
              height: AppIconSize.xl,
              child: Center(
                child: SizedBox(
                  width: AppIconSize.md,
                  height: AppIconSize.md,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            Switch(value: zone.isActive, onChanged: onToggle),
            PopupMenuButton<_ZoneAction>(
              tooltip: 'More',
              icon: Icon(Icons.more_vert, color: context.surfaces.inkSoft),
              onSelected: (action) => switch (action) {
                _ZoneAction.edit => onEdit(),
                _ZoneAction.delete => onDelete(),
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _ZoneAction.edit,
                  child: Text('Edit area'),
                ),
                PopupMenuItem(
                  value: _ZoneAction.delete,
                  child: Text(
                    'Delete area',
                    style: TextStyle(color: context.orderColors.overdue),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

enum _ZoneAction { edit, delete }

/// Said plainly, because the consequence is not guessable from an empty list.
class _NoZones extends StatelessWidget {
  const _NoZones();

  @override
  Widget build(BuildContext context) {
    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Text(
        'No delivery areas yet. Until one exists, delivery is priced by the '
        'flat rate in the server settings and postcodes are not checked at '
        'all.',
        style: context.texts.bodyMedium?.copyWith(
          color: context.surfaces.inkMuted,
        ),
      ),
    );
  }
}

class _AllPausedNotice extends StatelessWidget {
  const _AllPausedNotice();

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: colours.overdueContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: AppIconSize.md,
            color: colours.overdue,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              // Not the same as "no deliveries": the backend falls back to flat
              // pricing, so orders keep coming through at a price nobody on
              // this screen set.
              'Every area is paused, so delivery has fallen back to the flat '
              'rate in the server settings.',
              style: context.texts.bodySmall?.copyWith(color: colours.overdue),
            ),
          ),
        ],
      ),
    );
  }
}
