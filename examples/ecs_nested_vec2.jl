# A component made of Vec2 values -- at flat-SoA speed.
#
# This is the seam GAME_DX_VISION.md called unresolved: you could have the
# value vocabulary (`pos`, `vel` as real Vec2 values you add together) OR the
# columnar speed, not both. It took two pieces, in this order:
#
#   1. the inliner (Compile.inline_methods) -- `a + b` on two Vec2s is a
#      function call, and a call used to drop the whole system off the compiled
#      path. Inlined, it becomes the constructor it stands for.
#   2. nested SoA (Runtime.soa_leaf_paths, Ecs.make_soa_column) -- a struct
#      whose fields are themselves all-::Float structs flattens into LEAF
#      columns: Transform -> pos.x, pos.y, vel.x, vel.y.
#
# Together, `Transform(t.pos + t.vel, t.vel)` compiles to four direct column
# writes: no Vec2 boxed, no Transform boxed, no dispatch. Storage alone would
# not have done it -- `t.pos + t.vel` is a call, and calls were the real seam.

struct Vec2
    x::Float
    y::Float
end

function +(a::Vec2, b::Vec2)
    Vec2(a.x + b.x, a.y + b.y)
end

function *(v::Vec2, s::Float)
    Vec2(v.x * s, v.y * s)
end

# nested: two Vec2 fields -> four float columns
struct Transform
    pos::Vec2
    vel::Vec2
end

function movement()
    for id in query(["Transform"])
        t = get_component(id, "Transform")
        add_component!(id, Transform(t.pos + t.vel, t.vel))
    end
end

n = 10000
i = 0
while i < n
    e = create_entity()
    add_component!(e, Transform(Vec2(1.0 * i, 2.0 * i), Vec2(1.0, 0.5)))
    i = i + 1
end

frames = 60
t0 = time()
k = 0
while k < frames
    movement()
    k = k + 1
end
println("nested Vec2, value vocabulary  t.pos + t.vel : per-frame= ", (time() - t0) * 1000.0 / frames, " ms")
println("   (flat ::Float SoA runs the same system at ~3.9 ms; uncompiled it was ~43 ms)")

# still right, not just fast
probe = create_entity()
add_component!(probe, Transform(Vec2(10.0, 20.0), Vec2(1.0, 2.0)))
movement()
p = get_component(probe, "Transform")
println("correctness: pos=(", p.pos.x, ", ", p.pos.y, ") vel=(", p.vel.x, ", ", p.vel.y, ")   [expect pos=(11, 22) vel=(1, 2)]")
