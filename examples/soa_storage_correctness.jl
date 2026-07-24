# Correctness check for Ecs's SoA (columnar) storage path -- Position here
# is SoA-eligible (every field ::Float, see Runtime.soa_eligible), so
# add_component!/get_component/query/has_component/remove_component!/
# destroy_entity! all go through the SoA branch in ecs.ml, NOT the AoS one.
# This only exercises the transparent boxing/unboxing (ordinary Dispatch
# path) -- ecs_host_compile_correctness.jl covers the compiled fast path
# once try_compile_host's own SoA specialization lands.

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

e1 = create_entity()
add_component!(e1, Position(1.0, 2.0))
add_component!(e1, Velocity(0.5, 0.25))

e2 = create_entity()
add_component!(e2, Position(10.0, 20.0))
# no Velocity on e2

p1 = get_component(e1, "Position")
println("e1 Position: (", p1.x, ", ", p1.y, ")  [expect (1.0, 2.0)]")

println("e1 has Velocity: ", has_component(e1, "Velocity"), "  [expect true]")
println("e2 has Velocity: ", has_component(e2, "Velocity"), "  [expect false]")

movers = query(["Position", "Velocity"])
println("query([Position,Velocity]) = ", movers, "  [expect just e1's id]")

# overwrite in place (reconstruct, same as the AoS path does)
add_component!(e1, Position(p1.x + 1.0, p1.y + 1.0))
p1b = get_component(e1, "Position")
println("e1 Position after update: (", p1b.x, ", ", p1b.y, ")  [expect (2.0, 3.0)]")

remove_component!(e1, "Velocity")
println("e1 has Velocity after remove: ", has_component(e1, "Velocity"), "  [expect false]")

destroy_entity!(e2)
println("e2 Position after destroy: ", get_component(e2, "Position"), "  [expect nothing]")
println("query([Position]) after destroy = ", query(["Position"]), "  [expect just e1's id]")
