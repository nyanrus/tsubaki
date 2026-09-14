# Not julia-compatible: this is about Tsubaki's OWN two collection types and
# how they are tagged (`Float`/`Int`, `Array{T}` with no element parameter on
# a plain Vector) -- see tests/known_gaps.jl for why those names differ.

# a numeric literal is a flat Vector; anything else is an Array
nums = [1.0, 2.0, 3.0]
mixed = ["a", 1, true]
empty = []
println(typeof(nums), " ", typeof(mixed), " ", typeof(empty))

# a homogeneous Array is tagged by what it actually holds
struct Named
    label
    value
end
items = [Named("a", 1.0), Named("b", 2.0)]
println(typeof(items), " length ", length(items))
push!(items, Named("c", 3.0))
println("after push!: ", length(items), ", last label ", items[end].label)

# indexing, slicing, and `end` arithmetic
println(nums[1], " ", nums[end], " ", nums[end - 1])
println(nums[2:3], " ", nums[2:end])

# a DECLARED element type is enforced even while the array is empty
strict = Array{Named}()
println(typeof(strict), " length ", length(strict))
push!(strict, Named("x", 1.0))
println("after push!: ", length(strict))
try
    push!(strict, 5.0)
catch e
    println("refused: ", e)
end

# Vector{T}(undef, n) / Matrix{T}(undef, m, n): real Julia's uninitialized
# allocation, every cell starting as nothing
u = Vector{Int}(undef, 3)
println("undef vector: ", length(u), " first = ", u[1])
u[1] = 7
u[2] = 8
u[3] = 9
println("after filling: ", u[1], " ", u[2], " ", u[3])

m = Matrix{Named}(undef, 2, 2)
m[1, 1] = Named("corner", 0.0)
println("boxed matrix: ", size(m), " [1,1].label = ", m[1, 1].label)

# typed array literals
ints = Int[1, 2, 3]
println(typeof(ints), " ", length(ints))

# comprehensions: numeric ones build a Vector, others an Array
squares = [i * i for i in 1:4]
labels = [Named("n$i", 1.0 * i) for i in 1:3]
println(typeof(squares), " ", typeof(labels))
println(squares)

# a 2D comprehension with two clauses builds a real Matrix
grid = [i + 10j for i = 1:3, j = 1:2]
println(typeof(grid), " ", size(grid), " grid[1,1] = ", grid[1, 1], ", grid[3,2] = ", grid[3, 2])

# single-argument broadcast
double(x) = x * 2
println(double.(nums))

# sorting and mapping through Tsubaki's own dispatch
by_value(n::Named) = n.value
println(map(by_value, sort(items; by = by_value, rev = true)))

# an empty comprehension is an Array, the same answer `[]` gives -- with nothing
# in it, "all numbers" is true of nothing, and a numeric Vector would then
# refuse the first thing appended to it
empty_c = [x * "!" for x in []]
println(typeof(empty_c), " ", length(empty_c), " ", typeof([]))
println(vcat(empty_c, ["a"]))
