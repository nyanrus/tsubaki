# julia: vm
# 並びは、何の並びかを持っている。Julia ではどの配列も要素の型を持っていて、
# 中身が空になっても覚えている -- `Float64[]` は「空の Float64 の並び」で、
# 「空の何か」ではない。
#
# 木を歩く道は数だけの並びを float の箱で持つので、ここは Rust の VM だけが
# 本物の Julia と突き合わせる(`# julia: vm`)。言語の意味の話ではなく、
# 値の持ちかたの話なので。

# 書かれたものから決まる
println(typeof([1, 2]), " ", typeof([1, 2.0]), " ", typeof([1, "a"]), " ", typeof([]))
println(typeof([true]), " ", typeof(["a"]), " ", typeof([:a]), " ", typeof([nothing]))
println(typeof([[1, 2]]))

# 出しかたは、その型がわかるかどうかで決まる
println([1, 2], " ", [1, 2.0], " ", [1, "a"], " ", [])
println([true, false], " ", ["a"], " ", [:a], " ", [nothing], " ", [[1, 2]])

# 書いてあるほうが本当 -- 空になっても覚えている。入れられる形に直して入る
println(Float64[1, 2], " ", typeof(Float64[1, 2]))
println(Float64[], " ", typeof(Float64[]))
println(Int[3, 4], " ", typeof(Int[3, 4]))

# 型がばらけたら、いちばん近い共通の親まで登る
abstract type Animal end
struct Cat <: Animal
    n
end
struct Dog <: Animal
    n
end
println(typeof([Cat(1), Dog(2)]))
println(typeof([Cat(1), Cat(2)]), " ", [Cat(1), Cat(2)])

# 入れられないものは、入らない
xs = [1, 2]
try
    push!(xs, "x")
catch e
    println("caught")
end
# 入れられる形なら、その形にして入る
push!(xs, 3.0)
println(xs, " ", typeof(xs))

# `Any` の並びは、何でも受ける。何も書いていない `[]` も、それ
anys = Any[1, 2]
println(anys, " ", typeof(anys), " ", typeof([]))
push!(anys, "ok")
println(anys)

# 中身を言わない相手には、どの並びも合う
takes(v::Vector) = length(v)
println(takes([1, 2, 3]), " ", takes(["a"]))
println([1, 2] isa Vector, " ", [1, 2] isa Array, " ", [1, 2] isa AbstractArray)

# 切り出したものは、元と同じ何かの並び
println(typeof([1, 2, 3][1:2]))
