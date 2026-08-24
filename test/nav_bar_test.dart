import 'dart:ui' show ImageFilter, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:practice/core/theme/app_colors.dart';
import 'package:practice/core/theme/app_theme.dart';
import 'package:practice/shared/widgets/app_nav_bar.dart';

/// The Flutter tab bar's visual contract.
///
/// This is the bar on Android and web; iOS gets the real `UITabBar`. It follows
/// Material 3's `NavigationBar` metrics, and what is asserted here is the set of
/// things easy to break while changing something else and invisible in a diff:
/// the selected tab being a pill with its label beside the icon, one icon size,
/// the outlined-to-filled swap, an edge-to-edge bar with no shadow, and the
/// system inset sitting inside it.
void main() {
  const items = [
    AppNavItem(
      label: 'Menu',
      icon: Icons.restaurant_outlined,
      selectedIcon: Icons.restaurant,
    ),
    AppNavItem(
      label: 'Orders',
      icon: Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
    ),
  ];

  Widget wrap({
    int currentIndex = 0,
    ValueChanged<int>? onTap,
    ThemeData? theme,
    double bottomInset = 34,
  }) {
    return MaterialApp(
      theme: theme ?? AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AppNavBar(
            items: items,
            currentIndex: currentIndex,
            onTap: onTap ?? (_) {},
          ),
        ),
      ),
    );
  }

  /// The wrapper above is fixed at one index, which is right for the static
  /// checks and useless for the animated ones -- a tap has to actually move the
  /// selection or every frame looks identical.
  Widget live({int initialIndex = 0}) => MaterialApp(
    theme: AppTheme.light,
    home: MediaQuery(
      data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
      child: _LiveBar(items: items, initialIndex: initialIndex),
    ),
  );

  testWidgets('spans the full width — it is not a floating card', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byType(AppNavBar));
    final screen = tester.getRect(find.byType(MaterialApp));

    expect(bar.left, screen.left);
    expect(bar.right, screen.right);
    // Flush to the bottom edge: M3 anchors the bar to the screen, with the
    // gesture inset inside it rather than below a hovering pill.
    expect(bar.bottom, screen.bottom);
  });

  testWidgets('draws no shadow and no surrounding border', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>();

    expect(decorations, isNotEmpty);
    for (final decoration in decorations) {
      // A hairline stands in for M3's elevation. A drop shadow under an
      // edge-to-edge bar makes it look like a card that touches the bottom.
      expect(decoration.boxShadow, anyOf(isNull, isEmpty));

      final border = decoration.border;
      if (border != null) {
        expect(border, isA<Border>());
        final sides = border as Border;
        expect(sides.left, BorderSide.none);
        expect(sides.right, BorderSide.none);
        expect(sides.bottom, BorderSide.none);
        expect(sides.top.width, lessThanOrEqualTo(0.5));
      }
    }
  });

  testWidgets('the selected tab gets M3\'s active indicator and the tint', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(currentIndex: 1));
    await tester.pumpAndSettle();

    // Every tab builds its pill; only the selected one is filled in, so
    // selection can animate rather than pop in.
    final alphas = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(Container),
          ),
        )
        .map((c) => (c.decoration as BoxDecoration?)?.color?.a)
        .whereType<double>()
        .toList();
    expect(alphas, containsAll(<double>[1.0, 0.0]));

    // Tinted with the app's own accent container, not M3's secondaryContainer:
    // selection should read as the brand crimson.
    final pill = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .where((box) => box.color == AppSurfaces.light.accentContainer)
        .first;
    expect(pill.color, AppSurfaces.light.accentContainer);

    final accent = AppTheme.light.colorScheme.primary;
    final selected = tester.widget<Icon>(find.byIcon(Icons.receipt_long).first);
    expect(selected.color, accent);
    // ...and the unselected glyph is the outline variant in muted ink.
    final unselected = tester.widget<Icon>(
      find.byIcon(Icons.restaurant_outlined).first,
    );
    expect(unselected.color, isNot(accent));
  });

  testWidgets('every pill is 40 tall and icons are one size', (tester) async {
    await tester.pumpWidget(wrap(currentIndex: 1));
    await tester.pumpAndSettle();

    // Selected or not, each tab's pill is the same height -- only its width and
    // its fill change -- so nothing rises or drops as the selection moves.
    final heights = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.constraints?.maxHeight)
        .whereType<double>()
        .toSet();
    expect(heights, {40.0});

    // One icon size across every tab. A 24 beside a 25 reads as a mistake
    // without ever looking obviously wrong.
    final sizes = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(Icon),
          ),
        )
        .map((icon) => icon.size);
    expect(sizes, everyElement(24.0));
  });

  testWidgets('the whole cell is the touch target', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final cell = tester.getSize(find.byType(InkResponse).first);
    // Well past the 48pt minimum in both directions.
    expect(cell.height, greaterThanOrEqualTo(48));
    expect(cell.width, greaterThanOrEqualTo(48));

    // A tap near the cell's edge — not on the glyph — still registers.
    final taps = <int>[];
    await tester.pumpWidget(wrap(onTap: taps.add));
    final rect = tester.getRect(find.byType(InkResponse).last);
    await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
    expect(taps, [1]);
  });

  testWidgets('blurs what is behind it', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final backdrop = tester.widget<BackdropFilter>(
      find
          .descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(BackdropFilter),
          )
          .first,
    );
    expect(backdrop.filter, isA<ImageFilter>());
  });

  testWidgets('the system inset is inside the bar, not overlapped', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(bottomInset: 34));
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byType(AppNavBar));
    final label = tester.getRect(find.text('Menu'));

    // Content sits above the gesture area; the bar itself extends behind it.
    expect(bar.bottom - label.bottom, greaterThanOrEqualTo(34));
    expect(bar.height, AppNavBar.barHeight + 34);
  });

  testWidgets('pads itself where there is no system inset', (tester) async {
    await tester.pumpWidget(wrap(bottomInset: 0));
    await tester.pumpAndSettle();

    // 64 + 16 — M3's 80pt bar, reached the other way round.
    expect(
      tester.getRect(find.byType(AppNavBar)).height,
      AppNavBar.barHeight + AppNavBar.bottomPaddingWithoutInset,
    );
    expect(AppNavBar.barHeight + AppNavBar.bottomPaddingWithoutInset, 80);
  });

  testWidgets('a large text scale does not break the fixed height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.4)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AppNavBar(items: items, currentIndex: 0, onTap: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Clamped rather than allowed to overflow: the bar's height is fixed, so an
    // unbounded label would push the indicator out of it.
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(AppNavBar)).height,
      AppNavBar.barHeight + AppNavBar.bottomPaddingWithoutInset,
    );
  });

  testWidgets('reports taps and stays keyboard/screen-reader legible', (
    tester,
  ) async {
    final taps = <int>[];
    await tester.pumpWidget(wrap(onTap: taps.add));
    await tester.pumpAndSettle();

    // By glyph, not by label: an unselected tab no longer shows its name.
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    expect(taps, [1]);

    // Selection must reach assistive tech; a tint and a pill are both invisible
    // to it.
    final semantics = tester.getSemantics(find.text('Menu'));
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
  });

  testWidgets('renders in dark theme without exception', (tester) async {
    await tester.pumpWidget(wrap(theme: AppTheme.dark, currentIndex: 1));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('the dark pill stays a wash, so the label stays readable', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(theme: AppTheme.dark, currentIndex: 1));
    await tester.pumpAndSettle();

    final pill = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(AppNavBar),
            matching: find.byType(Container),
          ),
        )
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .whereType<Color>()
        .reduce((a, b) => a.a >= b.a ? a : b);

    // The dark palette's container is a 13% crimson wash. Fading it in with
    // `withValues(alpha: t)` *replaced* that alpha, so at full selection the
    // pill became solid crimson -- the very colour the label is drawn in, and
    // the label disappeared into it. Light mode was unaffected only because
    // its container is opaque to begin with.
    expect(pill.a, lessThan(0.5));

    final label = tester.widget<Text>(find.text('Orders'));
    final ink = label.style!.color!;
    expect(ink.a, 1.0);

    // The two must not be the same colour at the same strength.
    expect(pill.a, isNot(closeTo(ink.a, 0.01)));
  });

  testWidgets('only the selected tab shows its name', (tester) async {
    await tester.pumpWidget(live());
    await tester.pumpAndSettle();

    expect(find.text('Menu'), findsOneWidget);
    // The inactive tab is a bare glyph...
    expect(find.text('Orders'), findsNothing);

    // ...but it still has a name, so hiding the word costs a screen-reader
    // user nothing.
    expect(
      tester.getSemantics(find.byIcon(Icons.receipt_long_outlined)),
      matchesSemantics(
        label: 'Orders',
        isButton: true,
        isFocusable: true,
        hasSelectedState: true,
        isSelected: false,
        hasTapAction: true,
        hasFocusAction: true,
        tooltip: 'Orders',
      ),
    );

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();

    // The name follows the selection rather than both being shown at once.
    expect(find.text('Orders'), findsOneWidget);
    expect(find.text('Menu'), findsNothing);
  });

  testWidgets('the pill grows into what the other tabs give up', (
    tester,
  ) async {
    await tester.pumpWidget(live());
    await tester.pumpAndSettle();

    Size pillFor(IconData icon) => tester.getSize(
      find
          .ancestor(of: find.byIcon(icon), matching: find.byType(Container))
          .first,
    );

    final selectedAtRest = pillFor(Icons.restaurant);
    final unselectedAtRest = pillFor(Icons.receipt_long_outlined);
    expect(selectedAtRest.width, greaterThan(unselectedAtRest.width));
    // Height never changes -- only width does. A pill that grew taller would
    // push the glyph off the bar's centre line.
    expect(selectedAtRest.height, unselectedAtRest.height);

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();

    // The two have swapped roles. The exact widths differ because the labels
    // do -- "Orders" is wider than "Menu" -- so what is pinned is the
    // relationship, not a number.
    expect(
      pillFor(Icons.receipt_long).width,
      greaterThan(pillFor(Icons.restaurant_outlined).width),
    );
    expect(
      pillFor(Icons.restaurant_outlined).width,
      closeTo(unselectedAtRest.width, 1),
    );
  });

  testWidgets('the bar itself never resizes or moves while switching', (
    tester,
  ) async {
    await tester.pumpWidget(live());
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byType(AppNavBar));

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // Mid-flight is where a bar that reflows shows it.
    expect(tester.getRect(find.byType(AppNavBar)), before);

    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(AppNavBar)), before);
  });

  testWidgets('the two glyphs cross-fade as one, never both faint', (
    tester,
  ) async {
    await tester.pumpWidget(live());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    // The first pump starts the animation; the second lands inside it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final pair = tester
        .widgetList<Icon>(
          find.descendant(
            of: find
                .ancestor(
                  of: find.byIcon(Icons.receipt_long),
                  matching: find.byType(Stack),
                )
                .first,
            matching: find.byType(Icon),
          ),
        )
        .map((icon) => icon.color!.a)
        .toList();

    // Outline and filled, and their alphas are two halves of one value.
    // Summing to less than one would show as a ghost of both.
    expect(pair, hasLength(2));
    expect(pair[0] + pair[1], closeTo(1, 0.0001));
    // Actually mid-flight, not settled at either end.
    expect(pair[1], greaterThan(0));
    expect(pair[1], lessThan(1));
  });

  testWidgets('a press answers immediately, and lets go', (tester) async {
    await tester.pumpWidget(live());
    await tester.pumpAndSettle();

    double scaleOf(IconData icon) => tester
        .widget<AnimatedScale>(
          find
              .ancestor(
                of: find.byIcon(icon),
                matching: find.byType(AnimatedScale),
              )
              .first,
        )
        .scale;

    expect(scaleOf(Icons.receipt_long_outlined), 1);

    final gesture = await tester.press(
      find.byIcon(Icons.receipt_long_outlined),
    );
    // The tooltip's long-press recogniser is in the arena too, so the tap
    // recogniser holds `onTapDown` until it wins rather than firing on the
    // first frame.
    await tester.pump(const Duration(milliseconds: 150));
    // Subtle, not a bounce: the whole pill dips as one.
    expect(scaleOf(Icons.receipt_long_outlined), lessThan(1));
    expect(scaleOf(Icons.receipt_long_outlined), greaterThan(0.9));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scaleOf(Icons.receipt_long), 1);
  });
}

/// Owns the selected index, so a tap moves it.
class _LiveBar extends StatefulWidget {
  const _LiveBar({required this.items, required this.initialIndex});

  final List<AppNavItem> items;
  final int initialIndex;

  @override
  State<_LiveBar> createState() => _LiveBarState();
}

class _LiveBarState extends State<_LiveBar> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: AppNavBar(
      items: widget.items,
      currentIndex: _index,
      onTap: (index) => setState(() => _index = index),
    ),
  );
}
