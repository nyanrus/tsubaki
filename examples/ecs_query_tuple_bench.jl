# Compares ecs_scale_bench_soa.jl's direct get_component/get_component/
# add_component! movement_system (Host VM recognizes this exact shape and
# compiles it to direct SoA column reads/writes -- see try_compile_host)
# against the SAME system rewritten through the query2() userland helper
# from ecs_query_tuple_helper.jl, to see what indirection through a
# helper function costs: does the call site still get the Host VM/SoA
# fast path, or does going through query2/ecs_row2 fall back to the
# plain tree-walking interpreter?
#
# Run: make run FILE=examples/ecs_query_tuple_bench.jl

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

function ecs_row2(e, k1, k2)
    return e, get_component(e, k1), get_component(e, k2)
end

function query2(k1, k2)
    result = Array{Tuple}()
    for e in query([k1, k2])
        push!(result, ecs_row2(e, k1, k2))
    end
    return result
end

function movement_system_direct()
    for mover_id in query(["Position", "Velocity"])
        p = get_component(mover_id, "Position")
        v = get_component(mover_id, "Velocity")
        add_component!(mover_id, Position(p.x + v.dx, p.y + v.dy))
    end
end

function movement_system_via_query2()
    for row in query2("Position", "Velocity")
        e, p, v = row
        add_component!(e, Position(p.x + v.dx, p.y + v.dy))
    end
end

function setup(n)
    first_id = create_entity()
    add_component!(first_id, Position(0.0, 0.0))
    add_component!(first_id, Velocity(1.0, 2.0))
    for i in 2:n
        ent = create_entity()
        add_component!(ent, Position(0.0, 0.0))
        add_component!(ent, Velocity(1.0, 2.0))
    end
    return first_id
end

function bench(label, system_fn, n, frames)
    first_id = setup(n)

    t0 = time()
    for f in 1:frames
        system_fn()
    end
    t1 = time()
    elapsed = t1 - t0
    per_frame_ms = elapsed / frames * 1000.0

    for i in 0:(n - 1)
        destroy_entity!(first_id + i)
    end

    println(label, "  n=", n, "  frames=", frames, "  total=", elapsed, "s  per-frame=", per_frame_ms, "ms")
end

bench("direct    ", () -> movement_system_direct(), 10000, 30)
bench("via query2", () -> movement_system_via_query2(), 10000, 30)
bench("direct    ", () -> movement_system_direct(), 50000, 15)
bench("via query2", () -> movement_system_via_query2(), 50000, 15)
