import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../domain/reservation.dart';
import '../domain/reservation_repository.dart';

enum AdminBookingsStatus { loading, ready, failure }

class AdminBookingsState extends Equatable {
  const AdminBookingsState({
    required this.date,
    this.status = AdminBookingsStatus.loading,
    this.bookings = const [],
    this.stats = const ReservationStats(),
    this.filter,
    this.detail,
    this.failure,
    this.busyIds = const {},
    this.page = 1,
    this.totalPages = 0,
    this.loadingMore = false,
  });

  /// The day's sheet. Null means every upcoming booking rather than one date.
  final DateTime? date;

  final AdminBookingsStatus status;
  final List<ReservationSummary> bookings;

  /// The last page fetched and how many there are.
  final int page;
  final int totalPages;
  final bool loadingMore;

  /// Whether another page of bookings exists.
  bool get hasMore => page < totalPages;
  final ReservationStats stats;

  /// Null shows every status.
  final ReservationStatus? filter;

  /// The booking open in the sheet, in full — a summary carries no contact
  /// details, requests or reason.
  final ReservationDetail? detail;

  final ApiFailure? failure;

  /// Bookings with a write in flight, so only that row is disabled.
  final Set<String> busyIds;

  AdminBookingsState copyWith({
    DateTime? date,
    AdminBookingsStatus? status,
    List<ReservationSummary>? bookings,
    ReservationStats? stats,
    ReservationStatus? filter,
    ReservationDetail? detail,
    ApiFailure? failure,
    Set<String>? busyIds,
    int? page,
    int? totalPages,
    bool? loadingMore,
    bool clearDate = false,
    bool clearFilter = false,
    bool clearFailure = false,
    bool clearDetail = false,
  }) {
    return AdminBookingsState(
      date: clearDate ? null : (date ?? this.date),
      status: status ?? this.status,
      bookings: bookings ?? this.bookings,
      page: page ?? this.page,
      totalPages: totalPages ?? this.totalPages,
      loadingMore: loadingMore ?? this.loadingMore,
      stats: stats ?? this.stats,
      filter: clearFilter ? null : (filter ?? this.filter),
      detail: clearDetail ? null : (detail ?? this.detail),
      failure: clearFailure ? null : (failure ?? this.failure),
      busyIds: busyIds ?? this.busyIds,
    );
  }

  @override
  List<Object?> get props => [
    page,
    totalPages,
    loadingMore,
    date,
    status,
    bookings,
    stats,
    filter,
    detail,
    failure,
    busyIds,
  ];
}

/// The staff booking sheet.
///
/// Mirrors the kitchen queue: a filter, a stats strip, and a detail sheet that
/// offers only the moves the current status allows. The two rules that matter:
///
///  * **Adopt what the server returned.** Every mutation answers with the whole
///    booking; the row takes that rather than assuming the move stuck.
///  * **A 409 is expected, not exceptional.** Another device can act first, so
///    an invalid transition re-reads instead of showing a dead end.
class AdminBookingsCubit extends Cubit<AdminBookingsState> {
  AdminBookingsCubit({
    required ReservationRepository repository,
    DateTime? today,
  }) : _repository = repository,
       _today = today,
       super(
         const AdminBookingsState(
           date: null,
           // Pending first: an unanswered request is holding a table, and it is
           // the only thing on this screen with a clock running on it.
           filter: ReservationStatus.pending,
         ),
       );

  final ReservationRepository _repository;
  final DateTime? _today;

  DateTime get today {
    final now = _today ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      emit(
        state.copyWith(status: AdminBookingsStatus.loading, clearFailure: true),
      );
    }

    try {
      // Awaited in turn and emitted once, so the sheet and the counters above
      // it are never a refresh out of step. Not `Future.wait`: its list form
      // loses both types and needs the casts that used to be here, and its
      // record form wraps a failure in a `ParallelWaitError` the catch below
      // would not recognise.
      final page = await _repository.adminReservations(
        date: state.date,
        status: state.filter,
      );
      final stats = await _repository.adminStats();

      emit(
        state.copyWith(
          status: AdminBookingsStatus.ready,
          bookings: page.items,
          page: page.page,
          totalPages: page.totalPages,
          loadingMore: false,
          stats: stats,
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          status: silent && state.bookings.isNotEmpty
              ? AdminBookingsStatus.ready
              : AdminBookingsStatus.failure,
          failure: failure,
        ),
      );
    }
  }

  /// Fetches the next page of the sheet and appends it.
  Future<void> loadMore() async {
    if (!state.hasMore || state.loadingMore) return;
    emit(state.copyWith(loadingMore: true, clearFailure: true));

    try {
      final next = await _repository.adminReservations(
        page: state.page + 1,
        date: state.date,
        status: state.filter,
      );
      emit(
        state.copyWith(
          bookings: [...state.bookings, ...next.items],
          page: next.page,
          totalPages: next.totalPages,
          loadingMore: false,
        ),
      );
    } on ApiFailure catch (failure) {
      // The sheet already on screen stays; only the footer reports it.
      emit(state.copyWith(loadingMore: false, failure: failure));
    }
  }

  Future<void> setFilter(ReservationStatus? status) async {
    if (status == state.filter) return;
    // Page one: a different filter is a different list, not more of this one.
    emit(
      (status == null
              ? state.copyWith(clearFilter: true)
              : state.copyWith(filter: status))
          .copyWith(page: 1, totalPages: 0),
    );
    await load(silent: state.bookings.isNotEmpty);
  }

  Future<void> setDate(DateTime? date) async {
    final day = date == null ? null : DateTime(date.year, date.month, date.day);
    if (day == state.date) return;
    emit(
      day == null ? state.copyWith(clearDate: true) : state.copyWith(date: day),
    );
    await load(silent: state.bookings.isNotEmpty);
  }

  /// Opens one booking in full.
  Future<void> open(String id) async {
    emit(state.copyWith(clearDetail: true, clearFailure: true));
    try {
      emit(state.copyWith(detail: await _repository.adminReservation(id)));
    } on ApiFailure catch (failure) {
      emit(state.copyWith(failure: failure));
    }
  }

  void closeDetail() => emit(state.copyWith(clearDetail: true));

  /// Moves a booking on.
  ///
  /// Returns an error message to show, or null on success.
  Future<String?> updateStatus(
    String id, {
    required ReservationStatus status,
    String? note,
  }) async {
    if (state.busyIds.contains(id)) return null;
    emit(state.copyWith(busyIds: {...state.busyIds, id}));

    try {
      final updated = await _repository.updateStatus(
        id,
        status: status,
        note: note,
      );
      emit(
        state.copyWith(
          detail: updated,
          busyIds: {...state.busyIds}..remove(id),
        ),
      );
      // The row's status and every counter moved, and the filter may no longer
      // match — an approved request leaves the pending list.
      await load(silent: true);
      return null;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(busyIds: {...state.busyIds}..remove(id)));
      // Another device got there first. Re-reading is what makes the buttons
      // agree with reality rather than offering the same refused move again.
      if (BookingErrorCodes.meansReloadBooking(failure.code)) {
        await open(id);
        await load(silent: true);
      }
      return failure.message;
    }
  }
}
