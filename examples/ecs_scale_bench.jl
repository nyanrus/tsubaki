# ECS "movement system" cost at scale: N entities each with Position+Velocity,
# run the same query -> get_component x2 -> add_component! pattern as
# ecs_test.jl for a fixed number of simulated frames, measure elapsed time
# per frame. Answers: is the ECS system loop itself (not the native
# physics/gpu path) fast enough for a 16.6ms (60fps) frame budget at
# realistic entity counts.
#
# Run: make run FILE=examples/ecs_scale_bench.jl

struct Position
    x
    y
end

struct Velocity
    dx
    dy
end

# NOTE: ids are tracked as a contiguous [first_id, first_id+n) Int range
# rather than pushed into a `[]` literal array -- an empty `[]` literal
# evaluates to a numeric Vector (Eval.EArrayLit's all-numeric check is
# vacuously true on zero elements), so push!ing an entity Int id into it
# silently widens to Float (Vector Int/Float push! both exist, matching
# real Julia's Vector{Float64} auto-convert-on-push behavior) -- and
# destroy_entity! only has an Int-typed method. Real bug, worth its own
# report; sidestepped here since it's not what this benchmark is testing.
function bench(n, frames)
    first_id = create_entity()
    add_component!(first_id, Position(0.0, 0.0))
    add_component!(first_id, Velocity(1.0, 2.0))
    for i in 2:n
        ent = create_entity()
        add_component!(ent, Position(0.0, 0.0))
        add_component!(ent, Velocity(1.0, 2.0))
    end

    t0 = time()
    for f in 1:frames
        movers = query(["Position", "Velocity"])
        for mover_id in movers
            p = get_component(mover_id, "Position")
            v = get_component(mover_id, "Velocity")
            add_component!(mover_id, Position(p.x + v.dx, p.y + v.dy))
        end
    end
    t1 = time()
    elapsed = t1 - t0
    per_frame_ms = elapsed / frames * 1000.0

    for i in 0:(n - 1)
        destroy_entity!(first_id + i)
    end

    println("n=", n, "  frames=", frames, "  total=", elapsed, "s  per-frame=", per_frame_ms, "ms  (60fps budget=16.667ms)")
end

bench(1000, 60)
bench(10000, 60)
bench(50000, 30)
bench(100000, 15)
