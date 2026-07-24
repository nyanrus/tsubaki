# The value vocabulary, at SoA speed.
#
# The Host VM's SoA fast path (Compile.try_compile_host -> HEcsSoaWrite) writes
# a component straight into its flat float columns -- but only ever recognized
# add_component!'s argument when it was LITERALLY a constructor call. So the
# moment you wrote the system the way you actually want to say it --
#
#     add_component!(id, p + v)
#
# -- the whole function fell off the compiled path back into the tree-walker.
# Measured, at 10k entities: 43ms/frame instead of 3.8ms. No Vec2, no nesting,
# no storage question involved -- just "was it spelled as a constructor".
#
# Compile now inlines such a call back into the constructor it stands for
# before the fast path matches (see Compile.inline_methods for the conditions
# that make that safe), so all three spellings below compile to the SAME column
# writes and run at the same speed.

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

# the value vocabulary: an operator over the components themselves
function +(p::Position, v::Velocity)
    Position(p.x + v.dx, p.y + v.dy)
end

# A -- the shape the fast path always understood: a constructor literal
function movement_literal()
    for id in query(["Position", "Velocity"])
        p = get_component(id, "Position")
        v = get_component(id, "Velocity")
        add_component!(id, Position(p.x + v.dx, p.y + v.dy))
    end
end

# B -- the same thing, said the way you want to say it
function movement_value()
    for id in query(["Position", "Velocity"])
        p = get_component(id, "Position")
        v = get_component(id, "Velocity")
        add_component!(id, p + v)
    end
end

n = 10000
i = 0
while i < n
    e = create_entity()
    add_component!(e, Position(1.0 * i, 2.0 * i))
    add_component!(e, Velocity(1.0, 0.5))
    i = i + 1
end

function bench_literal(frames)
    t0 = time()
    k = 0
    while k < frames
        movement_literal()
        k = k + 1
    end
    (time() - t0) * 1000.0 / frames
end

function bench_value(frames)
    t0 = time()
    k = 0
    while k < frames
        movement_value()
        k = k + 1
    end
    (time() - t0) * 1000.0 / frames
end

a = bench_literal(60)
b = bench_value(60)
println("A  Position(p.x + v.dx, ...)  per-frame= ", a, " ms")
println("B  p + v                      per-frame= ", b, " ms   <- same speed, was ~12x slower")

# and it must still be RIGHT, not just fast
probe = create_entity()
add_component!(probe, Position(10.0, 20.0))
add_component!(probe, Velocity(1.0, 2.0))
movement_value()
r = get_component(probe, "Position")
println("correctness: (", r.x, ", ", r.y, ")   [expect (11.0, 22.0)]")
