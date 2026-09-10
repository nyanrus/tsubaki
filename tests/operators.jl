# 演算子も、名前のついた関数。`function +(a::P, b::P)` は、組み込みの `+` と
# 同じ表に一つ足す(実の Julia は `Base.:+` と書かせるので、ここは julia と
# 突き合わせない -- 綴りのほうがちがう)。
#
# 数の隣に名前を置くと掛け算になる(Julia の juxtaposition)ので、`40px` は
# `40 * px`。`*(n::Int, u::Symbol)` を一つ書けば、それが単位になる。

struct Money
    yen
end

function +(a::Money, b::Money)
    return Money(a.yen + b.yen)
end

function *(m::Money, n::Int)
    return Money(m.yen * n)
end

println(Money(120) + Money(80))
println(Money(120) * 3)

# 組み込みの道は、そのまま
println(1 + 2, " ", "a" * "b", " ", [1, 2] == [1, 2])

struct Len
    n
    unit
end

function *(n::Int, u::Symbol)
    return Len(n, u)
end

function *(n::Float64, u::Symbol)
    return Len(n, u)
end

px = :px
rem = :rem

println(40px, " ", 1.5rem)

w = 32
println(w * px)

# 自分で組んだものを、読み返せる
style = Dict(:width => 40px, :padding => (4px, 0))
println(style)
println(length((4px, 0)))
