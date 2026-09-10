import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/customer_order.dart';

/// Colour and glyph for a customer-facing order status.
///
/// Reuses the same four state colours the staff screens use — see
/// [OrderStateColors] — so "ready" is the same green on both sides of the app.
/// The mapping lives here rather than on the enum because the enum is domain and
/// knows nothing about themes.
extension CustomerOrderStatusPalette on CustomerOrderStatus {
  Color foreground(BuildContext context) {
    final c = context.orderColors;
    return switch (this) {
      // Money outstanding is the customer's problem to solve, so it borrows
      // the same attention colour a late order does on the staff side.
      CustomerOrderStatus.awaitingPayment => c.overdue,
      CustomerOrderStatus.placed ||
      CustomerOrderStatus.accepting ||
      CustomerOrderStatus.preparing => c.preparing,
      CustomerOrderStatus.ready ||
      CustomerOrderStatus.outForDelivery => c.ready,
      CustomerOrderStatus.completed => c.served,
      CustomerOrderStatus.cancelling ||
      CustomerOrderStatus.cancelled => c.overdue,
    };
  }

  Color container(BuildContext context) {
    final c = context.orderColors;
    return switch (this) {
      CustomerOrderStatus.awaitingPayment => c.overdueContainer,
      CustomerOrderStatus.placed ||
      CustomerOrderStatus.accepting ||
      CustomerOrderStatus.preparing => c.preparingContainer,
      CustomerOrderStatus.ready ||
      CustomerOrderStatus.outForDelivery => c.readyContainer,
      CustomerOrderStatus.completed => c.servedContainer,
      CustomerOrderStatus.cancelling ||
      CustomerOrderStatus.cancelled => c.overdueContainer,
    };
  }

  /// The glyph for this stage. Each one names the thing that is happening, so
  /// the tracker reads at a glance without the labels.
  IconData get icon => switch (this) {
    CustomerOrderStatus.awaitingPayment => Icons.credit_card_outlined,
    CustomerOrderStatus.placed => Icons.receipt_long_outlined,
    // A hold being turned into a charge, and a hold being released: both are
    // the provider working, neither is the kitchen.
    CustomerOrderStatus.accepting => Icons.verified_outlined,
    CustomerOrderStatus.cancelling => Icons.hourglass_bottom_outlined,
    CustomerOrderStatus.preparing => Icons.outdoor_grill_outlined,
    CustomerOrderStatus.ready => Icons.shopping_bag_outlined,
    CustomerOrderStatus.outForDelivery => Icons.delivery_dining_outlined,
    CustomerOrderStatus.completed => Icons.check_circle_outline,
    CustomerOrderStatus.cancelled => Icons.cancel_outlined,
  };
}
