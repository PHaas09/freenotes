import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model.dart';
import 'store.dart';

enum SyncAction { none, upload, download, conflict }

/// What to do with one notebook, given its version (updatedAt) here, on the NAS,
/// and at the last sync. Changed on both sides since then = conflict.
SyncAction decide(int? local, int? remote, int? base) {
  if (local == remote) return SyncAction.none;
  if (remote == null) return SyncAction.upload;
  if (local == null) return SyncAction.download;
  final localChanged = local != base, remoteChanged = remote != base;
  if (localChanged && remoteChanged) return SyncAction.conflict;
  return localChanged ? SyncAction.upload : SyncAction.download;
}

/// NAS connection settings. Only ever stored on this device, never in the code.
class NasConfig {
  String url = '', user = '', password = '';
  bool selfSigned = false; // accept the NAS's own (self-signed) HTTPS certificate
  bool get enabled => url.trim().isNotEmpty;
}

/// Minimal WebDAV client: GET, PUT, DELETE and MKCOL are all the sync needs.
class NasClient {
  NasClient(NasConfig cfg)
      : _base = Uri.parse(cfg.url.trim().endsWith('/') ? cfg.url.trim() : '${cfg.url.trim()}/'),
        _auth = 'Basic ${base64.encode(utf8.encode('${cfg.user}:${cfg.password}'))}' {
    final hc = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (cfg.selfSigned) hc.badCertificateCallback = (cert, host, port) => host == _base.host;
    _c = IOClient(hc);
  }
  final Uri _base;
  final String _auth;
  late final http.Client _c;

  Future<http.Response> _send(String method, String rel, [List<int>? body, Map<String, String>? headers]) async {
    final req = http.Request(method, _base.resolve(rel))..headers['Authorization'] = _auth;
    if (headers != null) req.headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    return http.Response.fromStream(await _c.send(req).timeout(const Duration(seconds: 60)));
  }

  /// Throws a readable error naming the step that failed, e.g. "NAS-Fehler 405 bei PUT library.json".
  void _check(http.Response r, String method, String rel) {
    final at = 'bei $method ${rel.isEmpty ? '/' : rel}';
    final c = r.statusCode;
    if (c == 401 || c == 403) throw 'Benutzername oder Passwort falsch oder keine Schreibrechte ($c $at)';
    if (c == 409) throw 'Ein Ordner in der NAS-Adresse existiert nicht ($c $at)';
    if (c == 405 && method != 'GET') {
      throw 'Die NAS erlaubt hier kein Schreiben ($c $at). Stimmt der Name der Freigabe in der Adresse?';
    }
    if (c >= 300) throw 'NAS-Fehler $c $at';
  }

  Future<List<int>?> get(String rel) async {
    final r = await _send('GET', rel);
    if (r.statusCode == 404) return null;
    _check(r, 'GET', rel);
    return r.bodyBytes;
  }

  Future<void> put(String rel, List<int> body) async => _check(await _send('PUT', rel, body), 'PUT', rel);
  Future<void> delete(String rel) async {
    final r = await _send('DELETE', rel);
    if (r.statusCode != 404) _check(r, 'DELETE', rel);
  }

  Future<void> mkcol(String rel) async {
    final r = await _send('MKCOL', rel);
    if (r.statusCode != 405 && r.statusCode != 301) _check(r, 'MKCOL', rel); // 405 = already exists
  }

  /// Names of the subfolders of [rel] (WebDAV PROPFIND, one level deep).
  Future<List<String>> listFolders(String rel) async {
    const body = '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
    final r = await _send('PROPFIND', rel, utf8.encode(body), {'Depth': '1', 'Content-Type': 'application/xml'});
    if (r.statusCode != 207) _check(r, 'PROPFIND', rel);
    return parseFolders(utf8.decode(r.bodyBytes), _base.resolve(rel).path);
  }

  void close() => _c.close();
}

/// Folder names from a PROPFIND reply, without the folder [selfPath] itself.
List<String> parseFolders(String xml, String selfPath) {
  final self = Uri.decodeFull(selfPath).replaceAll(RegExp(r'/+$'), '');
  final names = <String>[];
  for (final m in RegExp(r'<(?:\w+:)?response\b.*?</(?:\w+:)?response>', dotAll: true).allMatches(xml)) {
    final block = m[0]!;
    final href = RegExp(r'<(?:\w+:)?href>([^<]*)<').firstMatch(block)?[1]?.trim();
    if (href == null || !RegExp(r'<(?:\w+:)?collection\s*/?>').hasMatch(block)) continue;
    final path = Uri.decodeFull(Uri.parse(href).path).replaceAll(RegExp(r'/+$'), '');
    if (path == self || path.isEmpty) continue;
    names.add(path.split('/').last);
  }
  return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

class SyncService {
  SyncService(this.store);
  final Store store;
  final cfg = NasConfig();
  final status = ValueNotifier<String>('');
  final busy = ValueNotifier<bool>(false);
  final ok = ValueNotifier<bool?>(null); // null = not set up / not run yet
  String? openId; // notebook open in the editor: never overwritten from the NAS while open
  static const _secure = FlutterSecureStorage();

  Future<File> _settingsFile() async => File(p.join((await getApplicationSupportDirectory()).path, 'nas.json'));

  Future<void> load() async {
    try {
      final f = await _settingsFile();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        cfg.url = j['url'] as String? ?? '';
        cfg.user = j['user'] as String? ?? '';
        cfg.selfSigned = j['selfSigned'] == true;
      }
      cfg.password = await _secure.read(key: 'nas_password') ?? '';
    } catch (e) {
      status.value = 'NAS-Einstellungen konnten nicht geladen werden: $e';
    }
    Timer.periodic(const Duration(minutes: 2), (_) => run());
  }

  Future<void> saveConfig() async {
    final f = await _settingsFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'url': cfg.url.trim(), 'user': cfg.user, 'selfSigned': cfg.selfSigned}));
    await _secure.write(key: 'nas_password', value: cfg.password);
  }

  /// Checks that the folder can be read AND written (writes and deletes a small test file).
  Future<String> test() async {
    final nas = NasClient(cfg);
    try {
      await nas.mkcol('');
      await nas.get('library.json');
      await nas.put('.freenotes-test', utf8.encode('ok'));
      await nas.delete('.freenotes-test');
      return 'Verbindung OK';
    } catch (e) {
      return 'Fehler: $e';
    } finally {
      nas.close();
    }
  }

  Future<void> run() async {
    if (!cfg.enabled || busy.value) return;
    busy.value = true;
    status.value = 'Synchronisiere…';
    final nas = NasClient(cfg);
    try {
      await _sync(nas);
      final t = DateTime.now();
      status.value = 'Mit NAS synchronisiert um ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
      ok.value = true;
    } catch (e) {
      status.value = 'NAS nicht erreichbar: $e';
      ok.value = false;
    } finally {
      nas.close();
      busy.value = false;
    }
  }

  Future<void> _sync(NasClient nas) async {
    final s = store;
    await s.flush();
    await nas.mkcol('');
    await nas.mkcol('notebooks/');
    await nas.mkcol('assets/');
    final raw = await nas.get('library.json');
    final remote = raw == null ? Library([], []) : Library.fromJson(jsonDecode(utf8.decode(raw)));
    final remoteAssets = remote.assets.where(validAsset.hasMatch).toSet();

    // Folders: the newer version of each wins.
    final folders = {for (final f in remote.folders) if (validId.hasMatch(f.id)) f.id: f};
    for (final f in s.lib.folders) {
      final r = folders[f.id];
      if (r == null || f.updatedAt >= r.updatedAt) folders[f.id] = f;
    }
    s.lib.folders = folders.values.toList();

    final local = {for (final n in s.lib.notebooks) n.id: n};
    final rem = {for (final n in remote.notebooks) if (validId.hasMatch(n.id)) n.id: n};
    final out = <String, NotebookMeta>{}; // the notebook list the NAS will have afterwards
    for (final id in {...local.keys, ...rem.keys}) {
      final l = local[id], r = rem[id];
      var a = decide(l?.updatedAt, r?.updatedAt, s.syncBase[id]);
      if (a == SyncAction.conflict && r!.deleted) a = SyncAction.upload; // deleted there, edited here: keep it
      if (a == SyncAction.conflict && l!.deleted) a = SyncAction.download; // deleted here, edited there: restore
      if (id == openId && (a == SyncAction.download || a == SyncAction.conflict)) {
        out[id] = r!; // decide again once the notebook is closed
        continue;
      }
      switch (a) {
        case SyncAction.none:
          out[id] = (r ?? l)!;
        case SyncAction.upload:
          out[id] = await _upload(nas, l!, remoteAssets);
        case SyncAction.download:
          await _download(nas, r!);
          out[id] = r;
        case SyncAction.conflict:
          // Both sides changed: keep the NAS version as a copy, so nothing is lost.
          final copy = NotebookMeta(id: newId(), name: '${r!.name} (Konflikt)', folder: r.folder, cover: r.cover, search: r.search);
          await _download(nas, r, saveAs: copy);
          out[id] = await _upload(nas, l!, remoteAssets);
      }
      s.syncBase[id] = out[id]!.updatedAt;
    }

    await nas.put('library.json', utf8.encode(jsonEncode(Library(s.lib.folders, out.values.toList(), remoteAssets))));
    await s.saveLibrary();
    await s.saveSyncBase();
    s.refresh();
  }

  /// Uploads one notebook and its attachments. Returns the meta as it was when uploaded.
  Future<NotebookMeta> _upload(NasClient nas, NotebookMeta l, Set<String> remoteAssets) async {
    await store.flush(); // the file on disk must match the meta we snapshot next
    final snap = NotebookMeta.fromJson(l.toJson());
    if (snap.deleted) {
      await nas.delete('notebooks/${l.id}.json');
      return snap;
    }
    final bytes = await store.notebookFile(l.id).readAsBytes();
    for (final a in Notebook.fromJson(jsonDecode(utf8.decode(bytes))).assets()) {
      final f = File(store.assetPath(a));
      if (remoteAssets.contains(a) || !validAsset.hasMatch(a) || !await f.exists()) continue;
      await nas.put('assets/$a', await f.readAsBytes());
      remoteAssets.add(a);
    }
    await nas.put('notebooks/${l.id}.json', bytes);
    return snap;
  }

  Future<void> _download(NasClient nas, NotebookMeta r, {NotebookMeta? saveAs}) async {
    final s = store;
    if (r.deleted) {
      final f = s.notebookFile(r.id);
      if (await f.exists()) await f.delete();
    } else {
      final bytes = await nas.get('notebooks/${r.id}.json') ?? (throw 'Notizbuch "${r.name}" fehlt auf der NAS');
      final nb = Notebook.fromJson(jsonDecode(utf8.decode(bytes))); // also validates the file
      for (final a in nb.assets()) {
        if (!validAsset.hasMatch(a) || await File(s.assetPath(a)).exists()) continue;
        final data = await nas.get('assets/$a');
        if (data != null) await s.writeAtomic(File(s.assetPath(a)), data);
      }
      final id = saveAs?.id ?? r.id;
      await s.writeAtomic(s.notebookFile(id), utf8.encode(jsonEncode(Notebook(id, nb.pages))));
    }
    if (saveAs != null) {
      s.lib.notebooks.add(saveAs);
    } else {
      s.lib.notebooks.removeWhere((n) => n.id == r.id);
      s.lib.notebooks.add(r);
    }
  }
}
