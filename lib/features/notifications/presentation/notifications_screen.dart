import 'package:flutter/material.dart';
// `flutter_bloc` re-exports provider's `context.read` and the exception it
// throws when nothing is in scope, so the package is not a direct dependency.
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/animations/motion.dart';
import '../../../core/animations/page_transitions.dart';
import '../../../core/animations/reveal.dart';
import '../../../core/haptics/app_haptics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/session_refresh.dart';
import '../../auth/auth_cubit.dart';
import '../domain/app_notification.dart';
import '../domain/notification_repository.dart';
import 'notification_routing.dart';
import 'notifications_cubit.dart';
import '../../../shared/widgets/page_body.dart';

/// Opens the inbox.
///
/// [onFollow] is what a tapped row does. Without one the tap still marks the
/// row read and leaves the user on the inbox — which is a real action on a
/// screen that already says what happened, not a dead control.
///
/// Wiring a destination needs the shell's tabs, so it is supplied from there
/// rather than guessed at here. See [NotificationTarget]: anything the payload
/// does not clearly identify stays on the inbox by design.
void openNotifications(
  BuildContext context, {
  void Function(NotificationPayload payload)? onFollow,
}) {
  // The shell's answer, unless the caller supplied one. Captured here — before
  // the push — because the route's own context sits above the shell and would
  // not find it.
  final routing = NotificationRouting.maybeOf(context);
  final follow =
      onFollow ??
      (routing == null
          ? null
          : (payload) => routing.onFollow(context, payload));

  Navigator.of(context).push(
    AppPageRoute<void>(builder: (_) => NotificationsScreen(onOpen: follow)),
  );
}

/// The in-app inbox.
///
/// The durable half of notifications: whatever the operating system did or did
/// not show, this is the record. It is a screen rather than the sheet it
/// replaced because the list pages, and a sheet that grows past the height cap
/// clips its own contents.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key, this.onOpen});

  /// Opens whatever the notification is about. Given a validated payload — the
  /// screen it lands on fetches the record itself, because a push carries an id
  /// and nothing else worth trusting.
  final void Function(NotificationPayload payload)? onOpen;

  @override
  Widget build(BuildContext context) {
    // The app-level cubit, not a new one. The bell and this screen have to be
    // the same instance or marking everything read here leaves the badge
    // showing the old count — which is exactly what used to happen.
    context.read<NotificationsCubit>().load();
    return _NotificationsView(onOpen: onOpen);
  }
}

class _NotificationsView extends StatelessWidget {
  const _NotificationsView({this.onOpen});

  final void Function(NotificationPayload payload)? onOpen;

  Future<void> _open(BuildContext context, AppNotification item) async {
    AppHaptics.selection();
    // Marked read on open, as the guide asks. Not on arrival — a notification
    // that shows up while the list is open has not been read yet.
    await context.read<NotificationsCubit>().markRead(item);
    if (!context.mounted) return;
    onOpen?.call(item.payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: BlocBuilder<NotificationsCubit, NotificationsState>(
        builder: (context, state) {
          final cubit = context.read<NotificationsCubit>();

          if (state.status == InboxStatus.loading) {
            return const MessageListSkeleton();
          }
          if (state.status == InboxStatus.failure && state.failure != null) {
            return ApiErrorView(
              failure: state.failure!,
              onRetry: () => cubit.load(),
            );
          }
          if (state.items.isEmpty) return const _Empty();

          return RefreshIndicator(
            onRefresh: () =>
                refreshWithSession(context, () => cubit.load(silent: true)),
            child: ListView.separated(
              padding: pagePadding(
                context,
                top: AppSpacing.x4,
                bottom: AppSpacing.x12 + MediaQuery.paddingOf(context).bottom,
              ),
              // One extra leading row for the summary bar.
              itemCount: state.items.length + 1 + (state.hasMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.x3),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _InboxHeader(
                    unread: state.unread,
                    busy: state.status == InboxStatus.loading,
                    onMarkAllRead: cubit.markAllRead,
                  );
                }
                index -= 1;

                if (index == state.items.length) {
                  return Center(
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
                            child: const Text('Load more'),
                          ),
                  );
                }

                final item = state.items[index];
                return _NotificationRow(
                  key: ValueKey(item.id),
                  item: item,
                  onTap: () => _open(context, item),
                ).revealItem(index, duration: Motion.fast);
              },
            ),
          );
        },
      ),
    );
  }
}

/// How many are unread, and the one action that changes it.
///
/// In the list rather than the app bar: a disabled text button in a bar says
/// nothing about *why* it is disabled, and "Mark all read" with nothing unread
/// is a control with no work to do. Here it simply is not offered, and the row
/// says what the state is instead.
class _InboxHeader extends StatelessWidget {
  const _InboxHeader({
    required this.unread,
    required this.busy,
    required this.onMarkAllRead,
  });

  final int unread;
  final bool busy;
  final VoidCallback onMarkAllRead;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasUnread = unread > 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x1),
      child: Row(
        children: [
          if (hasUnread) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.x2),
          ],
          Expanded(
            child: Text(
              hasUnread ? '$unread unread' : 'All caught up',
              style: context.texts.titleMedium?.copyWith(
                color: hasUnread ? null : context.surfaces.inkSoft,
              ),
            ),
          ),
          if (hasUnread)
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      AppHaptics.toggle();
                      onMarkAllRead();
                    },
              child: const Text('Mark all read'),
            ),
        ],
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({super.key, required this.item, required this.onTap});

  final AppNotification item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppSurface.row(
          padding: EdgeInsets.zero,
          clip: true,
          // `IntrinsicHeight` so the edge stripe runs the full height of the
          // row — `stretch` alone needs a bounded height, and a list item has
          // none.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A crimson edge down the unread rows. Cheaper to scan than a dot
                // on the far side, and it survives being read in bright sun where
                // a weight difference alone does not.
                AnimatedContainer(
                  duration: context.motion.fade(Motion.fast),
                  width: 3,
                  color: item.isUnread ? scheme.primary : Colors.transparent,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.x4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: item.isUnread
                                ? context.surfaces.accentContainer
                                : context.surfaces.ground,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Icon(
                            _iconFor(item.payload.event),
                            size: AppIconSize.lg,
                            color: item.isUnread
                                ? scheme.primary
                                : context.surfaces.inkSoft,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: context.texts.titleMedium?.copyWith(
                                  // Weight, not colour: an unread row must still be
                                  // legible, and a bold line is the convention every
                                  // inbox already uses.
                                  fontWeight: item.isUnread
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              if (item.body.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(item.body, style: context.texts.bodySmall),
                              ],
                              if (item.createdAt != null) ...[
                                const SizedBox(height: AppSpacing.x1),
                                Text(
                                  _ago(item.createdAt!),
                                  style: context.texts.labelSmall?.copyWith(
                                    color: context.surfaces.inkSoft,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(NotificationEvent event) => switch (event) {
    NotificationEvent.orderPreparing => Icons.soup_kitchen_outlined,
    NotificationEvent.orderReady => Icons.room_service_outlined,
    NotificationEvent.orderOutForDelivery => Icons.local_shipping_outlined,
    NotificationEvent.orderCompleted => Icons.check_circle_outline,
    NotificationEvent.orderRejected ||
    NotificationEvent.orderCancelled ||
    NotificationEvent.orderCancelledAdmin => Icons.do_not_disturb_on_outlined,
    NotificationEvent.orderPlacedAdmin => Icons.receipt_long_outlined,
    NotificationEvent.bookingConfirmed => Icons.event_available_outlined,
    NotificationEvent.bookingRequestedAdmin => Icons.event_note_outlined,
    NotificationEvent.bookingRejected ||
    NotificationEvent.bookingCancelled ||
    NotificationEvent.bookingCancelledAdmin ||
    NotificationEvent.bookingExpired ||
    NotificationEvent.bookingNoShow => Icons.event_busy_outlined,
    // An event this build has never heard of still gets a row and an icon.
    NotificationEvent.unknown => Icons.notifications_none,
  };

  static String _ago(DateTime when) {
    final gap = DateTime.now().difference(when);
    if (gap.inMinutes < 1) return 'Just now';
    if (gap.inMinutes < 60) return '${gap.inMinutes} min ago';
    if (gap.inHours < 24) {
      return '${gap.inHours} ${gap.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    if (gap.inDays == 1) return 'Yesterday';
    if (gap.inDays < 7) return '${gap.inDays} days ago';
    return '${when.day}/${when.month}/${when.year}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return ListView(
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
                  Icons.notifications_none,
                  size: AppIconSize.hero,
                  color: context.surfaces.inkSoft,
                ),
                const SizedBox(height: AppSpacing.x4),
                Text(
                  'Nothing yet',
                  style: context.texts.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  'Updates about your orders and bookings will appear here.',
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

/// The bell, with its unread count.
///
/// Owns a cubit of its own so the badge is live wherever the bell sits, without
/// the surrounding screen having to know anything about notifications.
///
/// Draws nothing at all where no [NotificationRepository] is in scope — a screen
/// used standalone, or in a test. That is the honest outcome rather than a
/// fallback: a bell that cannot count anything and opens an inbox that cannot
/// load is exactly the decoration-shaped-like-a-control worth not shipping.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    // Nothing to a guest. The inbox is per-account and its endpoint answers a
    // session-less request with a 401, so a bell here would be a control that
    // opens an error -- and there is nothing an account-less visitor could
    // have been notified about anyway.
    try {
      if (!context.select((AuthCubit c) => c.state.isSignedIn)) {
        return const SizedBox.shrink();
      }
    } on ProviderNotFoundException {
      // No auth in scope either: a standalone screen or a test, handled below.
    }

    // Draws nothing where no cubit is in scope — a screen pumped standalone, or
    // a test. A bell that cannot count anything and opens an inbox that cannot
    // load is a decoration shaped like a control.
    try {
      context.read<NotificationsCubit>();
    } on ProviderNotFoundException {
      debugPrint(
        'NotificationBell: no NotificationsCubit in scope, so no bell.',
      );
      return const SizedBox.shrink();
    }
    return _BellButton(onOpen: onOpen);
  }
}

class _BellButton extends StatelessWidget {
  const _BellButton({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final motion = context.motion;
    final unread = context.select((NotificationsCubit c) => c.state.unread);

    return IconButton(
      tooltip: unread == 0
          ? 'Notifications'
          : '$unread unread ${unread == 1 ? 'notification' : 'notifications'}',
      color: scheme.primary,
      onPressed: () {
        AppHaptics.toggle();
        onOpen();
      },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          // Filled while something is waiting, outlined once it is not — the
          // glyph carries the state as well as the pill, so the bell still reads
          // at a glance to somebody who cannot make out a small red circle.
          AnimatedSwitcher(
            duration: motion.fade(Motion.fast),
            child: Icon(
              unread > 0
                  ? Icons.notifications
                  : Icons.notifications_none_outlined,
              key: ValueKey(unread > 0),
            ),
          ),
          Positioned(
            right: -6,
            top: -5,
            // Scales in and out rather than appearing: the count changes while
            // the user is looking at the bar, and a pill that pops into
            // existence reads as a glitch.
            child: AnimatedScale(
              scale: unread > 0 ? 1 : 0,
              duration: motion.move(Motion.fast),
              curve: motion.emphasized,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 17),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  // Punches the pill out of the bar behind it, so it reads as
                  // sitting on top of the bell rather than merging with it.
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
                child: AnimatedSwitcher(
                  duration: motion.fade(Motion.fast),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.5),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Text(
                    // Past 99 the pill stops being a number and starts being a
                    // width problem.
                    unread > 99 ? '99+' : '$unread',
                    key: ValueKey(unread),
                    textAlign: TextAlign.center,
                    style: AppTypography.badge(scheme.onPrimary),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
