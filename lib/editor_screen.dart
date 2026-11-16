import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'dialogs.dart';
import 'ink.dart';
import 'model.dart';
import 'store.dart';
import 'sync.dart';

enum Mode { pen, eraser, text, select }

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

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.store, required this.sync, required this.meta});
  final Store store;
  final SyncService sync;
  final NotebookMeta meta;
  @override
  State<EditorScreen> createState() => _EditorState();
}

class _EditorState extends State<EditorScreen> {
  Notebook? nb;
  int index = 0;
  NotePage get page => nb!.pages[index];

  Mode mode = Mode.pen;
  String pen = 'ballpoint';
  final colors = {'ballpoint': 0xFF1A1A1A, 'fountain': 0xFF1E4FD8, 'pencil': 0xFF5F6368, 'highlighter': 0xFFFFD400};
  final sizes = {for (final e in penTypes.entries) e.key: e.value.sizes[1]};
  double eraserSize = 10;

  // View: page point p is drawn at offset + p * scale.
  final view = ValueNotifier<Matrix4>(Matrix4.identity());
  double scale = 1, fitScale = 1, lastPanScale = 1;
  Offset offset = Offset.zero;
  Size viewport = Size.zero;

  final tick = _Tick();
  final hist = <String, _Hist>{};

  // Input state
  final touches = <int, Offset>{}; // fingers / right-mouse used for pan + zoom
  int? drawPointer;
  bool stylusSeen = false; // after the first stylus touch, fingers only pan and zoom (palm rejection)
  Stroke? live;
  bool erasing = false, dragged = false, resizing = false;
  _Snap? before;
  Offset? eraserAt, downAt;
  Offset downScreen = Offset.zero;
  String? selected;
  TextBox? origText;
  ImageBox? origImage;

  final pdfDocs = <String, PdfDocument>{};
  final pdfImages = <String, ui.Image>{};

  @override
  void initState() {
    super.initState();
    widget.sync.openId = widget.meta.id;
    widget.store.loadNotebook(widget.meta.id).then((n) {
      if (!mounted) return;
      setState(() => nb = n);
      _loadPdf();
    }, onError: (Object e) {
      if (mounted) snack(context, 'Notizbuch konnte nicht geöffnet werden: $e');
    });
  }

  @override
  void dispose() {
    widget.sync.openId = null;
    widget.store.flush().then((_) => widget.sync.run());
    for (final d in pdfDocs.values) { d.dispose(); }
    for (final i in pdfImages.values) { i.dispose(); }
    super.dispose();
  }

  // ---------- view ----------
  Offset toPage(Offset local) => (local - offset) / scale;

  void _apply() {
    final w = page.w * scale, h = page.h * scale;
    offset = Offset(offset.dx.clamp(80 - w, math.max(80 - w, viewport.width - 80)),
        offset.dy.clamp(80 - h, math.max(80 - h, viewport.height - 80)));
    view.value = Matrix4.translationValues(offset.dx, offset.dy, 0)..multiply(Matrix4.diagonal3Values(scale, scale, 1));
    tick.ping();
  }

  void _fit() {
    if (viewport.isEmpty || nb == null) return;
    scale = fitScale = math.min(viewport.width / page.w, viewport.height / page.h) * 0.96;
    offset = Offset((viewport.width - page.w * scale) / 2, (viewport.height - page.h * scale) / 2);
    _apply();
  }

  /// Zoom by [f] and move, keeping the page point under [c0] under [c1].
  void _zoomAround(Offset c0, Offset c1, double f) {
    final ns = (scale * f).clamp(fitScale * 0.5, 10.0);
    final p = (c0 - offset) / scale;
    offset = c1 - p * ns;
    scale = ns;
    _apply();
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
    if (_isStylus(e)) stylusSeen = true;
    final touch = e.kind == PointerDeviceKind.touch, mouse = e.kind == PointerDeviceKind.mouse;
    if (mouse && e.buttons != kPrimaryMouseButton) {
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
      } else {
        _objMove(p);
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
      _zoomAround(_centroid(prev), _centroid(now), f);
    }
  }

  void _onUp(PointerEvent e, {bool cancel = false}) {
    touches.remove(e.pointer);
    if (e.pointer == drawPointer) _end(cancel: cancel);
  }

  Offset _centroid(List<Offset> l) => l.reduce((a, b) => a + b) / l.length.toDouble();

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed) {
      _zoomAround(e.localPosition, e.localPosition, math.exp(-e.scrollDelta.dy / 400));
    } else {
      offset -= kb.isShiftPressed ? Offset(e.scrollDelta.dy, 0) : e.scrollDelta;
      _apply();
    }
  }

  void _begin(PointerDownEvent e) {
    final p = toPage(e.localPosition);
    downScreen = e.localPosition;
    dragged = false;
    if (e.kind == PointerDeviceKind.invertedStylus || mode == Mode.eraser) {
      erasing = true;
      before = _snap();
      _eraseAt(p);
    } else if (mode == Mode.pen) {
      live = Stroke(type: pen, color: colors[pen]!, size: sizes[pen]!, sim: !_isStylus(e), pts: [p.dx, p.dy, _pressure(e)]);
      tick.ping();
    } else {
      _objDown(p);
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
      if (!cancel) _edit(() => page.strokes = [...page.strokes, s]);
      tick.ping();
    } else {
      _objUp(cancel);
    }
  }

  void _eraseAt(Offset p) {
    eraserAt = p;
    final kept = page.strokes.where((s) => !hitStroke(s, p, eraserSize)).toList();
    if (kept.length != page.strokes.length) setState(() => page.strokes = kept);
    tick.ping();
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
    if (_h.undo.length > 300) _h.undo.removeAt(0);
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
      selected = null;
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

  Rect? _rectOf(String id) {
    for (final t in page.texts) { if (t.id == id) return _textRect(t); }
    for (final i in page.images) { if (i.id == id) return i.rect; }
    return null;
  }

  String? _hitObject(Offset p) {
    for (final t in page.texts.reversed) { if (_textRect(t).inflate(4).contains(p)) return t.id; }
    for (final i in page.images.reversed) { if (i.rect.contains(p)) return i.id; }
    return null;
  }

  void _objDown(Offset p) {
    downAt = p;
    if (mode != Mode.select) return;
    final sel = selected == null ? null : _rectOf(selected!);
    final img = page.images.where((i) => i.id == selected).firstOrNull;
    if (img != null && sel != null && (p - sel.bottomRight).distance < 16 / scale) {
      resizing = true;
      origImage = img;
    } else {
      selected = _hitObject(p);
      origText = page.texts.where((t) => t.id == selected).firstOrNull;
      origImage = page.images.where((i) => i.id == selected).firstOrNull;
    }
    if (selected != null) before = _snap();
    setState(() {});
  }

  void _objMove(Offset p) {
    if (downAt == null || before == null) return;
    final d = p - downAt!;
    if (resizing && origImage != null) {
      final r = origImage!.rect, w = math.max(24.0, r.width + d.dx);
      _replaceImage(ImageBox(id: origImage!.id, asset: origImage!.asset, rect: Rect.fromLTWH(r.left, r.top, w, w * r.height / r.width)));
    } else if (origText != null) {
      final t = origText!.copyWith(x: origText!.x + d.dx, y: origText!.y + d.dy);
      setState(() => page.texts = [for (final x in page.texts) x.id == t.id ? t : x]);
    } else if (origImage != null) {
      _replaceImage(ImageBox(id: origImage!.id, asset: origImage!.asset, rect: origImage!.rect.shift(d)));
    }
  }

  void _replaceImage(ImageBox b) => setState(() => page.images = [for (final x in page.images) x.id == b.id ? b : x]);

  void _objUp(bool cancel) {
    if (before != null) {
      if (cancel) {
        setState(() => _restore(before!));
      } else {
        _commit(before!);
      }
    } else if (!cancel && !dragged && mode == Mode.text && downAt != null) {
      final id = _hitObject(downAt!);
      _editText(page.texts.where((t) => t.id == id).firstOrNull, downAt!);
    }
    before = null;
    downAt = null;
    origText = null;
    origImage = null;
    resizing = false;
  }

  Future<void> _editText(TextBox? t, Offset at) async {
    final ctrl = TextEditingController(text: t?.text ?? '');
    var size = t?.size ?? 16.0;
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
                                child: Slider(value: size, min: 10, max: 48, divisions: 19, label: '${size.round()}',
                                    onChanged: (v) => set(() => size = v))),
                          ]),
                        ])),
                    actions: [
                      if (t != null) TextButton(onPressed: () => Navigator.pop(ctx, del), child: const Text('Löschen')),
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
                    ])));
    if (res == null || !mounted) return;
    final color = colors[pen == 'highlighter' ? 'ballpoint' : pen]!;
    _edit(() {
      if (res == del || res.trim().isEmpty) {
        if (t != null) page.texts = page.texts.where((x) => x.id != t.id).toList();
      } else if (t == null) {
        page.texts = [...page.texts, TextBox(id: newId(), x: at.dx, y: at.dy, text: res, size: size, color: color)];
      } else {
        page.texts = [for (final x in page.texts) x.id == t.id ? x.copyWith(text: res, size: size) : x];
      }
    });
  }

  void _deleteSelected() {
    final id = selected;
    if (id == null) return;
    selected = null;
    _edit(() {
      page.texts = page.texts.where((t) => t.id != id).toList();
      page.images = page.images.where((i) => i.id != id).toList();
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
      final w = math.min(page.w * 0.6, iw);
      final box = ImageBox(id: newId(), asset: asset,
          rect: Rect.fromCenter(center: toPage(viewport.center(Offset.zero)), width: w, height: w * ih / iw));
      _edit(() => page.images = [...page.images, box]);
      setState(() {
        mode = Mode.select;
        selected = box.id;
      });
    } catch (e) {
      if (mounted) snack(context, 'Bild konnte nicht eingefügt werden: $e');
    }
  }

  // ---------- PDF background ----------
  String? _pdfKey(NotePage p) => p.pdf == null ? null : '${p.pdf}#${p.pdfPage}';

  Future<void> _loadPdf() async {
    final pg = page, key = _pdfKey(pg);
    if (key == null || pdfImages.containsKey(key)) return;
    try {
      final doc = pdfDocs[pg.pdf!] ??= await PdfDocument.openFile(widget.store.assetPath(pg.pdf!));
      final img = await doc.pages[pg.pdfPage!].render(fullWidth: pg.w * 2.5, fullHeight: pg.h * 2.5, backgroundColor: 0xFFFFFFFF);
      if (img == null) return;
      final image = await img.createImage();
      img.dispose();
      if (!mounted) return image.dispose();
      if (pdfImages.length >= 4) pdfImages.remove(pdfImages.keys.first)?.dispose();
      setState(() => pdfImages[key] = image);
    } catch (e) {
      if (mounted) snack(context, 'PDF-Seite konnte nicht geladen werden: $e');
    }
  }

  // ---------- pages ----------
  void _go(int i) {
    if (i < 0 || i >= nb!.pages.length) return;
    setState(() {
      index = i;
      selected = null;
    });
    _fit();
    _loadPdf();
  }

  void _addPage() {
    final cur = page;
    nb!.pages.insert(index + 1, NotePage(paper: cur.pdf != null ? 'blank' : cur.paper, w: cur.w, h: cur.h));
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

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.name),
        actions: nb == null
            ? null
            : [
                IconButton(icon: const Icon(Icons.undo), tooltip: 'Rückgängig (Strg+Z)', onPressed: _h.undo.isEmpty ? null : () => _step(_h.undo, _h.redo)),
                IconButton(icon: const Icon(Icons.redo), tooltip: 'Wiederholen (Strg+Y)', onPressed: _h.redo.isEmpty ? null : () => _step(_h.redo, _h.undo)),
                const SizedBox(width: 12),
                IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Vorherige Seite', onPressed: index > 0 ? () => _go(index - 1) : null),
                Center(child: Text('${index + 1} / ${nb!.pages.length}')),
                IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Nächste Seite',
                    onPressed: index < nb!.pages.length - 1 ? () => _go(index + 1) : null),
                IconButton(icon: const Icon(Icons.note_add_outlined), tooltip: 'Seite einfügen', onPressed: _addPage),
                IconButton(icon: const Icon(Icons.fit_screen), tooltip: 'Ganze Seite zeigen (Strg+0)', onPressed: _fit),
                PopupMenuButton<String>(
                  tooltip: 'Seite',
                  onSelected: (v) {
                    if (v == 'delete') {
                      _deletePage();
                      return;
                    }
                    setState(() => page.paper = v);
                    widget.store.changed(nb!);
                  },
                  itemBuilder: (_) => [
                    for (final (v, label) in [('blank', 'Blanko'), ('lined', 'Liniert'), ('grid', 'Kariert'), ('dots', 'Punktiert')])
                      CheckedPopupMenuItem(value: v, checked: page.paper == v, child: Text('Papier: $label')),
                    const PopupMenuDivider(),
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
                const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(index - 1),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(index + 1),
                const SingleActivator(LogicalKeyboardKey.digit0, control: true): _fit,
              },
              child: Focus(
                autofocus: true,
                child: Column(children: [
                  SaveErrorBar(widget.store),
                  _toolbar(cs),
                  const Divider(height: 1),
                  Expanded(child: LayoutBuilder(builder: (context, c) {
                    if (c.biggest != viewport) {
                      viewport = c.biggest;
                      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
                    }
                    return MouseRegion(
                      cursor: mode == Mode.select ? SystemMouseCursors.move : SystemMouseCursors.precise,
                      child: Listener(
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
                                ValueListenableBuilder<Matrix4>(
                                    valueListenable: view,
                                    builder: (context, m, child) => Transform(transform: m, child: child),
                                    child: _pageWidget()),
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

  Widget _pageWidget() {
    final pg = page, key = _pdfKey(pg);
    return DecoratedBox(
      decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 10)]),
      child: SizedBox(
        width: pg.w,
        height: pg.h,
        child: Stack(children: [
          Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: PaperPainter(pg, key == null ? null : pdfImages[key])))),
          for (final i in pg.images)
            Positioned.fromRect(
                rect: i.rect,
                child: Image.file(File(widget.store.assetPath(i.asset)), fit: BoxFit.fill,
                    errorBuilder: (_, _, _) => const ColoredBox(color: Color(0x22000000)))),
          Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: InkPainter(pg.strokes)))),
          for (final t in pg.texts) Positioned(left: t.x, top: t.y, width: t.width, child: Text(t.text, style: _textStyle(t))),
          Positioned.fill(child: CustomPaint(painter: _LivePainter(this))),
        ]),
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    Widget tool(IconData icon, String tip, bool on, VoidCallback tap, {double? size}) => IconButton(
        icon: Icon(icon, size: size), tooltip: tip, isSelected: on, onPressed: tap,
        style: on ? IconButton.styleFrom(backgroundColor: cs.primaryContainer, foregroundColor: cs.onPrimaryContainer) : null);
    final quick = pen == 'highlighter' ? _quickHighlighter : _quickPen;
    final cur = colors[pen]!;
    final sizeList = mode == Mode.eraser ? _eraserSizes : penTypes[pen]!.sizes;
    return Material(
      color: cs.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          for (final e in penTypes.entries)
            tool(e.value.icon, e.value.name, mode == Mode.pen && pen == e.key, () => setState(() {
                  mode = Mode.pen;
                  pen = e.key;
                  selected = null;
                })),
          tool(Icons.auto_fix_normal, 'Radierer', mode == Mode.eraser, () => setState(() {
                mode = Mode.eraser;
                selected = null;
              })),
          tool(Icons.text_fields, 'Text (auf die Seite tippen)', mode == Mode.text, () => setState(() {
                mode = Mode.text;
                selected = null;
              })),
          tool(Icons.pan_tool_alt, 'Auswählen und verschieben', mode == Mode.select, () => setState(() => mode = Mode.select)),
          IconButton(icon: const Icon(Icons.image_outlined), tooltip: 'Bild einfügen', onPressed: _insertImage),
          const SizedBox(width: 16),
          if (mode == Mode.pen || mode == Mode.text) ...[
            for (final c in {...quick, cur}) swatch(context, c, c == cur, () => setState(() => colors[pen] = c)),
            IconButton(
                icon: const Icon(Icons.palette_outlined),
                tooltip: 'Mehr Farben',
                onPressed: () async {
                  final c = await pickColor(context, palette, cur);
                  if (c != null) setState(() => colors[pen] = c);
                }),
            const SizedBox(width: 16),
          ],
          if (mode == Mode.pen || mode == Mode.eraser)
            for (var i = 0; i < sizeList.length; i++)
              tool(Icons.circle, 'Stärke ${i + 1}', (mode == Mode.eraser ? eraserSize : sizes[pen]) == sizeList[i],
                  () => setState(() => mode == Mode.eraser ? eraserSize = sizeList[i] : sizes[pen] = sizeList[i]),
                  size: 8.0 + i * 5),
          if (selected != null)
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Auswahl löschen (Entf)', onPressed: _deleteSelected),
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
    if (s.live != null) paintStroke(c, s.live!, complete: false);
    if (s.eraserAt != null) {
      c.drawCircle(s.eraserAt!, s.eraserSize,
          Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5 / s.scale..color = const Color(0xFF888888));
    }
    final r = s.selected == null ? null : s._rectOf(s.selected!);
    if (r != null) {
      final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5 / s.scale..color = const Color(0xFF4F46E5);
      c.drawRect(r.inflate(3 / s.scale), p);
      if (s.page.images.any((i) => i.id == s.selected)) {
        c.drawCircle(r.bottomRight, 7 / s.scale, Paint()..color = const Color(0xFF4F46E5));
      }
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
