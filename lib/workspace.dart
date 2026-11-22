import 'package:material_ui/material_ui.dart';

import 'editor_screen.dart';
import 'model.dart';
import 'store.dart';
import 'sync.dart';

/// One notebook, or two side by side (on a portrait screen one above the other), for example a PDF on
/// one side and your notes on the other. Both can be written on.
class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.store, required this.sync, required this.first});
  final Store store;
  final SyncService sync;
  final NotebookMeta first;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  NotebookMeta? second;

  Future<void> _pickSecond() async {
    final store = widget.store;
    final picked = await showDialog<Object>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('Daneben öffnen'), children: [
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, 'new'),
                  child: const ListTile(leading: Icon(Icons.note_add_outlined), title: Text('Neues Notizbuch'))),
              for (final m in store.notebooks)
                if (m.id != widget.first.id)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, m),
                      child: ListTile(leading: Icon(Icons.book, color: Color(m.cover)), title: Text(m.name))),
            ]));
    if (picked == null || !mounted) return;
    final m = picked is NotebookMeta ? picked : await store.createNotebook('Notizen zu ${widget.first.name}', folder: widget.first.folder);
    if (mounted) setState(() => second = m);
  }

  @override
  Widget build(BuildContext context) {
    final s = second;
    return PopScope(
      canPop: s == null, // "back" closes the second notebook first
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => second = null);
      },
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= c.maxHeight;
        final mq = MediaQuery.of(context);
        // Each side sees its own size, so the editor picks its phone or desktop layout per side.
        // Always wrapped the same way, so the first editor keeps its state when the second opens.
        Widget side(int i, Widget editor) {
          final size = s == null ? c.biggest : (wide ? Size((c.maxWidth - 1) / 2, c.maxHeight) : Size(c.maxWidth, (c.maxHeight - 1) / 2));
          final two = s != null;
          return MediaQuery(
              data: mq.copyWith(size: size).removePadding(
                  removeLeft: two && wide && i == 1,
                  removeRight: two && wide && i == 0,
                  removeTop: two && !wide && i == 1,
                  removeBottom: two && !wide && i == 0),
              child: editor);
        }

        return Material(
          child: Flex(direction: wide ? Axis.horizontal : Axis.vertical, children: [
            Expanded(
                child: side(
                    0,
                    EditorScreen(
                        key: ValueKey(widget.first.id),
                        store: widget.store,
                        sync: widget.sync,
                        meta: widget.first,
                        onSplit: s == null ? _pickSecond : null))),
            if (s != null) ...[
              wide ? const VerticalDivider(width: 1, thickness: 1) : const Divider(height: 1, thickness: 1),
              Expanded(
                  child: side(
                      1,
                      EditorScreen(
                          key: ValueKey(s.id),
                          store: widget.store,
                          sync: widget.sync,
                          meta: s,
                          onClose: () => setState(() => second = null)))),
            ],
          ]),
        );
      }),
    );
  }
}
