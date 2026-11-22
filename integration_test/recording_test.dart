// The Windows app records itself into an MP4. Run: flutter test integration_test/recording_test.dart -d windows
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/recorder.dart';
import 'package:freenotes/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app picture is recorded into an MP4 file', (tester) async {
    await RustLib.init();
    var n = 0;
    late StateSetter redraw;
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => RepaintBoundary(key: ScreenRecorder.area, child: child),
        home: Scaffold(body: Center(child: StatefulBuilder(builder: (context, set) {
          redraw = set;
          return Text('FreeNotes Aufnahme $n', style: const TextStyle(fontSize: 40));
        })))));
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}freenotes_it_$pid.mp4';
    int? saved;
    await ScreenRecorder.instance.start(path, audio: false, owner: 'test', onSaved: (ms) => saved = ms);
    expect(ScreenRecorder.instance.active.value, isNotNull);
    for (var i = 0; i < 40; i++) {
      redraw(() => n++); // something changes on screen
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final ms = await ScreenRecorder.instance.stop();
    expect(saved, ms);
    expect(ms, greaterThan(1000));
    final size = File(path).lengthSync();
    File(path).deleteSync();
    expect(size, greaterThan(5000), reason: 'an MP4 with video frames');
    expect(ScreenRecorder.instance.active.value, isNull);
  }, skip: !Platform.isWindows);
}
