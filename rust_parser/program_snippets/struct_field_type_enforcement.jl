struct Point
    x::Float
    y::Float
end
p = Point(1.0, 2.0)
println(p)
try
    Point(1.0, "bad")
catch e
    println("caught: ", e)
end
p.x = 9.0
println(p)
try
    p.y = "bad"
catch e
    println("caught: ", e)
end
