println("before")
try
    host("exit", 3)
catch e
    println("CAUGHT: the exit was catchable")
end
println("AFTER: the program carried on")
