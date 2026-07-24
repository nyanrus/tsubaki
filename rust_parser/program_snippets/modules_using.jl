module Shapes
struct Circle
    r
end
area(c::Circle) = pi * c.r * c.r
end

c1 = Shapes.Circle(1.0)
println(Shapes.area(c1))

using Shapes
c2 = Circle(2.0)
println(area(c2))
