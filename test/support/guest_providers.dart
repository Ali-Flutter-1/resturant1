import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:practice/features/booking/domain/reservation_repository.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/delivery/domain/delivery_zone_repository.dart';
import 'package:practice/features/menu/domain/menu_repository.dart';
import 'package:practice/features/notifications/domain/notification_repository.dart';
import 'package:practice/features/orders/domain/order_repository.dart';
import 'package:practice/features/orders/presentation/orders_cubit.dart';

import 'fake_delivery_zone_repository.dart';
import 'fake_menu_repository.dart';
import 'fake_notification_repository.dart';
import 'fake_order_repository.dart';
import 'fake_reservation_repository.dart';

/// What the customer shell needs from the tree.
///
/// A guest now gets that shell rather than a login screen, so any test pumping
/// the app from the top has to supply what it reads -- the same set `main()`
/// provides, with fakes.
Widget guestProviders(Widget child) {
  final orders = FakeOrderRepository();

  return MultiRepositoryProvider(
    providers: [
      RepositoryProvider<MenuRepository>(create: (_) => FakeMenuRepository()),
      RepositoryProvider<OrderRepository>.value(value: orders),
      RepositoryProvider<DeliveryZoneRepository>(
        create: (_) => FakeDeliveryZoneRepository(),
      ),
      RepositoryProvider<ReservationRepository>(
        create: (_) => FakeReservationRepository(),
      ),
      RepositoryProvider<NotificationRepository>(
        create: (_) => FakeNotificationRepository(),
      ),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => CartCubit()),
        BlocProvider(create: (_) => OrdersCubit(repository: orders)),
      ],
      child: child,
    ),
  );
}
