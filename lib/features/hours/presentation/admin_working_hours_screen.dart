import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/session_refresh.dart';
import '../domain/working_hours.dart';
import '../domain/working_hours_repository.dart';
import 'working_hours_cubit.dart';
import '../../../shared/widgets/page_body.dart';

/// Setting the week. Admin only.
class AdminWorkingHoursScreen extends StatelessWidget {
  const AdminWorkingHoursScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => WorkingHoursCubit(
        repository: context.read<WorkingHoursRepository>(),
        admin: true,
      )..load(),
      child: const _AdminHoursView(),
    );
  }
}

class _AdminHoursView extends StatelessWidget {
  const _AdminHoursView();

  Future<void> _save(BuildContext context) async {
    AppHaptics.commit();
    final error = await context.read<WorkingHoursCubit>().save();
    if (!context.mounted) return;

    if (error != null) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
      return;
    }
    AppHaptics.success();
    showAppSnack(context, 'Opening hours saved.');
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WorkingHoursCubit, WorkingHoursState>(
      builder: (context, state) {
        final cubit = context.read<WorkingHoursCubit>();

        return Scaffold(
          // Nothing in the actions: discarding is half of the same decision
          // as saving, and the two belonged together rather than at opposite
          // ends of the screen.
          appBar: AppBar(title: const Text('Opening hours')),
          body: switch (state.status) {
            HoursStatus.loading => const MessageListSkeleton(rows: 7),
            HoursStatus.failure when state.failure != null => ApiErrorView(
              failure: state.failure!,
              onRetry: () => cubit.load(),
            ),
            _ => RefreshIndicator(
              onRefresh: () =>
                  refreshWithSession(context, () => cubit.load(silent: true)),
              child: ListView(
                padding: pagePadding(
                  context,
                  top: AppSpacing.x4,
                  bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  const _Notice(),
                  const SizedBox(height: AppSpacing.x4),
                  for (final day in state.draft) ...[
                    _DayRow(
                      day: day,
                      isConfigured: state.saved.isConfigured(day.weekday),
                      busy: state.saving,
                    ),
                    const SizedBox(height: AppSpacing.x3),
                  ],
                ].revealStaggered(),
              ),
            ),
          },
          bottomNavigationBar: state.isDirty
              ? _SaveBar(
                  state: state,
                  onSave: () => _save(context),
                  onDiscard: cubit.discard,
                )
              : null,
        );
      },
    );
  }
}

/// What these hours actually do — which is less than it looks.
class _Notice extends StatelessWidget {
  const _Notice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: context.surfaces.ground,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.surfaces.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: AppIconSize.md,
            color: context.surfaces.inkSoft,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            // Said plainly, because an admin who assumes otherwise will be
            // surprised by an order at 3am. The backend does not yet reject
            // orders or bookings outside these hours.
            child: Text(
              'These hours are shown to customers. They do not stop orders or '
              'bookings outside them yet.',
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.day,
    required this.isConfigured,
    required this.busy,
  });

  final DayHours day;
  final bool isConfigured;
  final bool busy;

  Future<void> _pick(BuildContext context, {required bool opening}) async {
    final current = opening ? day.opensAt : day.closesAt;
    final parts = current?.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: parts != null && parts.length >= 2
          ? TimeOfDay(
              hour: int.tryParse(parts[0]) ?? 10,
              minute: int.tryParse(parts[1]) ?? 0,
            )
          : TimeOfDay(hour: opening ? 10 : 22, minute: 0),
    );
    if (picked == null || !context.mounted) return;

    // Formatted by hand rather than through `TimeOfDay.format`, which is
    // localised and would send "10:00 AM" to a field expecting `10:00:00`.
    final value =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    final cubit = context.read<WorkingHoursCubit>();
    opening
        ? cubit.setOpensAt(day.weekday, value)
        : cubit.setClosesAt(day.weekday, value);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<WorkingHoursCubit>();
    final backwards =
        !day.isClosed &&
        day.isComplete &&
        day.closesAt!.compareTo(day.opensAt!) <= 0;

    return AppSurface.row(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        day.name,
                        style: context.texts.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!isConfigured) ...[
                      const SizedBox(width: AppSpacing.x2),
                      // Not the same as closed, and the difference matters: a
                      // day nobody has filled in should not tell customers the
                      // restaurant is shut.
                      Text(
                        'not set',
                        style: context.texts.labelSmall?.copyWith(
                          color: context.surfaces.inkSoft,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                'Closed',
                style: context.texts.bodySmall?.copyWith(
                  color: context.surfaces.inkSoft,
                ),
              ),
              Switch(
                value: day.isClosed,
                onChanged: busy
                    ? null
                    : (closed) {
                        AppHaptics.selection();
                        cubit.setClosed(day.weekday, closed);
                      },
              ),
            ],
          ),
          if (!day.isClosed) ...[
            const SizedBox(height: AppSpacing.x2),
            Row(
              children: [
                Expanded(
                  child: _TimeButton(
                    label: 'Opens',
                    value: day.opensAt,
                    onPressed: busy
                        ? null
                        : () => _pick(context, opening: true),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: _TimeButton(
                    label: 'Closes',
                    value: day.closesAt,
                    onPressed: busy
                        ? null
                        : () => _pick(context, opening: false),
                  ),
                ),
              ],
            ),
            if (backwards) ...[
              const SizedBox(height: AppSpacing.x2),
              Text(
                'Closing time must be after opening time.',
                style: context.texts.bodySmall?.copyWith(
                  color: context.orderColors.overdue,
                ),
              ),
            ],
          ],
          const SizedBox(height: AppSpacing.x2),
          // Wrapped rather than a Row: "Copy to every day" beside "Clear" runs
          // past a 320pt phone, and the two actions read fine stacked.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: busy ? null : () => cubit.applyToAll(day.weekday),
                child: const Text('Copy to every day'),
              ),
              if (isConfigured)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final error = await cubit.clear(day.weekday);
                          if (context.mounted && error != null) {
                            showAppSnack(context, error, isError: true);
                          }
                        },
                  style: TextButton.styleFrom(
                    foregroundColor: context.surfaces.inkSoft,
                  ),
                  child: const Text('Clear'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.label, required this.value, this.onPressed});

  final String label;
  final String? value;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final missing = value == null;

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(
          color: missing ? context.orderColors.overdue : context.surfaces.line,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: context.texts.labelSmall?.copyWith(
              color: context.surfaces.inkSoft,
            ),
          ),
          Text(
            value ?? 'Set a time',
            style: context.texts.titleSmall?.copyWith(
              color: missing ? context.orderColors.overdue : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.state,
    required this.onSave,
    required this.onDiscard,
  });

  final WorkingHoursState state;
  final VoidCallback onSave;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final blocked = state.incomplete.isNotEmpty || state.backwards.isNotEmpty;

    return Container(
      padding: pagePadding(
        context,
        top: AppSpacing.x3,
        bottom: AppSpacing.x3 + MediaQuery.paddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: context.surfaces.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blocked) ...[
            Text(
              // Named rather than left to a failed request: the API answers 422
              // for an open day with no times, and the fix is on this screen.
              state.incomplete.isNotEmpty
                  ? '${state.incomplete.map((d) => d.shortName).join(', ')} '
                        'need both times, or mark them closed.'
                  : '${state.backwards.map((d) => d.shortName).join(', ')} '
                        'close before they open.',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall?.copyWith(
                color: context.orderColors.overdue,
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
          ],
          Row(
            children: [
              // The quieter of the two, and on the left, so the thumb lands on
              // "save" rather than on the one that throws the week away.
              TextButton(
                onPressed: state.saving ? null : onDiscard,
                style: TextButton.styleFrom(
                  // A finite width: `Size.fromHeight` is `Size(infinity, 50)`,
                  // which a Row cannot lay out.
                  minimumSize: const Size(96, 50),
                  foregroundColor: context.surfaces.inkMuted,
                ),
                child: const Text('Discard'),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: FilledButton(
                  onPressed: state.canSave ? onSave : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: state.saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save the week'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
