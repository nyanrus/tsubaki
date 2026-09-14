# julia: yes
# Base's collection vocabulary over Arrays, Ranges and Dicts. Arrays of
# STRINGS throughout, on purpose: a numeric literal Vector is float-backed
# here and prints differently from real Julia's (see tests/known_gaps.jl),
# and this file is meant to run identically under both.

names = ["delta", "al", "charlie", "bo"]

println(length(names), " ", names[1], " ", names[end], " ", names[end - 1])
println(names[2:3])

long(s) = length(s) > 2
println(filter(long, names))
println(count(long, names))
println(any(long, names), " ", all(long, names))
println(map(length, names))

println(sort(names))
println(sort(names; rev = true))
println(sort(names; by = length))

push!(names, "echo")
println(length(names), " ", names[end])
last = pop!(names)
println("popped ", last, ", left ", length(names))

# ranges reduce without ever being materialized
println(sum(1:100), " ", maximum(1:10), " ", minimum(3:7), " ", length(1:2:9))

# comprehension over a range, collecting strings
tags = ["t$i" for i in 1:4]
println(tags)

# a Dict, with insertion order preserved on iteration
scores = Dict()
scores["red"] = 8
scores["blue"] = 12
scores["green"] = 3

println(length(scores), " ", scores["blue"], " ", haskey(scores, "red"), " ", haskey(scores, "pink"))
println(get(scores, "pink", 0))

function total_of(d)
    total = 0
    for (k, v) in d
        total += v
    end
    return total
end
println("total ", total_of(scores))

delete!(scores, "green")
println(length(scores), " ", haskey(scores, "green"))

# min/max/clamp, the scalar three
println(max(3, 5), " ", min(2, 9), " ", clamp(340, 0, 300), " ", clamp(-5, 0, 300))

# a tuple, and destructuring it
function minmax_of(xs)
    lo = xs[1]
    hi = xs[1]
    for x in xs
        if x < lo
            lo = x
        end
        if x > hi
            hi = x
        end
    end
    return (lo, hi)
end
lo, hi = minmax_of(["pear", "apple", "quince"])
println(lo, " ", hi)

# swapping through a destructure with full lvalue targets
letters = ["a", "b", "c"]
letters[1], letters[3] = letters[3], letters[1]
println(letters)
