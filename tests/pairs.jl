# NOT julia: yes -- the shapes here are all valid Julia, but two of the printed
# answers can't match. Tsubaki's Dict keeps insertion order (real Julia's is
# unordered, so it prints its own way), and `typeof` here answers a bare name
# where real Julia answers `Pair{String, Int64}`.
#
# `a => b` is a Pair, and a Dict can be written with them -- what a table of
# anything (props for a view, options, a lookup) is spelled with. Along with
# three things a literal `[...]` and a call couldn't hold before.

# a Pair on its own: it shows the way it is written, and carries two halves
p = "n" => 1 + 2
println(p, " ", p.first, " ", p.second, " ", typeof(p))

# a Dict written with pairs, and from a list of them
scores = Dict("ada" => 3, "bob" => 5)
println(scores, " ", scores["ada"] + scores["bob"], " ", length(scores))
println(Dict(["x" => 10, "y" => 20]))
println(Dict())

# a pair's value can be a pair (right-associative, like real Julia's)
println("a" => "b" => "c")

# ---- what a `[...]` literal can hold now ----

# a ternary inside one. The whitespace-sensitive matrix grammar can't read
# these, and a row holding one used to collapse to its first element and then
# fail at the comma.
open = true
println(["always", open ? "when open" : "when closed", "always"])

# a range inside one, same reason
println([1:3, 5:6])

# a trailing comma, as real Julia allows
println(length(["a", "b",]))

# the whitespace-separated row is untouched: still a 1xN Matrix, and a
# tight-bound sign still starts a new element
println([1.0 2.0 3.0])
println([1.0 -2.0])

# ---- `name = value` in a call is a keyword argument ----
# with or without the `;` that may separate them

@kwdef struct Panel
    id = ""
    width = 400
end
println(Panel(id = "left"))
println(Panel(Panel(id = "left"), width = 320))

speak(what; loud = false) = loud ? what * "!" : what
println(speak("hi"), " ", speak("hi", loud = true), " ", speak("hi"; loud = true))
