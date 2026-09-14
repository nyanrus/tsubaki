# 二枚目。drop の役。一枚目が置いたものを、名前で引く。
println(twice(21))
println(shared + 2)
println(add(1))
println(add(1, 5))
println(tagged(7))
println(tagged(7, label = "m"))
println(describe(Point(1, 2)))

# 同じ署名で書き直したら、置きかわる(Julia と同じ)
function describe(p::Point)
    return "point, again"
end
println(describe(Point(3, 4)))

doubled = [twice(n) for n in 1:3]
println(doubled)

double = x -> x * 2
println(double(5))
