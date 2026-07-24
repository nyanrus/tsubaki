add1 = x -> x + 1
println(add1(41))

function make_adder(n)
    return x -> x + n
end
adder5 = make_adder(5)
println(adder5(10))

classify = function (x)
    if x < 0
        return "negative"
    end
    return "non-negative"
end
println(classify(-3))
println(classify(3))
