# julia: yes
# `xs .+ 1` -- 一つずつに配る。点の無いほうの演算子を、要素ごとに呼ぶ。
#
# 数の並びは float で書いてある: 木を歩く道は、数だけの並びをぜんぶ float で
# 持つので(tests/arrays.jl のいちばん上に、その話がある)、Int で書くと本物の
# Julia と表示が食い違ってしまう。broadcast そのものの話ではない。

xs = [1.0, 2.0, 3.0]
ys = [10.0, 20.0, 30.0]

# 片側が一つだけなら、その一つが全部の相手になる
println(xs .+ 1)
println(xs .* 2)
println(2 .* xs)
println(xs .^ 2)

# 両側が並びなら、同じ場所どうし
println(xs .+ ys)
println(ys ./ xs)
println(ys .- xs)

# 点の無いほうと同じ強さで結ぶ -- `xs .* 2 .+ 1` は掛けてから足す
println(xs .* 2 .+ 1)

# 数だけの話ではない
println(["a", "b"] .* "!")
println("<" .* ["x", "y"] .* ">")

# `f.(xs)` は前から読めていた。並べて置いておく
sq(x) = x * x
println(sq.(xs))
