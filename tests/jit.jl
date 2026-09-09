# Not julia-compatible, for one reason: assigning to a name that already
# exists at the top level (`counter = counter + 1` inside `bump()` below)
# writes the GLOBAL here, where real Julia would make it a fresh local and
# raise UndefVarError. That is a deliberate simplification, not an accident --
# see tests/known_gaps.jl. Every numeric answer in this file was still checked
# against real Julia by hand.
#
# The second execution path: a zero-parameter function whose whole body is
# restricted-numeric gets compiled to bytecode and run by the Rust kernel's
# own interpreter instead of being tree-walked. Nothing here should be able
# to TELL -- same answers either way, which is the entire claim. See
# AST_IN_RUST_EXPERIMENT.md.

# the shape that is eligible: zero parameters, numeric locals only
function pisum_small()
    s = 0.0
    for k = 1:10000
        s += 1.0 / (k * k)
    end
    return s
end
println("pisum_small() = ", pisum_small())
println("called twice, same answer: ", pisum_small() == pisum_small())

function loop_sum()
    total = 0
    for i in 1:100
        total += i
    end
    return total
end
println("loop_sum() = ", loop_sum())

function nested_loops()
    acc = 0
    for i in 1:10
        for j in 1:10
            acc += i * j
        end
    end
    return acc
end
println("nested_loops() = ", nested_loops())

function with_branches()
    n = 0
    for i in 1:20
        if i % 3 == 0
            n += i
        elseif i % 5 == 0
            n -= 1
        end
    end
    return n
end
println("with_branches() = ", with_branches())

function while_loop()
    x = 1.0
    n = 0
    while x > 0.001
        x = x / 2.0
        n += 1
    end
    return n
end
println("while_loop() = ", while_loop())

# the regression that mattered: a zero-parameter function READING an outer
# variable must not get a private, zero-initialized slot for it. This printed
# 1, 1, 0 once -- a wrong answer, with nothing to signal it.
counter = 0
function bump()
    counter = counter + 1
    return counter
end
println(bump())
println(bump())
println(counter)

# reading (never writing) an outer variable
scale = 3
function scaled()
    return scale * 2
end
println("scaled() = ", scaled())

# a zero-parameter function that is NOT eligible (it calls another function,
# and handles a string) still gives the same answer through the tree-walker
function describe_total()
    t = loop_sum()
    return "total is $t"
end
println(describe_total())

# the operators the interpreter answers itself, inside an eligible shape. The
# compiled path sends a binop straight to dispatch, where these have no method
# at all -- so `pair()` used to be "MethodError: no method matching
# =>(String, Int)" while the very same expression at the top level was a Pair.
pair() = "a" => 1
same() = 1 === 1
differs() = 1 !== 2
member() = 3 in 1:5
println(pair(), " ", same(), " ", differs(), " ", member())
