//! Compact file format for the strokes of a page: about 10x smaller than JSON and much faster.
//! Points are stored as differences to the previous point in small variable-length integers (at the
//! precision the stroke needs), pressure as one byte; the whole block is deflate-compressed.

/// Strokes of a page as parallel arrays (cheap to pass between Dart and Rust).
/// Stroke i: kinds[i], colors[i], sizes[i], sims[i] != 0, points[offsets[i]..offsets[i+1]] (x, y, pressure).
pub struct StrokeBatch {
    pub ids: Vec<u32>,
    pub kinds: Vec<u8>,
    pub colors: Vec<u32>,
    pub sizes: Vec<f32>,
    pub sims: Vec<u8>,
    pub offsets: Vec<u32>,
    pub points: Vec<f32>,
    /// Filled by decode: left, top, right, bottom per stroke (including its width).
    pub bounds: Vec<f32>,
}

const MAGIC: &[u8; 4] = b"FNZ1";

/// Decimal places kept for a stroke of this width (same rule as the JSON format).
fn precision(size: f32) -> u8 {
    ((8.0 / size.max(1e-6) as f64).log10().ceil()).clamp(1.0, 6.0) as u8
}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn put_signed(out: &mut Vec<u8>, v: i64) {
    put_varint(out, ((v << 1) ^ (v >> 63)) as u64); // zigzag: small negatives stay small
}

struct Reader<'a> {
    b: &'a [u8],
    i: usize,
}

impl Reader<'_> {
    fn byte(&mut self) -> Result<u8, String> {
        let v = *self.b.get(self.i).ok_or("Datei ist abgeschnitten")?;
        self.i += 1;
        Ok(v)
    }
    fn bytes<const N: usize>(&mut self) -> Result<[u8; N], String> {
        let s = self.b.get(self.i..self.i + N).ok_or("Datei ist abgeschnitten")?;
        self.i += N;
        Ok(s.try_into().unwrap())
    }
    fn varint(&mut self) -> Result<u64, String> {
        let (mut v, mut shift) = (0u64, 0);
        loop {
            let b = self.byte()?;
            if shift > 63 {
                return Err("Ungültige Zahl in der Datei".into());
            }
            v |= ((b & 0x7f) as u64) << shift;
            if b < 0x80 {
                return Ok(v);
            }
            shift += 7;
        }
    }
    fn signed(&mut self) -> Result<i64, String> {
        let v = self.varint()?;
        Ok(((v >> 1) as i64) ^ -((v & 1) as i64))
    }
}

/// Packs a page's strokes for saving.
pub fn encode_strokes(batch: StrokeBatch) -> Vec<u8> {
    let n = batch.kinds.len();
    let mut raw = Vec::with_capacity(batch.points.len() * 3 + n * 16);
    put_varint(&mut raw, n as u64);
    for i in 0..n {
        let size = batch.sizes[i];
        let digits = precision(size);
        let q = 10f64.powi(digits as i32);
        raw.push(batch.kinds[i]);
        raw.push(batch.sims[i] & 1);
        raw.extend_from_slice(&batch.colors[i].to_le_bytes());
        raw.extend_from_slice(&size.to_le_bytes());
        raw.push(digits);
        let pts = &batch.points[batch.offsets[i] as usize..batch.offsets[i + 1] as usize];
        put_varint(&mut raw, (pts.len() / 3) as u64);
        let (mut px, mut py) = (0i64, 0i64);
        for c in pts.chunks_exact(3) {
            let (x, y) = ((c[0] as f64 * q).round() as i64, (c[1] as f64 * q).round() as i64);
            put_signed(&mut raw, x - px);
            put_signed(&mut raw, y - py);
            raw.push((c[2].clamp(0.0, 1.0) * 255.0).round() as u8);
            (px, py) = (x, y);
        }
    }
    let mut out = MAGIC.to_vec();
    out.extend(miniz_oxide::deflate::compress_to_vec(&raw, 1)); // fastest level: the varint packing already did most of the work
    out
}

/// Reads strokes saved by [encode_strokes]; also computes each stroke's bounds.
pub fn decode_strokes(bytes: Vec<u8>) -> Result<StrokeBatch, String> {
    if bytes.len() < 4 || &bytes[..4] != MAGIC {
        return Err("Unbekanntes Strich-Format".into());
    }
    let raw = miniz_oxide::inflate::decompress_to_vec_with_limit(&bytes[4..], 1 << 31).map_err(|e| format!("Datei beschädigt: {e:?}"))?;
    let mut r = Reader { b: &raw, i: 0 };
    let n = r.varint()? as usize;
    if n > raw.len() {
        return Err("Datei beschädigt".into());
    }
    let mut b = StrokeBatch {
        ids: vec![0; n],
        kinds: Vec::with_capacity(n),
        colors: Vec::with_capacity(n),
        sizes: Vec::with_capacity(n),
        sims: Vec::with_capacity(n),
        offsets: Vec::with_capacity(n + 1),
        points: Vec::with_capacity(raw.len()),
        bounds: Vec::with_capacity(n * 4),
    };
    b.offsets.push(0);
    for _ in 0..n {
        b.kinds.push(r.byte()?);
        b.sims.push(r.byte()?);
        b.colors.push(u32::from_le_bytes(r.bytes::<4>()?));
        let size = f32::from_le_bytes(r.bytes::<4>()?);
        b.sizes.push(size);
        let q = 10f64.powi(r.byte()?.min(9) as i32);
        let count = r.varint()? as usize;
        if count > raw.len() {
            return Err("Datei beschädigt".into());
        }
        let (mut x, mut y) = (0i64, 0i64);
        let (mut l, mut t, mut rr, mut bb) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for _ in 0..count {
            x += r.signed()?;
            y += r.signed()?;
            let p = r.byte()? as f32 / 255.0;
            let (fx, fy) = ((x as f64 / q) as f32, (y as f64 / q) as f32);
            b.points.extend_from_slice(&[fx, fy, p]);
            (l, t, rr, bb) = (l.min(fx), t.min(fy), rr.max(fx), bb.max(fy));
        }
        b.offsets.push((b.points.len()) as u32);
        if count == 0 {
            b.bounds.extend_from_slice(&[0.0; 4]);
        } else {
            b.bounds.extend_from_slice(&[l - size, t - size, rr + size, bb + size]);
        }
    }
    Ok(b)
}

/// A rendered page (BGRA pixels, as PDFium gives them) as a JPEG for the PDF export:
/// several times smaller than the raw pixels packed with deflate, and quick to make.
pub fn encode_jpeg(bgra: Vec<u8>, width: u32, height: u32, quality: u8) -> Result<Vec<u8>, String> {
    let (w, h) = (u16::try_from(width).map_err(|_| "image too wide")?, u16::try_from(height).map_err(|_| "image too high")?);
    if bgra.len() != width as usize * height as usize * 4 {
        return Err("pixel data does not match the size".into());
    }
    let mut out = Vec::new();
    jpeg_encoder::Encoder::new(&mut out, quality)
        .encode(&bgra, w, h, jpeg_encoder::ColorType::Bgra)
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strokes_survive_encode_and_decode() {
        let batch = StrokeBatch {
            ids: vec![1, 2],
            kinds: vec![1, 5],
            colors: vec![0xFF1A1A1A, 0x80FF0000],
            sizes: vec![2.0, 0.02],
            sims: vec![1, 0],
            offsets: vec![0, 6, 9],
            points: vec![10.04, -20.06, 0.5, 15.5, 30.25, 1.0, 100.12345, 50.56789, 0.0],
            bounds: vec![],
        };
        let back = decode_strokes(encode_strokes(batch)).unwrap();
        assert_eq!(back.kinds, vec![1, 5]);
        assert_eq!(back.colors, vec![0xFF1A1A1A, 0x80FF0000]);
        assert_eq!(back.sims, vec![1, 0]);
        assert_eq!(back.offsets, vec![0, 6, 9]);
        let want = [10.0, -20.1, 0.5, 15.5, 30.3, 1.0, 100.123, 50.568, 0.0]; // rounded to the stroke's precision
        for (a, b) in back.points.iter().zip(want) {
            assert!((a - b).abs() < 0.003, "{a} vs {b}");
        }
        for (a, b) in back.bounds[..4].iter().zip([8.0, -22.1, 17.5, 32.3]) {
            assert!((a - b).abs() < 1e-4, "bounds {a} vs {b}");
        }
    }

    #[test]
    fn garbage_is_rejected_not_crashing() {
        assert!(decode_strokes(b"FNZ1garbage".to_vec()).is_err());
        assert!(decode_strokes(vec![1, 2, 3]).is_err());
    }

    #[test]
    fn page_picture_becomes_a_jpeg() {
        let (w, h) = (64u32, 32u32);
        let px: Vec<u8> = (0..w * h).flat_map(|i| [(i % 256) as u8, 128, 255, 255]).collect();
        let jpg = encode_jpeg(px.clone(), w, h, 90).unwrap();
        assert_eq!(&jpg[..2], &[0xFF, 0xD8], "JPEG start marker");
        assert!(jpg.len() < px.len());
        assert!(encode_jpeg(px, w + 1, h, 90).is_err(), "wrong size is refused");
    }
}
