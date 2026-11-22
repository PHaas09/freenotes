import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'ink.dart';
import 'model.dart';

typedef TileKey = (int z, int x, int y);

/// Draws the square [world] of page space at [unit] pixels per page unit into a [px] x [px] image;
/// null if there is nothing to draw there.
typedef TileRenderer = Future<ui.Image?> Function(Rect world, double unit, int px);

class _Tile {
  _Tile(this.img, this.ver, this.dirtyVer);
  final ui.Image? img; // null = nothing in this tile
  final int ver; // content version the image was drawn from
  int dirtyVer; // version of the last change inside the tile; newer than [ver] = redraw
}

/// Draws page content as cached image tiles, like an online map: every zoom level has its own 512 px
/// tiles, drawn once in the background and reused while panning and zooming. Used for the ink of the
/// endless sheet (drawn by the Rust core) and for sharp PDF pages when zoomed in.
class TileCache {
  TileCache(this.onChange, this.render, {this.parallel = 3, this.ready});
  final VoidCallback onChange;
  final TileRenderer render;
  final int parallel; // tiles drawn at the same time
  final bool Function()? ready; // tiles wait until the content is loaded
  static const px = 512;
  static const maxTiles = 96; // about 100 MB of images
  static final _full = Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble());

  final _tiles = <TileKey, _Tile>{}; // keeps insertion order: least recently used first
  final _added = Map<Stroke, int>.identity(); // new strokes -> version; drawn as lines until their tiles catch up
  int _ver = 0;
  final _queue = <TileKey>[];
  final _rendering = <TileKey, bool>{}; // tile -> changed while being drawn
  bool _disposed = false;

  static double tileSize(int z) => px / math.pow(2.0, z);
  static Rect tileRect(TileKey k) {
    final t = tileSize(k.$1);
    return Rect.fromLTWH(k.$2 * t, k.$3 * t, t, t);
  }

  /// Zoom level whose tiles have at least as many pixels as the screen shows.
  static int levelFor(double pxPerUnit) => (math.log(pxPerUnit) / math.ln2).ceil().clamp(-30, 30);

  /// Strokes were added or removed: redraw the tiles they touch; new strokes show at once as lines.
  void changed(List<Stroke> added, List<Stroke> removed) {
    if (_tiles.isEmpty && _rendering.isEmpty) return; // nothing drawn yet (e.g. sheet just opened)
    _ver++;
    for (final s in added) {
      _added[s] = _ver;
      _invalidate(s.bounds);
    }
    for (final s in removed) {
      _added.remove(s);
      _invalidate(s.bounds);
    }
    while (_added.length > 300) {
      _added.remove(_added.keys.first);
    }
  }

  void _invalidate(Rect b) {
    for (final e in _tiles.entries) {
      if (tileRect(e.key).overlaps(b)) e.value.dirtyVer = _ver;
    }
    for (final k in _rendering.keys) {
      if (tileRect(k).overlaps(b)) _rendering[k] = true;
    }
  }

  /// Paints the visible part. [offset]/[scale]: screen = offset + page * scale.
  void paint(Canvas c, Size size, Offset offset, double scale, double dpr) {
    if (scale <= 0 || size.isEmpty) return;
    final z = levelFor(scale * dpr), t = tileSize(z);
    final view = Rect.fromLTWH(-offset.dx / scale, -offset.dy / scale, size.width / scale, size.height / scale);
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false;
    double snap(double v) => (v * dpr).roundToDouble() / dpr; // shared edges on whole pixels: no seams
    final visible = <TileKey>[];
    _queue.clear();
    for (var y = (view.top / t).floor(); y <= (view.bottom / t).floor(); y++) {
      for (var x = (view.left / t).floor(); x <= (view.right / t).floor(); x++) {
        final k = (z, x, y);
        visible.add(k);
        final dst = Rect.fromLTRB(snap(offset.dx + x * t * scale), snap(offset.dy + y * t * scale),
            snap(offset.dx + (x + 1) * t * scale), snap(offset.dy + (y + 1) * t * scale));
        final tile = _tiles.remove(k);
        if (tile != null) _tiles[k] = tile; // mark as recently used
        if ((tile == null || tile.ver < tile.dirtyVer) && !_rendering.containsKey(k)) _queue.add(k);
        if (tile == null) {
          _fallback(c, k, dst, paint);
        } else if (tile.img != null) {
          c.drawImageRect(tile.img!, _full, dst, paint);
        }
      }
    }
    final mid = view.center;
    _queue.sort((a, b) => (tileRect(a).center - mid).distanceSquared.compareTo((tileRect(b).center - mid).distanceSquared));
    _kick();

    if (_added.isEmpty) return;
    // Strokes newer than the tile under them: draw directly, so nothing flickers while tiles update.
    c.save();
    c.translate(offset.dx, offset.dy);
    c.scale(scale);
    for (final e in _added.entries) {
      final b = e.key.bounds;
      if (!b.overlaps(view)) continue;
      if (visible.any((k) => tileRect(k).overlaps(b) && (_tiles[k]?.ver ?? -1) < e.value)) {
        paintStrokeLod(c, e.key, scale * dpr);
      }
    }
    c.restore();
  }

  /// While a tile is missing, show a coarser one (zooming in) or the finer ones (zooming out).
  void _fallback(Canvas c, TileKey k, Rect dst, Paint paint) {
    final (z, x, y) = k;
    for (var up = 1; up <= 8; up++) {
      final p = _tiles[(z - up, x >> up, y >> up)];
      if (p == null) continue;
      if (p.img == null) return; // known to be empty
      final n = 1 << up, sub = px / n;
      c.drawImageRect(p.img!, Rect.fromLTWH((x - (x >> up << up)) * sub, (y - (y >> up << up)) * sub, sub, sub), dst, paint);
      return;
    }
    final w = dst.width / 2;
    for (var i = 0; i < 4; i++) {
      final img = _tiles[(z + 1, 2 * x + i % 2, 2 * y + i ~/ 2)]?.img;
      if (img != null) c.drawImageRect(img, _full, Rect.fromLTWH(dst.left + (i % 2) * w, dst.top + (i ~/ 2) * w, w, w), paint);
    }
  }

  /// Starts drawing queued tiles (several at once); each finished tile triggers a repaint, which queues the rest.
  void _kick() {
    if (_disposed || (ready != null && !ready!())) return;
    while (_rendering.length < parallel && _queue.isNotEmpty) {
      final k = _queue.removeAt(0);
      _rendering[k] = false;
      _render(k).whenComplete(() {
        _rendering.remove(k);
        if (!_disposed) onChange();
      });
    }
  }

  Future<void> _render(TileKey k) async {
    final r = tileRect(k), ver = _ver;
    final img = await render(r, px / r.width, px);
    if (_disposed) return img?.dispose();
    _tiles.remove(k)?.img?.dispose();
    _tiles[k] = _Tile(img, ver, _rendering[k] == true ? _ver : 0);
    while (_tiles.length > maxTiles) {
      _tiles.remove(_tiles.keys.first)?.img?.dispose();
    }
  }

  /// Tiles that are drawn and up to date (for tests).
  int get readyTiles => _tiles.values.where((t) => t.ver >= t.dirtyVer).length;

  void dispose() {
    _disposed = true;
    for (final t in _tiles.values) {
      t.img?.dispose();
    }
    _tiles.clear();
  }
}
