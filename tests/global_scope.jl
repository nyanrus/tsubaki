# julia: yes
# Assigning inside a function. A name that is only global is only global to
# READ there: assigning it makes a local, unless the function says `global`.

x = 10

function shadow()
    x = 99
    return x
end
println(shadow())
println(x)

function bump()
    global x
    x = x + 1
    return x
end
println(bump())
println(x)

function set_it(v)
    global x = v
    return nothing
end
set_it(7)
println(x)

# a name first created by `global` inside a function
function make_g()
    global made = 5
    return made
end
println(make_g())
println(made)

# several names at once
a = 1
b = 2
function both()
    global a, b
    a = 10
    b = 20
    return a + b
end
println(both())
println(a, " ", b)

# a loop inside a function: the same rule -- it does not touch the global
y = 100
function loop_local()
    s = 0
    for i in 1:3
        y = i
        s = s + y
    end
    return s
end
println(loop_local())
println(y)

# a closure still mutates the enclosing FUNCTION's local
function counter()
    n = 0
    inc = () -> (n = n + 1)
    inc()
    inc()
    return n
end
println(counter())

# a global is still there to read
z = 3
function read_z()
    return z * 2
end
println(read_z())
