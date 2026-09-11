import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_buttons.dart';
import '../../../shared/widgets/app_chip.dart';
import '../../../shared/widgets/app_sheet.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../domain/customer_order.dart';
import '../domain/order_quote.dart';
import 'order_status_palette.dart';
import '../../../shared/widgets/cart_icon_button.dart';
import '../../cart/cart_cubit.dart';
import 'order_tracker.dart';
import 'orders_cubit.dart';
import '../../auth/session_refresh.dart';
import '../../../shared/widgets/page_body.dart';

/// The customer's orders: what is happening now, and what happened before.
///
/// The screen is in two halves because the two questions are different. "Where
/// is my food?" is urgent and wants a tracker; "what did I order last time?" is
/// a list. Putting a live order into a uniform history list would bury the only
/// row the user opened the app to see.
class MyOrdersScreen extends StatelessWidget {
  const MyOrdersScreen({super.key, this.onBrowseMenu, this.onOpenCheckout});

  /// Offered from the empty state — a first-time customer has nothing to read
  /// here, so the screen's job is to send them somewhere useful.
  final VoidCallback? onBrowseMenu;

  /// Opens checkout. A basket filled on the Menu tab was otherwise unreachable
  /// from here: the customer had to go back to a dish to find the cart again.
  final VoidCallback? onOpenCheckout;

  @override
  Widget build(BuildContext context) {
    // The app-level cubit, not a new one. This tab is built once and then kept
    // alive by the shell, so a cubit created here would never hear about an
    // order placed on another tab -- which is exactly what happened to a
    // customer's first order: they had looked at this empty screen before
    // ordering, so coming back showed "no orders yet" until they pulled to
    // refresh.
    return _MyOrdersView(
      onBrowseMenu: onBrowseMenu,
      onOpenCheckout: onOpenCheckout,
    );
  }
}

class _MyOrdersView extends StatefulWidget {
  const _MyOrdersView({this.onBrowseMenu, this.onOpenCheckout});

  final VoidCallback? onBrowseMenu;
  final VoidCallback? onOpenCheckout;

  @override
  State<_MyOrdersView> createState() => _MyOrdersViewState();
}

class _MyOrdersViewState extends State<_MyOrdersView> {
  Timer? _poll;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // First look at this tab in this session: ask for the history. Silent when
    // something is already held, so returning to the tab refreshes underneath
    // rather than blanking a tracker the customer is watching.
    final cubit = context.read<OrdersCubit>();
    cubit.load(silent: cubit.state.orders.isNotEmpty);

    // A live order changes without the user doing anything, and pull-to-refresh
    // is a poor answer to "is it out for delivery yet" — it asks the person
    // watching the screen to keep asking. Polling is silent, so the tracker
    // moves under them rather than blanking.
    //
    // Thirty seconds, and only while something is actually in progress: see the
    // listener below, which stops the timer the moment the last order settles.
    _startPolling();

    // Backgrounding stops it, resuming reads once and starts again. Without
    // this the timer keeps firing on a suspended app — a request every thirty
    // seconds, on mobile data, for a screen nobody is looking at.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!mounted) return;
        context.read<OrdersCubit>().load(silent: true);
        _startPolling();
      },
      onPause: _stopPolling,
    );
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) context.read<OrdersCubit>().load(silent: true);
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  void _stopPollingIfSettled(OrdersState state) {
    if (state.status == OrdersStatus.ready && state.live.isEmpty) {
      _stopPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        actions: [
          // Only once there is something to check out. The badge is the whole
          // signal here — an empty cart icon on the orders screen would lead to
          // a screen that can only say the basket is empty.
          if (widget.onOpenCheckout != null &&
              context.select((CartCubit c) => !c.state.isEmpty))
            CartIconButton(onTap: widget.onOpenCheckout),
        ],
      ),
      body: BlocConsumer<OrdersCubit, OrdersState>(
        listener: (context, state) => _stopPollingIfSettled(state),
        builder: (context, state) {
          final cubit = context.read<OrdersCubit>();

          if (state.status == OrdersStatus.loading) {
            // The same card-shaped skeleton the menu uses, at tracker height:
            // the page doesn't reflow when the orders land.
            // Shaped like an order card -- reference, status pill, and the
            // action button under it -- rather than like the dish list. A
            // placeholder that does not match what arrives reads as the screen
            // being replaced rather than filled in.
            return const OrderListSkeleton(rows: 3);
          }

          if (state.status == OrdersStatus.failure && state.failure != null) {
            return ApiErrorView(
              failure: state.failure!,
              onRetry: () => cubit.load(),
            );
          }

          if (state.isEmpty) {
            return _NoOrdersYet(onBrowseMenu: widget.onBrowseMenu);
          }

          final live = state.live;
          final past = state.past;

          final rows = <WidgetBuilder>[
            if (live.isNotEmpty) ...[
              (_) => _SectionHeading(
                label: live.length == 1
                    ? 'Happening now'
                    : '${live.length} orders in progress',
              ),
              for (final order in live)
                (_) => Padding(
                  key: ValueKey('live-${order.id}'),
                  padding: const EdgeInsets.only(bottom: AppSpacing.x4),
                  child: _LiveOrderCard(
                    order: order,
                    isCancelling: state.cancellingId == order.id,
                    isPaying: state.payingId == order.id,
                  ),
                ),
            ],
            if (past.isNotEmpty) ...[
              if (live.isNotEmpty) (_) => const SizedBox(height: AppSpacing.x4),
              (_) => const _SectionHeading(label: 'Earlier orders'),
              for (final order in past)
                (_) => Padding(
                  key: ValueKey('past-${order.id}'),
                  padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                  child: _PastOrderRow(order: order),
                ),
            ],
            // Only where there is more history to fetch. A button that comes
            // back with nothing is worse than no button.
            if (state.hasMore)
              (_) => Padding(
                padding: const EdgeInsets.only(top: AppSpacing.x2),
                child: Center(
                  child: state.loadingMore
                      ? const Padding(
                          padding: EdgeInsets.all(AppSpacing.x3),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : OutlinedButton(
                          onPressed: cubit.loadMore,
                          child: const Text('Load earlier orders'),
                        ),
                ),
              ),
          ];

          return RefreshIndicator(
            onRefresh: () =>
                refreshWithSession(context, () => cubit.load(silent: true)),
            // Built one row at a time rather than all at once. The screen
            // rebuilds on every poll tick, and constructing a page of cards to
            // show three was most of the work it did. Pagination makes this
            // matter more, not less: the list only grows from here.
            //
            // The closures below are the cheap part: making them costs nothing,
            // and only the ones on screen are ever called.
            child: ListView.builder(
              padding: pagePadding(
                context,
                top: AppSpacing.x4,
                bottom: AppSpacing.x12,
              ),
              itemCount: rows.length,
              itemBuilder: (context, index) =>
                  rows[index](context).revealItem(index),
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: Text(label, style: context.texts.headlineMedium),
    );
  }
}

/// An order still in progress: the tracker, what is in it, and the way out.
class _LiveOrderCard extends StatelessWidget {
  const _LiveOrderCard({
    required this.order,
    required this.isCancelling,
    required this.isPaying,
  });

  final CustomerOrder order;
  final bool isCancelling;
  final bool isPaying;

  Future<void> _pay(BuildContext context) async {
    final cubit = context.read<OrdersCubit>();
    final message = await cubit.payOrder(order.id);
    if (!context.mounted) return;

    if (message == null) {
      AppHaptics.success();
      showAppSnack(
        context,
        'Payment received. Order ${order.reference} is '
        "confirmed and we're preparing it.",
      );
      return;
    }
    AppHaptics.failure();
    showAppSnack(context, message, isError: true);
  }

  Future<void> _cancel(BuildContext context) async {
    final cubit = context.read<OrdersCubit>();
    // Asked before it happens, not undone afterwards. There is no un-cancelling
    // an order the kitchen has already stopped cooking.
    final reason = TextEditingController();
    final confirmed = await showAppSheet<bool>(
      context: context,
      title: 'Cancel order ${order.reference}?',
      child: Builder(
        // `AppSheet` pads its title block but hands the child through bare, so
        // a sheet has to bring its own gutter. Without it the text ran to both
        // edges and the last button sat under the home indicator.
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
                'This cannot be undone. If the kitchen has already started, we '
                'may not be able to cancel.',
                style: sheetContext.texts.bodyMedium?.copyWith(
                  color: sheetContext.surfaces.inkMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.x4),
              // Optional, and said to be: the restaurant reads these, but
              // demanding an explanation before letting somebody out of an
              // order they have not been charged for is a toll, not a question.
              TextField(
                controller: reason,
                maxLength: 500,
                maxLines: 2,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  hintText: 'Ordered by mistake, changed my mind…',
                ),
              ),
              const SizedBox(height: AppSpacing.x4),
              // Keeping the order is the safe choice, so it gets the filled
              // button; cancelling is the destructive one and reads as such.
              // The old layout had them the other way round, which put the
              // irreversible action under the thumb by default.
              PrimaryButton(
                label: 'Keep my order',
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: AppSpacing.x2),
              TextButton(
                // Pops the sheet's own route, not the screen behind it — hence
                // the Builder: the enclosing context predates the sheet.
                onPressed: () => Navigator.of(sheetContext).pop(true),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: sheetContext.orderColors.overdue,
                ),
                child: const Text('Cancel this order'),
              ),
            ],
          ),
        ),
      ),
    );

    final typed = reason.text;
    reason.dispose();
    if (confirmed != true || !context.mounted) return;

    final error = await cubit.cancelOrder(order.id, reason: typed);
    if (!context.mounted) return;

    if (error == null) {
      AppHaptics.success();
      showAppSnack(context, 'Order ${order.reference} was cancelled.');
    } else {
      AppHaptics.failure();
      showAppSnack(context, error, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final colour = order.status.foreground(context);

    return AppSurface.panel(
      padding: const EdgeInsets.all(AppSpacing.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: order.status.container(context),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(
                  order.status.icon,
                  size: AppIconSize.xl,
                  color: colour,
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.statusLabel,
                      style: context.texts.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${order.reference} · ${_itemSummary(order)}',
                      style: context.texts.bodySmall?.copyWith(
                        color: surfaces.inkSoft,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                order.formattedTotal,
                style: AppTypography.money(
                  Theme.of(context).colorScheme.onSurface,
                  size: MoneySize.small,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x5),

          OrderTracker(order: order),

          const SizedBox(height: AppSpacing.x4),
          Text(order.statusExplanation, style: context.texts.bodyMedium),

          if (order.estimatedReadyAt != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: AppIconSize.sm,
                  color: surfaces.inkSoft,
                ),
                const SizedBox(width: AppSpacing.x1 + 2),
                Text(
                  '${order.isDelivery ? 'Arriving' : 'Ready'} around '
                  '${_time(order.estimatedReadyAt!)}',
                  style: context.texts.bodySmall?.copyWith(
                    color: surfaces.inkSoft,
                  ),
                ),
              ],
            ),
          ],

          if (order.needsPayment) ...[
            const SizedBox(height: AppSpacing.x4),
            PrimaryButton(
              // "Try again" after a decline, because the first attempt is not
              // something to repeat -- the flow fetches a new page, which
              // Worldpay requires for a retry to reach it at all.
              label: isPaying
                  ? 'Confirming payment…'
                  : order.paymentStatus == CustomerPaymentStatus.failed
                  ? 'Try again'
                  : 'Pay ${order.formattedTotal}',
              icon: Icons.credit_card,
              onPressed: isPaying ? null : () => _pay(context),
            ),
          ],

          if (order.canCancel) ...[
            const SizedBox(height: AppSpacing.x4),
            // Quiet, not a primary button: cancelling is the rare choice on a
            // card whose main purpose is reassurance.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: isCancelling ? null : () => _cancel(context),
                icon: isCancelling
                    ? const SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.close, size: AppIconSize.md),
                label: Text(isCancelling ? 'Cancelling…' : 'Cancel order'),
                style: TextButton.styleFrom(
                  foregroundColor: context.orderColors.overdue,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A finished order: one line, tappable for the receipt.
class _PastOrderRow extends StatefulWidget {
  const _PastOrderRow({required this.order});

  final CustomerOrder order;

  @override
  State<_PastOrderRow> createState() => _PastOrderRowState();
}

class _PastOrderRowState extends State<_PastOrderRow> {
  /// True from the tap until the receipt is on screen.
  ///
  /// Fetching the receipt takes a moment and the row gave no sign it had
  /// heard, so a second tap sent a second request and opened a second sheet on
  /// top of the first. The first tap now takes the row out of service.
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    AppHaptics.toggle();

    // The list endpoint sends no lines, so the receipt is fetched. If the
    // fetch fails the summary is shown anyway — a total and a date is still
    // most of a receipt, and an error sheet would be less.
    final cubit = context.read<OrdersCubit>();
    final detailed = await cubit.loadDetail(widget.order.id);
    if (!mounted) return;
    setState(() => _opening = false);
    _showReceipt(context, detailed ?? widget.order);
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = context.surfaces;
    final scheme = Theme.of(context).colorScheme;
    final order = widget.order;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: _opening ? null : _open,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppSurface.row(
          padding: const EdgeInsets.all(AppSpacing.x3 + 2),
          child: Row(
            children: [
              Icon(
                order.status.icon,
                size: AppIconSize.xl,
                color: order.status.foreground(context),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      order.reference,
                      style: context.texts.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (order.placedAt != null) _date(order.placedAt!),
                        _itemSummary(order),
                      ].join(' · '),
                      style: context.texts.bodySmall?.copyWith(
                        color: surfaces.inkSoft,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    order.formattedTotal,
                    style: AppTypography.money(
                      scheme.onSurface,
                      size: MoneySize.small,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.x1 + 2),
                  AppChip.status(
                    label: order.statusLabel,
                    foreground: order.status.foreground(context),
                    background: order.status.container(context),
                  ),
                ],
              ),
              // Always the same width, spinning or not, so the row does not
              // shift sideways the instant it is tapped.
              SizedBox(
                width: AppIconSize.xl,
                child: Center(
                  child: _opening
                      ? SizedBox(
                          width: AppIconSize.md,
                          height: AppIconSize.md,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.chevron_right,
                          size: AppIconSize.lg,
                          color: surfaces.inkSoft,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The receipt for a past order.
void _showReceipt(BuildContext context, CustomerOrder order) {
  showAppSheet<void>(
    context: context,
    title: 'Order ${order.reference}',
    // Padded and scrollable. It was a bare Column: no gutter, so the lines ran
    // to both edges, and no scroll, so a receipt with several items grew the
    // sheet to the height cap and then clipped the total off the bottom.
    child: Builder(
      builder: (context) => SingleChildScrollView(
        padding: pagePadding(
          context,
          top: 0,
          bottom: AppSpacing.x2 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppChip.status(
                  label: order.statusLabel,
                  foreground: order.status.foreground(context),
                  background: order.status.container(context),
                ),
                const SizedBox(width: AppSpacing.x2),
                if (order.placedAt != null)
                  Text(
                    _date(order.placedAt!),
                    style: context.texts.bodySmall?.copyWith(
                      color: context.surfaces.inkSoft,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.x4),

            // Why, in the restaurant's own words. The API makes the note
            // mandatory when staff cancel or reject, so on those orders there is
            // always something here — and a customer whose order was refused
            // with no explanation has to ring up to find out why.
            if (order.cancellationReason != null) ...[
              _ReasonNotice(order: order),
              const SizedBox(height: AppSpacing.x4),
            ],

            if (order.items.isEmpty)
              // Only reached when the detail fetch failed, since the API always
              // sends lines on a single order. Saying so beats an empty gap that
              // reads as a rendering fault.
              Text(
                'Could not load the item breakdown. Pull to refresh and try '
                'again.',
                style: context.texts.bodyMedium?.copyWith(
                  color: context.surfaces.inkSoft,
                ),
              )
            else
              for (final item in order.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${item.quantity}×',
                          style: context.texts.titleMedium,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Size, serving or package included: "Breakfast"
                            // alone does not say which one was bought.
                            Text(
                              item.titleWithVariant,
                              style: context.texts.bodyLarge,
                            ),
                            // Every option, with the server's own included /
                            // charged split -- which is what was actually
                            // billed, and the only version worth printing on
                            // a receipt.
                            for (final selection in item.selections)
                              Text(
                                selection.isCharged
                                    ? '${selection.label} '
                                          '+${OrderQuote.formatPence(selection.totalPence)}'
                                    : selection.label,
                                style: context.texts.bodySmall?.copyWith(
                                  color: context.surfaces.inkSoft,
                                ),
                              ),
                            // Read from the order, not the dish: an admin can
                            // turn spice choices off later and this receipt must
                            // still say what was ordered.
                            if (item.spiceLevel != null || item.notes != null)
                              Text(
                                [
                                  if (item.spiceLevel != null)
                                    '${item.spiceLevel!.label} spice',
                                  if (item.notes != null) item.notes!,
                                ].join(' · '),
                                style: context.texts.bodySmall?.copyWith(
                                  color: context.surfaces.inkSoft,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x2),
                      Text(
                        '£${(item.linePence / 100).toStringAsFixed(2)}',
                        style: context.texts.bodyLarge,
                      ),
                    ],
                  ),
                ),

            Divider(height: AppSpacing.x6, color: context.surfaces.line),
            Row(
              children: [
                Expanded(child: Text('Total', style: context.texts.titleLarge)),
                Text(
                  order.formattedTotal,
                  style: AppTypography.money(
                    Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Why the restaurant cancelled or rejected an order.
class _ReasonNotice extends StatelessWidget {
  const _ReasonNotice({required this.order});

  final CustomerOrder order;

  @override
  Widget build(BuildContext context) {
    final colours = context.orderColors;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: colours.overdueContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            order.wasRejected
                ? Icons.do_not_disturb_on_outlined
                : Icons.info_outline,
            size: AppIconSize.md,
            color: colours.overdue,
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.wasRejected
                      ? 'The restaurant declined this order'
                      : 'This order was cancelled',
                  style: context.texts.titleSmall?.copyWith(
                    color: colours.overdue,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  order.cancellationReason!,
                  style: context.texts.bodyMedium,
                ),
                if (order.cancelledAt != null) ...[
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    _date(order.cancelledAt!),
                    style: context.texts.bodySmall?.copyWith(
                      color: context.surfaces.inkSoft,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Nothing ordered yet.
class _NoOrdersYet extends StatelessWidget {
  const _NoOrdersYet({this.onBrowseMenu});

  final VoidCallback? onBrowseMenu;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: AppIconSize.hero,
              color: context.surfaces.inkSoft,
            ),
            const SizedBox(height: AppSpacing.x4),
            Text('No orders yet', style: context.texts.headlineMedium),
            const SizedBox(height: AppSpacing.x2),
            Text(
              'Your orders will appear here, and you can follow each one from '
              'the kitchen to your door.',
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium?.copyWith(
                color: context.surfaces.inkMuted,
              ),
            ),
            if (onBrowseMenu != null) ...[
              const SizedBox(height: AppSpacing.x6),
              SecondaryButton(
                label: 'Browse the menu',
                onPressed: onBrowseMenu,
              ),
            ],
          ],
        ),
      ).reveal(),
    );
  }
}

String _itemSummary(CustomerOrder order) {
  final count = order.itemCount;
  if (count == 0) return order.isDelivery ? 'Delivery' : 'Collection';
  return '$count ${count == 1 ? 'item' : 'items'}'
      ' · ${order.isDelivery ? 'Delivery' : 'Collection'}';
}

/// A date a person can read. "Today" and "Yesterday" are what someone scanning
/// their recent orders is actually looking for.
String _date(DateTime when) {
  final now = DateTime.now();
  final day = DateTime(when.year, when.month, when.day);
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;

  if (difference == 0) return 'Today, ${_time(when)}';
  if (difference == 1) return 'Yesterday, ${_time(when)}';
  return '${when.day} ${_months[when.month - 1]}'
      '${when.year == now.year ? '' : ' ${when.year}'}';
}

String _time(DateTime when) =>
    '${when.hour.toString().padLeft(2, '0')}:'
    '${when.minute.toString().padLeft(2, '0')}';

const _months = [
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
