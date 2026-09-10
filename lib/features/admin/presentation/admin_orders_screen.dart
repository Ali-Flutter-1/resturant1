import 'dart:async';

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
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/status_pill.dart';
import '../domain/admin_order.dart';
import '../domain/admin_order_repository.dart';
import 'admin_orders_cubit.dart';
import '../../auth/session_refresh.dart';
import '../../../shared/widgets/page_body.dart';

/// The kitchen queue.
///
/// Live orders from `/admin/orders`, and the documented status machine on each
/// row: placed → preparing → ready → out_for_delivery (delivery only) →
/// completed, with reject and cancel available early.
///
/// One tap advances an order, because that is the gesture a kitchen makes twenty
/// times a service. The other moves — rejecting, cancelling — sit behind the
/// overflow, where a stray tap cannot reach them.
class AdminOrdersScreen extends StatelessWidget {
  const AdminOrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          AdminOrdersCubit(repository: context.read<AdminOrderRepository>())
            ..load(),
      child: const _QueueView(),
    );
  }
}

class _QueueView extends StatefulWidget {
  const _QueueView();

  @override
  State<_QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<_QueueView> {
  final _search = TextEditingController();
  Timer? _poll;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // The queue changes because customers order, not because staff refresh. The
    // guide notes there is no realtime subscription yet, so this polls — quietly,
    // so a ticket never disappears under someone's hand mid-read.
    _startPolling();

    // Stopped while the app is backgrounded. A kitchen tablet left on the queue
    // overnight would otherwise make three requests a minute until morning.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!mounted) return;
        context.read<AdminOrdersCubit>().load(silent: true);
        _startPolling();
      },
      onPause: () {
        _poll?.cancel();
        _poll = null;
      },
    );
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) context.read<AdminOrdersCubit>().load(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lifecycle?.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _advance(AdminOrder order) async {
    final next = order.advanceTo;
    if (next == null) return;

    AppHaptics.commit();
    final error = await context.read<AdminOrdersCubit>().changeStatus(
      order.id,
      next,
    );
    if (!mounted) return;

    if (error != null) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
    } else {
      showAppSnack(
        context,
        '${order.orderNumber} is now ${next.label.toLowerCase()}.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildAdminAppBar(context),
      body: BlocBuilder<AdminOrdersCubit, AdminOrdersState>(
        builder: (context, state) {
          final cubit = context.read<AdminOrdersCubit>();
          final loading = state.status == QueueStatus.loading;

          // The controls stay put through every state, so a filter does not
          // vanish while the request it started is in flight.
          return Column(
            children: [
              _StatsStrip(stats: state.stats, loading: loading).reveal(),
              const SizedBox(height: AppSpacing.x3),
              _SearchField(
                controller: _search,
                onChanged: cubit.search,
              ).revealItem(1),
              const SizedBox(height: AppSpacing.x3),
              _QueueFilter(
                selected: state.filter,
                openOnly: state.openOnly,
                onStatus: cubit.filterBy,
                onOpenOnly: cubit.showOpenOnly,
              ).revealItem(2),
              const SizedBox(height: AppSpacing.x3),
              if (loading)
                const Expanded(child: OrderListSkeleton())
              else if (state.status == QueueStatus.failure &&
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
                    child: state.visible.isEmpty
                        ? _EmptyQueue(
                            searched: state.isSearchEmpty,
                            openOnly: state.openOnly,
                            filtered: state.filter != null,
                          )
                        : ListView.separated(
                            padding: pagePadding(
                              context,
                              top: 0,
                              bottom:
                                  AppSpacing.x12 +
                                  MediaQuery.paddingOf(context).bottom,
                            ),
                            itemCount: state.visible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: AppSpacing.x3),
                            itemBuilder: (context, index) {
                              final order = state.visible[index];
                              return _OrderTicket(
                                key: ValueKey(order.id),
                                order: order,
                                busy: state.busyIds.contains(order.id),
                                onAdvance: () => _advance(order),
                                onOpen: () => _showOrder(context, order),
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

/// Today's counters.
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats, required this.loading});

  final OrderStats stats;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        children: [
          _StatTile(
            label: 'Open',
            value: loading ? '—' : '${stats.openOrders}',
            emphasise: true,
          ),
          const SizedBox(width: AppSpacing.x3),
          _StatTile(label: 'New', value: loading ? '—' : '${stats.placed}'),
          const SizedBox(width: AppSpacing.x3),
          _StatTile(
            label: 'Cooking',
            value: loading ? '—' : '${stats.preparing}',
          ),
          const SizedBox(width: AppSpacing.x3),
          _StatTile(label: 'Ready', value: loading ? '—' : '${stats.ready}'),
          const SizedBox(width: AppSpacing.x3),
          _StatTile(
            label: 'Out',
            value: loading ? '—' : '${stats.outForDelivery}',
          ),
          const SizedBox(width: AppSpacing.x3),
          _StatTile(
            label: 'Today',
            value: loading ? '—' : stats.formattedRevenue,
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
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
      width: 92,
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

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: SizedBox(
        height: 44,
        child: TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          decoration: const InputDecoration(
            hintText: 'Search order number, name or phone...',
            prefixIcon: Icon(Icons.search, size: AppIconSize.lg),
          ),
        ),
      ),
    );
  }
}

/// The kitchen queue, or one status, or everything.
class _QueueFilter extends StatelessWidget {
  const _QueueFilter({
    required this.selected,
    required this.openOnly,
    required this.onStatus,
    required this.onOpenOnly,
  });

  final OrderStatus? selected;
  final bool openOnly;
  final ValueChanged<OrderStatus?> onStatus;
  final ValueChanged<bool> onOpenOnly;

  /// Only the states an order can actually be in — `unknown` is a decoding
  /// fallback, not something to filter by.
  static const _filterable = [
    OrderStatus.placed,
    OrderStatus.preparing,
    OrderStatus.ready,
    OrderStatus.outForDelivery,
    OrderStatus.completed,
    OrderStatus.cancelled,
    OrderStatus.rejected,
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
            label: 'Kitchen queue',
            selected: openOnly && selected == null,
            onSelected: () => onOpenOnly(true),
          ),
          const SizedBox(width: AppSpacing.x2),
          SelectableChip(
            label: 'All orders',
            selected: !openOnly && selected == null,
            onSelected: () => onOpenOnly(false),
          ),
          for (final status in _filterable) ...[
            const SizedBox(width: AppSpacing.x2),
            SelectableChip(
              label: status.label,
              selected: selected == status,
              onSelected: () => onStatus(selected == status ? null : status),
            ),
          ],
        ],
      ),
    );
  }
}

/// One order in the queue.
class _OrderTicket extends StatelessWidget {
  const _OrderTicket({
    super.key,
    required this.order,
    required this.busy,
    required this.onAdvance,
    required this.onOpen,
  });

  final AdminOrder order;
  final bool busy;
  final VoidCallback onAdvance;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final next = order.advanceTo;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: busy ? null : onOpen,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppSurface.row(
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order.orderNumber,
                      style: context.texts.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  StatusPill(status: order.status),
                ],
              ),
              const SizedBox(height: AppSpacing.x1),
              Row(
                children: [
                  Icon(
                    order.fulfilment == FulfilmentType.delivery
                        ? Icons.delivery_dining_outlined
                        : Icons.storefront_outlined,
                    size: AppIconSize.sm,
                    color: context.surfaces.inkSoft,
                  ),
                  const SizedBox(width: AppSpacing.x1 + 2),
                  Expanded(
                    child: Text(
                      [
                        order.fulfilment.label,
                        '${order.itemCount} '
                            '${order.itemCount == 1 ? 'item' : 'items'}',
                        if (order.placedAt != null) _when(order.placedAt!),
                        // A scheduled order is the one thing a kitchen must not
                        // start early, so it says so on the row.
                        if (!order.isAsap && order.requestedFor != null)
                          'for ${_time(order.requestedFor!)}',
                      ].join(' · '),
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkSoft,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Text(
                    order.formattedTotal,
                    style: AppTypography.money(
                      scheme.onSurface,
                      size: MoneySize.small,
                    ),
                  ),
                ],
              ),
              if (order.paymentStatus == PaymentStatus.pending &&
                  order.status.isFinal) ...[
                const SizedBox(height: AppSpacing.x2),
                AppChip.outlined(label: 'Unpaid'),
              ],
              if (next != null || !order.status.isFinal) ...[
                const SizedBox(height: AppSpacing.x3),
                Row(
                  children: [
                    if (next != null)
                      Expanded(
                        child: FilledButton(
                          onPressed: busy ? null : onAdvance,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(40),
                          ),
                          // Named after the destination, not "Next": a kitchen
                          // reads the word, not the arrow.
                          child: Text(busy ? 'Saving…' : 'Mark ${_verb(next)}'),
                        ),
                      ),
                    if (next != null) const SizedBox(width: AppSpacing.x2),
                    // Rejecting and cancelling live behind the overflow. They
                    // should not be one stray tap from a row being scrolled past.
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton(
                        onPressed: busy ? null : onOpen,
                        icon: Icon(
                          Icons.more_horiz,
                          color: context.surfaces.inkSoft,
                        ),
                        tooltip: 'More for ${order.orderNumber}',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _verb(OrderStatus status) => switch (status) {
    OrderStatus.preparing => 'cooking',
    OrderStatus.ready => 'ready',
    OrderStatus.outForDelivery => 'out for delivery',
    OrderStatus.completed => 'completed',
    _ => status.label.toLowerCase(),
  };
}

/// The full ticket, with every legal move on it.
void _showOrder(BuildContext context, AdminOrder order) {
  final cubit = context.read<AdminOrdersCubit>();
  cubit.openDetail(order);
  showAppSheet<void>(
    context: context,
    title: order.orderNumber,
    subtitle: '${order.fulfilment.label} · ${order.formattedTotal}',
    child: BlocProvider.value(
      value: cubit,
      child: _OrderDetail(id: order.id),
    ),
    // Dropped when the sheet goes, so a stale ticket is not still held in state
    // the next time one is opened.
  ).whenComplete(cubit.closeDetail);
}

class _OrderDetail extends StatefulWidget {
  const _OrderDetail({required this.id});

  final String id;

  @override
  State<_OrderDetail> createState() => _OrderDetailState();
}

class _OrderDetailState extends State<_OrderDetail> {
  /// The last ticket this sheet actually rendered.
  ///
  /// Closing the sheet clears `detail` while the dismiss animation is still
  /// running, and the sheet would fall back to its spinner -- which, being a
  /// [Center], expands to whatever height it is offered. So the sheet grew as
  /// it slid away. Holding the last ticket means there is always something to
  /// draw, and the sheet keeps the size it had.
  AdminOrder? _last;

  @override
  void initState() {
    super.initState();
    final detail = context.read<AdminOrdersCubit>().state.detail;
    if (detail?.id == widget.id) _last = detail;
  }

  Future<void> _change(OrderStatus next) async {
    // Rejecting or cancelling asks for a reason, which the API stores as the
    // cancellation reason — the customer is told, so it should not be blank.
    String? note;
    if (next == OrderStatus.cancelled || next == OrderStatus.rejected) {
      note = await _askReason(context, next);
      if (note == null || !mounted) return;
    }

    final error = await context.read<AdminOrdersCubit>().changeStatus(
      widget.id,
      next,
      note: note,
    );
    if (!mounted) return;

    if (error != null) {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
      return;
    }
    AppHaptics.success();
    Navigator.of(context).pop();
    showAppSnack(context, 'Marked ${next.label.toLowerCase()}.');
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AdminOrdersCubit, AdminOrdersState>(
      listenWhen: (_, state) => state.detail?.id == widget.id,
      listener: (_, state) => _last = state.detail,
      builder: (context, state) {
        // Read from `detail`, never from the list. The 20-second poll replaces
        // `orders` wholesale, and an order the current filter no longer returns
        // used to disappear from under the reader mid-sentence.
        final order = state.detail?.id == widget.id ? state.detail : _last;
        if (order == null) {
          // Bounded on purpose: an unbounded `Center` takes the whole sheet.
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final busy = state.busyIds.contains(order.id);

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
                  StatusPill(status: order.status),
                  const SizedBox(width: AppSpacing.x2),
                  AppChip.outlined(label: order.paymentStatus.label),
                  const Spacer(),
                  if (order.placedAt != null)
                    Text(
                      _when(order.placedAt!),
                      style: context.texts.bodySmall?.copyWith(
                        color: context.surfaces.inkSoft,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.x4),

              if (order.contactName != null)
                _Line(icon: Icons.person_outline, value: order.contactName!),
              if (order.contactPhone != null)
                _Line(icon: Icons.phone_outlined, value: order.contactPhone!),
              if (order.address != null)
                _Line(icon: Icons.place_outlined, value: order.address!),
              if (order.deliveryNotes != null)
                _Line(icon: Icons.info_outline, value: order.deliveryNotes!),
              if (!order.isAsap && order.requestedFor != null)
                _Line(
                  icon: Icons.schedule,
                  value: 'Requested for ${_time(order.requestedFor!)}',
                ),
              if (order.customerNote != null)
                _Line(icon: Icons.note_outlined, value: order.customerNote!),
              if (order.cancellationReason != null)
                _Line(
                  icon: Icons.cancel_outlined,
                  value: order.cancellationReason!,
                ),

              const SizedBox(height: AppSpacing.x4),
              Text('Items', style: context.texts.titleMedium),
              const SizedBox(height: AppSpacing.x2),
              if (!order.hasLines)
                Text(
                  'Loading the items…',
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                )
              else
                for (final line in order.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 28,
                          child: Text(
                            '${line.quantity}×',
                            style: context.texts.titleMedium,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(line.title, style: context.texts.bodyLarge),
                              // What actually goes on the plate. Included and
                              // charged options are printed alike: whether the
                              // customer paid extra makes no difference to
                              // cooking it, and a missing hopper is a missing
                              // hopper.
                              for (final choice in line.selections)
                                Text(
                                  choice.label,
                                  style: context.texts.bodySmall?.copyWith(
                                    color: context.surfaces.inkMuted,
                                  ),
                                ),
                              // The kitchen's instruction. Emphasised, because
                              // this is the line that gets missed.
                              if (line.notes != null)
                                Text(
                                  line.notes!,
                                  style: context.texts.bodySmall?.copyWith(
                                    color: context.orderColors.preparing,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

              Divider(height: AppSpacing.x6, color: context.surfaces.line),
              Row(
                children: [
                  Expanded(
                    child: Text('Total', style: context.texts.titleLarge),
                  ),
                  Text(
                    order.formattedTotal,
                    style: AppTypography.money(
                      Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.x5),

              // Money is moving at the provider. Say so plainly and offer
              // nothing to tap: the accept or the cancel has already been
              // recorded, and a second tap here would be a second attempt at a
              // payment that is already in flight.
              if (order.status.isSettling ||
                  order.paymentStatus.isSettling) ...[
                _SettlingNotice(order: order),
              ] else if (order.nextStatuses.isEmpty)
                Text(
                  'This order is ${order.status.label.toLowerCase()} and cannot '
                  'change.',
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.surfaces.inkSoft,
                  ),
                )
              else ...[
                // What accepting will do to the customer's money, before the
                // tap rather than after. Capturing a hold is not reversible by
                // tapping again.
                if (order.paymentStatus == PaymentStatus.authorized) ...[
                  _CardHoldNotice(total: order.formattedTotal),
                  const SizedBox(height: AppSpacing.x3),
                ],
                Text('Move it on', style: context.texts.titleMedium),
                const SizedBox(height: AppSpacing.x2),
                // Only the legal moves for *this* order's fulfilment type. A
                // button the API would refuse with a 409 is not worth drawing.
                for (final next in order.nextStatuses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.x2),
                    child: _MoveButton(
                      status: next,
                      busy: busy,
                      onPressed: () => _change(next),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Shown while Worldpay is capturing or releasing a hold.
class _SettlingNotice extends StatelessWidget {
  const _SettlingNotice({required this.order});

  final AdminOrder order;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;
    final releasing =
        order.status == OrderStatus.cancellationPending ||
        order.paymentStatus == PaymentStatus.cancelPending;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: colours.preparingContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          SizedBox(
            width: AppIconSize.md,
            height: AppIconSize.md,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colours.preparing,
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Text(
              releasing
                  ? 'Releasing the hold on the customer\'s card. This order '
                        'will finish cancelling on its own.'
                  : 'Taking payment from the card. This order will move to '
                        'preparing on its own once it clears.',
              style: context.texts.bodySmall?.copyWith(
                color: colours.preparing,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What accepting an authorised card order actually does.
class _CardHoldNotice extends StatelessWidget {
  const _CardHoldNotice({required this.total});

  final String total;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.credit_card_outlined,
          size: AppIconSize.sm,
          color: context.surfaces.inkMuted,
        ),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Text(
            'The card is authorised for $total. Accepting takes the money; '
            'rejecting releases it. Never ask this customer to pay again.',
            style: context.texts.bodySmall?.copyWith(
              color: context.surfaces.inkMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class _MoveButton extends StatelessWidget {
  const _MoveButton({
    required this.status,
    required this.busy,
    required this.onPressed,
  });

  final OrderStatus status;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final destructive =
        status == OrderStatus.cancelled || status == OrderStatus.rejected;

    return SizedBox(
      width: double.infinity,
      child: destructive
          ? OutlinedButton(
              onPressed: busy ? null : onPressed,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                foregroundColor: context.orderColors.overdue,
                side: BorderSide(
                  color: context.orderColors.overdue.withValues(alpha: 0.5),
                ),
              ),
              child: Text(status.label),
            )
          : FilledButton(
              onPressed: busy ? null : onPressed,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              child: Text(status.label),
            ),
    );
  }
}

/// Asks why, before cancelling or rejecting.
Future<String?> _askReason(BuildContext context, OrderStatus status) {
  final controller = TextEditingController();
  return showAppSheet<String>(
    context: context,
    title: status == OrderStatus.rejected
        ? 'Reject this order?'
        : 'Cancel this order?',
    subtitle: 'The customer is told, so a reason helps.',
    child: Builder(
      builder: (sheetContext) => Padding(
        padding: pagePadding(
          context,
          top: 0,
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + AppSpacing.x4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              maxLines: 2,
              maxLength: 500,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Kitchen closed early, out of an ingredient…',
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            // The API refuses a cancellation or rejection with no note, so the
            // button waits for one rather than sending a request that comes
            // back as a validation error. The customer is shown this text, so
            // a blank would leave them with an order gone and no reason why.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: sheetContext.orderColors.overdue,
                  foregroundColor: Colors.white,
                ),
                onPressed: value.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(
                        sheetContext,
                      ).pop(controller.text.trim()),
                child: Text(
                  status == OrderStatus.rejected
                      ? 'Reject order'
                      : 'Cancel order',
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Leave it as it is'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1 + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppIconSize.lg, color: context.surfaces.inkSoft),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: SelectableText(value, style: context.texts.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({
    required this.searched,
    required this.openOnly,
    required this.filtered,
  });

  final bool searched;
  final bool openOnly;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = searched
        ? (
            Icons.search_off,
            'No matches',
            'Nothing loaded matches that. Try fewer words.',
          )
        : filtered
        ? (
            Icons.filter_alt_off_outlined,
            'Nothing in this state',
            'Try another status, or the whole queue.',
          )
        : openOnly
        ? (
            Icons.done_all,
            'Nothing waiting',
            'Every order is done. New ones appear here the moment they are '
                'placed.',
          )
        : (
            Icons.receipt_long_outlined,
            'No orders yet',
            'Orders appear here as soon as customers place them.',
          );

    return ListView(
      // Scrollable so pull-to-refresh works on an empty queue, which is exactly
      // when a kitchen will try it.
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.14),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.x8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: AppIconSize.hero,
                  color: context.surfaces.inkSoft,
                ),
                const SizedBox(height: AppSpacing.x4),
                Text(
                  title,
                  style: context.texts.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  body,
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

String _when(DateTime when) {
  final now = DateTime.now();
  final minutes = now.difference(when).inMinutes;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  final day = DateTime(when.year, when.month, when.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return _time(when);
  return '${when.day}/${when.month} ${_time(when)}';
}

String _time(DateTime when) =>
    '${when.hour.toString().padLeft(2, '0')}:'
    '${when.minute.toString().padLeft(2, '0')}';
