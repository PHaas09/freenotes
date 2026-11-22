//! Screen recording on Windows with Media Foundation (part of Windows, no extra codecs): the app's own
//! picture comes in as frames, gets encoded as H.264 video, sound from the default microphone as AAC,
//! both into one MP4 file.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

use windows::core::{Error, Result, GUID, HSTRING};
use windows::Win32::Foundation::E_INVALIDARG;
use windows::Win32::Media::Audio::eConsole;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

/// COM objects used from several threads; all of them live in the multithreaded apartment.
struct Mt<T>(T);
unsafe impl<T> Send for Mt<T> {}
unsafe impl<T> Sync for Mt<T> {}

struct Rec {
    writer: Arc<Mutex<Mt<IMFSinkWriter>>>,
    video: u32,
    w: u32,
    h: u32,
    fps: u32,
    frame: Vec<u8>,
    last: Option<i64>, // time of the last frame, 100 ns units
    stop: Arc<AtomicBool>,
    sound: Option<JoinHandle<()>>,
}

static RECS: LazyLock<Mutex<HashMap<u32, Rec>>> = LazyLock::new(Default::default);
static NEXT: AtomicU32 = AtomicU32::new(1);

fn com() {
    // every thread that touches Media Foundation must join COM; repeated calls are harmless
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
}

fn pack(a: u32, b: u32) -> u64 {
    ((a as u64) << 32) | b as u64
}

unsafe fn media_type(major: &GUID, sub: &GUID) -> Result<IMFMediaType> {
    let t = MFCreateMediaType()?;
    t.SetGUID(&MF_MT_MAJOR_TYPE, major)?;
    t.SetGUID(&MF_MT_SUBTYPE, sub)?;
    Ok(t)
}

unsafe fn video_type(sub: &GUID, w: u32, h: u32, fps: u32) -> Result<IMFMediaType> {
    let t = media_type(&MFMediaType_Video, sub)?;
    t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
    t.SetUINT64(&MF_MT_FRAME_SIZE, pack(w, h))?;
    t.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1))?;
    t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
    Ok(t)
}

unsafe fn pcm_type(rate: u32, ch: u32) -> Result<IMFMediaType> {
    let t = media_type(&MFMediaType_Audio, &MFAudioFormat_PCM)?;
    t.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
    t.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate)?;
    t.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, ch)?;
    t.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, ch * 2)?;
    t.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * ch * 2)?;
    t.SetUINT32(&MF_MT_ALL_SAMPLES_INDEPENDENT, 1)?;
    Ok(t)
}

/// The default microphone, delivering 16-bit PCM at 48 kHz (what the AAC encoder takes).
unsafe fn open_mic() -> Result<(IMFSourceReader, u32)> {
    let mut attrs = None;
    MFCreateAttributes(&mut attrs, 2)?;
    let attrs = attrs.ok_or_else(|| Error::from(E_INVALIDARG))?;
    attrs.SetGUID(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID)?;
    attrs.SetUINT32(&MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ROLE, eConsole.0 as u32)?;
    let source = MFCreateDeviceSource(&attrs)?;
    let reader = MFCreateSourceReaderFromMediaSource(&source, None)?;
    let stream = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;
    let ch = reader.GetNativeMediaType(stream, 0)?.GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS)?.clamp(1, 2);
    reader.SetCurrentMediaType(stream, None, &pcm_type(48000, ch)?)?;
    Ok((reader, ch))
}

pub fn start(path: &str, w: u32, h: u32, fps: u32, audio: bool) -> Result<u32> {
    com();
    let (w, h, fps) = (w.max(2) & !1, h.max(2) & !1, fps.clamp(1, 60)); // H.264 needs even sizes
    unsafe {
        MFStartup(MF_VERSION, MFSTARTUP_FULL)?;
        let started = Instant::now();
        let result = (|| -> Result<Rec> {
            let mut attrs = None;
            MFCreateAttributes(&mut attrs, 1)?;
            let attrs = attrs.ok_or_else(|| Error::from(E_INVALIDARG))?;
            attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)?;
            let _ = std::fs::remove_file(path);
            let writer = MFCreateSinkWriterFromURL(&HSTRING::from(path), None, &attrs)?;
            let out = video_type(&MFVideoFormat_H264, w, h, fps)?;
            // about 0.15 bit per pixel and frame: handwriting and text stay crisp
            out.SetUINT32(&MF_MT_AVG_BITRATE, ((w as u64 * h as u64 * fps as u64 * 15 / 100) as u32).clamp(1_000_000, 12_000_000))?;
            let video = writer.AddStream(&out)?;
            let inp = video_type(&MFVideoFormat_RGB32, w, h, fps)?;
            inp.SetUINT32(&MF_MT_DEFAULT_STRIDE, w * 4)?; // top-down rows
            writer.SetInputMediaType(video, &inp, None)?;
            let mic = if audio {
                let (reader, ch) = open_mic()?;
                let out = media_type(&MFMediaType_Audio, &MFAudioFormat_AAC)?;
                out.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
                out.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48000)?;
                out.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, ch)?;
                out.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000)?; // 128 kbit/s
                let stream = writer.AddStream(&out)?;
                writer.SetInputMediaType(stream, &pcm_type(48000, ch)?, None)?;
                Some((Mt(reader), stream))
            } else {
                None
            };
            writer.BeginWriting()?;
            let writer = Arc::new(Mutex::new(Mt(writer)));
            let stop = Arc::new(AtomicBool::new(false));
            let sound = mic.map(|(reader, stream)| {
                let (writer, stop) = (writer.clone(), stop.clone());
                std::thread::spawn(move || record_sound(reader, stream, writer, stop, started))
            });
            Ok(Rec { writer, video, w, h, fps, frame: vec![], last: None, stop, sound })
        })();
        match result {
            Ok(rec) => {
                let id = NEXT.fetch_add(1, Ordering::Relaxed);
                RECS.lock().unwrap().insert(id, rec);
                Ok(id)
            }
            Err(e) => {
                let _ = MFShutdown();
                Err(e)
            }
        }
    }
}

/// Copies microphone samples into the file until stopped, timed from the start of the recording.
fn record_sound(reader: Mt<IMFSourceReader>, stream: u32, writer: Arc<Mutex<Mt<IMFSinkWriter>>>, stop: Arc<AtomicBool>, started: Instant) {
    com();
    let mut base: Option<(i64, i64)> = None; // (device time of the first sample, recording time then)
    while !stop.load(Ordering::Relaxed) {
        let (mut flags, mut ts, mut sample) = (0u32, 0i64, None);
        let read = unsafe {
            reader.0.ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut sample))
        };
        if read.is_err() || flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
            break;
        }
        let Some(sample) = sample else { continue };
        let (dev0, rec0) = *base.get_or_insert((ts, started.elapsed().as_nanos() as i64 / 100));
        unsafe {
            let _ = sample.SetSampleTime(ts - dev0 + rec0);
            let _ = writer.lock().unwrap().0.WriteSample(stream, &sample);
        }
    }
}

/// RGBA from Flutter into the BGRX frame of the video, scaled to fit if the window changed size.
fn fit(src: &[u8], sw: usize, sh: usize, dst: &mut Vec<u8>, w: usize, h: usize) {
    dst.clear();
    dst.resize(w * h * 4, 0);
    if sw == 0 || sh == 0 || src.len() < sw * sh * 4 {
        return;
    }
    let k = (w as f32 / sw as f32).min(h as f32 / sh as f32);
    let (tw, th) = (((sw as f32 * k) as usize).min(w), ((sh as f32 * k) as usize).min(h));
    let (ox, oy) = ((w - tw) / 2, (h - th) / 2);
    for y in 0..th {
        let sy = ((y as f32 + 0.5) / k) as usize;
        let row = &src[sy.min(sh - 1) * sw * 4..];
        let out = &mut dst[((oy + y) * w + ox) * 4..];
        for x in 0..tw {
            let s = ((x as f32 + 0.5) / k) as usize;
            let p = &row[s.min(sw - 1) * 4..];
            out[x * 4..x * 4 + 4].copy_from_slice(&[p[2], p[1], p[0], 255]);
        }
    }
}

pub fn frame(id: u32, rgba: &[u8], fw: u32, fh: u32, ms: u32) -> Result<()> {
    com();
    let mut recs = RECS.lock().unwrap();
    let r = recs.get_mut(&id).ok_or_else(|| Error::from(E_INVALIDARG))?;
    let t = ms as i64 * 10_000;
    if r.last.is_some_and(|l| t <= l) {
        return Ok(()); // times must keep increasing
    }
    fit(rgba, fw as usize, fh as usize, &mut r.frame, r.w as usize, r.h as usize);
    unsafe {
        let len = r.frame.len() as u32;
        let buf = MFCreateMemoryBuffer(len)?;
        let mut p = std::ptr::null_mut();
        buf.Lock(&mut p, None, None)?;
        std::ptr::copy_nonoverlapping(r.frame.as_ptr(), p, r.frame.len());
        buf.Unlock()?;
        buf.SetCurrentLength(len)?;
        let s = MFCreateSample()?;
        s.AddBuffer(&buf)?;
        s.SetSampleTime(t)?;
        s.SetSampleDuration(10_000_000 / r.fps as i64)?;
        r.writer.lock().unwrap().0.WriteSample(r.video, &s)?;
    }
    r.last = Some(t);
    Ok(())
}

/// Finishes the file; returns the length of the recording in milliseconds.
pub fn stop(id: u32) -> Result<u32> {
    com();
    let r = RECS.lock().unwrap().remove(&id).ok_or_else(|| Error::from(E_INVALIDARG))?;
    r.stop.store(true, Ordering::Relaxed);
    if let Some(t) = r.sound {
        let _ = t.join(); // the next microphone sample arrives within a few milliseconds
    }
    let done = unsafe { r.writer.lock().unwrap().0.Finalize() };
    unsafe {
        let _ = MFShutdown();
    }
    done?;
    Ok((r.last.unwrap_or(0) / 10_000) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Opens a recorded file with Windows itself: (video size, number of frames, has sound).
    unsafe fn read_back(path: &str) -> (u64, usize, bool) {
        com();
        MFStartup(MF_VERSION, MFSTARTUP_FULL).unwrap();
        let reader = MFCreateSourceReaderFromURL(&HSTRING::from(path), None).unwrap();
        let vs = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
        let t = reader.GetNativeMediaType(vs, 0).unwrap();
        assert_eq!(t.GetGUID(&MF_MT_SUBTYPE).unwrap(), MFVideoFormat_H264);
        let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap();
        let sound = reader
            .GetNativeMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32, 0)
            .is_ok_and(|a| a.GetGUID(&MF_MT_SUBTYPE).unwrap() == MFAudioFormat_AAC);
        let mut frames = 0;
        loop {
            let (mut flags, mut ts, mut s) = (0u32, 0i64, None);
            reader.ReadSample(vs, 0, None, Some(&mut flags), Some(&mut ts), Some(&mut s)).unwrap();
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                break;
            }
            frames += s.is_some() as usize;
        }
        drop(reader);
        let _ = MFShutdown();
        (size, frames, sound)
    }

    fn record(path: &str, audio: bool, frames: u32) -> u32 {
        let id = start(path, 321, 240, 15, audio).unwrap(); // odd width is made even
        let mut px = vec![255u8; 320 * 240 * 4];
        for i in 0..frames {
            px.fill(255);
            for y in 100..140 {
                for x in (i as usize * 8)..(i as usize * 8 + 40) {
                    let o = (y * 320 + x.min(319)) * 4;
                    px[o..o + 3].copy_from_slice(&[20, 20, 20]); // a dark square moving right
                }
            }
            frame(id, &px, 320, 240, i * 66).unwrap();
        }
        frame(id, &[255u8; 640 * 480 * 4], 640, 480, frames * 66).unwrap(); // window got bigger: fitted in
        frame(id, &px, 320, 240, frames * 66).unwrap(); // same time again: skipped
        stop(id).unwrap()
    }

    #[test]
    fn frames_become_an_mp4_that_windows_plays() {
        let path = std::env::temp_dir().join(format!("freenotes_rec_{}.mp4", std::process::id()));
        let p = path.to_str().unwrap();
        let ms = record(p, false, 30);
        assert_eq!(ms, 30 * 66);
        let (size, frames, sound) = unsafe { read_back(p) };
        let _ = std::fs::remove_file(&path);
        assert_eq!(size, pack(320, 240));
        assert!(frames >= 31, "{frames} frames in the file");
        assert!(!sound);
    }

    /// Records 2 s from the real microphone; only when FREENOTES_MIC_TEST=1 (needs a microphone).
    #[test]
    fn microphone_sound_is_recorded() {
        if std::env::var("FREENOTES_MIC_TEST").as_deref() != Ok("1") {
            return;
        }
        let path = std::env::temp_dir().join(format!("freenotes_mic_{}.mp4", std::process::id()));
        let p = path.to_str().unwrap();
        let id = start(p, 320, 240, 15, true).unwrap();
        let px = vec![255u8; 320 * 240 * 4];
        let t0 = Instant::now();
        for i in 0..30u32 {
            frame(id, &px, 320, 240, i * 66).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(66).saturating_sub(t0.elapsed() - std::time::Duration::from_millis(i as u64 * 66)));
        }
        stop(id).unwrap();
        let (_, _, sound) = unsafe { read_back(p) };
        let _ = std::fs::remove_file(&path);
        assert!(sound, "the file has an AAC sound track");
    }
}
