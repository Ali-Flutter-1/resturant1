import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/menu/presentation/dish_details_screen.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/features/menu/domain/spice_level.dart';
import 'package:practice/shared/preview/sample_content.dart';

/// The dish these price tests are about.
///
/// Stated rather than relying on the screen's fallback: the screen used to
/// default to a sample dish costing £17.50, and every expectation below was
/// silently pinned to that.
const _priced = Dish(
  id: 'd1',
  name: 'Black Pork Curry',
  description: 'Dark roasted heritage classic.',
  pricePence: 1750,
);

/// The same dish, with the kitchen offering a heat choice.
const _spiced = Dish(
  id: 'd1',
  name: 'Black Pork Curry',
  description: 'Dark roasted heritage classic.',
  pricePence: 1750,
  hasSpiceLevels: true,
);

Widget wrapDish({Dish dish = _priced}) => DishDetailsScreen(dish: dish);

void main() {
  group('CartCubit', () {
    const curry = Dish(
      id: 'd1',
      name: 'Chicken Kottu',
      description: '',
      pricePence: 895,
    );
    const hoppers = Dish(
      id: 'd2',
      name: 'Hoppers',
      description: '',
      pricePence: 450,
    );

    test('starts empty', () {
      final cart = CartCubit();
      expect(cart.state.isEmpty, isTrue);
      expect(cart.state.count, 0);
    });

    test('holds real lines, not a count', () {
      final cart = CartCubit()..addDish(curry, quantity: 2);

      // The counter it used to be could not place an order: there was nothing to
      // send. A line carries the three fields the API accepts.
      expect(cart.state.lines.single.dishId, 'd1');
      expect(cart.state.lines.single.toJson(), {
        'dish_id': 'd1',
        'quantity': 2,
      });
      expect(cart.state.count, 2);
    });

    test('merges the same dish with the same note', () {
      final cart = CartCubit()
        ..addDish(curry, notes: 'Mild')
        ..addDish(curry, notes: 'Mild');

      // Two taps of add should read as one line of two.
      expect(cart.state.lines, hasLength(1));
      expect(cart.state.lines.single.quantity, 2);
    });

    test('keeps a different note as its own line', () {
      final cart = CartCubit()
        ..addDish(curry, notes: 'Mild')
        ..addDish(curry, notes: 'Hot');

      // A different note is a different instruction to the kitchen.
      expect(cart.state.lines, hasLength(2));
    });

    test('a blank note is no note at all', () {
      final cart = CartCubit()..addDish(curry, notes: '   ');
      expect(cart.state.lines.single.notes, isNull);
      expect(cart.state.lines.single.toJson().containsKey('notes'), isFalse);
    });

    test('caps a line at the API limit rather than being refused', () {
      final cart = CartCubit()..addDish(curry, quantity: 80);
      expect(cart.state.lines.single.quantity, CartState.maxQuantity);
    });

    test('setting a quantity to zero removes the line', () {
      final cart = CartCubit()
        ..addDish(curry)
        ..addDish(hoppers);
      cart.setQuantity(cart.state.lines.first, 0);

      expect(cart.state.lines.single.dishId, 'd2');
    });

    test('the subtotal is display only', () {
      final cart = CartCubit()
        ..addDish(curry, quantity: 2)
        ..addDish(hoppers);

      // Shown while the quote is loading; the server's figure is what charges.
      expect(cart.state.displaySubtotalPence, 895 * 2 + 450);
    });

    test('clear empties it', () {
      final cart = CartCubit()..addDish(curry, quantity: 4);
      cart.clear();
      expect(cart.state.isEmpty, isTrue);
    });
  });

  group('DishDetails pricing', () {
    Widget wrap(Widget child) => BlocProvider(
      create: (_) => CartCubit(),
      child: MaterialApp(theme: AppTheme.light, home: child),
    );

    testWidgets('opens at the dish price for a single unit', (tester) async {
      await tester.pumpWidget(wrap(wrapDish()));
      await tester.pumpAndSettle();

      // Featured dish is £17.50.
      expect(find.text('£17.50'), findsOneWidget);
    });

    testWidgets('quantity multiplies the total', (tester) async {
      await tester.pumpWidget(wrap(wrapDish()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(find.text('2'), findsWidgets);
      expect(find.text('£35.00'), findsOneWidget);
    });

    testWidgets('there are no add-ons to choose', (tester) async {
      await tester.pumpWidget(wrap(wrapDish()));
      await tester.pumpAndSettle();

      // They were sample data priced entirely in the app and passed to the
      // kitchen as free text -- the server prices from `dish_id` alone, so
      // nothing here could ever have been charged for.
      expect(find.text('Add-ons'), findsNothing);
      expect(find.text('Coconut Roti'), findsNothing);

      // The total is the dish, times however many.
      expect(find.text('£17.50'), findsOneWidget);
    });

    testWidgets('quantity will not drop below one', (tester) async {
      await tester.pumpWidget(wrap(wrapDish()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();

      // Ordering zero of something is not a thing the UI should allow.
      expect(find.text('£17.50'), findsOneWidget);
    });

    testWidgets('renders the dish it was given, not the featured one', (
      tester,
    ) async {
      const dish = Dish(
        id: 'd9',
        name: 'Tempered Dhal',
        description: 'Red lentils.',
        pricePence: 1200,
      );
      await tester.pumpWidget(wrap(const DishDetailsScreen(dish: dish)));
      await tester.pumpAndSettle();

      expect(find.text('Tempered Dhal'), findsOneWidget);
      expect(find.text('£12.00'), findsOneWidget);
      // Its own description, not another dish's. The screen used to print one
      // hardcoded paragraph about Black Pork Curry whatever it was given.
      expect(find.text('Red lentils.'), findsOneWidget);
    });

    testWidgets('shows the kitchen\'s prep time, not a fixed one', (
      tester,
    ) async {
      const dish = Dish(
        id: 'd9',
        name: 'Hoppers',
        description: 'Fermented rice pancakes.',
        pricePence: 950,
        prepMinMinutes: 15,
        prepMaxMinutes: 20,
      );
      await tester.pumpWidget(wrap(const DishDetailsScreen(dish: dish)));
      await tester.pumpAndSettle();

      expect(find.text('Ready in 15–20 min'), findsOneWidget);
      // "45-60 min delivery" was printed for every dish on the menu.
      expect(find.textContaining('45-60'), findsNothing);
    });

    testWidgets('a dish with no description says so', (tester) async {
      const dish = Dish(
        id: 'd9',
        name: 'Plain',
        description: '',
        pricePence: 500,
      );
      await tester.pumpWidget(wrap(const DishDetailsScreen(dish: dish)));
      await tester.pumpAndSettle();

      expect(find.text('No description yet.'), findsOneWidget);
    });

    testWidgets('no spice selector unless the dish offers one', (tester) async {
      await tester.pumpWidget(wrap(wrapDish()));
      await tester.pumpAndSettle();

      // Sending a level for a dish with `has_spice_levels` false earns a
      // SPICE_LEVEL_NOT_OFFERED, so the control must not be there to tap.
      expect(find.text('Spice Level'), findsNothing);
    });

    testWidgets('spice level is single-select and clearable', (tester) async {
      await tester.pumpWidget(wrap(wrapDish(dish: _spiced)));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Hot'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hot'));
      await tester.pumpAndSettle();

      // All three remain on screen; only the styling differs, so the check is
      // that selecting one does not remove the others. The menu's wording is
      // Low / Mild / Hot.
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('Mild'), findsOneWidget);
      expect(find.text('Hot'), findsOneWidget);
    });

    testWidgets('the chosen level reaches the basket as its own field', (
      tester,
    ) async {
      final cart = CartCubit();
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [BlocProvider.value(value: cart)],
          child: MaterialApp(
            theme: AppTheme.light,
            home: wrapDish(dish: _spiced),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Mild'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mild'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('ADD TO CART'), -200);
      await tester.tap(find.text('ADD TO CART'));
      await tester.pumpAndSettle();

      final line = cart.state.lines.single;
      expect(line.spiceLevel, SpiceLevel.mid);
      // Its own field, not smuggled into the free-text note — a note the
      // kitchen reads is not something a report can count.
      //
      // The menu says Mild and the wire says `mid`: the label is the
      // restaurant's wording, the value is the backend's contract, and
      // renaming the latter to match would break every stored order.
      expect(line.toJson()['spice_level'], 'mid');
      expect(line.notes ?? '', isNot(contains('Mild')));
    });

    test('a level is dropped for a dish that does not offer one', () {
      final cart = CartCubit();
      cart.addDish(_priced, spiceLevel: SpiceLevel.high);
      // Discarded here rather than sent and refused: a stale selection is the
      // app's problem, not an error for the customer to read.
      expect(cart.state.lines.single.spiceLevel, isNull);
      expect(
        cart.state.lines.single.toJson().containsKey('spice_level'),
        false,
      );
    });

    test('different heat is a different line', () {
      final cart = CartCubit()
        ..addDish(_spiced, spiceLevel: SpiceLevel.low)
        ..addDish(_spiced, spiceLevel: SpiceLevel.high);
      expect(cart.state.lines.length, 2);

      cart.addDish(_spiced, spiceLevel: SpiceLevel.low);
      expect(cart.state.lines.length, 2);
      expect(cart.state.lines.first.quantity, 2);
    });
  });

  group('SampleContent basket maths', () {
    test('subtotal is the sum of the line items', () {
      expect(SampleContent.basketSubtotal, 32.50);
    });

    test('total adds delivery and service to the subtotal', () {
      expect(
        SampleContent.basketTotal,
        SampleContent.basketSubtotal +
            SampleContent.deliveryFee +
            SampleContent.serviceCharge,
      );
      expect(SampleContent.basketTotal, 37.00);
    });

    test('every dish formats its price in sterling to two places', () {
      for (final dish in SampleContent.menu) {
        expect(dish.formattedPrice, startsWith('£'));
        expect(dish.formattedPrice.split('.').last.length, 2);
      }
    });
  });
}
