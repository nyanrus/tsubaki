# julia: yes
# Counting a String, the Julia way: `length` counts characters; `ncodeunits`
# and `sizeof` count bytes (what `s[a:b]` is indexed by); `lastindex` is where
# the last character starts.

s = "hello"
println(length(s), " ", ncodeunits(s), " ", sizeof(s), " ", lastindex(s))

# é takes two bytes, ñ too
t = "héllo"
println(length(t), " ", ncodeunits(t), " ", sizeof(t), " ", lastindex(t))

u = "añ"
println(length(u), " ", ncodeunits(u), " ", lastindex(u))
println(u[lastindex(u):end])

e = ""
println(length(e), " ", ncodeunits(e), " ", lastindex(e))

# the three agree with what slicing does
println(t[1:lastindex(t)] == t)
println(length(t[1:2]), " ", ncodeunits(t[1:2]))
