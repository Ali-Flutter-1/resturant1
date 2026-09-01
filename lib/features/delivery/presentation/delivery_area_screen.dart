import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/api_error_view.dart';
import '../../../shared/widgets/page_body.dart';
import '../../../shared/widgets/skeleton.dart';
import '../domain/delivery_zone_repository.dart';
import 'delivery_zones_cubit.dart';
import 'delivery_zones_map.dart';

/// Where we deliver, and what each area costs.
///
/// Public: a customer can read this before signing in, which is the right way
/// round -- finding out we do not deliver to you *after* making an account is
/// the wrong order of events.
class DeliveryAreaScreen extends StatelessWidget {
  const DeliveryAreaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          DeliveryZonesCubit(repository: context.read<DeliveryZoneRepository>())
            ..load(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Delivery areas')),
        body: BlocBuilder<DeliveryZonesCubit, DeliveryZonesState>(
          builder: (context, state) {
            final cubit = context.read<DeliveryZonesCubit>();

            return switch (state.status) {
              ZonesStatus.loading => const MessageListSkeleton(rows: 2),
              ZonesStatus.failure when state.failure != null => ApiErrorView(
                failure: state.failure!,
                onRetry: cubit.load,
              ),
              _ => ListView(
                padding: pagePadding(
                  context,
                  top: AppSpacing.x4,
                  bottom: AppSpacing.x8 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  if (state.isEmpty)
                    Text(
                      'Delivery areas are being set up. Ask the restaurant '
                      'whether they can deliver to you.',
                      style: context.texts.bodyMedium?.copyWith(
                        color: context.surfaces.inkMuted,
                      ),
                    )
                  else
                    DeliveryZonesMap(zones: state.zones, height: 320),
                ],
              ),
            };
          },
        ),
      ),
    );
  }
}
