import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';

enum AdminZonesStatus { loading, ready, failure }

class AdminZonesState extends Equatable {
  const AdminZonesState({
    this.status = AdminZonesStatus.loading,
    this.zones = const [],
    this.failure,
    this.busyId,
  });

  final AdminZonesStatus status;

  /// Every zone, live and paused.
  final List<AdminDeliveryZone> zones;

  final ApiFailure? failure;

  /// The zone whose change is in flight, so only that row shows a spinner.
  final String? busyId;

  bool get isEmpty => status == AdminZonesStatus.ready && zones.isEmpty;

  /// True when no zone is switched on.
  ///
  /// Worth saying out loud on the screen: with no active zones the backend
  /// falls back to flat pricing and stops checking postcodes altogether, which
  /// is a bigger change than "the map looks empty".
  bool get noneActive =>
      status == AdminZonesStatus.ready &&
      zones.isNotEmpty &&
      zones.every((zone) => !zone.isActive);

  AdminZonesState copyWith({
    AdminZonesStatus? status,
    List<AdminDeliveryZone>? zones,
    ApiFailure? failure,
    String? busyId,
    bool clearFailure = false,
    bool clearBusy = false,
  }) {
    return AdminZonesState(
      status: status ?? this.status,
      zones: zones ?? this.zones,
      failure: clearFailure ? null : (failure ?? this.failure),
      busyId: clearBusy ? null : (busyId ?? this.busyId),
    );
  }

  @override
  List<Object?> get props => [status, zones, failure, busyId];
}

/// The delivery areas, as an admin manages them.
class AdminZonesCubit extends Cubit<AdminZonesState> {
  AdminZonesCubit({required AdminDeliveryZoneRepository repository})
    : _repository = repository,
      super(const AdminZonesState());

  final AdminDeliveryZoneRepository _repository;

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      emit(
        state.copyWith(status: AdminZonesStatus.loading, clearFailure: true),
      );
    }

    try {
      emit(
        state.copyWith(
          status: AdminZonesStatus.ready,
          zones: await _repository.zones(),
          clearFailure: true,
        ),
      );
    } on ApiFailure catch (failure) {
      emit(
        state.copyWith(
          // A failed refresh keeps what is on screen: these are prices, and
          // blanking them reads as "there are no zones", which would be a very
          // different thing to believe.
          status: silent && state.zones.isNotEmpty
              ? AdminZonesStatus.ready
              : AdminZonesStatus.failure,
          failure: failure,
        ),
      );
    }
  }

  /// Pauses or resumes one zone.
  ///
  /// Returns a message to show, or null on success.
  Future<String?> setActive(String id, bool isActive) async {
    if (state.busyId != null) return null;
    emit(state.copyWith(busyId: id));

    try {
      final updated = await _repository.update(id, isActive: isActive);
      emit(
        state.copyWith(
          zones: [
            for (final zone in state.zones)
              if (zone.id == id) updated else zone,
          ],
          clearBusy: true,
        ),
      );
      return null;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(clearBusy: true));
      return failure.message;
    }
  }

  /// Removes a zone for good.
  Future<String?> remove(String id) async {
    if (state.busyId != null) return null;
    emit(state.copyWith(busyId: id));

    try {
      await _repository.delete(id);
      emit(
        state.copyWith(
          zones: [
            for (final zone in state.zones)
              if (zone.id != id) zone,
          ],
          clearBusy: true,
        ),
      );
      return null;
    } on ApiFailure catch (failure) {
      emit(state.copyWith(clearBusy: true));
      return failure.message;
    }
  }

  /// Adopts a zone that the editor just created or changed.
  void adopt(AdminDeliveryZone zone) {
    final known = state.zones.any((existing) => existing.id == zone.id);
    emit(
      state.copyWith(
        zones: known
            ? [
                for (final existing in state.zones)
                  if (existing.id == zone.id) zone else existing,
              ]
            : [...state.zones, zone],
      ),
    );
  }
}
