# The seam layer: things that react, without anyone polling them.
#
# A game's score, its collision count, its camera -- these change rarely and
# are read from everywhere. Wiring them by hand means either polling every
# frame ("did the score change? did it change now?") or remembering to call
# every interested party from every place that writes. An Observable is the
# other shape: write once, and everyone who asked to know, knows.
#
# See observable.jl for the whole implementation -- it is 4 short methods.

include("observable.jl")

score = Observable(0)
combo = Observable(1)

# a listener: fires on every write, never in between
on(score) do v
    println("  [hud]   SCORE ", v)
end

# a second listener on the same signal -- they don't know about each other
on(score) do v
    if v >= 30
        println("  [sfx]   ding! (score crossed 30)")
    end
end

# a DERIVED value: one Observable listening to another. This is `@lift`'s
# hand-written form -- no macro needed to have the idea.
on(combo) do c
    println("  [hud]   COMBO x", c)
end

println("nlisteners(score) = ", nlisteners(score), "   [expect 2]")

println("frame 1: two hits")
score[] += 20

println("frame 2: one hit, combo up")
combo[] = 2
score[] += 10 * combo[]

println("frame 3: nothing happened")
# ...and nothing prints. No poll, no callback, no work at all.

println("final: score=", score[], " combo=", combo[], "   [expect score=40 combo=2]")
