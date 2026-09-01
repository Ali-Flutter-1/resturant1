import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/haptics/app_haptics.dart';
import '../../../core/network/api_failure.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../shared/widgets/app_surface.dart';
import '../../../shared/widgets/page_body.dart';
import '../../venue/domain/restaurant_location.dart';
import '../domain/delivery_zone.dart';
import '../domain/delivery_zone_repository.dart';

/// Draws or edits one delivery area.
///
/// The polygon is built by tapping the map: each tap adds a corner, and the
/// shape closes itself. That is the whole interaction -- dragging existing
/// vertices would need hit-testing against a map that is also panning, and
/// getting that subtly wrong on a touch screen is worse than redrawing a shape
/// that takes four taps to make.
///
/// Nothing is sent until Save, so a half-drawn area never prices an order.
class ZoneEditorScreen extends StatefulWidget {
  const ZoneEditorScreen({super.key, this.zone});

  /// The zone being changed, or null to draw a new one.
  final AdminDeliveryZone? zone;

  @override
  State<ZoneEditorScreen> createState() => _ZoneEditorScreenState();
}

class _ZoneEditorScreenState extends State<ZoneEditorScreen> {
  static const LatLng _venue = LatLng(
    RestaurantLocation.latitude,
    RestaurantLocation.longitude,
  );

  /// The API's own limits. Fewer than three points is not a shape; more than a
  /// hundred is refused.
  static const int _minPoints = 3;
  static const int _maxPoints = 100;

  late final _name = TextEditingController(text: widget.zone?.name ?? '');
  late final _minimum = TextEditingController(
    text: _pounds(widget.zone?.zone.minOrderPence),
  );
  late final _fee = TextEditingController(
    text: _pounds(widget.zone?.zone.deliveryFeePence),
  );
  late final _priority = TextEditingController(
    text: widget.zone?.zone.priority.toString() ?? '',
  );

  late List<ZonePoint> _points = [...?widget.zone?.zone.polygon];
  late String _colourHex = widget.zone?.zone.colorHex ?? _palette.first;
  late bool _isActive = widget.zone?.isActive ?? true;

  bool _saving = false;
  String? _error;

  /// Enough distinct colours for a handful of rings, and all of them legible
  /// over map tiles.
  static const List<String> _palette = [
    '#e8a33d',
    '#3d7de8',
    '#4caf50',
    '#9c27b0',
    '#e91e63',
  ];

  static String _pounds(int? pence) =>
      pence == null ? '' : (pence / 100).toStringAsFixed(2);

  @override
  void dispose() {
    _name.dispose();
    _minimum.dispose();
    _fee.dispose();
    _priority.dispose();
    super.dispose();
  }

  Color get _colour {
    final value = int.tryParse(_colourHex.replaceFirst('#', ''), radix: 16);
    return value == null ? Colors.orange : Color(0xFF000000 | value);
  }

  void _addPoint(LatLng point) {
    if (_points.length >= _maxPoints) {
      setState(() => _error = 'A zone can have at most $_maxPoints corners.');
      return;
    }
    AppHaptics.selection();
    setState(() {
      _points = [
        ..._points,
        ZonePoint(lat: point.latitude, lng: point.longitude),
      ];
      _error = null;
    });
  }

  void _undo() {
    if (_points.isEmpty) return;
    AppHaptics.toggle();
    setState(() => _points = _points.sublist(0, _points.length - 1));
  }

  void _clear() {
    if (_points.isEmpty) return;
    AppHaptics.toggle();
    setState(() => _points = const []);
  }

  /// Pounds and pence as an integer number of pence.
  ///
  /// Rounded, not truncated: 12.50 in binary floating point is 1249.9999… and
  /// `toInt()` would set the minimum a penny low.
  int? _pence(TextEditingController field) {
    final value = double.tryParse(field.text.trim());
    if (value == null || value < 0) return null;
    return (value * 100).round();
  }

  Future<void> _save() async {
    if (_saving) return;

    final name = _name.text.trim();
    if (name.isEmpty) return _fail('Give the area a name.');
    if (_points.length < _minPoints) {
      return _fail('Tap the map to draw at least $_minPoints corners.');
    }

    final minimum = _pence(_minimum);
    if (minimum == null) return _fail('Enter a minimum order, like 30.00.');
    final fee = _pence(_fee);
    if (fee == null) return _fail('Enter a delivery fee, like 4.00.');

    final priority = _priority.text.trim().isEmpty
        ? null
        : int.tryParse(_priority.text.trim());
    if (_priority.text.trim().isNotEmpty && priority == null) {
      return _fail('Priority is a whole number, lowest wins.');
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final repository = context.read<AdminDeliveryZoneRepository>();
    try {
      final saved = widget.zone == null
          ? await repository.create(
              name: name,
              polygon: _points,
              minOrderPence: minimum,
              deliveryFeePence: fee,
              colorHex: _colourHex,
              priority: priority,
              isActive: _isActive,
            )
          : await repository.update(
              widget.zone!.id,
              name: name,
              polygon: _points,
              minOrderPence: minimum,
              deliveryFeePence: fee,
              colorHex: _colourHex,
              priority: priority,
              isActive: _isActive,
            );

      if (!mounted) return;
      AppHaptics.success();
      Navigator.of(context).pop(saved);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      // The API's own words: it knows things this form cannot check, like a
      // polygon that crosses itself.
      _fail(failure.message);
    }
  }

  void _fail(String message) {
    AppHaptics.failure();
    setState(() {
      _error = message;
      _saving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.zone != null;

    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit area' : 'New area')),
      body: ListView(
        padding: pagePadding(
          context,
          top: AppSpacing.x4,
          bottom: AppSpacing.x8 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _MapEditor(
            points: _points,
            colour: _colour,
            centre: _points.isEmpty
                ? _venue
                : LatLng(_points.first.lat, _points.first.lng),
            onTap: _saving ? null : _addPoint,
          ),
          const SizedBox(height: AppSpacing.x3),
          Row(
            children: [
              Expanded(
                child: Text(
                  _points.isEmpty
                      ? 'Tap the map to place the corners of this area.'
                      : '${_points.length} '
                            '${_points.length == 1 ? "corner" : "corners"}'
                            '${_points.length < _minPoints ? " — at least $_minPoints needed" : ""}',
                  style: context.texts.bodySmall?.copyWith(
                    color: _points.isNotEmpty && _points.length < _minPoints
                        ? context.orderColors.overdue
                        : context.surfaces.inkSoft,
                  ),
                ),
              ),
              TextButton(
                onPressed: _saving || _points.isEmpty ? null : _undo,
                child: const Text('Undo'),
              ),
              TextButton(
                onPressed: _saving || _points.isEmpty ? null : _clear,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),

          _Labelled(
            label: 'Name',
            child: TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Zone 1'),
            ),
          ),
          const SizedBox(height: AppSpacing.x4),

          Row(
            children: [
              Expanded(
                child: _Labelled(
                  label: 'Minimum order',
                  child: TextField(
                    controller: _minimum,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '30.00',
                      prefixText: '£ ',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: _Labelled(
                  label: 'Delivery fee',
                  child: TextField(
                    controller: _fee,
                    enabled: !_saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '4.00',
                      prefixText: '£ ',
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),

          _Labelled(
            label: 'Priority',
            child: TextField(
              controller: _priority,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(hintText: '1'),
            ),
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(
            // The one rule an admin can get wrong in a way nobody notices until
            // a customer is overcharged.
            'Where areas overlap the lowest number wins. Give the small inner '
            'area a lower number than the rings around it, or addresses in '
            'both are charged the dearer fee.',
            style: context.texts.bodySmall?.copyWith(
              color: context.surfaces.inkSoft,
            ),
          ),
          const SizedBox(height: AppSpacing.x4),

          Text('Colour', style: context.texts.bodySmall),
          const SizedBox(height: AppSpacing.x2),
          Wrap(
            spacing: AppSpacing.x3,
            children: [
              for (final hex in _palette)
                _ColourDot(
                  hex: hex,
                  selected: hex.toLowerCase() == _colourHex.toLowerCase(),
                  onTap: _saving
                      ? null
                      : () => setState(() => _colourHex = hex),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),

          AppSurface.row(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4,
              vertical: AppSpacing.x2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Delivering here', style: context.texts.titleSmall),
                      Text(
                        'Turn off to pause this area without deleting it.',
                        style: context.texts.bodySmall?.copyWith(
                          color: context.surfaces.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isActive,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _isActive = value),
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: AppSpacing.x4),
            Text(
              _error!,
              style: context.texts.bodySmall?.copyWith(
                color: context.orderColors.overdue,
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.x6),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            child: Text(
              _saving ? 'Saving…' : (editing ? 'Save changes' : 'Create area'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The map the polygon is drawn on.
class _MapEditor extends StatelessWidget {
  const _MapEditor({
    required this.points,
    required this.colour,
    required this.centre,
    required this.onTap,
  });

  final List<ZonePoint> points;
  final Color colour;
  final LatLng centre;
  final ValueChanged<LatLng>? onTap;

  @override
  Widget build(BuildContext context) {
    final latLngs = [for (final p in points) LatLng(p.lat, p.lng)];

    return AppSurface.row(
      padding: EdgeInsets.zero,
      clip: true,
      child: SizedBox(
        height: 300,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: centre,
            initialZoom: 10,
            onTap: onTap == null ? null : (_, point) => onTap!(point),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.tscafe.app',
            ),
            // Three points make a shape; fewer are drawn as the line so far,
            // so a half-finished outline is still visible.
            if (latLngs.length >= 3)
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: latLngs,
                    color: colour.withValues(alpha: 0.20),
                    borderColor: colour,
                    borderStrokeWidth: 2,
                  ),
                ],
              )
            else if (latLngs.length == 2)
              PolylineLayer(
                polylines: [
                  Polyline(points: latLngs, color: colour, strokeWidth: 2),
                ],
              ),
            MarkerLayer(
              markers: [
                for (final (index, point) in latLngs.indexed)
                  Marker(
                    point: point,
                    width: 22,
                    height: 22,
                    // Numbered, because the order the corners were tapped is
                    // the order the outline joins them -- and a shape that
                    // crosses itself is the usual mistake.
                    child: _Vertex(index: index + 1, colour: colour),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Vertex extends StatelessWidget {
  const _Vertex({required this.index, required this.colour});

  final int index;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Center(
        child: Text(
          '$index',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ColourDot extends StatelessWidget {
  const _ColourDot({
    required this.hex,
    required this.selected,
    required this.onTap,
  });

  final String hex;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    final colour = value == null ? Colors.grey : Color(0xFF000000 | value);

    return Semantics(
      selected: selected,
      button: true,
      label: 'Colour $hex',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: context.texts.bodySmall),
        const SizedBox(height: AppSpacing.x1),
        child,
      ],
    );
  }
}
