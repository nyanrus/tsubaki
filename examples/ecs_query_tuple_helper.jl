# Ergonomics probe: a userland (no engine changes) helper that turns
# `query(kinds)` + a per-kind get_component into a single call returning
# (entity, comp1, comp2) tuples, so the caller can destructure directly
# instead of re-querying each component by hand. Pure Tsubaki, no new
# builtins -- see whether this is enough, and whether it costs the
# Host VM/SoA fast path (measured separately in ecs_query_tuple_bench.jl).

# a bare `(a, b, c)` tuple LITERAL only parses at statement-comma
# positions (return/assignment-RHS/destructure-RHS -- see parser.ml's
# parse_comma_exprs), not inside an arbitrary expression like a function
# call's argument list -- so building one to hand to push! goes through
# a tiny helper that assembles it via `return`, where the comma syntax
# does apply.
function ecs_row2(e, k1, k2)
    return e, get_component(e, k1), get_component(e, k2)
end

# `result = []` works here now -- an empty array literal is an empty Array of
# anything (it used to default to a numeric Vector, which then refused the
# Tuples being push!ed into it). Array{Tuple}() is still what this wants,
# though: it DECLARES the element type, so a wrong push! is caught at the
# push!, not wherever the wrong thing eventually surfaces.
function query2(k1, k2)
    result = Array{Tuple}()
    for e in query([k1, k2])
        push!(result, ecs_row2(e, k1, k2))
    end
    return result
end

struct Position
    x
    y
end

struct Velocity
    dx
    dy
end

moving = create_entity()
add_component!(moving, Position(0.0, 0.0))
add_component!(moving, Velocity(1.0, 2.0))

still = create_entity()
add_component!(still, Position(5.0, 5.0))

# `for` itself only binds a single loop variable (see parser.ml's SFor --
# no `for (a, b) in ...` destructuring in the loop header), so destructure
# each row on the first line of the body instead.
for row in query2("Position", "Velocity")
    e, pos, vel = row
    add_component!(e, Position(pos.x + vel.dx, pos.y + vel.dy))
end

moved = get_component(moving, "Position")
println("moving's Position after query2-driven step: (", moved.x, ", ", moved.y, ")  [expect (1.0, 2.0)]")
println("query2 count = ", length(query2("Position", "Velocity")), "  [expect 1 -- `still` has no Velocity]")
