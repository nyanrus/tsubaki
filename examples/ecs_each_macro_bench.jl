# Does a movement system written via @each still get Host VM/SoA
# compilation (Compile.try_compile_host), or does going through the macro
# expansion somehow fall back to the plain tree-walking interpreter? The
# expansion is plain get_component/query/for calls (see ecs_each_macro_probe.jl),
# so it should compile identically to the hand-written direct version --
# this measures whether that's actually true.
#
# Run: make run FILE=examples/ecs_each_macro_bench.jl

macro each(forloop)
    entity_sym = forloop.args[1]
    iter_call = forloop.args[2]
    body = forloop.args[3]
    kinds = Array{Any}()
    all_args = iter_call.args
    for i in 2:length(all_args)
        push!(kinds, all_args[i])
    end

    kind_strs = Array{Any}()
    bindings = Array{Any}()
    for k in kinds
        ks = string(k)
        push!(kind_strs, ks)
        var_sym = Symbol(lowercase(ks))
        binding = Expr(Symbol("="), [var_sym, Expr(:call, [:get_component, entity_sym, ks])])
        push!(bindings, binding)
    end

    new_iter = Expr(:call, [:query, Expr(:vect, kind_strs)])
    new_body = Expr(:block, vcat(bindings, body.args))

    Expr(Symbol("for"), [entity_sym, new_iter, new_body])
end

struct Position
    x::Float
    y::Float
end

struct Velocity
    dx::Float
    dy::Float
end

function movement_system_direct()
    for mover_id in query(["Position", "Velocity"])
        p = get_component(mover_id, "Position")
        v = get_component(mover_id, "Velocity")
        add_component!(mover_id, Position(p.x + v.dx, p.y + v.dy))
    end
end

function movement_system_via_each()
    @each for e in each_kinds(Position, Velocity)
        add_component!(e, Position(position.x + velocity.dx, position.y + velocity.dy))
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

bench("direct  ", () -> movement_system_direct(), 10000, 30)
bench("via each", () -> movement_system_via_each(), 10000, 30)
bench("direct  ", () -> movement_system_direct(), 50000, 15)
bench("via each", () -> movement_system_via_each(), 50000, 15)
