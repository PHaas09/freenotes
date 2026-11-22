import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'src/rust/api/codec.dart';

final _rnd = Random.secure();
String newId() =>
    DateTime.now().millisecondsSinceEpoch.toRadixString(36) + _rnd.nextInt(1 << 30).toRadixString(36);
int nowMs() => DateTime.now().millisecondsSinceEpoch;
double _d(Object? v) => (v as num).toDouble();

/// Ids and asset names come from files on the NAS too, so they are checked
/// before being used in a file path.
final validId = RegExp(r'^[a-z0-9]{4,40}$');
final validAsset = RegExp(r'^[a-z0-9]{4,40}\.[a-z0-9]{2,5}$');

/// Pen kinds, in the order of their numbers in the file format (never reorder; append new ones).
const penKinds = ['ballpoint', 'fountain', 'pencil', 'highlighter', 'brush', 'calligraphy', 'fineliner'];

int _nextStrokeId = 1;

/// One pen stroke. [pts] holds x, y, pressure triplets in page units.
/// Finished strokes keep their points in a Float32List (4 bytes per number): an endless sheet can hold
/// hundreds of thousands of strokes.
class Stroke {
  // ignore: prefer_initializing_formals (named parameters can't be private)
  Stroke({required this.type, required this.color, required this.size, required this.pts, this.sim = false, int? id, Rect? bounds})
      : _id = id, // ignore: prefer_initializing_formals
        _bounds = bounds; // ignore: prefer_initializing_formals
  final String type; // one of [penKinds]
  final int color;
  final double size;
  final List<double> pts;
  final bool sim; // no real pressure (mouse/finger): simulate it from speed
  final int? _id;
  final Rect? _bounds;

  /// Key of this stroke in the Rust core's copy of the page, and its drawing order there (higher = on top).
  /// Only valid while the app runs; given out on first use, so strokes made in other isolates get fresh ones.
  late final int id = _id ?? _nextStrokeId++;
  int get kind => max(0, penKinds.indexOf(type));

  /// Same stroke with changes. [keepId] keeps its place in the drawing order (recolour, move);
  /// otherwise it is a new stroke on top (copy, paste).
  Stroke copyWith({List<double>? pts, int? color, double? size, bool keepId = true}) => Stroke(
      type: type, color: color ?? this.color, size: size ?? this.size, sim: sim, pts: pts ?? this.pts, id: keepId ? id : null);

  /// Area the stroke covers, including its width. Computed once (loaded strokes get it from the Rust core).
  late final Rect bounds = _bounds ?? () {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (var i = 0; i + 2 < pts.length; i += 3) {
      if (pts[i] < l) l = pts[i];
      if (pts[i] > r) r = pts[i];
      if (pts[i + 1] < t) t = pts[i + 1];
      if (pts[i + 1] > b) b = pts[i + 1];
    }
    return pts.length < 3 ? Rect.zero : Rect.fromLTRB(l, t, r, b).inflate(size);
  }();

  Map<String, dynamic> toJson() {
    // Precision follows the stroke width: a line drawn while zoomed in far keeps its detail.
    final q = pow(10, (log(8 / size) / ln10).ceil().clamp(1, 6)).toDouble();
    return {
      't': type,
      'c': color,
      's': size,
      if (sim) 'sim': true,
      'p': [for (var i = 0; i < pts.length; i++) i % 3 == 2 ? (pts[i] * 100).round() / 100 : (pts[i] * q).round() / q],
    };
  }

  factory Stroke.fromJson(Map<String, dynamic> j) => Stroke(
      type: j['t'] as String,
      color: j['c'] as int,
      size: _d(j['s']),
      sim: j['sim'] == true,
      pts: Float32List.fromList([for (final v in j['p'] as List) _d(v)]));
}

/// Strokes as the parallel arrays the Rust core works with.
StrokeBatch strokeBatch(List<Stroke> strokes) {
  final n = strokes.length;
  var total = 0;
  for (final s in strokes) {
    total += s.pts.length;
  }
  final pts = Float32List(total), offsets = Uint32List(n + 1), ids = Uint32List(n), kinds = Uint8List(n);
  final colors = Uint32List(n), sizes = Float32List(n), sims = Uint8List(n), bounds = Float32List(n * 4);
  var o = 0;
  for (var i = 0; i < n; i++) {
    final s = strokes[i], b = s.bounds;
    pts.setRange(o, o + s.pts.length, s.pts);
    o += s.pts.length;
    offsets[i + 1] = o;
    ids[i] = s.id;
    kinds[i] = s.kind;
    colors[i] = s.color;
    sizes[i] = s.size;
    sims[i] = s.sim ? 1 : 0;
    bounds[i * 4] = b.left;
    bounds[i * 4 + 1] = b.top;
    bounds[i * 4 + 2] = b.right;
    bounds[i * 4 + 3] = b.bottom;
  }
  return StrokeBatch(ids: ids, kinds: kinds, colors: colors, sizes: sizes, sims: sims, offsets: offsets, points: pts, bounds: bounds);
}

/// Strokes from the Rust core's arrays; the points stay one shared array (no copying).
List<Stroke> strokesFromBatch(StrokeBatch b) => [
      for (var i = 0; i < b.kinds.length; i++)
        Stroke(
            type: penKinds[min(b.kinds[i], penKinds.length - 1)],
            color: b.colors[i],
            size: b.sizes[i],
            sim: b.sims[i] != 0,
            pts: Float32List.sublistView(b.points, b.offsets[i], b.offsets[i + 1]),
            bounds: b.bounds.length >= 4 * (i + 1)
                ? Rect.fromLTRB(b.bounds[4 * i], b.bounds[4 * i + 1], b.bounds[4 * i + 2], b.bounds[4 * i + 3])
                : null)
    ];

// Notebook file: "FNB2", u32 length + the notebook as JSON without strokes, then for every page
// u32 length + its strokes packed by the Rust core (about 10x smaller and much faster than JSON).
// Files from FreeNotes 1.x (plain JSON) are still read.
const _magic = [0x46, 0x4E, 0x42, 0x32];
bool _isV2(List<int> b) => b.length >= 8 && b[0] == _magic[0] && b[1] == _magic[1] && b[2] == _magic[2] && b[3] == _magic[3];

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// Splits a v2 file into its JSON part and the stroke blocks, checking every length (files come from the NAS too).
(List<int>, List<List<int>>) _splitV2(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  var i = 4;
  List<int> take() {
    if (i + 4 > data.length) throw const FormatException('Notizbuch-Datei ist abgeschnitten');
    final n = view.getUint32(i, Endian.little);
    i += 4;
    if (i + n > data.length) throw const FormatException('Notizbuch-Datei ist abgeschnitten');
    i += n;
    return Uint8List.sublistView(data, i - n, i);
  }

  final head = take(), blobs = <List<int>>[];
  while (i < data.length) {
    blobs.add(take());
  }
  return (head, blobs);
}

Future<List<int>> encodeNotebook(Notebook nb) async {
  final blobs = await Future.wait([for (final p in nb.pages) encodeStrokes(batch: strokeBatch(p.strokes))]);
  final head = utf8.encode(jsonEncode({
    'id': nb.id,
    'pages': [for (final p in nb.pages) p.toJson(withStrokes: false)],
    if (nb.recordings.isNotEmpty) 'recordings': nb.recordings,
  }));
  final out = BytesBuilder(copy: false)
    ..add(_magic)
    ..add(_u32(head.length))
    ..add(head);
  for (final b in blobs) {
    out
      ..add(_u32(b.length))
      ..add(b);
  }
  return out.takeBytes();
}

Future<Notebook> decodeNotebook(List<int> bytes) async {
  if (!_isV2(bytes)) return Isolate.run(() => Notebook.fromJson(jsonDecode(utf8.decode(bytes)))); // FreeNotes 1.x
  final (head, blobs) = _splitV2(bytes);
  final j = jsonDecode(utf8.decode(head)) as Map<String, dynamic>;
  final pages = j['pages'] as List;
  if (pages.length != blobs.length) throw const FormatException('Notizbuch-Datei ist beschädigt');
  final strokes = await Future.wait([for (final b in blobs) decodeStrokes(bytes: b)]);
  return Notebook(j['id'] as String, [
    for (var i = 0; i < pages.length; i++) NotePage.fromJson(pages[i] as Map<String, dynamic>, strokes: strokesFromBatch(strokes[i]))
  ], recordings: _recordings(j));
}

/// Checks a notebook file (e.g. from the NAS) and returns its attachments plus the bytes to store under [id].
Future<(Set<String>, List<int>)> checkNotebookFile(List<int> bytes, String id) async {
  if (!_isV2(bytes)) {
    return Isolate.run(() {
      final nb = Notebook.fromJson(jsonDecode(utf8.decode(bytes)));
      return (nb.assets(), nb.id == id ? bytes : utf8.encode(jsonEncode(Notebook(id, nb.pages, recordings: nb.recordings))));
    });
  }
  final (head, blobs) = _splitV2(bytes);
  final j = jsonDecode(utf8.decode(head)) as Map<String, dynamic>;
  final assets = <String>{
    for (final p in (j['pages'] as List).cast<Map<String, dynamic>>()) ...[
      if (p['pdf'] is String) p['pdf'] as String,
      for (final i in (p['images'] as List? ?? const [])) (i as Map<String, dynamic>)['a'] as String,
    ],
    for (final r in _recordings(j)) r.asset,
  };
  if (j['id'] == id) return (assets, bytes);
  final newHead = utf8.encode(jsonEncode({...j, 'id': id}));
  final out = BytesBuilder(copy: false)
    ..add(_magic)
    ..add(_u32(newHead.length))
    ..add(newHead);
  for (final b in blobs) {
    out
      ..add(_u32(b.length))
      ..add(b);
  }
  return (assets, out.takeBytes());
}

class TextBox {
  const TextBox({required this.id, required this.x, required this.y, required this.text,
      this.size = 16, this.color = 0xFF1A1A1A, this.width = 260});
  final String id, text;
  final double x, y, size, width;
  final int color;

  TextBox copyWith({double? x, double? y, String? text, double? size, int? color, double? width}) => TextBox(
      id: id, x: x ?? this.x, y: y ?? this.y, text: text ?? this.text,
      size: size ?? this.size, color: color ?? this.color, width: width ?? this.width);
  Map<String, dynamic> toJson() => {'id': id, 'x': x, 'y': y, 't': text, 's': size, 'c': color, 'w': width};
  factory TextBox.fromJson(Map<String, dynamic> j) => TextBox(id: j['id'] as String, x: _d(j['x']), y: _d(j['y']),
      text: j['t'] as String, size: _d(j['s']), color: j['c'] as int, width: _d(j['w']));
}

class ImageBox {
  const ImageBox({required this.id, required this.asset, required this.rect});
  final String id, asset;
  final Rect rect;
  Map<String, dynamic> toJson() => {'id': id, 'a': asset, 'r': [rect.left, rect.top, rect.width, rect.height]};
  factory ImageBox.fromJson(Map<String, dynamic> j) {
    final r = [for (final v in j['r'] as List) _d(v)];
    return ImageBox(id: j['id'] as String, asset: j['a'] as String, rect: Rect.fromLTWH(r[0], r[1], r[2], r[3]));
  }
}

/// A page. Its lists are replaced, never changed in place, so undo can keep old ones.
class NotePage {
  NotePage({String? id, this.paper = 'lined', this.w = 595, this.h = 842, this.pdf, this.pdfPage,
      this.infinite = false, this.strokes = const [], this.texts = const [], this.images = const []})
      : id = id ?? newId();
  final String id;
  String paper; // blank | lined | grid | dots
  final double w, h; // page units = PDF points (A4 = 595 x 842); not used by an endless sheet
  final bool infinite; // endless sheet: no edges, any zoom
  final String? pdf; // asset name of an imported PDF
  final int? pdfPage;
  List<Stroke> strokes;
  List<TextBox> texts;
  List<ImageBox> images;

  /// Same page with a new id (page overview: duplicate). Lists are shared; they are never changed in place.
  NotePage duplicate() => NotePage(paper: paper, w: w, h: h, pdf: pdf, pdfPage: pdfPage, infinite: infinite,
      strokes: strokes, texts: texts, images: images);

  Map<String, dynamic> toJson({bool withStrokes = true}) => {
        'id': id, 'paper': paper, 'w': w, 'h': h,
        if (infinite) 'inf': true,
        if (pdf != null) 'pdf': pdf,
        if (pdfPage != null) 'pdfPage': pdfPage,
        if (withStrokes) 'strokes': strokes,
        'texts': texts, 'images': images,
      };
  factory NotePage.fromJson(Map<String, dynamic> j, {List<Stroke>? strokes}) => NotePage(
      id: j['id'] as String, paper: j['paper'] as String, w: _d(j['w']), h: _d(j['h']),
      pdf: j['pdf'] as String?, pdfPage: j['pdfPage'] as int?, infinite: j['inf'] == true,
      strokes: strokes ?? [for (final s in j['strokes'] as List? ?? const []) Stroke.fromJson(s)],
      texts: [for (final t in j['texts'] as List) TextBox.fromJson(t)],
      images: [for (final i in j['images'] as List) ImageBox.fromJson(i)]);
}

class Notebook {
  Notebook(this.id, this.pages, {List<Recording>? recordings}) : recordings = recordings ?? [];
  final String id;
  final List<NotePage> pages;
  final List<Recording> recordings;

  Set<String> assets() => {
        for (final p in pages) ...[if (p.pdf != null) p.pdf!, for (final i in p.images) i.asset],
        for (final r in recordings) r.asset,
      };
  String searchText() => [for (final p in pages) for (final t in p.texts) t.text].join('\n').toLowerCase();
  Map<String, dynamic> toJson() => {'id': id, 'pages': pages, if (recordings.isNotEmpty) 'recordings': recordings};
  factory Notebook.fromJson(Map<String, dynamic> j) => Notebook(j['id'] as String, [for (final p in j['pages'] as List) NotePage.fromJson(p)],
      recordings: _recordings(j));
}

List<Recording> _recordings(Map<String, dynamic> j) =>
    [for (final r in (j['recordings'] as List? ?? const [])) Recording.fromJson(r as Map<String, dynamic>)];

/// A screen recording kept with the notebook: an MP4 file among the notebook's attachments.
class Recording {
  const Recording({required this.asset, required this.created, required this.ms, required this.audio});
  final String asset;
  final int created, ms; // when it was made, how long it is
  final bool audio; // with sound from the microphone
  Map<String, dynamic> toJson() => {'a': asset, 'c': created, 'ms': ms, 'au': audio};
  factory Recording.fromJson(Map<String, dynamic> j) =>
      Recording(asset: j['a'] as String, created: j['c'] as int, ms: j['ms'] as int, audio: j['au'] as bool? ?? false);
}

class NotebookMeta {
  NotebookMeta({required this.id, required this.name, this.folder, this.cover = 0xFF4F46E5,
      int? updatedAt, this.deleted = false, this.search = ''})
      : updatedAt = updatedAt ?? nowMs();
  final String id;
  String name;
  String? folder;
  int cover, updatedAt;
  bool deleted; // kept as a marker so the deletion reaches other devices
  String search;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'folder': folder, 'cover': cover,
      'updatedAt': updatedAt, 'deleted': deleted, 'search': search};
  factory NotebookMeta.fromJson(Map<String, dynamic> j) => NotebookMeta(id: j['id'] as String,
      name: j['name'] as String, folder: j['folder'] as String?, cover: j['cover'] as int,
      updatedAt: j['updatedAt'] as int, deleted: j['deleted'] == true, search: j['search'] as String? ?? '');
}

class Folder {
  Folder({required this.id, required this.name, int? updatedAt, this.deleted = false})
      : updatedAt = updatedAt ?? nowMs();
  final String id;
  String name;
  int updatedAt;
  bool deleted;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'updatedAt': updatedAt, 'deleted': deleted};
  factory Folder.fromJson(Map<String, dynamic> j) => Folder(id: j['id'] as String, name: j['name'] as String,
      updatedAt: j['updatedAt'] as int, deleted: j['deleted'] == true);
}

class Library {
  Library(this.folders, this.notebooks, [Set<String>? assets]) : assets = assets ?? {};
  List<Folder> folders;
  List<NotebookMeta> notebooks;
  Set<String> assets; // only used in the NAS copy: which attachments are already uploaded

  Map<String, dynamic> toJson() => {'folders': folders, 'notebooks': notebooks, 'assets': assets.toList()};
  factory Library.fromJson(Map<String, dynamic> j) => Library(
      [for (final f in j['folders'] as List) Folder.fromJson(f)],
      [for (final n in j['notebooks'] as List) NotebookMeta.fromJson(n)],
      {for (final a in (j['assets'] as List? ?? const [])) a as String});
}
