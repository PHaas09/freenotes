// ignore_for_file: avoid_print
// How big and how fast the PDF export of an imported PDF is.
// Run: FREENOTES_PDF=path/to/file.pdf [FREENOTES_OUT=folder] flutter test benchmark/pdf_export_bench_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/pdf_export.dart';
import 'package:freenotes/store.dart';
import 'package:pdfrx/pdfrx.dart';

import '../test/rust_init.dart';

void main() {
  final pdf = Platform.environment['FREENOTES_PDF'];
  setUpAll(initRust);

  testWidgets('export an imported PDF', (tester) async {
    if (pdf == null) return markTestSkipped('set FREENOTES_PDF');
    await tester.runAsync(() async {
      Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path; // no path_provider plugin in tests
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openFile(pdf);
      final nb = Notebook('abcd1234', [
        for (final p in doc.pages) NotePage(pdf: 'x.pdf', pdfPage: p.pageNumber - 1, w: p.width, h: p.height,
            strokes: [Stroke(type: 'ballpoint', color: 0xFF1E40FF, size: 2, pts: [50, 50, .5, 200, 80, .5])]),
      ]);
      final sw = Stopwatch()..start();
      final bytes = await exportPdf(nb, Store(Directory.systemTemp), openPdf: (_) async => doc);
      print('Original: ${File(pdf).lengthSync() ~/ 1024} KB, ${doc.pages.length} Seiten');
      print('Export: ${bytes.length ~/ 1024} KB in ${sw.elapsedMilliseconds} ms');
      final out = Platform.environment['FREENOTES_OUT'];
      if (out == null) return;
      // first page of the exported file as PNG, to check colours and sharpness by eye
      final back = await PdfDocument.openData(bytes);
      final pg = back.pages.first;
      final img = await (await pg.render(fullWidth: pg.width * 2, fullHeight: pg.height * 2))!.createImage();
      File('$out/export_page1.png').writeAsBytesSync((await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
    });
  });
}
