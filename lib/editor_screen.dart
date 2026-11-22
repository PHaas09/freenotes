import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'dialogs.dart';
import 'ink.dart';
import 'model.dart';
import 'page_overview.dart';
import 'pdf_detail.dart';
import 'pdf_export.dart';
import 'prefs.dart';
import 'recorder.dart';
import 'scene.dart';
import 'store.dart';
import 'sync.dart';
import 'tiles.dart';

/// pen: write; shape: write, then the stroke snaps to a clean shape; laser: pointer that fades away;
/// eraser; lasso: select, move, resize, recolour, copy; text: tap to type.
enum Mode { pen, shape, laser, eraser, lasso, text }

const _quickPen = [0xFF1A1A1A, 0xFF1E4FD8, 0xFFD42A2A, 0xFF178A3E, 0xFF8E24AA, 0xFFFF9800];
const _quickHighlighter = [0xFFFFD400, 0xFF7CB342, 0xFFF48FB1, 0xFF0B8BD9, 0xFFFF9800];
const _eraserSizes = [5.0, 10.0, 20.0];

class _Snap {
  _Snap(this.strokes, this.texts, this.images);
  final List<Stroke> strokes;
  final List<TextBox> texts;
  final List<ImageBox> images;
}

class _Hist {
  final undo = <_Snap>[], redo = <_Snap>[];
}

class _Tick extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Moving or resizing the selection. Selected strokes are taken off the page while dragging and drawn
/// by the live layer instead, so the page doesn't have to be redrawn on every move.
class _Drag {
  _Drag(this.start, this.resize, this.box, this.before);
  final Offset start;
  final bool resize;
  final Rect box;
  final _Snap before;
  Offset move = Offset.zero;
  double k = 1; // scale, around the box's top left corner
  List<Stroke> strokes = const [];
  Map<String, TextBox> texts = const {};
  Map<String, ImageBox> images = const {};

  Offset map(Offset p) => box.topLeft + (p - box.topLeft) * k + move;
}

/// A copied selection; app-wide, so it can be pasted on another page or in another notebook.
class _Clip {
  _Clip(this.strokes, this.texts, this.images, this.bounds);
  final List<Stroke> strokes;
  final List<TextBox> texts;
  final List<ImageBox> images;
  final Rect bounds;
}

_Clip? _clipboard;

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.sync, required this.meta, this.onSplit, this.onClose});
  final Store store;
  final SyncService sync;
  final NotebookMeta meta;

  /// Set when a second notebook can be opened beside this one (menu "Daneben öffnen").
  final VoidCallback? onSplit;

  /// Set for the notebook shown beside another one: closes just this side.
  final VoidCallback? onClose;
  @override
  State<EditorScreen> createState() => _EditorState();
}

class _EditorState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  Notebook? nb;
  int index = 0;
  NotePage get page => nb!.pages[index];
  bool get endless => page.infinite;

  /// The page's strokes in the Rust core (eraser, lasso, and the endless sheet's tiles); always up to date when read.
  PageScene? scene;
  PageScene get sc => scene!..sync(page.strokes);
  TileCache? tiles; // endless sheet only
  PdfDetail? pdfDetail; // PDF page: extra sharpness when zoomed in

  Mode mode = Mode.pen;
  String pen = 'ballpoint';
  final colors = {
    for (final k in penTypes.keys) k: switch (k) { 'highlighter' => 0xFFFFD400, 'fountain' => 0xFF1E4FD8, 'pencil' => 0xFF5F6368, _ => 0xFF1A1A1A }
  };
  final sizes = {for (final e in penTypes.entries) e.key: e.value.sizes[1]};
  double eraserSize = 10;
  bool eraserPartial = false, eraserHighlighterOnly = false, straightHighlighter = false;

  /// Zoom relative to 100 %: whole page (A4) or 1 unit = 1 screen point (endless sheet).
  /// Pen, eraser and text sizes are divided by it, so they look the same on screen at any zoom.
  double get zoom => scale / (endless ? 1 : fitScale);
  double get minScale => endless ? 0.002 : fitScale * 0.5;
  double get maxScale => endless ? 200 : fitScale * 30;
  double dpr = 1;
  final zoomLabel = ValueNotifier<String?>(null);
  Timer? _zoomLabelTimer;
  late final Ticker _fling;
  Offset _flingV = Offset.zero;
  Duration _flingLast = Duration.zero;
  VelocityTracker? _vt;
  int _vtFingers = 0;

  // View: page point p is drawn at offset + p * scale.
  final view = ValueNotifier<Matrix4>(Matrix4.identity());
  double scale = 1, fitScale = 1, lastPanScale = 1;
  Offset offset = Offset.zero;
  Size viewport = Size.zero;

  final tick = _Tick();
  final hist = <String, _Hist>{};

  // Input
  final touches = <int, Offset>{}; // fingers / right mouse button: pan and zoom
  int? rightMouse; // pointer of a held right mouse button: the wheel zooms meanwhile
  int? drawPointer;
  bool stylusSeen = false; // after the first stylus touch, fingers only pan and zoom (palm rejection)
  Stroke? live;
  bool erasing = false, dragged = false;
  _Snap? before;
  Offset? eraserAt, downAt;
  Offset downScreen = Offset.zero;

  // Selection (lasso)
  final selStrokes = Set<Stroke>.identity();
  final selItems = <String>{}; // ids of selected text boxes and pictures
  List<Offset>? lassoPts;
  _Drag? drag;

  // Laser pointer: finished trails fade out
  final laser = <(Stroke, DateTime)>[];
  Timer? _laserTimer;

  final pdfDocs = <String, PdfDocument>{};
  final pdfImages = <String, ui.Image>{};
  final _pdfLoading = <String>{};

  final _focus = FocusNode(debugLabel: 'editor'); // keyboard shortcuts go to the side last touched

  @override
  void initState() {
    super.initState();
    _fling = createTicker(_onFlingTick);
    widget.sync.openIds.add(widget.meta.id);
    widget.store.loadNotebook(widget.meta.id).then((n) {
      if (!mounted) return;
      setState(() => nb = n);
      _pageChanged();
    }, onError: (Object e) {
      if (mounted) snack(context, 'Notizbuch konnte nicht geöffnet werden: $e');
    });
  }

  @override
  void dispose() {
    final rec = ScreenRecorder.instance;
    if (rec.owner == widget.meta.id) rec.stop().ignore(); // the file is finished and kept with the notebook
    widget.sync.openIds.remove(widget.meta.id);
    widget.store.flush().then((_) => widget.sync.run());
    for (final d in pdfDocs.values) {
      d.dispose();
    }
    for (final i in pdfImages.values) {
      i.dispose();
    }
    tiles?.dispose();
    scene?.dispose();
    pdfDetail?.dispose();
    _fling.dispose();
    _focus.dispose();
    _zoomLabelTimer?.cancel();
    _laserTimer?.cancel();
    super.dispose();
  }

  // ---------- view ----------
  Offset toPage(Offset local) => (local - offset) / scale;

  void _apply() {
    if (!endless) {
      // A page can't be pushed completely out of sight.
      final w = page.w * scale, h = page.h * scale;
      offset = Offset(offset.dx.clamp(80 - w, math.max(80 - w, viewport.width - 80)),
          offset.dy.clamp(80 - h, math.max(80 - h, viewport.height - 80)));
    }
    view.value = Matrix4.translationValues(offset.dx, offset.dy, 0)..multiply(Matrix4.diagonal3Values(scale, scale, 1));
    tick.ping();
  }

  double _pageFitScale() => math.min(viewport.width / page.w, viewport.height / page.h) * 0.96;

  /// Whole page, or for the endless sheet: everything written on it (at most 100 %).
  void _fit() {
    if (viewport.isEmpty || nb == null) return;
    _fling.stop();
    if (endless) {
      final b = _contentBounds();
      scale = b == null ? 1 : math.min(1.0, math.min(viewport.width / b.width, viewport.height / b.height) * 0.9).clamp(minScale, 1.0);
      offset = viewport.center(Offset.zero) - (b?.center ?? Offset.zero) * scale;
    } else {
      scale = fitScale = _pageFitScale();
      offset = Offset((viewport.width - page.w * scale) / 2, (viewport.height - page.h * scale) / 2);
    }
    _showZoom();
    _apply();
  }

  Rect? _contentBounds() {
    Rect? b = scene?.ready == true ? sc.bounds() : null;
    if (b == null) {
      for (final s in page.strokes) {
        b = b?.expandToInclude(s.bounds) ?? s.bounds;
      }
    }
    for (final t in page.texts) {
      b = b?.expandToInclude(_textRect(t)) ?? _textRect(t);
    }
    for (final i in page.images) {
      b = b?.expandToInclude(i.rect) ?? i.rect;
    }
    return b;
  }

  /// The screen area changed (window resized, phone rotated): keep what's in the middle in the middle.
  void _viewportChanged(Size old) {
    if (old.isEmpty) return _fit();
    if (!endless) fitScale = _pageFitScale();
    offset += viewport.center(Offset.zero) - old.center(Offset.zero);
    _apply();
  }

  /// Zoom by [f] and move, keeping the page point under [c0] under [c1].
  void _zoomAround(Offset c0, Offset c1, double f) {
    final ns = (scale * f).clamp(minScale, maxScale);
    final p = (c0 - offset) / scale;
    offset = c1 - p * ns;
    if (ns != scale) {
      scale = ns;
      _showZoom();
    }
    _apply();
  }

  /// Briefly shows the zoom level (e.g. "250 %").
  void _showZoom() {
    zoomLabel.value = '${(zoom * 100).round()} %';
    _zoomLabelTimer?.cancel();
    _zoomLabelTimer = Timer(const Duration(milliseconds: 1200), () => zoomLabel.value = null);
  }

  /// Keeps sliding after a quick two-finger pan, slowing down like a sheet of paper on a table.
  void _onFlingTick(Duration t) {
    final dt = (t - _flingLast).inMicroseconds / 1e6;
    _flingLast = t;
    if (dt <= 0) return;
    offset += _flingV * dt;
    _flingV *= math.pow(0.03, dt).toDouble();
    _apply();
    if (_flingV.distance < 30) _fling.stop();
  }

  void _startFling() {
    final v = _vt?.getVelocity().pixelsPerSecond ?? Offset.zero;
    _vt = null;
    if (v.distance < 300) return;
    _flingV = v;
    _flingLast = Duration.zero;
    _fling.start();
  }

  // ---------- pointer input ----------
  bool _isStylus(PointerEvent e) => e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;

  double _pressure(PointerEvent e) {
    if (!_isStylus(e)) return 0.5;
    final r = e.pressureMax - e.pressureMin;
    return r <= 0 ? 0.5 : ((e.pressure - e.pressureMin) / r).clamp(0.0, 1.0);
  }

  void _onDown(PointerDownEvent e) {
    if (nb == null) return;
    _focus.requestFocus();
    _fling.stop();
    if (touches.isEmpty) _vt = null;
    if (_isStylus(e)) stylusSeen = true;
    final touch = e.kind == PointerDeviceKind.touch, mouse = e.kind == PointerDeviceKind.mouse;
    if (mouse && e.buttons != kPrimaryMouseButton) {
      if (e.buttons & kSecondaryMouseButton != 0) rightMouse = e.pointer;
      touches[e.pointer] = e.localPosition; // right / middle drag pans
      return;
    }
    if (touch) {
      touches[e.pointer] = e.localPosition;
      if (touches.length >= 2) return _end(cancel: true); // second finger: zoom instead of drawing
      if (stylusSeen) return;
    }
    if (drawPointer != null) return;
    drawPointer = e.pointer;
    _begin(e);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer == drawPointer) {
      if (touches.containsKey(e.pointer)) touches[e.pointer] = e.localPosition;
      final p = toPage(e.localPosition);
      if ((e.localPosition - downScreen).distance > 4) dragged = true;
      if (erasing) {
        _eraseAt(p);
      } else if (live != null) {
        live!.pts.addAll([p.dx, p.dy, _pressure(e)]);
        tick.ping();
      } else if (mode == Mode.lasso) {
        _lassoMove(p);
      }
    } else if (touches.containsKey(e.pointer)) {
      final prev = touches.values.toList();
      touches[e.pointer] = e.localPosition;
      final now = touches.values.toList();
      var f = 1.0;
      if (now.length >= 2) {
        final d0 = (prev[0] - prev[1]).distance;
        if (d0 > 1) f = (now[0] - now[1]).distance / d0;
      }
      if (_vt == null || _vtFingers != now.length) {
        // finger count changed: the centre jumps, start over
        _vt = VelocityTracker.withKind(PointerDeviceKind.touch);
        _vtFingers = now.length;
      }
      _vt!.addPosition(e.timeStamp, _centroid(now));
      _zoomAround(_centroid(prev), _centroid(now), f);
    }
  }

  void _onUp(PointerEvent e, {bool cancel = false}) {
    final wasGesture = touches.remove(e.pointer) != null && e.pointer != drawPointer;
    if (e.pointer == rightMouse) rightMouse = null;
    if (e.pointer == drawPointer) _end(cancel: cancel);
    if (wasGesture && touches.isEmpty && !cancel) _startFling();
  }

  Offset _centroid(List<Offset> l) => l.reduce((a, b) => a + b) / l.length.toDouble();

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || rightMouse != null) {
      _zoomAround(e.localPosition, e.localPosition, math.exp(-e.scrollDelta.dy / 400));
    } else {
      offset -= kb.isShiftPressed ? Offset(e.scrollDelta.dy, 0) : e.scrollDelta;
      _apply();
    }
  }

  void _begin(PointerDownEvent e) {
    final p = toPage(e.localPosition);
    downScreen = e.localPosition;
    downAt = p;
    dragged = false;
    if (e.kind == PointerDeviceKind.invertedStylus || mode == Mode.eraser) {
      erasing = true;
      before = _snap();
      _eraseAt(p);
      return;
    }
    switch (mode) {
      case Mode.pen || Mode.shape || Mode.laser:
        final laserOn = mode == Mode.laser;
        // Width follows the zoom: zoomed in 4x, the pen writes 4x finer, so it looks the same on screen.
        live = Stroke(
            type: laserOn ? 'ballpoint' : pen,
            color: laserOn ? 0xFFFF1744 : colors[pen]!,
            size: (laserOn ? 3.0 : sizes[pen]!) / zoom,
            sim: !_isStylus(e),
            pts: <double>[p.dx, p.dy, _pressure(e)]);
        tick.ping();
      case Mode.lasso:
        _lassoDown(p);
      case Mode.eraser || Mode.text:
        break; // text: handled when the finger lifts (a tap)
    }
  }

  void _end({bool cancel = false}) {
    drawPointer = null;
    if (erasing) {
      erasing = false;
      eraserAt = null;
      if (cancel) {
        setState(() => _restore(before!));
      } else {
        _commit(before!);
      }
      before = null;
      tick.ping();
    } else if (live != null) {
      final s = live!;
      live = null;
      if (!cancel) _finishStroke(s);
      tick.ping();
    } else if (mode == Mode.lasso) {
      _lassoUp(cancel);
    } else if (mode == Mode.text && !cancel && !dragged && downAt != null) {
      final id = _hitObject(downAt!);
      _editText(page.texts.where((t) => t.id == id).firstOrNull, downAt!);
    }
  }

  void _finishStroke(Stroke s) {
    var pts = Float32List.fromList(s.pts);
    if (mode == Mode.laser) {
      laser.add((s.copyWith(pts: pts, keepId: false), DateTime.now()));
      _laserTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        laser.removeWhere((l) => DateTime.now().difference(l.$2).inMilliseconds > 1200);
        tick.ping();
        if (laser.isEmpty) {
          _laserTimer?.cancel();
          _laserTimer = null;
        }
      });
      return;
    }
    var sim = s.sim;
    if (mode == Mode.shape) {
      final shape = recognizeShape(pts, s.size);
      if (shape != null) (pts, sim) = (shape, false);
    } else if (s.type == 'highlighter' && straightHighlighter && pts.length >= 6) {
      // straight highlighter: from start to end, snapped to horizontal when nearly level
      final (x0, y0, x1) = (pts[0], pts[1], pts[pts.length - 3]);
      var y1 = pts[pts.length - 2];
      if ((y1 - y0).abs() < (x1 - x0).abs() * 0.15) y1 = y0;
      pts = Float32List.fromList([x0, y0, 0.5, x1, y1, 0.5]);
    }
    final done = Stroke(type: s.type, color: s.color, size: s.size, sim: sim, pts: pts);
    _edit(() => page.strokes = [...page.strokes, done]);
  }

  void _eraseAt(Offset p) {
    eraserAt = p;
    final r = eraserSize / zoom, s = sc;
    if (eraserPartial) {
      final cuts = s.erasePartial(p.dx, p.dy, r, highlighterOnly: eraserHighlighterOnly);
      if (cuts.isNotEmpty) {
        final pieces = Map<Stroke, List<Stroke>>.identity();
        for (final (old, parts) in cuts) {
          pieces[old] = [for (final q in parts) Stroke(type: old.type, color: old.color, size: old.size, sim: old.sim, pts: q)];
        }
        final next = <Stroke>[for (final x in page.strokes) ...(pieces[x] ?? [x])];
        s.sync(next, removed: pieces.keys.toList(), added: [for (final v in pieces.values) ...v]);
        setState(() => page.strokes = next);
      }
    } else {
      final hit = s.hit(p.dx, p.dy, r, highlighterOnly: eraserHighlighterOnly);
      if (hit.isNotEmpty) {
        final gone = Set<Stroke>.identity()..addAll(hit);
        final kept = [for (final x in page.strokes) if (!gone.contains(x)) x];
        s.sync(kept, removed: hit);
        setState(() => page.strokes = kept);
      }
    }
    tick.ping();
  }

  // ---------- lasso: select, move, resize ----------
  bool get _hasSel => selStrokes.isNotEmpty || selItems.isNotEmpty;

  Rect? get _selBox {
    Rect? b;
    for (final s in page.strokes) {
      if (selStrokes.contains(s)) b = b?.expandToInclude(s.bounds) ?? s.bounds;
    }
    for (final t in page.texts) {
      if (selItems.contains(t.id)) b = b?.expandToInclude(_textRect(t)) ?? _textRect(t);
    }
    for (final i in page.images) {
      if (selItems.contains(i.id)) b = b?.expandToInclude(i.rect) ?? i.rect;
    }
    return b;
  }

  void _clearSelection() {
    selStrokes.clear();
    selItems.clear();
  }

  void _lassoDown(Offset p) {
    final box = _selBox;
    if (box != null && box.inflate(10 / scale).contains(p)) {
      final d = drag = _Drag(p, (p - box.bottomRight).distance < 18 / scale, box, _snap());
      d.strokes = [for (final s in page.strokes) if (selStrokes.contains(s)) s];
      d.texts = {for (final t in page.texts) if (selItems.contains(t.id)) t.id: t};
      d.images = {for (final i in page.images) if (selItems.contains(i.id)) i.id: i};
      if (d.strokes.isNotEmpty) setState(() => page.strokes = [for (final s in page.strokes) if (!selStrokes.contains(s)) s]);
      return;
    }
    setState(() {
      _clearSelection();
      lassoPts = [p];
    });
  }

  void _lassoMove(Offset p) {
    final d = drag;
    if (d != null) {
      if (d.resize) {
        d.k = math.max(0.1, (d.box.width + (p - d.start).dx) / math.max(d.box.width, 1e-6));
      } else {
        d.move = p - d.start;
      }
      if (d.texts.isNotEmpty || d.images.isNotEmpty) {
        setState(() {
          page.texts = [for (final t in page.texts) d.texts[t.id] != null ? _moveText(d.texts[t.id]!, d) : t];
          page.images = [for (final i in page.images) d.images[i.id] != null ? _moveImage(d.images[i.id]!, d) : i];
        });
      }
      tick.ping();
      return;
    }
    final l = lassoPts;
    if (l != null && (p - l.last).distance * scale > 2) {
      l.add(p);
      tick.ping();
    }
  }

  void _lassoUp(bool cancel) {
    final d = drag;
    if (d != null) {
      drag = null;
      if (cancel || (d.move == Offset.zero && d.k == 1)) {
        setState(() => _restore(d.before));
        return;
      }
      final moved = Map<Stroke, Stroke>.identity();
      for (final s in d.strokes) {
        moved[s] = _moveStroke(s, d);
      }
      page.strokes = [for (final s in d.before.strokes) moved[s] ?? s];
      selStrokes
        ..clear()
        ..addAll(moved.values);
      _commit(d.before);
      return;
    }
    final l = lassoPts;
    lassoPts = null;
    if (l == null || cancel) return tick.ping();
    if (!dragged) {
      // a tap selects what is under it
      final id = _hitObject(l.first);
      if (id != null) {
        selItems.add(id);
      } else {
        final hit = sc.hit(l.first.dx, l.first.dy, 8 / scale);
        if (hit.isNotEmpty) selStrokes.add(hit.reduce((a, b) => a.id > b.id ? a : b)); // the one on top
      }
    } else if (l.length > 2) {
      selStrokes.addAll(sc.lasso([for (final o in l) ...[o.dx, o.dy]]));
      for (final t in page.texts) {
        if (_inside(l, _textRect(t).center)) selItems.add(t.id);
      }
      for (final i in page.images) {
        if (_inside(l, i.rect.center)) selItems.add(i.id);
      }
    }
    setState(() {});
  }

  static bool _inside(List<Offset> poly, Offset p) {
    var c = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final (a, b) = (poly[i], poly[j]);
      if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) c = !c;
    }
    return c;
  }

  Stroke _moveStroke(Stroke s, _Drag d) {
    final q = Float32List.fromList(s.pts), o = d.box.topLeft;
    for (var i = 0; i + 2 < q.length; i += 3) {
      q[i] = o.dx + (q[i] - o.dx) * d.k + d.move.dx;
      q[i + 1] = o.dy + (q[i + 1] - o.dy) * d.k + d.move.dy;
    }
    return s.copyWith(pts: q, size: s.size * d.k); // keeps its place in the drawing order
  }

  TextBox _moveText(TextBox t, _Drag d) {
    final p = d.map(Offset(t.x, t.y));
    return t.copyWith(x: p.dx, y: p.dy, size: t.size * d.k, width: t.width * d.k);
  }

  ImageBox _moveImage(ImageBox i, _Drag d) => ImageBox(id: i.id, asset: i.asset, rect: Rect.fromPoints(d.map(i.rect.topLeft), d.map(i.rect.bottomRight)));

  void _recolor(int c) {
    final changed = Map<Stroke, Stroke>.identity();
    _edit(() {
      page.strokes = [
        for (final s in page.strokes)
          if (selStrokes.contains(s)) changed[s] = s.copyWith(color: c) else s
      ];
      page.texts = [for (final t in page.texts) selItems.contains(t.id) ? t.copyWith(color: c) : t];
    });
    setState(() => selStrokes
      ..clear()
      ..addAll(changed.values));
  }

  void _deleteSelection() {
    if (!_hasSel) return;
    _edit(() {
      page.strokes = [for (final s in page.strokes) if (!selStrokes.contains(s)) s];
      page.texts = [for (final t in page.texts) if (!selItems.contains(t.id)) t];
      page.images = [for (final i in page.images) if (!selItems.contains(i.id)) i];
    });
    setState(_clearSelection);
  }

  _Clip? _selectionClip() {
    final box = _selBox;
    if (box == null) return null;
    return _Clip([for (final s in page.strokes) if (selStrokes.contains(s)) s], [for (final t in page.texts) if (selItems.contains(t.id)) t],
        [for (final i in page.images) if (selItems.contains(i.id)) i], box);
  }

  void _copySelection({bool cut = false}) {
    final c = _selectionClip();
    if (c == null) return;
    _clipboard = c;
    if (cut) {
      _deleteSelection();
    } else {
      setState(() {}); // shows "Einfügen"
    }
    snack(context, cut ? 'Ausgeschnitten' : 'Kopiert');
  }

  /// Pastes [clip] (or the clipboard) moved by [shift], or into the middle of the screen; selects the copies.
  void _paste({_Clip? clip, Offset? shift}) {
    final c = clip ?? _clipboard;
    if (c == null) return;
    final d = shift ?? toPage(viewport.center(Offset.zero)) - c.bounds.center;
    final strokes = [
      for (final s in c.strokes)
        s.copyWith(keepId: false, pts: Float32List.fromList([for (var i = 0; i < s.pts.length; i++) s.pts[i] + (i % 3 == 0 ? d.dx : i % 3 == 1 ? d.dy : 0)]))
    ];
    final texts = [for (final t in c.texts) TextBox(id: newId(), x: t.x + d.dx, y: t.y + d.dy, text: t.text, size: t.size, color: t.color, width: t.width)];
    final images = [for (final i in c.images) ImageBox(id: newId(), asset: i.asset, rect: i.rect.shift(d))];
    _edit(() {
      page.strokes = [...page.strokes, ...strokes];
      page.texts = [...page.texts, ...texts];
      page.images = [...page.images, ...images];
    });
    setState(() {
      mode = Mode.lasso;
      _clearSelection();
      selStrokes.addAll(strokes);
      selItems.addAll([...texts.map((t) => t.id), ...images.map((i) => i.id)]);
    });
  }

  void _duplicateSelection() {
    final c = _selectionClip();
    if (c != null) _paste(clip: c, shift: Offset(24, 24) / zoom);
  }

  // ---------- undo ----------
  _Hist get _h => hist.putIfAbsent(page.id, _Hist.new);
  _Snap _snap() => _Snap(page.strokes, page.texts, page.images);
  void _restore(_Snap s) {
    page.strokes = s.strokes;
    page.texts = s.texts;
    page.images = s.images;
  }

  void _commit(_Snap b) {
    if (identical(b.strokes, page.strokes) && identical(b.texts, page.texts) && identical(b.images, page.images)) return;
    _h.undo.add(b);
    // Each step keeps the old stroke list; on a huge endless sheet keep fewer steps to save memory.
    while (_h.undo.length > (page.strokes.length > 5000 ? 30 : 300)) {
      _h.undo.removeAt(0);
    }
    _h.redo.clear();
    widget.store.changed(nb!);
    setState(() {});
  }

  void _edit(void Function() fn) {
    final b = _snap();
    fn();
    _commit(b);
  }

  void _step(List<_Snap> from, List<_Snap> to) {
    if (from.isEmpty) return;
    to.add(_snap());
    setState(() {
      _restore(from.removeLast());
      _clearSelection();
    });
    widget.store.changed(nb!);
  }

  // ---------- text + images ----------
  TextStyle _textStyle(TextBox t) => TextStyle(fontSize: t.size, color: Color(t.color), height: 1.3);

  Rect _textRect(TextBox t) {
    final tp = TextPainter(text: TextSpan(text: t.text, style: _textStyle(t)), textDirection: TextDirection.ltr)
      ..layout(maxWidth: t.width);
    return Rect.fromLTWH(t.x, t.y, t.width, math.max(tp.height, t.size));
  }

  String? _hitObject(Offset p) {
    for (final t in page.texts.reversed) {
      if (_textRect(t).inflate(4 / zoom).contains(p)) return t.id;
    }
    for (final i in page.images.reversed) {
      if (i.rect.contains(p)) return i.id;
    }
    return null;
  }

  Future<void> _editText(TextBox? t, Offset at) async {
    final ctrl = TextEditingController(text: t?.text ?? '');
    // The slider shows the size as it looks on screen right now; the stored size follows the zoom like the pen.
    var size = t == null ? 16.0 : (t.size * zoom).clamp(10.0, 48.0);
    var sizeMoved = false;
    const del = '\u0000delete';
    final res = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                    title: Text(t == null ? 'Text einfügen' : 'Text bearbeiten'),
                    content: SizedBox(
                        width: 420,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(controller: ctrl, autofocus: true, minLines: 3, maxLines: 10,
                              decoration: const InputDecoration(border: OutlineInputBorder())),
                          Row(children: [
                            const Text('Größe'),
                            Expanded(
                                child: Slider(
                                    value: size,
                                    min: 10,
                                    max: 48,
                                    divisions: 19,
                                    label: '${size.round()}',
                                    onChanged: (v) => set(() {
                                          size = v;
                                          sizeMoved = true;
                                        }))),
                          ]),
                        ])),
                    actions: [
                      if (t != null) TextButton(onPressed: () => Navigator.pop(ctx, del), child: const Text('Löschen')),
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
                    ])));
    if (res == null || !mounted) return;
    final color = colors[pen == 'highlighter' ? 'ballpoint' : pen]!;
    final newSize = t != null && !sizeMoved ? t.size : size / zoom;
    _edit(() {
      if (res == del || res.trim().isEmpty) {
        if (t != null) page.texts = page.texts.where((x) => x.id != t.id).toList();
      } else if (t == null) {
        page.texts = [...page.texts, TextBox(id: newId(), x: at.dx, y: at.dy, text: res, size: newSize, color: color, width: 260 / zoom)];
      } else {
        page.texts = [for (final x in page.texts) x.id == t.id ? x.copyWith(text: res, size: newSize) : x];
      }
    });
  }

  Future<void> _insertImage() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f?.path == null || !mounted) return;
    try {
      final codec = await ui.instantiateImageCodec(await File(f!.path!).readAsBytes());
      final frame = await codec.getNextFrame();
      final iw = frame.image.width.toDouble(), ih = frame.image.height.toDouble();
      frame.image.dispose();
      codec.dispose();
      final asset = await widget.store.importAsset(f.path!);
      final w = endless ? 300 / zoom : math.min(page.w * 0.6, iw);
      final box = ImageBox(id: newId(), asset: asset, rect: Rect.fromCenter(center: toPage(viewport.center(Offset.zero)), width: w, height: w * ih / iw));
      _edit(() => page.images = [...page.images, box]);
      setState(() {
        mode = Mode.lasso;
        _clearSelection();
        selItems.add(box.id);
      });
    } catch (e) {
      if (mounted) snack(context, 'Bild konnte nicht eingefügt werden: $e');
    }
  }

  // ---------- PDF ----------
  ui.Image? _pdfImage(NotePage p) => pdfImages['${p.pdf}#${p.pdfPage}'];

  Future<PdfDocument> _openPdf(String asset) async => pdfDocs[asset] ??= await PdfDocument.openFile(widget.store.assetPath(asset));

  /// The page image (2 pixels per unit); zooming in further is handled by [PdfDetail].
  Future<void> _loadPdf() async {
    final pg = page, key = '${pg.pdf}#${pg.pdfPage}';
    if (pg.pdf == null || pg.pdfPage == null) return;
    try {
      final doc = await _openPdf(pg.pdf!);
      if (!mounted || !identical(pg, page)) return;
      if (pdfDetail == null) {
        final d = pdfDetail = PdfDetail(doc.pages[pg.pdfPage!], tick.ping, sharpenScans: Prefs.instance.sharpenScans);
        d.init();
      }
      if (pdfImages.containsKey(key) || !_pdfLoading.add(key)) return;
      final img = await doc.pages[pg.pdfPage!].render(fullWidth: pg.w * 2, fullHeight: pg.h * 2, backgroundColor: 0xFFFFFFFF);
      if (img == null) return;
      final image = await img.createImage();
      img.dispose();
      if (!mounted) return image.dispose();
      if (pdfImages.length >= 6) pdfImages.remove(pdfImages.keys.first)?.dispose();
      setState(() => pdfImages[key] = image);
    } catch (e) {
      if (mounted) snack(context, 'PDF-Seite konnte nicht geladen werden: $e');
    } finally {
      _pdfLoading.remove(key);
    }
  }

  Future<ui.Image?> _pdfThumb(NotePage p) async {
    try {
      final doc = await _openPdf(p.pdf!);
      final img = await doc.pages[p.pdfPage!].render(fullWidth: 240, fullHeight: 240 * p.h / p.w, backgroundColor: 0xFFFFFFFF);
      if (img == null) return null;
      final image = await img.createImage();
      img.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  // ---------- screen recording ----------
  Future<void> _startRecording() async {
    final audio = await showDialog<bool>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('Bildschirm aufnehmen'), children: [
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const ListTile(leading: Icon(Icons.mic), title: Text('Mit Ton'), subtitle: Text('Deine Stimme über das Mikrofon'))),
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const ListTile(leading: Icon(Icons.mic_off), title: Text('Ohne Ton'))),
            ]));
    if (audio == null || !mounted) return;
    final notebook = nb!, store = widget.store, name = '${newId()}.mp4', created = nowMs();
    try {
      final path = store.assetPath(name);
      await Directory(File(path).parent.path).create(recursive: true);
      await ScreenRecorder.instance.start(path, audio: audio, owner: widget.meta.id, onSaved: (ms) {
        notebook.recordings.add(Recording(asset: name, created: created, ms: ms, audio: audio));
        store.changed(notebook);
      });
    } catch (e) {
      if (mounted) snack(context, 'Aufnahme nicht möglich: ${e is PlatformException ? e.message : e}');
    }
  }

  Future<void> _stopRecording() async {
    try {
      final ms = await ScreenRecorder.instance.stop();
      if (mounted) snack(context, 'Aufnahme gespeichert (${formatDuration(ms)}). Zu finden im Menü unter „Aufnahmen“.');
    } catch (e) {
      if (mounted) snack(context, 'Aufnahme konnte nicht gespeichert werden: ${e is PlatformException ? e.message : e}');
    }
  }

  String _recTitle(Recording r) {
    final d = DateTime.fromMillisecondsSinceEpoch(r.created);
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Aufnahme vom ${two(d.day)}.${two(d.month)}.${d.year}, ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _playRecording(Recording r) async {
    final f = File(widget.store.assetPath(r.asset));
    if (!await f.exists()) {
      if (mounted) snack(context, 'Die Aufnahme ist auf diesem Gerät noch nicht da (wird mit der NAS abgeglichen).');
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [f.path]); // no in-app video player for Linux: the system's player opens
      return;
    }
    if (mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecordingPlayer(file: f, title: _recTitle(r))));
  }

  Future<void> _saveRecordingAs(Recording r) async {
    final src = File(widget.store.assetPath(r.asset));
    try {
      final name = '${_recTitle(r).replaceAll(':', '-').replaceAll(',', '')}.mp4';
      final where = await FilePicker.saveFile(
          fileName: name, bytes: await src.readAsBytes(), mimeType: 'video/mp4', dialogTitle: 'Aufnahme speichern unter');
      if (where != null && mounted) snack(context, 'Aufnahme gespeichert');
    } catch (e) {
      if (mounted) snack(context, 'Speichern fehlgeschlagen: $e');
    }
  }

  Future<void> _openRecordings() async {
    await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, refresh) => ListView(shrinkWrap: true, children: [
                  ListTile(title: Text('Aufnahmen (${nb!.recordings.length})', style: Theme.of(ctx).textTheme.titleMedium)),
                  if (nb!.recordings.isEmpty) const ListTile(title: Text('Noch keine Aufnahmen.')),
                  for (final r in nb!.recordings.reversed)
                    ListTile(
                      leading: Icon(r.audio ? Icons.mic : Icons.videocam_outlined),
                      title: Text(_recTitle(r)),
                      subtitle: Text('${formatDuration(r.ms)}${r.audio ? ', mit Ton' : ', ohne Ton'}'),
                      onTap: () => _playRecording(r),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Mehr',
                        onSelected: (v) async {
                          if (v == 'save') return _saveRecordingAs(r);
                          if (!await confirm(ctx, 'Aufnahme löschen?', '${_recTitle(r)} wird gelöscht.')) return;
                          nb!.recordings.remove(r);
                          widget.store.changed(nb!);
                          await File(widget.store.assetPath(r.asset)).delete().then((_) {}, onError: (_) {});
                          refresh(() {});
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'save', child: Text('Speichern unter…')),
                          PopupMenuItem(value: 'delete', child: Text('Löschen')),
                        ],
                      ),
                    ),
                ])));
  }

  Future<void> _exportPdf() async {
    await widget.store.flush();
    if (!mounted) return;
    final progress = ValueNotifier<String>('PDF wird erstellt…');
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
            content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: ValueListenableBuilder(valueListenable: progress, builder: (_, v, _) => Text(v))),
        ])));
    try {
      final bytes = await exportPdf(nb!, widget.store,
          openPdf: _openPdf, progress: (done, total) => progress.value = 'Seite ${math.min(done + 1, total)} von $total…');
      if (!mounted) return;
      Navigator.pop(context);
      final name = widget.meta.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final where = await FilePicker.saveFile(fileName: '$name.pdf', bytes: bytes, mimeType: 'application/pdf', dialogTitle: 'PDF speichern');
      if (where != null && mounted) snack(context, 'PDF gespeichert');
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      snack(context, 'Export fehlgeschlagen: $e');
    }
  }

  // ---------- pages ----------
  void _go(int i) {
    if (i < 0 || i >= nb!.pages.length) return;
    setState(() => index = i);
    _pageChanged();
  }

  void _pageChanged() {
    tiles?.dispose();
    scene?.dispose();
    pdfDetail?.dispose();
    pdfDetail = null;
    _clearSelection();
    live = null;
    lassoPts = null;
    drag = null;
    final s = scene = PageScene();
    if (endless) {
      final t = tiles = TileCache(tick.ping, s.render, ready: () => s.ready);
      s.onChange = t.changed;
    } else {
      tiles = null;
    }
    s.load(page.strokes).then((_) {
      if (mounted) tick.ping();
    });
    _fit();
    _loadPdf();
  }

  void _addPage() {
    final cur = page;
    nb!.pages.insert(index + 1, NotePage(paper: cur.pdf != null ? 'blank' : cur.paper, w: cur.w, h: cur.h, infinite: cur.infinite));
    widget.store.changed(nb!);
    _go(index + 1);
  }

  Future<void> _deletePage() async {
    final empty = page.strokes.isEmpty && page.texts.isEmpty && page.images.isEmpty;
    if (!empty && !await confirm(context, 'Seite löschen?', 'Diese Seite wird endgültig gelöscht.')) return;
    hist.remove(page.id);
    nb!.pages.removeAt(index);
    if (nb!.pages.isEmpty) nb!.pages.add(NotePage());
    widget.store.changed(nb!);
    _go(math.min(index, nb!.pages.length - 1));
  }

  Future<void> _openOverview() async {
    final current = page.id;
    final picked = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => PageOverview(nb: nb!, store: widget.store, currentId: current, pdfThumb: _pdfThumb)));
    if (!mounted) return;
    final i = picked ?? nb!.pages.indexWhere((p) => p.id == current);
    setState(() => index = i.clamp(0, nb!.pages.length - 1));
    _pageChanged();
  }

  // ---------- tools ----------
  void _setMode(Mode m, {String? penType}) => setState(() {
        mode = m;
        if (penType != null) pen = penType;
        if (m != Mode.lasso) _clearSelection();
      });

  void _addFavorite() {
    final f = PenPreset(pen, colors[pen]!, sizes[pen]!);
    final favs = Prefs.instance.favorites;
    if (favs.contains(f)) return snack(context, 'Diesen Stift gibt es schon als Favorit');
    setState(() => favs.add(f));
    Prefs.instance.save();
  }

  void _removeFavorite(PenPreset f) {
    setState(() => Prefs.instance.favorites.remove(f));
    Prefs.instance.save();
    snack(context, 'Favorit entfernt');
  }

  void _useFavorite(PenPreset f) => setState(() {
        mode = Mode.pen;
        pen = penTypes.containsKey(f.type) ? f.type : 'ballpoint';
        colors[pen] = f.color;
        sizes[pen] = f.size;
        _clearSelection();
      });

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 600; // phone: fewer buttons in the top bar, rest in the menu
    dpr = MediaQuery.devicePixelRatioOf(context);
    final fitLabel = nb != null && endless ? 'Alles zeigen' : 'Ganze Seite zeigen';
    void zoomStep(double f) => _zoomAround(viewport.center(Offset.zero), viewport.center(Offset.zero), f);
    return Scaffold(
      resizeToAvoidBottomInset: false, // the keyboard of the text dialog must not move the page
      appBar: AppBar(
        leading: widget.onClose == null ? null : IconButton(icon: const Icon(Icons.close), tooltip: 'Diese Seite schließen', onPressed: widget.onClose),
        title: Text(widget.meta.name),
        titleSpacing: narrow ? 0 : null,
        actions: nb == null
            ? null
            : [
                if (ScreenRecorder.supported)
                  ValueListenableBuilder(
                      valueListenable: ScreenRecorder.instance.active,
                      builder: (context, since, _) => since != null
                          ? RecordingChip(since: since, onStop: _stopRecording)
                          : narrow
                              ? const SizedBox.shrink()
                              : IconButton(
                                  icon: const Icon(Icons.fiber_manual_record_outlined, color: Color(0xFFD32F2F)),
                                  tooltip: 'Bildschirm aufnehmen',
                                  onPressed: _startRecording)),
                IconButton(icon: const Icon(Icons.undo), tooltip: 'Rückgängig (Strg+Z)', onPressed: _h.undo.isEmpty ? null : () => _step(_h.undo, _h.redo)),
                IconButton(icon: const Icon(Icons.redo), tooltip: 'Wiederholen (Strg+Y)', onPressed: _h.redo.isEmpty ? null : () => _step(_h.redo, _h.undo)),
                if (!narrow) const SizedBox(width: 12),
                IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Vorherige Seite', onPressed: index > 0 ? () => _go(index - 1) : null),
                Center(child: Text('${index + 1} / ${nb!.pages.length}')),
                IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Nächste Seite',
                    onPressed: index < nb!.pages.length - 1 ? () => _go(index + 1) : null),
                if (!narrow) IconButton(icon: const Icon(Icons.grid_view), tooltip: 'Seitenübersicht', onPressed: _openOverview),
                if (!narrow) IconButton(icon: const Icon(Icons.note_add_outlined), tooltip: 'Seite einfügen', onPressed: _addPage),
                if (!narrow) IconButton(icon: const Icon(Icons.fit_screen), tooltip: '$fitLabel (Strg+0)', onPressed: _fit),
                PopupMenuButton<String>(
                  tooltip: 'Seite',
                  onSelected: (v) {
                    switch (v) {
                      case 'delete':
                        _deletePage();
                      case 'add':
                        _addPage();
                      case 'fit':
                        _fit();
                      case 'overview':
                        _openOverview();
                      case 'export':
                        _exportPdf();
                      case 'split':
                        widget.onSplit?.call();
                      case 'record':
                        _startRecording();
                      case 'recordings':
                        _openRecordings();
                      case 'sharpen':
                        Prefs.instance.sharpenScans = !Prefs.instance.sharpenScans;
                        Prefs.instance.save();
                        pdfDetail?.dispose();
                        pdfDetail = null;
                        _loadPdf();
                      default:
                        setState(() => page.paper = v);
                        widget.store.changed(nb!);
                    }
                  },
                  itemBuilder: (_) => [
                    if (narrow) const PopupMenuItem(value: 'overview', child: Text('Seitenübersicht')),
                    if (narrow) const PopupMenuItem(value: 'add', child: Text('Seite einfügen')),
                    if (narrow) PopupMenuItem(value: 'fit', child: Text(fitLabel)),
                    if (narrow) const PopupMenuDivider(),
                    for (final (v, label) in [('blank', 'Blanko'), ('lined', 'Liniert'), ('grid', 'Kariert'), ('dots', 'Punktiert')])
                      CheckedPopupMenuItem(value: v, checked: page.paper == v, child: Text('Papier: $label')),
                    const PopupMenuDivider(),
                    if (widget.onSplit != null) const PopupMenuItem(value: 'split', child: Text('Zweites Notizbuch daneben öffnen')),
                    if (narrow && ScreenRecorder.supported && ScreenRecorder.instance.active.value == null)
                      const PopupMenuItem(value: 'record', child: Text('Bildschirm aufnehmen')),
                    if (nb!.recordings.isNotEmpty) PopupMenuItem(value: 'recordings', child: Text('Aufnahmen (${nb!.recordings.length})')),
                    if (page.pdf != null)
                      CheckedPopupMenuItem(value: 'sharpen', checked: Prefs.instance.sharpenScans, child: const Text('Scans beim Zoomen schärfen')),
                    const PopupMenuItem(value: 'export', child: Text('Als PDF exportieren')),
                    const PopupMenuItem(value: 'delete', child: Text('Seite löschen')),
                  ],
                ),
              ],
      ),
      body: nb == null
          ? const Center(child: CircularProgressIndicator())
          : CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => _step(_h.undo, _h.redo),
                const SingleActivator(LogicalKeyboardKey.keyY, control: true): () => _step(_h.redo, _h.undo),
                const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): () => _step(_h.redo, _h.undo),
                const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copySelection,
                const SingleActivator(LogicalKeyboardKey.keyX, control: true): () => _copySelection(cut: true),
                const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
                const SingleActivator(LogicalKeyboardKey.keyD, control: true): _duplicateSelection,
                const SingleActivator(LogicalKeyboardKey.delete): _deleteSelection,
                const SingleActivator(LogicalKeyboardKey.escape): () => setState(_clearSelection),
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(index - 1),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(index + 1),
                const SingleActivator(LogicalKeyboardKey.digit0, control: true): _fit,
                const SingleActivator(LogicalKeyboardKey.equal, control: true): () => zoomStep(1.25),
                const SingleActivator(LogicalKeyboardKey.bracketRight, control: true): () => zoomStep(1.25), // "+" on German keyboards
                const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): () => zoomStep(1.25),
                const SingleActivator(LogicalKeyboardKey.minus, control: true): () => zoomStep(0.8),
                const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true): () => zoomStep(0.8),
              },
              child: Focus(
                focusNode: _focus,
                autofocus: true,
                child: Column(children: [
                  SaveErrorBar(widget.store),
                  _toolbar(cs),
                  const Divider(height: 1),
                  Expanded(child: LayoutBuilder(builder: (context, c) {
                    if (c.biggest != viewport) {
                      final old = viewport;
                      viewport = c.biggest;
                      WidgetsBinding.instance.addPostFrameCallback((_) => _viewportChanged(old));
                    }
                    return MouseRegion(
                      cursor: mode == Mode.text ? SystemMouseCursors.text : SystemMouseCursors.precise,
                      child: Listener(
                        key: const Key('canvas'),
                        onPointerDown: _onDown,
                        onPointerMove: _onMove,
                        onPointerUp: _onUp,
                        onPointerCancel: (e) => _onUp(e, cancel: true),
                        onPointerSignal: _onSignal,
                        onPointerPanZoomStart: (_) => lastPanScale = 1,
                        onPointerPanZoomUpdate: (e) {
                          final f = e.scale / lastPanScale;
                          lastPanScale = e.scale;
                          final c1 = e.localPosition + e.localPan;
                          _zoomAround(c1 - e.localPanDelta, c1, f);
                        },
                        child: ClipRect(
                          child: ColoredBox(
                            color: cs.surfaceContainerHighest,
                            child: SizedBox.expand(
                              child: Stack(children: [
                                if (endless)
                                  ..._endlessLayers()
                                else ...[
                                  _transformed(_pageBackground()),
                                  if (pdfDetail != null) Positioned.fill(child: CustomPaint(painter: _DetailPainter(this))),
                                  _transformed(_pageContent()),
                                ],
                                // Zoom level, shown briefly while zooming; tap = back to the overview.
                                Positioned(
                                  top: 12,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: ValueListenableBuilder<String?>(
                                      valueListenable: zoomLabel,
                                      builder: (context, label, _) => AnimatedOpacity(
                                        opacity: label == null ? 0 : 1,
                                        duration: const Duration(milliseconds: 200),
                                        child: ActionChip(label: Text(label ?? ''), onPressed: label == null ? null : _fit, tooltip: fitLabel),
                                      ),
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    );
                  })),
                ]),
              ),
            ),
    );
  }

  /// Puts [child] (in page units) under the view transform. Positioned without a size = unconstrained,
  /// so the page keeps its full size even when the screen area is smaller.
  Widget _transformed(Widget child) => Positioned(
        left: 0,
        top: 0,
        child: ValueListenableBuilder<Matrix4>(
            valueListenable: view, builder: (context, m, child) => Transform(transform: m, child: child), child: child),
      );

  Widget _image(ImageBox i) => Positioned.fromRect(
      rect: i.rect,
      child: Image.file(File(widget.store.assetPath(i.asset)), fit: BoxFit.fill,
          errorBuilder: (_, _, _) => const ColoredBox(color: Color(0x22000000))));

  Widget _text(TextBox t) => Positioned(left: t.x, top: t.y, width: t.width, child: Text(t.text, style: _textStyle(t)));

  /// Endless sheet, bottom to top: paper, images, ink tiles, text, the live layer.
  /// Paper and ink are painted in screen space for the current view; images and text are moved by the transform.
  List<Widget> _endlessLayers() {
    final pg = page;
    Widget objects(List<Widget> children) =>
        _transformed(SizedBox(width: 1, height: 1, child: Stack(clipBehavior: Clip.none, children: children)));
    return [
      Positioned.fill(child: CustomPaint(painter: _EndlessPainter(this, ink: false))),
      objects([for (final i in pg.images) _image(i)]),
      Positioned.fill(child: CustomPaint(painter: _EndlessPainter(this, ink: true))),
      objects([for (final t in pg.texts) _text(t)]),
      Positioned.fill(child: CustomPaint(painter: _LivePainter(this))),
    ];
  }

  Widget _pageBackground() {
    final pg = page;
    return DecoratedBox(
      decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 10)]),
      child: SizedBox(width: pg.w, height: pg.h, child: RepaintBoundary(child: CustomPaint(painter: PaperPainter(pg, _pdfImage(pg))))),
    );
  }

  Widget _pageContent() {
    final pg = page;
    return SizedBox(
      width: pg.w,
      height: pg.h,
      child: ClipRect(
          child: Stack(children: [
        for (final i in pg.images) _image(i),
        Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: InkPainter(pg.strokes)))),
        for (final t in pg.texts) _text(t),
        Positioned.fill(child: CustomPaint(painter: _LivePainter(this))),
      ])),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    Widget tool(IconData icon, String tip, bool on, VoidCallback tap, {double? size}) => IconButton(
        icon: Icon(icon, size: size), tooltip: tip, isSelected: on, onPressed: tap,
        style: on ? IconButton.styleFrom(backgroundColor: cs.primaryContainer, foregroundColor: cs.onPrimaryContainer) : null);
    Widget gap() => const SizedBox(width: 14);
    final writing = mode == Mode.pen || mode == Mode.shape;
    final quick = pen == 'highlighter' ? _quickHighlighter : _quickPen;
    final cur = colors[pen]!;
    Widget colorRow(int current, void Function(int) set) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (final c in {...quick, current}) swatch(context, c, c == current, () => set(c)),
          IconButton(
              icon: const Icon(Icons.palette_outlined),
              tooltip: 'Mehr Farben',
              onPressed: () async {
                final c = await pickColor(context, palette, current);
                if (c != null) set(c);
              }),
        ]);
    final sizeList = mode == Mode.eraser ? _eraserSizes : penTypes[pen]!.sizes;
    final favs = Prefs.instance.favorites;

    return Material(
      color: cs.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          for (final e in penTypes.entries) tool(e.value.icon, e.value.name, mode == Mode.pen && pen == e.key, () => _setMode(Mode.pen, penType: e.key)),
          tool(Icons.category, 'Formen: Kreis, Linie, Rechteck, Dreieck werden sauber', mode == Mode.shape, () => _setMode(Mode.shape)),
          tool(Icons.auto_fix_normal, 'Radierer', mode == Mode.eraser, () => _setMode(Mode.eraser)),
          tool(Icons.highlight_alt, 'Lasso: auswählen, verschieben, Größe ändern', mode == Mode.lasso, () => _setMode(Mode.lasso)),
          tool(Icons.text_fields, 'Text (auf die Seite tippen)', mode == Mode.text, () => _setMode(Mode.text)),
          tool(Icons.auto_awesome, 'Laserpointer (verschwindet wieder)', mode == Mode.laser, () => _setMode(Mode.laser)),
          IconButton(icon: const Icon(Icons.image_outlined), tooltip: 'Bild einfügen', onPressed: _insertImage),
          gap(),
          if (writing || mode == Mode.text) ...[
            colorRow(cur, (c) => setState(() => colors[pen] = c)),
            gap(),
          ],
          if (writing || mode == Mode.eraser)
            for (var i = 0; i < sizeList.length; i++)
              tool(Icons.circle, 'Stärke ${i + 1}', (mode == Mode.eraser ? eraserSize : sizes[pen]) == sizeList[i],
                  () => setState(() => mode == Mode.eraser ? eraserSize = sizeList[i] : sizes[pen] = sizeList[i]),
                  size: 8.0 + i * 5),
          if (writing && pen == 'highlighter') ...[
            gap(),
            FilterChip(label: const Text('Gerade'), tooltip: 'Textmarker zieht gerade Linien', selected: straightHighlighter,
                onSelected: (v) => setState(() => straightHighlighter = v)),
          ],
          if (writing) ...[
            gap(),
            for (final f in favs)
              Tooltip(
                message: '${penTypes[f.type]?.name ?? 'Stift'} – lange drücken zum Entfernen',
                child: Semantics(
                  button: true,
                  label: 'Favorit ${penTypes[f.type]?.name ?? ''}',
                  child: InkResponse(
                    onTap: () => _useFavorite(f),
                    onLongPress: () => _removeFavorite(f),
                    radius: 20,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Color(f.color), width: 3)),
                        child: Icon(penTypes[f.type]?.icon ?? Icons.edit, size: 16,
                            color: Color(f.color).computeLuminance() > 0.8 ? Colors.black54 : Color(f.color)),
                      ),
                    ),
                  ),
                ),
              ),
            IconButton(icon: const Icon(Icons.star_border), tooltip: 'Aktuellen Stift als Favorit speichern', onPressed: _addFavorite),
          ],
          if (mode == Mode.eraser) ...[
            gap(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Ganzer Strich')),
                ButtonSegment(value: true, label: Text('Genau')),
              ],
              selected: {eraserPartial},
              onSelectionChanged: (v) => setState(() => eraserPartial = v.first),
            ),
            gap(),
            FilterChip(label: const Text('Nur Textmarker'), selected: eraserHighlighterOnly,
                onSelected: (v) => setState(() => eraserHighlighterOnly = v)),
          ],
          if (mode == Mode.lasso && _hasSel) ...[
            colorRow(selStrokes.isNotEmpty ? selStrokes.first.color : cur, _recolor),
            IconButton(icon: const Icon(Icons.content_copy), tooltip: 'Kopieren (Strg+C)', onPressed: _copySelection),
            IconButton(icon: const Icon(Icons.content_cut), tooltip: 'Ausschneiden (Strg+X)', onPressed: () => _copySelection(cut: true)),
            IconButton(icon: const Icon(Icons.control_point_duplicate), tooltip: 'Duplizieren (Strg+D)', onPressed: _duplicateSelection),
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Löschen (Entf)', onPressed: _deleteSelection),
          ],
          if (mode == Mode.lasso && !_hasSel && _clipboard != null)
            TextButton.icon(icon: const Icon(Icons.content_paste), label: const Text('Einfügen'), onPressed: _paste),
          if (mode == Mode.lasso && !_hasSel && _clipboard == null)
            Text('Schleife um Geschriebenes ziehen oder antippen', style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.s) : super(repaint: s.tick);
  final _EditorState s;

  @override
  void paint(Canvas c, Size size) {
    if (s.endless) {
      // endless sheet: this painter fills the screen, so move into page units first
      c.translate(s.offset.dx, s.offset.dy);
      c.scale(s.scale);
    }
    final accent = const Color(0xFF4F46E5), hair = 1.5 / s.scale;

    // laser pointer: glowing red, fading out
    final now = DateTime.now();
    for (final (st, end) in s.laser) {
      final a = (1 - now.difference(end).inMilliseconds / 1200).clamp(0.0, 1.0);
      _laser(c, strokePath(st), a);
    }
    final l = s.live;
    if (l != null) {
      if (s.mode == Mode.laser) {
        _laser(c, strokePath(l, complete: false), 1);
      } else {
        paintStroke(c, l, complete: false);
      }
    }

    if (s.eraserAt != null) {
      c.drawCircle(s.eraserAt!, s.eraserSize / s.zoom, Paint()..style = PaintingStyle.stroke..strokeWidth = hair..color = const Color(0xFF888888));
    }

    // lasso loop being drawn
    final loop = s.lassoPts;
    if (loop != null && loop.length > 1) {
      final path = Path()..addPolygon(loop, false);
      c.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = hair..color = accent);
    }

    // selection: moving strokes, frame and resize handle
    final d = s.drag;
    Rect? box;
    if (d != null) {
      c.save();
      c.translate(d.box.left + d.move.dx, d.box.top + d.move.dy);
      c.scale(d.k);
      c.translate(-d.box.left, -d.box.top);
      for (final st in d.strokes) {
        paintStroke(c, st);
      }
      c.restore();
      box = Rect.fromPoints(d.map(d.box.topLeft), d.map(d.box.bottomRight));
    } else if (s._hasSel) {
      box = s._selBox;
    }
    if (box != null) {
      final r = box.inflate(4 / s.scale);
      final frame = Paint()..style = PaintingStyle.stroke..strokeWidth = hair..color = accent;
      // dashed frame
      for (final (a, b) in [(r.topLeft, r.topRight), (r.topRight, r.bottomRight), (r.bottomRight, r.bottomLeft), (r.bottomLeft, r.topLeft)]) {
        final len = (b - a).distance, dash = 6 / s.scale;
        for (var t = 0.0; t < len; t += dash * 2) {
          c.drawLine(Offset.lerp(a, b, t / len)!, Offset.lerp(a, b, math.min(1, (t + dash) / len))!, frame);
        }
      }
      c.drawCircle(r.bottomRight, 8 / s.scale, Paint()..color = accent);
      c.drawCircle(r.bottomRight, 4 / s.scale, Paint()..color = const Color(0xFFFFFFFF));
    }
  }

  void _laser(Canvas c, Path p, double a) {
    if (a <= 0) return;
    c.drawPath(p, Paint()
      ..color = Color.fromRGBO(255, 23, 68, 0.35 * a)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 / s.scale));
    c.drawPath(p, Paint()..color = Color.fromRGBO(255, 23, 68, a));
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

/// Endless sheet in screen space: the paper pattern ([ink] false) or the ink tiles ([ink] true).
class _EndlessPainter extends CustomPainter {
  _EndlessPainter(this.s, {required this.ink}) : super(repaint: s.tick);
  final _EditorState s;
  final bool ink;

  @override
  void paint(Canvas c, Size size) {
    if (!ink) return paintEndlessPaper(c, size, s.page.paper, s.offset, s.scale);
    s.scene?.sync(s.page.strokes); // tells the tiles what changed
    s.tiles?.paint(c, size, s.offset, s.scale, s.dpr);
  }

  @override
  bool shouldRepaint(_EndlessPainter old) => true;
}

/// PDF page: extra sharp tiles over the page image while zoomed in.
class _DetailPainter extends CustomPainter {
  _DetailPainter(this.s) : super(repaint: s.tick);
  final _EditorState s;

  @override
  void paint(Canvas c, Size size) => s.pdfDetail?.paint(c, size, s.offset, s.scale, s.dpr);

  @override
  bool shouldRepaint(_DetailPainter old) => true;
}
