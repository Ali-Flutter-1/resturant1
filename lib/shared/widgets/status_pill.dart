import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/admin/domain/admin_order.dart';
import 'app_chip.dart';

/// Colour for an order status.
///
/// The status enum itself lives in the admin domain — it is the API's, not this
/// widget's. There used to be a second one here with `served` and `overdue`,
/// invented before the backend's own vocabulary was known; two enums called
/// OrderStatus in one app is a trap, so this is the only one left.
extension OrderStatusPalette on OrderStatus {
  Color foreground(BuildContext context) {
    final c = context.orderColors;
    return switch (this) {
      // The queue that needs a human decision, and the one waiting on the
      // customer's money. Both need attention, neither is cooking.
      OrderStatus.pendingApproval => c.overdue,
      OrderStatus.awaitingPayment => c.overdue,
      OrderStatus.placed => c.preparing,
      OrderStatus.acceptancePending => c.preparing,
      OrderStatus.cancellationPending => c.overdue,
      OrderStatus.preparing => c.preparing,
      OrderStatus.ready || OrderStatus.outForDelivery => c.ready,
      OrderStatus.completed => c.served,
      OrderStatus.cancelled || OrderStatus.rejected => c.overdue,
      OrderStatus.unknown => c.served,
    };
  }

  Color container(BuildContext context) {
    final c = context.orderColors;
    return switch (this) {
      OrderStatus.pendingApproval => c.overdueContainer,
      OrderStatus.awaitingPayment => c.overdueContainer,
      OrderStatus.placed => c.preparingContainer,
      OrderStatus.acceptancePending => c.preparingContainer,
      OrderStatus.cancellationPending => c.overdueContainer,
      OrderStatus.preparing => c.preparingContainer,
      OrderStatus.ready || OrderStatus.outForDelivery => c.readyContainer,
      OrderStatus.completed => c.servedContainer,
      OrderStatus.cancelled || OrderStatus.rejected => c.overdueContainer,
      OrderStatus.unknown => c.servedContainer,
    };
  }
}

/// Status as a chip: a dot for peripheral vision, a word for certainty.
///
/// A thin wrapper over [AppChip] so status can't drift away from every other
/// chip in the app, which is exactly what had happened.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    return AppChip.status(
      label: status.label,
      foreground: status.foreground(context),
      background: status.container(context),
    );
  }
}
