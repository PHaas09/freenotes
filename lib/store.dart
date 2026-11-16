import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model.dart';

/// Thrown at start when the chosen storage folder (e.g. on drive G:) is not reachable.
class StorageMissing implements Exception {
  StorageMissing(this.path);
  final String path;
}

/// Local storage, by default in Documents/FreeNotes (the folder can be changed in the settings):
///   library.json          folders + notebook list
///   notebooks/ID.json     pages of one notebook
///   assets/NAME           imported PDFs and images
class Store extends ChangeNotifier {
  Store(this.dir);
  final Directory dir;
  Library lib = Library([], []);
  Map<String, int> syncBase = {}; // notebook/folder id -> updatedAt at the last successful NAS sync
  String? saveError;

  final _dirty = <String, Notebook>{};
  Timer? _timer;
  Future<void> _queue = Future.value();

  /// Small file in the app's settings folder that remembers a custom storage folder.
  static Future<File> _locationFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'location.json'));

  static Future<Store> open() async {
    final loc = await _locationFile();
    String path;
    if (await loc.exists()) {
      path = (jsonDecode(await loc.readAsString()) as Map<String, dynamic>)['path'] as String;
      // Never silently fall back to another folder: a missing drive must not look like "no notes".
      if (!await Directory(path).exists()) throw StorageMissing(path);
    } else {
      path = p.join((await getApplicationDocumentsDirectory()).path, 'FreeNotes');
    }
    final s = Store(Directory(path));
    await Directory(p.join(s.dir.path, 'notebooks')).create(recursive: true);
    await Directory(p.join(s.dir.path, 'assets')).create(recursive: true);
    final lib = s.file('library.json'), base = s.file('sync_state.json');
    if (await lib.exists()) s.lib = Library.fromJson(jsonDecode(await lib.readAsString()));
    if (await base.exists()) s.syncBase = Map<String, int>.from(jsonDecode(await base.readAsString()));
    return s;
  }

  File file(String rel) => File(p.join(dir.path, rel));
  File notebookFile(String id) => file('notebooks/$id.json');
  String assetPath(String name) => p.join(dir.path, 'assets', name);
  NotebookMeta meta(String id) => lib.notebooks.firstWhere((n) => n.id == id);
  List<Folder> get folders => lib.folders.where((f) => !f.deleted).toList();
  List<NotebookMeta> get notebooks => lib.notebooks.where((n) => !n.deleted).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Runs file writes one after another, so two saves never race on the same file.
  Future<T> serial<T>(Future<T> Function() fn) {
    final r = _queue.then((_) => fn());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  /// Write to a temp file first, then swap it in: a crash mid-write never leaves a half file.
  Future<void> writeAtomic(File f, List<int> bytes) => serial(() async {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
      });

  Future<Notebook> loadNotebook(String id) async {
    if (_dirty[id] != null) return _dirty[id]!;
    final f = notebookFile(id);
    if (!await f.exists()) return Notebook(id, [NotePage()]);
    return Notebook.fromJson(jsonDecode(await f.readAsString()));
  }

  /// Call after every edit. Saves to disk shortly after, batching quick edits.
  void changed(Notebook nb) {
    meta(nb.id)
      ..updatedAt = nowMs()
      ..search = nb.searchText();
    _dirty[nb.id] = nb;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final items = Map.of(_dirty);
    _dirty.clear();
    try {
      for (final nb in items.values) {
        await writeAtomic(notebookFile(nb.id), utf8.encode(jsonEncode(nb)));
      }
      await saveLibrary();
      saveError = null;
    } catch (e) {
      items.forEach((k, v) => _dirty.putIfAbsent(k, () => v)); // keep for the next try
      saveError = 'Speichern fehlgeschlagen: $e';
    }
    notifyListeners();
  }

  void refresh() => notifyListeners();

  Future<void> saveLibrary() => writeAtomic(file('library.json'), utf8.encode(jsonEncode(lib)));
  Future<void> saveSyncBase() => writeAtomic(file('sync_state.json'), utf8.encode(jsonEncode(syncBase)));

  Future<NotebookMeta> createNotebook(String name, {String? folder, int cover = 0xFF4F46E5, List<NotePage>? pages}) async {
    final m = NotebookMeta(id: newId(), name: name, folder: folder, cover: cover);
    final nb = Notebook(m.id, pages ?? [NotePage()]);
    await writeAtomic(notebookFile(m.id), utf8.encode(jsonEncode(nb)));
    lib.notebooks.add(m);
    await saveLibrary();
    notifyListeners();
    return m;
  }

  Future<void> updateMeta(NotebookMeta m, void Function(NotebookMeta) fn) async {
    fn(m);
    m.updatedAt = nowMs();
    await saveLibrary();
    notifyListeners();
  }

  Future<void> deleteNotebook(NotebookMeta m) async {
    await updateMeta(m, (m) => m.deleted = true);
    final f = notebookFile(m.id);
    if (await f.exists()) await f.delete();
  }

  Future<Folder> createFolder(String name) async {
    final f = Folder(id: newId(), name: name);
    lib.folders.add(f);
    await saveLibrary();
    notifyListeners();
    return f;
  }

  Future<void> updateFolder(Folder f, void Function(Folder) fn) async {
    fn(f);
    f.updatedAt = nowMs();
    if (f.deleted) {
      for (final n in lib.notebooks.where((n) => n.folder == f.id)) {
        n.folder = null;
        n.updatedAt = nowMs();
      }
    }
    await saveLibrary();
    notifyListeners();
  }

  /// Moves all notes into [picked] (a "FreeNotes" subfolder is used unless the folder is already
  /// called that) and remembers it as the storage folder. If the target already holds FreeNotes
  /// data, that data is used and the current folder is kept untouched, so nothing is overwritten.
  /// Returns the new folder. The app must restart afterwards.
  Future<String> moveTo(String picked) async {
    final target = p.normalize(p.basename(picked).toLowerCase() == 'freenotes' ? picked : p.join(picked, 'FreeNotes'));
    final from = p.normalize(dir.path);
    if (p.equals(target, from) || p.isWithin(from, target) || p.isWithin(target, from)) {
      throw 'Bitte einen Ordner außerhalb des jetzigen Speicherorts wählen.';
    }
    await flush();
    await Directory(target).create(recursive: true);
    final existing = await File(p.join(target, 'library.json')).exists();
    if (!existing) {
      await for (final e in dir.list(recursive: true)) {
        if (e is! File || e.path.endsWith('.tmp')) continue;
        final dst = File(p.join(target, p.relative(e.path, from: from)));
        await dst.parent.create(recursive: true);
        await e.copy(dst.path);
        if (await dst.length() != await e.length()) throw 'Kopieren fehlgeschlagen: ${e.path}';
      }
    }
    final loc = await _locationFile();
    await loc.parent.create(recursive: true);
    await loc.writeAsString(jsonEncode({'path': target}));
    if (!existing) await dir.delete(recursive: true); // only after every file was copied and checked
    return target;
  }

  /// Copies a picked file into the assets folder and returns its new name.
  Future<String> importAsset(String srcPath) async {
    final ext = p.extension(srcPath).toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final name = '${newId()}.${ext.isEmpty ? 'bin' : ext}';
    await File(srcPath).copy(assetPath(name));
    return name;
  }
}
