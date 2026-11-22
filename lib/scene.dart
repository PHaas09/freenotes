import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'model.dart';
import 'src/rust/api/scene.dart' as rust;

/// The strokes of the open page, mirrored in the Rust core: a spatial index for eraser and lasso, and
/// multi-core tile rendering for the endless sheet. Stroke lists are replaced on every change (never
/// edited in place), so comparing with the previous list tells what was added or removed.
class PageScene {
  PageScene() : id = rust.sceneCreate();
  final int id;
  List<Stroke> _strokes = const [];
  final _byId = <int, Stroke>{};
  bool ready = false;
  List<Stroke>? _pending;

  /// Told about every change, e.g. so image tiles can be redrawn.
  void Function(List<Stroke> added, List<Stroke> removed)? onChange;

  /// Loads all strokes of the page at once (indexing runs off the UI thread).
  Future<void> load(List<Stroke> strokes) async {
    _strokes = strokes;
    _byId
      ..clear()
      ..addEntries(strokes.map((s) => MapEntry(s.id, s)));
    await rust.sceneLoad(scene: id, batch: strokeBatch(strokes));
    ready = true;
    final p = _pending;
    _pending = null;
    if (p != null) sync(p);
  }

  /// Brings the Rust copy up to date with [strokes]. [removed]/[added] skip the comparison when the
  /// caller already knows them (eraser on a huge sheet, where comparing every move would be too slow).
  void sync(List<Stroke> strokes, {List<Stroke>? removed, List<Stroke>? added}) {
    if (identical(strokes, _strokes)) return;
    if (!ready) {
      _pending = strokes;
      return;
    }
    final old = _strokes;
    List<Stroke> add, rem;
    if (removed != null || added != null) {
      (add, rem) = (added ?? const [], removed ?? const []);
    } else if (strokes.length > old.length &&
        (old.isEmpty || (identical(strokes[old.length - 1], old.last) && identical(strokes[0], old[0])))) {
      (add, rem) = (strokes.sublist(old.length), const <Stroke>[]); // the usual case: strokes appended
    } else {
      final a = Set<Stroke>.identity()..addAll(old), b = Set<Stroke>.identity()..addAll(strokes);
      add = [for (final s in strokes) if (!a.contains(s)) s];
      rem = [for (final s in old) if (!b.contains(s)) s];
    }
    // remove first: a changed stroke (new colour, moved) keeps its id and comes back in `add`
    if (rem.isNotEmpty) {
      rust.sceneRemove(scene: id, ids: Uint32List.fromList([for (final s in rem) s.id]));
      for (final s in rem) {
        if (identical(_byId[s.id], s)) _byId.remove(s.id);
      }
    }
    if (add.isNotEmpty) {
      rust.sceneAdd(scene: id, batch: strokeBatch(add));
      for (final s in add) {
        _byId[s.id] = s;
      }
    }
    _strokes = strokes;
    onChange?.call(add, rem);
  }

  List<Stroke> _strokesFor(Uint32List ids) => [for (final i in ids) ?_byId[i]];

  /// Strokes touched by an eraser of radius [r] at ([x], [y]).
  List<Stroke> hit(double x, double y, double r, {bool highlighterOnly = false}) =>
      ready ? _strokesFor(rust.sceneHit(scene: id, x: x, y: y, r: r, highlighterOnly: highlighterOnly)) : const [];

  /// Strokes with at least half of their points inside the loop ([x0, y0, x1, y1, ...]).
  List<Stroke> lasso(List<double> loop) => ready ? _strokesFor(rust.sceneLasso(scene: id, poly: loop)) : const [];

  /// Precise eraser: for each stroke under the eraser, the pieces that are left of it.
  List<(Stroke, List<Float32List>)> erasePartial(double x, double y, double r, {bool highlighterOnly = false}) {
    if (!ready) return const [];
    return [
      for (final c in rust.sceneErasePartial(scene: id, x: x, y: y, r: r, highlighterOnly: highlighterOnly))
        if (_byId[c.id] != null) (_byId[c.id]!, c.pieces)
    ];
  }

  /// Everything on the page, or null if it is empty.
  ui.Rect? bounds() {
    if (!ready) return null;
    final b = rust.sceneBounds(scene: id);
    return b.length == 4 ? ui.Rect.fromLTRB(b[0], b[1], b[2], b[3]) : null;
  }

  /// The square of page space at [world] drawn at [unit] pixels per page unit; null if no ink is in it.
  Future<ui.Image?> render(ui.Rect world, double unit, int px) async {
    final pixels = await rust.sceneRender(scene: id, x0: world.left, y0: world.top, unit: unit, px: px);
    return pixels.isEmpty ? null : imageFromPixels(pixels, px, px);
  }

  void dispose() => rust.sceneDrop(scene: id);
}

/// Premultiplied RGBA pixels as an image.
Future<ui.Image> imageFromPixels(Uint8List pixels, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}
