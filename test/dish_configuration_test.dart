import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/admin/domain/dish_configuration_draft.dart';
import 'package:practice/features/admin/domain/admin_menu_repository.dart';
import 'package:practice/features/admin/presentation/dish_configuration_cubit.dart';
import 'package:practice/features/admin/presentation/dish_configuration_screen.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/features/menu/domain/dish_configuration.dart';

import 'support/fake_admin_menu_repository.dart';

/// A dish already configured: two sizes, a single-choice crust, a paid extra.
final _pizza = Dish.fromJson({
  'id': 'pizza',
  'title': 'Margherita',
  'price_pence': 1250,
  'variants': [
    {
      'id': 'v12',
      'code': 'twelve-inch',
      'name': '12-inch',
      'price_pence': 1250,
      'is_default': true,
      'sort_order': 0,
      'option_groups': [
        {
          'option_group_id': 'crust',
          'group_code': 'crust',
          'min_quantity': 1,
          'max_quantity': 1,
        },
        {
          'option_group_id': 'extras',
          'group_code': 'extras',
          'min_quantity': 0,
          'max_quantity': 3,
        },
      ],
    },
    {
      'id': 'v16',
      'code': 'sixteen-inch',
      'name': '16-inch',
      'price_pence': 1750,
      'sort_order': 1,
      'option_groups': [
        {
          'option_group_id': 'crust',
          'group_code': 'crust',
          'min_quantity': 1,
          'max_quantity': 1,
        },
      ],
    },
  ],
  'option_groups': [
    {
      'id': 'crust',
      'code': 'crust',
      'name': 'Crust Style',
      'selection_type': 'single',
      'pricing_mode': 'always',
      'sort_order': 0,
      'options': [
        {
          'id': 'traditional',
          'code': 'traditional',
          'name': 'Traditional',
          'price_pence': 0,
          'is_default': true,
          'sort_order': 0,
        },
        {
          'id': 'stuffed',
          'code': 'garlic-stuffed',
          'name': 'Garlic Butter Stuffed',
          'price_pence': 220,
          'sort_order': 1,
        },
      ],
    },
    {
      'id': 'extras',
      'code': 'extras',
      'name': 'Extras',
      'selection_type': 'multiple',
      'pricing_mode': 'always',
      'sort_order': 1,
      'options': [
        {
          'id': 'cheese',
          'code': 'extra-cheese',
          'name': 'Extra Cheese',
          'price_pence': 150,
          'sort_order': 0,
        },
      ],
    },
  ],
});

/// A dish with nothing configured yet — the starting point for most admins.
const _plain = Dish(
  id: 'plain',
  name: 'Poppadom',
  description: '',
  pricePence: 150,
);

void main() {
  DishConfigurationCubit cubitFor(
    Dish dish, {
    FakeAdminMenuRepository? repository,
  }) => DishConfigurationCubit(
    repository: repository ?? FakeAdminMenuRepository(),
    dish: dish,
  );

  group('opening the editor', () {
    test('starts clean, so Save is not offered until something changes', () {
      final cubit = cubitFor(_pizza);
      expect(cubit.state.isDirty, isFalse);
      expect(cubit.state.canSave, isFalse);
      expect(cubit.state.problems, isEmpty);
    });

    test('an unconfigured dish opens empty and says what is missing', () {
      final cubit = cubitFor(_plain);
      expect(cubit.state.draft.variants, isEmpty);
      // Not a failure — just not saveable yet.
      expect(cubit.state.problems.first, contains('at least one'));
      expect(cubit.state.canSave, isFalse);
    });
  });

  group('sizes', () {
    test('the first one added becomes the default', () {
      final cubit = cubitFor(_plain)
        ..addVariant(name: '12-inch', pricePence: 1250);

      expect(cubit.state.draft.variants.single.isDefault, isTrue);
      // Built from what was typed, digits and all — the guide's hand-written
      // "twelve-inch" is a human choice, not something to reverse-engineer.
      expect(cubit.state.draft.variants.single.code, '12-inch');
      expect(cubit.state.problems, isEmpty);
      expect(cubit.state.canSave, isTrue);
    });

    test('a second one does not steal the default', () {
      final cubit = cubitFor(_plain)
        ..addVariant(name: '12-inch', pricePence: 1250)
        ..addVariant(name: '16-inch', pricePence: 1750);

      expect(cubit.state.draft.variants.map((v) => v.isDefault), [true, false]);
    });

    test('setting a default clears the previous one', () {
      final cubit = cubitFor(_pizza)..setDefaultVariant('sixteen-inch');

      expect(
        cubit.state.draft.variants.where((v) => v.isDefault).map((v) => v.code),
        ['sixteen-inch'],
      );
      expect(cubit.state.problems, isEmpty);
    });

    test('removing the default hands it to a survivor', () {
      // Left alone this is the invalid state the server refuses: no default at
      // all, which an admin would only find out about on save.
      final cubit = cubitFor(_pizza)..removeVariant('twelve-inch');

      expect(cubit.state.draft.variants.single.code, 'sixteen-inch');
      expect(cubit.state.draft.variants.single.isDefault, isTrue);
      expect(cubit.state.problems, isEmpty);
    });

    test('two sizes with the same name get distinct codes', () {
      // Codes are identity. Two colliding ones would make the server treat one
      // size as the other.
      final cubit = cubitFor(_plain)
        ..addVariant(name: 'Regular', pricePence: 100)
        ..addVariant(name: 'Regular', pricePence: 200);

      expect(cubit.state.draft.variants.map((v) => v.code), [
        'regular',
        'regular-2',
      ]);
      expect(cubit.state.problems, isEmpty);
    });

    test('renaming keeps the code, so the option keeps its identity', () {
      final cubit = cubitFor(_pizza)
        ..updateVariant('twelve-inch', name: 'Twelve inch (regular)');

      final variant = cubit.state.draft.variants.first;
      expect(variant.name, 'Twelve inch (regular)');
      expect(variant.code, 'twelve-inch');
    });

    test('a new size inherits the groups the dish already has', () {
      final cubit = cubitFor(_pizza)
        ..addVariant(name: '20-inch', pricePence: 2200);

      // Starting from nothing would silently drop the crust choice every other
      // size offers.
      expect(cubit.state.draft.variants.last.rules.map((r) => r.groupCode), [
        'crust',
        'extras',
      ]);
    });
  });

  group('choice groups', () {
    test('a new group is offered by every existing size', () {
      final cubit = cubitFor(_pizza)
        ..addGroup(
          name: 'Dips',
          selectionType: OptionSelectionType.multiple,
          pricingMode: OptionPricingMode.always,
        );

      for (final variant in cubit.state.draft.variants) {
        expect(
          variant.rules.map((r) => r.groupCode),
          contains('dips'),
          reason: variant.code,
        );
      }
    });

    test('a single-choice group is capped at one everywhere it is offered', () {
      final cubit = cubitFor(_pizza)
        ..addGroup(
          name: 'Spice',
          selectionType: OptionSelectionType.single,
          pricingMode: OptionPricingMode.always,
        );

      final rule = cubit.state.draft.variants.first.rules.firstWhere(
        (r) => r.groupCode == 'spice',
      );
      expect(rule.maxQuantity, 1);
      expect(cubit.state.problems, isEmpty);
    });

    test('turning a group into a single choice fixes the rules that allowed '
        'more', () {
      // Otherwise the contradiction reaches the customer as
      // OPTION_GROUP_SINGLE_ONLY halfway through ordering.
      final cubit = cubitFor(_pizza)
        ..updateGroup('extras', selectionType: OptionSelectionType.single);

      final rule = cubit.state.draft.variants.first.rules.firstWhere(
        (r) => r.groupCode == 'extras',
      );
      expect(rule.maxQuantity, 1);
      expect(cubit.state.problems, isEmpty);
    });

    test('removing a group removes the rules pointing at it', () {
      final cubit = cubitFor(_pizza)..removeGroup('extras');

      expect(cubit.state.draft.optionGroups.map((g) => g.code), ['crust']);
      for (final variant in cubit.state.draft.variants) {
        expect(
          variant.rules.map((r) => r.groupCode),
          isNot(contains('extras')),
        );
      }
      // An orphan rule would be the one thing the server rejects outright.
      expect(cubit.state.problems, isEmpty);
    });

    test('a size can stop offering a group without deleting it', () {
      final cubit = cubitFor(_pizza)
        ..setGroupOffered('twelve-inch', 'extras', false);

      expect(cubit.state.draft.variants.first.rules.map((r) => r.groupCode), [
        'crust',
      ]);
      // The group itself survives for the other sizes.
      expect(cubit.state.draft.optionGroups.map((g) => g.code), [
        'crust',
        'extras',
      ]);
    });
  });

  group('choices inside a group', () {
    test('adding one gives it a code from its name', () {
      final cubit = cubitFor(_pizza)
        ..addOption('extras', name: 'Extra Olives', pricePence: 90);

      final option = cubit.state.draft.optionGroups.last.options.last;
      expect(option.code, 'extra-olives');
      expect(option.pricePence, 90);
    });

    test('pre-selecting in a single-choice group clears the other', () {
      final cubit = cubitFor(_pizza)
        ..updateOption('crust', 'garlic-stuffed', isDefault: true);

      final defaults = cubit.state.draft.optionGroups.first.options
          .where((o) => o.isDefault)
          .map((o) => o.code);
      // Two pre-selected radios is not a state the customer's screen can show.
      expect(defaults, ['garlic-stuffed']);
    });

    test('a sold-out choice stays in the structure', () {
      // Removing it would erase it from the menu; the customer's screen shows
      // it struck through, which is the honest version.
      final cubit = cubitFor(_pizza)
        ..updateOption('extras', 'extra-cheese', isAvailable: false);

      expect(
        cubit.state.draft.optionGroups.last.options.single.isAvailable,
        isFalse,
      );
      expect(cubit.state.problems, isEmpty);
    });
  });

  group('the allowance', () {
    test('included and maximum are set independently', () {
      final cubit = cubitFor(_pizza)
        ..updateGroup('extras', pricingMode: OptionPricingMode.excessOnly)
        // `clearMaximum`, not `maxQuantity: null` — null means "leave it
        // alone", so without this the old ceiling of 3 survives and a minimum
        // of 6 contradicts it.
        ..setRule(
          'twelve-inch',
          'extras',
          minQuantity: 6,
          includedQuantity: 6,
          clearMaximum: true,
        );

      final rule = cubit.state.draft.variants.first.rules.firstWhere(
        (r) => r.groupCode == 'extras',
      );
      expect(rule.minQuantity, 6);
      expect(rule.includedQuantity, 6);
      expect(rule.maxQuantity, isNull);
      // The 6-item breakfast shape: six included, and no ceiling on extras.
      expect(cubit.state.problems, isEmpty);
    });

    test('"no limit" is reachable and is not the same as zero', () {
      final cubit = cubitFor(_pizza)
        ..setRule('twelve-inch', 'extras', clearMaximum: true);

      final rule = cubit.state.draft.variants.first.rules.firstWhere(
        (r) => r.groupCode == 'extras',
      );
      expect(rule.maxQuantity, isNull);
      // Sent as an explicit null, because the PUT replaces and an omitted key
      // would let the old ceiling survive.
      final json = cubit.state.draft.toJson();
      final rules =
          ((json['variants'] as List).first as Map)['option_groups'] as List;
      final extras = rules.firstWhere(
        (r) => (r as Map)['group_code'] == 'extras',
      );
      expect((extras as Map).containsKey('max_quantity'), isTrue);
      expect(extras['max_quantity'], isNull);
    });

    test('a maximum below the minimum is caught before saving', () {
      final cubit = cubitFor(_pizza)
        ..setRule('twelve-inch', 'extras', minQuantity: 4, maxQuantity: 2);

      expect(
        cubit.state.problems.any((p) => p.contains('fewer than it requires')),
        isTrue,
      );
      expect(cubit.state.canSave, isFalse);
    });
  });

  group('saving', () {
    test(
      'sends the complete structure once and adopts the server\'s answer',
      () async {
        final repository = FakeAdminMenuRepository()..configuredDish = _pizza;
        final cubit = cubitFor(_pizza, repository: repository)
          ..addVariant(name: '20-inch', pricePence: 2200);

        expect(cubit.state.isDirty, isTrue);
        final saved = await cubit.save();

        expect(saved, isNotNull);
        expect(repository.configurations, hasLength(1));
        expect(repository.configurations.single.$1, 'pizza');
        expect(
          repository.configurations.single.$2.variants.map((v) => v.code),
          ['twelve-inch', 'sixteen-inch', '20-inch'],
        );
        // Re-read from the server, so the editor shows what is stored rather
        // than what was typed.
        expect(cubit.state.isDirty, isFalse);
        expect(cubit.state.draft.variants.map((v) => v.code), [
          'twelve-inch',
          'sixteen-inch',
        ]);
      },
    );

    test('an invalid structure is never sent', () async {
      final repository = FakeAdminMenuRepository();
      final cubit = cubitFor(_pizza, repository: repository)
        ..setRule('twelve-inch', 'extras', minQuantity: 4, maxQuantity: 2);

      expect(await cubit.save(), isNull);
      expect(repository.configurations, isEmpty);
    });

    test('a rejected save keeps the edits so nothing is lost', () async {
      final repository = FakeAdminMenuRepository()
        ..failure = const ApiFailure(
          kind: ApiFailureKind.server,
          message: 'The kitchen server is having trouble.',
        );
      final cubit = cubitFor(_pizza, repository: repository)
        ..addVariant(name: '20-inch', pricePence: 2200);

      expect(await cubit.save(), isNull);
      expect(cubit.state.failure, isNotNull);
      expect(cubit.state.isDirty, isTrue);
      expect(cubit.state.draft.variants, hasLength(3));
    });

    test('undo returns to what the server last confirmed', () {
      final cubit = cubitFor(_pizza)
        ..addVariant(name: '20-inch', pricePence: 2200)
        ..removeGroup('extras');
      expect(cubit.state.isDirty, isTrue);

      cubit.revert();
      expect(cubit.state.isDirty, isFalse);
      expect(cubit.state.draft, configurationOf(_pizza));
    });
  });

  group('the editor screen', () {
    Widget wrap(Dish dish, FakeAdminMenuRepository repository) =>
        RepositoryProvider<AdminMenuRepository>.value(
          value: repository,
          child: MaterialApp(
            theme: AppTheme.light,
            home: DishConfigurationScreen(dish: dish),
          ),
        );

    Future<void> show(
      WidgetTester tester,
      Dish dish,
      FakeAdminMenuRepository repository,
    ) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(dish, repository));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the sizes and the groups as they stand', (tester) async {
      await show(tester, _pizza, FakeAdminMenuRepository());

      expect(find.text('12-inch'), findsOneWidget);
      expect(find.text('16-inch'), findsOneWidget);
      expect(find.text('Crust Style'), findsOneWidget);
      expect(find.text('Garlic Butter Stuffed'), findsOneWidget);
      // The default and the price are on the row, not buried in a sheet.
      expect(find.textContaining('Default'), findsOneWidget);
      expect(find.textContaining('£12.50'), findsOneWidget);
    });

    testWidgets('an unconfigured dish says what it needs before Save works', (
      tester,
    ) async {
      await show(tester, _plain, FakeAdminMenuRepository());

      expect(find.text('Fix these before saving'), findsOneWidget);
      expect(find.textContaining('at least one'), findsWidgets);
      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Save'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('adding a size in pounds stores integer pence', (tester) async {
      final repository = FakeAdminMenuRepository()..configuredDish = _pizza;
      await show(tester, _plain, repository);

      await tester.tap(find.text('Add a size or serving'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Regular');
      await tester.enterText(find.widgetWithText(TextField, 'Price'), '11.95');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('Regular'), findsOneWidget);
      // 11.95 must not land on 1194 — `(11.95 * 100).toInt()` does exactly
      // that on a binary double.
      expect(find.textContaining('£11.95'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        repository.configurations.single.$2.variants.single.pricePence,
        1195,
      );
    });

    testWidgets('a price typed as nonsense is refused with a reason', (
      tester,
    ) async {
      await show(tester, _plain, FakeAdminMenuRepository());

      await tester.tap(find.text('Add a size or serving'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Regular');
      await tester.enterText(find.widgetWithText(TextField, 'Price'), '1.2.3');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.textContaining('like 11.95'), findsOneWidget);
    });

    testWidgets('a nameless size is refused', (tester) async {
      await show(tester, _plain, FakeAdminMenuRepository());

      await tester.tap(find.text('Add a size or serving'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('Give it a name.'), findsOneWidget);
    });

    testWidgets('leaving with unsaved edits asks first', (tester) async {
      await show(tester, _pizza, FakeAdminMenuRepository());

      await tester.tap(find.text('Add a size or serving'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Giant');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // The structure takes a while to build and is kept nowhere else, so a
      // stray back gesture must not cost it.
      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.text('Discard these options?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Giant'), findsOneWidget);
    });

    testWidgets('undo puts everything back', (tester) async {
      await show(tester, _pizza, FakeAdminMenuRepository());
      expect(find.text('Undo all changes'), findsNothing);

      await tester.tap(find.text('Add a size or serving'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Giant');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo all changes'));
      await tester.pumpAndSettle();
      expect(find.text('Giant'), findsNothing);
      expect(find.text('Undo all changes'), findsNothing);
    });
  });
}

/// The draft a dish would produce, for comparing against after an undo.
Matcher configurationOf(Dish dish) => _DraftMatcher(dish);

class _DraftMatcher extends Matcher {
  const _DraftMatcher(this.dish);

  final Dish dish;

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) =>
      item == DishConfigurationDraft.fromDish(dish);

  @override
  Description describe(Description description) =>
      description.add('the configuration ${dish.name} was opened with');
}
