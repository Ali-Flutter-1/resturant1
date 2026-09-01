import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/api_failure.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';

enum ZonesStatus { loading, ready, failure }

class DeliveryZonesState extends Equatable {
  const DeliveryZonesState({
    this.status = ZonesStatus.loading,
    this.zones = const [],
    this.failure,
  });

  final ZonesStatus status;

  /// Cheapest first, as the server orders them.
  final List<DeliveryZone> zones;

  final ApiFailure? failure;

  /// True once the server has answered and there is nothing to draw.
  ///
  /// A real state, not an error: with no active zones the backend falls back to
  /// flat pricing and stops asking for postcodes at all, so a map of nothing is
  /// the honest picture.
  bool get isEmpty => status == ZonesStatus.ready && zones.isEmpty;

  @override
  List<Object?> get props => [status, zones, failure];
}

/// The delivery map's data.
class DeliveryZonesCubit extends Cubit<DeliveryZonesState> {
  DeliveryZonesCubit({required DeliveryZoneRepository repository})
    : _repository = repository,
      super(const DeliveryZonesState());

  final DeliveryZoneRepository _repository;

  Future<void> load() async {
    emit(const DeliveryZonesState());
    try {
      emit(
        DeliveryZonesState(
          status: ZonesStatus.ready,
          zones: await _repository.zones(),
        ),
      );
    } on ApiFailure catch (failure) {
      emit(DeliveryZonesState(status: ZonesStatus.failure, failure: failure));
    }
  }
}
