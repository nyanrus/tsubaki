# @each: turns `for e in (Position, Velocity) ... end` into a real
# `for e in query(["Position","Velocity"]) ... end` with
# `position = get_component(e, "Position")` / `velocity = get_component(e,
# "Velocity")` spliced in ahead of the caller's own body -- all built from
# plain get_component/query/for calls, so the Host VM/SoA compiler
# (Compile.try_compile_host) should still recognize and specialize them
# exactly as if the user had hand-written the expanded form.

macro each(forloop)
    entity_sym = forloop.args[1]
    iter_call = forloop.args[2] # each_kinds(Position, Velocity) -- a bare
                                 # ECall used only as a syntactic container
                                 # for the kind names ((a,b) tuple literals
                                 # can't appear in a for-loop's iterator
                                 # position -- see parser.ml)
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

@each for e in each_kinds(Position, Velocity)
    add_component!(e, Position(position.x + velocity.dx, position.y + velocity.dy))
end

moved = get_component(moving, "Position")
println("moving's Position after @each step: (", moved.x, ", ", moved.y, ")  [expect (1.0, 2.0)]")
untouched = get_component(still, "Position")
println("still's Position (no Velocity, must be untouched): (", untouched.x, ", ", untouched.y, ")  [expect (5.0, 5.0)]")
