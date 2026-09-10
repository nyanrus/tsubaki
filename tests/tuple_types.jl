# julia: vm
# タプルが、自分の中身の型を持っていること。**Rust の VM だけ**が本物の Julia と
# 突き合わせる -- 木を歩くほうは値が「何であるか」ではなく「どう書くか」の名前
# (`Int` / `Float`)を答えるので、ここは合わない(それは前からの、持ちかたの差)。
#
# 空の `()` はまだ書けないので、余りを集めるほうから取る。

println(typeof((1, 2)))
println(typeof(("a", :b)))
println(typeof((1, 2.0, true)))

# 入れ子。中身の中身まで
println(typeof(((1, 2), 3)))

# 並びが「何の並びか」を言うとき、タプルもちゃんと名前を持っている
println(typeof([(1, 2)]))
# 形の違うタプルが混ざったら、要素ごとにいちばん近い共通の親へ
println(typeof([(1, 2), ("a", :b)]))

# 余りを集めたものも、ふつうのタプル。ゼロ個なら `Tuple{}`
rest(xs...) = typeof(xs)
println(rest(), " ", rest(1), " ", rest(1, "a"))

# 中身の型を持つということは、入れられないものを断れるということ
xs = [(1, 2)]
push!(xs, (3, 4))
println(typeof(xs), " ", length(xs))
try
    push!(xs, ("a", :b))
catch e
    println("push! refused")
end
