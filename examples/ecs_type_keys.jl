# Naming a component by its TYPE, not by a string.
#
#     get_component(id, Position)      instead of   get_component(id, "Position")
#     query([Position, Velocity])      instead of   query(["Position", "Velocity"])
#
# The storage doesn't change at all -- a type key is a different spelling of
# the same kind name, resolved one step earlier. Two things come of it:
#
#   * a typo is an error at the call. `get_component(id, Positon)` is an
#     undefined variable, caught the moment it runs; `get_component(id,
#     "Positon")` was a perfectly good string, and quietly handed back
#     `nothing` for a component nobody ever stored.
#   * it costs nothing. The compiler resolves the identifier at compile time
#     and emits the very same SoA column opcodes the string form did (see
#     Compile.try_compile_host's kind_key), so B below runs at A's speed.

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

function +(p::Position, v::Velocity)
    Position(p.x + v.dx, p.y + v.dy)
end

# A -- kinds named by string, as before
function movement_str()
    for id in query(["Position", "Velocity"])
        p = get_component(id, "Position")
        v = get_component(id, "Velocity")
        add_component!(id, p + v)
    end
end

# B -- the same system, kinds named by type
function movement_type()
    for id in query([Position, Velocity])
        p = get_component(id, Position)
        v = get_component(id, Velocity)
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

function bench_str(frames)
    t0 = time()
    k = 0
    while k < frames
        movement_str()
        k = k + 1
    end
    (time() - t0) * 1000.0 / frames
end

function bench_type(frames)
    t0 = time()
    k = 0
    while k < frames
        movement_type()
        k = k + 1
    end
    (time() - t0) * 1000.0 / frames
end

a = bench_str(60)
b = bench_type(60)
println("A  query([\"Position\"...]) / get_component(id, \"Position\")  per-frame= ", a, " ms")
println("B  query([Position...])    / get_component(id, Position)    per-frame= ", b, " ms   <- same speed")

# right, not just fast
probe = create_entity()
add_component!(probe, Position(10.0, 20.0))
add_component!(probe, Velocity(1.0, 2.0))
movement_type()
r = get_component(probe, Position)
println("correctness: (", r.x, ", ", r.y, ")   [expect (11.0, 22.0)]")

# the rest of the component surface takes a type key too
println("has_component(probe, Velocity) = ", has_component(probe, Velocity), "   [expect true]")
remove_component!(probe, Velocity)
println("after remove!                  = ", has_component(probe, Velocity), "   [expect false]")

# and the typo, which is the whole point
println("get_component(probe, \"Positon\") = ", get_component(probe, "Positon"), "   <- a string typo: silently nothing")
try
    r2 = get_component(probe, Positon)
    println("get_component(probe, Positon)   = ", r2, "   <- should not get here")
catch e
    println("get_component(probe, Positon)   -> ", e, "   <- a type typo: an error, at the call")
end
