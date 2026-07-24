# Headless ECS check: entities with different component combinations, a
# query that must exclude entities missing a component, and a plain
# "movement system" (query -> read -> integrate -> write back). Run:
# make run FILE=examples/ecs_test.jl

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
# no Velocity on `still` -- must be excluded by query(["Position","Velocity"])

println("has_component(moving, \"Velocity\") = ", has_component(moving, "Velocity"))
println("has_component(still, \"Velocity\") = ", has_component(still, "Velocity"))

movers = query(["Position", "Velocity"])
println("query([Position,Velocity]) entity ids = ", movers)
println("  (expect just `moving`'s id, not `still`'s)")

for e in movers
    pos = get_component(e, "Position")
    vel = get_component(e, "Velocity")
    add_component!(e, Position(pos.x + vel.dx, pos.y + vel.dy))
end

moved = get_component(moving, "Position")
println("moving's Position after one system step: (", moved.x, ", ", moved.y, ")  [expect (1.0, 2.0)]")

everyone_with_position = query(["Position"])
println("query([Position]) entity ids = ", everyone_with_position, "  [expect both entities]")

destroy_entity!(still)
println("after destroy_entity!(still), query([Position]) = ", query(["Position"]), "  [expect just `moving`'s id]")
println("get_component(still, \"Position\") after destroy = ", get_component(still, "Position"), "  [expect nothing]")

remove_component!(moving, "Velocity")
println("after remove_component!(moving, Velocity), query([Position,Velocity]) = ", query(["Position", "Velocity"]), "  [expect empty]")
