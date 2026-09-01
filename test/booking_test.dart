import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/booking/domain/reservation.dart';
import 'package:practice/features/booking/domain/reservation_repository.dart';
import 'package:practice/features/booking/presentation/admin_bookings_cubit.dart';
import 'package:practice/features/booking/presentation/book_table_screen.dart';
import 'package:practice/features/booking/presentation/booking_cubit.dart';
import 'package:practice/features/booking/presentation/my_bookings_cubit.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_reservation_repository.dart';

/// Table bookings.
///
/// The expensive mistake in this feature is one sentence from the guide: **201
/// means the request was created and is awaiting approval, never that a table is
/// confirmed**. Everything else follows — the pending state, the countdown, the
/// customer's cancel window closing on approval. Each has a test.
void main() {
  late FakeReservationRepository repository;

  setUp(() {
    repository = FakeReservationRepository();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 2600);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  group('the reservation model', () {
    test('an unknown status does not take the screen down', () {
      // The guide's own model throws here. That is the wrong trade for a phone:
      // a backend that gains a state would break the whole history list, when
      // showing one row as in progress costs nothing.
      expect(ReservationStatus.fromApi('brand_new'), ReservationStatus.pending);
      expect(ReservationStatus.fromApi(null), ReservationStatus.pending);
      expect(ReservationStatus.fromApi('no_show'), ReservationStatus.noShow);
      expect(ReservationStatus.noShow.apiValue, 'no_show');
    });

    test('only pending, confirmed and seated still hold a table', () {
      expect(ReservationStatus.pending.isLive, isTrue);
      expect(ReservationStatus.confirmed.isLive, isTrue);
      expect(ReservationStatus.seated.isLive, isTrue);
      for (final status in [
        ReservationStatus.rejected,
        ReservationStatus.completed,
        ReservationStatus.cancelled,
        ReservationStatus.noShow,
        ReservationStatus.expired,
      ]) {
        expect(status.isLive, isFalse, reason: '$status should be finished');
      }
    });

    test('a service date is a calendar date, not an instant', () {
      // The one bug this whole type exists to prevent: parsing the day as an
      // instant and letting a phone in another timezone move the booking.
      final date = parseCalendarDate('2026-08-20');
      expect(date.year, 2026);
      expect(date.month, 8);
      expect(date.day, 20);
      expect(date.isUtc, isFalse);
      expect(apiDate(date), '2026-08-20');
      // And the round trip survives a device east of the restaurant.
      expect(apiDate(parseCalendarDate(apiDate(date))), '2026-08-20');
    });

    test('a start time is never converted', () {
      const sitting = AvailabilitySitting(
        slotId: 's1',
        startTime: '19:00:00',
        durationMinutes: 90,
        bufferMinutes: 15,
        pricePence: 0,
        isAvailable: true,
      );
      // Shown as the restaurant's wall clock, seconds trimmed and nothing else.
      expect(sitting.label, '19:00');
    });

    test('can_cancel is read, never derived', () {
      // Staff can approve between the screen loading and the button being
      // pressed. Deriving this from the status would put the button back.
      final booking = ReservationDetail.fromJson(const {
        'id': 'r1',
        'status': 'pending',
        'can_cancel': false,
      });
      expect(booking.status, ReservationStatus.pending);
      expect(booking.canCancel, isFalse);
    });

    test('money is integer pence', () {
      expect(formatBookingPrice(0), 'Free');
      expect(formatBookingPrice(895), '£8.95');
      expect(formatBookingPrice(1500), '£15.00');
      expect(formatBookingPrice(1505), '£15.05');
    });

    test('staff are offered only legal moves', () {
      expect(ReservationTransitions.nextFor(ReservationStatus.pending), [
        ReservationStatus.confirmed,
        ReservationStatus.rejected,
        ReservationStatus.cancelled,
      ]);
      // A finished booking offers nothing at all.
      expect(ReservationTransitions.nextFor(ReservationStatus.completed), []);
      expect(ReservationTransitions.nextFor(ReservationStatus.expired), []);
    });

    test('reject, cancel and no-show need a reason; the rest do not', () {
      expect(
        ReservationTransitions.needsReason(ReservationStatus.rejected),
        isTrue,
      );
      expect(
        ReservationTransitions.needsReason(ReservationStatus.cancelled),
        isTrue,
      );
      expect(
        ReservationTransitions.needsReason(ReservationStatus.noShow),
        isTrue,
      );
      expect(
        ReservationTransitions.needsReason(ReservationStatus.confirmed),
        isFalse,
      );
    });
  });

  group('choosing a sitting', () {
    test('loads availability for the chosen day and party', () async {
      final cubit = BookingCubit(
        repository: repository,
        today: DateTime(2026, 8, 20),
      );
      await cubit.load();

      expect(cubit.state.stage, BookingStage.ready);
      expect(repository.availabilityQueries.last, {
        'date': '2026-08-20',
        'guests': 2,
      });
      // Unavailable sittings are kept, not filtered out: a disabled slot with a
      // reason is a schedule, a missing one is a gap nobody can explain.
      expect(cubit.state.availability!.tables.first.sittings, hasLength(2));
    });

    test('changing the day clears the selection', () async {
      final cubit = BookingCubit(
        repository: repository,
        today: DateTime(2026, 8, 20),
      );
      await cubit.load();
      cubit.select('s1');
      expect(cubit.state.selectedSlotId, 's1');

      await cubit.setDate(DateTime(2026, 8, 21));
      // The slot belonged to the old day.
      expect(cubit.state.selectedSlotId, isNull);
    });

    test('a stale reply cannot overwrite a newer one', () async {
      repository = FakeReservationRepository(
        delay: const Duration(milliseconds: 40),
      );
      final cubit = BookingCubit(
        repository: repository,
        today: DateTime(2026, 8, 20),
      );

      final first = cubit.load();
      final second = cubit.setGuests(6);
      await Future.wait([first, second]);

      expect(cubit.state.guests, 6);
      expect(repository.availabilityQueries.last['guests'], 6);
    });

    test('the request sends the slot id and the party', () async {
      final cubit = BookingCubit(
        repository: repository,
        today: DateTime(2026, 8, 20),
      );
      await cubit.load();
      cubit.select('s1');

      final failure = await cubit.submit(
        contactName: '  Ali Hassan ',
        contactPhone: '07700 900123',
        specialRequests: '  ',
      );

      expect(failure, isNull);
      expect(repository.lastRequest, {
        'slot_id': 's1',
        'guests': 2,
        'contact_name': '  Ali Hassan ',
        'contact_phone': '07700 900123',
        'special_requests': '  ',
      });
      // Pending, not confirmed. This is the whole point of the feature.
      expect(cubit.state.stage, BookingStage.requested);
      expect(cubit.state.reservation!.status, ReservationStatus.pending);
    });

    test('a taken slot clears the selection and reloads', () async {
      final cubit = BookingCubit(
        repository: repository,
        today: DateTime(2026, 8, 20),
      );
      await cubit.load();
      cubit.select('s1');
      final loadsBefore = repository.availabilityCalls;

      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.conflict,
        message: 'That slot was just taken.',
        code: BookingErrorCodes.slotAlreadyBooked,
      );
      final failure = await cubit.submit(
        contactName: 'Ali',
        contactPhone: '07700 900123',
      );

      expect(failure, isNotNull);
      // Pressing the same button again could not possibly work, so the choice
      // goes and availability is re-read.
      expect(cubit.state.selectedSlotId, isNull);
      expect(repository.availabilityCalls, loadsBefore + 1);
    });

    test('a field complaint is attached to its field', () async {
      final cubit = BookingCubit(repository: repository);
      await cubit.load();
      cubit.select('s1');

      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.invalid,
        message: 'Please check the highlighted fields.',
        code: 'VALIDATION_FAILED',
        fieldErrors: {'contact_phone': 'Enter a number we can reach you on.'},
      );
      await cubit.submit(contactName: 'Ali', contactPhone: '1');

      expect(
        cubit.state.fieldErrors['contact_phone'],
        'Enter a number we can reach you on.',
      );
      // The selection survives: the slot is fine, the form was not.
      expect(cubit.state.selectedSlotId, 's1');
    });

    test('a second submit while one is in flight is ignored', () async {
      repository = FakeReservationRepository(
        delay: const Duration(milliseconds: 30),
      );
      final cubit = BookingCubit(repository: repository);
      await cubit.load();
      cubit.select('s1');

      // No idempotency key on this endpoint, so a double tap is a double table.
      final first = cubit.submit(contactName: 'A', contactPhone: '07700900123');
      final second = cubit.submit(
        contactName: 'A',
        contactPhone: '07700900123',
      );
      await Future.wait([first, second]);

      expect(repository.lastRequest, isNotNull);
      expect(cubit.state.stage, BookingStage.requested);
    });
  });

  group('the customer\'s bookings', () {
    test('watches a pending booking and stops once answered', () async {
      final cubit = MyBookingsCubit(repository: repository);
      repository.requestResult = FakeReservationRepository.detail();
      await cubit.load();
      await cubit.open('r1');

      expect(cubit.state.detail!.status, ReservationStatus.pending);
      final reads = repository.detailCalls;

      // Staff approve it.
      repository.requestResult = FakeReservationRepository.detail(
        status: ReservationStatus.confirmed,
        canCancel: false,
      );
      await cubit.refreshDetail('r1');
      expect(cubit.state.detail!.status, ReservationStatus.confirmed);
      expect(repository.detailCalls, reads + 1);

      // Nothing left to watch for, so the timer is gone. A booking that has
      // been answered polling forever is a request every ten seconds for a
      // fact that cannot change.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repository.detailCalls, reads + 1);
      await cubit.close();
    });

    test('cancelling replaces the booking with what came back', () async {
      final cubit = MyBookingsCubit(repository: repository);
      await cubit.load();
      await cubit.open('r1');

      final error = await cubit.cancel('r1', reason: 'Plans changed');
      expect(error, isNull);
      expect(repository.lastCancel, {'id': 'r1', 'reason': 'Plans changed'});
      expect(cubit.state.detail!.status, ReservationStatus.cancelled);
      expect(cubit.state.detail!.canCancel, isFalse);
      await cubit.close();
    });

    test('a late cancellation re-reads instead of insisting', () async {
      final cubit = MyBookingsCubit(repository: repository);
      await cubit.load();
      await cubit.open('r1');
      final reads = repository.detailCalls;

      // Staff approved it between the screen loading and the tap.
      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.conflict,
        message:
            'This booking is approved. Please contact the restaurant to make '
            'changes.',
        code: BookingErrorCodes.alreadyApproved,
      );
      final error = await cubit.cancel('r1');

      expect(error, contains('contact the restaurant'));
      expect(repository.detailCalls, greaterThan(reads));
      await cubit.close();
    });
  });

  group('the staff booking sheet', () {
    test('opens on the pending queue', () async {
      final cubit = AdminBookingsCubit(repository: repository);
      await cubit.load();

      // An unanswered request is the only thing here with a clock on it.
      expect(cubit.state.filter, ReservationStatus.pending);
      expect(cubit.state.stats.pendingApproval, 3);
      await cubit.close();
    });

    test('approving sends no note and adopts the answer', () async {
      final cubit = AdminBookingsCubit(repository: repository);
      await cubit.load();
      await cubit.open('r1');

      final error = await cubit.updateStatus(
        'r1',
        status: ReservationStatus.confirmed,
      );
      expect(error, isNull);
      expect(repository.lastStatusChange, {
        'id': 'r1',
        'status': 'confirmed',
        'note': null,
      });
      expect(cubit.state.detail!.status, ReservationStatus.confirmed);
      expect(cubit.state.busyIds, isEmpty);
      await cubit.close();
    });

    test('rejecting carries the reason the customer will read', () async {
      final cubit = AdminBookingsCubit(repository: repository);
      await cubit.load();
      await cubit.open('r1');

      await cubit.updateStatus(
        'r1',
        status: ReservationStatus.rejected,
        note: 'We are fully booked for that sitting.',
      );
      expect(repository.lastStatusChange, {
        'id': 'r1',
        'status': 'rejected',
        'note': 'We are fully booked for that sitting.',
      });
      expect(
        cubit.state.detail!.cancellationReason,
        'We are fully booked for that sitting.',
      );
      await cubit.close();
    });

    test('a move another device already made re-reads', () async {
      final cubit = AdminBookingsCubit(repository: repository);
      await cubit.load();
      await cubit.open('r1');
      final reads = repository.detailCalls;

      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.conflict,
        message: 'That booking has already moved on.',
        code: BookingErrorCodes.invalidTransition,
      );
      final error = await cubit.updateStatus(
        'r1',
        status: ReservationStatus.confirmed,
      );

      expect(error, 'That booking has already moved on.');
      expect(repository.detailCalls, greaterThan(reads));
      expect(cubit.state.busyIds, isEmpty);
      await cubit.close();
    });
  });

  group('the booking screen', () {
    Widget wrap() => BlocProvider(
      create: (_) => AuthFixtures.cubit(AuthFixtures.customer),
      child: RepositoryProvider<ReservationRepository>.value(
        value: repository,
        // The app theme, because the screen reads the `AppSurfaces` extension
        // from it — a bare MaterialApp has none and every surface throws.
        child: MaterialApp(
          theme: AppTheme.light,
          home: const BookTableScreen(),
        ),
      ),
    );

    testWidgets('shows unavailable sittings with their reason', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Window Table 1'), findsOneWidget);
      expect(find.text('19:00'), findsNWidgets(2));
      // Kept and explained rather than hidden.
      expect(find.text('Already booked'), findsOneWidget);
      // ...and "too small" names the number, because the customer's next move
      // is to reduce the party or pick another table.
      expect(find.text('Seats up to 2'), findsOneWidget);
    });

    testWidgets('will not send a request until a sitting is chosen', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Choose a sitting'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose a sitting'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('says a request is not a confirmed table', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // The single most important sentence on the screen.
      expect(find.textContaining('The restaurant confirms it'), findsOneWidget);
    });

    testWidgets('a sent request reads as awaiting approval', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('19:00').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '07700 900123'),
        '07700 900123',
      );
      await tester.pump();
      await tester.tap(find.text('Request this table'));
      await tester.pumpAndSettle();

      expect(find.text('Awaiting approval'), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      // Never the word "confirmed".
      expect(find.textContaining('Confirmed'), findsNothing);
    });

    testWidgets('a request without a phone number is not sent', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('19:00').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request this table'));
      await tester.pumpAndSettle();

      expect(repository.lastRequest, isNull);
      expect(find.textContaining('phone number'), findsWidgets);
    });
  });

  group('choosing a day and a party', () {
    test('a new day drops the slot chosen on the old one', () async {
      final repository = FakeReservationRepository();
      final cubit = BookingCubit(repository: repository);
      await cubit.load();

      final slot = cubit.state.availability!.tables.first.sittings.first;
      cubit.select(slot.slotId);
      expect(cubit.state.selectedSlotId, isNotNull);

      await cubit.setDate(cubit.state.date.add(const Duration(days: 1)));

      // That sitting belongs to yesterday. Keeping the id would book a table
      // on a day the customer is no longer looking at.
      expect(cubit.state.selectedSlotId, isNull);
      await cubit.close();
    });

    test('a bigger party keeps the slot and lets the server judge', () async {
      final repository = FakeReservationRepository();
      final cubit = BookingCubit(repository: repository);
      await cubit.load();

      final slot = cubit.state.availability!.tables.first.sittings.first;
      cubit.select(slot.slotId);

      await cubit.setGuests(cubit.state.guests + 1);

      // Kept on purpose: a bigger party may still fit the same table, and the
      // reload marks the sitting too small if it does not. Clearing it would
      // make the customer re-pick a time that is probably still fine.
      expect(cubit.state.selectedSlotId, slot.slotId);
      await cubit.close();
    });

    test('the party size stops at the API ceiling', () async {
      final cubit = BookingCubit(repository: FakeReservationRepository());

      await cubit.setGuests(500);
      expect(cubit.state.guests, BookingCubit.maxGuests);

      await cubit.setGuests(0);
      // Nobody books a table for nought people, and the API refuses it.
      expect(cubit.state.guests, 1);
      await cubit.close();
    });

    test('the same day again is not a reload', () async {
      final repository = FakeReservationRepository();
      final cubit = BookingCubit(repository: repository);
      await cubit.load();
      final calls = repository.availabilityCalls;

      await cubit.setDate(cubit.state.date);

      // Tapping today when today is already showing should cost nothing.
      expect(repository.availabilityCalls, calls);
      await cubit.close();
    });

    test('tapping the chosen sitting again lets go of it', () async {
      final cubit = BookingCubit(repository: FakeReservationRepository());
      await cubit.load();

      final slot = cubit.state.availability!.tables.first.sittings.first;
      cubit.select(slot.slotId);
      cubit.select(slot.slotId);

      // Otherwise there is no way to change your mind short of leaving.
      expect(cubit.state.selectedSlotId, isNull);
      expect(cubit.state.canSubmit, isFalse);
      await cubit.close();
    });
  });

  group('after a booking is made', () {
    test('starting again keeps the day and party, not the booking', () async {
      final repository = FakeReservationRepository();
      final cubit = BookingCubit(repository: repository);
      await cubit.load();
      await cubit.setGuests(4);
      cubit.select(
        cubit.state.availability!.tables.first.sittings.first.slotId,
      );
      await cubit.submit(contactName: 'Ali', contactPhone: '07700 900123');
      expect(cubit.state.reservation, isNotNull);

      cubit.startAgain();

      // Booking a second table is usually the same party on the same evening,
      // so those survive; the booking itself must not, or the screen would
      // show a confirmation for a table nobody has asked for yet.
      expect(cubit.state.guests, 4);
      expect(cubit.state.reservation, isNull);
      expect(cubit.state.selectedSlotId, isNull);
      await cubit.close();
    });
  });
}
