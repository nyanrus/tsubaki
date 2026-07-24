function safe_div(a, b)
    try
        if b == 0
            error("division by zero")
        end
        return a / b
    catch e
        println("  caught: ", e)
        return 0.0
    end
end
println(safe_div(10.0, 2.0))
println(safe_div(10.0, 0.0))
