import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'dialogs.dart';
import 'store.dart';
import 'nas_wizard.dart';
import 'sync.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store, required this.sync});
  final Store store;
  final SyncService sync;
  @override
  State<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsScreen> {
  late final url = TextEditingController(text: widget.sync.cfg.url);
  late final user = TextEditingController(text: widget.sync.cfg.user);
  late final pass = TextEditingController(text: widget.sync.cfg.password);
  late bool selfSigned = widget.sync.cfg.selfSigned;
  String? result;
  bool testing = false;

  Future<void> _save() async {
    // another NAS: forget the certificate remembered for the old one
    if (Uri.tryParse(url.text.trim())?.host != Uri.tryParse(widget.sync.cfg.url)?.host) widget.sync.cfg.pin = '';
    final cfg = widget.sync.cfg
      ..url = url.text.trim()
      ..user = user.text.trim()
      ..password = pass.text
      ..selfSigned = selfSigned;
    setState(() => testing = true);
    try {
      await widget.sync.saveConfig();
      final r = cfg.enabled ? await widget.sync.test() : 'Gespeichert. NAS-Sync ist aus.';
      setState(() => result = r);
      if (r == 'Verbindung OK') widget.sync.run();
    } catch (e) {
      setState(() => result = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  /// Lets the user click through the folders on the NAS and pick where FreeNotes should store its data.
  Future<void> _browse() async {
    final u = Uri.tryParse(url.text.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) {
      snack(context, 'Bitte zuerst die Adresse der NAS eintragen, z. B. https://NAS-IP:5006');
      return;
    }
    final root = u.replace(pathSegments: const []);
    final nas = NasClient(NasConfig()
      ..url = root.toString()
      ..user = user.text.trim()
      ..password = pass.text
      ..selfSigned = selfSigned);
    final segs = <String>[];
    const use = '\u0000use', up = '\u0000up';
    try {
      while (mounted) {
        final folders = await nas.listFolders(segs.isEmpty ? '' : '${segs.map(Uri.encodeComponent).join('/')}/');
        if (!mounted) return;
        final pick = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(title: Text(segs.isEmpty ? 'Ordner auf der NAS' : '/${segs.join('/')}'), children: [
                  if (segs.isNotEmpty)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, use),
                        child: const Text('✓ Hier speichern', style: TextStyle(fontWeight: FontWeight.bold))),
                  if (segs.isNotEmpty) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, up), child: const Text('← Zurück')),
                  for (final f in folders)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, f),
                        child: Row(children: [const Icon(Icons.folder_outlined), const SizedBox(width: 12), Expanded(child: Text(f))])),
                  if (folders.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Keine Unterordner.')),
                ]));
        if (pick == null) return;
        if (pick == up) {
          segs.removeLast();
        } else if (pick == use) {
          final inside = segs.last.toLowerCase() == 'freenotes';
          setState(() => url.text = root.replace(pathSegments: [...segs, if (!inside) 'FreeNotes']).toString());
          await _save();
          return;
        } else {
          segs.add(pick);
        }
      }
    } catch (e) {
      if (mounted) snack(context, 'Ordner auf der NAS konnten nicht gelesen werden: $e');
    } finally {
      nas.close();
    }
  }

  Future<void> _changeLocation() async {
    // Desktop only (button is hidden on phones), and we need a real folder path here, not a content:// URI.
    // ignore: deprecated_member_use
    final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Neuen Speicherort für FreeNotes wählen');
    if (picked == null || !mounted) return;
    if (!await confirm(context, 'Notizen verschieben?',
        'Alle Notizbücher werden in einen Ordner „FreeNotes“ unter\n$picked\nverschoben und am alten Ort gelöscht, '
        'sobald alles kopiert ist. Gibt es dort schon FreeNotes-Daten, werden diese verwendet und der alte Ort bleibt unverändert.\n\n'
        'FreeNotes startet danach neu.', ok: 'Verschieben')) {
      return;
    }
    while (widget.sync.busy.value) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    widget.sync.busy.value = true; // blocks NAS sync while files move; the app restarts afterwards
    try {
      await widget.store.moveTo(picked);
      await restartApp();
    } catch (e) {
      widget.sync.busy.value = false;
      if (mounted) snack(context, 'Verschieben fehlgeschlagen: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            Text('NAS-Synchronisierung (WebDAV)', style: t.titleLarge),
            const SizedBox(height: 8),
            const Text('Deine Notizbücher werden automatisch auf deiner NAS gespeichert: beim Start, alle 2 Minuten, '
                'beim Schließen eines Notizbuchs und beim Beenden der App. Adresse und Passwort bleiben nur auf diesem Gerät.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.wifi_find),
              label: const Text('NAS automatisch finden und verbinden'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => NasWizard(sync: widget.sync)));
                if (!mounted) return;
                final c = widget.sync.cfg;
                setState(() {
                  url.text = c.url;
                  user.text = c.user;
                  pass.text = c.password;
                  selfSigned = c.selfSigned;
                });
              },
            ),
            const SizedBox(height: 16),
            Text('Oder von Hand einrichten:', style: t.bodySmall),
            TextField(
                controller: url,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'WebDAV-Adresse', hintText: 'https://NAS-ADRESSE:PORT/Ordner/FreeNotes')),
            if (url.text.trim().startsWith('http://'))
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Achtung: Mit http:// wird dein Passwort unverschlüsselt übertragen. Besser https:// verwenden.',
                      style: TextStyle(color: Theme.of(context).colorScheme.error))),
            TextField(controller: user, decoration: const InputDecoration(labelText: 'Benutzername')),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Passwort')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: selfSigned,
              onChanged: (v) => setState(() => selfSigned = v),
              title: const Text('Eigenes Zertifikat der NAS akzeptieren'),
              subtitle: const Text('Nötig bei https:// mit dem Standard-Zertifikat der NAS. Gilt nur für diese Adresse.'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, children: [
              FilledButton(onPressed: testing ? null : _save, child: const Text('Speichern und testen')),
              OutlinedButton.icon(
                  icon: const Icon(Icons.folder_outlined), label: const Text('Ordner auf der NAS durchsuchen'), onPressed: _browse),
              OutlinedButton(onPressed: widget.sync.cfg.enabled ? widget.sync.run : null, child: const Text('Jetzt synchronisieren')),
            ]),
            if (testing) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (result != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(result!)),
            ValueListenableBuilder(
                valueListenable: widget.sync.status,
                builder: (context, s, _) => s.isEmpty ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 8), child: Text(s))),
            const Divider(height: 40),
            Text('Lokaler Speicherort', style: t.titleMedium),
            const SizedBox(height: 4),
            SelectableText(widget.store.dir.path),
            const SizedBox(height: 8),
            // Phones keep app data in the app's own storage; moving it needs a restart, which only desktop can do.
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_outlined), label: const Text('Speicherort ändern…'), onPressed: _changeLocation)),
          ]),
        ),
      ),
    );
  }
}
