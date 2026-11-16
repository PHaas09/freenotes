import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'dialogs.dart';
import 'library_screen.dart';
import 'store.dart';
import 'sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  final Store store;
  try {
    store = await Store.open();
  } on StorageMissing catch (e) {
    return runApp(_StorageMissingApp(e.path));
  }
  final sync = SyncService(store);
  await sync.load();
  runApp(FreeNotesApp(store: store, sync: sync));
  sync.run();
}

/// Shown instead of the app when the storage folder (e.g. drive G:) is not connected.
class _StorageMissingApp extends StatelessWidget {
  const _StorageMissingApp(this.path);
  final String path;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FreeNotes',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF4F46E5)),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.folder_off_outlined, size: 56),
                const SizedBox(height: 16),
                Text('Speicherort nicht erreichbar:\n$path', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                const Text('Schließe das Laufwerk an (oder verbinde es neu) und versuche es dann erneut.', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: restartApp, child: const Text('Erneut versuchen')),
              ]),
            ),
          ),
        ),
      );
}

class FreeNotesApp extends StatefulWidget {
  const FreeNotesApp({super.key, required this.store, required this.sync});
  final Store store;
  final SyncService sync;
  @override
  State<FreeNotesApp> createState() => _FreeNotesAppState();
}

class _FreeNotesAppState extends State<FreeNotesApp> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onPause: widget.store.flush, // phone: app goes to background
      onInactive: widget.store.flush,
      onExitRequested: () async {
        // Save everything and push it to the NAS before the window closes (max. 8 s).
        await widget.store.flush();
        await widget.sync.run().timeout(const Duration(seconds: 8), onTimeout: () {});
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4F46E5);
    return MaterialApp(
      title: 'FreeNotes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: LibraryScreen(store: widget.store, sync: widget.sync),
    );
  }
}
