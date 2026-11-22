//! The strokes of the open page, kept in Rust with a spatial index (R-tree):
//! tile rendering on all CPU cores, and instant hit tests for eraser and lasso.
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, RwLock};

use flutter_rust_bridge::frb;
use rayon::prelude::*;
use rstar::primitives::{GeomWithData, Rectangle};
use rstar::{RTree, AABB};
use tiny_skia::{FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke as SkStroke, Transform};

use super::codec::StrokeBatch;
use super::ink::{self, HIGHLIGHTER};

struct Ink {
    kind: u8,
    color: u32,
    size: f32,
    sim: bool,
    pts: Vec<f32>,
    bounds: [f32; 4],
}

type Entry = GeomWithData<Rectangle<[f32; 2]>, u32>;

#[frb(ignore)] // internal; only the functions below are for Dart
#[derive(Default)]
struct Scene {
    strokes: HashMap<u32, Ink>,
    tree: RTree<Entry>,
}

static SCENES: LazyLock<RwLock<HashMap<u32, Arc<RwLock<Scene>>>>> = LazyLock::new(Default::default);
static NEXT: AtomicU32 = AtomicU32::new(1);

fn scene(id: u32) -> Option<Arc<RwLock<Scene>>> {
    SCENES.read().unwrap().get(&id).cloned()
}

fn entry(id: u32, b: &[f32; 4]) -> Entry {
    GeomWithData::new(Rectangle::from_corners([b[0], b[1]], [b[2], b[3]]), id)
}

fn inks(batch: StrokeBatch) -> Vec<(u32, Ink)> {
    (0..batch.kinds.len())
        .map(|i| {
            let pts = batch.points[batch.offsets[i] as usize..batch.offsets[i + 1] as usize].to_vec();
            let size = batch.sizes[i];
            let bounds = if batch.bounds.len() >= 4 * (i + 1) {
                [batch.bounds[4 * i], batch.bounds[4 * i + 1], batch.bounds[4 * i + 2], batch.bounds[4 * i + 3]]
            } else {
                let (mut l, mut t, mut r, mut b) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
                for c in pts.chunks_exact(3) {
                    (l, t, r, b) = (l.min(c[0]), t.min(c[1]), r.max(c[0]), b.max(c[1]));
                }
                [l - size, t - size, r + size, b + size]
            };
            (batch.ids[i], Ink { kind: batch.kinds[i], color: batch.colors[i], size, sim: batch.sims[i] != 0, pts, bounds })
        })
        .filter(|(_, ink)| !ink.pts.is_empty())
        .collect()
}

/// A new, empty scene. Returns its handle.
#[frb(sync)]
pub fn scene_create() -> u32 {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    SCENES.write().unwrap().insert(id, Default::default());
    id
}

#[frb(sync)]
pub fn scene_drop(scene: u32) {
    SCENES.write().unwrap().remove(&scene);
}

/// Replaces all strokes at once (opening a page); builds the index in one go, off the UI thread.
pub fn scene_load(scene: u32, batch: StrokeBatch) {
    let Some(sc) = self::scene(scene) else { return };
    let items = inks(batch);
    let tree = RTree::bulk_load(items.iter().map(|(id, ink)| entry(*id, &ink.bounds)).collect());
    let mut s = sc.write().unwrap();
    s.tree = tree;
    s.strokes = items.into_iter().collect();
}

/// Adds strokes (a new stroke, undo, paste...). Their ids decide the drawing order: higher = on top.
#[frb(sync)]
pub fn scene_add(scene: u32, batch: StrokeBatch) {
    let Some(sc) = self::scene(scene) else { return };
    let mut s = sc.write().unwrap();
    for (id, ink) in inks(batch) {
        s.tree.insert(entry(id, &ink.bounds));
        s.strokes.insert(id, ink);
    }
}

#[frb(sync)]
pub fn scene_remove(scene: u32, ids: Vec<u32>) {
    let Some(sc) = self::scene(scene) else { return };
    let mut s = sc.write().unwrap();
    for id in ids {
        if let Some(ink) = s.strokes.remove(&id) {
            s.tree.remove(&entry(id, &ink.bounds));
        }
    }
}

/// Left, top, right, bottom of everything in the scene; empty if there is nothing.
#[frb(sync)]
pub fn scene_bounds(scene: u32) -> Vec<f64> {
    let Some(sc) = self::scene(scene) else { return vec![] };
    let s = sc.read().unwrap();
    if s.strokes.is_empty() {
        return vec![];
    }
    let e = s.tree.root().envelope();
    let (a, b) = (e.lower(), e.upper());
    vec![a[0] as f64, a[1] as f64, b[0] as f64, b[1] as f64]
}

/// Draws the square of page space starting at (x0, y0) with `unit` pixels per page unit into a
/// `px` x `px` image. Returns premultiplied RGBA, or nothing if no ink is in the square.
pub fn scene_render(scene: u32, x0: f64, y0: f64, unit: f64, px: u32) -> Vec<u8> {
    let Some(sc) = self::scene(scene) else { return vec![] };
    let s = sc.read().unwrap();
    let side = px as f64 / unit;
    let env = AABB::from_corners([x0 as f32, y0 as f32], [(x0 + side) as f32, (y0 + side) as f32]);
    let mut hits: Vec<u32> = s.tree.locate_in_envelope_intersecting(&env).map(|e| e.data).collect();
    if hits.is_empty() {
        return vec![];
    }
    hits.sort_unstable();
    let to_px = |x: f32, y: f32| (((x as f64 - x0) * unit) as f32, ((y as f64 - y0) * unit) as f32);
    // Outlines are the expensive part: compute them on all cores, then fill in order.
    let shapes: Vec<(tiny_skia::Path, Paint, Option<SkStroke>)> = hits
        .par_iter()
        .filter_map(|id| {
            let ink = s.strokes.get(id)?;
            let a = ((ink.color >> 24) as f32 / 255.0) * ink::pen_alpha(ink.kind);
            let mut paint = Paint::default();
            paint.set_color_rgba8((ink.color >> 16) as u8, (ink.color >> 8) as u8, ink.color as u8, (a * 255.0) as u8);
            paint.anti_alias = true;
            let mut pb = PathBuilder::new();
            if (ink.size as f64) * unit < 2.5 && ink.kind != HIGHLIGHTER {
                // Zoomed far out: a plain line looks the same and is much cheaper.
                let (x, y) = to_px(ink.pts[0], ink.pts[1]);
                pb.move_to(x, y);
                for c in ink.pts.chunks_exact(3).skip(1) {
                    let (x, y) = to_px(c[0], c[1]);
                    pb.line_to(x, y);
                }
                if ink.pts.len() == 3 {
                    pb.line_to(x + 0.01, y);
                }
                let st = SkStroke { width: (ink.size as f64 * unit * 0.8).max(0.4) as f32, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() };
                return pb.finish().map(|p| (p, paint, Some(st)));
            }
            for poly in ink::polygons(ink.kind, ink.size as f64, ink.sim, &ink.pts, true) {
                let (x, y) = to_px(poly[0].x as f32, poly[0].y as f32);
                pb.move_to(x, y);
                for p in &poly[1..] {
                    let (x, y) = to_px(p.x as f32, p.y as f32);
                    pb.line_to(x, y);
                }
                pb.close();
            }
            pb.finish().map(|p| (p, paint, None))
        })
        .collect();
    let Some(mut pm) = Pixmap::new(px, px) else { return vec![] };
    for (path, paint, stroke) in &shapes {
        match stroke {
            Some(st) => pm.stroke_path(path, paint, st, Transform::identity(), None),
            None => pm.fill_path(path, paint, FillRule::Winding, Transform::identity(), None),
        }
    }
    pm.take()
}

fn seg_dist(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0.0 { 0.0 } else { (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0) };
    (px - ax - dx * t).hypot(py - ay - dy * t)
}

fn touches(ink: &Ink, x: f64, y: f64, r: f64) -> bool {
    let tol = r + ink.size as f64 / 2.0;
    let p = &ink.pts;
    if p.len() == 3 {
        return (p[0] as f64 - x).hypot(p[1] as f64 - y) <= tol;
    }
    p.chunks_exact(3).zip(p.chunks_exact(3).skip(1)).any(|(a, b)| seg_dist(x, y, a[0] as f64, a[1] as f64, b[0] as f64, b[1] as f64) <= tol)
}

fn near(s: &Scene, x: f64, y: f64, r: f64) -> impl Iterator<Item = (u32, &Ink)> {
    let env = AABB::from_corners([(x - r) as f32, (y - r) as f32], [(x + r) as f32, (y + r) as f32]);
    s.tree.locate_in_envelope_intersecting(&env).filter_map(|e| s.strokes.get(&e.data).map(|i| (e.data, i)))
}

/// Strokes touched by an eraser of radius r at (x, y).
#[frb(sync)]
pub fn scene_hit(scene: u32, x: f64, y: f64, r: f64, highlighter_only: bool) -> Vec<u32> {
    let Some(sc) = self::scene(scene) else { return vec![] };
    let s = sc.read().unwrap();
    near(&s, x, y, r).filter(|(_, i)| (!highlighter_only || i.kind == HIGHLIGHTER) && touches(i, x, y, r)).map(|(id, _)| id).collect()
}

/// A stroke cut by the precise eraser: what is left of it (each piece becomes its own stroke).
pub struct Cut {
    pub id: u32,
    pub pieces: Vec<Vec<f32>>,
}

/// Precise eraser: only the part of each stroke under the eraser is removed.
#[frb(sync)]
pub fn scene_erase_partial(scene: u32, x: f64, y: f64, r: f64, highlighter_only: bool) -> Vec<Cut> {
    let Some(sc) = self::scene(scene) else { return vec![] };
    let s = sc.read().unwrap();
    near(&s, x, y, r)
        .filter(|(_, i)| !highlighter_only || i.kind == HIGHLIGHTER)
        .filter_map(|(id, i)| ink::cut(&i.pts, x, y, r + i.size as f64 / 2.0).map(|pieces| Cut { id, pieces }))
        .collect()
}

fn inside(poly: &[(f64, f64)], x: f64, y: f64) -> bool {
    let mut c = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[j]);
        if (a.1 > y) != (b.1 > y) && x < (b.0 - a.0) * (y - a.1) / (b.1 - a.1) + a.0 {
            c = !c;
        }
        j = i;
    }
    c
}

/// Lasso: strokes with at least half of their points inside the drawn loop (x, y pairs).
#[frb(sync)]
pub fn scene_lasso(scene: u32, poly: Vec<f32>) -> Vec<u32> {
    let Some(sc) = self::scene(scene) else { return vec![] };
    let s = sc.read().unwrap();
    let loop_: Vec<(f64, f64)> = poly.chunks_exact(2).map(|c| (c[0] as f64, c[1] as f64)).collect();
    if loop_.len() < 3 {
        return vec![];
    }
    let (mut l, mut t, mut r, mut b) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for c in poly.chunks_exact(2) {
        (l, t, r, b) = (l.min(c[0]), t.min(c[1]), r.max(c[0]), b.max(c[1]));
    }
    let mut ids: Vec<u32> = s
        .tree
        .locate_in_envelope_intersecting(&AABB::from_corners([l, t], [r, b]))
        .filter_map(|e| {
            let ink = s.strokes.get(&e.data)?;
            let n = ink.pts.len() / 3;
            let hits = ink.pts.chunks_exact(3).filter(|c| inside(&loop_, c[0] as f64, c[1] as f64)).count();
            (hits * 2 >= n).then_some(e.data)
        })
        .collect();
    ids.sort_unstable();
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(id: u32, x0: f32, y: f32, x1: f32, kind: u8) -> StrokeBatch {
        StrokeBatch { ids: vec![id], kinds: vec![kind], colors: vec![0xFF000000], sizes: vec![4.0], sims: vec![0], offsets: vec![0, 6], points: vec![x0, y, 0.5, x1, y, 0.5], bounds: vec![] }
    }

    #[test]
    fn render_hit_lasso_erase() {
        let s = scene_create();
        scene_add(s, line(1, 10.0, 20.0, 200.0, 0));
        scene_add(s, line(2, 10.0, 300.0, 200.0, HIGHLIGHTER));
        // the line shows up in its tile, nothing in an empty one
        let px = scene_render(s, 0.0, 0.0, 1.0, 256);
        assert_eq!(px.len(), 256 * 256 * 4);
        assert!(px[(20 * 256 + 100) * 4 + 3] > 200, "ink is drawn");
        assert!(scene_render(s, 1000.0, 1000.0, 1.0, 256).is_empty());
        // hit tests
        assert_eq!(scene_hit(s, 100.0, 22.0, 3.0, false), vec![1]);
        assert!(scene_hit(s, 100.0, 60.0, 3.0, false).is_empty());
        assert!(scene_hit(s, 100.0, 22.0, 3.0, true).is_empty(), "only highlighter");
        // lasso around the first line only
        assert_eq!(scene_lasso(s, vec![0.0, 0.0, 250.0, 0.0, 250.0, 50.0, 0.0, 50.0]), vec![1]);
        // precise eraser splits line 1 into two pieces
        let cuts = scene_erase_partial(s, 100.0, 20.0, 5.0, false);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].pieces.len(), 2);
        // remove + bounds
        scene_remove(s, vec![1]);
        assert!(scene_hit(s, 100.0, 22.0, 3.0, false).is_empty());
        let b = scene_bounds(s);
        assert!((b[1] - 296.0).abs() < 1e-3, "bounds now only the highlighter: {b:?}");
        scene_drop(s);
        assert!(scene_render(s, 0.0, 0.0, 1.0, 64).is_empty(), "dropped scene draws nothing");
    }
}
