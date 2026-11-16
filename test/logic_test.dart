import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:freenotes/ink.dart';
import 'package:freenotes/model.dart';
import 'package:freenotes/sync.dart';

void main() {
  test('sync decision', () {
    expect(decide(5, 5, 1), SyncAction.none);
    expect(decide(5, null, null), SyncAction.upload); // new here
    expect(decide(null, 5, null), SyncAction.download); // new on the NAS
    expect(decide(7, 5, 5), SyncAction.upload); // changed here only
    expect(decide(5, 7, 5), SyncAction.download); // changed on the NAS only
    expect(decide(7, 8, 5), SyncAction.conflict); // changed on both
    expect(decide(7, 8, null), SyncAction.conflict); // never synced, differs on both
  });

  test('eraser hit test', () {
    final line = Stroke(type: 'ballpoint', color: 0, size: 4, pts: [0, 0, .5, 100, 0, .5]);
    expect(hitStroke(line, const Offset(50, 5), 5), isTrue);
    expect(hitStroke(line, const Offset(50, 30), 5), isFalse);
    expect(hitStroke(line, const Offset(105, 0), 5), isTrue);
    expect(hitStroke(line, const Offset(120, 0), 5), isFalse);
    final dot = Stroke(type: 'ballpoint', color: 0, size: 4, pts: [10, 10, .5]);
    expect(hitStroke(dot, const Offset(12, 12), 2), isTrue);
    expect(hitStroke(dot, const Offset(30, 30), 2), isFalse);
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
    expect(p.strokes.single.pts, [1.2, 2.3, .46]);
    expect(p.strokes.single.sim, isTrue);
    expect(p.texts.single.text, 'Hallo');
    expect(p.images.single.rect, const Rect.fromLTWH(1, 2, 3, 4));
    expect(back.assets(), {'abcd1234.png'});
    expect(back.searchText(), 'hallo');
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
