# julia: yes
# `xs...` -- ばらして渡す。呼び出しの引数のところにだけ立つ印で、そこに
# あるものを、並べられるものとしてほどく。

function three(a, b, c)
    return a * "-" * b * "-" * c
end

parts = ["x", "y", "z"]
println(three(parts...))

# 一部だけばらす、という書きかたもできる
println(three("a", ["b", "c"]...))

# タプルも、そのまま
t = ("p", "q")
println(three("o", t...))

# 呼ばれるほうは、名前のない関数でもいい
both = (a, b) -> a * b
println(both(["<", ">"]...))

# range は、立ち会う数をほどく
function add3(a, b, c)
    return a + b + c
end
println(add3((1:3)...))

# struct を建てるときも同じ
struct Sides
    left
    right
end
s = Sides(["l", "r"]...)
println(s.left, " ", s.right)

# タプルそのものが、並べられるもの -- for でも回る
for x in ("m", "n")
    print(x)
end
println()
