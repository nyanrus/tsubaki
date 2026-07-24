# Correctness check for the SoA-specialized compile path: Position/Velocity
# here are SoA-eligible (::Float fields), and movement_system is the exact
# shape Compile.try_compile_host's soa_aliases logic targets -- `p`/`v`
# never become real boxed structs at all, `p.x`/`v.dx`/... compile straight
# to HEcsSoaFieldRead, and the final add_component! compiles to
# HEcsSoaWrite. Same expected numbers as ecs_host_compile_correctness.jl
# (the AoS/untyped-fields version) -- confirms the two storage/compile
# paths agree, not just that either one runs without error.

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

function movement_system()
    for mover_id in query(["Position", "Velocity"])
        p = get_component(mover_id, "Position")
        v = get_component(mover_id, "Velocity")
        add_component!(mover_id, Position(p.x + v.dx, p.y + v.dy))
    end
end

moving = create_entity()
add_component!(moving, Position(0.0, 0.0))
add_component!(moving, Velocity(1.0, 2.0))

still = create_entity()
add_component!(still, Position(5.0, 5.0))

movement_system()

moved = get_component(moving, "Position")
println("moving's Position after one SoA-compiled system step: (", moved.x, ", ", moved.y, ")  [expect (1.0, 2.0)]")

still_pos = get_component(still, "Position")
println("still's Position (no Velocity, must be untouched): (", still_pos.x, ", ", still_pos.y, ")  [expect (5.0, 5.0)]")

movement_system()
movement_system()
moved2 = get_component(moving, "Position")
println("moving's Position after three total steps: (", moved2.x, ", ", moved2.y, ")  [expect (3.0, 6.0)]")
