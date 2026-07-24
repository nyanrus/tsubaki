# keel_map -- the "kind map scene" from map.f3liz.casa's RESEARCH.md §7.5,
# made runnable on the Keel surface (examples/keel.jl).
#
# The story is the map's own: a bus route starts as a jagged PENDING (blue)
# polyline -- just the stops joined by straight guesses -- and becomes a
# smooth CONFIRMED (red) line once it's tidied. Here "tidied" is Chaikin
# corner-cutting (RESEARCH Q1: V-W simplify -> Chaikin smooth), and you tune
# how much by hand: ArrowUp adds a smoothing pass, ArrowDown removes one. The
# little yellow squares along the bottom count the passes (demo.html doesn't
# wire draw_text, so the count is drawn, not written -- rects only).
#
# The point of the example is §7.5's thesis, made concrete: the author writes
# in Vec2 / Color(named) / Segment / draw dispatch, and the raw 8-float rect
# ABI is touched in exactly ONE place -- stroke_segment! below. The real map
# swaps that one body for a host_gpu_draw_lines call into overlay-bridge.js's
# LINE_WGSL pipeline; everything above it (Vec2, Chaikin, the named colors,
# the frame body) is unchanged. Swap the primitive, keep the spine.
#
# Run it:
#   web/demo.html?src=../examples/keel_map.jl   (serve the repo root; interactive)
#   make run FILE=examples/keel_map.jl          (headless: loads + registers, exits)
#   node -r ./preload.js _build/default/bin/main.bc.wasm.js --frames 5 \
#        examples/keel_map.jl                    (headless: actually ticks 5 frames)
#
# The Keel Vec2/Color block is inlined verbatim from examples/keel.jl because
# Tsubaki has no file-include yet -- once it lands this file's top collapses to
# include("examples/keel.jl").

# ------------------------------- Vec2 -------------------------------
# Untyped fields on purpose (see keel.jl): lets 0 and 0.0 both flow through.
struct Vec2
    x
    y
end

function +(a::Vec2, b::Vec2)
    Vec2(a.x + b.x, a.y + b.y)
end
function -(a::Vec2, b::Vec2)
    Vec2(a.x - b.x, a.y - b.y)
end
function *(s, v::Vec2)
    Vec2(s * v.x, s * v.y)
end
function *(v::Vec2, s)
    Vec2(v.x * s, v.y * s)
end

# ------------------------------- Color ------------------------------
struct Color
    r
    g
    b
    a
end

PENDING   = Color(0.20, 0.45, 1.0, 0.85)   # blue: stops joined by a straight guess
CONFIRMED = Color(0.92, 0.22, 0.20, 0.95)  # red:  the tidied (smoothed) line

# ------------------------------ Segment -----------------------------
struct Segment
    a::Vec2
    b::Vec2
end

function seg_len(s::Segment)
    dx = s.b.x - s.a.x
    dy = s.b.y - s.a.y
    sqrt(dx * dx + dy * dy)          # sqrt is a real builtin now (runtime.ml:3092)
end

# --------------------- the ONE place touching the raw ABI ------------
# stroke_segment! walks squares along a segment (arc-length stepped) and
# appends each as 8 flats {x,y,w,h,r,g,b,a} -- overlapping so the squares read
# as a solid stroke. This is the only function that knows draw_rects' layout.
# In map.f3liz.casa this body becomes: push {ax,ay,bx,by,r,g,b,a} and call
# host_gpu_draw_lines -> LINE_WGSL. Nothing that calls it has to change.
function stroke_segment!(flat, s::Segment, col::Color, width)
    L = seg_len(s)
    dir = s.b - s.a
    hx = width / 2.0
    steps = floor(L / (width * 0.6)) + 1.0   # how many squares to lay down (Float)
    inv = 1.0 / steps
    t = 0.0
    while t <= 1.0
        p = s.a + t * dir                     # Vec2 arithmetic (keel.jl's operators)
        push!(flat, p.x - hx); push!(flat, p.y - hx)
        push!(flat, width); push!(flat, width)
        push!(flat, col.r); push!(flat, col.g); push!(flat, col.b); push!(flat, col.a)
        t = t + inv
    end
end

# stroke_route!: a whole ordered point list, segment by segment. Reads like a
# sentence -- "each neighbouring pair of points, as a stroke of this color."
function stroke_route!(flat, pts, col::Color, width)
    n = length(pts)
    i = 1
    while i < n
        stroke_segment!(flat, Segment(pts[i], pts[i + 1]), col, width)
        i = i + 1
    end
end

# ----------------------------- smoothing ----------------------------
# Chaikin corner-cutting on a Vec2 list: each interior segment gives a 1/4 and
# a 3/4 point; endpoints are kept so the line still starts/ends on real stops.
# Pure Tsubaki on Vec2 -- the same functions the map runs (RESEARCH Q1).
function chaikin_once(pts)
    n = length(pts)
    out = Array{Vec2}()
    out = push!(out, pts[1])
    i = 1
    while i < n
        p = pts[i]
        q = pts[i + 1]
        out = push!(out, 0.75 * p + 0.25 * q)   # Q (near p)
        out = push!(out, 0.25 * p + 0.75 * q)   # R (near q)
        i = i + 1
    end
    out = push!(out, pts[n])
    out
end

function chaikin(pts, iters)
    result = pts
    k = 0
    while k < iters
        result = chaikin_once(result)
        k = k + 1
    end
    result
end

# ------------------------------- Editor -----------------------------
# One frame of history for edge detection + the current smoothing count + a
# clock for the gentle drift. mutable struct = the reliable cross-frame state
# holder (ui_lib.jl's pattern).
mutable struct Editor
    iterations
    up_was
    down_was
    t
end

# live_route: the authored stops, but one interior stop breathes slowly so the
# smoothing recomputes every frame and dt visibly does something.
function live_route(base, t)
    out = Array{Vec2}()
    n = length(base)
    i = 1
    while i <= n
        p = base[i]
        if i == 4
            p = Vec2(p.x, p.y + 40.0 * sin(t))   # sin is a real builtin now
        end
        out = push!(out, p)
        i = i + 1
    end
    out
end

# ------------------------------ game loop ---------------------------
function play(loop)
    on_frame(loop)
end

# The authored route: a jagged zigzag across the 480x320 canvas (pixel space,
# top-left origin, y-down -- the one convention demo.html hides for us).
route = Array{Vec2}()
route = push!(route, Vec2(40.0, 250.0))
route = push!(route, Vec2(110.0, 90.0))
route = push!(route, Vec2(180.0, 210.0))
route = push!(route, Vec2(250.0, 70.0))
route = push!(route, Vec2(320.0, 200.0))
route = push!(route, Vec2(400.0, 110.0))
route = push!(route, Vec2(445.0, 240.0))

ed = Editor(2, false, false, 0.0)

play() do dt
    clear_screen(0.06, 0.07, 0.09)
    ed.t = ed.t + dt

    # ArrowUp/ArrowDown tune the number of Chaikin passes, on the press edge
    # only (key_down is level-triggered, so compare against last frame).
    up = key_down(:ArrowUp)
    if up && !ed.up_was
        ed.iterations = ed.iterations + 1
    end
    ed.up_was = up

    down = key_down(:ArrowDown)
    if down && !ed.down_was
        if ed.iterations > 0
            ed.iterations = ed.iterations - 1
        end
    end
    ed.down_was = down

    base = live_route(route, ed.t)
    smooth = chaikin(base, ed.iterations)

    flat = Float[]
    stroke_route!(flat, base, PENDING, 3.0)      # blue: the jagged guess, underneath
    stroke_route!(flat, smooth, CONFIRMED, 5.0)  # red:  the smoothed line, on top

    # smoothing-pass counter: one small yellow square per pass along the bottom
    shown = 0
    bx = 12.0
    while shown < ed.iterations
        push!(flat, bx); push!(flat, 300.0); push!(flat, 8.0); push!(flat, 8.0)
        push!(flat, 0.95); push!(flat, 0.85); push!(flat, 0.2); push!(flat, 1.0)
        bx = bx + 12.0
        shown = shown + 1
    end

    draw_rects(Vector(flat))
end
