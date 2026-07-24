abstract type Being end
struct Human <: Being
    name
end
humans = [Human("a"), Human("b")]
function census(a::Array{Being})
    println(length(a))
end
census(humans)

println(typeof(3))
println(isa(3, Int))
println(isa(3, Number))
println(isa(3, Float))

items = [Human("a")]
items = push!(items, Human("b"))
println(length(items))
println(typeof(items))
