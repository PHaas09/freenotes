//! Screen recording into an MP4 file. On Windows the app hands over its own picture frame by frame and
//! Media Foundation encodes it (with or without microphone sound). Android and iPhone record with the
//! system's own screen recorder instead and don't use these functions.

/// Starts a recording of `width` x `height` pixels into `path`; returns its handle.
pub fn rec_start(path: String, width: u32, height: u32, fps: u32, audio: bool) -> Result<u32, String> {
    #[cfg(windows)]
    return crate::winrec::start(&path, width, height, fps, audio).map_err(|e| e.message());
    #[cfg(not(windows))]
    {
        let _ = (path, width, height, fps, audio);
        Err("Aufnahme über den Rust-Kern gibt es nur unter Windows".into())
    }
}

/// Adds one picture (RGBA, any size: it is fitted into the video) taken `ms` milliseconds after the start.
pub fn rec_frame(rec: u32, rgba: Vec<u8>, width: u32, height: u32, ms: u32) -> Result<(), String> {
    #[cfg(windows)]
    return crate::winrec::frame(rec, &rgba, width, height, ms).map_err(|e| e.message());
    #[cfg(not(windows))]
    {
        let _ = (rec, rgba, width, height, ms);
        Err("nur unter Windows".into())
    }
}

/// Finishes the file; returns the length of the recording in milliseconds.
pub fn rec_stop(rec: u32) -> Result<u32, String> {
    #[cfg(windows)]
    return crate::winrec::stop(rec).map_err(|e| e.message());
    #[cfg(not(windows))]
    {
        let _ = rec;
        Err("nur unter Windows".into())
    }
}
