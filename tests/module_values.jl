# julia: yes
# `module M ... end` の中で置かれた**値**も member になる。関数と型はもう
# 名前空間を持っていた(`M.area` / `M.Circle`)けれど、値の束縛だけが行き場を
# 持っていなかった。Julia では `const x = 1` も `M.x` で読める。

module Colors
    const bg = "canvas"
    const text = "ink"
    plain = "no const, same thing"
    name() = "colors"
end

println(Colors.bg, " / ", Colors.text, " / ", Colors.plain)
println(Colors.name())

# module そのものも値
println(typeof(Colors))

# 入れ子も、そのまま次の `.` が読める
module Outer
    const a = 1
    module Inner
        const b = 2
    end
end
println(Outer.a, " ", Outer.Inner.b)

# 中で置いた名前は、外には出ない
try
    println(plain)
    println("leaked")
catch e
    println("not visible outside")
end

# 無い member は、そう言う
try
    println(Colors.nope)
    println("found")
catch e
    println("no such member")
end
