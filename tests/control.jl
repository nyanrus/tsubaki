# julia: yes
# Control flow, operators, and the small arithmetic surface a program leans on
# constantly. Everything printed is a scalar or a string, and every loop that
# accumulates lives inside a function -- real Julia's top-level `while` is a
# soft scope, so a bare one would warn there and print nothing here.

function classify(n)
    if n < 0
        return "negative"
    elseif n == 0
        return "zero"
    elseif n < 10
        return "small"
    else
        return "large"
    end
end

println(-3, " -> ", classify(-3))
println(0, " -> ", classify(0))
println(5, " -> ", classify(5))
println(100, " -> ", classify(100))

function sum_while(n)
    total = 0
    i = 1
    while i <= n
        total += i
        i += 1
    end
    return total
end
println("1+..+5 = ", sum_while(5))

function sum_stepped()
    s = 0
    for k in 1:2:9
        s += k
    end
    return s
end
println("1+3+5+7+9 = ", sum_stepped())

function sum_float_range()
    acc = 0.0
    for x in 0.0:0.25:1.0
        acc += x
    end
    return acc
end
println("0+.25+.5+.75+1 = ", sum_float_range())

# ternary and short-circuit -- the right-hand side must not run
function loud(tag)
    println("  (evaluated ", tag, ")")
    return true
end
println("ternary: ", 3 > 2 ? "yes" : "no")
println("false && ...: ", false && loud("&&"))
println("true || ...: ", true || loud("||"))
println("true && ...: ", true && loud("&&"))

# integer vs float division, remainder, power
println(7 / 2, " ", 7 % 2, " ", 2^10, " ", 2.0^0.5)
println(-7 % 3, " ", 7 % -3)

# bitwise, at real Julia's arithmetic-like precedence (not &&/||'s)
println(6 & 3, " ", 6 | 3, " ", 6 << 2, " ", 6 >> 1)
# `~` はビットを裏返す。`!` と同じで、前に置く一つだけの演算子
println(~5, " ", ~0, " ", 6 & ~3)
println(1 << 3 + 1)

# comparisons across Int/Float
println(3 == 3.0, " ", 3 < 3.5, " ", 3 >= 3, " ", 1 != 2)

# numeric literal coefficients
x = 4
println(2x, " ", 2(x + 1), " ", 3x^2)

# nested loops with an early return
function first_pair(n)
    for a in 1:n
        for b in 1:n
            if a * b == 12 && a < b
                return "a=$a b=$b"
            end
        end
    end
    return "none"
end
println(first_pair(10))
