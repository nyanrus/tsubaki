# julia: yes
# Multiple dispatch: an abstract hierarchy, most-specific-wins, and dispatch
# on a PAIR of arguments (where "most specific" stops being obvious).

abstract type Animal end
abstract type Pet <: Animal end

struct Cat <: Pet
    name
end

struct Dog <: Pet
    name
end

struct Wolf <: Animal
    name
end

speak(a::Animal) = "..."
speak(p::Pet) = "(looks up)"
speak(c::Cat) = "nyan"

println(speak(Cat("kuro")))
println(speak(Dog("pochi")))
println(speak(Wolf("gray")))

# two arguments: the most specific PAIR wins, not the most specific first one
meets(a::Animal, b::Animal) = "two animals"
meets(c::Cat, d::Dog) = "cat meets dog"
meets(p::Pet, a::Animal) = "a pet meets an animal"

println(meets(Cat("kuro"), Dog("pochi")))
println(meets(Cat("kuro"), Wolf("gray")))
println(meets(Wolf("gray"), Cat("kuro")))

# a named function is a value -- `speak` here is the whole generic function,
# dispatched afresh on each element it is handed
function each(f, xs)
    for x in xs
        println(f(x))
    end
end
each(speak, [Cat("a"), Dog("b"), Wolf("c")])

# a method added later joins the same generic function
speak(w::Wolf) = "awoo"
println(speak(Wolf("gray")))

# 「どちらが狭いとも言えない」ときは、決めない。`f(1, 1.0)` は下の二つに
# どちらも当たるけれど、片方が片方の中に収まってはいない -- そこで黙って
# 一つ選ぶと、いちばん見つけにくい食い違いになる。
# (何と言って断るかは runtime ごとに少し違うので、ここでは断ったことだけ)
side(x::Int, y) = "left"
side(x, y::Float64) = "right"
println(side(1, 1), " ", side("s", 1.0))
try
    side(1, 1.0)
    println("chose one")
catch e
    println("ambiguous")
end

# 同じ署名で書き直したら、置きかわる(積み上がらない)
over(x) = "first"
over(x) = "second"
println(over(1))
