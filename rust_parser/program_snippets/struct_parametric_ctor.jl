struct Box{T}
    value
end
println(typeof(Box(5)))
println(typeof(Box(3.5)))

struct PositiveBox
    value
    function PositiveBox(v)
        if v < 0
            error("value must be non-negative")
        end
        new(v)
    end
end
println(PositiveBox(5))
try
    PositiveBox(-1)
catch e
    println("caught: ", e)
end
