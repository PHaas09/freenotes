//! FreeNotes core, called from Flutter through flutter_rust_bridge.
//! Only `api` is visible to Dart; `freehand` is the stroke outline algorithm it uses.
pub mod api;
mod freehand;
#[cfg(windows)]
mod winrec;
mod frb_generated;
