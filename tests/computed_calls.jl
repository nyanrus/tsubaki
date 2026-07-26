# julia: yes
# Calling what an expression EVALUATED to, rather than a name: `f()()`,
# `v[1](x)`, `(x -> x + 1)(3)`. None of these parsed at all before -- a "("
# was only ever the start of a named call's argument list.

# the shape that made this worth having: a factory's result, called at once
function make_adder(n)
    return x -> x + n
end
println(make_adder(5)(10))
println(make_adder(100)(1))

# a function returning a function, by name
f() = 1
g() = f
println(g()())

# out of a container
fs = [x -> x * 2, x -> x * 10]
println(fs[1](21), " ", fs[2](3))

d = Dict()
d["double"] = x -> x * 2
d["negate"] = x -> -x
println(d["double"](8), " ", d["negate"](3))

# a lambda literal, called where it stands
println((x -> x * x)(7))
println(((a, b) -> a * 10 + b)(3, 4))

# chained
h() = () -> 42
println(h()())

# several arguments, and nesting
pair_maker() = (a, b) -> a + b
println(pair_maker()(20, 22))
println(make_adder(make_adder(1)(2))(30))

# a plain named call is untouched by any of this
square(n) = n * n
println(square(9))

# ...and so is a qualified one
module Tools
    twice(x) = x * 2
end
println(Tools.twice(21))

# whitespace still separates statements. The line below BEGINS with "(" and
# follows one that ends in ")" -- if the new rule looked at anything less than
# "no space before the (", this would be read as square(3)(n > 0) instead.
n = square(3)
(n + 1)
println("n is ", n)
