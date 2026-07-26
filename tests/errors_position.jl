# Not julia-compatible: this is about where TSUBAKI says an error happened.
# The program deliberately dies, so its golden is the failure report itself --
# file, line, and the chain of calls that got there.
#
# Keep the line numbers below in mind when editing this file: the golden
# records them, so inserting a line above `boom` will (correctly) fail this
# test until it is re-recorded.

function boom(x)
    return x.no_such_field
end

function middle(x)
    return boom(x)
end

function outer(x)
    return middle(x)
end

# a caught error must NOT leave its position behind for the later, real one
try
    error("this one is handled")
catch e
    println("handled: ", e)
end

println("about to fail")
outer(42)
println("never reached")
