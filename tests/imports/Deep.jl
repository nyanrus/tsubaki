# a module file that asks for another one: resolved against THIS file's
# directory, not against whoever imported this
module Deep
    import Shapes
    unit_circle() = Shapes.area(Shapes.Circle(1.0))
end
