import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'dialogs.dart';
import 'store.dart';
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

  Future<void> _changeLocation() async {
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
            Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_outlined), label: const Text('Speicherort ändern…'), onPressed: _changeLocation)),
          ]),
        ),
      ),
    );
  }
}
