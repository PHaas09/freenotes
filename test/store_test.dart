import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');
  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(root, 'docs');
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('freenotes_test');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('moving the storage folder keeps every notebook and removes the old copy', () async {
    final s = await Store.open();
    final old = s.dir.path;
    final m = await s.createNotebook('Mathe');
    final target = await s.moveTo(p.join(tmp.path, 'G'));

    expect(target, p.join(tmp.path, 'G', 'FreeNotes'));
    expect(Directory(old).existsSync(), isFalse);
    final reopened = await Store.open();
    expect(reopened.dir.path, target);
    expect(reopened.notebooks.single.name, 'Mathe');
    expect(File(p.join(target, 'notebooks', '${m.id}.json')).existsSync(), isTrue);
  });

  test('existing data in the target is used and the old folder is kept', () async {
    final a = await Store.open();
    await a.createNotebook('Alt');
    final target = p.join(tmp.path, 'G', 'FreeNotes');
    final other = Store(Directory(target));
    await Directory(p.join(target, 'notebooks')).create(recursive: true);
    other.lib.notebooks.clear();
    await other.saveLibrary();

    await a.moveTo(target);
    expect(Directory(a.dir.path).existsSync(), isTrue, reason: 'old notes must not be deleted');
    expect((await Store.open()).notebooks, isEmpty, reason: 'target data is used, not overwritten');
  });

  test('a missing storage drive is reported, not replaced by an empty folder', () async {
    final s = await Store.open();
    final target = await s.moveTo(p.join(tmp.path, 'G'));
    await Directory(target).delete(recursive: true);
    expect(Store.open(), throwsA(isA<StorageMissing>()));
  });
}
