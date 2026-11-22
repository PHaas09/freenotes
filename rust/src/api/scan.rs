//! Sharp text from scanned PDF pages at any zoom.
//!
//! A scan has no text, only pixels, so zooming in normally gives blurry letters. Like distance-field
//! font rendering, the smooth (bicubic) image is used as a map of "how inky" every point is: near a
//! letter edge each pixel is pushed to the local ink or paper colour with a one-screen-pixel soft edge,
//! so edges stay sharp however far you zoom. Flat areas and soft photos keep their plain colours.
//! Ink and paper colours come from the neighbourhood: its pixels are split into a dark and a light group
//! (two-means on brightness, like Otsu's method); ink = the darker half of the dark group, paper = the
//! light group of a wider area, so soft letter edges don't make text grey or leave light or dark halos.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, RwLock};

use flutter_rust_bridge::frb;
use rayon::prelude::*;

struct Scan {
    w: usize,
    h: usize,
    /// pixels per page unit of the scan image
    res: f64,
    rgb: Vec<[f32; 3]>,
    lum: Vec<f32>,
    ink: Vec<[f32; 3]>,
    paper: Vec<[f32; 3]>,
}

static SCANS: LazyLock<RwLock<HashMap<u32, Arc<Scan>>>> = LazyLock::new(Default::default);
static NEXT: AtomicU32 = AtomicU32::new(1);

fn lum(c: [f32; 3]) -> f32 {
    0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
}

/// For every pixel: (ink colour, paper colour) of its 11 x 11 neighbourhood.
fn ink_and_paper(rgb: &[[f32; 3]], lum: &[f32], w: usize, h: usize) -> (Vec<[f32; 3]>, Vec<[f32; 3]>) {
    const R: isize = 5;
    let mean = |acc: [f32; 4]| if acc[3] > 0.0 { [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3]] } else { [255.0; 3] };
    (0..h)
        .into_par_iter()
        .flat_map_iter(|y| {
            let mut win: Vec<usize> = Vec::with_capacity(121);
            (0..w)
                .map(|x| {
                    win.clear();
                    for dy in -R..=R {
                        let yy = (y as isize + dy).clamp(0, h as isize - 1) as usize;
                        for dx in -R..=R {
                            win.push(yy * w + (x as isize + dx).clamp(0, w as isize - 1) as usize);
                        }
                    }
                    let (mut lo, mut hi) = (f32::MAX, f32::MIN);
                    for &i in &win {
                        lo = lo.min(lum[i]);
                        hi = hi.max(lum[i]);
                    }
                    // two-means on brightness: threshold between the dark and the light group
                    let (mut thr, mut md, mut ml) = ((lo + hi) / 2.0, lo, hi);
                    for _ in 0..2 {
                        let (mut sd, mut nd, mut sl, mut nl) = (0.0, 0.0, 0.0, 0.0);
                        for &i in &win {
                            if lum[i] < thr {
                                (sd, nd) = (sd + lum[i], nd + 1.0);
                            } else {
                                (sl, nl) = (sl + lum[i], nl + 1.0);
                            }
                        }
                        if nd == 0.0 || nl == 0.0 {
                            break;
                        }
                        (md, ml) = (sd / nd, sl / nl);
                        thr = (md + ml) / 2.0;
                    }
                    // ink: darker half of the dark group, so soft letter edges don't turn the text grey
                    let mut ink = [0.0f32; 4];
                    for &i in &win {
                        if lum[i] <= md {
                            let c = rgb[i];
                            ink = [ink[0] + c[0], ink[1] + c[1], ink[2] + c[2], ink[3] + 1.0];
                        }
                    }
                    // paper: brighter half of the light group of a wider area (17 x 17, every 2nd pixel).
                    // Leaves out soft letter edges and the colour that JPEG smears next to coloured text.
                    let (mut sl, mut nl) = (0.0f32, 0.0f32);
                    let mut wide: [usize; 81] = [0; 81];
                    let mut n = 0;
                    for dy in (-8..=8).step_by(2) {
                        let yy = (y as isize + dy).clamp(0, h as isize - 1) as usize;
                        for dx in (-8..=8).step_by(2) {
                            let i = yy * w + (x as isize + dx).clamp(0, w as isize - 1) as usize;
                            if lum[i] >= thr {
                                wide[n] = i;
                                n += 1;
                                (sl, nl) = (sl + lum[i], nl + 1.0);
                            }
                        }
                    }
                    let upper = if nl > 0.0 { sl / nl } else { ml };
                    let mut paper = [0.0f32; 4];
                    for &i in &wide[..n] {
                        if lum[i] >= upper {
                            let c = rgb[i];
                            paper = [paper[0] + c[0], paper[1] + c[1], paper[2] + c[2], paper[3] + 1.0];
                        }
                    }
                    (mean(ink), mean(paper))
                })
                .collect::<Vec<_>>()
        })
        .unzip()
}

fn blur(img: &[[f32; 3]], w: usize, h: usize, sigma: f32) -> Vec<[f32; 3]> {
    let rad = (sigma * 3.0).ceil() as isize;
    let k: Vec<f32> = (-rad..=rad).map(|i| (-(i * i) as f32 / (2.0 * sigma * sigma)).exp()).collect();
    let sum: f32 = k.iter().sum();
    let k: Vec<f32> = k.iter().map(|v| v / sum).collect();
    let pass = |src: &[[f32; 3]], horizontal: bool| -> Vec<[f32; 3]> {
        (0..h)
            .into_par_iter()
            .flat_map_iter(|y| {
                let k = &k;
                (0..w).map(move |x| {
                    let mut acc = [0.0f32; 3];
                    for (j, kv) in k.iter().enumerate() {
                        let d = j as isize - rad;
                        let i = if horizontal {
                            y * w + (x as isize + d).clamp(0, w as isize - 1) as usize
                        } else {
                            (y as isize + d).clamp(0, h as isize - 1) as usize * w + x
                        };
                        for c in 0..3 {
                            acc[c] += src[i][c] * kv;
                        }
                    }
                    acc
                })
            })
            .collect()
    };
    pass(&pass(img, true), false)
}

/// Registers a scanned page image (RGBA, or BGRA as PDFium renders it; `res` pixels per page unit)
/// and prepares its colour maps. Returns a handle for [scan_render]. Takes a moment; runs off the UI thread.
pub fn scan_load(pixels: Vec<u8>, width: u32, height: u32, res: f64, bgra: bool) -> u32 {
    let (w, h) = (width as usize, height as usize);
    let (r, b) = if bgra { (2, 0) } else { (0, 2) };
    let rgb: Vec<[f32; 3]> = pixels.chunks_exact(4).take(w * h).map(|p| [p[r] as f32, p[1] as f32, p[b] as f32]).collect();
    let lum_v: Vec<f32> = rgb.par_iter().map(|c| lum(*c)).collect();
    let (ink, paper) = ink_and_paper(&rgb, &lum_v, w, h);
    let (ink, paper) = (blur(&ink, w, h, 1.0), blur(&paper, w, h, 1.0));
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    SCANS.write().unwrap().insert(id, Arc::new(Scan { w, h, res, rgb, lum: lum_v, ink, paper }));
    id
}

#[frb(sync)]
pub fn scan_drop(scan: u32) {
    SCANS.write().unwrap().remove(&scan);
}

/// Catmull-Rom (sharp) and cubic B-spline (smooth) weights for a fractional position t.
fn weights(t: f32) -> ([f32; 4], [f32; 4]) {
    let (t2, t3) = (t * t, t * t * t);
    let cr = [(-t3 + 2.0 * t2 - t) / 2.0, (3.0 * t3 - 5.0 * t2 + 2.0) / 2.0, (-3.0 * t3 + 4.0 * t2 + t) / 2.0, (t3 - t2) / 2.0];
    let it = 1.0 - t;
    let bs = [it * it * it / 6.0, (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0, (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0, t3 / 6.0];
    (cr, bs)
}

/// Draws the square of page space at (x0, y0) with `unit` pixels per page unit as `px` x `px`
/// premultiplied RGBA, with sharpened text.
pub fn scan_render(scan: u32, x0: f64, y0: f64, unit: f64, px: u32) -> Vec<u8> {
    let Some(s) = SCANS.read().unwrap().get(&scan).cloned() else { return vec![] };
    let n = px as usize;
    let zoom = (unit / s.res) as f32; // screen pixels per scan pixel
    let w_edge = (1.0 / zoom).min(0.5); // about one screen pixel
    let clampi = |v: isize, hi: usize| v.clamp(0, hi as isize - 1) as usize;
    let mut out = vec![0u8; n * n * 4];
    out.par_chunks_mut(n * 4).enumerate().for_each(|(row, line)| {
        let sy = ((y0 + (row as f64 + 0.5) / unit) * s.res - 0.5) as f32;
        let (iy, fy) = (sy.floor() as isize, sy - sy.floor());
        let (cry, bsy) = weights(fy);
        for col in 0..n {
            let sx = ((x0 + (col as f64 + 0.5) / unit) * s.res - 0.5) as f32;
            if sx < -0.5 || sy < -0.5 || sx > s.w as f32 - 0.5 || sy > s.h as f32 - 0.5 {
                continue; // outside the page: transparent
            }
            let (ix, fx) = (sx.floor() as isize, sx - sx.floor());
            let (crx, bsx) = weights(fx);
            let (mut c, mut sm) = ([0.0f32; 3], 0.0f32);
            for j in 0..4 {
                let yy = clampi(iy - 1 + j as isize, s.h);
                for i in 0..4 {
                    let idx = yy * s.w + clampi(ix - 1 + i as isize, s.w);
                    let (wc, ws) = (crx[i] * cry[j], bsx[i] * bsy[j]);
                    for k in 0..3 {
                        c[k] += s.rgb[idx][k] * wc;
                    }
                    sm += s.lum[idx] * ws;
                }
            }
            // ink and paper colour: bilinear
            let (bx, by) = (clampi(ix, s.w), clampi(iy, s.h));
            let (bx1, by1) = (clampi(ix + 1, s.w), clampi(iy + 1, s.h));
            let bil = |m: &Vec<[f32; 3]>| {
                let (a, b, cc, d) = (m[by * s.w + bx], m[by * s.w + bx1], m[by1 * s.w + bx], m[by1 * s.w + bx1]);
                let mut r = [0.0f32; 3];
                for k in 0..3 {
                    r[k] = (a[k] * (1.0 - fx) + b[k] * fx) * (1.0 - fy) + (cc[k] * (1.0 - fx) + d[k] * fx) * fy;
                }
                r
            };
            let (ink, paper) = (bil(&s.ink), bil(&s.paper));
            let (li, lp) = (lum(ink), lum(paper));
            let contrast = (lp - li) / 255.0;
            let mut col_rgb = c;
            if contrast >= 0.12 {
                let t = ((sm - li) / (lp - li)).clamp(0.0, 1.0);
                let e = ((t - 0.5) / (2.0 * w_edge) + 0.5).clamp(0.0, 1.0);
                let st = e * e * (3.0 - 2.0 * e);
                let k = ((contrast - 0.12) / 0.06).min(1.0);
                for ch in 0..3 {
                    col_rgb[ch] = (ink[ch] + (paper[ch] - ink[ch]) * st) * k + c[ch] * (1.0 - k);
                }
            }
            let o = col * 4;
            line[o] = col_rgb[0].clamp(0.0, 255.0) as u8;
            line[o + 1] = col_rgb[1].clamp(0.0, 255.0) as u8;
            line[o + 2] = col_rgb[2].clamp(0.0, 255.0) as u8;
            line[o + 3] = 255;
        }
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A thin blurry dark line on white, like a letter stroke in a low-resolution scan (stems are 1-3 px).
    fn blurry_bar(w: usize, h: usize) -> Vec<u8> {
        let mut v = vec![];
        for _y in 0..h {
            for x in 0..w {
                let d = (x as f32 - 20.0).abs();
                let g = (255.0 * ((d - 0.5) / 1.5).clamp(0.0, 1.0)) as u8; // 1 px core, 1.5 px soft edge
                v.extend_from_slice(&[g, g, g, 255]);
            }
        }
        v
    }

    #[test]
    fn zoomed_in_edges_are_sharp() {
        let (w, h) = (40, 40);
        let id = scan_load(blurry_bar(w, h), w as u32, h as u32, 1.0, false);
        let px = scan_render(id, 0.0, 10.0, 16.0, 512); // 16x zoom: one scan pixel = 16 screen pixels
        let row: Vec<u8> = (0..512).map(|x| px[(100 * 512 + x) * 4]).collect();
        // the same row, only smoothly enlarged (Catmull-Rom), as without sharpening
        let src: Vec<f32> = blurry_bar(w, 1).chunks(4).map(|p| p[0] as f32).collect();
        let plain: Vec<f32> = (0..512)
            .map(|x| {
                let sx = (x as f32 + 0.5) / 16.0 - 0.5;
                let (i, f) = (sx.floor() as isize, sx - sx.floor());
                let (cr, _) = weights(f);
                (0..4).map(|j| src[(i - 1 + j as isize).clamp(0, w as isize - 1) as usize] * cr[j]).sum()
            })
            .collect();
        // count grey pixels (neither ink nor paper) across the left edge of the bar
        let grey = row[200..330].iter().filter(|&&g| g > 40 && g < 215).count();
        let grey_plain = plain[200..330].iter().filter(|&&g| g > 40.0 && g < 215.0).count();
        assert!(grey * 2 <= grey_plain, "edge {grey} px wide, without sharpening {grey_plain} px");
        assert!(row[20 * 16] < 40, "middle of the bar stays dark");
        assert!(row[2 * 16] > 215, "paper stays white");
        scan_drop(id);
    }
}
