# A JS value held as it is (`JSValue`), and the two doors beside it. Under
# Node the host's globals are Node's own, so `Math`/`JSON`/`Array` stand in
# here for what a browser would hand over (`document`, a `<browser>`, `h`).

# the one way in, and what it hands back
m = jsglobal("Math")
println(typeof(m))
println(m.floor(3.7), " ", m.max(2, 9))

# ...and the same call written without the variable in between
println(jsglobal("Math").sqrt(81.0))

# a property read comes back as the Tsubaki value it obviously is
println(typeof(m.PI), " ", m.PI > 3.14)

# an object stays a handle -- nothing is copied behind your back
json = jsglobal("JSON")
println(typeof(json))

# going out, a Dict is a plain object and an Array is an Array
d = Dict()
d["name"] = "tsubaki"
d["n"] = 2
println(json.stringify(d))
println(json.stringify([1, 2, 3]))

# coming back deep, only when asked
parsed = fromjs(json.parse("{\"a\": [1, 2], \"b\": \"hi\"}"))
println(typeof(parsed), " ", parsed["a"], " ", parsed["b"])

# a closure crosses as a real JS function
doubled = jsglobal("Array").of(1, 2, 3).map(x -> x * 2)
println(fromjs(doubled))

# a JS function held in a variable is callable by name, like any other
parse_int = jsglobal("parseInt")
println(parse_int("42") + 1)

# writing a property
g = jsglobal("globalThis")
g.tsubaki_says = "hello"
println(g.tsubaki_says)

# a global the host doesn't have says so
try
    jsglobal("no_such_global_here")
catch e
    println("caught: ", e)
end
