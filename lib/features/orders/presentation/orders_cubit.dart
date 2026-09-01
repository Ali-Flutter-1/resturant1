import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../domain/customer_order.dart';
import '../domain/order_repository.dart';
import '../domain/payment_flow.dart';

enum OrdersStatus { loading, ready, failure }

class OrdersState extends Equatable {
  const OrdersState({
    this.status = OrdersStatus.loading,
    this.orders = const [],
    this.failure,
    this.cancellingId,
    this.payingId,
  });

  final OrdersStatus status;

  /// Newest first, as the repository sorts them.
  final List<CustomerOrder> orders;

  /// Set only when [status] is [OrdersStatus.failure]; safe to show verbatim.
  final ApiFailure? failure;

  /// The order whose cancellation is in flight, so only that row shows a
  /// spinner and only that row's button is disabled.
  final String? cancellingId;

  /// The order whose payment sheet is open, or whose result is being confirmed.
  final String? payingId;

  /// The orders still in progress, for the tracker at the top.
  List<CustomerOrder> get live =>
      orders.where((order) => order.status.isLive).toList();

  /// Everything finished, for the history list.
  List<CustomerOrder> get past =>
      orders.where((order) => !order.status.isLive).toList();

  bool get isEmpty => status == OrdersStatus.ready && orders.isEmpty;

  OrdersState copyWith({
    OrdersStatus? status,
    List<CustomerOrder>? orders,
    ApiFailure? failure,
    String? cancellingId,
    String? payingId,
    bool clearFailure = false,
    bool clearCancelling = false,
    bool clearPaying = false,
  }) {
    return OrdersState(
      status: status ?? this.status,
      orders: orders ?? this.orders,
      failure: clearFailure ? null : (failure ?? this.failure),
      cancellingId: clearCancelling
          ? null
          : (cancellingId ?? this.cancellingId),
      payingId: clearPaying ? null : (payingId ?? this.payingId),
    );
  }

  @override
  List<Object?> get props => [status, orders, failure, cancellingId, payingId];
}

/// The customer's order history, and the live tracker built from it.
///
/// One request feeds both: an order is "live" or "past" according to its own
/// status, so splitting them in the state costs nothing and asking the API twice
/// would only invite the two lists to disagree.
class OrdersCubit extends Cubit<OrdersState> {
  OrdersCubit({required OrderRepository repository, PaymentFlow? paymentFlow})
    : _repository = repository,
      _payments = paymentFlow ?? PaymentFlow(repository: repository),
      super(const OrdersState());

  final OrderRepository _repository;
  final PaymentFlow _payments;

  /// Drops everything on sign-out.
  ///
  /// Order history belongs to one account. Leaving it in place means the next
  /// person to sign in on this phone sees somebody else's orders -- with their
  /// address and phone number on the receipt -- until the first refresh lands.
  void clear() => emit(const OrdersState(status: OrdersStatus.ready));

  /// Loads, or reloads after a failure.
  ///
  /// [silent] keeps the current list on screen while refetching, so
  /// pull-to-refresh — and the automatic refresh below — never blank a tracker
  /// the user is watching.
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      emit(state.copyWith(status: OrdersStatus.loading, clearFailure: true));
    }

    try {
      emit(
        state.copyWith(
          status: OrdersStatus.ready,
          orders: await _repository.myOrders(),
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          status: silent && state.orders.isNotEmpty
              ? OrdersStatus.ready
              : OrdersStatus.failure,
          failure: failure,
        ),
      );
    }
  }

  /// Fetches one order in full, for the receipt.
  ///
  /// The list endpoint documents that it leaves lines out — `item_count` is all
  /// a row gets — so a receipt has to ask for the order itself. The fetched copy
  /// replaces the summary in state, which also picks up the server's `can_cancel`
  /// verdict for the tracker.
  ///
  /// Returns null if the fetch failed; the caller then shows what it already has
  /// rather than an error over a receipt the user can mostly read.
  Future<CustomerOrder?> loadDetail(String id) async {
    try {
      final order = await _repository.orderById(id);
      emit(
        state.copyWith(
          orders: [
            for (final existing in state.orders)
              if (existing.id == id) order else existing,
          ],
        ),
      );
      return order;
    } on ApiFailure {
      return null;
    }
  }

  /// Opens the payment page for an unpaid card order, then adopts whatever the
  /// server says afterwards.
  ///
  /// Covers all three ways an order can end up here unpaid: the customer closed
  /// the sheet without paying, the card was declined, or Worldpay was
  /// unreachable when the order was placed and it never got a page at all.
  ///
  /// Returns a message to show, or null when the payment went through.
  Future<String?> payOrder(String id) async {
    if (state.payingId != null) return null;
    final order = state.orders.firstWhere(
      (o) => o.id == id,
      orElse: () => throw StateError('No order $id to pay for.'),
    );
    if (!order.needsPayment) return null;

    emit(state.copyWith(payingId: id));
    try {
      final settled = await _payments.payFor(order);
      emit(
        state.copyWith(
          orders: [
            for (final existing in state.orders)
              if (existing.id == id) settled else existing,
          ],
          clearPaying: true,
        ),
      );
      return switch (settled.paymentStatus) {
        CustomerPaymentStatus.paid => null,
        CustomerPaymentStatus.failed =>
          'Your card was declined. You can try again.',
        // Placed and unpaid: either the sheet was closed without paying, or the
        // webhook is still in transit. Both are honestly "not yet".
        _ =>
          "We're still confirming your payment. We'll update your order as "
              'soon as it clears.',
      };
    } on ApiFailure catch (failure) {
      emit(state.copyWith(clearPaying: true));
      return failure.message;
    }
  }

  /// Cancels an order and adopts whatever the server says its status now is.
  ///
  /// Returns an error message to show, or null on success. The state is never
  /// updated optimistically: cancelling races the kitchen accepting the order,
  /// and showing "Cancelled" for an order that is already being cooked would be
  /// the one lie this screen must not tell.
  Future<String?> cancelOrder(String id, {String? reason}) async {
    if (state.cancellingId != null) return null;
    emit(state.copyWith(cancellingId: id));

    try {
      final updated = await _repository.cancel(id, reason: reason);
      emit(
        state.copyWith(
          orders: [
            for (final order in state.orders)
              if (order.id == id) updated else order,
          ],
          clearCancelling: true,
        ),
      );
      return null;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(clearCancelling: true));
      return failure.message;
    }
  }
}
