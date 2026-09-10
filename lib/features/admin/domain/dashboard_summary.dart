import 'package:equatable/equatable.dart';

import '../../../core/money/pence.dart' as money;

/// Takings, in integer pence.
///
/// **Completed orders only**, bucketed by when they completed. Cancelled and
/// rejected orders never count, and an order still cooking counts nowhere yet —
/// so a figure here can only grow through the day, never shrink.
class RevenueTiles extends Equatable {
  const RevenueTiles({
    this.todayPence = 0,
    this.thisWeekPence = 0,
    this.thisMonthPence = 0,
  });

  factory RevenueTiles.fromJson(Map<String, dynamic> json) => RevenueTiles(
    todayPence: _int(json['today_pence']),
    thisWeekPence: _int(json['this_week_pence']),
    thisMonthPence: _int(json['this_month_pence']),
  );

  final int todayPence;
  final int thisWeekPence;
  final int thisMonthPence;

  @override
  List<Object?> get props => [todayPence, thisWeekPence, thisMonthPence];
}

/// The live queue, right now — not "today".
///
/// An order placed yesterday evening and still open appears here but not in
/// [OrdersSummary.today].
class OpenOrders extends Equatable {
  const OpenOrders({
    this.placed = 0,
    this.preparing = 0,
    this.ready = 0,
    this.outForDelivery = 0,
  });

  factory OpenOrders.fromJson(Map<String, dynamic> json) => OpenOrders(
    placed: _int(json['placed']),
    preparing: _int(json['preparing']),
    ready: _int(json['ready']),
    outForDelivery: _int(json['out_for_delivery']),
  );

  final int placed;
  final int preparing;
  final int ready;
  final int outForDelivery;

  int get total => placed + preparing + ready + outForDelivery;

  @override
  List<Object?> get props => [placed, preparing, ready, outForDelivery];
}

class OrdersSummary extends Equatable {
  const OrdersSummary({this.today = 0, this.open = const OpenOrders()});

  factory OrdersSummary.fromJson(Map<String, dynamic> json) => OrdersSummary(
    today: _int(json['today']),
    open: OpenOrders.fromJson(_map(json['open'])),
  );

  /// Orders **placed** since midnight on the restaurant's clock, whatever
  /// happened to them since — cancelled ones included. This is "how busy are we
  /// today", not revenue.
  final int today;

  final OpenOrders open;

  @override
  List<Object?> get props => [today, open];
}

/// A to-do list, not a statistic. Both counts fall as an admin deals with the
/// item, and zero is the happy state.
class AttentionSummary extends Equatable {
  const AttentionSummary({this.pendingBookings = 0, this.newMessages = 0});

  factory AttentionSummary.fromJson(Map<String, dynamic> json) =>
      AttentionSummary(
        pendingBookings: _int(json['pending_bookings']),
        newMessages: _int(json['new_messages']),
      );

  final int pendingBookings;
  final int newMessages;

  bool get isClear => pendingBookings == 0 && newMessages == 0;

  @override
  List<Object?> get props => [pendingBookings, newMessages];
}

/// Everything the dashboard shows, from one request.
class DashboardSummary extends Equatable {
  const DashboardSummary({
    this.revenue = const RevenueTiles(),
    this.orders = const OrdersSummary(),
    this.attention = const AttentionSummary(),
  });

  factory DashboardSummary.fromJson(Map<String, dynamic> json) =>
      DashboardSummary(
        revenue: RevenueTiles.fromJson(_map(json['revenue'])),
        orders: OrdersSummary.fromJson(_map(json['orders'])),
        attention: AttentionSummary.fromJson(_map(json['attention'])),
      );

  final RevenueTiles revenue;
  final OrdersSummary orders;
  final AttentionSummary attention;

  @override
  List<Object?> get props => [revenue, orders, attention];
}

/// Tolerant readers.
///
/// The guide's own models cast with `as int`, which throws the whole screen away
/// if the backend ever sends a null or a double for one counter. A missing
/// figure showing as zero is a far better outcome than a dashboard that will not
/// render — and every field here is a count or integer pence.
int _int(Object? value) => (value as num?)?.toInt() ?? 0;

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

/// Re-exported so the dashboard's call sites keep working. The one
/// implementation lives in `core/money/pence.dart`.
String formatPence(int pence) => money.formatPence(pence);
