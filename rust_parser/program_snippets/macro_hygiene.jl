e = :(1 + 2)
println(e)
println(eval(e))

macro double(x)
    quote
        $(esc(x)) + $(esc(x))
    end
end
println(@double(3 + 4))

tmp = "outer"
macro my_max(a, b)
    quote
        tmp = $(esc(a))
        if $(esc(b)) > tmp
            tmp = $(esc(b))
        end
        tmp
    end
end
println(@my_max(3, 7))
println(tmp)
