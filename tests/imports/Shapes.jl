module Shapes
    struct Circle
        r
    end

    struct Square
        side
    end

    area(c::Circle) = 3.141592653589793 * c.r * c.r
    area(s::Square) = s.side * s.side
end
