# Base's collection vocabulary, and the two language holes that kept it out of
# reach: a named function couldn't be a value, and `[]` was a numeric Vector.
#
# Everything here was written by hand at the call site before -- keeping a
# paddle on screen took two `if`s; keel.jl rebuilt its node list with a loop
# because there was no `filter` to call.

struct Ball
    y::Float
    w::Float
end

function fell(b::Ball)
    b.y > 100.0
end

function weight(b::Ball)
    b.w
end

# ---- `[]` is an empty Array of ANYTHING (Julia's Vector{Any}), not of numbers
balls = []
push!(balls, Ball(150.0, 3.0))
push!(balls, Ball(10.0, 1.0))
push!(balls, Ball(200.0, 2.0))
println("balls = ", length(balls), "  typeof = ", typeof(balls))

# ---- a named function is a value: `fell`, not `b -> fell(b)`
println("filter(fell, balls)   -> ", length(filter(fell, balls)), " fell")
println("count(fell, balls)    -> ", count(fell, balls))
println("any(fell, balls)      -> ", any(fell, balls), "   all -> ", all(fell, balls))
println("map(weight, balls)    -> ", map(weight, balls))

# ---- sort takes `by =` and `rev =`, and orders through Tsubaki's own `<`
println("sort by weight        -> ", map(weight, sort(balls; by = weight)))
println("sort by weight, rev   -> ", map(weight, sort(balls; by = weight, rev = true)))

# ---- the scalar three a game reaches for constantly
paddle_x = clamp(340.0, 0.0, 300.0)
println("clamp(340, 0, 300)    -> ", paddle_x, "   max(3, 5.5) -> ", max(3, 5.5), "   min(2, 9) -> ", min(2, 9))
println("sum(1:4) -> ", sum(1:4), "   maximum(map(weight, balls)) -> ", maximum(map(weight, balls)))

# ---- push!'s other half
stack = [1.0, 2.0, 3.0]
top = pop!(stack)
println("pop!([1,2,3])         -> ", top, "  leaving ", stack)

# ---- Dict: no `=>` literal yet (see README), so: Dict(), then d[k] = v
score = Dict()
score[:red] = 7
score[:blue] = 12
score[:red] = score[:red] + 1
println("score                 -> ", score, "   length ", length(score))
println("haskey(:red) ", haskey(score, :red), "   get(:green, 0) -> ", get(score, :green, 0))
for (team, points) in score
    println("  ", team, ": ", points)
end
# a Dict filtered by its (key, value) pairs stays a Dict
println("filter(p -> p[2] > 10, score) -> ", filter(p -> p[2] > 10, score))
delete!(score, :blue)
println("after delete!(:blue)  -> ", score)
