import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:freenotes/src/rust/frb_generated.dart';

bool _loaded = false;

/// Loads the Rust core for tests. Build it first: `cargo build --release --manifest-path rust/Cargo.toml`
Future<void> initRust() async {
  if (_loaded) return;
  _loaded = true;
  final name = Platform.isWindows ? 'freenotes_core.dll' : (Platform.isMacOS ? 'libfreenotes_core.dylib' : 'libfreenotes_core.so');
  await RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/release/$name'));
}
