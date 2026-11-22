//! Stroke outlines. A port of perfect-freehand (MIT, (c) 2021 Stephen Ruiz, Dart port (c) 2023 Adil Hanney)
//! - the same algorithm FreeNotes used before, so existing notes look the same - plus the flat-nib
//! calligraphy pen. All math in f64 like the original.
//!
//! perfect-freehand license (applies to the ported outline algorithm):
//!
//! MIT License
//!
//! Copyright (c) 2021 Stephen Ruiz
//! Copyright (c) 2023 Adil Hanney
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.

use std::f64::consts::PI;

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct P {
    pub x: f64,
    pub y: f64,
    pub p: f64,
}

impl P {
    fn new(x: f64, y: f64, p: f64) -> P {
        P { x, y, p }
    }
    fn add(self, o: P) -> P {
        P::new(self.x + o.x, self.y + o.y, self.p)
    }
    fn sub(self, o: P) -> P {
        P::new(self.x - o.x, self.y - o.y, o.p)
    }
    fn mul(self, k: f64) -> P {
        P::new(self.x * k, self.y * k, self.p)
    }
    fn neg(self) -> P {
        P::new(-self.x, -self.y, self.p)
    }
    fn per(self) -> P {
        P::new(self.y, -self.x, self.p)
    }
    fn dpr(self, o: P) -> f64 {
        self.x * o.x + self.y * o.y
    }
    fn dist2(self, o: P) -> f64 {
        let (dx, dy) = (self.x - o.x, self.y - o.y);
        dx * dx + dy * dy
    }
    fn dist(self, o: P) -> f64 {
        self.dist2(o).sqrt()
    }
    fn unit(self) -> P {
        let l = (self.x * self.x + self.y * self.y).sqrt();
        if l == 0.0 { P::new(0.0, 0.0, self.p) } else { P::new(self.x / l, self.y / l, self.p) }
    }
    /// Unit vector from self to `o`.
    fn unit_to(self, o: P) -> P {
        let (dx, dy) = (o.x - self.x, o.y - self.y);
        if dx == 0.0 && dy == 0.0 {
            return P::new(0.0, 0.0, 0.5);
        }
        let d = (dx * dx + dy * dy).sqrt();
        P::new(dx / d, dy / d, 0.5)
    }
    fn lerp(self, t: f64, o: P) -> P {
        // Flutter's lerpDouble: a * (1 - t) + b * t
        let l = |a: f64, b: f64| if a == b { a } else { a * (1.0 - t) + b * t };
        P::new(l(self.x, o.x), l(self.y, o.y), l(self.p, o.p))
    }
    fn rot_around(self, c: P, r: f64) -> P {
        let (s, co) = r.sin_cos();
        let (px, py) = (self.x - c.x, self.y - c.y);
        P::new(px * co - py * s + c.x, px * s + py * co + c.y, self.p)
    }
    fn project(self, dir: P, d: f64) -> P {
        P::new(self.x + dir.x * d, self.y + dir.y * d, self.p)
    }
}

pub struct Options {
    pub size: f64,
    pub thinning: f64,
    pub smoothing: f64,
    pub streamline: f64,
    pub simulate_pressure: bool,
    pub taper: bool, // taper start and end (brush)
    pub complete: bool,
}

#[derive(Clone, Copy)]
struct SP {
    point: P,
    vector: P,
    distance: f64,
    running: f64,
}

const RATE_OF_PRESSURE_CHANGE: f64 = 0.275;

fn simulate(distance: f64, prev: f64, size: f64) -> f64 {
    let sp = (distance / size).min(1.0);
    let rp = (1.0 - sp).min(1.0);
    (prev + (rp - prev) * (sp * RATE_OF_PRESSURE_CHANGE)).min(1.0)
}

fn radius(size: f64, thinning: f64, pressure: f64) -> f64 {
    size * (0.5 - thinning * (0.5 - pressure))
}

fn stroke_points(input: &[P], o: &Options) -> Vec<SP> {
    if input.is_empty() {
        return vec![];
    }
    let t = 0.15 + (1.0 - o.streamline) * 0.85;
    let mut pts: Vec<P> = input.to_vec();
    if pts.len() == 2 && pts[0] == pts[1] {
        pts.pop();
    }
    if pts.len() == 2 {
        let (first, last) = (pts[0], pts.pop().unwrap());
        for i in 1..5 {
            pts.push(first.lerp(i as f64 / 4.0, last));
        }
    }
    if pts.len() == 1 {
        let f = pts[0];
        pts.push(P::new(f.x + 1.0, f.y + 1.0, f.p));
    }
    let mut out = vec![SP { point: pts[0], vector: P::new(1.0, 1.0, 0.5), distance: 0.0, running: 0.0 }];
    let mut reached = false;
    let mut running = 0.0;
    let max = pts.len() - 1;
    for i in 0..pts.len() {
        let prev = *out.last().unwrap();
        let point = if o.complete && i == max { pts[i] } else { prev.point.lerp(t, pts[i]) };
        if point == prev.point {
            continue;
        }
        let distance = point.dist(prev.point);
        running += distance;
        if i < max && !reached {
            if running < o.size {
                continue;
            }
            reached = true;
        }
        out.push(SP { point, vector: point.unit_to(prev.point), distance, running });
    }
    out[0].vector = if out.len() > 1 { out[1].vector } else { P::new(0.0, 0.0, 0.5) };
    out
}

fn ease_out_quad(t: f64) -> f64 {
    t * (2.0 - t)
}
fn ease_out_cubic(t: f64) -> f64 {
    let t = t - 1.0;
    t * t * t + 1.0
}

/// Outline polygon of a stroke (perfect-freehand `getStroke`).
pub fn outline(input: &[P], o: &Options) -> Vec<P> {
    let points = stroke_points(input, o);
    if points.is_empty() || o.size <= 0.0 {
        return vec![];
    }
    let total = points.last().unwrap().running;
    let (taper_start, taper_end) = if o.taper { (o.size.max(total), o.size.max(total)) } else { (0.0, 0.0) };
    let min_distance = (o.size * o.smoothing).powi(2);
    let mut left: Vec<P> = vec![];
    let mut right: Vec<P> = vec![];

    let mut prev_pressure = {
        let mut smoothed = points[0].point.p;
        for c in &points[0..10.min(points.len() - 1)] {
            let pr = if o.simulate_pressure { simulate(c.distance, smoothed, o.size) } else { c.point.p };
            smoothed = (smoothed + pr) / 2.0;
        }
        smoothed
    };
    let mut rad = radius(o.size, o.thinning, points.last().unwrap().point.p);
    let mut first_radius: Option<f64> = None;
    let mut prev_vector = points[0].vector;
    let mut pl = points[0].point;
    let mut pr = pl;
    let mut is_prev_sharp = false;

    for i in 0..points.len() {
        let (point, vector, running) = (points[i].point, points[i].vector, points[i].running);
        if i < points.len() - 1 && o.complete && !is_prev_sharp && total - running < o.size / 2.0 {
            continue;
        }
        if o.thinning != 0.0 {
            let pressure = if o.simulate_pressure {
                let p = simulate(points[i].distance, prev_pressure, o.size);
                prev_pressure = p;
                p
            } else {
                point.p
            };
            rad = radius(o.size, o.thinning, pressure);
        } else {
            rad = o.size / 2.0;
        }
        if first_radius.is_none() {
            first_radius = Some(rad);
        }
        let ts = if running < taper_start { ease_out_quad(running / taper_start) } else { 1.0 };
        let te = if total - running < taper_end { ease_out_cubic((total - running) / taper_end) } else { 1.0 };
        rad = (rad * ts.min(te)).max(0.01);

        let next_vector = if i < points.len() - 1 { points[i + 1].vector } else { vector };
        let next_dpr = if i < points.len() - 1 { vector.dpr(next_vector) } else { 1.0 };
        let prev_dpr = vector.dpr(prev_vector);
        let max_dpr = o.size / 128.0;
        let is_point_sharp = prev_dpr < max_dpr && !is_prev_sharp;
        let is_next_sharp = next_dpr < max_dpr;

        if is_point_sharp || is_next_sharp {
            let prev_offset = prev_vector.per().mul(rad);
            let step = 1.0 / 13.0;
            let mut t = 0.0;
            while t <= 1.0 {
                left.push(point.sub(prev_offset).rot_around(point, PI * t));
                right.push(point.add(prev_offset).rot_around(point, PI * -t));
                t += step;
            }
            let next_offset = next_vector.per().mul(rad);
            let tl = point.add(next_offset).rot_around(point, -PI);
            let tr = point.sub(next_offset).rot_around(point, PI);
            left.push(tl);
            right.push(tr);
            pl = tr;
            pr = tl;
            if is_next_sharp {
                is_prev_sharp = true;
            }
            continue;
        }
        is_prev_sharp = false;

        if i == points.len() - 1 {
            let off = vector.per().mul(rad);
            left.push(point.sub(off));
            right.push(point.add(off));
            continue;
        }
        let off = next_vector.lerp(next_dpr, vector).per().mul(rad);
        let tl = point.sub(off);
        if i <= 1 || pl.dist2(tl) > min_distance {
            left.push(tl);
            pl = tl;
        }
        let tr = point.add(off);
        if i <= 1 || pr.dist2(tr) > min_distance {
            right.push(tr);
            pr = tr;
        }
        prev_vector = vector;
    }

    let first_point = points[0].point;
    let last_point = if points.len() > 1 { points.last().unwrap().point } else { first_point.add(points[0].vector) };
    let mut start_cap = vec![];
    let mut end_cap = vec![];

    if points.len() == 1 {
        if !(taper_start > 0.0 || taper_end > 0.0) || o.complete {
            let start = first_point.project(first_point.sub(last_point).per().unit(), -first_radius.unwrap_or(rad));
            let step = 1.0 / 13.0;
            let mut dot = vec![];
            let mut t = step;
            while t <= 1.0 {
                dot.push(start.rot_around(first_point, PI * 2.0 * t));
                t += step;
            }
            return dot;
        }
    } else if taper_start > 0.0 || (taper_end > 0.0 && points.len() == 1) {
        // tapered start: no cap
    } else if let Some(&r0) = right.first() {
        let step = 1.0 / 13.0;
        let mut t = step;
        while t <= 1.0 {
            start_cap.push(r0.rot_around(first_point, PI * t));
            t += step;
        }
    }

    let direction = points.last().unwrap().vector.neg().per();
    if taper_end > 0.0 || (taper_start > 0.0 && points.len() == 1) {
        end_cap.push(last_point);
    } else {
        let start = last_point.project(direction, rad);
        let step = 1.0 / 29.0;
        let mut t = step;
        while t <= 1.0 {
            end_cap.push(start.rot_around(last_point, PI * 3.0 * t));
            t += step;
        }
    }
    let mut out = left;
    out.extend(end_cap);
    out.extend(right.into_iter().rev());
    out.extend(start_cap);
    out
}

/// Flat-nib calligraphy pen: the nib is a short line at 45 degrees, so strokes in that direction are
/// thin and strokes across it are wide. Returns one small polygon per segment, all wound the same way,
/// so filling them together (non-zero) gives their union without holes.
pub fn calligraphy(input: &[P], o: &Options) -> Vec<Vec<P>> {
    let smooth: Vec<P> = stroke_points(input, &Options { thinning: 0.0, ..*o }).into_iter().map(|s| s.point).collect();
    let (nx, ny) = (std::f64::consts::FRAC_1_SQRT_2, -std::f64::consts::FRAC_1_SQRT_2);
    let half = |p: &P| o.size * 0.5 * (0.6 + 0.8 * if o.simulate_pressure { 0.5 } else { p.p });
    let min_w = o.size * 0.06; // never thinner than a hairline
    if smooth.len() < 2 {
        let p = input.first().copied().unwrap_or(P::new(0.0, 0.0, 0.5));
        let h = half(&p);
        return vec![vec![
            P::new(p.x + nx * h, p.y + ny * h, 0.5),
            P::new(p.x + nx * h + min_w, p.y + ny * h + min_w, 0.5),
            P::new(p.x - nx * h + min_w, p.y - ny * h + min_w, 0.5),
            P::new(p.x - nx * h, p.y - ny * h, 0.5),
        ]];
    }
    let mut quads = Vec::with_capacity(smooth.len());
    for w in smooth.windows(2) {
        let (a, b) = (w[0], w[1]);
        let n = b.sub(a).per().unit().mul(min_w);
        let (ha, hb) = (half(&a), half(&b));
        let mut q = vec![
            P::new(a.x + nx * ha + n.x, a.y + ny * ha + n.y, 0.5),
            P::new(b.x + nx * hb + n.x, b.y + ny * hb + n.y, 0.5),
            P::new(b.x - nx * hb - n.x, b.y - ny * hb - n.y, 0.5),
            P::new(a.x - nx * ha - n.x, a.y - ny * ha - n.y, 0.5),
        ];
        // shoelace area: make every quad counter-clockwise
        let area: f64 = (0..4).map(|i| q[i].x * q[(i + 1) % 4].y - q[(i + 1) % 4].x * q[i].y).sum();
        if area < 0.0 {
            q.reverse();
        }
        quads.push(q);
    }
    quads
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(size: f64) -> Options {
        Options { size, thinning: 0.15, smoothing: 0.5, streamline: 0.35, simulate_pressure: false, taper: false, complete: true }
    }

    #[test]
    fn straight_line_outline_has_the_pen_width() {
        let pts: Vec<P> = (0..=20).map(|i| P::new(i as f64 * 5.0, 50.0, 0.5)).collect();
        let out = outline(&pts, &opts(4.0));
        assert!(out.len() > 10);
        let (min_y, max_y) = out.iter().fold((f64::MAX, f64::MIN), |(a, b), p| (a.min(p.y), b.max(p.y)));
        // width = size * (0.5 - 0.15 * (0.5 - 0.5)) * 2 = 4 (caps are round, so allow a little)
        assert!((max_y - min_y - 4.0).abs() < 0.3, "width {}", max_y - min_y);
    }

    #[test]
    fn single_point_gives_a_dot() {
        let out = outline(&[P::new(10.0, 10.0, 0.5)], &opts(6.0));
        assert!(out.len() >= 12);
        for p in &out {
            assert!((p.dist(P::new(10.5, 10.5, 0.5)) - 3.0).abs() < 1.2);
        }
    }

    #[test]
    fn calligraphy_is_thin_along_the_nib_and_wide_across() {
        let o = Options { size: 10.0, thinning: 0.0, smoothing: 0.5, streamline: 0.45, simulate_pressure: false, taper: false, complete: true };
        let along: Vec<P> = (0..20).map(|i| P::new(i as f64 * 3.0, -i as f64 * 3.0, 0.5)).collect(); // direction of the nib
        let across: Vec<P> = (0..20).map(|i| P::new(i as f64 * 3.0, i as f64 * 3.0, 0.5)).collect();
        let width = |quads: &[Vec<P>]| {
            let q = &quads[quads.len() / 2];
            let ab = P::new(q[1].x - q[0].x, q[1].y - q[0].y, 0.5).unit();
            q.iter().map(|p| (p.x - q[0].x) * -ab.y + (p.y - q[0].y) * ab.x).fold(0.0f64, |m, v| m.max(v.abs()))
        };
        let (thin, wide) = (width(&calligraphy(&along, &o)), width(&calligraphy(&across, &o)));
        assert!(wide > thin * 4.0, "thin {thin} wide {wide}");
    }
}
