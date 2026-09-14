# struct を、一つだけ変えて建て直す。`T(もとのもの, 名前 = 値)` --
# もとのものは変わらない(データ指向で書くと、update はぜんぶこの形になる)。
#
# 実の Julia にはこの綴りが無い(`Setfield.@set` などを使う)ので、
# ここは julia と突き合わせず、二つの runtime の答えをそれぞれ記録する。

struct AppState
    panels
    selected
    width
end

s = AppState(["a", "b"], "a", 40)
println(AppState(s, selected = "b"))
println(AppState(s, selected = "c", width = 32))

# もとのものは、そのまま
println(s)

# @kwdef なら、もとのものが無くても建てられる
@kwdef struct Opts
    loud = false
    times = 1
    label = "-"
end

o = Opts()
println(o)
println(Opts(times = 3))
println(Opts(o, loud = true))

# 無い名前は、そう言う
try
    AppState(s, nope = 1)
catch e
    println("caught")
end
