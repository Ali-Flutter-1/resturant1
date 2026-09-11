import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/motion.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_chip.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/session_refresh.dart';
import '../../booking/domain/reservation.dart';
import '../../booking/domain/reservation_repository.dart';
import '../../booking/presentation/admin_bookings_cubit.dart';
import '../../../shared/widgets/admin_nav.dart';
import '../../../shared/widgets/page_body.dart';

/// The booking sheet, for staff and admin.
///
/// The screen's job is the pending queue: an unanswered request is holding a
/// table with a clock running on it, so that is the default filter and the first
/// counter. Everything else — today's confirmed, who is seated — is a filter
/// away rather than a separate screen.
class AdminReservationsScreen extends StatelessWidget {
  const AdminReservationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          AdminBookingsCubit(repository: context.read<ReservationRepository>())
            ..load(),
      child: const _AdminReservationsView(),
    );
  }
}

class _AdminReservationsView extends StatelessWidget {
  const _AdminReservationsView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAdminAppBar(context, title: 'Bookings'),
      body: BlocBuilder<AdminBookingsCubit, AdminBookingsState>(
        builder: (context, state) {
          final cubit = context.read<AdminBookingsCubit>();
          final loading = state.status == AdminBookingsStatus.loading;

          return Column(
            children: [
              _StatsStrip(stats: state.stats, loading: loading).reveal(),
              const SizedBox(height: AppSpacing.x3),
              _Filters(state: state, cubit: cubit).revealItem(1),
              const SizedBox(height: AppSpacing.x3),
              if (loading)
                const Expanded(child: MessageListSkeleton())
              else if (state.status == AdminBookingsStatus.failure &&
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
                    child: state.bookings.isEmpty
                        ? _Empty(filter: state.filter)
                        : ListView.separated(
                            padding: pagePadding(
                              context,
                              top: 0,
                              bottom:
                                  AppSpacing.x12 +
                                  MediaQuery.paddingOf(context).bottom,
                            ),
                            // One extra row for the footer where there is
                            // another page behind this one.
                            itemCount:
                                state.bookings.length + (state.hasMore ? 1 : 0),
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.x3),
                            itemBuilder: (context, index) {
                              if (index >= state.bookings.length) {
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
                                          onPressed: cubit.loadMore,
                                          child: const Text(
                                            'Load more bookings',
                                          ),
                                        ),
                                );
                              }
                              final booking = state.bookings[index];
                              return _BookingRow(
                                key: ValueKey(booking.id),
                                booking: booking,
                                busy: state.busyIds.contains(booking.id),
                                onOpen: () => _showBooking(context, booking.id),
                              ).revealItem(index, duration: Motion.fast);
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

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats, required this.loading});

  final ReservationStats stats;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    String value(int n) => loading ? '—' : '$n';

    return SizedBox(
      height: 74,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        children: [
          // First and emphasised: it is the only figure with a deadline on it.
          _Tile(
            label: 'To approve',
            value: value(stats.pendingApproval),
            emphasise: true,
          ),
          const SizedBox(width: AppSpacing.x3),
          _Tile(label: 'Today', value: value(stats.todayConfirmed)),
          const SizedBox(width: AppSpacing.x3),
          _Tile(label: 'Covers', value: value(stats.todayGuests)),
          const SizedBox(width: AppSpacing.x3),
          _Tile(label: 'Seated', value: value(stats.seatedNow)),
          const SizedBox(width: AppSpacing.x3),
          _Tile(label: 'Upcoming', value: value(stats.upcoming)),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 100,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: emphasise ? scheme.primary : context.surfaces.ground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: emphasise ? null : Border.all(color: context.surfaces.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: AppTypography.caption(
              emphasise ? scheme.onPrimary : context.surfaces.inkSoft,
            ),
          ),
          const SizedBox(height: 2),
          Flexible(
            child: FittedBox(
              child: Text(
                value,
                style: context.texts.headlineMedium?.copyWith(
                  color: emphasise ? scheme.onPrimary : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.state, required this.cubit});

  final AdminBookingsState state;
  final AdminBookingsCubit cubit;

  static const _statuses = [
    ReservationStatus.pending,
    ReservationStatus.confirmed,
    ReservationStatus.seated,
    ReservationStatus.completed,
    ReservationStatus.cancelled,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        children: [
          SelectableChip(
            label: 'All',
            selected: state.filter == null,
            onSelected: () => cubit.setFilter(null),
          ),
          for (final status in _statuses) ...[
            const SizedBox(width: AppSpacing.x2),
            SelectableChip(
              label: status == ReservationStatus.pending
                  ? 'To approve'
                  : status.label,
              selected: state.filter == status,
              onSelected: () => cubit.setFilter(status),
            ),
          ],
          const SizedBox(width: AppSpacing.x4),
          // A separate axis, so it is set apart: the date narrows whichever
          // status is chosen rather than replacing it.
          SelectableChip(
            label: state.date == null ? 'Any day' : _dayLabel(state.date!),
            selected: state.date != null,
            onSelected: () async {
              if (state.date != null) return cubit.setDate(null);
              final picked = await showDatePicker(
                context: context,
                initialDate: cubit.today,
                firstDate: cubit.today.subtract(const Duration(days: 365)),
                lastDate: cubit.today.add(const Duration(days: 365)),
              );
              if (picked != null) await cubit.setDate(picked);
            },
          ),
        ],
      ),
    );
  }
}

class _BookingRow extends StatelessWidget {
  const _BookingRow({
    super.key,
    required this.booking,
    required this.busy,
    required this.onOpen,
  });

  final ReservationSummary booking;
  final bool busy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: busy ? null : onOpen,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppSurface.row(
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: Row(
            children: [
              // The sitting time, large: a service sheet is read down the times.
              SizedBox(
                width: 54,
                child: Text(booking.timeLabel, style: context.texts.titleLarge),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(booking.tableName, style: context.texts.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${booking.guestLabel} · ${_dayLabel(booking.serviceDate)}'
                      ' · ${booking.reference}',
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkSoft,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              _StatusChip(status: booking.status),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ReservationStatus status;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;
    final (foreground, background) = switch (status) {
      ReservationStatus.pending => (
        colours.preparing,
        colours.preparingContainer,
      ),
      ReservationStatus.confirmed ||
      ReservationStatus.seated => (colours.ready, colours.readyContainer),
      ReservationStatus.completed => (colours.served, colours.servedContainer),
      ReservationStatus.rejected ||
      ReservationStatus.cancelled ||
      ReservationStatus.noShow ||
      ReservationStatus.expired => (colours.overdue, colours.overdueContainer),
    };

    return AppChip.status(
      label: status == ReservationStatus.pending ? 'To approve' : status.label,
      foreground: foreground,
      background: background,
    );
  }
}

/// One booking, and the moves its status allows.
void _showBooking(BuildContext context, String id) {
  final cubit = context.read<AdminBookingsCubit>();
  cubit.open(id);
  showAppSheet<void>(
    context: context,
    title: 'Booking',
    child: BlocProvider.value(value: cubit, child: const _BookingDetail()),
  ).whenComplete(cubit.closeDetail);
}

class _BookingDetail extends StatefulWidget {
  const _BookingDetail();

  @override
  State<_BookingDetail> createState() => _BookingDetailState();
}

class _BookingDetailState extends State<_BookingDetail> {
  /// The last booking this sheet actually rendered.
  ///
  /// Closing clears `detail` while the dismiss animation is still running, and
  /// the sheet fell back to its spinner -- which, being a [Center], expands to
  /// whatever height it is offered, so the sheet grew as it slid away.
  ReservationDetail? _last;

  @override
  void initState() {
    super.initState();
    _last = context.read<AdminBookingsCubit>().state.detail;
  }

  /// Runs a move, asking for a reason first where the API requires one.
  Future<void> _move(
    BuildContext context,
    ReservationDetail booking,
    ReservationStatus status,
  ) async {
    String? note;

    if (ReservationTransitions.needsReason(status)) {
      note = await _askReason(context, status);
      // Cancelled the dialog. Not the same as an empty reason, which the API
      // refuses with a 422.
      if (note == null || !context.mounted) return;
    }

    AppHaptics.commit();
    final error = await context.read<AdminBookingsCubit>().updateStatus(
      booking.id,
      status: status,
      note: note,
    );
    if (!context.mounted) return;

    if (error != null) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
      return;
    }
    AppHaptics.success();
    showAppSnack(
      context,
      '${booking.reference} is now ${status.label.toLowerCase()}.',
    );
  }

  /// The mandatory note for reject, cancel and no-show.
  ///
  /// Enforced here as well as by the API — the customer is shown this text as
  /// the restaurant's reason, so an empty one is a refusal with no explanation.
  static Future<String?> _askReason(
    BuildContext context,
    ReservationStatus status,
  ) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '${ReservationTransitions.actionLabel(status)} this booking',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The customer is shown this, so say why.'),
            const SizedBox(height: AppSpacing.x3),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'We are fully booked for that sitting.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back'),
          ),
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => TextButton(
              // Disabled until there is something to send: the API answers 422
              // for a blank or whitespace-only note.
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(value.text.trim()),
              style: TextButton.styleFrom(
                foregroundColor: context.orderColors.overdue,
              ),
              child: Text(ReservationTransitions.actionLabel(status)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AdminBookingsCubit, AdminBookingsState>(
      listenWhen: (_, state) => state.detail != null,
      listener: (_, state) => _last = state.detail,
      builder: (context, state) {
        final booking = state.detail ?? _last;
        if (booking == null) {
          // Bounded on purpose: an unbounded `Center` takes the whole sheet.
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final busy = state.busyIds.contains(booking.id);
        final moves = ReservationTransitions.nextFor(booking.status);

        return SingleChildScrollView(
          padding: pagePadding(
            context,
            top: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.x4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusChip(status: booking.status),
                  const SizedBox(width: AppSpacing.x2),
                  Text(
                    booking.reference,
                    style: context.texts.labelSmall?.copyWith(
                      color: context.surfaces.inkSoft,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),

              _Detail(label: 'Table', value: booking.tableName),
              _Detail(
                label: 'Sitting',
                value:
                    '${_dayLabel(booking.serviceDate)} at ${booking.timeLabel}',
              ),
              _Detail(label: 'Party', value: booking.guestLabel),
              _Detail(label: 'Name', value: booking.contactName),
              _Detail(label: 'Phone', value: booking.contactPhone),
              if (booking.specialRequests != null)
                _Detail(label: 'Requests', value: booking.specialRequests!),
              if (booking.cancellationReason != null)
                _Detail(label: 'Reason', value: booking.cancellationReason!),

              const SizedBox(height: AppSpacing.x5),
              if (moves.isEmpty)
                Text(
                  'This booking is finished. Nothing further can be changed.',
                  style: context.texts.bodySmall?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                )
              else ...[
                Text('What next', style: context.texts.titleMedium),
                const SizedBox(height: AppSpacing.x3),
                for (final move in moves) ...[
                  _MoveButton(
                    status: move,
                    // The first legal move is the ordinary one — approve, seat,
                    // complete — so it gets the filled button and the rest read
                    // as exceptions.
                    prominent: move == moves.first,
                    busy: busy,
                    onPressed: () => _move(context, booking, move),
                  ),
                  const SizedBox(height: AppSpacing.x2),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MoveButton extends StatelessWidget {
  const _MoveButton({
    required this.status,
    required this.prominent,
    required this.busy,
    required this.onPressed,
  });

  final ReservationStatus status;
  final bool prominent;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = ReservationTransitions.actionLabel(status);
    final destructive = ReservationTransitions.needsReason(status);

    if (prominent) {
      return FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label),
      );
    }

    return OutlinedButton(
      onPressed: busy ? null : onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: destructive ? context.orderColors.overdue : null,
      ),
      child: Text(label),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: context.texts.bodySmall?.copyWith(
                color: context.surfaces.inkSoft,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(child: Text(value, style: context.texts.bodyMedium)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({this.filter});

  final ReservationStatus? filter;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  filter == ReservationStatus.pending
                      ? Icons.done_all
                      : Icons.event_available_outlined,
                  size: AppIconSize.hero,
                  color: context.surfaces.inkSoft,
                ),
                const SizedBox(height: AppSpacing.x4),
                Text(
                  filter == ReservationStatus.pending
                      ? 'Nothing waiting'
                      : 'No bookings here',
                  style: context.texts.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  filter == ReservationStatus.pending
                      ? 'Every request has been answered.'
                      : 'Try another status or day.',
                  style: context.texts.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _dayLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final difference = DateTime(
    date.year,
    date.month,
    date.day,
  ).difference(today).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Tomorrow';
  if (difference == -1) return 'Yesterday';

  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${date.day} ${months[date.month - 1]}';
}
