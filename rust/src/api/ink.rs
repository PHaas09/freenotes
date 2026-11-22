//! Pen shapes, shape recognition and cutting strokes (precise eraser).
use flutter_rust_bridge::frb;

use crate::freehand::{self, Options, P};

/// Pen kinds are stored in notebook files as numbers (0 ballpoint, 1 fountain, 2 pencil, 3 highlighter,
/// 4 brush, 5 calligraphy, 6 fineliner); never change them.
pub(crate) const HIGHLIGHTER: u8 = 3;
pub(crate) const CALLIGRAPHY: u8 = 5;

/// (thinning, smoothing, streamline, tapered ends)
fn pen(kind: u8) -> (f64, f64, f64, bool) {
    match kind {
        1 => (0.65, 0.5, 0.35, false), // fountain pen
        2 => (0.3, 0.5, 0.35, false),  // pencil
        3 => (0.0, 0.5, 0.35, false),  // highlighter
        4 => (0.75, 0.6, 0.5, true),   // brush
        5 => (0.0, 0.5, 0.45, false),  // calligraphy (own outline)
        6 => (0.0, 0.5, 0.45, false),  // fineliner
        _ => (0.15, 0.5, 0.35, false), // ballpoint
    }
}

/// Opacity of a pen kind's ink.
pub(crate) fn pen_alpha(kind: u8) -> f32 {
    match kind {
        2 => 0.75,
        3 => 0.35,
        _ => 1.0,
    }
}

pub(crate) fn to_points(pts: &[f32]) -> Vec<P> {
    pts.chunks_exact(3).map(|c| P { x: c[0] as f64, y: c[1] as f64, p: c[2] as f64 }).collect()
}

/// The filled shape(s) of a stroke in page units.
pub(crate) fn polygons(kind: u8, size: f64, sim: bool, pts: &[f32], complete: bool) -> Vec<Vec<P>> {
    let input = to_points(pts);
    if input.is_empty() {
        return vec![];
    }
    let (thinning, smoothing, streamline, taper) = pen(kind);
    let o = Options {
        size,
        thinning,
        smoothing,
        streamline,
        simulate_pressure: sim && (thinning > 0.0 || kind == CALLIGRAPHY),
        taper,
        complete,
    };
    if kind == CALLIGRAPHY {
        return freehand::calligraphy(&input, &o);
    }
    let out = freehand::outline(&input, &o);
    if out.len() > 2 { vec![out] } else { vec![] }
}

/// Outline polygons, flattened: polygon i is points[starts[i]*2 .. starts[i+1]*2] (the last runs to the end).
pub struct Outline {
    pub points: Vec<f32>,
    pub starts: Vec<u32>,
}

/// Outline of a stroke for drawing; `complete` is false while the pen is still down.
#[frb(sync)]
pub fn stroke_outline(kind: u8, size: f64, sim: bool, points: Vec<f32>, complete: bool) -> Outline {
    let mut out = Outline { points: vec![], starts: vec![] };
    for poly in polygons(kind, size, sim, &points, complete) {
        out.starts.push((out.points.len() / 2) as u32);
        for p in poly {
            out.points.push(p.x as f32);
            out.points.push(p.y as f32);
        }
    }
    out
}

fn dist(a: (f64, f64), b: (f64, f64)) -> f64 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

fn seg_dist(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0.0 { 0.0 } else { (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0) };
    dist(p, (a.0 + dx * t, a.1 + dy * t))
}

/// Ramer-Douglas-Peucker on an open polyline: keeps the corners.
fn rdp(pts: &[(f64, f64)], eps: f64, out: &mut Vec<(f64, f64)>) {
    if pts.len() < 3 {
        out.extend_from_slice(&pts[..pts.len().saturating_sub(1)]);
        return;
    }
    let (a, b) = (pts[0], *pts.last().unwrap());
    let (mut far, mut idx) = (0.0, 0);
    for (i, &p) in pts.iter().enumerate().take(pts.len() - 1).skip(1) {
        let d = seg_dist(p, a, b);
        if d > far {
            far = d;
            idx = i;
        }
    }
    if far > eps {
        rdp(&pts[..=idx], eps, out);
        rdp(&pts[idx..], eps, out);
    } else {
        out.push(a);
    }
}

fn sample(corners: &[(f64, f64)], closed: bool, step: f64) -> Vec<f32> {
    let mut out = vec![];
    let n = corners.len();
    let segs = if closed { n } else { n - 1 };
    for i in 0..segs {
        let (a, b) = (corners[i], corners[(i + 1) % n]);
        let k = (dist(a, b) / step).ceil().max(1.0) as usize;
        for j in 0..k {
            let t = j as f64 / k as f64;
            out.extend_from_slice(&[(a.0 + (b.0 - a.0) * t) as f32, (a.1 + (b.1 - a.1) * t) as f32, 0.5]);
        }
    }
    let end = if closed { corners[0] } else { corners[n - 1] };
    out.extend_from_slice(&[end.0 as f32, end.1 as f32, 0.5]);
    out
}

/// Shape tool: if a hand-drawn stroke is roughly a line, circle, ellipse, triangle, rectangle or a
/// polygon with up to 6 corners, returns the clean shape as new points (x, y, pressure); else None.
#[frb(sync)]
pub fn recognize_shape(points: Vec<f32>, size: f64) -> Option<Vec<f32>> {
    let pts: Vec<(f64, f64)> = points.chunks_exact(3).map(|c| (c[0] as f64, c[1] as f64)).collect();
    if pts.len() < 3 {
        return None;
    }
    let (mut l, mut t, mut r, mut b) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for &(x, y) in &pts {
        l = l.min(x);
        r = r.max(x);
        t = t.min(y);
        b = b.max(y);
    }
    let (w, h) = (r - l, b - t);
    let diag = w.hypot(h);
    if diag < size * 4.0 {
        return None;
    }
    let step = (size * 0.5).max(diag / 300.0);
    let (first, last) = (pts[0], *pts.last().unwrap());

    if dist(first, last) > 0.25 * diag {
        // open: a straight line?
        let len = dist(first, last);
        let dev = pts.iter().map(|&p| seg_dist(p, first, last)).fold(0.0, f64::max);
        if len < 0.8 * diag || dev > 0.06 * len + size * 0.5 {
            return None;
        }
        let ang = (last.1 - first.1).atan2(last.0 - first.0);
        let snap = (ang / std::f64::consts::FRAC_PI_4).round() * std::f64::consts::FRAC_PI_4;
        let end = if (ang - snap).abs() < 4f64.to_radians() { (first.0 + len * snap.cos(), first.1 + len * snap.sin()) } else { last };
        return Some(sample(&[first, end], false, step));
    }

    // closed: an ellipse or circle?
    let (cx, cy, rx, ry) = ((l + r) / 2.0, (t + b) / 2.0, w / 2.0, h / 2.0);
    if rx > 0.0 && ry > 0.0 {
        let err = pts.iter().map(|&(x, y)| (((x - cx) / rx).hypot((y - cy) / ry) - 1.0).abs()).sum::<f64>() / pts.len() as f64;
        if err < 0.09 {
            let (rx, ry) = if (rx - ry).abs() < 0.15 * rx.max(ry) { ((rx + ry) / 2.0, (rx + ry) / 2.0) } else { (rx, ry) };
            let n = ((std::f64::consts::TAU * rx.max(ry)) / step).ceil().max(48.0) as usize;
            let ring: Vec<(f64, f64)> = (0..n)
                .map(|i| {
                    let a = std::f64::consts::TAU * i as f64 / n as f64;
                    (cx + rx * a.cos(), cy + ry * a.sin())
                })
                .collect();
            return Some(sample(&ring, true, step));
        }
    }

    // a polygon: split the loop at the point farthest from the start and simplify both halves
    let far = (0..pts.len()).max_by(|&i, &j| dist(pts[i], first).total_cmp(&dist(pts[j], first))).unwrap();
    let mut corners = vec![];
    rdp(&pts[..=far], 0.08 * diag, &mut corners);
    let mut back = pts[far..].to_vec();
    back.push(first);
    rdp(&back, 0.08 * diag, &mut corners);
    let mut merged: Vec<(f64, f64)> = vec![];
    for c in corners {
        if merged.last().is_none_or(|&m| dist(m, c) > 0.12 * diag) {
            merged.push(c);
        }
    }
    if merged.len() > 2 && dist(merged[0], *merged.last().unwrap()) < 0.12 * diag {
        merged.pop();
    }
    match merged.len() {
        4 => {
            // nearly axis-aligned with right angles: a clean rectangle
            let axis = (0..4).all(|i| {
                let (a, b) = (merged[i], merged[(i + 1) % 4]);
                let ang = (b.1 - a.1).atan2(b.0 - a.0).abs() % std::f64::consts::FRAC_PI_2;
                ang < 12f64.to_radians() || ang > 78f64.to_radians()
            });
            let rect = [(l, t), (r, t), (r, b), (l, b)];
            Some(sample(if axis { &rect } else { &merged }, true, step))
        }
        3 | 5 | 6 => Some(sample(&merged, true, step)),
        _ => None,
    }
}

/// Where segment a->b is inside the circle (c, r), as parameters 0..1 along the segment.
fn inside_interval(a: (f64, f64), b: (f64, f64), c: (f64, f64), r: f64) -> Option<(f64, f64)> {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (fx, fy) = (a.0 - c.0, a.1 - c.1);
    let qa = dx * dx + dy * dy;
    let qb = 2.0 * (fx * dx + fy * dy);
    let qc = fx * fx + fy * fy - r * r;
    if qa == 0.0 {
        return if qc <= 0.0 { Some((0.0, 1.0)) } else { None };
    }
    let disc = qb * qb - 4.0 * qa * qc;
    if disc < 0.0 {
        return None;
    }
    let s = disc.sqrt();
    let (t1, t2) = ((-qb - s) / (2.0 * qa), (-qb + s) / (2.0 * qa));
    let (lo, hi) = (t1.max(0.0), t2.min(1.0));
    if lo > hi { None } else { Some((lo, hi)) }
}

/// Precise eraser: the parts of a stroke outside the circle (x, y, r). None if the circle misses it.
pub(crate) fn cut(points: &[f32], x: f64, y: f64, r: f64) -> Option<Vec<Vec<f32>>> {
    let pts = to_points(points);
    let c = (x, y);
    if pts.len() == 1 {
        return if dist((pts[0].x, pts[0].y), c) <= r { Some(vec![]) } else { None };
    }
    let lerp = |a: P, b: P, t: f64| [(a.x + (b.x - a.x) * t) as f32, (a.y + (b.y - a.y) * t) as f32, (a.p + (b.p - a.p) * t) as f32];
    let mut pieces: Vec<Vec<f32>> = vec![];
    let mut cur: Vec<f32> = if dist((pts[0].x, pts[0].y), c) > r { vec![pts[0].x as f32, pts[0].y as f32, pts[0].p as f32] } else { vec![] };
    let mut touched = false;
    for w in pts.windows(2) {
        let (a, b) = (w[0], w[1]);
        match inside_interval((a.x, a.y), (b.x, b.y), c, r) {
            None => cur.extend_from_slice(&[b.x as f32, b.y as f32, b.p as f32]),
            Some((s, e)) => {
                touched = true;
                if s > 0.0 {
                    cur.extend_from_slice(&lerp(a, b, s));
                }
                if cur.len() >= 6 {
                    pieces.push(std::mem::take(&mut cur));
                }
                cur.clear();
                if e < 1.0 {
                    cur.extend_from_slice(&lerp(a, b, e));
                    cur.extend_from_slice(&[b.x as f32, b.y as f32, b.p as f32]);
                }
            }
        }
    }
    if !touched {
        return None;
    }
    if cur.len() >= 6 {
        pieces.push(cur);
    }
    Some(pieces)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pts(xy: impl Iterator<Item = (f64, f64)>) -> Vec<f32> {
        xy.flat_map(|(x, y)| [x as f32, y as f32, 0.5]).collect()
    }

    #[test]
    fn wobbly_line_becomes_straight_and_snaps_to_horizontal() {
        let p = pts((0..50).map(|i| (i as f64 * 4.0, 100.0 + (i as f64 * 1.7).sin() * 2.0 + i as f64 * 0.05)));
        let s = recognize_shape(p, 2.0).expect("line");
        let ys: Vec<f32> = s.chunks(3).map(|c| c[1]).collect();
        assert!(ys.iter().all(|&y| (y - ys[0]).abs() < 1e-3), "snapped to horizontal");
    }

    #[test]
    fn rough_circle_becomes_a_circle() {
        let p = pts((0..80).map(|i| {
            let a = i as f64 / 79.0 * std::f64::consts::TAU;
            let r = 100.0 + (i as f64 * 0.9).sin() * 4.0;
            (300.0 + r * a.cos(), 300.0 + r * a.sin())
        }));
        let s = recognize_shape(p, 2.0).expect("circle");
        for c in s.chunks(3) {
            let d = ((c[0] - 300.0).powi(2) + (c[1] - 300.0).powi(2)).sqrt();
            assert!((d - 100.0).abs() < 6.0, "radius {d}");
        }
    }

    #[test]
    fn hand_drawn_rectangle_and_triangle_are_recognized() {
        let mut rect = vec![];
        for (a, b) in [((0.0, 0.0), (200.0, 3.0)), ((200.0, 3.0), (198.0, 100.0)), ((198.0, 100.0), (2.0, 98.0)), ((2.0, 98.0), (0.0, 2.0))] {
            for i in 0..20 {
                let t = i as f64 / 20.0;
                rect.push((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t));
            }
        }
        let s = recognize_shape(pts(rect.into_iter()), 2.0).expect("rectangle");
        assert!(s.chunks(3).all(|c| (c[0] - 0.0).abs() < 0.01 || (c[0] - 200.0).abs() < 0.01 || (c[1] - 0.0).abs() < 0.01 || (c[1] - 100.0).abs() < 0.01));

        let mut tri = vec![];
        for (a, b) in [((0.0, 200.0), (100.0, 0.0)), ((100.0, 0.0), (200.0, 200.0)), ((200.0, 200.0), (3.0, 198.0))] {
            for i in 0..25 {
                let t = i as f64 / 25.0;
                tri.push((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t));
            }
        }
        assert!(recognize_shape(pts(tri.into_iter()), 2.0).is_some(), "triangle");
    }

    #[test]
    fn scribble_is_left_alone() {
        let p = pts((0..60).map(|i| (i as f64 * 5.0, if i % 2 == 0 { 0.0 } else { 40.0 })));
        assert!(recognize_shape(p, 2.0).is_none());
    }

    #[test]
    fn cut_removes_the_middle_and_keeps_both_ends() {
        let line = pts((0..=10).map(|i| (i as f64 * 10.0, 0.0)));
        let pieces = cut(&line, 50.0, 0.0, 12.0).expect("touched");
        assert_eq!(pieces.len(), 2);
        assert!((pieces[0][pieces[0].len() - 3] - 38.0).abs() < 1e-3, "left piece ends at the circle");
        assert!((pieces[1][0] - 62.0).abs() < 1e-3, "right piece starts at the circle");
        assert!(cut(&line, 50.0, 30.0, 5.0).is_none(), "missed");
    }
}
