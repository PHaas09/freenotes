// ignore_for_file: avoid_print
// Shows how a scanned PDF page looks zoomed in, without and with FreeNotes' scan sharpening.
// Run: FREENOTES_PDF=path/to/file.pdf FREENOTES_OUT=folder flutter test benchmark/scan_preview_test.dart
// Optional: FREENOTES_PAGE (index, default 1), FREENOTES_X / FREENOTES_Y (page units, top left of the
// 512 px tile, default 450 / 70), FREENOTES_ZOOM (times the scan resolution, default 6), FREENOTES_PX (tile size, default 512).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/pdf_detail.dart';
import 'package:freenotes/scene.dart' show imageFromPixels;
import 'package:freenotes/src/rust/api/scan.dart';
import 'package:pdfrx/pdfrx.dart';

import '../test/rust_init.dart';

void main() {
  final env = Platform.environment;
  final pdf = env['FREENOTES_PDF'], out = env['FREENOTES_OUT'];
  double num(String k, double d) => double.tryParse(env[k] ?? '') ?? d;
  setUpAll(initRust);

  testWidgets('zoomed scan: plain vs sharpened', (tester) async {
    if (pdf == null || out == null) return markTestSkipped('set FREENOTES_PDF and FREENOTES_OUT');
    await tester.runAsync(() async {
      Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path; // no path_provider plugin in tests
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openFile(pdf);
      final page = doc.pages[num('FREENOTES_PAGE', 1).toInt()];
      final text = await page.loadText();
      print('Text auf der Seite: ${text?.fullText.trim().length ?? 0} Zeichen');
      const res = PdfDetail.scanRes;
      final img = await page.render(fullWidth: page.width * res, fullHeight: page.height * res, backgroundColor: 0xFFFFFFFF);
      final base = await img!.createImage(); // the page as PDFium draws it, for comparing
      File('$out/scan_base.png').writeAsBytesSync((await base.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      final sw = Stopwatch()..start();
      final scan = await scanLoad(pixels: img.pixels, width: img.width, height: img.height, res: res, bgra: true);
      print('Farbkarten vorbereitet: ${sw.elapsedMilliseconds} ms (${img.width} x ${img.height} px)');
      // a 512 px tile at 6x the scan resolution, in the body text of the right page
      final unit = res * num('FREENOTES_ZOOM', 6), x0 = num('FREENOTES_X', 450), y0 = num('FREENOTES_Y', 70);
      final px = num('FREENOTES_PX', 512).toInt();
      sw.reset();
      final sharp = await scanRender(scan: scan, x0: x0, y0: y0, unit: unit, px: px);
      print('Kachel geschärft: ${sw.elapsedMilliseconds} ms');
      final plain = await page.render(
          x: (x0 * unit).round(), y: (y0 * unit).round(), width: px, height: px, fullWidth: page.width * unit, fullHeight: page.height * unit);
      Future<void> save(ui.Image i, String name) async =>
          File('$out/$name').writeAsBytesSync((await i.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      await save(await imageFromPixels(sharp, px, px), 'scan_sharp.png');
      await save(await plain!.createImage(), 'scan_plain.png');
      scanDrop(scan: scan);
      await doc.dispose();
    });
  });
}
