import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/hours/domain/working_hours.dart';
import 'package:practice/features/hours/domain/working_hours_repository.dart';
import 'package:practice/features/hours/presentation/admin_working_hours_screen.dart';
import 'package:practice/features/hours/presentation/working_hours_cubit.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_working_hours_repository.dart';

/// Opening hours.
///
/// Two distinctions carry this whole feature, and getting either wrong is a
/// visible lie to customers:
///
///  * **Not configured is not closed.** The API returns only the days somebody
///    has filled in; treating a missing Sunday as "Closed" tells people the
///    restaurant is shut when nobody has said so.
///  * **These hours do not gate anything.** The backend does not yet refuse
///    orders or bookings outside them, so the app must not claim to be open.
void main() {
  late FakeWorkingHoursRepository repository;

  setUp(() {
    repository = FakeWorkingHoursRepository();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(390, 2400);
    view.devicePixelRatio = 1.0;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  group('the week', () {
    test('a missing day is not a closed day', () {
      const hours = WorkingHours(
        days: [
          DayHours(
            weekday: 0,
            isClosed: false,
            opensAt: '10:00',
            closesAt: '22:00',
          ),
        ],
      );

      expect(hours.isConfigured(0), isTrue);
      expect(hours.isConfigured(6), isFalse);
      // The placeholder for an unconfigured day is open-with-no-times, never
      // closed — the customer card leaves it out rather than announcing a
      // closure nobody decided on.
      final sunday = hours.wholeWeek[6];
      expect(sunday.isClosed, isFalse);
      expect(sunday.isComplete, isFalse);
      expect(sunday.label, 'Not set');
    });

    test('times are wall clocks, kept as sent', () {
      // The one bug worth guarding: converting these through the device's zone
      // makes a London restaurant appear to open at 14:00 in Karachi.
      final day = DayHours.fromJson(const {
        'weekday': 4,
        'is_closed': false,
        'opens_at': '10:00:00',
        'closes_at': '23:00:00',
      });
      expect(day.opensAt, '10:00');
      expect(day.closesAt, '23:00');
      expect(day.label, '10:00 – 23:00');
      expect(day.name, 'Friday');
    });

    test('a closed day sends no times', () {
      const day = DayHours(
        weekday: 6,
        isClosed: true,
        opensAt: '10:00',
        closesAt: '22:00',
      );
      // A closed Sunday still carrying 10:00 is a contradiction for whoever
      // reads it next.
      expect(day.toJson(), {
        'weekday': 6,
        'is_closed': true,
        'opens_at': null,
        'closes_at': null,
      });
    });

    test('seconds are added back on the way out', () {
      const day = DayHours(
        weekday: 0,
        isClosed: false,
        opensAt: '10:00',
        closesAt: '22:00',
      );
      expect(day.toJson()['opens_at'], '10:00:00');
      expect(day.toJson()['closes_at'], '22:00:00');
    });

    test('the customer summary never claims to be open', () {
      // The backend does not enforce these hours, so "Open now" would be a
      // promise nothing has made.
      final today = DateTime.now().weekday - 1;
      final hours = WorkingHours(
        days: [
          DayHours(
            weekday: today,
            isClosed: false,
            opensAt: '10:00',
            closesAt: '22:00',
          ),
        ],
      );
      expect(hours.todayLabel, 'Today 10:00 – 22:00');
      expect(hours.todayLabel, isNot(contains('Open')));
    });
  });

  group('editing the week', () {
    test('loads into a seven-day draft whatever the API sent', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      // Five configured days, but the editor is a week.
      expect(cubit.state.saved.days, hasLength(5));
      expect(cubit.state.draft, hasLength(7));
      expect(cubit.state.isDirty, isFalse);
      await cubit.close();
    });

    test('edits are staged, not saved on every tap', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      // Saturday and Sunday come back unconfigured, which counts as open with
      // no times — so they have to be settled before anything can be sent.
      cubit.setClosed(5, true);
      cubit.setClosed(6, true);
      cubit.setOpensAt(0, '09:00');

      expect(cubit.state.isDirty, isTrue);
      // Nothing has gone out: a week is one decision, and seven PUTs while
      // somebody is still thinking would advertise a half-finished schedule.
      expect(repository.lastWeekSent, isNull);

      await cubit.save();
      expect(repository.lastWeekSent, hasLength(7));
      expect(cubit.state.isDirty, isFalse);
      await cubit.close();
    });

    test('an open day with no times cannot be saved', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      // Saturday is unconfigured and open — exactly what the API answers 422
      // for, so the button says so instead of sending it.
      cubit.setClosed(5, false);
      expect(cubit.state.incomplete.map((d) => d.weekday), [5, 6]);
      expect(cubit.state.canSave, isFalse);

      cubit.setClosed(5, true);
      cubit.setClosed(6, true);
      expect(cubit.state.canSave, isTrue);
      await cubit.close();
    });

    test('a day that closes before it opens cannot be saved', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      cubit.setClosesAt(0, '09:00');
      expect(cubit.state.backwards.map((d) => d.weekday), [0]);
      expect(cubit.state.canSave, isFalse);

      cubit.setClosesAt(0, '23:00');
      expect(cubit.state.backwards, isEmpty);
      await cubit.close();
    });

    test('copying one day fills the rest', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      cubit.setOpensAt(0, '08:00');
      cubit.setClosesAt(0, '23:30');
      cubit.applyToAll(0);

      for (final day in cubit.state.draft) {
        expect(day.opensAt, '08:00');
        expect(day.closesAt, '23:30');
      }
      await cubit.close();
    });

    test('discarding goes back to what the server said', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      cubit.setOpensAt(0, '06:00');
      expect(cubit.state.isDirty, isTrue);

      cubit.discard();
      expect(cubit.state.isDirty, isFalse);
      expect(cubit.state.draft.first.opensAt, '10:00');
      await cubit.close();
    });

    test('a refused save keeps the edits on screen', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();
      cubit.setClosed(5, true);
      cubit.setClosed(6, true);
      cubit.setOpensAt(0, '09:00');

      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.invalid,
        message: 'Please check the highlighted fields and try again.',
      );
      final error = await cubit.save();

      expect(error, 'Please check the highlighted fields and try again.');
      // Making somebody retype a week because one field was refused would be
      // its own bug.
      expect(cubit.state.draft.first.opensAt, '09:00');
      expect(cubit.state.isDirty, isTrue);
      await cubit.close();
    });

    test('clearing a day that was already cleared is not an error', () async {
      final cubit = WorkingHoursCubit(repository: repository, admin: true);
      await cubit.load();

      repository.writeFailure = const ApiFailure(
        kind: ApiFailureKind.invalid,
        message: 'Those hours are not set.',
        code: WorkingHoursErrorCodes.notSet,
      );
      final error = await cubit.clear(6);

      // The screen and the server agree on the outcome, which is all anybody
      // wanted from the tap.
      expect(error, isNull);
      await cubit.close();
    });
  });

  group('the admin screen', () {
    Widget wrap() => BlocProvider(
      create: (_) => AuthFixtures.cubit(AuthFixtures.admin),
      child: RepositoryProvider<WorkingHoursRepository>.value(
        value: repository,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const AdminWorkingHoursScreen(),
        ),
      ),
    );

    testWidgets('shows every weekday, set or not', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Monday'), findsOneWidget);
      expect(find.text('Sunday'), findsOneWidget);
      // The two the API never sent are marked, rather than silently reading as
      // an open day with blank times.
      expect(find.text('not set'), findsNWidgets(2));
    });

    testWidgets('says what these hours actually do', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // An admin who assumes otherwise will be surprised by an order at 3am.
      expect(
        find.textContaining('do not stop orders or bookings'),
        findsOneWidget,
      );
    });

    testWidgets('the save bar appears only once something changed', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(find.text('Save the week'), findsNothing);

      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();

      expect(find.text('Save the week'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
    });

    testWidgets('naming the days that block a save', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // Saturday and Sunday are open with no times. Nudging any switch makes
      // the bar appear, and it should name them rather than just disabling.
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.textContaining('need both times'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save the week'),
      );
      expect(button.onPressed, isNull);
    });
    group('where the unsaved-change actions live', () {
      testWidgets('discard sits beside save, not up in the app bar', (
        tester,
      ) async {
        await tester.pumpWidget(wrap());
        await tester.pumpAndSettle();

        // Nothing pending: neither action is offered.
        expect(find.text('Discard'), findsNothing);
        expect(find.text('Save the week'), findsNothing);

        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();

        // Both halves of the same decision, in the same place -- the app bar is
        // the other end of the screen from the thumb that just changed a day.
        final discard = tester.getRect(find.text('Discard'));
        final save = tester.getRect(find.text('Save the week'));
        expect(discard.center.dy, closeTo(save.center.dy, 8));

        // And discard is the left, quieter one, so the thumb lands on save.
        expect(discard.center.dx, lessThan(save.center.dx));
      });
    });
  });
}
