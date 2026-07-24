# Compares the OLD way to bulk-export a SoA-eligible component's data
# (query -> get_component -> push! per entity, e.g. ecs_bounce_batched.jl's
# own rects-building loop) against soa_flatten (bin/ecs.ml), which reads the
# SAME underlying columns directly, with no query/get_component/push! round
# trip through the interpreter at all.
#
# Both walk entities low-id-first (query_range scans its id range downward but
# PREPENDS, so its list comes out ascending; soa_flatten walks the presence
# bitmap upward), so the two outputs line up element for element. This file
# used to reverse new_out's pairs before comparing, on the belief that query
# came out highest-id-first -- it doesn't, and the check had been quietly
# printing FAIL. Neither function PROMISES an order; if one ever changes,
# this comparison is where it will say so.
#
# Run: make run FILE=examples/ecs_soa_flatten_bench.jl

struct Position
    x::Float
    y::Float
end

n = 20000

i = 0
while i < n
    e = create_entity()
    add_component!(e, Position(i * 1.0, i * 2.0))
    i = i + 1
end

t0 = time()
old_out = []
for e in query(["Position"])
    p = get_component(e, "Position")
    push!(old_out, p.x)
    push!(old_out, p.y)
end
t1 = time()
old_elapsed = t1 - t0

t0 = time()
new_out = soa_flatten("Position", ["x", "y"])
t1 = time()
new_elapsed = t1 - t0

println("n=", n, "  old (query+get_component+push!): ", old_elapsed, "s  new (soa_flatten): ", new_elapsed, "s  speedup: ", old_elapsed / new_elapsed, "x")

# correctness check: same entities, same order, so this is element for element.
ok = length(old_out) == length(new_out)
if ok
    idx = 1
    while idx <= length(old_out)
        if old_out[idx] != new_out[idx]
            ok = false
        end
        idx = idx + 1
    end
end
println(ok ? "PASS: soa_flatten matches the old per-entity loop, entity for entity" : "FAIL: outputs differ")
