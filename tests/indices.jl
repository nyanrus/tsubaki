# julia: yes
# `begin` / `end` inside an index, and the two functions behind them.
# Everything here starts at 1; the point of writing `begin` is to not say so.

a = ["x", "y", "z"]
println(a[begin], " ", a[end])
println(firstindex(a), " ", lastindex(a))
println(a[begin:end])

# an index that came from a 0-origin world (a JS array, Python) applied without
# writing the +1 by hand -- and the `begin` says which world the offset is from
for i in 0:2
    print(a[begin + i], " ")
end
println()

v = [1.0, 2.0, 3.0]
println(v[begin], " ", v[end], " ", firstindex(v), " ", lastindex(v))

t = (10, 20, 30)
println(t[begin], " ", t[end], " ", firstindex(t), " ", lastindex(t))
