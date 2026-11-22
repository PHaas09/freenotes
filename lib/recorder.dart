import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import 'src/rust/api/record.dart' as rust;

/// Records the screen into an MP4 file, with or without sound from the microphone.
/// Windows: the app's own picture (everything inside [area]) 15 times a second, encoded by Windows'
/// Media Foundation through the Rust core. Android and iPhone: the system's screen recorder, which asks
/// for permission each time. Linux: not available yet.
class ScreenRecorder {
  ScreenRecorder._();
  static final instance = ScreenRecorder._();

  /// Wraps the whole app (main.dart): on Windows this is what gets recorded.
  static final area = GlobalKey();
  static bool get supported => Platform.isWindows || Platform.isAndroid || Platform.isIOS;
  static const _channel = MethodChannel('freenotes/recorder');

  /// While recording: when it started.
  final active = ValueNotifier<DateTime?>(null);

  /// Notebook the running recording belongs to.
  String? owner;
  void Function(int ms)? _onSaved;
  int? _rec;
  Timer? _timer;
  Future<void>? _frameDone;
  final _clock = Stopwatch();

  /// Starts recording into [path]; [onSaved] gets the length once the file is finished.
  Future<void> start(String path, {required bool audio, required String owner, required void Function(int ms) onSaved}) async {
    if (active.value != null) throw StateError('Es läuft schon eine Aufnahme.');
    if (Platform.isWindows) {
      final ctx = area.currentContext!;
      final box = ctx.findRenderObject()! as RenderRepaintBoundary;
      // pixels per logical pixel: the screen's sharpness, but at most 1920 pixels wide
      final k = math.min(View.of(ctx).devicePixelRatio, 1920 / box.size.width);
      _rec = await rust.recStart(
          path: path, width: (box.size.width * k).round(), height: (box.size.height * k).round(), fps: 15, audio: audio);
      _clock
        ..reset()
        ..start();
      _timer = Timer.periodic(const Duration(milliseconds: 66), (_) => _frameDone ??= _frame(box, k).whenComplete(() => _frameDone = null));
    } else {
      await _channel.invokeMethod<void>('start', {'path': path, 'audio': audio});
    }
    this.owner = owner;
    _onSaved = onSaved;
    active.value = DateTime.now();
  }

  Future<void> _frame(RenderRepaintBoundary box, double k) async {
    try {
      final img = await box.toImage(pixelRatio: k);
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final (w, h) = (img.width, img.height);
      img.dispose();
      final rec = _rec;
      if (data != null && rec != null) {
        await rust.recFrame(rec: rec, rgba: data.buffer.asUint8List(), width: w, height: h, ms: _clock.elapsedMilliseconds);
      }
    } catch (_) {
      // a skipped frame is not worth stopping the recording for
    }
  }

  /// Stops and finishes the file; returns its length in milliseconds.
  Future<int> stop() async {
    final onSaved = _onSaved;
    try {
      final int ms;
      if (Platform.isWindows) {
        _timer?.cancel();
        await _frameDone;
        final rec = _rec!;
        _rec = null;
        ms = await rust.recStop(rec: rec);
      } else {
        ms = await _channel.invokeMethod<int>('stop') ?? 0;
      }
      onSaved?.call(ms);
      return ms;
    } finally {
      _onSaved = null;
      owner = null;
      active.value = null;
    }
  }
}

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Red "● 1:23 ■" chip shown while recording; tapping it stops.
class RecordingChip extends StatefulWidget {
  const RecordingChip({super.key, required this.since, required this.onStop});
  final DateTime since;
  final VoidCallback onStop;
  @override
  State<RecordingChip> createState() => _RecordingChipState();
}

class _RecordingChipState extends State<RecordingChip> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ActionChip(
          avatar: const Icon(Icons.stop, color: Colors.white, size: 18),
          label: Text(formatDuration(DateTime.now().difference(widget.since).inMilliseconds),
              style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
          backgroundColor: const Color(0xFFD32F2F),
          side: BorderSide.none,
          tooltip: 'Aufnahme beenden',
          onPressed: widget.onStop,
        ),
      );
}

/// Plays a recording inside the app (on Linux the system's video player opens instead).
class RecordingPlayer extends StatefulWidget {
  const RecordingPlayer({super.key, required this.file, required this.title});
  final File file;
  final String title;
  @override
  State<RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<RecordingPlayer> {
  late final c = VideoPlayerController.file(widget.file);
  String? error;

  @override
  void initState() {
    super.initState();
    c.addListener(() {
      if (mounted) setState(() {});
    });
    c.initialize().then((_) => c.play(), onError: (Object e) {
      if (mounted) setState(() => error = '$e');
    });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = c.value;
    const white = TextStyle(color: Colors.white);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(
            child: Center(
                child: error != null
                    ? Text('Abspielen nicht möglich: $error', style: white)
                    : v.isInitialized
                        ? AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(c))
                        : const CircularProgressIndicator())),
        if (v.isInitialized) ...[
          VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.all(12)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                color: Colors.white,
                iconSize: 40,
                tooltip: v.isPlaying ? 'Pause' : 'Abspielen',
                onPressed: () => v.isPlaying ? c.pause() : c.play()),
            Text('${formatDuration(v.position.inMilliseconds)} / ${formatDuration(v.duration.inMilliseconds)}', style: white),
          ]),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }
}
