# Not julia-compatible: real Julia writes `using .Shapes` for a module defined
# in the same file, and treats `export` as load-bearing. Tsubaki's `using` is
# a bare name and merges everything the module declared (see README).

module Shapes
    abstract type Shape end

    struct Circle <: Shape
        r
    end

    struct Square <: Shape
        side
    end

    area(c::Circle) = 3.141592653589793 * c.r * c.r
    area(s::Square) = s.side * s.side

    # a bare call from inside the module resolves within the module
    ring_area(outer, inner) = area(Circle(outer)) - area(Circle(inner))
end

# qualified access works with no `using` at all, at any chain length
c1 = Shapes.Circle(1.0)
println("Shapes.area(c1) = ", Shapes.area(c1))
println("Shapes.area(Shapes.Square(3.0)) = ", Shapes.area(Shapes.Square(3.0)))

# before `using`, the bare names are not in scope
try
    Circle(1.0)
catch e
    println("bare Circle before using: ", e)
end

using Shapes

c2 = Circle(2.0)
println("after using -- area(c2) = ", area(c2))
println("same tag either way: ", typeof(c1), " / ", typeof(c2))
println("ring_area(2.0, 1.0) = ", Shapes.ring_area(2.0, 1.0))

# qualified access is strict: no silent fallback to a global
try
    Shapes.nope(1)
catch e
    println("Shapes.nope: ", e)
end

# two modules, same member name, unrelated types -- both coexist
module Metric
    label(x::Int) = "Metric saw an Int"
end

module Imperial
    label(x::String) = "Imperial saw a String"
end

using Metric
using Imperial
println(label(5))
println(label("x"))

# nested modules
module Outer
    module Inner
        depth() = "two levels down"
    end
    shallow() = "one level down"
end

println(Outer.shallow())
println(Outer.Inner.depth())
using Outer.Inner
println(depth())

# import binds only the named members bare
module Toolbox
    hammer() = "bang"
    saw() = "zzz"
end

import Toolbox: hammer
println(hammer())
try
    saw()
catch e
    println("saw was not imported: ", e)
end
println("but Toolbox.saw() still works: ", Toolbox.saw())
