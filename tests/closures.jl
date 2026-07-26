# julia: yes
# Closures: real lexical capture, both reading and mutating, plus functions
# taken and returned as ordinary values.

add1 = x -> x + 1
println("add1(41) = ", add1(41))

pair = (a, b) -> a * 10 + b
println("pair(3, 4) = ", pair(3, 4))

function make_adder(n)
    return x -> x + n
end
add5 = make_adder(5)
add100 = make_adder(100)
println("add5(10) = ", add5(10), ", add100(10) = ", add100(10))
println("the two adders don't share n: ", add5(0), " and ", add100(0))

# a named inner function closes over its enclosing function's locals, and can
# mutate them -- this is the scoping bug quicksort originally exposed, where
# every "local" was secretly one shared global
function counter()
    n = 0
    function bump()
        n = n + 1
        return n
    end
    return bump
end

b = counter()
println("bump: ", b(), " ", b(), " ", b())

# ...and calling the factory again makes a genuinely NEW one. This used to
# hand back the same counter twice over: an inner `function` was only a
# method on the global generic function of its name, and defining one with
# the same signature replaces it, so both names resolved to whichever ran
# last.
function counter_pair()
    n = 0
    function bump()
        n = n + 1
        return n
    end
    function peek()
        return n
    end
    return (bump, peek)
end

b1, p1 = counter_pair()
b2, p2 = counter_pair()
println("b1: ", b1(), " ", b1(), " ", b1(), " (peek ", p1(), ")")
println("b2: ", b2(), " (peek ", p2(), ")")

# an inner function can recurse by its own name
function factorial_of(n)
    function go(k)
        if k <= 1
            return 1
        end
        return k * go(k - 1)
    end
    return go(n)
end
println("factorial_of(6) = ", factorial_of(6))

# two same-named inner methods still choose by argument type
function describe_one(v)
    function label(x::Int)
        return "an int"
    end
    function label(x::String)
        return "a string"
    end
    return label(v)
end
println(describe_one(3), " / ", describe_one("x"))

# a closure passed to a function that only knows it is callable
function twice(f, x)
    return f(f(x))
end
println("twice(add5, 1) = ", twice(add5, 1))
println("twice(x -> x * x, 3) = ", twice(x -> x * x, 3))

# capture inside a loop body
function accumulate_steps(n)
    total = 0
    step = x -> x * 2
    for i in 1:n
        total += step(i)
    end
    return total
end
println("accumulate_steps(4) = ", accumulate_steps(4))

# recursion through a named local function
function fact(n)
    if n <= 1
        return 1
    end
    return n * fact(n - 1)
end
println("fact(10) = ", fact(10))
