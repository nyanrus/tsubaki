# NOT julia-compatible on purpose.
#
# This file pins down places where Tsubaki currently answers DIFFERENTLY from
# real Julia. The golden here records what Tsubaki does today, not what is
# right -- so that when one of these is fixed, this test fails loudly and gets
# updated, instead of the fix landing unnoticed. Each case says what real
# Julia 1.12.5 prints for the identical source.

# ---- 1. a numeric vector literal is float-backed ----
# `[1, 2, 3]` is a Vector of Float64 here, so it prints with a fractional part.
#   real Julia: [1, 2, 3]
println([1, 2, 3])

# ---- 2. `typeof` answers with Tsubaki's own tag ----
# `Float64`/`Int64` are accepted everywhere a type name is WRITTEN (see
# tests/type_aliases.jl), but the tag a value carries is still `Float`/`Int`,
# and that is what `typeof` reports. Renaming the tags means rewriting the
# ~120 method signatures that spell them out as literal strings. A Vector also
# carries no element parameter in its tag.
#   real Julia: Int64 Float64 Vector{Int64}
println(typeof(1), " ", typeof(1.0), " ", typeof([1, 2]))

# And `typeof` returns a String, where real Julia returns the type itself --
# so comparing it against a type value is false here whichever spelling is
# used. `isa` is the one that works (tests/type_aliases.jl).
#   real Julia: true true
println(typeof(1.0) == Float64, " ", typeof(1.0) == Float)

# ---- 3. a Dict shows without its key/value parameters ----
#   real Julia: Dict{Any, Any}("a" => 1)
d = Dict()
d["a"] = 1
println(d)

# ---- 4. unary minus on a float zero loses the sign ----
# `-x` is evaluated as `0 - x`, and 0.0 - 0.0 is +0.0 under IEEE-754
# round-to-nearest.
#   real Julia: -0.0
println(-0.0)

# ---- 5. assignment inside a function writes the global ----
# Tsubaki has no local-by-default rule and no `global` keyword: assigning to a
# name that already exists at the top level updates it. Real Julia treats the
# assignment as declaring a fresh local, so the read on the right-hand side
# has nothing to read.
#   real Julia: UndefVarError: `hits` not defined in local scope
hits = 0
function record()
    hits = hits + 1
    return hits
end
println(record(), " ", record(), " ", hits)

# ---- 6. a struct shows its field NAMES ----
#   real Julia: Point(1, 2)
struct Point
    x
    y
end
println(Point(1, 2))
