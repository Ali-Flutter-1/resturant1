/// Content used to lay out and review screens before the API exists.
///
/// This is deliberately a single file of plain values with no repository,
/// data source or mock service behind it. When the real contract arrives,
/// delete this file — each screen then takes the same shapes from a bloc.
///
/// Prices are in **£** throughout. The Figma file is inconsistent: Discover
/// and The Menu price in dollars while Dish Details, Checkout and the admin
/// screens price in pounds. A London restaurant settles that argument.
library;

import 'package:flutter/material.dart';

class SampleDish {
  const SampleDish({
    required this.name,
    required this.description,
    required this.price,
    this.tag,
    this.isFavourite = false,
    this.rating,
    this.reviewCount,
    this.imageUrl,
  });

  final String name;
  final String description;
  final double price;
  final String? tag;
  final bool isFavourite;
  final double? rating;
  final int? reviewCount;

  /// Null until the API supplies photography; `DishImage` shows a tinted
  /// placeholder in the meantime.
  final String? imageUrl;

  String get formattedPrice => '£${price.toStringAsFixed(2)}';
}

abstract final class SampleContent {
  /// Real `IconData` constants. These were raw codepoints, which rendered as
  /// whatever glyph happened to sit at that position in the icon font — a
  /// smiley for Breakfast, a wifi symbol for Drinks.
  static const categories = <({String label, IconData icon})>[
    (label: 'Breakfast', icon: Icons.egg_alt_outlined),
    (label: 'Curry', icon: Icons.ramen_dining_outlined),
    (label: 'Kottu', icon: Icons.rice_bowl_outlined),
    (label: 'Sides', icon: Icons.lunch_dining_outlined),
    (label: 'Drinks', icon: Icons.local_cafe_outlined),
  ];

  /// The Figma file shows only three chips, with "Curry Dishes" selected on
  /// load — which would open the menu already hiding every non-curry dish.
  /// "All" is added so the default state shows the whole menu.
  static const menuFilters = ['All', 'Curry Dishes', 'Vegan', 'Main Dishes'];

  /// Tags a dish can carry, as offered in the admin editor.
  ///
  /// Collected from the tags the design's own dishes use. A dish carries one
  /// tag, so this is a single choice — when the API defines the real
  /// vocabulary this list is what it replaces.
  static const dishTags = [
    'Spicy',
    'Vegan',
    'Vegetarian',
    'Authentic Sri Lankan',
    'Chef’s Choice',
  ];

  static const featured = SampleDish(
    name: 'Black Pork Curry',
    description:
        'Authentic rich and spicy dark roasted curry, a true heritage classic.',
    price: 17.50,
    tag: 'Authentic Sri Lankan',
    rating: 4.8,
    reviewCount: 124,
  );

  static const popular = [
    SampleDish(
      name: 'String Hoppers Set',
      description: '10 String hoppers with pol sambol and kiri hodi.',
      price: 8.50,
    ),
    SampleDish(
      name: 'Chicken Kottu',
      description: 'Street food style chopped roti with chicken.',
      price: 12.00,
    ),
  ];

  static const menu = [
    SampleDish(
      name: 'Jaffna Crab Curry',
      description:
          'Fresh mud crab cooked in a robust blend of roasted spices and coconut milk.',
      price: 28.00,
      tag: 'Spicy',
      isFavourite: true,
    ),
    SampleDish(
      name: 'Young Jackfruit Curry',
      description:
          'Tender baby jackfruit slow-cooked in a mild, aromatic coconut gravy.',
      price: 18.00,
      tag: 'Vegan',
    ),
    SampleDish(
      name: 'Black Pork Curry',
      description:
          'A heritage recipe featuring deeply roasted spices and goraka.',
      price: 22.00,
      isFavourite: true,
    ),
    SampleDish(
      name: 'Tempered Dhal',
      description:
          'Red lentils cooked with turmeric, coconut milk and curry leaves.',
      price: 12.00,
      tag: 'Vegan',
    ),
  ];

  static const spiceLevels = ['Low', 'Mild', 'Hot'];

  static const addOns = [
    (
      name: 'Coconut Roti',
      description: 'Warm, freshly grated coconut flatbread',
      price: 3.50,
    ),
    (
      name: 'Extra Sambal',
      description: 'Spicy onion relish for an extra kick',
      price: 1.50,
    ),
  ];

  static const seatingPreferences = [
    'Any Available',
    'Main Dining Room',
    'Terrace',
  ];

  static const basket = [
    (
      quantity: 1,
      name: 'Ceylon Spiced Chicken Curry',
      note: 'Extra spicy, No coriander',
      price: 14.50,
    ),
    (
      quantity: 2,
      name: 'Heritage Hoppers Set',
      note: 'With Seeni Sambol',
      price: 18.00,
    ),
  ];

  static const deliveryFee = 3.50;
  static const serviceCharge = 1.00;

  static double get basketSubtotal =>
      basket.fold(0, (sum, item) => sum + item.price);

  static double get basketTotal => basketSubtotal + deliveryFee + serviceCharge;
}
