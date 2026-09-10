# julia: yes
# タプルの「形」で method が選べること。中身の型を持つようになったので、
# `t::Tuple{Int64, Int64}` が書けて、そして**当たる**(前は parse は通るのに
# 決して当たらなかった)。
#
# 印字するのは答えの文字列だけ。型の名前そのものは二つの runtime で綴りが
# 違う(木を歩くほうは `Int`、VM は `Int64`)ので、そちらは tuple_types.jl へ。

g(t::Tuple{Int64, Int64}) = "two ints"
g(t::Tuple{Number, Number}) = "two numbers"
g(t::Tuple) = "any tuple"

# いちばん狭いものが勝つ
println(g((1, 2)))
# Julia のタプルは共変 -- `Tuple{Int64, Float64}` は `Tuple{Number, Number}`
println(g((1, 2.0)))
println(g((1.5, 2.5)))
# 数が合わなければ、中身を言わないほうへ落ちる
println(g((1, 2, 3)))
println(g(("a", :b)))

# 空のタプル。`()` はまだ書けないので、余りを集めるほうから
rest(xs...) = xs
println(g(rest()))

# 入れ子
println(g(((1, 2), (3, 4))))

# 中身を言う注釈しか無いときは、合わなければ当たらない
only_ints(t::Tuple{Int64, Int64}) = "ok"
println(only_ints((7, 8)))
try
    println(only_ints(("a", "b")))
catch e
    println("caught")
end
