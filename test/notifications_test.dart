import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/auth/auth_cubit.dart';
import 'package:practice/features/notifications/data/push_coordinator.dart';
import 'package:practice/features/notifications/domain/app_notification.dart';
import 'package:practice/features/notifications/domain/notification_repository.dart';
import 'package:practice/features/notifications/domain/push_service.dart';
import 'package:practice/features/notifications/presentation/notification_routing.dart';
import 'package:practice/features/notifications/presentation/notifications_cubit.dart';
import 'package:practice/features/notifications/presentation/notifications_screen.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_notification_repository.dart';

/// Notifications.
///
/// The expensive mistake here is trusting a push. A payload is untrusted input
/// that arrived from the network via the operating system: it can be malformed,
/// it can be for an event this build has never heard of, and its title was
/// written when the event happened rather than when it was tapped. So the
/// routing is a closed set, the fallback is always the inbox, and the inbox —
/// not the notification tray — is what the badge counts.
void main() {
  late FakeNotificationRepository repository;

  setUp(() {
    repository = FakeNotificationRepository(
      items: [
        FakeNotificationRepository.item(id: 'n1'),
        FakeNotificationRepository.item(
          id: 'n2',
          event: 'booking_confirmed',
          entityType: 'reservation',
          entityId: 'b1',
          title: 'Booking confirmed',
          readAt: DateTime(2026, 8, 15, 12, 30),
        ),
      ],
    );
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 2000);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  group('the payload contract', () {
    NotificationPayload parse(Map<String, dynamic> data) =>
        NotificationPayload.fromData(data);

    test('a customer order event opens the customer order screen', () {
      final payload = parse(const {
        'schema_version': '1',
        'type': 'order_ready',
        'entity_type': 'order',
        'entity_id': 'o1',
        'reference': 'ABCD-1234',
        'route': '/orders/o1',
      });
      expect(payload.target, NotificationTarget.customerOrder);
      expect(payload.entityId, 'o1');
    });

    test('an admin event opens the admin screen, not the customer one', () {
      // The two endpoints carry different fields, and a customer calling the
      // admin one gets a 403.
      expect(
        parse(const {
          'schema_version': '1',
          'type': 'order_placed_admin',
          'entity_type': 'order',
          'entity_id': 'o1',
        }).target,
        NotificationTarget.adminOrder,
      );
      expect(
        parse(const {
          'schema_version': '1',
          'type': 'booking_requested_admin',
          'entity_type': 'reservation',
          'entity_id': 'b1',
        }).target,
        NotificationTarget.adminBooking,
      );
    });

    test('an unknown event type falls back to the inbox', () {
      // A backend that adds an event must not be able to crash an older app.
      final payload = parse(const {
        'schema_version': '1',
        'type': 'loyalty_points_awarded',
        'entity_type': 'order',
        'entity_id': 'o1',
      });
      expect(payload.event, NotificationEvent.unknown);
      expect(payload.target, NotificationTarget.inbox);
    });

    test('an unknown schema version falls back to the inbox', () {
      // Version 2 may mean something entirely different by these field names.
      expect(
        parse(const {
          'schema_version': '2',
          'type': 'order_ready',
          'entity_type': 'order',
          'entity_id': 'o1',
        }).target,
        NotificationTarget.inbox,
      );
    });

    test('a missing entity id falls back to the inbox', () {
      expect(
        parse(const {
          'schema_version': '1',
          'type': 'order_ready',
          'entity_type': 'order',
        }).target,
        NotificationTarget.inbox,
      );
      expect(
        parse(const {
          'schema_version': '1',
          'type': 'order_ready',
          'entity_type': 'order',
          'entity_id': '   ',
        }).target,
        NotificationTarget.inbox,
      );
    });

    test('an event and entity that disagree fall back to the inbox', () {
      // A booking event carrying an order id is a payload nobody should act on
      // — following it would fetch the wrong record and show it confidently.
      expect(
        parse(const {
          'schema_version': '1',
          'type': 'booking_confirmed',
          'entity_type': 'order',
          'entity_id': 'o1',
        }).target,
        NotificationTarget.inbox,
      );
    });

    test('the route string is never what gets followed', () {
      // The guide's rule: do not navigate blindly. The route is a diagnostic
      // hint, and a hostile or malformed one must not steer the app.
      final payload = parse(const {
        'schema_version': '1',
        'type': 'order_ready',
        'entity_type': 'order',
        'entity_id': 'o1',
        'route': '/admin/users/../../somewhere-else',
      });
      // Routed from the type and the entity, so the route field cannot matter.
      expect(payload.target, NotificationTarget.customerOrder);
    });

    test('an inbox row routes from its own columns, not just the blob', () {
      // A row whose `data` blob is missing still has to route.
      final item = AppNotification.fromJson(const {
        'id': 'n9',
        'event_type': 'order_out_for_delivery',
        'entity_type': 'order',
        'entity_id': 'o9',
        'title': 'On its way',
        'body': '',
      });
      expect(item.payload.target, NotificationTarget.customerOrder);
      expect(item.payload.entityId, 'o9');
      expect(item.isUnread, isTrue);
    });
  });

  group('the inbox', () {
    test('loads rows and the badge together', () async {
      final cubit = NotificationsCubit(repository: repository);
      await cubit.load();

      expect(cubit.state.status, InboxStatus.ready);
      expect(cubit.state.items, hasLength(2));
      // Counted by the server, not by what happens to be on this page.
      expect(cubit.state.unread, 1);
      await cubit.close();
    });

    test('opening one marks it read straight away', () async {
      final cubit = NotificationsCubit(repository: repository);
      await cubit.load();

      await cubit.markRead(cubit.state.items.first);
      expect(repository.markedRead, ['n1']);
      expect(cubit.state.items.first.isUnread, isFalse);
      expect(cubit.state.unread, 0);
      await cubit.close();
    });

    test('an already-read row is not marked again', () async {
      final cubit = NotificationsCubit(repository: repository);
      await cubit.load();

      await cubit.markRead(cubit.state.items.last);
      expect(repository.markedRead, isEmpty);
      await cubit.close();
    });

    test('a refused mark puts the row back', () async {
      final cubit = NotificationsCubit(repository: repository);
      await cubit.load();
      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.invalid,
        message: 'Not found.',
        code: NotificationErrorCodes.notFound,
      );

      await cubit.markRead(cubit.state.items.first);
      // Reloaded from the server, so the optimistic change does not stick.
      expect(cubit.state.items.first.isUnread, isTrue);
      expect(cubit.state.unread, 1);
      await cubit.close();
    });

    test(
      'marking all read does nothing when there is nothing unread',
      () async {
        final cubit = NotificationsCubit(repository: repository);
        await cubit.load();
        await cubit.markAllRead();
        expect(repository.markAllCalls, 1);

        await cubit.markAllRead();
        // Already zero, so no second request.
        expect(repository.markAllCalls, 1);
        await cubit.close();
      },
    );

    test('the badge can be refreshed on its own', () async {
      final cubit = NotificationsCubit(repository: repository);
      await cubit.refreshBadge();

      expect(cubit.state.unread, 1);
      // No list request: this is what a foreground push and startup call.
      expect(repository.inboxCalls, 0);
      await cubit.close();
    });

    test('a failed badge refresh is silent', () async {
      final cubit = NotificationsCubit(repository: repository);
      repository.failure = ApiFailure.offline;
      await cubit.refreshBadge();

      expect(cubit.state.failure, isNull);
      await cubit.close();
    });
  });

  group('device registration', () {
    test('nothing is registered while push is unavailable', () async {
      // The state of this build until the Firebase config files are added.
      final coordinator = PushCoordinator(
        repository: repository,
        push: const NoPushService(),
      );
      expect(await coordinator.register(), isFalse);
      expect(repository.lastRegistration, isNull);
      await coordinator.dispose();
    });

    test('signing out removes the device before the logout call', () async {
      // The order is the whole point: `logout` invalidates the token, and the
      // removal needs a valid one. Get it wrong and the next person to sign in
      // on this phone receives the previous user's alerts.
      final auth = FakeAuthRepository(user: AuthFixtures.customer);
      final calls = <String>[];
      final cubit = AuthCubit(
        repository: auth,
        initialUser: AuthFixtures.customer,
      )..onSigningOut = () async => calls.add('remove-device');

      await cubit.signOut();

      expect(calls, ['remove-device']);
      expect(auth.logoutCalls, 1);
    });

    test('a failed removal still signs the user out', () async {
      final auth = FakeAuthRepository(user: AuthFixtures.customer);
      final cubit = AuthCubit(
        repository: auth,
        initialUser: AuthFixtures.customer,
      )..onSigningOut = () async => throw Exception('offline');

      await cubit.signOut();

      // Leaving somebody signed in for the sake of tidy bookkeeping is the
      // worse failure, and the removal is idempotent server-side.
      expect(cubit.state.isSignedIn, isFalse);
      expect(auth.logoutCalls, 1);
    });
  });

  group('the inbox screen', () {
    Widget wrap() => MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AuthFixtures.cubit(AuthFixtures.customer)),
        // One cubit, app-level — the bell and this screen share it, which is
        // what makes "mark all read" move the badge.
        BlocProvider(create: (_) => NotificationsCubit(repository: repository)),
      ],
      child: RepositoryProvider<NotificationRepository>.value(
        value: repository,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const NotificationsScreen(),
        ),
      ),
    );

    testWidgets('lists what arrived, unread first-class', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Order ready'), findsOneWidget);
      expect(find.text('Booking confirmed'), findsOneWidget);
    });

    testWidgets('tapping a row marks it read', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Order ready'));
      await tester.pumpAndSettle();

      expect(repository.markedRead, ['n1']);
    });

    testWidgets('mark all read is offered only when something is unread', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // Offered while something is unread, alongside the count.
      expect(find.text('1 unread'), findsOneWidget);
      expect(find.text('Mark all read'), findsOneWidget);

      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();

      expect(repository.markAllCalls, 1);
      // Gone once there is nothing to do, rather than sitting there disabled
      // with no explanation — and the header says why.
      expect(find.text('Mark all read'), findsNothing);
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('an empty inbox says so', (tester) async {
      repository = FakeNotificationRepository();
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Nothing yet'), findsOneWidget);
    });

    testWidgets('the bell draws nothing without a repository', (tester) async {
      // A bell that cannot count anything and opens an inbox that cannot load
      // is a decoration shaped like a control.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            appBar: AppBar(actions: [NotificationBell(onOpen: () {})]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No cubit in scope, so no bell.
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('tap-through routing', () {
    testWidgets('the shell supplies the destination, not the inbox', (
      tester,
    ) async {
      NotificationPayload? followed;

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(
              create: (_) => AuthFixtures.cubit(AuthFixtures.customer),
            ),
            BlocProvider(
              create: (_) => NotificationsCubit(repository: repository),
            ),
          ],
          child: RepositoryProvider<NotificationRepository>.value(
            value: repository,
            child: MaterialApp(
              theme: AppTheme.light,
              home: NotificationRouting(
                onFollow: (_, payload) => followed = payload,
                child: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => openNotifications(context),
                      child: const Text('open inbox'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open inbox'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Order ready'));
      await tester.pumpAndSettle();

      // The payload reached the shell, validated — the inbox never navigates on
      // its own.
      expect(followed, isNotNull);
      expect(followed!.target, NotificationTarget.customerOrder);
      expect(followed!.entityId, 'o1');
    });

    testWidgets('no routing in scope still marks the row read', (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(
              create: (_) => AuthFixtures.cubit(AuthFixtures.customer),
            ),
            BlocProvider(
              create: (_) => NotificationsCubit(repository: repository),
            ),
          ],
          child: RepositoryProvider<NotificationRepository>.value(
            value: repository,
            child: MaterialApp(
              theme: AppTheme.light,
              home: const NotificationsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Order ready'));
      await tester.pumpAndSettle();

      // Read-only is a legitimate state, not a dead tap.
      expect(repository.markedRead, ['n1']);
    });
  });

  group('the bell and the inbox are one thing', () {
    testWidgets('marking all read moves the badge immediately', (tester) async {
      final inbox = NotificationsCubit(repository: repository);
      addTearDown(inbox.close);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(
              create: (_) => AuthFixtures.cubit(AuthFixtures.customer),
            ),
            BlocProvider.value(value: inbox),
          ],
          child: RepositoryProvider<NotificationRepository>.value(
            value: repository,
            child: MaterialApp(
              theme: AppTheme.light,
              home: Scaffold(
                appBar: AppBar(actions: [NotificationBell(onOpen: () {})]),
                body: const NotificationsScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The badge and the list are reading the same state.
      expect(find.text('1'), findsWidgets);
      expect(find.text('1 unread'), findsOneWidget);

      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();

      // This is the bug: the bell used to build its own cubit, so the badge
      // stayed on the old count until it happened to be rebuilt.
      expect(inbox.state.unread, 0);
      expect(find.text('All caught up'), findsOneWidget);
      final badge = tester.widget<AnimatedScale>(
        find.byType(AnimatedScale).first,
      );
      expect(badge.scale, 0);
    });

    test('signing out empties the inbox for the next account', () async {
      final inbox = NotificationsCubit(repository: repository);
      await inbox.load();
      expect(inbox.state.items, isNotEmpty);
      expect(inbox.state.unread, 1);

      inbox.clear();

      // The next person to sign in on this phone must not see the previous
      // user's unread count, even briefly.
      expect(inbox.state.items, isEmpty);
      expect(inbox.state.unread, 0);
      await inbox.close();
    });
  });

  group('every event lands somewhere true', () {
    NotificationTarget targetOf(String type, String entity) =>
        NotificationPayload.fromData({
          'schema_version': '1',
          'type': type,
          'entity_type': entity,
          'entity_id': 'abc',
        }).target;

    test('a customer event goes to the customer screen, staff to theirs', () {
      // Sending a customer to a kitchen screen -- or a waiter to a receipt --
      // is a wrong screen, and a wrong screen is worse than the inbox.
      for (final type in [
        'order_preparing',
        'order_ready',
        'order_out_for_delivery',
        'order_completed',
        'order_rejected',
        'order_cancelled',
      ]) {
        expect(
          targetOf(type, 'order'),
          NotificationTarget.customerOrder,
          reason: type,
        );
      }

      for (final type in ['order_placed_admin', 'order_cancelled_admin']) {
        expect(
          targetOf(type, 'order'),
          NotificationTarget.adminOrder,
          reason: type,
        );
      }

      for (final type in [
        'booking_confirmed',
        'booking_rejected',
        'booking_cancelled',
        'booking_expired',
      ]) {
        expect(
          targetOf(type, 'reservation'),
          NotificationTarget.customerBooking,
          reason: type,
        );
      }
    });

    test('a payload that contradicts itself goes to the inbox', () {
      // A booking event carrying an order id is a payload nobody should act
      // on: one of the two fields is wrong and there is no telling which.
      expect(targetOf('order_ready', 'reservation'), NotificationTarget.inbox);
      expect(targetOf('booking_confirmed', 'order'), NotificationTarget.inbox);
    });

    test('a future schema is not guessed at', () {
      // Version 2 may use the same field names for different things. Acting on
      // it would be acting on a guess.
      expect(
        NotificationPayload.fromData({
          'schema_version': '2',
          'type': 'order_ready',
          'entity_type': 'order',
          'entity_id': 'abc',
        }).target,
        NotificationTarget.inbox,
      );
    });

    test('a missing id has nothing to open', () {
      for (final id in [null, '', '   ']) {
        expect(
          NotificationPayload.fromData({
            'schema_version': '1',
            'type': 'order_ready',
            'entity_type': 'order',
            'entity_id': id,
          }).target,
          NotificationTarget.inbox,
          reason: '$id',
        );
      }
    });

    test('an event this build has never heard of goes to the inbox', () {
      expect(targetOf('order_teleported', 'order'), NotificationTarget.inbox);
    });
  });
}
