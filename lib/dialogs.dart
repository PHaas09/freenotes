import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'store.dart';

/// Starts a fresh copy of the app and ends this one (desktop only).
Future<Never> restartApp() async {
  await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
  exit(0);
}

void snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'Löschen'}) async =>
    await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(title: Text(title), content: Text(body), actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
            ])) ??
    false;

/// Returns the trimmed text, or null if cancelled or empty.
Future<String?> askText(BuildContext context, String title, {String initial = '', String ok = 'OK'}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
                FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ok)),
              ]));
  final t = r?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

Widget swatch(BuildContext context, int color, bool selected, VoidCallback onTap, {double size = 26}) {
  final cs = Theme.of(context).colorScheme;
  return Semantics(
    button: true,
    selected: selected,
    label: 'Farbe',
    child: InkResponse(
      onTap: onTap,
      radius: size * 0.8,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
              color: Color(color),
              shape: BoxShape.circle,
              border: Border.all(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 3 : 1)),
        ),
      ),
    ),
  );
}

Future<int?> pickColor(BuildContext context, List<int> colors, int current, {String title = 'Farbe wählen'}) =>
    showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
            title: Text(title),
            content: SizedBox(
                width: 320,
                child: Wrap(children: [
                  for (final c in colors) swatch(ctx, c, c == current, () => Navigator.pop(ctx, c), size: 36),
                ]))));

/// Red bar shown when saving to disk failed, so the user knows before closing the app.
class SaveErrorBar extends StatelessWidget {
  const SaveErrorBar(this.store, {super.key});
  final Store store;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: store,
      builder: (context, _) => store.saveError == null
          ? const SizedBox.shrink()
          : Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(8),
              child: Text(store.saveError!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))));
}
