import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/animations/motion.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class AppNavItem {
  const AppNavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;

  /// Outlined glyph, for an inactive item.
  final IconData icon;

  /// Filled glyph, for the active one.
  final IconData selectedIcon;
}

/// The tab bar everywhere iOS's own material isn't available — Android and web.
///
/// The selected tab is a pill with its label *beside* the icon; the others are
/// bare icons. The pill grows into the space the other tabs give up, so the
/// selection reads as one object moving along the bar rather than four items
/// each changing state.
///
/// Metrics still follow M3 where they apply:
///
///  * **64pt of content, plus the system inset.** M3 specifies an 80pt bar;
///    that is 64 of content and 16 of bottom padding, which on Android is the
///    gesture inset. So the inset is added below the content rather than baked
///    in, and a device without one gets [bottomPaddingWithoutInset] instead.
///  * **A 40pt-tall active pill**, tinted with the app's own `accentContainer`
///    rather than `secondaryContainer`, so selection reads as the brand crimson.
///  * **24pt glyphs, outlined → filled.** One icon size across every tab; the
///    fill and the tint change together.
///  * **Edge to edge, flush to the bottom.** M3 anchors the bar to the screen
///    edge — a floating rounded card is an M2 idiom.
///
/// Hiding the inactive labels is the one real cost of this shape, so every tab
/// keeps its name in [Semantics] and in a tooltip: a screen reader still reads
/// "Orders, tab 2 of 5" whether or not the word is on screen.
///
/// [BackdropFilter] is kept from the previous design: the shell sets
/// `extendBody`, so content scrolls behind the bar, and a light blur under a
/// near-opaque surface keeps that from looking like a clipping fault.
class AppNavBar extends StatefulWidget {
  const AppNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.tint,
  });

  /// M3's content height. The system inset is added below this, not carved out
  /// of it — see the class note.
  static const double barHeight = 64;

  /// M3's 16pt bottom padding, for a device with no gesture inset of its own.
  static const double bottomPaddingWithoutInset = 16;

  /// The active pill's height, and the corner radius that follows from it.
  static const double _pillHeight = 40;

  /// How much wider the selected tab is than an unselected one, as flex. The
  /// row hands out space in these proportions, so the pill grows into exactly
  /// what the others give up and the bar never changes size.
  static const int _restingFlex = 100;
  static const int _selectedExtraFlex = 130;

  final List<AppNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Selected-item colour. Defaults to the theme's primary.
  final Color? tint;

  @override
  State<AppNavBar> createState() => _AppNavBarState();
}

class _AppNavBarState extends State<AppNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.fast,
    value: 1,
  );

  /// The tab the pill is travelling *from*. Tracked explicitly rather than
  /// inferred, because a jump from the first tab to the last must not light up
  /// the two in between on the way past.
  int? _leaving;

  @override
  void didUpdateWidget(AppNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _leaving = oldWidget.currentIndex;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// How selected tab [index] is, from 0 to 1.
  double _selectionOf(int index, double progress) {
    if (index == widget.currentIndex) return progress;
    if (index == _leaving) return 1 - progress;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = context.surfaces;
    final accent = widget.tint ?? theme.colorScheme.primary;
    final motion = context.motion;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // M3's bar is an opaque `surfaceContainer`. Held just short of opaque so the
    // blur still has something to do where content passes behind, which is the
    // one thing an edge-to-edge bar over a scrolling list needs.
    final fill = surfaces.raised.withValues(alpha: 0.94);

    return ClipRect(
      child: BackdropFilter(
        // Lighter than the old glass blur: the surface above it is nearly
        // opaque, so this only has to soften what shows through at the edges.
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            border: Border(
              // A hairline instead of M3's elevation. An edge-to-edge bar with a
              // drop shadow reads as a card that happens to touch the bottom.
              top: BorderSide(color: surfaces.line, width: 0.5),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: bottomInset > 0
                  ? bottomInset
                  : AppNavBar.bottomPaddingWithoutInset,
            ),
            child: SizedBox(
              height: AppNavBar.barHeight,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  // Eased once, here, and shared by every tab: the pill's
                  // width, its colour, the glyph swap and the label's reveal
                  // all read from this one number, so they cannot drift apart.
                  final progress = motion.reduced
                      ? 1.0
                      : Motion.enter.transform(_controller.value);

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (index, item) in widget.items.indexed)
                        Flexible(
                          flex:
                              AppNavBar._restingFlex +
                              (AppNavBar._selectedExtraFlex *
                                      _selectionOf(index, progress))
                                  .round(),
                          child: _NavButton(
                            item: item,
                            selection: _selectionOf(index, progress),
                            accent: accent,
                            onTap: () => widget.onTap(index),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab: a pill that carries its label when selected, and a bare glyph when
/// not.
///
/// [selection] runs 0 to 1 and is computed once by the bar, so the pill's
/// colour, the label's reveal, the glyph swap and the tint all move on exactly
/// the same clock. Nothing here starts an animation of its own except the press.
class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.item,
    required this.selection,
    required this.accent,
    required this.onTap,
  });

  final AppNavItem item;
  final double selection;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final motion = context.motion;
    final surfaces = context.surfaces;
    final t = widget.selection;
    final selected = t > 0.5;
    final colour = Color.lerp(surfaces.inkMuted, widget.accent, t)!;

    return Semantics(
      button: true,
      selected: selected,
      // The name is here whether or not it is on screen, so hiding the
      // inactive labels costs a screen-reader user nothing.
      label: widget.item.label,
      child: Tooltip(
        message: widget.item.label,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            // No haptic here: the shell plays the selection tick for whichever
            // bar is on screen, and firing one from both places double-taps the
            // motor.
            onTap: widget.onTap,
            // Tracked so the cell can answer the finger before the tab has
            // changed. The ripple alone lags a fast tap on a slow frame.
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            // The whole cell is the target — 64pt tall, comfortably past the
            // 48pt minimum — but the ripple is a rounded rect inside it, so it
            // never runs into the bar's edges or its neighbour.
            containedInkWell: true,
            highlightShape: BoxShape.rectangle,
            borderRadius: BorderRadius.circular(AppNavBar._pillHeight / 2),
            // No ripple and no highlight. The crimson wash spreading out of
            // the tap read as a second, unexplained colour arriving beside the
            // pill -- and it outlived the pill's own 200ms move, so the bar was
            // still flushing red after the selection had finished. The press
            // dip below is the feedback; it is faster and it moves the thing
            // the finger is actually on.
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            child: Center(
              child: AnimatedScale(
                // A press the eye can just about catch, and nothing more.
                scale: _pressed ? motion.pressScale : 1,
                duration: motion.move(Motion.instant),
                curve: motion.standard,
                child: Container(
                  height: AppNavBar._pillHeight,
                  padding: EdgeInsets.symmetric(
                    // Room for the label to sit in, appearing as it does.
                    horizontal: 12 + (4 * t),
                  ),
                  decoration: BoxDecoration(
                    // Fades in with everything else rather than switching on.
                    //
                    // Scaled, not replaced. `withValues(alpha: t)` overwrites
                    // the channel, and the dark palette's container is a 13%
                    // crimson wash -- so at t = 1 the pill became *fully
                    // opaque* crimson, which is the same colour the label is
                    // drawn in. The selected tab's name vanished into its own
                    // background, in dark mode only, because the light
                    // container happens to be opaque already.
                    color: surfaces.accentContainer.withValues(
                      alpha: surfaces.accentContainer.a * t,
                    ),
                    borderRadius: BorderRadius.circular(
                      AppNavBar._pillHeight / 2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // The two glyphs are the same size in the same place, so
                      // this is a weight change rather than a swap: their
                      // alphas always sum to one, and neither ghosts.
                      //
                      // Faded through the colour rather than through `Opacity`.
                      // A glyph is a single colour, so the result is identical
                      // -- but `Opacity` between 0 and 1 pushes a saveLayer,
                      // and this was two of them per tab on every frame of the
                      // move.
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            widget.item.icon,
                            size: _glyphSize,
                            color: colour.withValues(alpha: 1 - t),
                          ),
                          Icon(
                            widget.item.selectedIcon,
                            size: _glyphSize,
                            color: colour.withValues(alpha: t),
                          ),
                        ],
                      ),
                      // Revealed by width rather than faded in place: the label
                      // slides out from behind the icon as the pill opens, so
                      // there is never text sitting in a space too small for
                      // it. `Flexible` is what bounds it -- a non-flex child of
                      // a Row is laid out unbounded, and an unbounded Text
                      // cannot ellipsise, it overflows.
                      if (t > 0)
                        Flexible(
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              widthFactor: t,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: AppSpacing.x2,
                                ),
                                child: MediaQuery.withClampedTextScaling(
                                  // Clamped, because the bar's height is fixed:
                                  // past about 1.2 the label starts fighting
                                  // the pill rather than wrapping.
                                  maxScaleFactor: 1.2,
                                  child: Text(
                                    widget.item.label,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.navLabel(
                                      colour,
                                    ).copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// M3's tab glyph, and the app's `xxl` step less four — 24 is the one size
/// every bar icon uses.
const double _glyphSize = 24;
