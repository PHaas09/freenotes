import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/tiles.dart';
import 'package:material_ui/material_ui.dart';

/// Paints the cache like the app does each frame, giving the background tile rendering time in between,
/// until every visible tile is up to date. Returns the final frame as an image.
Future<ui.Image> settle(TileCache cache, Size size, Offset offset, double scale) async {
  for (var i = 0; i < 50; i++) {
    final rec = ui.PictureRecorder();
    cache.paint(Canvas(rec), size, offset, scale, 1);
    rec.endRecording().dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final rec = ui.PictureRecorder();
  cache.paint(Canvas(rec), size, offset, scale, 1);
  return rec.endRecording().toImage(size.width.toInt(), size.height.toInt());
}

Future<int> alphaAt(ui.Image img, int x, int y) async {
  final data = (await img.toByteData())!;
  return data.getUint8((y * img.width + x) * 4 + 3);
}

Stroke line(double x0, double y, double x1) =>
    Stroke(type: 'ballpoint', color: 0xFF000000, size: 4, pts: Float32List.fromList([x0, y, .5, x1, y, .5]));

void main() {
  test('tile level and size', () {
    expect(TileCache.levelFor(1), 0);
    expect(TileCache.levelFor(3), 2); // 3 px per unit needs the 4 px level
    expect(TileCache.tileSize(0), 512);
    expect(TileCache.tileRect((1, -1, 2)), const Rect.fromLTWH(-256, 512, 256, 256));
  });

  testWidgets('endless sheet: ink is drawn into tiles, erased ink disappears from them', (tester) async {
    await tester.runAsync(() async {
      final cache = TileCache(() {});
      final s = line(20, 30, 300);
      cache.setStrokes([s]);
      final img = await settle(cache, const Size(400, 300), Offset.zero, 1);
      expect(cache.readyTiles, greaterThan(0));
      expect(await alphaAt(img, 150, 30), greaterThan(200), reason: 'line is visible');
      expect(await alphaAt(img, 150, 200), 0, reason: 'empty paper stays empty');

      cache.setStrokes([], removed: [s]); // eraser
      final after = await settle(cache, const Size(400, 300), Offset.zero, 1);
      expect(await alphaAt(after, 150, 30), 0, reason: 'erased line is gone after the tiles are redrawn');
      cache.dispose();
    });
  });

  testWidgets('endless sheet: zoomed far out, thousands of strokes still show up', (tester) async {
    await tester.runAsync(() async {
      final cache = TileCache(() {});
      // 2000 lines spread over 60 000 x 60 000 units (roughly 100 x 70 A4 pages)
      cache.setStrokes([for (var i = 0; i < 2000; i++) line((i % 50) * 1200.0, (i ~/ 50) * 1500.0, (i % 50) * 1200.0 + 1000)]);
      final img = await settle(cache, const Size(600, 600), Offset.zero, 0.01);
      expect(await alphaAt(img, 5, 0), greaterThan(0), reason: 'the first line, 1 px tall at this zoom');
      cache.dispose();
    });
  });
}
