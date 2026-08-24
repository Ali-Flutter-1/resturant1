import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/admin/domain/admin_menu_repository.dart';
import 'package:practice/features/admin/presentation/dish_editor_sheet.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/shared/widgets/app_chip.dart';

import 'support/fake_admin_menu_repository.dart';

/// The add-dish sheet.
///
/// Two things here are easy to regress and invisible in a diff: the order of the
/// form, and whether a category outside the built-in list can be entered at all.
void main() {
  late FakeAdminMenuRepository repository;
  Dish? saved;

  setUp(() {
    // The draft is session-scoped by design, so it outlives the test that
    // made it unless each one starts clean.
    resetDishDraft();
    repository = FakeAdminMenuRepository();
    saved = null;
  });

  Future<void> open(WidgetTester tester, {Dish? dish}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await showDishEditor(
                context: context,
                repository: repository,
                categories: FakeAdminMenuRepository.defaultCategories,
                dish: dish,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the photograph comes before the name', (tester) async {
    await open(tester);

    final photograph = tester.getTopLeft(find.text('Photograph')).dy;
    final name = tester.getTopLeft(find.text('Name')).dy;
    final price = tester.getTopLeft(find.text('Price')).dy;

    // It was last. The most visible thing about a dish should not be the final
    // thing you are asked for, below the fold behind the keyboard.
    expect(photograph, lessThan(name));
    expect(name, lessThan(price));
  });

  testWidgets('offers both the camera and the gallery', (tester) async {
    await open(tester);

    expect(find.text('Camera'), findsOne);
    expect(find.text('Gallery'), findsOne);
    // No paste-a-URL field: the API takes `{public_id, url}` pairs from its own
    // upload endpoint, and a pasted link has no public_id — it could never be
    // saved, so offering the field would be offering a dead end.
    expect(find.textContaining('paste an image URL'), findsNothing);
  });

  testWidgets('a category outside the built-in list can be added', (
    tester,
  ) async {
    await open(tester);

    const custom = 'Street Food';
    expect(find.textContaining(custom), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, 'Add another category'),
      custom,
    );
    await tester.ensureVisible(find.byTooltip('Add category'));
    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();

    // Added *and* selected: typing a category is a statement that this dish is
    // in it, so making the user tap the new chip as well would be a second step
    // for no decision.
    // Marked "(new)" because it does not exist server-side yet — it is created
    // on save, so abandoning the sheet leaves no stray category behind.
    expect(find.text('$custom (new)'), findsOne);
  });

  testWidgets('creates the category first, then the dish with its id', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Kottu Roti',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '9.00');
    await tester.enterText(
      find.widgetWithText(TextField, 'Add another category'),
      'Street Food',
    );
    await tester.ensureVisible(find.byTooltip('Add category'));
    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    // The category had to exist before the dish could reference it — the API
    // takes ids, not names.
    expect(repository.createdCategories, ['Street Food']);
    expect(repository.lastCreate?['category_ids'], contains('cat-new-3'));
    expect(repository.lastCreate?['title'], 'Kottu Roti');
    // Pence as an integer, and rounded: 9.00 × 100 in binary floating point is
    // not exactly 900, and truncating would sell it for £8.99.
    expect(repository.lastCreate?['price_pence'], 900);
    expect(saved?.name, 'Kottu Roti');
  });

  testWidgets('sends the prep-time range the API requires', (tester) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Hoppers',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '6.50');
    await tester.ensureVisible(find.text('Curry Dishes'));
    await tester.tap(find.text('Curry Dishes'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    // Defaulted rather than left null, because the API requires both.
    expect(repository.lastCreate?['prep_min'], 15);
    expect(repository.lastCreate?['prep_max'], 20);
  });

  testWidgets('refuses a prep range that runs backwards', (tester) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Hoppers',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '6.50');
    await tester.enterText(find.widgetWithText(TextField, '15'), '30');
    await tester.enterText(find.widgetWithText(TextField, '20'), '10');
    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    expect(
      find.text('The shortest time cannot be longer than the longest.'),
      findsOne,
    );
    expect(repository.lastCreate, isNull);
  });

  testWidgets('refuses a dish with no category', (tester) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Hoppers',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '6.50');
    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    // The API requires one, and an uncategorised dish would not appear on the
    // public menu even if it accepted one.
    expect(find.text('Choose at least one category.'), findsOne);
    expect(repository.lastCreate, isNull);
  });

  testWidgets('a dish can sit in several categories at once', (tester) async {
    await open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Jackfruit Curry',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '18.00');
    await tester.ensureVisible(find.text('Curry Dishes'));
    await tester.tap(find.text('Curry Dishes'));
    await tester.ensureVisible(find.text('Vegan'));
    await tester.tap(find.text('Vegan'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    expect(
      repository.lastCreate?['category_ids'],
      containsAll(<String>['cat-1', 'cat-2']),
    );
  });

  testWidgets('reports the API message when saving fails', (tester) async {
    await open(tester);
    repository.failure = const ApiFailure(
      kind: ApiFailureKind.conflict,
      message: 'A dish with that name already exists.',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Hoppers',
    );
    await tester.enterText(find.widgetWithText(TextField, '12.50'), '6.50');
    await tester.ensureVisible(find.text('Curry Dishes'));
    await tester.tap(find.text('Curry Dishes'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();

    // The API's own words, shown verbatim, and the sheet stays open so the
    // typing is not lost.
    expect(find.text('A dish with that name already exists.'), findsOne);
    expect(saved, isNull);
  });

  testWidgets('will not add the same category twice under a different case', (
    tester,
  ) async {
    await open(tester);

    final before = find.text('Vegan').evaluate().length;

    await tester.enterText(
      find.widgetWithText(TextField, 'Add another category'),
      'vegan',
    );
    await tester.ensureVisible(find.byTooltip('Add category'));
    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();

    // Otherwise "vegan" becomes a second Vegan sitting beside the first, and no
    // category should be created for it on save either.
    expect(find.text('Vegan').evaluate().length, before);
    expect(find.text('vegan (new)'), findsNothing);
  });

  testWidgets(
    'an empty category is ignored rather than added as a blank chip',
    (tester) async {
      await open(tester);
      final before = find.byType(TextField).evaluate().length;

      await tester.ensureVisible(find.byTooltip('Add category'));
      await tester.tap(find.byTooltip('Add category'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField).evaluate().length, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('still refuses a dish with no name or a bad price', (
    tester,
  ) async {
    await open(tester);

    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();
    expect(find.text('Give the dish a name.'), findsOne);

    await tester.enterText(
      find.widgetWithText(TextField, 'Jaffna Crab Curry'),
      'Hoppers',
    );
    await tester.ensureVisible(find.text('Add dish'));
    await tester.tap(find.text('Add dish'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a price, like 12.50.'), findsOne);
  });

  group('a section\'s logo', () {
    test('uploading returns the server\'s own image_url', () async {
      final repository = FakeAdminMenuRepository();
      final categories = await repository.categories();
      final target = categories.first;

      final updated = await repository.setCategoryLogo(target.id, '/tmp/a.jpg');

      expect(repository.logoChanges.last, {
        'id': target.id,
        'path': '/tmp/a.jpg',
      });
      // Displayed as sent. The guide is explicit that the app must never build
      // a Cloudinary URL of its own.
      expect(updated.imageUrl, isNotNull);
      expect(updated.imageUrl, startsWith('https://'));
      expect(updated.id, target.id);
      expect(updated.name, target.name);
    });

    test('removing clears the picture and keeps the section', () async {
      final repository = FakeAdminMenuRepository();
      final target = (await repository.categories()).first;
      await repository.setCategoryLogo(target.id, '/tmp/a.jpg');

      final cleared = await repository.removeCategoryLogo(target.id);

      expect(cleared.imageUrl, isNull);
      expect(cleared.name, target.name);
      // The whole category comes back, not a bare acknowledgement, so the
      // caller re-renders from one source.
      expect((await repository.categories()).first.imageUrl, isNull);
    });
  });

  group('spice levels on a dish', () {
    testWidgets('off by default, and sent as chosen', (tester) async {
      await open(tester);

      await tester.ensureVisible(find.text('Offer a spice level'));
      await tester.pumpAndSettle();

      // Off unless asked for: most dishes are not adjustable, and a selector on
      // every one would ask a question the kitchen cannot answer.
      final before = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Offer a spice level'),
      );
      expect(before.value, isFalse);

      await tester.tap(find.text('Offer a spice level'));
      await tester.pumpAndSettle();

      final after = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Offer a spice level'),
      );
      expect(after.value, isTrue);
    });

    testWidgets('an existing dish shows what it already offers', (
      tester,
    ) async {
      await open(
        tester,
        dish: const Dish(
          id: 'd1',
          name: 'Devilled Chicken',
          description: 'Hot.',
          pricePence: 1250,
          hasSpiceLevels: true,
        ),
      );

      await tester.ensureVisible(find.text('Offer a spice level'));
      await tester.pumpAndSettle();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Offer a spice level'),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('a new section can carry a logo', (tester) async {
      await open(tester);

      await tester.ensureVisible(find.byTooltip('Add category'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Add another category'),
        'Street Food',
      );
      await tester.tap(find.byTooltip('Add category'));
      await tester.pumpAndSettle();

      // The picture and the category are one job rather than two screens.
      expect(find.text('No picture yet'), findsOneWidget);
      expect(find.text('Add logo'), findsOneWidget);
    });
  });

  group('managing a section from the dish editor', () {
    /// The manage sheet reads the repository from the tree, which the plain
    /// editor harness does not provide.
    Future<void> openWithProvider(WidgetTester tester) async {
      await tester.pumpWidget(
        RepositoryProvider<AdminMenuRepository>.value(
          value: repository,
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => saved = await showDishEditor(
                    context: context,
                    repository: repository,
                    categories: FakeAdminMenuRepository.defaultCategories,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('every saved section carries a visible way in', (tester) async {
      await openWithProvider(tester);

      // A glyph on the chip rather than a hidden long press, and one per
      // saved section.
      expect(
        find.descendant(
          of: find.byType(SelectableChip),
          matching: find.byIcon(Icons.edit_outlined),
        ),
        findsNWidgets(FakeAdminMenuRepository.defaultCategories.length),
      );
      expect(find.textContaining('Tap the pencil'), findsOneWidget);
    });

    /// The chip, specifically: the manage sheet repeats the section's name in
    /// its title and in the rename row.
    Finder chip(String label) => find.widgetWithText(SelectableChip, label);

    /// The pencil on that chip, which is a target of its own -- tapping the
    /// label still just picks the section.
    Finder manage(String label) => find.descendant(
      of: chip(label),
      matching: find.byIcon(Icons.edit_outlined),
    );

    testWidgets('the pencil edits, the label still selects', (tester) async {
      await openWithProvider(tester);
      await tester.ensureVisible(chip('Curry Dishes'));
      await tester.pumpAndSettle();

      // Tapping the label picks the section for this dish...
      await tester.tap(find.text('Curry Dishes'));
      await tester.pumpAndSettle();
      expect(find.text('Rename section'), findsNothing);

      // ...and tapping the glyph beside it opens the manage sheet instead of
      // toggling the selection underneath it.
      await tester.tap(manage('Curry Dishes'));
      await tester.pumpAndSettle();
      expect(find.text('Rename section'), findsOneWidget);
      expect(find.text('Delete section'), findsOneWidget);
    });

    testWidgets('renaming a section updates its chip', (tester) async {
      await openWithProvider(tester);

      // The chips sit below the fold on a test viewport.
      await tester.ensureVisible(chip('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(manage('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename section'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Curries');
      await tester.tap(find.text('Save name'));
      await tester.pumpAndSettle();

      expect(repository.renamedCategories, [('cat-1', 'Curries')]);

      // Back on the editor, the chip carries the new name. "Done" sits below
      // the fold now that the sheet scrolls.
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(chip('Curries'), findsOneWidget);
      expect(chip('Curry Dishes'), findsNothing);
    });

    testWidgets('deleting a section takes it off the dish too', (tester) async {
      await openWithProvider(tester);

      // Pick it first: the dish is filed under it, and that has to come undone
      // with it -- a dish cannot belong to a section that is gone.
      await tester.ensureVisible(chip('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(chip('Curry Dishes'));
      await tester.pumpAndSettle();

      await tester.tap(manage('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete section'));
      await tester.pumpAndSettle();

      // Asked before it happens.
      expect(find.text('Keep this section'), findsOneWidget);
      await tester.tap(find.text('Delete section').last);
      await tester.pumpAndSettle();

      expect(repository.deletedCategories, ['cat-1']);
      expect(chip('Curry Dishes'), findsNothing);
    });

    testWidgets('a refused delete leaves the section alone', (tester) async {
      await openWithProvider(tester);

      await tester.ensureVisible(chip('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(manage('Curry Dishes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete section'));
      await tester.pumpAndSettle();

      // Second thoughts are the safe path, and the filled button.
      await tester.tap(find.text('Keep this section'));
      await tester.pumpAndSettle();

      expect(repository.deletedCategories, isEmpty);
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(chip('Curry Dishes'), findsOneWidget);
    });

    group('an unfinished dish survives a dismissed sheet', () {
      testWidgets('what was typed comes back, and can be discarded', (
        tester,
      ) async {
        await openWithProvider(tester);

        await tester.enterText(
          find.widgetWithText(TextField, 'Jaffna Crab Curry'),
          'Devilled Prawns',
        );
        await tester.enterText(
          find.widgetWithText(TextField, '12.50'),
          '14.00',
        );
        await tester.pumpAndSettle();

        // Dismissed without saving -- a stray tap outside, or the back gesture.
        Navigator.of(tester.element(find.byType(TextField).first)).pop();
        await tester.pumpAndSettle();

        await openWithProvider(tester);

        // Everything typed is still there, and the sheet says why rather than
        // silently repopulating -- which is indistinguishable from the app
        // having saved something it has not.
        expect(find.text('Devilled Prawns'), findsOneWidget);
        expect(find.text('14.00'), findsOneWidget);
        expect(find.text('Picked up where you left off.'), findsOneWidget);

        await tester.ensureVisible(find.text('Start again'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start again'));
        await tester.pumpAndSettle();

        expect(find.text('Devilled Prawns'), findsNothing);
        expect(find.text('Picked up where you left off.'), findsNothing);
      });

      testWidgets('a saved dish leaves no draft behind', (tester) async {
        await openWithProvider(tester);

        await tester.enterText(
          find.widgetWithText(TextField, 'Jaffna Crab Curry'),
          'Devilled Prawns',
        );
        await tester.enterText(
          find.widgetWithText(TextField, '12.50'),
          '14.00',
        );
        await tester.pumpAndSettle();
        await tester.tap(chip('Curry Dishes'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Add dish'));
        await tester.pumpAndSettle();

        await openWithProvider(tester);

        // Finished work is not a draft. Bringing it back would offer to add the
        // same dish twice.
        expect(find.text('Devilled Prawns'), findsNothing);
        expect(find.text('Picked up where you left off.'), findsNothing);
      });
    });
  });
}
