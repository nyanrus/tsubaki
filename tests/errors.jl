# Not julia-compatible: error MESSAGES are Tsubaki's own wording, which is
# exactly what this file is here to pin down.

# a user error, raised and caught
try
    error("something went wrong")
catch e
    println("caught: ", e)
    println("  isa Exception: ", isa(e, Exception), ", isa ErrorException: ", isa(e, ErrorException))
    println("  e.msg = ", e.msg)
end

# the interpreter's own failures are ordinary catchable values, each with a
# real type
describe(n::Int) = "int"
try
    describe("nope")
catch e
    println("caught: ", e)
    println("  isa MethodError: ", isa(e, MethodError), ", isa DimensionMismatch: ", isa(e, DimensionMismatch))
end

try
    nonexistent_name + 1
catch e
    println("caught: ", e, "  isa UndefVarError: ", isa(e, UndefVarError))
end

struct Strict
    n::Int
end
try
    Strict("nope")
catch e
    println("caught: ", e, "  isa TypeError: ", isa(e, TypeError))
end

d = Dict()
try
    d["missing"]
catch e
    println("caught: ", e)
end

try
    v = [1.0, 2.0]
    v[10]
catch e
    println("caught: ", e, "  isa BoundsError: ", isa(e, BoundsError))
end

try
    A = [1.0 2.0; 3.0 4.0]
    b = [1.0, 2.0, 3.0]
    A * b
catch e
    println("caught: ", e, "  isa DimensionMismatch: ", isa(e, DimensionMismatch))
end

# throw() passes ANY value through untouched -- a user's own struct included
struct MyError
    code
end
try
    throw(MyError(42))
catch e
    println("caught a MyError, code = ", e.code, ", isa MyError: ", isa(e, MyError))
end

# a catch block's value is the try/catch's value, and execution continues
function safe_div(a, b)
    try
        if b == 0
            error("division by zero")
        end
        return a / b
    catch e
        return -1.0
    end
end
println("safe_div(6, 3) = ", safe_div(6, 3), ", safe_div(1, 0) = ", safe_div(1, 0))

# an error thrown deep inside is caught at the top
function level3()
    error("from level 3")
end
level2() = level3()
level1() = level2()
try
    level1()
catch e
    println("caught from three frames down: ", e)
end
println("still running")
