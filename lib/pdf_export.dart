import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' show PdfDocument;

import 'ink.dart' show penTypes;
import 'model.dart';
import 'src/rust/api/codec.dart' as rust show encodeJpeg;
import 'src/rust/api/ink.dart' as rust;
import 'store.dart';

/// The notebook as a PDF file: ink as sharp vector shapes (the same outlines the app draws), paper lines
/// as vectors, pictures and imported PDF pages as images, typed text in the standard Helvetica font.
/// An endless sheet becomes one page as big as what is written on it.
Future<Uint8List> exportPdf(Notebook nb, Store store,
    {required Future<PdfDocument> Function(String asset) openPdf, void Function(int done, int total)? progress}) async {
  final doc = pw.Document(creator: 'FreeNotes');
  for (var n = 0; n < nb.pages.length; n++) {
    progress?.call(n, nb.pages.length);
    final pg = nb.pages[n];
    final area = pg.infinite ? _content(pg) : Rect.fromLTWH(0, 0, pg.w, pg.h);

    pw.ImageProvider? background;
    if (pg.pdf != null && pg.pdfPage != null) {
      // shortcut: imported PDF pages are embedded as images (216 dpi), not as the original vector page
      final src = await openPdf(pg.pdf!);
      final img = await src.pages[pg.pdfPage!].render(fullWidth: pg.w * 3, fullHeight: pg.h * 3, backgroundColor: 0xFFFFFFFF);
      if (img != null) {
        background = pw.MemoryImage(await rust.encodeJpeg(bgra: img.pixels, width: img.width, height: img.height, quality: 90));
        img.dispose();
      }
    }
    final pictures = <(ImageBox, pw.ImageProvider)>[];
    for (final i in pg.images) {
      final f = File(store.assetPath(i.asset));
      if (await f.exists()) pictures.add((i, pw.MemoryImage(await f.readAsBytes())));
    }

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(area.width, area.height, marginAll: 0),
      build: (context) => pw.Stack(children: [
        if (background != null) pw.Positioned.fill(child: pw.Image(background, fit: pw.BoxFit.fill)),
        if (background == null)
          pw.Positioned.fill(child: pw.CustomPaint(size: PdfPoint(area.width, area.height), painter: (c, size) => _paper(c, size, pg.paper, area))),
        for (final (i, img) in pictures)
          pw.Positioned(
              left: i.rect.left - area.left,
              top: i.rect.top - area.top,
              child: pw.SizedBox(width: i.rect.width, height: i.rect.height, child: pw.Image(img, fit: pw.BoxFit.fill))),
        pw.Positioned.fill(
            child: pw.CustomPaint(size: PdfPoint(area.width, area.height), painter: (c, size) => _ink(c, size, pg.strokes, area))),
        for (final t in pg.texts)
          pw.Positioned(
              left: t.x - area.left,
              top: t.y - area.top,
              child: pw.SizedBox(
                  width: t.width,
                  child: pw.Text(t.text, style: pw.TextStyle(fontSize: t.size, color: PdfColor.fromInt(t.color), lineSpacing: t.size * 0.3)))),
      ]),
    ));
  }
  progress?.call(nb.pages.length, nb.pages.length);
  return doc.save();
}

Rect _content(NotePage pg) {
  Rect? b;
  for (final s in pg.strokes) {
    b = b?.expandToInclude(s.bounds) ?? s.bounds;
  }
  for (final i in pg.images) {
    b = b?.expandToInclude(i.rect) ?? i.rect;
  }
  for (final t in pg.texts) {
    final r = Rect.fromLTWH(t.x, t.y, t.width, t.size * 2);
    b = b?.expandToInclude(r) ?? r;
  }
  return (b ?? const Rect.fromLTWH(0, 0, 595, 842)).inflate(30);
}

// PDF drawing has y pointing up from the bottom edge; the app's page space has y pointing down.
double _y(PdfPoint size, Rect area, double y) => size.y - (y - area.top);

void _ink(PdfGraphics c, PdfPoint size, List<Stroke> strokes, Rect area) {
  for (final s in strokes) {
    final o = rust.strokeOutline(kind: s.kind, size: s.size, sim: s.sim, points: s.pts, complete: true);
    if (o.starts.isEmpty) continue;
    final p = o.points;
    for (var k = 0; k < o.starts.length; k++) {
      final from = o.starts[k], to = k + 1 < o.starts.length ? o.starts[k + 1] : p.length ~/ 2;
      if (to - from < 3) continue;
      c.moveTo(p[2 * from] - area.left, _y(size, area, p[2 * from + 1]));
      for (var i = from + 1; i < to; i++) {
        c.lineTo(p[2 * i] - area.left, _y(size, area, p[2 * i + 1]));
      }
      c.closePath();
    }
    final alpha = ((s.color >> 24) / 255) * (penTypes[s.type]?.alpha ?? 1);
    c
      ..saveContext()
      ..setGraphicState(PdfGraphicState(opacity: alpha))
      ..setFillColor(PdfColor.fromInt(s.color | 0xFF000000))
      ..fillPath()
      ..restoreContext();
  }
}

void _paper(PdfGraphics c, PdfPoint size, String paper, Rect area) {
  c
    ..setFillColor(PdfColor.fromInt(0xFFFFFEFA))
    ..drawRect(0, 0, size.x, size.y)
    ..fillPath();
  if (paper == 'blank') return;
  const g = 24.0;
  c
    ..setStrokeColor(PdfColor.fromInt(0xFFCDD8E6))
    ..setLineWidth(0.6);
  final h = area.height, w = area.width;
  if (paper == 'dots') {
    c.setFillColor(PdfColor.fromInt(0xFFAAB6C6));
    for (var x = g; x < w; x += g) {
      for (var y = g; y < h; y += g) {
        c.drawEllipse(x, size.y - y, 0.8, 0.8);
      }
    }
    c.fillPath();
    return;
  }
  for (var y = paper == 'lined' ? 3 * g : g; y < h - (paper == 'lined' ? g : 0); y += g) {
    c
      ..moveTo(0, size.y - y)
      ..lineTo(w, size.y - y);
  }
  if (paper == 'grid') {
    for (var x = g; x < w; x += g) {
      c
        ..moveTo(x, 0)
        ..lineTo(x, size.y);
    }
  }
  c.strokePath();
  if (paper == 'lined') {
    c
      ..setStrokeColor(PdfColor.fromInt(0xFFF0B4B4))
      ..setLineWidth(0.8)
      ..moveTo(60, 0)
      ..lineTo(60, size.y)
      ..strokePath();
  }
}
