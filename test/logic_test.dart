import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/ink.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/scene.dart';
import 'package:freenotes/sync.dart';

import 'rust_init.dart';

void main() {
  setUpAll(initRust);

  test('sync decision', () {
    expect(decide(5, 5, 1), SyncAction.none);
    expect(decide(5, null, null), SyncAction.upload); // new here
    expect(decide(null, 5, null), SyncAction.download); // new on the NAS
    expect(decide(7, 5, 5), SyncAction.upload); // changed here only
    expect(decide(5, 7, 5), SyncAction.download); // changed on the NAS only
    expect(decide(7, 8, 5), SyncAction.conflict); // changed on both
    expect(decide(7, 8, null), SyncAction.conflict); // never synced, differs on both
  });

  test('eraser, precise eraser and lasso find strokes through the Rust core', () async {
    final line = Stroke(type: 'ballpoint', color: 0, size: 4, pts: [0, 0, .5, 100, 0, .5]);
    final dot = Stroke(type: 'ballpoint', color: 0, size: 4, pts: [10, 10, .5]);
    final scene = PageScene();
    await scene.load([line, dot]);
    expect(scene.hit(50, 5, 5), [line]);
    expect(scene.hit(50, 30, 5), isEmpty);
    expect(scene.hit(105, 0, 5), [line], reason: 'just past the end: radius + half the width');
    expect(scene.hit(120, 0, 5), isEmpty);
    expect(scene.hit(12, 12, 2), contains(dot));
    // lasso around the line only
    expect(scene.lasso([-5, -5, 110, -5, 110, 5, -5, 5]), [line]);
    // precise eraser cuts the line in two
    final cuts = scene.erasePartial(50, 0, 5);
    expect(cuts.single.$1, line);
    expect(cuts.single.$2.length, 2);
    // after removing it from the page list, the scene no longer finds it
    scene.sync([dot]);
    expect(scene.hit(50, 0, 5), isEmpty);
    scene.dispose();
  });

  test('pen outlines come from the Rust core: the new pens draw, shapes snap', () {
    for (final type in penKinds) {
      final s = Stroke(type: type, color: 0xFF000000, size: 4, pts: [for (var i = 0; i < 20; i++) ...[i * 5.0, (i % 3) * 2.0, 0.5]]);
      expect(strokePath(s).getBounds().width, greaterThan(80), reason: '\$type draws');
    }
    final wobbly = [for (var i = 0; i < 50; i++) ...[i * 4.0, 100 + (i % 2) * 1.5, 0.5]];
    final line = recognizeShape(wobbly, 2)!;
    expect({for (var i = 1; i < line.length; i += 3) line[i]}.length, 1, reason: 'snapped to one straight horizontal line');
  });

  test('notebook survives a save/load round trip', () {
    final nb = Notebook('abcd1234', [
      NotePage(paper: 'grid', strokes: [Stroke(type: 'fountain', color: 0xFF000000, size: 2, pts: [1.234, 2.345, .456], sim: true)],
          texts: const [TextBox(id: 't1xx', x: 1, y: 2, text: 'Hallo')],
          images: const [ImageBox(id: 'i1xx', asset: 'abcd1234.png', rect: Rect.fromLTWH(1, 2, 3, 4))]),
    ]);
    final back = Notebook.fromJson(jsonDecode(jsonEncode(nb)));
    final p = back.pages.single;
    expect(p.paper, 'grid');
    expect(p.infinite, isFalse);
    expect(p.strokes.single.pts, [closeTo(1.2, 1e-6), closeTo(2.3, 1e-6), closeTo(.46, 1e-6)]);
    expect(p.strokes.single.sim, isTrue);
    expect(p.texts.single.text, 'Hallo');
    expect(p.images.single.rect, const Rect.fromLTWH(1, 2, 3, 4));
    expect(back.assets(), {'abcd1234.png'});
    expect(back.searchText(), 'hallo');
  });

  test('a fine stroke drawn while zoomed in keeps its detail when saved', () {
    // zoomed in 100x: pen width 2 becomes 0.02 page units
    final fine = Stroke(type: 'ballpoint', color: 0, size: 0.02, pts: [100.1234, 50.5678, .5]);
    final page = NotePage(infinite: true, strokes: [fine]);
    final back = NotePage.fromJson(jsonDecode(jsonEncode(page)));
    expect(back.infinite, isTrue);
    expect(back.strokes.single.pts[0], closeTo(100.123, 0.002));
    expect(back.strokes.single.pts[1], closeTo(50.568, 0.002));
  });

  test('new compact file format: round trip, conflict copy with a new id', () async {
    final nb = Notebook('abcd1234', [
      NotePage(infinite: true, strokes: [Stroke(type: 'calligraphy', color: 0xFF112233, size: 3, pts: [1, 2, .5, 3, 4, 1])]),
      NotePage(texts: const [TextBox(id: 't1xx', x: 1, y: 2, text: 'Hallo')],
          images: const [ImageBox(id: 'i1xx', asset: 'abcd1234.png', rect: Rect.fromLTWH(1, 2, 3, 4))]),
    ]);
    final bytes = await encodeNotebook(nb);
    expect(String.fromCharCodes(bytes.take(4)), 'FNB2');
    final back = await decodeNotebook(bytes);
    final s = back.pages[0].strokes.single;
    expect((s.type, s.color, s.size), ('calligraphy', 0xFF112233, 3.0));
    expect(s.pts, [closeTo(1, 1e-3), closeTo(2, 1e-3), closeTo(.5, 0.01), closeTo(3, 1e-3), closeTo(4, 1e-3), closeTo(1, 0.01)]);
    expect(back.pages[0].infinite, isTrue);
    expect(back.pages[1].texts.single.text, 'Hallo');
    final (assets, copy) = await checkNotebookFile(bytes, 'zzzz9999');
    expect(assets, {'abcd1234.png'});
    expect((await decodeNotebook(copy)).id, 'zzzz9999');
    await expectLater(decodeNotebook([..._magic, 255, 255, 255, 255]), throwsFormatException);
  });

  test('screen recordings are kept with the notebook and synced as attachments', () async {
    const rec = Recording(asset: 'abcd5678.mp4', created: 1700000000000, ms: 61500, audio: true);
    final nb = Notebook('abcd1234', [NotePage()], recordings: [rec]);
    expect(nb.assets(), {'abcd5678.mp4'});
    final back = await decodeNotebook(await encodeNotebook(nb));
    expect(back.recordings.single.toJson(), rec.toJson());
    final (assets, copy) = await checkNotebookFile(await encodeNotebook(nb), 'zzzz9999');
    expect(assets, {'abcd5678.mp4'}, reason: 'the NAS sync uploads and downloads the video');
    expect((await decodeNotebook(copy)).recordings, hasLength(1), reason: 'a conflict copy keeps them');
    final old = Notebook.fromJson(jsonDecode(jsonEncode(nb)));
    expect(old.recordings.single.audio, isTrue);
    expect(validAsset.hasMatch(rec.asset), isTrue);
  });

  test('notebooks saved by FreeNotes 1.x (JSON) still open', () async {
    final old = utf8.encode(jsonEncode(Notebook('abcd1234', [NotePage(strokes: [Stroke(type: 'fountain', color: 1, size: 2, pts: [1, 2, .5])])])));
    final back = await decodeNotebook(old);
    expect(back.pages.single.strokes.single.type, 'fountain');
    final (_, bytes) = await checkNotebookFile(old, 'zzzz9999');
    expect((await decodeNotebook(bytes)).id, 'zzzz9999');
  });

  test('NAS certificate: remembered on first contact, then only exactly that one is accepted', () {
    final cfg = NasConfig()..trustNew = true;
    expect(trustCertificate(cfg, '10.1.2.3', 'evil.example', [1, 2, 3]), isFalse, reason: 'other hosts never');
    expect(trustCertificate(cfg, '10.1.2.3', '10.1.2.3', [1, 2, 3]), isTrue, reason: 'first contact in the assistant');
    cfg.trustNew = false;
    expect(trustCertificate(cfg, '10.1.2.3', '10.1.2.3', [1, 2, 3]), isTrue, reason: 'same certificate again');
    expect(trustCertificate(cfg, '10.1.2.3', '10.1.2.3', [9, 9, 9]), isFalse, reason: 'a different certificate is refused');
    expect(trustCertificate(NasConfig(), '10.1.2.3', '10.1.2.3', [1]), isFalse, reason: 'nothing remembered, not allowed');
  });

  test('ids and asset names from the NAS are checked', () {
    expect(validAsset.hasMatch('abcd1234.pdf'), isTrue);
    expect(validAsset.hasMatch('../../evil.pdf'), isFalse);
    expect(validId.hasMatch('../x'), isFalse);
  });

  test('NAS folder list is read from a WebDAV reply', () {
    const xml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/personal_folder/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/Meine%20Fotos/</D:href><D:propstat><D:prop><D:resourcetype><D:collection /></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/notiz.txt</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
</D:multistatus>''';
    expect(parseFolders(xml, '/'), ['Meine Fotos', 'personal_folder']);
    expect(parseFolders(xml.replaceAll('D:', 'd:'), '/'), ['Meine Fotos', 'personal_folder']);
  });
}

const _magic = [0x46, 0x4E, 0x42, 0x32];
