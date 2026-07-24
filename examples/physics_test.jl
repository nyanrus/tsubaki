# Headless physics check: a ball dropped over a static floor, under gravity,
# should accelerate, hit the floor, bounce (losing energy per its
# restitution), and settle -- all readable straight from stdout, no GPU/audio
# needed. Run: make run FILE=examples/physics_test.jl

world = physics_world_new(0.0, -300.0)
floor = physics_add_box(world, 0.0, -50.0, 0.0, 0.0, 100.0, 10.0, 0.0, 0.5)
ball = physics_add_circle(world, 0.0, 100.0, 0.0, 0.0, 10.0, 1.0, 0.5)

dt = 1.0 / 60.0
for tick in 1:120
    collisions = physics_step(world, dt)
    state = physics_get_bodies(world)
    y = state[6]
    vy = state[8]
    if tick % 10 == 0 || collisions > 0
        println("tick ", tick, ": ball y=", y, " vy=", vy, " collisions=", collisions)
    end
end

println("")
println("floor is static, so its own y should be unchanged (-50.0): ", physics_get_bodies(world)[2])
