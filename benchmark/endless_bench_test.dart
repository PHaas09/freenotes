// ignore_for_file: avoid_print
// Load test for the endless sheet: 1000 fully written A4 pages on one sheet.
// Run: flutter test benchmark/endless_bench_test.dart
// Times are from the debug test runner (JIT); the installed app (AOT) is usually several times faster.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/ink.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/tiles.dart';
import 'package:material_ui/material_ui.dart';

const pages = 1000, linesPerPage = 30, wordsPerLine = 4; // 120 strokes per page

List<Stroke> handwriting() {
  final rnd = math.Random(1), out = <Stroke>[];
  for (var p = 0; p < pages; p++) {
    final px = (p % 40) * 650.0, py = (p ~/ 40) * 900.0; // pages side by side, 40 per row
    for (var l = 0; l < linesPerPage; l++) {
      for (var w = 0; w < wordsPerLine; w++) {
        final x0 = px + 40 + w * 130, y0 = py + 60 + l * 26, pts = <double>[];
        for (var i = 0; i < 40; i++) {
          pts.addAll([x0 + i * 3, y0 + math.sin(i * 0.9 + rnd.nextDouble()) * 7, 0.5]);
        }
        out.add(Stroke(type: 'ballpoint', color: 0xFF1A1A1A, size: 2, pts: Float32List.fromList(pts)));
      }
    }
  }
  return out;
}

Future<int> settle(TileCache cache, Size size, Offset offset, double scale) async {
  final sw = Stopwatch()..start();
  var last = -1, same = 0;
  while (same < 5 && sw.elapsedMilliseconds < 120000) {
    final rec = ui.PictureRecorder();
    cache.paint(Canvas(rec), size, offset, scale, 1);
    rec.endRecording().dispose();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    same = cache.readyTiles == last ? same + 1 : 0;
    last = cache.readyTiles;
  }
  return sw.elapsedMilliseconds;
}

void main() {
  testWidgets('1000 A4 pages on one endless sheet', (tester) async {
    await tester.runAsync(() async {
      final sw = Stopwatch()..start();
      final strokes = handwriting();
      final pts = strokes.fold<int>(0, (n, s) => n + s.pts.length ~/ 3);
      print('Striche: ${strokes.length}, Punkte: $pts (erzeugt in ${sw.elapsedMilliseconds} ms)');

      final nb = Notebook('bench0001', [NotePage(infinite: true, strokes: strokes)]);
      sw.reset();
      final saving = encodeNotebook(nb);
      print('Speichern, davon blockiert die Oberfläche: ${sw.elapsedMilliseconds} ms');
      final bytes = await saving;
      print('Speichern (Hintergrund): ${sw.elapsedMilliseconds} ms, Datei ${(bytes.length / 1048576).toStringAsFixed(1)} MB');
      sw.reset();
      final loading = decodeNotebook(bytes);
      print('Laden, davon blockiert die Oberfläche: ${sw.elapsedMilliseconds} ms');
      final loaded = (await loading).pages.single.strokes;
      print('Laden (Hintergrund, inkl. Begrenzungen): ${sw.elapsedMilliseconds} ms');

      const view = Size(1280, 800);
      final cache = TileCache(() {});
      sw.reset();
      cache.setStrokes(loaded);
      for (final s in loaded) { strokeBounds(s); }
      print('Öffnen: Vorbereitung im Vordergrund: ${sw.elapsedMilliseconds} ms');

      // Overview: all 1000 pages on one screen (40 x 25 pages = 26 000 x 22 500 units)
      const overview = 0.045;
      print('Gesamtansicht zeichnen (einmalig): ${await settle(cache, view, const Offset(20, 20), overview)} ms');
      var frame = Stopwatch()..start();
      for (var i = 0; i < 60; i++) {
        final rec = ui.PictureRecorder();
        cache.paint(Canvas(rec), view, Offset(20.0 + i, 20), overview, 1);
        rec.endRecording().dispose();
      }
      print('Verschieben in der Gesamtansicht: ${(frame.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)} ms pro Bild');

      // Zoomed into one page, as when writing
      const write = 1.5, at = Offset(-20000, -10000);
      print('Hineinzoomen auf eine Seite (neue Kacheln): ${await settle(cache, view, at, write)} ms');
      frame = Stopwatch()..start();
      for (var i = 0; i < 60; i++) {
        final rec = ui.PictureRecorder();
        cache.paint(Canvas(rec), view, at + Offset(i.toDouble(), 0), write, 1);
        rec.endRecording().dispose();
      }
      print('Verschieben beim Schreiben: ${(frame.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)} ms pro Bild');

      // Writing one more stroke and erasing
      final extra = Stroke(type: 'ballpoint', color: 0xFF000000, size: 2, pts: Float32List.fromList([13400, 6800, .5, 13500, 6810, .5]));
      final more = [...loaded, extra];
      sw.reset();
      cache.setStrokes(more);
      print('Strich hinzufügen (Liste + Kacheln markieren): ${sw.elapsedMicroseconds / 1000} ms');
      sw.reset();
      final hit = more.where((s) => hitStroke(s, const Offset(13450, 6805), 5)).length;
      print('Radierer-Treffertest über alle Striche: ${sw.elapsedMicroseconds / 1000} ms ($hit Treffer)');
      cache.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
