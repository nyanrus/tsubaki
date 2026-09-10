# julia: yes
# `function f(xs...)` -- 余ったものを、ぜんぶ集めて受ける。集まったものは
# タプル(Julia もタプル)。渡すほうの `f(xs...)` は tests/splat.jl に。

function count_all(xs...)
    return length(xs)
end
println(count_all(), " ", count_all(1), " ", count_all(1, 2, 3))

# 前のいくつかは、いつもどおり名前で受ける
function label(who, rest...)
    return who * " and " * string(length(rest))
end
println(label("a"), " ", label("a", 1, 2))

# 集まったものは、ふつうのタプル -- 添字も for も効く
function firstof(xs...)
    return xs[1]
end
println(firstof(7, 8))

function total(xs...)
    s = 0
    for x in xs
        s = s + x
    end
    return s
end
println(total(1, 2, 3), " ", total())

# 何が来ても、来たとおりに
function shape(xs...)
    return xs
end
println(shape(1, "a", :b))

# 数がぴったりの method のほうが先に選ばれる
two(a, b) = "two"
two(a, xs...) = "many"
println(two(1, 2), " ", two(1), " ", two(1, 2, 3))

# ばらして渡す側と、受ける側が、つながる
println(total(shape(4, 5, 6)...))
