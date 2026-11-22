import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A saved pen: type, colour and width, one tap away in the toolbar.
class PenPreset {
  const PenPreset(this.type, this.color, this.size);
  final String type;
  final int color;
  final double size;
  Map<String, dynamic> toJson() => {'t': type, 'c': color, 's': size};
  factory PenPreset.fromJson(Map<String, dynamic> j) => PenPreset(j['t'] as String, j['c'] as int, (j['s'] as num).toDouble());
  @override
  bool operator ==(Object other) => other is PenPreset && other.type == type && other.color == color && other.size == size;
  @override
  int get hashCode => Object.hash(type, color, size);
}

/// Settings of this device only (not synced to the NAS): pen favourites, scan sharpening.
class Prefs {
  Prefs._();
  static final instance = Prefs._();
  final favorites = <PenPreset>[];
  bool sharpenScans = true; // clearer text in scanned PDFs when zooming in
  File? _file;

  Future<void> load() async {
    try {
      _file = File(p.join((await getApplicationSupportDirectory()).path, 'prefs.json'));
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        favorites
          ..clear()
          ..addAll([for (final f in j['favorites'] as List? ?? const []) PenPreset.fromJson(f as Map<String, dynamic>)]);
        sharpenScans = j['sharpenScans'] as bool? ?? true;
      }
    } catch (_) {
      // unreadable settings: start with none, the notes themselves are not affected
    }
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'favorites': favorites, 'sharpenScans': sharpenScans}));
  }
}
