import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/editor_screen.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/store.dart';
import 'package:freenotes/sync.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'rust_init.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');
  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(root, 'docs');
}

/// Opens the editor on a new notebook and returns its state (read through `dynamic`, it is private).
Future<dynamic> openEditor(WidgetTester tester, {required bool endless}) async {
  late Store store;
  late NotebookMeta meta;
  await tester.runAsync(() async {
    final tmp = await Directory.systemTemp.createTemp('freenotes_editor');
    addTearDown(() => tmp.delete(recursive: true).then((_) {}, onError: (_) {})); // Windows may still hold a file
    PathProviderPlatform.instance = _FakePaths(tmp.path);
    store = await Store.open();
    meta = await store.createNotebook('Test', pages: [NotePage(infinite: endless)]);
  });
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: EditorScreen(store: store, sync: SyncService(store), meta: meta)));
  final dynamic s = tester.state(find.byType(EditorScreen));
  for (var i = 0; i < 100 && s.nb == null; i++) { // the notebook loads in a background isolate
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 50));
  return s;
}

/// Closes the editor and lets the pending save finish, so no timer outlives the test.
Future<void> closeEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(seconds: 5));
}

Offset canvasCenter(WidgetTester tester) => tester.getCenter(find.byKey(const Key('canvas')));

Future<void> pinch(WidgetTester tester, double from, double to, {Offset shift = Offset.zero}) async {
  final c = canvasCenter(tester);
  final a = await tester.startGesture(c - Offset(from / 2, 0), pointer: 11);
  final b = await tester.startGesture(c + Offset(from / 2, 0), pointer: 12);
  for (var i = 1; i <= 10; i++) {
    final d = from + (to - from) * i / 10, s = shift * (i / 10);
    await a.moveTo(c - Offset(d / 2, 0) + s);
    await b.moveTo(c + Offset(d / 2, 0) + s);
  }
  await a.up();
  await b.up();
  await tester.pump();
}

void main() {
  setUpAll(initRust);
  testWidgets('endless sheet: pinch zoom and pen width that follows the zoom', (tester) async {
    final s = await openEditor(tester, endless: true);
    expect(s.zoom, closeTo(1, 1e-9));

    await tester.dragFrom(canvasCenter(tester) - const Offset(100, 50), const Offset(200, 0));
    await tester.pump();
    expect(s.page.strokes.length, 1);
    final base = s.page.strokes.single.size as double;

    await pinch(tester, 400, 100); // zoom out to 25 %
    expect(s.zoom, closeTo(0.25, 0.01));
    expect(s.page.strokes.length, 1, reason: 'the first finger of a pinch must not leave a stroke');
    expect(find.text('25 %'), findsOneWidget, reason: 'zoom level is shown');

    await tester.dragFrom(canvasCenter(tester) + const Offset(-100, 100), const Offset(200, 0));
    await tester.pump();
    expect(s.page.strokes.last.size, closeTo(base * 4, 1e-6), reason: 'zoomed out 4x: pen 4x wider, same on screen');

    // Ctrl + mouse wheel zooms around the mouse
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    tester.binding.handlePointerEvent(PointerScrollEvent(position: canvasCenter(tester), scrollDelta: const Offset(0, -400)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(s.zoom, closeTo(0.25 * 2.718, 0.02));

    // endless sheet zooms far beyond a page in both directions
    for (var i = 0; i < 8; i++) {
      await pinch(tester, 400, 50);
    }
    expect(s.zoom, lessThan(0.01));
    await closeEditor(tester);
  });

  testWidgets('a quick two-finger pan keeps sliding a little (momentum)', (tester) async {
    final s = await openEditor(tester, endless: true);
    final c = canvasCenter(tester);
    final a = await tester.startGesture(c - const Offset(50, 0), pointer: 21);
    final b = await tester.startGesture(c + const Offset(50, 0), pointer: 22);
    for (var i = 1; i <= 5; i++) {
      final t = Duration(milliseconds: 8 * i); // 40 px every 8 ms = a quick swipe
      await a.moveTo(c - const Offset(50, 0) + Offset(40.0 * i, 0), timeStamp: t);
      await b.moveTo(c + const Offset(50, 0) + Offset(40.0 * i, 0), timeStamp: t);
    }
    await a.up();
    await b.up();
    final released = s.offset as Offset;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    expect((s.offset as Offset).dx, greaterThan(released.dx + 5), reason: 'keeps moving after the fingers left');
    await tester.pump(const Duration(seconds: 3));
    final stopped = s.offset as Offset;
    await tester.pump(const Duration(milliseconds: 200));
    expect(s.offset, stopped, reason: 'and comes to rest');
    await closeEditor(tester);
  });

  testWidgets('A4 page: zoomed in 2x the pen writes half as wide; resizing keeps the zoom', (tester) async {
    final s = await openEditor(tester, endless: false);
    expect(s.zoom, closeTo(1, 1e-9));
    await pinch(tester, 100, 200);
    expect(s.zoom, closeTo(2, 0.02));
    await tester.dragFrom(canvasCenter(tester), const Offset(150, 0));
    await tester.pump();
    expect(s.page.strokes.single.size, closeTo(2 / 2, 0.02), reason: 'ballpoint middle size 2, halved');

    final scale = s.scale as double;
    await tester.binding.setSurfaceSize(const Size(900, 1000)); // window resized / phone rotated
    await tester.pump();
    await tester.pump();
    expect(s.scale, scale, reason: 'the view is not reset when the window changes size');
    await closeEditor(tester);
  });
}
