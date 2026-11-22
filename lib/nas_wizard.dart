import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'sync.dart';

/// A device in the home network that looks like a NAS.
class NasFound {
  NasFound(this.host);
  final String host;
  bool https = false, http = false, ugreen = false, synology = false;
  bool get webdav => https || http;
  String get label => ugreen ? 'UGREEN NAS' : (synology ? 'Synology NAS' : 'NAS');
  String get url => https ? 'https://$host:5006/' : 'http://$host:5005/';
}

Future<bool> _open(String host, int port) async {
  try {
    final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 500));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Searches the home network for a NAS: on every address of the own network, tries the WebDAV ports
/// (5006 https, 5005 http) and the web pages of UGREEN (9999) and Synology (5000/5001).
Future<List<NasFound>> findNas({void Function(double done)? progress}) async {
  final nets = <String>{};
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in ni.addresses) {
      final p = a.address.split('.').map(int.parse).toList();
      if (p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] >= 16 && p[1] <= 31)) nets.add('${p[0]}.${p[1]}.${p[2]}');
    }
  }
  // shortcut: searches the own /24 network (x.y.z.1-254), which covers home routers; else type the address in
  const ports = [5006, 5005, 9999, 5001, 5000];
  final jobs = [for (final n in nets) for (var h = 1; h < 255; h++) for (final p in ports) ('$n.$h', p)];
  final found = <String, NasFound>{};
  for (var i = 0; i < jobs.length; i += 200) {
    await Future.wait([
      for (final (host, port) in jobs.skip(i).take(200))
        _open(host, port).then((open) {
          if (!open) return;
          final f = found.putIfAbsent(host, () => NasFound(host));
          switch (port) {
            case 5006:
              f.https = true;
            case 5005:
              f.http = true;
            case 9999:
              f.ugreen = true;
            default:
              f.synology = true;
          }
        })
    ]);
    progress?.call(((i + 200) / jobs.length).clamp(0.0, 1.0));
  }
  return found.values.toList()..sort((a, b) => (b.webdav ? 1 : 0) - (a.webdav ? 1 : 0));
}

/// Step by step: find the NAS, sign in, pick a folder. Saves the settings and starts the first sync.
class NasWizard extends StatefulWidget {
  const NasWizard({super.key, required this.sync});
  final SyncService sync;
  @override
  State<NasWizard> createState() => _NasWizardState();
}

class _NasWizardState extends State<NasWizard> {
  int step = 0; // 0 search, 1 sign in, 2 folder, 3 done
  double? searching;
  List<NasFound> found = const [];
  NasFound? nas;
  final user = TextEditingController(), pass = TextEditingController();
  NasConfig? cfg;
  final segs = <String>[];
  List<String>? folders;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      searching = 0;
      error = null;
    });
    try {
      final f = await findNas(progress: (d) {
        if (mounted) setState(() => searching = d);
      });
      if (mounted) setState(() => found = f);
    } catch (e) {
      if (mounted) setState(() => error = 'Suche nicht möglich: $e');
    } finally {
      if (mounted) setState(() => searching = null);
    }
  }

  Future<void> _signIn() async {
    final c = NasConfig()
      ..url = nas!.url
      ..user = user.text.trim()
      ..password = pass.text
      ..trustNew = true; // first contact: remember the NAS's certificate
    setState(() {
      busy = true;
      error = null;
    });
    final client = NasClient(c);
    try {
      final f = await client.listFolders('');
      c.trustNew = false;
      setState(() {
        cfg = c;
        folders = f;
        step = 2;
      });
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _open(String? folder) async {
    final c = cfg!;
    if (folder == null) {
      segs.removeLast();
    } else {
      segs.add(folder);
    }
    setState(() {
      busy = true;
      error = null;
    });
    final client = NasClient(c);
    try {
      final f = await client.listFolders(segs.isEmpty ? '' : '${segs.map(Uri.encodeComponent).join('/')}/');
      setState(() => folders = f);
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _useHere() async {
    final c = cfg!, s = widget.sync;
    final inside = segs.isNotEmpty && segs.last.toLowerCase() == 'freenotes';
    s.cfg
      ..url = Uri.parse(c.url).replace(pathSegments: [...segs, if (!inside) 'FreeNotes']).toString()
      ..user = c.user
      ..password = c.password
      ..pin = c.pin
      ..selfSigned = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await s.saveConfig();
      final r = await s.test();
      if (r != 'Verbindung OK') throw r;
      s.run();
      setState(() => step = 3);
    } catch (e) {
      setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _howToEnable(NasFound f) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('WebDAV einschalten'),
            content: Text(f.ugreen
                ? 'Auf der NAS ist WebDAV noch aus. So geht es bei UGREEN:\n\n'
                    '1. Im Browser http://${f.host}:9999 öffnen und anmelden.\n'
                    '2. Systemsteuerung → Dateidienste → WebDAV.\n'
                    '3. „Dienst aktivieren“ anhaken, unter „Erweitert“ HTTPS (Port 5006) einschalten.\n'
                    '4. Speichern und „Übernehmen“.\n\nDanach hier „Erneut suchen“.'
                : 'Auf der NAS ist WebDAV noch aus. Schalte in der Weboberfläche der NAS den WebDAV-Dienst ein '
                    '(am besten mit HTTPS, Port 5006) und suche danach erneut.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget body;
    switch (step) {
      case 0:
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('NAS im Heimnetz suchen', style: t.titleLarge),
          const SizedBox(height: 8),
          const Text('Das Gerät muss im selben WLAN/Netzwerk wie die NAS sein.'),
          const SizedBox(height: 16),
          if (searching != null) ...[LinearProgressIndicator(value: searching), const SizedBox(height: 8), const Text('Suche läuft…')],
          if (searching == null && found.isEmpty) const Text('Keine NAS gefunden.'),
          for (final f in found)
            Card(
              child: ListTile(
                leading: Icon(f.webdav ? Icons.storage : Icons.warning_amber),
                title: Text('${f.label}  (${f.host})'),
                subtitle: Text(f.webdav ? (f.https ? 'Bereit (WebDAV, verschlüsselt)' : 'Bereit (WebDAV, unverschlüsselt)') : 'WebDAV ist noch aus – antippen für Hilfe'),
                onTap: () => f.webdav
                    ? setState(() {
                        nas = f;
                        step = 1;
                      })
                    : _howToEnable(f),
              ),
            ),
          const SizedBox(height: 12),
          if (searching == null) OutlinedButton.icon(icon: const Icon(Icons.refresh), label: const Text('Erneut suchen'), onPressed: _search),
        ]);
      case 1:
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Bei ${nas!.label} anmelden', style: t.titleLarge),
          const SizedBox(height: 8),
          const Text('Mit deinem normalen NAS-Benutzer. Passwort und Adresse bleiben nur auf diesem Gerät.'),
          TextField(controller: user, autofocus: true, decoration: const InputDecoration(labelText: 'Benutzername')),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Passwort'), onSubmitted: (_) => _signIn()),
          const SizedBox(height: 16),
          FilledButton(onPressed: busy ? null : _signIn, child: const Text('Anmelden')),
          TextButton(onPressed: () => setState(() => step = 0), child: const Text('Andere NAS wählen')),
        ]);
      case 2:
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Wo sollen die Notizen hin?', style: t.titleLarge),
          const SizedBox(height: 4),
          Text(segs.isEmpty ? 'Ordner auf der NAS' : '/${segs.join('/')}', style: t.bodySmall),
          const SizedBox(height: 8),
          if (segs.isNotEmpty) ...[
            FilledButton.icon(
                icon: const Icon(Icons.check),
                label: Text(segs.last.toLowerCase() == 'freenotes' ? 'Hier speichern' : 'Hier speichern (Ordner „FreeNotes“ wird angelegt)'),
                onPressed: busy ? null : _useHere),
            TextButton.icon(icon: const Icon(Icons.arrow_back), label: const Text('Zurück'), onPressed: busy ? null : () => _open(null)),
          ],
          for (final f in folders ?? const <String>[])
            ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f), onTap: busy ? null : () => _open(f)),
          if ((folders ?? const []).isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Keine Unterordner.')),
        ]);
      default:
        body = Column(children: [
          const Icon(Icons.check_circle, size: 64, color: Color(0xFF178A3E)),
          const SizedBox(height: 12),
          Text('Fertig!', style: t.headlineSmall),
          const SizedBox(height: 8),
          const Text('Deine Notizbücher werden ab jetzt automatisch auf der NAS gespeichert.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen')),
        ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('NAS verbinden')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            body,
            if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        ),
      ),
    );
  }
}
