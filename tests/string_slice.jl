# julia: yes
# s[a:b] on a String: a fresh String, with byte positions as in Julia.

s = "hello world"
println(s[1:5])
println(s[7:end])
println(s[end:end])
println(s[3:2] == "")
println(length(s[2:4]))

# é takes two bytes (2 and 3): both ends must start a character, and the
# slice runs through the end of the last one -- so t[1:2] is "hé", and 3 is not
# an index at all
t = "héllo"
println(t[1:2])
println(t[2:2])
println(t[4:end])

# end is where the last character starts, so a slice can reach it
u = "añ"
println(u[1:end])

# a slice is a String like any other
d = "2026-10-14"
println(d[1:4] * "/" * d[6:7] * "/" * d[9:10])
n = 3
println(s[n:n+2])
