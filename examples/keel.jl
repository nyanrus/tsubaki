# Keel -- a small, honest game layer over Tsubaki's physics/gpu/audio bridges.
#
# This is the "feel-proof MVP" from GAME_DX_VISION.md: the L0/L1 surface where
# `Vec2`, `Transform`, `spawn!`, `step!`, `draw` are real Tsubaki values and real
# multiple-dispatch methods, not string-keyed component soup. Nothing here
# reaches for a Dict, even though Tsubaki has one now: each node remembers its own
# physics body by carrying the handle as a plain field, so `step!` can pull that
# node's row out of the flat physics array no matter what order things were
# spawned in. A field the node already has beats a lookup it doesn't need.
#
# This file is the single source of the layer. A demo picks it up with
# `include("keel.jl")` (resolved relative to the including file, so it works
# from any cwd) and adds only its own scene + loop -- see examples/keel_bounce.jl
# and examples/keel_despawn.jl, which are ~50 lines each because of it.

# ------------------------------- Vec2 -------------------------------
# Declared `::Float`, and it costs the caller nothing: construction converts an
# Int into a Float field the way real Julia's `convert` does, so `Vec2(0, 0)`
# and `Vec2(0.0, 0.0)` both just work. (These fields were untyped for exactly
# that reason before -- an Int used to be a TypeError here.)
#
# Being immutable with every field `::Float` is also what makes Vec2 a value
# the ECS can flatten into flat float columns (Runtime.soa_eligible), so a
# component built out of Vec2s costs nothing over hand-written x/y floats --
# see examples/ecs_nested_vec2.jl. Keel itself drives physics/, not the ECS,
# but the type is the same honest one either way.
struct Vec2
    x::Float
    y::Float
end

function +(a::Vec2, b::Vec2)
    Vec2(a.x + b.x, a.y + b.y)
end
function -(a::Vec2, b::Vec2)
    Vec2(a.x - b.x, a.y - b.y)
end
# scalar * vector and vector * scalar (untyped scalar so Int or Float works)
function *(s, v::Vec2)
    Vec2(s * v.x, s * v.y)
end
function *(v::Vec2, s)
    Vec2(v.x * s, v.y * s)
end

ZERO = Vec2(0.0, 0.0)

# ------------------------------- Color ------------------------------
# @kwdef, so alpha has a default and a caller names only what it means:
# `Color(; r = 0.9, g = 0.3, b = 0.2)` is opaque. The positional form
# `Color(0.9, 0.3, 0.2, 1.0)` still works exactly as before.
@kwdef struct Color
    r::Float
    g::Float
    b::Float
    a::Float = 1.0
end

RED   = Color(; r = 0.9, g = 0.3, b = 0.2)
GREEN = Color(; r = 0.3, g = 0.9, b = 0.4)
BLUE  = Color(; r = 0.2, g = 0.6, b = 0.9)

# ------------------------------- Shapes -----------------------------
# A Shape is positioned (carries its own center) so `draw` needs only the
# shape + a color -- draw(::Circle, ::Color), draw(::Rect, ::Color).
abstract type Shape end

struct Circle <: Shape
    center::Vec2
    r::Float
end

struct Rect <: Shape
    center::Vec2
    w::Float
    h::Float
end

# There is no draw_circle primitive; a circle draws as its bounding square,
# exactly as the original bouncing_balls.jl did.
function draw(c::Circle, col::Color)
    d = 2.0 * c.r
    draw_rect(c.center.x - c.r, c.center.y - c.r, d, d, col.r, col.g, col.b, col.a)
end
function draw(rc::Rect, col::Color)
    draw_rect(rc.center.x - rc.w / 2.0, rc.center.y - rc.h / 2.0, rc.w, rc.h, col.r, col.g, col.b, col.a)
end

# ----------------------------- Transform ----------------------------
mutable struct Transform
    pos::Vec2
    vel::Vec2
end

# ------------------------------- Ball -------------------------------
# `handle` is this ball's physics body id (0-based). That single field IS the
# identity->body map -- no Dict needed, no fixed index table.
mutable struct Ball
    tf::Transform
    radius::Float
    color::Color
    handle::Int
end

function draw(b::Ball)
    draw(Circle(b.tf.pos, b.radius), b.color)
end

# ------------------------------- Stage ------------------------------
mutable struct Stage
    world::Int
    balls
    width::Float
    height::Float
    collisions::Int
end

# `stage(w, h)` hides the raw world handle. Gravity is +y because the canvas
# is y-down (down = larger y), matching bouncing_balls.jl.
function stage(width, height; gravity = 400.0)
    Stage(physics_world_new(0.0, gravity), Array{Ball}(), width, height, 0)
end

# spawn!: add a circle body, remember its handle on the node, keep the node.
# Everything but the stage is a keyword with a default, so a call reads by name
# --  spawn!(scene; pos = Vec2(100, 50), color = RED)  --  and any field you
# don't care about (vel, radius, mass, restitution) just falls to its default.
# This is the @kwdef-style "bundle" from GAME_DX_VISION.md's L0 sketch, reached
# with Tsubaki's own keyword arguments (note the `;` -- comma-form `f(a, k=v)` is
# NOT a keyword here) rather than a new struct-constructor macro.
function spawn!(s::Stage; pos::Vec2 = ZERO, vel::Vec2 = ZERO, radius = 10.0, color::Color = RED, mass = 1.0, restitution = 0.7)
    h = physics_add_circle(s.world, pos.x, pos.y, vel.x, vel.y, radius, mass, restitution)
    b = Ball(Transform(pos, vel), radius, color, h)
    s.balls = push!(s.balls, b)
    b
end

# despawn!: the other half of spawn!. Tombstone this ball's physics body (its
# slot stays put so no *surviving* ball's stored handle shifts) and drop the
# node from the stage -- keeping every ball whose handle isn't this one, which
# is an exact identity match since handles are unique among live bodies. The
# freed slot is reused by a later spawn!, so churn (spawn/despawn every frame)
# doesn't grow the world -- but that also means this ball's handle may later
# belong to a different body, so don't hold onto `b` after despawning it.
#
# This was a hand-written rebuild loop until `filter` existed. It kept the
# Array{Ball} element type then and it keeps it now (filter gives back the
# shape it was handed), so nothing downstream can tell the difference -- it's
# just four lines shorter, and says what it means.
function despawn!(s::Stage, b::Ball)
    physics_remove(s.world, b.handle)
    s.balls = filter(other -> other.handle != b.handle, s.balls)
    nothing
end

# walls: four static boxes framing the stage. They take the first four handles
# (0..3) but that never matters here -- every ball reads its OWN stored handle,
# so wall vs ball ordering can never shift a ball's row.
function walls(s::Stage; thickness = 20.0, restitution = 0.6)
    w = s.width
    h = s.height
    t = thickness
    physics_add_box(s.world, w / 2.0, h + t / 2.0, 0.0, 0.0, w / 2.0, t / 2.0, 0.0, restitution) # floor
    physics_add_box(s.world, w / 2.0, -t / 2.0, 0.0, 0.0, w / 2.0, t / 2.0, 0.0, restitution)    # ceiling
    physics_add_box(s.world, -t / 2.0, h / 2.0, 0.0, 0.0, t / 2.0, h / 2.0, 0.0, restitution)    # left
    physics_add_box(s.world, w + t / 2.0, h / 2.0, 0.0, 0.0, t / 2.0, h / 2.0, 0.0, restitution) # right
    s
end

# ------------------------------- Input ------------------------------
# arrows(): held arrow keys -> a direction Vec2. Symbol keys reuse the same
# host input as the string keys. Screen is y-down, so Down = +y.
function arrows()
    vx = 0.0
    vy = 0.0
    if key_down(:ArrowRight)
        vx = vx + 1.0
    end
    if key_down(:ArrowLeft)
        vx = vx - 1.0
    end
    if key_down(:ArrowDown)
        vy = vy + 1.0
    end
    if key_down(:ArrowUp)
        vy = vy - 1.0
    end
    Vec2(vx, vy)
end

# nudge!: push a ball's velocity directly (arrow-driven control).
function nudge!(s::Stage, b::Ball, v::Vec2)
    physics_set_velocity(s.world, b.handle, v.x, v.y)
end

# ------------------------------- Step -------------------------------
# step!: advance physics one dt, then sync each node's Transform from the flat
# body array. handle is 0-based; Tsubaki vectors are 1-based, so body h occupies
# state[4h+1 .. 4h+4].
function step!(s::Stage, dt)
    n = physics_step(s.world, dt)
    s.collisions = n
    state = physics_get_bodies(s.world)
    for b in s.balls
        base = 4 * b.handle
        b.tf.pos = Vec2(state[base + 1], state[base + 2])
        b.tf.vel = Vec2(state[base + 3], state[base + 4])
    end
    n
end

function collided(s::Stage)
    s.collisions > 0
end

# ------------------------------- Audio ------------------------------
function beep()
    play_tone(220.0, 0.05)
end

# ---------------------------- Game loop -----------------------------
# play(...) do dt ... end  -- the front door. The trailing closure gets the
# frame delta (seconds); `play` just hands it to on_frame.
function play(loop)
    on_frame(loop)
end
