// A small 2D physics crate for Tsubaki's game-engine bridge (bin/physicsBridge.ml).
// Same wasm32-unknown-unknown, no-wasm-bindgen posture as kernel/src/lib.rs --
// pure math, no web-sys/DOM dependency, so the SAME compiled .wasm loads via
// preload.js (Node, fs.readFileSync + WebAssembly.Instance) and via
// web/demo.html (browser, fetch + WebAssembly.instantiate).
//
// Worlds/bodies live resident in this module's own memory (thread_local, same
// idiom gpu/src/lib.rs uses for its GpuState) so a frame only has to cross the
// FFI boundary with handles, not full body arrays.

use std::cell::RefCell;

#[no_mangle]
pub extern "C" fn wasm_alloc(bytes: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(bytes);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[no_mangle]
pub extern "C" fn wasm_dealloc(ptr: *mut u8, bytes: usize) {
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, bytes));
    }
}

enum Shape {
    Circle { radius: f64 },
    Aabb { hw: f64, hh: f64 },
}

struct Body {
    shape: Shape,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    inv_mass: f64,
    restitution: f64,
    // Tombstone flag: physics_remove sets this false instead of deleting the
    // body, so a live body's index (the handle a Tsubaki node stored) never
    // shifts. A dead body is skipped by physics_step; its slot goes on the
    // world's free list and is reused by the next add (see insert_body), so a
    // spawn/despawn-heavy game reuses rows instead of growing without bound.
    alive: bool,
}

struct World {
    gx: f64,
    gy: f64,
    bodies: Vec<Body>,
    // Indices of dead bodies, available for the next add to overwrite (LIFO).
    // Reuse is what keeps churn from growing `bodies`; the cost is that a
    // handle is only meaningful until its body is removed -- once removed, that
    // number may be handed to a different body, so a Tsubaki node must drop its
    // handle on despawn (keel's despawn! does exactly this).
    free: Vec<usize>,
}

thread_local! {
    static WORLDS: RefCell<Vec<World>> = RefCell::new(Vec::new());
}

// Put a body into the world, reusing a freed slot if one is available so the
// bodies Vec doesn't grow under spawn/despawn churn. Returns the slot index,
// which is the handle the caller stores.
fn insert_body(world: &mut World, body: Body) -> u32 {
    match world.free.pop() {
        Some(i) => {
            world.bodies[i] = body;
            i as u32
        }
        None => {
            world.bodies.push(body);
            (world.bodies.len() - 1) as u32
        }
    }
}

#[no_mangle]
pub extern "C" fn physics_world_new(gx: f64, gy: f64) -> u32 {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        w.push(World { gx, gy, bodies: Vec::new(), free: Vec::new() });
        (w.len() - 1) as u32
    })
}

#[no_mangle]
pub extern "C" fn physics_add_circle(world: u32, x: f64, y: f64, vx: f64, vy: f64, radius: f64, mass: f64, restitution: f64) -> u32 {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        let world = &mut w[world as usize];
        insert_body(world, Body {
            shape: Shape::Circle { radius },
            x,
            y,
            vx,
            vy,
            inv_mass: if mass > 0.0 { 1.0 / mass } else { 0.0 },
            restitution,
            alive: true,
        })
    })
}

#[no_mangle]
pub extern "C" fn physics_add_box(world: u32, x: f64, y: f64, vx: f64, vy: f64, hw: f64, hh: f64, mass: f64, restitution: f64) -> u32 {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        let world = &mut w[world as usize];
        insert_body(world, Body {
            shape: Shape::Aabb { hw, hh },
            x,
            y,
            vx,
            vy,
            inv_mass: if mass > 0.0 { 1.0 / mass } else { 0.0 },
            restitution,
            alive: true,
        })
    })
}

#[no_mangle]
pub extern "C" fn physics_set_velocity(world: u32, body: u32, vx: f64, vy: f64) {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        let b = &mut w[world as usize].bodies[body as usize];
        b.vx = vx;
        b.vy = vy;
    });
}

// Tombstone a body: mark it dead so physics_step ignores it, but leave it in
// the Vec (its index doesn't shift) and put that index on the free list for the
// next add to reuse. The `alive` guard makes a double remove a no-op -- pushing
// the same slot twice would later hand two bodies the same handle. Out-of-range
// handles are ignored rather than panicking across the FFI boundary.
#[no_mangle]
pub extern "C" fn physics_remove(world: u32, body: u32) {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        if let Some(world) = w.get_mut(world as usize) {
            let i = body as usize;
            if world.bodies.get(i).map_or(false, |b| b.alive) {
                world.bodies[i].alive = false;
                world.free.push(i);
            }
        }
    });
}

// Number of body slots in a world (live + tombstoned). physics_get_bodies
// writes one 4-float row per slot in index order, so the OCaml bridge asks for
// this to size its read buffer -- it can't just count adds any more, since the
// free list means an add reuses a slot instead of growing the Vec.
#[no_mangle]
pub extern "C" fn physics_body_count(world: u32) -> u32 {
    WORLDS.with(|w| {
        let w = w.borrow();
        w.get(world as usize).map_or(0, |world| world.bodies.len() as u32)
    })
}

#[no_mangle]
pub extern "C" fn physics_get_bodies(world: u32, out_ptr: *mut f64) {
    WORLDS.with(|w| {
        let w = w.borrow();
        let bodies = &w[world as usize].bodies;
        let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, bodies.len() * 4) };
        for (i, b) in bodies.iter().enumerate() {
            out[i * 4] = b.x;
            out[i * 4 + 1] = b.y;
            out[i * 4 + 2] = b.vx;
            out[i * 4 + 3] = b.vy;
        }
    });
}

// Circle-vs-circle and circle-vs-box both need "distance from circle center
// to the nearest point of the other shape, plus a separating normal" -- this
// is that shared penetration test. Returns None if not overlapping.
fn circle_vs_point(cx: f64, cy: f64, radius: f64, px: f64, py: f64) -> Option<(f64, f64, f64)> {
    let dx = cx - px;
    let dy = cy - py;
    let dist_sq = dx * dx + dy * dy;
    if dist_sq >= radius * radius {
        return None;
    }
    let dist = dist_sq.sqrt();
    if dist > 1e-9 {
        Some((dx / dist, dy / dist, radius - dist))
    } else {
        Some((0.0, 1.0, radius))
    }
}

// Normal always points from body `a` toward body `b`. Returns
// (nx, ny, penetration) if the two shapes overlap.
fn collide(a: &Body, b: &Body) -> Option<(f64, f64, f64)> {
    match (&a.shape, &b.shape) {
        (Shape::Circle { radius: ra }, Shape::Circle { radius: rb }) => {
            let dx = b.x - a.x;
            let dy = b.y - a.y;
            let dist = (dx * dx + dy * dy).sqrt();
            let min_dist = ra + rb;
            if dist >= min_dist {
                return None;
            }
            if dist > 1e-9 {
                Some((dx / dist, dy / dist, min_dist - dist))
            } else {
                Some((0.0, 1.0, min_dist))
            }
        }
        (Shape::Circle { radius }, Shape::Aabb { hw, hh }) => {
            let closest_x = a.x.clamp(b.x - hw, b.x + hw);
            let closest_y = a.y.clamp(b.y - hh, b.y + hh);
            // normal from a (circle) to b (box), so flip circle_vs_point's
            // circle-to-point direction.
            circle_vs_point(a.x, a.y, *radius, closest_x, closest_y).map(|(nx, ny, pen)| (-nx, -ny, pen))
        }
        (Shape::Aabb { hw, hh }, Shape::Circle { radius }) => {
            let closest_x = b.x.clamp(a.x - hw, a.x + hw);
            let closest_y = b.y.clamp(a.y - hh, a.y + hh);
            circle_vs_point(b.x, b.y, *radius, closest_x, closest_y)
        }
        (Shape::Aabb { hw: ahw, hh: ahh }, Shape::Aabb { hw: bhw, hh: bhh }) => {
            let overlap_x = (ahw + bhw) - (b.x - a.x).abs();
            let overlap_y = (ahh + bhh) - (b.y - a.y).abs();
            if overlap_x <= 0.0 || overlap_y <= 0.0 {
                return None;
            }
            if overlap_x < overlap_y {
                Some((if b.x >= a.x { 1.0 } else { -1.0 }, 0.0, overlap_x))
            } else {
                Some((0.0, if b.y >= a.y { 1.0 } else { -1.0 }, overlap_y))
            }
        }
    }
}

// Standard impulse resolution (velocity along the normal) plus a small
// positional correction (Baumgarte-style, percent/slop) so resting bodies
// don't slowly sink into each other. Returns true if an impulse was actually
// applied (the two bodies were approaching, not just resting/separating).
fn resolve(a: &mut Body, b: &mut Body, nx: f64, ny: f64, penetration: f64) -> bool {
    let inv_mass_sum = a.inv_mass + b.inv_mass;
    if inv_mass_sum <= 0.0 {
        return false;
    }

    let rvx = b.vx - a.vx;
    let rvy = b.vy - a.vy;
    let vel_along_normal = rvx * nx + rvy * ny;

    let mut applied = false;
    if vel_along_normal <= 0.0 {
        let e = a.restitution.min(b.restitution);
        let j = -(1.0 + e) * vel_along_normal / inv_mass_sum;
        a.vx -= j * nx * a.inv_mass;
        a.vy -= j * ny * a.inv_mass;
        b.vx += j * nx * b.inv_mass;
        b.vy += j * ny * b.inv_mass;
        applied = true;
    }

    const PERCENT: f64 = 0.8;
    const SLOP: f64 = 0.01;
    let correction = (penetration - SLOP).max(0.0) / inv_mass_sum * PERCENT;
    a.x -= correction * nx * a.inv_mass;
    a.y -= correction * ny * a.inv_mass;
    b.x += correction * nx * b.inv_mass;
    b.y += correction * ny * b.inv_mass;

    applied
}

#[no_mangle]
pub extern "C" fn physics_step(world: u32, dt: f64) -> u32 {
    WORLDS.with(|w| {
        let mut w = w.borrow_mut();
        let world = &mut w[world as usize];

        for b in world.bodies.iter_mut() {
            if b.alive && b.inv_mass > 0.0 {
                b.vx += world.gx * dt;
                b.vy += world.gy * dt;
                b.x += b.vx * dt;
                b.y += b.vy * dt;
            }
        }

        let n = world.bodies.len();
        let mut collisions = 0u32;
        for i in 0..n {
            if !world.bodies[i].alive {
                continue;
            }
            for j in (i + 1)..n {
                if !world.bodies[j].alive {
                    continue;
                }
                let (left, right) = world.bodies.split_at_mut(j);
                let a = &mut left[i];
                let b = &mut right[0];
                if let Some((nx, ny, penetration)) = collide(a, b) {
                    if resolve(a, b, nx, ny, penetration) {
                        collisions += 1;
                    }
                }
            }
        }
        collisions
    })
}
