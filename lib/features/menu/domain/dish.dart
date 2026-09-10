import 'package:equatable/equatable.dart';

import '../../../core/money/pence.dart';

import 'dish_configuration.dart';

/// One picture in a dish's gallery.
///
/// Named `DishPhoto` rather than `DishImage` because the widget that draws one
/// already owns that name; two `DishImage`s in scope is a needless ambiguity.
///
/// The API returns a Cloudinary `public_id` alongside the URL. The id is what
/// admin reorder and remove operations address, so it is kept even though only
/// the URL is needed to draw anything.
class DishPhoto extends Equatable {
  const DishPhoto({required this.publicId, required this.url});

  factory DishPhoto.fromJson(Map<String, dynamic> json) => DishPhoto(
    publicId: json['public_id']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
  );

  final String publicId;
  final String url;

  /// Sent back verbatim when creating or updating a dish — the API takes exactly
  /// what its upload endpoint returned.
  Map<String, dynamic> toJson() => {'public_id': publicId, 'url': url};

  @override
  List<Object?> get props => [publicId, url];
}

/// A section of the menu.
class MenuCategory extends Equatable {
  const MenuCategory({
    required this.id,
    required this.slug,
    required this.name,
    this.description,
    this.imageUrl,
    this.sortOrder = 0,
    this.parentId,
  });

  factory MenuCategory.fromJson(Map<String, dynamic> json) => MenuCategory(
    id: json['id']?.toString() ?? '',
    slug: json['slug']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    description: json['description']?.toString(),
    imageUrl: json['image_url']?.toString(),
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    // Null for a top-level section; set for a child of one. The menu uses it to
    // nest Curry -> Meat Curries without a second endpoint. Filtering dishes by
    // a parent includes its active children, so the app never has to walk the
    // tree itself to build a category's list.
    parentId: json['parent_id']?.toString(),
  );

  final String id;
  final String slug;
  final String name;
  final String? description;

  /// A photograph for the section, where one has been uploaded. The home
  /// screen's circles use it in place of a glyph.
  final String? imageUrl;

  final int sortOrder;

  /// The section this one sits under, or null when it is top level.
  final String? parentId;

  /// Whether this is a top-level section rather than a child of one.
  bool get isTopLevel => parentId == null || parentId!.isEmpty;

  @override
  List<Object?> get props => [
    id,
    slug,
    name,
    description,
    imageUrl,
    sortOrder,
    parentId,
  ];
}

/// A dish as the public menu describes it.
///
/// Field names follow the API: it calls the dish's name `title`, and a dish
/// belongs to *several* categories rather than one — a dish can appear in more
/// than one section of the menu. Both were different when this was written
/// against an earlier version of the backend, which is why the JSON keys and the
/// Dart names don't line up everywhere; the Dart side keeps `name` because forty
/// call sites read it and "name" is what it is.
class Dish extends Equatable {
  const Dish({
    required this.id,
    required this.name,
    required this.description,
    required this.pricePence,
    this.categories = const [],
    this.images = const [],
    this.imageUrlOverride,
    this.thumbnailUrl,
    this.prepMinMinutes,
    this.prepMaxMinutes,
    this.isVegetarian = false,
    this.isVegan = false,
    this.isGlutenFree = false,
    this.allergens = const [],
    this.isAvailable = true,
    this.hasSpiceLevels = false,
    this.createdAt,
    this.variants = const [],
    this.optionGroups = const [],
    this.requiresVariantSelection = false,
  });

  factory Dish.fromJson(Map<String, dynamic> json) {
    final images = json['images'];
    final categories = json['categories'];
    final variants = json['variants'];
    final optionGroups = json['option_groups'];
    return Dish(
      id: json['id']?.toString() ?? '',
      // `title` is the API's name for it. `name` is kept as a fallback so a
      // fixture or an older deployment still parses.
      name: (json['title'] ?? json['name'])?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      // Pence, integer, always. Never parsed as a double — money in floating
      // point is how totals end up a penny out.
      pricePence: (json['price_pence'] as num?)?.toInt() ?? 0,
      categories: categories is List
          ? categories
                .whereType<Map>()
                .map((c) => MenuCategory.fromJson(Map<String, dynamic>.from(c)))
                .toList()
          : const [],
      images: images is List
          ? images
                .whereType<Map>()
                .map((i) => DishPhoto.fromJson(Map<String, dynamic>.from(i)))
                .toList()
          : const [],
      // The API computes both, so the app doesn't have to reach into the gallery
      // to find the picture it should draw.
      imageUrlOverride: json['image_url']?.toString(),
      thumbnailUrl: json['thumbnail_url']?.toString(),
      prepMinMinutes: (json['preparation_time_min_minutes'] as num?)?.toInt(),
      prepMaxMinutes: (json['preparation_time_max_minutes'] as num?)?.toInt(),
      // The current API sends no dietary flags. Still parsed, because the fields
      // are cheap and the badges reappear by themselves if the backend adds them
      // back — see [dietaryTag].
      isVegetarian: json['is_vegetarian'] == true,
      isVegan: json['is_vegan'] == true,
      isGlutenFree: json['is_gluten_free'] == true,
      allergens:
          (json['allergens'] as List?)?.whereType<String>().toList() ??
          const [],
      // Absent means available. A sold-out dish is still listed — the API is
      // explicit that it comes back with this false so the app can grey it out
      // rather than hide it.
      isAvailable: json['is_available'] != false,
      // Absent means no choice offered. Defaulting the other way would put a
      // spice selector on every dish the moment an older deployment answered.
      hasSpiceLevels: json['has_spice_levels'] == true,
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at'].toString())?.toLocal(),
      // Sorted once here so no screen has to remember to. An older deployment
      // sends neither key, which is exactly the unconfigured dish the rest of
      // the app already handles.
      variants: variants is List
          ? (variants
                .whereType<Map>()
                .map((v) => DishVariant.fromJson(Map<String, dynamic>.from(v)))
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
          : const [],
      optionGroups: optionGroups is List
          ? (optionGroups
                .whereType<Map>()
                .map(
                  (g) => DishOptionGroup.fromJson(Map<String, dynamic>.from(g)),
                )
                .toList()
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
          : const [],
      requiresVariantSelection: json['requires_variant_selection'] == true,
    );
  }

  final String id;
  final String name;
  final String description;
  final int pricePence;

  /// Every section this dish appears in. Empty is legitimate — an uncategorised
  /// dish is hidden from the public menu but still exists in admin.
  final List<MenuCategory> categories;

  final List<DishPhoto> images;

  /// The API's own `image_url`, which wins over reaching into [images].
  final String? imageUrlOverride;

  final String? thumbnailUrl;

  /// How long the kitchen says it takes, as a range.
  final int? prepMinMinutes;
  final int? prepMaxMinutes;
  final bool isVegetarian;
  final bool isVegan;
  final bool isGlutenFree;
  final List<String> allergens;

  /// False means the admin has taken it off the menu. Still listed, not
  /// orderable — the API is explicit about that so the menu doesn't appear to
  /// shrink through the evening.
  final bool isAvailable;

  /// Whether the kitchen offers Low/Mid/High for this dish.
  ///
  /// False means no selector at all — sending a level for such a dish earns a
  /// `SPICE_LEVEL_NOT_OFFERED`, so the control must not be there to tap.
  final bool hasSpiceLevels;

  /// When the dish was added, for showing the newest first.
  final DateTime? createdAt;

  /// The sizes, servings, portions or packages this dish is sold in, in
  /// `sort_order`.
  ///
  /// Empty is the ordinary case and means the dish has one price: [pricePence].
  /// Nothing here may be assumed about *what kind* of choice it is — the same
  /// list carries "14-inch", "Bottle" and "6 Items", and inventing labels like
  /// Small/Medium/Large would put words on the menu the admin never wrote.
  final List<DishVariant> variants;

  /// Every group of choices the dish defines. Which of them apply depends on
  /// the selected variant, so read them through `DishSelection.groups` rather
  /// than rendering this list directly.
  final List<DishOptionGroup> optionGroups;

  /// Whether the size/serving choice should read as required.
  ///
  /// Presentation only — the app still pre-selects the default variant so the
  /// screen opens on a price, and this makes the selector look like a decision
  /// rather than a detail.
  final bool requiresVariantSelection;

  /// Whether this dish is sold in more than one form at all.
  bool get isConfigurable => variants.isNotEmpty || optionGroups.isNotEmpty;

  /// The variant the screen should open on: the default, else the first that
  /// can be bought, else the first that exists.
  DishVariant? get defaultVariant {
    if (variants.isEmpty) return null;
    for (final variant in variants) {
      if (variant.isDefault && variant.isAvailable) return variant;
    }
    for (final variant in variants) {
      if (variant.isAvailable) return variant;
    }
    return variants.first;
  }

  /// The cheapest price a customer could pay, for a card that has to show one
  /// number. Falls back to [pricePence] for an unconfigured dish.
  int get fromPricePence {
    final sellable = [
      for (final variant in variants)
        if (variant.isAvailable) variant.pricePence,
    ];
    if (sellable.isEmpty) return pricePence;
    return sellable.reduce((a, b) => a < b ? a : b);
  }

  /// Whether a card should say "from £x" rather than a flat price — true only
  /// when the variants actually differ in price.
  bool get hasPriceRange {
    final sellable = [
      for (final variant in variants)
        if (variant.isAvailable) variant.pricePence,
    ];
    if (sellable.length < 2) return false;
    return sellable.any((price) => price != sellable.first);
  }

  DishOptionGroup? optionGroupById(String id) {
    for (final group in optionGroups) {
      if (group.id == id) return group;
    }
    return null;
  }

  /// The picture to draw. The API's `image_url` first, then the gallery's first
  /// entry, which is the one it treats as primary.
  String? get imageUrl {
    final override = imageUrlOverride;
    if (override != null && override.isNotEmpty) return override;
    return images.isEmpty ? null : images.first.url;
  }

  /// Ids of the sections this dish is in, for filtering without a join.
  List<String> get categoryIds => [for (final c in categories) c.id];

  /// The kitchen's estimate as a phrase, or null where the API sent no times.
  String? get prepTime {
    final min = prepMinMinutes, max = prepMaxMinutes;
    if (min == null && max == null) return null;
    if (min == null || max == null) return '${min ?? max} min';
    return min == max ? '$min min' : '$min–$max min';
  }

  double get price => pricePence / 100;

  /// The price for a card.
  ///
  /// "from £12.50" where the variants differ, because a single number beside a
  /// pizza sold in three sizes is a number the customer will not be charged.
  String get formattedPrice => hasPriceRange
      ? 'from ${formatPence(fromPricePence)}'
      : formatPence(fromPricePence);

  /// The single badge worth showing on a card. Vegan is the stronger claim, so
  /// it wins over vegetarian; a dish with neither shows nothing rather than an
  /// invented label.
  String? get dietaryTag {
    if (isVegan) return 'Vegan';
    if (isVegetarian) return 'Vegetarian';
    if (isGlutenFree) return 'Gluten free';
    return null;
  }

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    pricePence,
    categories,
    images,
    imageUrlOverride,
    thumbnailUrl,
    prepMinMinutes,
    prepMaxMinutes,
    isVegetarian,
    isVegan,
    isGlutenFree,
    allergens,
    isAvailable,
    hasSpiceLevels,
    createdAt,
    variants,
    optionGroups,
    requiresVariantSelection,
  ];
}
