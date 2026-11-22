import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'dialogs.dart';
import 'ink.dart';
import 'model.dart';
import 'store.dart';

/// All pages of a notebook as thumbnails: tap to open one, drag to reorder, duplicate or delete.
/// Returns the index of the page to open (or null to stay on the current one).
class PageOverview extends StatefulWidget {
  const PageOverview({super.key, required this.nb, required this.store, required this.currentId, required this.pdfThumb});
  final Notebook nb;
  final Store store;
  final String currentId;
  final Future<ui.Image?> Function(NotePage) pdfThumb;
  @override
  State<PageOverview> createState() => _PageOverviewState();
}

class _PageOverviewState extends State<PageOverview> {
  final _thumbs = <String, ui.Image?>{}; // pdf asset#page -> small picture

  List<NotePage> get pages => widget.nb.pages;

  void _changed() {
    widget.store.changed(widget.nb);
    setState(() {});
  }

  Future<void> _delete(int i) async {
    final pg = pages[i];
    final empty = pg.strokes.isEmpty && pg.texts.isEmpty && pg.images.isEmpty;
    if (!empty && !await confirm(context, 'Seite ${i + 1} löschen?', 'Diese Seite wird endgültig gelöscht.')) return;
    pages.removeAt(i);
    if (pages.isEmpty) pages.add(NotePage());
    _changed();
  }

  Widget _thumb(NotePage pg) {
    if (pg.infinite) {
      return Container(
        width: 120,
        height: 120,
        color: const Color(0xFFFFFEFA),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.all_inclusive, size: 36, color: Color(0xFF5F6368)),
          Text('${pg.strokes.length} Striche', style: const TextStyle(fontSize: 11, color: Color(0xFF5F6368))),
        ]),
      );
    }
    final key = '${pg.pdf}#${pg.pdfPage}';
    if (pg.pdf != null && !_thumbs.containsKey(key)) {
      _thumbs[key] = null;
      widget.pdfThumb(pg).then((img) {
        if (mounted) setState(() => _thumbs[key] = img);
      });
    }
    return SizedBox(
      height: 150,
      child: AspectRatio(
        aspectRatio: pg.w / pg.h,
        child: FittedBox(
          child: SizedBox(
            width: pg.w,
            height: pg.h,
            child: ClipRect(
              child: Stack(children: [
                Positioned.fill(child: CustomPaint(painter: PaperPainter(pg, _thumbs[key]))),
                Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: InkPainter(pg.strokes)))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Seiten (${pages.length})')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: pages.length,
            onReorderItem: (from, to) {
              pages.insert(to, pages.removeAt(from));
              _changed();
            },
            itemBuilder: (context, i) {
              final pg = pages[i], current = pg.id == widget.currentId;
              return Card(
                key: ValueKey(pg.id),
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: current ? cs.primaryContainer : null,
                child: InkWell(
                  onTap: () => Navigator.pop(context, i),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      DecoratedBox(
                          decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 4)]),
                          child: _thumb(pg)),
                      const SizedBox(width: 16),
                      Expanded(
                          child: Text('Seite ${i + 1}',
                              style: TextStyle(fontWeight: current ? FontWeight.bold : FontWeight.normal, fontSize: 16))),
                      IconButton(
                          icon: const Icon(Icons.control_point_duplicate),
                          tooltip: 'Duplizieren',
                          onPressed: () {
                            pages.insert(i + 1, pg.duplicate());
                            _changed();
                          }),
                      IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Löschen', onPressed: () => _delete(i)),
                      const SizedBox(width: 24), // room for the drag handle
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
