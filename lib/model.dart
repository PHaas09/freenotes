import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

final _rnd = Random.secure();
String newId() =>
    DateTime.now().millisecondsSinceEpoch.toRadixString(36) + _rnd.nextInt(1 << 30).toRadixString(36);
int nowMs() => DateTime.now().millisecondsSinceEpoch;
double _d(Object? v) => (v as num).toDouble();

/// Ids and asset names come from files on the NAS too, so they are checked
/// before being used in a file path.
final validId = RegExp(r'^[a-z0-9]{4,40}$');
final validAsset = RegExp(r'^[a-z0-9]{4,40}\.[a-z0-9]{2,5}$');

/// One pen stroke. [pts] holds x, y, pressure triplets in page units.
/// Finished strokes keep their points in a Float32List (4 bytes per number): an endless sheet can hold
/// hundreds of thousands of strokes. Holds only plain data, so notebooks can be saved in a background isolate.
class Stroke {
  Stroke({required this.type, required this.color, required this.size, required this.pts, this.sim = false});
  final String type; // ballpoint | fountain | pencil | highlighter
  final int color;
  final double size;
  final List<double> pts;
  final bool sim; // no real pressure (mouse/finger): simulate it from speed

  /// Area the stroke covers, including its width. Computed once; for loaded notebooks already in the
  /// background isolate, so opening a huge endless sheet doesn't freeze the screen.
  late final Rect bounds = () {
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

/// JSON <-> notebook in a background isolate, so big notebooks never freeze the UI.
Future<List<int>> encodeNotebook(Notebook nb) => Isolate.run(() => utf8.encode(jsonEncode(nb)));
Future<Notebook> decodeNotebook(List<int> bytes) => Isolate.run(() {
      final nb = Notebook.fromJson(jsonDecode(utf8.decode(bytes)));
      for (final p in nb.pages) {
        for (final s in p.strokes) {
          s.bounds; // computed here, off the UI thread
        }
      }
      return nb;
    });

/// Checks a notebook file (e.g. from the NAS) and returns its attachments plus the bytes to store under [id].
Future<(Set<String>, List<int>)> checkNotebookFile(List<int> bytes, String id) => Isolate.run(() {
      final nb = Notebook.fromJson(jsonDecode(utf8.decode(bytes)));
      return (nb.assets(), nb.id == id ? bytes : utf8.encode(jsonEncode(Notebook(id, nb.pages))));
    });

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

  Map<String, dynamic> toJson() => {
        'id': id, 'paper': paper, 'w': w, 'h': h,
        if (infinite) 'inf': true,
        if (pdf != null) 'pdf': pdf,
        if (pdfPage != null) 'pdfPage': pdfPage,
        'strokes': strokes, 'texts': texts, 'images': images,
      };
  factory NotePage.fromJson(Map<String, dynamic> j) => NotePage(
      id: j['id'] as String, paper: j['paper'] as String, w: _d(j['w']), h: _d(j['h']),
      pdf: j['pdf'] as String?, pdfPage: j['pdfPage'] as int?, infinite: j['inf'] == true,
      strokes: [for (final s in j['strokes'] as List) Stroke.fromJson(s)],
      texts: [for (final t in j['texts'] as List) TextBox.fromJson(t)],
      images: [for (final i in j['images'] as List) ImageBox.fromJson(i)]);
}

class Notebook {
  Notebook(this.id, this.pages);
  final String id;
  final List<NotePage> pages;

  Set<String> assets() => {
        for (final p in pages) ...[if (p.pdf != null) p.pdf!, for (final i in p.images) i.asset]
      };
  String searchText() => [for (final p in pages) for (final t in p.texts) t.text].join('\n').toLowerCase();
  Map<String, dynamic> toJson() => {'id': id, 'pages': pages};
  factory Notebook.fromJson(Map<String, dynamic> j) =>
      Notebook(j['id'] as String, [for (final p in j['pages'] as List) NotePage.fromJson(p)]);
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
