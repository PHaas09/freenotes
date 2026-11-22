//! FreeNotes core, called from Flutter through flutter_rust_bridge.
//! Only `api` is visible to Dart; `freehand` is the stroke outline algorithm it uses.
pub mod api;
mod freehand;
mod frb_generated;
