import '../../../core/network/page_data.dart';
import 'admin_order.dart';

/// The staff and admin order queue.
///
/// Every route here accepts both roles — the guide is explicit that staff and
/// admin have the same order permissions, and that a customer gets 403.
abstract interface class AdminOrderRepository {
  /// Newest first, paginated.
  ///
  /// [openOnly] is the kitchen queue: everything not yet completed, cancelled or
  /// rejected.
  Future<PageData<AdminOrder>> orders({
    int page = 1,
    int pageSize = 20,
    OrderStatus? status,
    FulfilmentType? fulfilment,
    bool openOnly = false,
  });

  Future<OrderStats> stats();

  /// One order in full, including its lines and the customer's contact details.
  Future<AdminOrder> orderById(String id);

  /// Takes an order the restaurant has decided to accept.
  ///
  /// Only valid while it is `pending_approval`; anything else answers
  /// `ORDER_NOT_PENDING_APPROVAL` and the screen should reload, because another
  /// member of staff has almost certainly just decided it.
  ///
  /// A cash order becomes `placed` and goes to the kitchen. A card order
  /// becomes `awaiting_payment` and the customer is notified that they can pay.
  /// Either way the backend does the notifying.
  Future<AdminOrder> approve(String id);

  /// Refuses an order before anything is charged.
  ///
  /// [reason] is shown to the customer, so it is required rather than optional
  /// -- "rejected" with no explanation is the version of this that generates a
  /// phone call.
  Future<AdminOrder> decline(String id, {required String reason});

  /// Moves an order exactly one legal step.
  ///
  /// Not the way out of `pending_approval` -- use [approve] or [decline] for
  /// that.
  ///
  /// [note] becomes the cancellation reason when the new status is `cancelled`
  /// or `rejected`. Returns the updated order so the screen shows what the
  /// server did rather than what it hoped for.
  Future<AdminOrder> updateStatus(
    String id, {
    required OrderStatus status,
    String? note,
  });
}
