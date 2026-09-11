import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/features/menu/presentation/dish_details_screen.dart';

import 'package:practice/core/money/pence.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/features/admin/domain/admin_order.dart';
import 'package:practice/features/admin/domain/dish_configuration_draft.dart';
import 'package:practice/features/cart/cart_cubit.dart';
import 'package:practice/features/menu/domain/dish.dart';
import 'package:practice/features/menu/domain/dish_configuration.dart';
import 'package:practice/features/menu/domain/dish_selection.dart';
import 'package:practice/features/menu/domain/spice_level.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/features/orders/domain/menu_staleness.dart';
import 'package:practice/features/orders/domain/order_quote.dart';

/// The worked example from the API guide, verbatim.
///
/// Using the document's own dish rather than an invented one matters: the
/// numbers in section 5 are the contract, and a test built on convenient
/// fixtures can agree with itself while disagreeing with the backend.
final _breakfastJson = {
  'id': 'dish-uuid',
  'title': "T's Heritage Custom Breakfast",
  'price_pence': 1195,
  'is_available': true,
  'requires_variant_selection': true,
  'variants': [
    {
      'id': 'four-variant-uuid',
      'code': 'four-item',
      'name': '4 Items',
      'price_pence': 850,
      'is_default': false,
      'is_available': true,
      'sort_order': 0,
      'option_groups': [
        {
          'option_group_id': 'breakfast-group-uuid',
          'group_code': 'breakfast-items',
          'min_quantity': 4,
          'max_quantity': 100,
          'included_quantity': 4,
        },
      ],
    },
    {
      'id': 'six-variant-uuid',
      'code': 'six-item',
      'name': '6 Items',
      'price_pence': 1195,
      'is_default': true,
      'is_available': true,
      'sort_order': 1,
      'option_groups': [
        {
          'option_group_id': 'breakfast-group-uuid',
          'group_code': 'breakfast-items',
          'min_quantity': 6,
          'max_quantity': 100,
          'included_quantity': 6,
        },
      ],
    },
  ],
  'option_groups': [
    {
      'id': 'breakfast-group-uuid',
      'code': 'breakfast-items',
      'name': 'Choose Your Items',
      'selection_type': 'multiple',
      'pricing_mode': 'excess_only',
      'sort_order': 0,
      'options': [
        {
          'id': 'egg-hopper-option-uuid',
          'code': 'egg-hopper',
          'name': 'Egg Hopper',
          'price_pence': 150,
          'max_quantity': 20,
          'is_default': false,
          'is_available': true,
          'sort_order': 0,
        },
        {
          'id': 'bacon-option-uuid',
          'code': 'crispy-bacon',
          'name': 'Crispy Bacon',
          'price_pence': 200,
          'max_quantity': 20,
          'is_default': false,
          'is_available': true,
          'sort_order': 1,
        },
      ],
    },
  ],
};

/// A pizza: two sizes, a single-choice crust with a default, and a paid extra.
final _pizzaJson = {
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
          'included_quantity': 0,
        },
        {
          'option_group_id': 'extras',
          'group_code': 'extras',
          'min_quantity': 0,
          'max_quantity': 3,
          'included_quantity': 0,
        },
      ],
    },
    {
      'id': 'v16',
      'code': 'sixteen-inch',
      'name': '16-inch',
      'price_pence': 1750,
      'is_default': false,
      'sort_order': 1,
      // Deliberately offers only the crust: the 16-inch takes no extras.
      'option_groups': [
        {
          'option_group_id': 'crust',
          'group_code': 'crust',
          'min_quantity': 1,
          'max_quantity': 1,
          'included_quantity': 0,
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
        {
          'id': 'sourdough',
          'code': 'sourdough',
          'name': 'Sourdough',
          'price_pence': 100,
          'is_available': false,
          'sort_order': 2,
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
          'max_quantity': 2,
          'sort_order': 0,
        },
      ],
    },
  ],
};

DishOptionGroup _group(Dish dish, String id) => dish.optionGroupById(id)!;
DishOption _option(DishOptionGroup group, String id) => group.optionById(id)!;

void main() {
  final breakfast = Dish.fromJson(_breakfastJson);
  final pizza = Dish.fromJson(_pizzaJson);

  group('parsing a configurable dish', () {
    test('reads variants and groups, sorted as the admin ordered them', () {
      expect(breakfast.variants.map((v) => v.name), ['4 Items', '6 Items']);
      expect(breakfast.requiresVariantSelection, isTrue);
      expect(breakfast.isConfigurable, isTrue);

      final items = _group(breakfast, 'breakfast-group-uuid');
      expect(items.pricingMode, OptionPricingMode.excessOnly);
      expect(items.selectionType, OptionSelectionType.multiple);
      expect(items.options.map((o) => o.name), ['Egg Hopper', 'Crispy Bacon']);
    });

    test('the default variant is the one flagged, not the first', () {
      expect(breakfast.defaultVariant?.name, '6 Items');
    });

    test('a dish with no variants stays an ordinary dish', () {
      const plain = Dish(
        id: 'd',
        name: 'Poppadom',
        description: '',
        pricePence: 150,
      );
      expect(plain.isConfigurable, isFalse);
      expect(plain.hasPriceRange, isFalse);
      expect(plain.formattedPrice, '£1.50');
      expect(DishSelection.forDish(plain).groups, isEmpty);
      expect(DishSelection.forDish(plain).unitPricePence, 150);
    });

    test('a card says "from" only when the variants actually differ', () {
      expect(pizza.hasPriceRange, isTrue);
      expect(pizza.formattedPrice, 'from £12.50');

      // Two variants at one price is not a range, and "from" would be a lie.
      final flat = Dish.fromJson({
        ..._pizzaJson,
        'variants': [
          {'id': 'a', 'name': 'A', 'price_pence': 1250, 'is_default': true},
          {'id': 'b', 'name': 'B', 'price_pence': 1250},
        ],
      });
      expect(flat.hasPriceRange, isFalse);
      expect(flat.formattedPrice, '£12.50');
    });

    test('a category knows whether it is nested', () {
      final child = MenuCategory.fromJson({
        'id': 'c2',
        'name': 'Meat Curries',
        'parent_id': 'c1',
      });
      expect(child.parentId, 'c1');
      expect(child.isTopLevel, isFalse);
      expect(
        MenuCategory.fromJson({'id': 'c1', 'name': 'Curry'}).isTopLevel,
        isTrue,
      );
    });
  });

  group('the guide\'s breakfast example', () {
    // Section 5: the 6-item variant, 4 egg hoppers then 3 crispy bacon.
    // The first six units are included, so one bacon is charged at £2.00 and
    // the unit price is £13.95.
    DishSelection sixItemsWithSevenChosen() {
      var selection = DishSelection.forDish(breakfast);
      final items = _group(breakfast, 'breakfast-group-uuid');
      final hopper = _option(items, 'egg-hopper-option-uuid');
      final bacon = _option(items, 'bacon-option-uuid');

      for (var i = 0; i < 4; i++) {
        selection = selection.increment(items, hopper);
      }
      for (var i = 0; i < 3; i++) {
        selection = selection.increment(items, bacon);
      }
      return selection;
    }

    test('prices exactly as the document says', () {
      final selection = sixItemsWithSevenChosen();
      expect(selection.variant?.name, '6 Items');
      expect(selection.basePricePence, 1195);
      expect(selection.optionsPence, 200);
      expect(selection.unitPricePence, 1395);
      expect(formatPence(selection.unitPricePence), '£13.95');
    });

    test('splits the group into included and charged the way the API does', () {
      final pricing = sixItemsWithSevenChosen().pricingFor(
        _group(breakfast, 'breakfast-group-uuid'),
      );
      expect(pricing.chosen, 7);
      expect(pricing.included, 6);
      expect(pricing.charged, 1);
      expect(pricing.chargedPence, 200);
    });

    test('included_quantity does not cap the selection', () {
      // The trap the guide calls out: a 6-item breakfast must accept a
      // seventh item and charge for it, not refuse it.
      final selection = sixItemsWithSevenChosen();
      final items = _group(breakfast, 'breakfast-group-uuid');
      expect(
        selection.canIncrement(items, _option(items, 'bacon-option-uuid')),
        isTrue,
      );
      expect(selection.isComplete, isTrue);
    });

    test('selection order decides which units are free', () {
      // Bacon first: now two bacon are inside the allowance and the charged
      // unit is a £1.50 hopper, not a £2.00 bacon.
      final items = _group(breakfast, 'breakfast-group-uuid');
      var selection = DishSelection.forDish(breakfast);
      for (var i = 0; i < 3; i++) {
        selection = selection.increment(
          items,
          _option(items, 'bacon-option-uuid'),
        );
      }
      for (var i = 0; i < 4; i++) {
        selection = selection.increment(
          items,
          _option(items, 'egg-hopper-option-uuid'),
        );
      }
      expect(selection.pricingFor(items).chargedPence, 150);
    });

    test('a group short of its minimum blocks the order and says why', () {
      var selection = DishSelection.forDish(breakfast);
      final items = _group(breakfast, 'breakfast-group-uuid');
      selection = selection.increment(
        items,
        _option(items, 'egg-hopper-option-uuid'),
      );

      expect(selection.isComplete, isFalse);
      expect(selection.problem!.groupId, 'breakfast-group-uuid');
      expect(selection.problem!.message, contains('5 more'));
    });

    test('switching variant re-applies the new minimum', () {
      final items = _group(breakfast, 'breakfast-group-uuid');
      var selection = DishSelection.forDish(breakfast);
      for (var i = 0; i < 4; i++) {
        selection = selection.increment(
          items,
          _option(items, 'egg-hopper-option-uuid'),
        );
      }
      // Four is short for a 6-item box but exactly right for a 4-item one.
      expect(selection.isComplete, isFalse);

      final smaller = selection.selectVariant(breakfast.variants.first);
      expect(smaller.variant?.name, '4 Items');
      expect(smaller.isComplete, isTrue);
      expect(smaller.unitPricePence, 850);
    });
  });

  group('option group rules', () {
    test('a single-choice group starts on its default and replaces on tap', () {
      final selection = DishSelection.forDish(pizza);
      final crust = _group(pizza, 'crust');
      expect(selection.quantityOf(crust, _option(crust, 'traditional')), 1);

      final stuffed = selection.increment(crust, _option(crust, 'stuffed'));
      expect(stuffed.quantityOf(crust, _option(crust, 'traditional')), 0);
      expect(stuffed.chosenIn(crust), 1);
      expect(stuffed.unitPricePence, 1250 + 220);
    });

    test('a required single-choice group cannot be emptied', () {
      final crust = _group(pizza, 'crust');
      final selection = DishSelection.forDish(pizza);
      // Re-tapping the chosen answer would otherwise clear it and leave the
      // customer stuck against a minimum they cannot see how to satisfy.
      final again = selection.increment(crust, _option(crust, 'traditional'));
      expect(again.chosenIn(crust), 1);
    });

    test('an unavailable option cannot be chosen', () {
      final crust = _group(pizza, 'crust');
      final selection = DishSelection.forDish(pizza);
      final sourdough = _option(crust, 'sourdough');

      expect(selection.canIncrement(crust, sourdough), isFalse);
      expect(selection.increment(crust, sourdough), selection);
      expect(crust.available.map((o) => o.id), ['traditional', 'stuffed']);
    });

    test('the group ceiling and the option ceiling both hold', () {
      final extras = _group(pizza, 'extras');
      final cheese = _option(extras, 'cheese');
      var selection = DishSelection.forDish(pizza);

      selection = selection.increment(extras, cheese);
      selection = selection.increment(extras, cheese);
      // The option's own max_quantity is 2, below the group's 3.
      expect(selection.quantityOf(extras, cheese), 2);
      expect(selection.canIncrement(extras, cheese), isFalse);
      expect(selection.increment(extras, cheese), selection);
    });

    test('only the selected variant\'s groups are shown', () {
      final selection = DishSelection.forDish(pizza);
      expect(selection.groups.map((g) => g.id), ['crust', 'extras']);

      final large = selection.selectVariant(pizza.variants.last);
      expect(large.groups.map((g) => g.id), ['crust']);
      // And nothing from the dropped group reaches the wire.
      expect(
        large.wireSelections.map((s) => s.optionId),
        isNot(contains('cheese')),
      );
    });

    test('switching variant keeps choices the new variant still offers', () {
      final crust = _group(pizza, 'crust');
      final extras = _group(pizza, 'extras');
      var selection = DishSelection.forDish(pizza);
      selection = selection.increment(crust, _option(crust, 'stuffed'));
      selection = selection.increment(extras, _option(extras, 'cheese'));

      final large = selection.selectVariant(pizza.variants.last);
      // The crust survives; the extra cheese does not, because the 16-inch
      // does not offer that group at all.
      expect(large.quantityOf(crust, _option(crust, 'stuffed')), 1);
      expect(large.unitPricePence, 1750 + 220);
    });

    test('the wire payload is ids and quantities, and nothing else', () {
      final crust = _group(pizza, 'crust');
      final extras = _group(pizza, 'extras');
      var selection = DishSelection.forDish(pizza);
      selection = selection.increment(extras, _option(extras, 'cheese'));

      expect(selection.wireSelections.map((s) => s.toJson()), [
        {'option_id': 'traditional', 'quantity': 1},
        {'option_id': 'cheese', 'quantity': 1},
      ]);
      // Nothing at zero ever appears.
      final cleared = selection.decrement(extras, _option(extras, 'cheese'));
      expect(cleared.wireSelections.map((s) => s.optionId), ['traditional']);
      expect(crust, isNotNull);
    });
  });

  group('the basket', () {
    CartCubit cartWithPizza({required bool stuffed}) {
      final crust = _group(pizza, 'crust');
      var selection = DishSelection.forDish(pizza);
      if (stuffed) {
        selection = selection.increment(crust, _option(crust, 'stuffed'));
      }
      return CartCubit()..addSelection(selection);
    }

    test('sends variant_id and selections, and never a price', () {
      final line = cartWithPizza(stuffed: true).state.lines.single;
      final json = line.toJson();

      expect(json['dish_id'], 'pizza');
      expect(json['variant_id'], 'v12');
      expect(json['quantity'], 1);
      expect(json['selections'], [
        {'option_id': 'stuffed', 'quantity': 1},
      ]);
      // The server prices from the ids. Anything a client could set, a client
      // could forge.
      expect(json.keys, isNot(contains('price_pence')));
      expect(json.keys, isNot(contains('unit_price_pence')));
      expect(json.keys, isNot(contains('line_total_pence')));
    });

    test('an unconfigured dish omits variant_id entirely', () {
      const plain = Dish(
        id: 'd',
        name: 'Poppadom',
        description: '',
        pricePence: 150,
      );
      final cart = CartCubit()..addDish(plain);
      expect(
        cart.state.lines.single.toJson().keys,
        isNot(contains('variant_id')),
      );
      expect(
        cart.state.lines.single.toJson().keys,
        isNot(contains('selections')),
      );
    });

    test('identically configured meals merge into one line', () {
      final cart = cartWithPizza(stuffed: true);
      final crust = _group(pizza, 'crust');
      cart.addSelection(
        DishSelection.forDish(
          pizza,
        ).increment(crust, _option(crust, 'stuffed')),
      );

      expect(cart.state.lines, hasLength(1));
      expect(cart.state.lines.single.quantity, 2);
    });

    test('differently configured meals stay separate lines', () {
      final cart = cartWithPizza(stuffed: true);
      cart.addSelection(DishSelection.forDish(pizza));

      expect(cart.state.lines, hasLength(2));
      expect(cart.state.count, 2);
    });

    test('a different size of the same dish is a different line', () {
      final cart = cartWithPizza(stuffed: false);
      cart.addSelection(
        DishSelection.forDish(pizza).selectVariant(pizza.variants.last),
      );
      expect(cart.state.lines, hasLength(2));
      expect(cart.state.lines.map((l) => l.variantId), ['v12', 'v16']);
    });

    test('an incomplete configuration is refused rather than sent', () {
      final cart = CartCubit();
      // The default 6-item breakfast has nothing chosen and needs six.
      final added = cart.addSelection(DishSelection.forDish(breakfast));

      expect(added, isFalse);
      expect(cart.state.lines, isEmpty);
    });

    test('the basket row can name the variant before any quote arrives', () {
      final line = cartWithPizza(stuffed: true).state.lines.single;
      expect(line.titleWithVariant, 'Margherita (12-inch)');
      expect(line.selectionSummary, 'Garlic Butter Stuffed');
      expect(line.displayPricePence, 1470);
    });
  });

  group('the quote is the authority', () {
    final quote = OrderQuote.fromJson({
      'items': [
        {
          'dish_id': 'dish-uuid',
          'variant_id': 'six-variant-uuid',
          'name': "T's Heritage Custom Breakfast",
          'variant_name': '6 Items',
          'base_price_pence': 1195,
          'options_total_pence': 200,
          'unit_price_pence': 1395,
          'quantity': 1,
          'line_total_pence': 1395,
          'selections': [
            {
              'option_id': 'egg-hopper-option-uuid',
              'group_name': 'Choose Your Items',
              'option_name': 'Egg Hopper',
              'quantity': 4,
              'included_quantity': 4,
              'chargeable_quantity': 0,
              'unit_price_pence': 150,
              'total_pence': 0,
            },
            {
              'option_id': 'bacon-option-uuid',
              'group_name': 'Choose Your Items',
              'option_name': 'Crispy Bacon',
              'quantity': 3,
              'included_quantity': 2,
              'chargeable_quantity': 1,
              'unit_price_pence': 200,
              'total_pence': 200,
            },
          ],
        },
      ],
      'subtotal_pence': 1395,
      'delivery_fee_pence': 350,
      'total_pence': 1745,
      'minimum_order_pence': 1500,
      'meets_minimum': false,
      'delivery_zone_id': 'zone-2',
      'delivery_zone_name': 'Zone 2',
    });

    test('reads the line, its variant and its breakdown', () {
      final line = quote.lines.single;
      expect(line.variantName, '6 Items');
      expect(line.titleWithVariant, "T's Heritage Custom Breakfast (6 Items)");
      expect(line.basePricePence, 1195);
      expect(line.optionsTotalPence, 200);
      expect(line.unitPricePence, 1395);
    });

    test('keeps the included and charged split per option', () {
      final selections = quote.lines.single.selections;
      expect(selections.first.label, '4 x Egg Hopper');
      expect(selections.first.isCharged, isFalse);
      expect(selections.last.includedQuantity, 2);
      expect(selections.last.chargeableQuantity, 1);
      expect(selections.last.totalPence, 200);
      expect(quote.lines.single.chargedSelections, hasLength(1));
    });

    test('names the zone that priced the delivery', () {
      expect(quote.deliveryZoneName, 'Zone 2');
      // The fee never counts towards the minimum, so the shortfall is measured
      // on the subtotal alone.
      expect(quote.meetsMinimum, isFalse);
      expect(quote.shortfallPence, 105);
    });

    test('derives the missing half of a split when only one is sent', () {
      final partial = QuoteSelection.fromJson({
        'option_name': 'Egg Hopper',
        'quantity': 3,
        'chargeable_quantity': 1,
      });
      expect(partial.includedQuantity, 2);
    });
  });

  group('an order receipt', () {
    test('keeps the variant and the options that were bought', () {
      final item = CustomerOrderItem.fromJson({
        'name': 'Breakfast',
        'variant_name': '6 Items',
        'quantity': 1,
        'line_total_pence': 1395,
        'selections': [
          {'option_name': 'Crispy Bacon', 'quantity': 3, 'total_pence': 200},
        ],
      });
      expect(item.titleWithVariant, 'Breakfast (6 Items)');
      expect(item.selections.single.label, '3 x Crispy Bacon');
      expect(item.selections.single.isCharged, isTrue);
    });

    test('a kitchen ticket lists every option, charged or not', () {
      final line = AdminOrderLine.fromJson({
        'name': 'Breakfast',
        'variant_name': '6 Items',
        'quantity': 1,
        'line_total_pence': 1395,
        'selections': [
          {'option_name': 'Egg Hopper', 'quantity': 4, 'total_pence': 0},
          {'option_name': 'Crispy Bacon', 'quantity': 3, 'total_pence': 200},
        ],
      });
      expect(line.title, 'Breakfast (6 Items)');
      // A free hopper still has to be cooked.
      expect(line.selections.map((s) => s.label), [
        '4 x Egg Hopper',
        '3 x Crispy Bacon',
      ]);
    });
  });

  group('the card payment state matrix', () {
    CustomerOrder order(String status, String payment) =>
        CustomerOrder.fromJson({
          'id': 'o1',
          'order_number': 'A1',
          'status': status,
          'payment_method': 'card',
          'payment_status': payment,
          'payment_url': 'https://pay.example/1',
          'total_pence': 1000,
        });

    test('a pending card order is the one that offers Pay', () {
      final pending = order('awaiting_payment', 'pending');
      expect(pending.status, CustomerOrderStatus.awaitingPayment);
      expect(pending.needsPayment, isTrue);
      expect(pending.statusLabel, 'Payment needed');
      // It has not reached the kitchen, so it is not on the tracker.
      expect(pending.status.step, isNull);
      expect(pending.status.isLive, isTrue);
    });

    test('an authorised order never offers Pay again', () {
      final authorised = order('awaiting_payment', 'authorized');
      expect(authorised.needsPayment, isFalse);
      expect(authorised.paymentStatus.isCommitted, isTrue);
      // Approval happened before payment, so capture follows on its own --
      // there is no second restaurant step to tell the customer to wait for.
      expect(authorised.paymentMessage, contains('Confirming'));
      expect(
        authorised.paymentMessage,
        isNot(contains('Waiting for the restaurant')),
      );
    });

    test('capture and cancel in progress offer nothing and keep polling', () {
      for (final payment in ['capture_pending', 'cancel_pending']) {
        final settling = order('acceptance_pending', payment);
        expect(settling.needsPayment, isFalse, reason: payment);
        expect(settling.isSettlingPayment, isTrue, reason: payment);
        expect(settling.isPaymentInFlight, isTrue, reason: payment);
      }
    });

    test('a captured order is paid', () {
      final captured = order('preparing', 'captured');
      expect(captured.isPaid, isTrue);
      expect(captured.needsPayment, isFalse);
      expect(captured.paymentMessage, isNull);
    });

    test('a released hold says plainly that nothing was taken', () {
      final released = order('cancelled', 'cancelled');
      expect(released.needsPayment, isFalse);
      expect(released.paymentMessage, contains('not been charged'));
    });

    test('a decline can be retried, and needs a brand new page', () {
      final declined = order('awaiting_payment', 'failed');
      expect(declined.needsPayment, isTrue);
      expect(declined.paymentFailed, isTrue);
      // Worldpay treats a repeated reference as the same payment, so the old
      // URL is useless and POST /pay must be called first.
      expect(declined.needsFreshPaymentPage, isTrue);
    });

    test('a pending order that never got a URL also asks for a fresh one', () {
      final noUrl = CustomerOrder.fromJson({
        'id': 'o1',
        'status': 'awaiting_payment',
        'payment_method': 'card',
        'payment_status': 'pending',
        'total_pence': 1000,
      });
      expect(noUrl.needsFreshPaymentPage, isTrue);
    });

    test('a cash order is never asked to pay in the app', () {
      final cash = CustomerOrder.fromJson({
        'id': 'o1',
        'status': 'preparing',
        'payment_method': 'cash',
        'payment_status': 'pending',
        'total_pence': 1000,
      });
      expect(cash.needsPayment, isFalse);
      expect(cash.paymentMessage, isNull);
    });

    test('the transient states are understood rather than unknown', () {
      expect(
        OrderStatus.fromApi('acceptance_pending'),
        OrderStatus.acceptancePending,
      );
      expect(
        OrderStatus.fromApi('cancellation_pending'),
        OrderStatus.cancellationPending,
      );
      // Nothing leads out of them: the backend advances the order when the
      // provider answers, and a button here is a second capture attempt.
      expect(
        OrderStatus.acceptancePending.isSettling &&
            OrderStatus.cancellationPending.isSettling,
        isTrue,
      );
      for (final type in FulfilmentType.values) {
        expect(
          OrderTransitions.nextFor(OrderStatus.acceptancePending, type),
          isEmpty,
        );
        expect(
          OrderTransitions.nextFor(OrderStatus.cancellationPending, type),
          isEmpty,
        );
      }
    });

    test('staff cannot start cooking an unpaid card order', () {
      final next = OrderTransitions.nextFor(
        OrderStatus.awaitingPayment,
        FulfilmentType.collection,
      );
      expect(next, isNot(contains(OrderStatus.preparing)));
      expect(next, contains(OrderStatus.rejected));
    });
  });

  group('a menu that changed under the customer', () {
    ApiFailure withCode(String code) =>
        ApiFailure(kind: ApiFailureKind.invalid, message: 'no', code: code);

    test('a withdrawn dish drops its line', () {
      final staleness = MenuStaleness.of(withCode('DISH_SOLD_OUT'));
      expect(staleness, MenuStaleness.dishGone);
      expect(staleness.dropsLine, isTrue);
      expect(staleness.needsRefresh, isTrue);
    });

    test('a stale variant or option refreshes but keeps the line', () {
      for (final code in [
        'VARIANT_NOT_OFFERED',
        'VARIANT_SOLD_OUT',
        'OPTION_SOLD_OUT',
        'OPTION_NOT_OFFERED',
      ]) {
        final staleness = MenuStaleness.of(withCode(code));
        expect(staleness.needsRefresh, isTrue, reason: code);
        expect(staleness.dropsLine, isFalse, reason: code);
      }
    });

    test('a broken rule is fixed in place, without a refetch', () {
      for (final code in [
        'OPTION_QUANTITY_EXCEEDED',
        'OPTION_GROUP_MINIMUM_NOT_MET',
        'OPTION_GROUP_MAXIMUM_EXCEEDED',
        'OPTION_GROUP_SINGLE_ONLY',
        'SPICE_LEVEL_NOT_OFFERED',
      ]) {
        final staleness = MenuStaleness.of(withCode(code));
        expect(staleness, MenuStaleness.configurationInvalid, reason: code);
        expect(staleness.needsRefresh, isFalse, reason: code);
      }
    });

    test('a delivery problem is not a menu problem', () {
      for (final code in [
        'BELOW_MINIMUM_ORDER',
        'POSTCODE_REQUIRED',
        'OUTSIDE_DELIVERY_AREA',
      ]) {
        expect(MenuStaleness.of(withCode(code)), MenuStaleness.none);
        expect(isDeliveryFailure(withCode(code)), isTrue);
      }
    });

    test('an unknown code triggers no speculative refresh', () {
      expect(MenuStaleness.of(withCode('SOMETHING_NEW')), MenuStaleness.none);
      expect(MenuStaleness.of(withCode('SOMETHING_NEW')).recovery, isNull);
    });
  });

  group('an admin configuration draft', () {
    DishConfigurationDraft draftOf(Dish dish) =>
        DishConfigurationDraft.fromDish(dish);

    test('round-trips a live dish without changing it', () {
      final draft = draftOf(pizza);
      expect(draft.isValid, isTrue);
      expect(draft.variants.map((v) => v.code), [
        'twelve-inch',
        'sixteen-inch',
      ]);
      // Rules are addressed by group code, which is what survives a rename.
      expect(draft.variants.first.rules.map((r) => r.groupCode), [
        'crust',
        'extras',
      ]);
    });

    test('sends the complete structure, because PUT replaces it', () {
      final json = draftOf(pizza).toJson();
      expect(json.keys, containsAll(['variants', 'option_groups']));
      final crust = (json['option_groups'] as List).first as Map;
      expect(crust['selection_type'], 'single');
      expect(crust['pricing_mode'], 'always');
      // null max_quantity is sent, not omitted: it means "no ceiling", and
      // leaving the key out would let a previous limit survive a replace.
      final extrasRule =
          ((json['variants'] as List).first as Map)['option_groups'] as List;
      expect((extrasRule.last as Map).containsKey('max_quantity'), isTrue);
    });

    test('refuses a structure the server would reject', () {
      expect(
        const DishConfigurationDraft().problems.first,
        contains('at least one'),
      );

      const twoDefaults = DishConfigurationDraft(
        variants: [
          VariantDraft(code: 'a', name: 'A', pricePence: 100, isDefault: true),
          VariantDraft(code: 'b', name: 'B', pricePence: 100, isDefault: true),
        ],
      );
      expect(twoDefaults.problems.first, contains('2 are set'));

      const duplicateCodes = DishConfigurationDraft(
        variants: [
          VariantDraft(code: 'a', name: 'A', pricePence: 100, isDefault: true),
          VariantDraft(code: 'a', name: 'Also A', pricePence: 100),
        ],
      );
      expect(
        duplicateCodes.problems.any((p) => p.contains('share the code')),
        isTrue,
      );
    });

    test('catches a rule pointing at a group that does not exist', () {
      const orphan = DishConfigurationDraft(
        variants: [
          VariantDraft(
            code: 'a',
            name: 'A',
            pricePence: 100,
            isDefault: true,
            rules: [GroupRuleDraft(groupCode: 'ghost')],
          ),
        ],
      );
      expect(orphan.problems.first, contains('does not exist'));
    });

    test('catches a single-choice group allowed more than one', () {
      const contradiction = DishConfigurationDraft(
        variants: [
          VariantDraft(
            code: 'a',
            name: 'A',
            pricePence: 100,
            isDefault: true,
            rules: [GroupRuleDraft(groupCode: 'crust', maxQuantity: 2)],
          ),
        ],
        optionGroups: [
          OptionGroupDraft(
            code: 'crust',
            name: 'Crust',
            selectionType: OptionSelectionType.single,
          ),
        ],
      );
      expect(
        contradiction.problems.any((p) => p.contains('single choice')),
        isTrue,
      );
    });

    test('catches a maximum below its minimum', () {
      const backwards = DishConfigurationDraft(
        variants: [
          VariantDraft(
            code: 'a',
            name: 'A',
            pricePence: 100,
            isDefault: true,
            rules: [
              GroupRuleDraft(
                groupCode: 'items',
                minQuantity: 4,
                maxQuantity: 2,
              ),
            ],
          ),
        ],
        optionGroups: [OptionGroupDraft(code: 'items', name: 'Items')],
      );
      expect(
        backwards.problems.any((p) => p.contains('fewer than it requires')),
        isTrue,
      );
    });
  });

  group('the dish screen', () {
    /// A tall window, so every group is on screen.
    ///
    /// The default 800x600 puts the option rows under the fold behind a 280pt
    /// stretchy header, and a tap that misses still dispatches at that offset —
    /// hitting whatever is there instead and passing for the wrong reason.
    Future<void> show(WidgetTester tester, Widget app) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
    }

    /// The running total lives in an [AnimatedSwitcher], which `pumpAndSettle`
    /// leaves one frame short of showing its new child. A real duration is what
    /// makes the new figure readable.
    Future<void> settleMoney(WidgetTester tester) =>
        tester.pump(const Duration(milliseconds: 400));

    Widget wrap(CartCubit cart, Dish dish) => BlocProvider.value(
      value: cart,
      child: MaterialApp(
        theme: AppTheme.light,
        home: DishDetailsScreen(dish: dish),
      ),
    );

    testWidgets('offers every variant at its own price', (tester) async {
      await show(tester, wrap(CartCubit(), pizza));

      expect(find.text('12-inch'), findsOneWidget);
      expect(find.text('16-inch'), findsOneWidget);
      // Each variant's own price, not the dish's single `price_pence`.
      expect(find.text('£17.50'), findsOneWidget);
    });

    testWidgets('shows only the groups the chosen variant offers', (
      tester,
    ) async {
      await show(tester, wrap(CartCubit(), pizza));
      expect(find.text('Extras'), findsOneWidget);

      // The 16-inch references only the crust group.
      await tester.tap(find.text('16-inch'));
      await tester.pumpAndSettle();
      expect(find.text('Extras'), findsNothing);
      expect(find.text('Crust Style'), findsOneWidget);
    });

    testWidgets('a sold-out option cannot be chosen', (tester) async {
      await show(tester, wrap(CartCubit(), pizza));

      expect(find.text('Sourdough'), findsOneWidget);
      expect(find.text('Sold out'), findsWidgets);
    });

    testWidgets('the running total follows the choices', (tester) async {
      await show(tester, wrap(CartCubit(), pizza));
      // The 12-inch on its traditional crust, which is free.
      expect(find.text('£12.50'), findsWidgets);

      await tester.tap(find.text('Garlic Butter Stuffed'));
      await tester.pumpAndSettle();
      await settleMoney(tester);
      expect(find.text('£14.70'), findsOneWidget);
    });

    testWidgets('an incomplete configuration explains itself instead of '
        'silently failing', (tester) async {
      final cart = CartCubit();
      await show(tester, wrap(cart, breakfast));

      await tester.tap(find.text('ADD TO CART'));
      await tester.pumpAndSettle();

      // Nothing was added, and the reason names the group and the shortfall.
      expect(cart.state.lines, isEmpty);
      expect(find.textContaining('Choose 6 more'), findsOneWidget);
    });

    testWidgets('a seventh breakfast item is allowed and priced', (
      tester,
    ) async {
      await show(tester, wrap(CartCubit(), breakfast));

      // Six egg hoppers, then a seventh item.
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.bySemanticsLabel('One more Egg Hopper'));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('included'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('One more Crispy Bacon'));
      await tester.pumpAndSettle();
      await settleMoney(tester);

      // Charged, not refused.
      expect(find.textContaining('1 extra'), findsOneWidget);
      expect(find.text('£13.95'), findsOneWidget);
    });

    testWidgets('a sold-out dish cannot be added at all', (tester) async {
      final soldOut = Dish.fromJson({..._pizzaJson, 'is_available': false});
      final cart = CartCubit();
      await show(tester, wrap(cart, soldOut));

      expect(find.text('SOLD OUT'), findsOneWidget);
      await tester.tap(find.text('SOLD OUT'));
      await tester.pumpAndSettle();
      expect(cart.state.lines, isEmpty);
    });
  });

  group('spice levels', () {
    test('the menu reads Low / Mild / Hot', () {
      expect(SpiceLevel.values.map((level) => level.label), [
        'Low',
        'Mild',
        'Hot',
      ]);
    });

    test('the wire values are unchanged, whatever the menu calls them', () {
      // The label and the value diverge in the middle on purpose. Renaming
      // `mid` to `mild` to match the menu would orphan every order already
      // stored against the old value.
      expect(SpiceLevel.values.map((level) => level.apiValue), [
        'low',
        'mid',
        'high',
      ]);
    });

    test('an order stored under any spelling still reads back', () {
      expect(SpiceLevel.tryParse('mid'), SpiceLevel.mid);
      expect(SpiceLevel.tryParse('mild'), SpiceLevel.mid);
      expect(SpiceLevel.tryParse('medium'), SpiceLevel.mid);
      expect(SpiceLevel.tryParse('hot'), SpiceLevel.high);
      expect(SpiceLevel.tryParse('high'), SpiceLevel.high);
      expect(SpiceLevel.tryParse('low'), SpiceLevel.low);
      // A receipt with an unknown level shows none rather than failing.
      expect(SpiceLevel.tryParse('nuclear'), isNull);
      expect(SpiceLevel.tryParse(null), isNull);
    });

    test('no description contradicts its own label', () {
      // The descriptions used to open with a second, different word -- "Mild"
      // under the Low chip, "Medium" under Mid -- which is exactly how the
      // wrong three names got onto the menu.
      for (final level in SpiceLevel.values) {
        for (final other in SpiceLevel.values) {
          if (other == level) continue;
          expect(
            level.description.toLowerCase(),
            isNot(contains(other.label.toLowerCase())),
            reason: '${level.label} description mentions ${other.label}',
          );
        }
      }
    });
  });

  group('money', () {
    test('formats integer pence without touching a double', () {
      expect(formatPence(1195), '£11.95');
      expect(formatPence(80), '£0.80');
      expect(formatPence(0), '£0.00');
      expect(formatPence(100), '£1.00');
    });

    test('groups thousands, so a day\'s takings are readable', () {
      expect(formatPence(431025), '£4,310.25');
      expect(formatPence(100000000), '£1,000,000.00');
    });

    test('the two formatters that used to disagree now agree', () {
      expect(OrderQuote.formatPence(431025), formatPence(431025));
    });

    test('a negative keeps its sign in front of the symbol', () {
      expect(formatPence(-150), '-£1.50');
    });

    test('a delta is signed, and nothing is shown for free', () {
      expect(formatPenceDelta(220), '+£2.20');
      expect(formatPenceDelta(0), isNull);
    });
  });
}
