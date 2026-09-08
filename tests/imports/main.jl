# The asking happens from HERE, so every file named below is looked for in
# this directory -- tests/imports/ -- and not in tests/, where the test that
# included this file lives. That is the whole rule: next to whoever asked.

import Shapes
println("qualified: ", Shapes.area(Shapes.Circle(1.0)))

# `using` afterwards merges the bare names. Asking a second time reads nothing
# (the module is already here) and merges nothing twice -- a method that came
# along once would otherwise tie with itself.
using Shapes
println("bare after using: ", area(Circle(2.0)))
println("same tag either way: ", typeof(Shapes.Circle(1.0)), " / ", typeof(Circle(1.0)))
using Shapes
println("using twice is still fine: ", area(Square(3.0)))

# .tsubaki is looked for too, after .jl
import Toolbox: hammer
println("selective import: ", hammer())
try
    saw()
catch e
    println("saw was not imported: ", e)
end
println("but qualified still works: ", Toolbox.saw())

# a module inside a module, in a file
using Nested.Inner
println("nested: ", depth(), " / ", Nested.shallow())

# a module file that asks for another one, from inside its own module body:
# Shapes is found beside Deep.jl, and lands as `Shapes`, not `Deep.Shapes`
import Deep
println("transitive: ", Deep.unit_circle())

# the file is there, but it is not what it was asked to be
try
    import Mislabelled
catch e
    println("mislabelled: ", e)
end

# two files that ask each other
try
    import Loop
catch e
    println("a knot: ", e)
end

# the knot left nothing half-open behind it
import After
println("after: ", After.ok())
