# 添字も、名前のついた関数だった。`a[i]` は組み込みの入れものだけのもので
# はなくて、`getindex(a, i)` / `setindex!(a, v, i)` への呼び出し -- だから
# 自分の中身を並びとして持っている型も、同じ綴りで書ける。
#
# 実の Julia の `a[i]` は `Base.getindex` に降りるので、伸ばすには
# `Base.getindex(...)` と書く決まり。Tsubaki に Base は無く、名前は一つ
# `getindex` だけなので、ここは julia と突き合わせず、二つの runtime の
# 答えをそれぞれ記録する。

struct Grid
    cells
end

getindex(g::Grid, i) = g.cells[i]

function setindex!(g::Grid, v, i)
    g.cells[i] = v
end

g = Grid(["a", "b", "c"])
println(g[2])
g[3] = "z"
println(g[3], " ", g.cells)

# 組み込みの形が先に勝つ -- Dict も Array も、今までのまま
d = Dict("k" => 1)
println(d["k"])
xs = ["x", "y"]
xs[1] = "w"
println(xs)

# method が無ければ MethodError。言っていることは今までと同じで、言いかたが
# この言語のことばになった
struct Plain
    v
end

p = Plain(1)
try
    println(p[1])
catch e
    println("caught: ", e)
end
