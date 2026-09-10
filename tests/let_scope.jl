# julia: yes
# `let ... end` -- 新しいスコープを開く一つだけの形(`begin` は開かない)。
# 束ねる値は**外**で作ってから中に置くので、`let x = x` が外の x を捕まえる。

x = "outer"
let x = "inner"
    println(x)
end
println(x)

n = 1
let n = n + 10, m = 2
    println(n, " ", m)
end
println(n)

# 何も束ねなくても、スコープは開く
let
    y = 5
    println(y)
end

# 値は、最後の文のもの
v = let a = 3
    a * a
end
println(v)

# 関数の中でも、ループの中でも
function f()
    t = 0
    for i in 1:3
        t = t + let k = i * 2
            k + 1
        end
    end
    return t
end
println(f())

# 中から抜けるときは、そのスコープも一緒に降りる
for i in 1:5
    let k = i
        if k == 3
            break
        end
        print(k, " ")
    end
end
println()
for i in 1:5
    let k = i
        if k % 2 == 0
            continue
        end
        print(k, " ")
    end
end
println()
