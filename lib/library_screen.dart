import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'dialogs.dart';
import 'editor_screen.dart';
import 'model.dart';
import 'settings_screen.dart';
import 'store.dart';
import 'sync.dart';

const covers = [0xFF4F46E5, 0xFF0B8BD9, 0xFF00897B, 0xFF178A3E, 0xFFFF9800, 0xFFD42A2A, 0xFFD81B60, 0xFF6D4C41, 0xFF37474F];

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store, required this.sync});
  final Store store;
  final SyncService sync;
  @override
  State<LibraryScreen> createState() => _LibraryState();
}

class _LibraryState extends State<LibraryScreen> {
  String? folder; // null = all notebooks
  String query = '';
  Store get store => widget.store;

  void _open(NotebookMeta m) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => EditorScreen(store: store, sync: widget.sync, meta: m)));

  Future<void> _newNotebook() async {
    final name = TextEditingController(text: 'Notizbuch ${store.notebooks.length + 1}');
    var cover = covers[store.notebooks.length % covers.length];
    var paper = 'lined';
    var endless = false;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                    title: const Text('Neues Notizbuch'),
                    content: SizedBox(
                        width: 360,
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
                          const SizedBox(height: 16),
                          const Text('Cover'),
                          Wrap(children: [for (final c in covers) swatch(ctx, c, c == cover, () => set(() => cover = c), size: 30)]),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            initialValue: paper,
                            decoration: const InputDecoration(labelText: 'Papier'),
                            items: const [
                              DropdownMenuItem(value: 'blank', child: Text('Blanko')),
                              DropdownMenuItem(value: 'lined', child: Text('Liniert')),
                              DropdownMenuItem(value: 'grid', child: Text('Kariert')),
                              DropdownMenuItem(value: 'dots', child: Text('Punktiert')),
                            ],
                            onChanged: (v) => paper = v ?? paper,
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<bool>(
                            initialValue: endless,
                            decoration: const InputDecoration(labelText: 'Format'),
                            items: const [
                              DropdownMenuItem(value: false, child: Text('Seiten (A4)')),
                              DropdownMenuItem(value: true, child: Text('Unendliches Blatt')),
                            ],
                            onChanged: (v) => endless = v ?? endless,
                          ),
                        ])),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Erstellen')),
                    ])));
    if (ok != true || !mounted) return;
    final n = name.text.trim().isEmpty ? 'Notizbuch' : name.text.trim();
    _open(await store.createNotebook(n, folder: folder, cover: cover, pages: [NotePage(paper: paper, infinite: endless)]));
  }

  Future<void> _importPdf() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf']);
    if (f?.path == null) return;
    try {
      final asset = await store.importAsset(f!.path!);
      final doc = await PdfDocument.openFile(store.assetPath(asset));
      final pages = [
        for (var i = 0; i < doc.pages.length; i++)
          NotePage(paper: 'blank', w: doc.pages[i].width, h: doc.pages[i].height, pdf: asset, pdfPage: i)
      ];
      await doc.dispose();
      final m = await store.createNotebook(p.basenameWithoutExtension(f.path!), folder: folder, cover: 0xFF37474F, pages: pages);
      if (mounted) _open(m);
    } catch (e) {
      if (mounted) snack(context, 'PDF konnte nicht importiert werden: $e');
    }
  }

  Future<void> _notebookMenu(NotebookMeta m, String action) async {
    switch (action) {
      case 'rename':
        final n = await askText(context, 'Umbenennen', initial: m.name);
        if (n != null) await store.updateMeta(m, (m) => m.name = n);
      case 'cover':
        final c = await pickColor(context, covers, m.cover, title: 'Cover-Farbe');
        if (c != null) await store.updateMeta(m, (m) => m.cover = c);
      case 'move':
        if (!mounted) return;
        final target = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(title: const Text('Verschieben nach'), children: [
                  SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Kein Ordner')),
                  for (final f in store.folders)
                    SimpleDialogOption(onPressed: () => Navigator.pop(ctx, f.id), child: Text(f.name)),
                ]));
        if (target != null) await store.updateMeta(m, (m) => m.folder = target.isEmpty ? null : target);
      case 'delete':
        if (await confirm(context, '„${m.name}“ löschen?', 'Das Notizbuch wird auf allen Geräten gelöscht.')) {
          await store.deleteNotebook(m);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final side = _folders(wide);
        return Scaffold(
          appBar: AppBar(
            title: const Text('FreeNotes'),
            titleSpacing: wide ? null : 0,
            actions: [
              SizedBox(
                width: wide ? 280 : 120, // phone: leave room for the title
                child: TextField(
                  decoration: InputDecoration(
                      hintText: 'Suchen…', prefixIcon: const Icon(Icons.search), isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24))),
                  onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
                ),
              ),
              _syncButton(),
              IconButton(
                  icon: const Icon(Icons.settings),
                  tooltip: 'Einstellungen',
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => SettingsScreen(store: store, sync: widget.sync)))),
              const SizedBox(width: 8),
            ],
          ),
          drawer: wide ? null : Drawer(child: side),
          body: Column(children: [
            SaveErrorBar(store),
            Expanded(
                child: Row(children: [
              if (wide) SizedBox(width: 240, child: side),
              if (wide) const VerticalDivider(width: 1),
              Expanded(child: _grid()),
            ])),
          ]),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Neu'),
            onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (ctx) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(leading: const Icon(Icons.note_add_outlined), title: const Text('Neues Notizbuch'),
                          onTap: () { Navigator.pop(ctx); _newNotebook(); }),
                      ListTile(leading: const Icon(Icons.picture_as_pdf), title: const Text('PDF importieren'),
                          onTap: () { Navigator.pop(ctx); _importPdf(); }),
                    ]))),
          ),
        );
      },
    );
  }

  Widget _syncButton() => ListenableBuilder(
      listenable: Listenable.merge([widget.sync.busy, widget.sync.ok, widget.sync.status]),
      builder: (context, _) {
        final s = widget.sync;
        if (!s.cfg.enabled) {
          return IconButton(icon: const Icon(Icons.cloud_off), tooltip: 'NAS nicht eingerichtet',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => SettingsScreen(store: store, sync: s))));
        }
        final icon = s.busy.value ? Icons.cloud_sync : s.ok.value == false ? Icons.sync_problem : Icons.cloud_done;
        return IconButton(
            icon: Icon(icon, color: s.ok.value == false ? Theme.of(context).colorScheme.error : null),
            tooltip: s.status.value.isEmpty ? 'Jetzt mit NAS synchronisieren' : s.status.value,
            onPressed: s.run);
      });

  Widget _folders(bool wide) {
    void pick(String? id) {
      setState(() => folder = id);
      if (!wide) Navigator.pop(context);
    }

    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
      ListTile(leading: const Icon(Icons.library_books_outlined), title: const Text('Alle Notizbücher'),
          selected: folder == null, onTap: () => pick(null)),
      for (final f in store.folders)
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(f.name),
          selected: folder == f.id,
          onTap: () => pick(f.id),
          trailing: PopupMenuButton<String>(
            tooltip: 'Ordner',
            onSelected: (v) async {
              if (v == 'rename') {
                final n = await askText(context, 'Ordner umbenennen', initial: f.name);
                if (n != null) await store.updateFolder(f, (f) => f.name = n);
              } else if (await confirm(context, 'Ordner „${f.name}“ löschen?',
                  'Die Notizbücher darin bleiben erhalten und landen unter „Alle Notizbücher“.')) {
                await store.updateFolder(f, (f) => f.deleted = true);
                if (folder == f.id) setState(() => folder = null);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
              PopupMenuItem(value: 'delete', child: Text('Löschen')),
            ],
          ),
        ),
      ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: const Text('Neuer Ordner'),
          onTap: () async {
            final n = await askText(context, 'Neuer Ordner', ok: 'Erstellen');
            if (n != null) pick((await store.createFolder(n)).id);
          }),
    ]);
  }

  Widget _grid() {
    final list = store.notebooks
        .where((n) => query.isNotEmpty
            ? n.name.toLowerCase().contains(query) || n.search.contains(query)
            : folder == null || n.folder == folder)
        .toList();
    if (list.isEmpty) {
      return Center(child: Text(query.isNotEmpty ? 'Nichts gefunden.' : 'Noch keine Notizbücher. Tippe auf „Neu“.'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 170, mainAxisSpacing: 24, crossAxisSpacing: 24, childAspectRatio: 0.6),
      itemCount: list.length,
      itemBuilder: (context, i) => _card(list[i]),
    );
  }

  Widget _card(NotebookMeta m) {
    final d = DateTime.fromMillisecondsSinceEpoch(m.updatedAt);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Material(
          color: Color(m.cover),
          elevation: 3,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(4), right: Radius.circular(12)),
          child: InkWell(
            onTap: () => _open(m),
            child: Stack(children: [
              const Positioned(left: 12, top: 0, bottom: 0, width: 3, child: ColoredBox(color: Colors.white24)),
              Center(
                child: Container(
                  margin: const EdgeInsets.only(left: 26, right: 12),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(6)),
                  child: Text(m.name, maxLines: 3, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF222222))),
                ),
              ),
            ]),
          ),
        ),
      ),
      Row(children: [
        Expanded(child: Text('${d.day}.${d.month}.${d.year}', style: Theme.of(context).textTheme.bodySmall)),
        PopupMenuButton<String>(
          tooltip: 'Notizbuch',
          onSelected: (v) => _notebookMenu(m, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
            PopupMenuItem(value: 'cover', child: Text('Cover-Farbe')),
            PopupMenuItem(value: 'move', child: Text('In Ordner verschieben')),
            PopupMenuItem(value: 'delete', child: Text('Löschen')),
          ],
        ),
      ]),
    ]);
  }
}
