struct Point
    x
    y
end
p = Point(1.0, 2.0)
println(p)
println(p.x, " ", p.y)

mutable struct Counter
    n
end
c = Counter(0)
c.n = c.n + 1
c.n = c.n + 1
println(c.n)
