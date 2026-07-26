# julia: yes
# struct / mutable struct, inner constructors, `new`, and parametric structs.
# Fields are printed one at a time rather than whole structs: Tsubaki shows a
# struct as `Point(x=1, y=2)` where real Julia shows `Point(1, 2)`, and this
# file is meant to run identically under both.

struct Point
    x
    y
end

mutable struct Counter
    n
end

p = Point(3, 4)
println("p.x = ", p.x, ", p.y = ", p.y)

c = Counter(0)
c.n = c.n + 1
c.n += 10
println("c.n = ", c.n)

# a method on a struct is just a function that dispatches on it
norm2(p::Point) = p.x * p.x + p.y * p.y
println("norm2(p) = ", norm2(p))

# an inner constructor replaces the default one and can refuse to build
struct Positive
    value
    function Positive(v)
        if v < 0
            error("Positive: value must be non-negative")
        end
        new(v)
    end
end

println("Positive(5).value = ", Positive(5).value)
try
    Positive(-1)
catch e
    println("Positive(-1) refused")
end

# `new` may take FEWER args than there are fields -- what makes a
# self-referential struct constructible at all
mutable struct Node
    val
    next
    function Node(v)
        n = new(v)
        n.next = n
        return n
    end
end
n = Node(42)
println("n.val = ", n.val, ", n.next.val = ", n.next.val)

# parametric structs: the concrete parameter is inferred from the field
struct Box{T}
    value::T
end

struct KV{K,V}
    key::K
    value::V
end

bi = Box(5)
bf = Box(3.5)
println("Box(5).value = ", bi.value, ", Box(3.5).value = ", bf.value)

# dispatch on the parameter, not just on the outer name
describe(b::Box{Int}) = "an Int box holding $(b.value)"
describe(b::Box) = "some box holding $(b.value)"
println(describe(bi))
println(describe(bf))

kv = KV(1, "one")
println("KV: ", kv.key, " => ", kv.value)

# a struct holding a struct
struct Segment
    a
    b
end
seg = Segment(Point(0, 0), Point(3, 4))
println("segment dx = ", seg.b.x - seg.a.x, ", dy = ", seg.b.y - seg.a.y)
