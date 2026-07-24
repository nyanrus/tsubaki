# Same benchmark as ecs_scale_bench_compiled.jl, but Position/Velocity are
# declared with ::Float fields -- SoA-eligible (see Runtime.soa_eligible) --
# so movement_system's compiled body never boxes a VStruct at all: p/v are
# compile-time aliases (see Compile.try_compile_host's soa_aliases), every
# field read is a direct HEcsSoaFieldRead, and the final add_component! is
# a direct HEcsSoaWrite into Position's flat float columns.
#
# Run: make run FILE=examples/ecs_scale_bench_soa.jl

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
        movement_system()
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
