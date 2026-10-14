# julia: yes
# `where` is a keyword only after a signature; elsewhere it is an ordinary name.

where = 3
println(where + 1)
function show_it(where)
    return where * 2
end
println(show_it(5))
struct Spot
    where
    b
end
t = Spot(7, 2)
println(t.where)
function g(x::T) where T
    return x
end
println(g(4))
function h(; where = 9)
    return where
end
println(h())
println(h(where = 11))
