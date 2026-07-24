# A system on every core.
#
#     parallel_each(:movement!, [Position, Velocity])
#
# `movement!` is an ORDINARY system -- the same zero-argument function you would
# call directly, unchanged. Inside a worker, `query` simply answers with that
# worker's share of the entities, so the body never learns it was split up. That
# also keeps it on the Host VM's compiled SoA path, which is the only reason
# there is anything here worth parallelizing.
#
# The workers are real OS threads (Node worker_threads; wasm_of_ocaml has no
# threads of its own). What they share is the component columns themselves --
# every SoA column is a Float64Array on a SharedArrayBuffer, so nothing is
# copied to a worker and nothing is copied back. See bin/parallelBridge.ml.
#
# Two rules, both enforced rather than assumed:
#   * a parallel system may only write components an entity ALREADY has.
#     Spawning and despawning grow the columns, which belongs on the main thread.
#   * it must query exactly the components parallel_each names.

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

# the world is built once, on the main thread. A worker runs this same script --
# that is how it comes to know Position, Velocity and movement! -- so its setup
# is skipped, and it attaches to the world main built instead of building a
# second one of its own.
n = 100000
if !is_worker()
    i = 0
    while i < n
        e = create_entity()
        add_component!(e, Position(1.0 * i, 2.0 * i))
        add_component!(e, Velocity(1.0, 0.5))
        i = i + 1
    end
end

function movement!()
    for id in query([Position, Velocity])
        p = get_component(id, Position)
        v = get_component(id, Velocity)
        add_component!(id, p + v)
    end
end

if !is_worker()
    # correctness first: one step on one core, one step on all of them, and the
    # answer had better be the same one.
    probe = 7
    before = get_component(probe, Position)
    movement!()
    serial = get_component(probe, Position)
    parallel_each(:movement!, [Position, Velocity])
    both = get_component(probe, Position)
    println("entity ", probe, ": start (", before.x, ", ", before.y, ")")
    println("  after 1 serial step:   (", serial.x, ", ", serial.y, ")")
    println("  after 1 parallel step: (", both.x, ", ", both.y, ")   [expect one more (+1.0, +0.5)]")

    function bench_serial(frames)
        t0 = time()
        k = 0
        while k < frames
            movement!()
            k = k + 1
        end
        (time() - t0) * 1000.0 / frames
    end

    function bench_parallel(frames)
        t0 = time()
        k = 0
        while k < frames
            parallel_each(:movement!, [Position, Velocity])
            k = k + 1
        end
        (time() - t0) * 1000.0 / frames
    end

    # warm both paths first -- a worker's wasm tiers up on its first frames, and
    # timing that instead of the steady state is how you get a number that lies
    bench_serial(10)
    bench_parallel(10)

    a = bench_serial(30)
    b = bench_parallel(30)
    println("")
    println(n, " entities")
    println("  one core   ", a, " ms/frame")
    println("  every core ", b, " ms/frame   (60fps budget = 16.667ms)")
end
