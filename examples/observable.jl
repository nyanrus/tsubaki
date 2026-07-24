# Observable -- a value you can watch. Makie.jl / Observables.jl's own core,
# and nothing more than its core.
#
#     score = Observable(0)
#     on(score) do v            # a signal, not a per-frame poll
#         println("score is now ", v)
#     end
#     score[] += 10             # every listener hears it
#
# The whole thing is ordinary Tsubaki -- an inner constructor for the defaulted
# listener list, and `getindex`/`setindex!` methods, which is exactly what
# `obs[]` and `obs[] = v` mean in real Julia. Nothing in the interpreter knows
# the word "Observable".
#
# Keep it COARSE. One Observable per seam -- a score, a collision count, a
# camera, the window size. Never one per entity: a listener fires on every
# write, so a per-entity Observable turns a 10k-entity frame into 10k callback
# storms, which is the cliff Makie users fall off. Entities have components
# (see ecs_type_keys.jl); seams have Observables.

mutable struct Observable
    value
    listeners::Array
    # an INNER constructor: `Observable(0)` gives the listener list its empty
    # default. (Tsubaki has no outer constructors -- naming a method after a
    # struct takes over its construction entirely -- so the defaulted field
    # has to be filled in here, with `new`. Real Julia writes it the same way.)
    Observable(v) = new(v, Array{Any}())
end

# `obs[]` -- read
getindex(o::Observable) = o.value

# `obs[] = v` (and `obs[] += v`) -- write, then tell everyone who asked
function setindex!(o::Observable, v)
    o.value = v
    for f in o.listeners
        f(v)
    end
    v
end

# `on(obs) do v ... end` -- listen. The do-block's closure arrives FIRST,
# as in real Julia, which is why this reads `on(f, o)` and not `on(o, f)`.
function on(f, o::Observable)
    push!(o.listeners, f)
    f
end

# how many are listening -- handy in a test, and a way to SEE the cliff above
nlisteners(o::Observable) = length(o.listeners)
