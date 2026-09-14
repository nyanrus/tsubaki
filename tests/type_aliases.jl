# julia: yes
# `Float64` and `Int64` -- real Julia's own names for the two default numeric
# types. Tsubaki's tags are `Float` and `Int`; these are accepted everywhere a
# type name can be written and normalized on the way in, so the identical file
# runs under real Julia. (`typeof` still answers `Float`/`Int` -- that is the
# tag itself, see tests/known_gaps.jl.)

# ---- parameter and return annotations
function scale(x::Float64, k::Int64)
    return x * k
end
println(scale(2.5, 3))

# dispatch really is on the aliased types, not on Any
kind(x::Float64) = "a float"
kind(n::Int64) = "an int"
kind(s::String) = "a string"
println(kind(1.5), " / ", kind(2), " / ", kind("s"))

# ---- struct fields, enforced
struct Reading
    value::Float64
    count::Int64
end
r = Reading(1.5, 2)
println(r.value, " ", r.count)

# ---- typed array literals and undef allocation
v = Float64[1.0, 2.0]
push!(v, 3.0)
println(v)

ints = Int64[10, 20]
println(length(ints), " ", ints[2])

u = Vector{Float64}(undef, 3)
u[1] = 1.5
u[2] = 2.5
u[3] = 3.5
println(u[1], " ", u[2], " ", u[3])

# ---- isa
println(isa(1.0, Float64), " ", isa(1, Int64), " ", isa(1.0, Int64), " ", isa("s", Float64))

# ---- conversion constructors
println(Float64(3), " ", Int64(4.0), " ", sqrt(Float64(16)))

# ---- Union alternatives
function twice(x::Union{Int64,Float64})
    return x * 2
end
println(twice(3), " ", twice(1.5))

# ---- a parametric struct instantiated at the aliased type
struct Box{T}
    value::T
end
describe(b::Box{Float64}) = "a float box"
describe(b::Box{Int64}) = "an int box"
println(describe(Box(1.5)), " / ", describe(Box(2)))

# ---- dispatch on the type ITSELF
name_of(::Type{Float64}) = "float64"
name_of(::Type{Int64}) = "int64"
println(name_of(Float64), " ", name_of(Int64))
