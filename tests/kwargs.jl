# julia: yes
# Keyword arguments: a side channel that never takes part in dispatch, and
# positional defaults, which do change the arities a method answers to.

function greet(name; greeting = "Hello", punct = "!")
    return "$greeting, $name$punct"
end

println(greet("shiro"))
println(greet("shiro"; greeting = "yo"))
println(greet("shiro"; punct = "?"))
println(greet("shiro"; greeting = "yo", punct = "?"))
println(greet("shiro"; punct = "?", greeting = "yo"))

# keywords are NOT part of the signature -- these two dispatch purely on the
# positional argument's type
describe(n::Int; unit = "") = "int $n$unit"
describe(s::String; unit = "") = "string $s$unit"
println(describe(3))
println(describe(3; unit = "cm"))
println(describe("x"; unit = "!"))

# positional defaults, a suffix of the parameter list
function span(a, b = 10, c = 100)
    return a + b + c
end
println(span(1), " ", span(1, 2), " ", span(1, 2, 3))

# a default expression is evaluated at call time, and can see earlier params
function pad(text, width = 8, fill = "-")
    n = width - length(text)
    out = text
    for i in 1:n
        out = out * fill
    end
    return out
end
println(pad("ab"))
println(pad("ab", 5))
println(pad("ab", 5, "."))

# keywords passed through a wrapper
function shout(name; greeting = "HI")
    return greet(name; greeting = greeting, punct = "!!")
end
println(shout("kuro"))
println(shout("kuro"; greeting = "OI"))
