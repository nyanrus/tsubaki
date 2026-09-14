# julia: yes
# break と continue -- いちばん内側のループを抜ける / 次の turn へ。
# ネストしたループと、途中で開いたスコープ(if の体)をまたぐところを見ている。

for i in 1:3
    for j in 1:3
        if j == 2
            break
        end
        println(i, "-", j)
    end
end

function count_up()
    n = 0
    while true
        n += 1
        if n > 3
            break
        end
        if n == 2
            continue
        end
        println("n=", n)
    end
end
count_up()

for i in 1:5
    if i % 2 == 0
        continue
    end
    for j in 1:2
        if j == 2
            break
        end
        println(i, ":", j)
    end
end

# ループの中からの return は、ループではなく関数を抜ける
function find_first(xs, want)
    for x in xs
        if x == want
            return "found"
        end
    end
    return "no"
end
println(find_first([1, 2, 3], 2), " ", find_first([1, 2, 3], 9))
