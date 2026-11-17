import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

import 'model.dart';

class PenType {
  const PenType(this.name, this.icon, this.thinning, this.alpha, this.sizes);
  final String name;
  final IconData icon;
  final double thinning, alpha;
  final List<double> sizes;
}

const penTypes = {
  'ballpoint': PenType('Kugelschreiber', Icons.edit, 0.15, 1, [1.2, 2, 3]),
  'fountain': PenType('Füller', Icons.draw, 0.65, 1, [1.6, 2.6, 4]),
  'pencil': PenType('Bleistift', Icons.gesture, 0.3, 0.75, [1, 1.8, 3]),
  'highlighter': PenType('Textmarker', Icons.border_color, 0, 0.35, [10, 16, 24]),
};

const palette = [
  0xFF1A1A1A, 0xFF5F6368, 0xFFFFFFFF, 0xFF1E4FD8, 0xFF0B8BD9, 0xFF00897B,
  0xFF178A3E, 0xFF7CB342, 0xFFFFD400, 0xFFFF9800, 0xFFF4511E, 0xFFD42A2A,
  0xFFD81B60, 0xFFF48FB1, 0xFF8E24AA, 0xFF5E35B1, 0xFF6D4C41, 0xFF90A4AE,
];

// Path cache lives next to the strokes (not inside them): a Path can't be sent to the save isolate.
final _paths = Expando<Path>();

/// Area a stroke covers, including its width.
Rect strokeBounds(Stroke s) => s.bounds;

/// Outline of a stroke as a filled shape. Finished strokes are cached unless [cache] is false
/// (the endless sheet keeps its own image tiles instead of one path per stroke).
Path strokePath(Stroke s, {bool complete = true, bool cache = true}) {
  final hit = complete ? _paths[s] : null;
  if (hit != null) return hit;
  final pen = penTypes[s.type] ?? penTypes['ballpoint']!;
  final pts = [for (var i = 0; i + 2 < s.pts.length; i += 3) PointVector(s.pts[i], s.pts[i + 1], s.pts[i + 2])];
  final outline = getStroke(pts,
      options: StrokeOptions(
          size: s.size, thinning: pen.thinning, smoothing: 0.5, streamline: 0.35,
          simulatePressure: s.sim && pen.thinning > 0, isComplete: complete));
  final path = Path();
  if (outline.length > 2) path.addPolygon(outline, true);
  if (complete && cache) _paths[s] = path;
  return path;
}

Paint _inkPaint(Stroke s) {
  final pen = penTypes[s.type] ?? penTypes['ballpoint']!;
  final color = Color(s.color);
  return Paint()..color = pen.alpha < 1 ? color.withValues(alpha: pen.alpha) : color;
}

void paintStroke(Canvas c, Stroke s, {bool complete = true, bool cache = true}) =>
    c.drawPath(strokePath(s, complete: complete, cache: cache), _inkPaint(s));

/// Draws a stroke for a view where [pxPerUnit] screen pixels make one page unit. Strokes only a few
/// pixels wide are drawn as a plain line: looks the same, but is many times cheaper when zoomed far out.
void paintStrokeLod(Canvas c, Stroke s, double pxPerUnit) {
  if (s.size * pxPerUnit >= 2.5) return paintStroke(c, s, cache: false);
  final q = s.pts, path = Path()..moveTo(q[0], q[1]);
  for (var i = 3; i + 2 < q.length; i += 3) {
    path.lineTo(q[i], q[i + 1]);
  }
  if (q.length == 3) path.lineTo(q[0] + 0.01, q[1]);
  c.drawPath(path, _inkPaint(s)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = s.size * 0.8);
}

double distToSeg(Offset p, Offset a, Offset b) {
  final d = b - a, len2 = d.dx * d.dx + d.dy * d.dy;
  final t = len2 == 0 ? 0.0 : (((p - a).dx * d.dx + (p - a).dy * d.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + d * t)).distance;
}

/// True if an eraser of radius [r] at [p] touches the stroke.
bool hitStroke(Stroke s, Offset p, double r) {
  final tol = r + s.size / 2, q = s.pts;
  if (q.length < 3 || !strokeBounds(s).inflate(r).contains(p)) return false;
  var prev = Offset(q[0], q[1]);
  if (q.length == 3) return (p - prev).distance <= tol;
  for (var i = 3; i + 2 < q.length; i += 3) {
    final cur = Offset(q[i], q[i + 1]);
    if (distToSeg(p, prev, cur) <= tol) return true;
    prev = cur;
  }
  return false;
}

class PaperPainter extends CustomPainter {
  PaperPainter(this.page, this.pdfImage);
  final NotePage page;
  final ui.Image? pdfImage;

  @override
  void paint(Canvas c, Size size) {
    final r = Offset.zero & size;
    c.drawRect(r, Paint()..color = const Color(0xFFFFFEFA));
    if (pdfImage != null) {
      c.drawImageRect(pdfImage!, Offset.zero & Size(pdfImage!.width.toDouble(), pdfImage!.height.toDouble()), r,
          Paint()..filterQuality = FilterQuality.medium);
      return;
    }
    const g = 24.0;
    final line = Paint()..color = const Color(0xFFCDD8E6)..strokeWidth = 0.6;
    switch (page.paper) {
      case 'lined':
        for (var y = 3 * g; y < size.height - g; y += g) { c.drawLine(Offset(0, y), Offset(size.width, y), line); }
        c.drawLine(const Offset(60, 0), Offset(60, size.height), Paint()..color = const Color(0xFFF0B4B4)..strokeWidth = 0.8);
      case 'grid':
        for (var x = g; x < size.width; x += g) { c.drawLine(Offset(x, 0), Offset(x, size.height), line); }
        for (var y = g; y < size.height; y += g) { c.drawLine(Offset(0, y), Offset(size.width, y), line); }
      case 'dots':
        final dots = <Offset>[for (var x = g; x < size.width; x += g) for (var y = g; y < size.height; y += g) Offset(x, y)];
        c.drawPoints(ui.PointMode.points, dots,
            Paint()..color = const Color(0xFFAAB6C6)..strokeWidth = 1.6..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(PaperPainter old) => old.page.paper != page.paper || old.pdfImage != pdfImage || old.page != page;
}

/// Paper of the endless sheet, drawn in screen space for the current view ([offset], [scale]).
/// The pattern spacing halves or doubles with the zoom, so it never gets too dense or too sparse.
void paintEndlessPaper(Canvas c, Size size, String paper, Offset offset, double scale) {
  c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFEFA));
  if (paper == 'blank' || scale <= 0) return;
  var g = 24.0;
  while (g * scale < 16) { g *= 2; }
  while (g * scale >= 32) { g /= 2; }
  final step = g * scale, x0 = offset.dx % step, y0 = offset.dy % step;
  if (paper == 'dots') {
    c.drawPoints(ui.PointMode.points, [
      for (var x = x0; x < size.width; x += step) for (var y = y0; y < size.height; y += step) Offset(x, y)
    ], Paint()..color = const Color(0xFFAAB6C6)..strokeWidth = 2..strokeCap = StrokeCap.round);
    return;
  }
  final line = Paint()..color = const Color(0xFFCDD8E6)..strokeWidth = 1;
  for (var y = y0; y < size.height; y += step) { c.drawLine(Offset(0, y), Offset(size.width, y), line); }
  if (paper == 'grid') {
    for (var x = x0; x < size.width; x += step) { c.drawLine(Offset(x, 0), Offset(x, size.height), line); }
  }
}

/// Finished strokes. Recorded once into a Picture per strokes list, so zooming and
/// panning only replay it instead of rebuilding every path.
class InkPainter extends CustomPainter {
  InkPainter(this.strokes);
  final List<Stroke> strokes;
  static final _cache = Expando<ui.Picture>();

  @override
  void paint(Canvas c, Size size) {
    c.drawPicture(_cache[strokes] ??= () {
      final rec = ui.PictureRecorder();
      final pc = Canvas(rec);
      for (final s in strokes) { paintStroke(pc, s); }
      return rec.endRecording();
    }());
  }

  @override
  bool shouldRepaint(InkPainter old) => !identical(old.strokes, strokes);
}
