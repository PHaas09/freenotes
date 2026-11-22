import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'scene.dart' show imageFromPixels;
import 'src/rust/api/scan.dart' as rust;
import 'tiles.dart';

/// Keeps a PDF page sharp at any zoom. Pages with real text are re-drawn by PDFium for just the visible
/// part at the exact zoom (text and lines are vector shapes, so they stay sharp however far you zoom).
/// Scanned pages are only a picture; there the Rust core rebuilds sharp letter edges from the scan.
class PdfDetail {
  PdfDetail(this.page, this.onChange);
  final PdfPage page;
  final VoidCallback onChange;
  late final TileCache tiles = TileCache(onChange, _render, parallel: 2, ready: () => _kind != null);
  String? _kind; // 'text' or 'scan', once known
  int? _scan;
  bool _disposed = false;

  /// Pixels per page unit the scan is prepared at (about 216 dpi, more than most scans have).
  static const scanRes = 3.0;

  bool get isScan => _kind == 'scan';

  Future<void> init() async {
    try {
      final text = await page.loadText();
      if ((text?.fullText.trim().length ?? 0) > 20) {
        _kind = 'text';
        return onChange();
      }
      final img = await page.render(fullWidth: page.width * scanRes, fullHeight: page.height * scanRes, backgroundColor: 0xFFFFFFFF);
      if (img == null || _disposed) return img?.dispose();
      final id = await rust.scanLoad(pixels: img.pixels, width: img.width, height: img.height, res: scanRes, bgra: true);
      img.dispose();
      if (_disposed) return rust.scanDrop(scan: id);
      _scan = id;
      _kind = 'scan';
      onChange();
    } catch (_) {
      // the normal page image still shows; only the extra sharpness is missing
    }
  }

  /// The normal page image is drawn at 2 pixels per unit; more detail is only needed beyond that.
  bool _needed(double pxPerUnit) => switch (_kind) {
        'text' => pxPerUnit > 2.2,
        'scan' => pxPerUnit > scanRes * 1.1,
        _ => false,
      };

  Future<ui.Image?> _render(Rect world, double unit, int px) async {
    if (!world.overlaps(Rect.fromLTWH(0, 0, page.width, page.height))) return null;
    if (_kind == 'scan') {
      final pixels = await rust.scanRender(scan: _scan!, x0: world.left, y0: world.top, unit: unit, px: px);
      return pixels.isEmpty ? null : imageFromPixels(pixels, px, px);
    }
    final img = await page.render(
        x: (world.left * unit).round(),
        y: (world.top * unit).round(),
        width: px,
        height: px,
        fullWidth: page.width * unit,
        fullHeight: page.height * unit,
        backgroundColor: 0xFFFFFFFF);
    if (img == null) return null;
    final image = await img.createImage();
    img.dispose();
    return image;
  }

  /// Paints over the normal page image where the screen needs more detail (screen = offset + page * scale).
  void paint(Canvas c, Size size, Offset offset, double scale, double dpr) {
    if (!_needed(scale * dpr)) return;
    c.save();
    c.clipRect(Rect.fromLTWH(offset.dx, offset.dy, page.width * scale, page.height * scale));
    tiles.paint(c, size, offset, scale, dpr);
    c.restore();
  }

  void dispose() {
    _disposed = true;
    tiles.dispose();
    if (_scan != null) rust.scanDrop(scan: _scan!);
  }
}
