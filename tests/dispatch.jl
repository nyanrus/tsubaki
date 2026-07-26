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
