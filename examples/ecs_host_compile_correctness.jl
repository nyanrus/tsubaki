# Correctness check for Compile.try_compile_host: same scenario as
# ecs_test.jl's "movement system" step, but pulled into its own
# zero-parameter function so it actually goes through the Host path
# instead of the tree-walking interpreter. Confirms host-compiled and
# tree-walked code agree, not just that the host path runs without error.

struct Position
    x
    y
end

struct Velocity
    dx
    dy
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
println("moving's Position after one host-compiled system step: (", moved.x, ", ", moved.y, ")  [expect (1.0, 2.0)]")

still_pos = get_component(still, "Position")
println("still's Position (no Velocity, must be untouched): (", still_pos.x, ", ", still_pos.y, ")  [expect (5.0, 5.0)]")

movement_system()
movement_system()
moved2 = get_component(moving, "Position")
println("moving's Position after three total steps: (", moved2.x, ", ", moved2.y, ")  [expect (3.0, 6.0)]")
