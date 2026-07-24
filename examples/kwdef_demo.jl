# @kwdef -- keyword constructors with per-field defaults.
#
# `@kwdef struct T ... end` lets a field carry `= default`. After it, T can be
# built three ways: all defaults `T()`, by keyword `T(; field=val, ...)` (any
# omitted field falls to its default, order doesn't matter), or positionally
# `T(a, b, ...)` exactly as before. This is real Julia's @kwdef, reached by
# recording the field defaults at declaration and filling them in the keyword
# construct path (a struct NOT declared with @kwdef keeps only the plain
# positional constructor -- the defaults are what @kwdef adds).
#
# Note the `;` in the keyword calls below: like every keyword call in Tsubaki,
# construction reads keywords only after a semicolon -- `Color(; r=0.2, ...)`,
# not `Color(r=0.2, ...)` (comma-form args are positional here). Real Julia
# accepts the comma too; closing that gap is a parser change for all calls, not
# something @kwdef itself needs.

struct Vec2
    x
    y
end
function +(a::Vec2, b::Vec2)
    Vec2(a.x + b.x, a.y + b.y)
end

ORIGIN = Vec2(0.0, 0.0)

# A color whose alpha defaults to opaque, so callers name only what they mean.
@kwdef struct Color
    r = 1.0
    g = 1.0
    b = 1.0
    a = 1.0
end

# An enemy that reads like the GAME_DX_VISION L0 sketch: name the fields you
# care about, let the rest default.
@kwdef struct Enemy
    pos::Vec2 = ORIGIN
    vel::Vec2 = ORIGIN
    hp = 100
    tint::Color = Color(; r = 0.9, g = 0.3, b = 0.2)
end

function describe(e::Enemy)
    println("Enemy pos=(", e.pos.x, ",", e.pos.y, ") hp=", e.hp,
            " tint=(", e.tint.r, ",", e.tint.g, ",", e.tint.b, ",", e.tint.a, ")")
end

# all defaults
describe(Enemy())

# name a couple of fields; vel and tint default, order is free
describe(Enemy(; hp = 30, pos = Vec2(120.0, 40.0)))

# a keyword-built Color with a default alpha, nested inside a keyword Enemy
describe(Enemy(; pos = Vec2(5.0, 5.0), tint = Color(; r = 0.2, g = 0.6, b = 0.9)))

# advance an enemy one step, reusing the partial-update constructor that
# already existed (Enemy(existing; field=val)) -- @kwdef and it coexist
e = Enemy(; pos = Vec2(0.0, 0.0), vel = Vec2(3.0, -1.0))
e2 = Enemy(e; pos = e.pos + e.vel)
describe(e2)
