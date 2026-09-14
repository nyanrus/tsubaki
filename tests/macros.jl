# julia: yes
# Macros: quote/unquote, real hygiene, and esc() reaching the caller's scope.
# Expr VALUES are not printed here (Tsubaki shows them in its own internal
# shape, unlike real Julia's `:(1 + 2)`) -- only what they evaluate to.

println("eval of a quoted expression: ", eval(:(1 + 2)))

macro double(x)
    :($x + $x)
end
# expands to (3+4) + (3+4), not 3 + 4 + 3 + 4
println("@double(3 + 4) = ", @double(3 + 4))
println("@double(2) = ", @double(2))

# hygiene: the macro's own `tmp` cannot clobber the call site's
macro my_max(a, b)
    quote
        tmp = $a
        if $b > tmp
            tmp = $b
        end
        tmp
    end
end

tmp = "this must survive untouched"
println("@my_max(3, 7) = ", @my_max(3, 7))
println("@my_max(9, 2) = ", @my_max(9, 2))
println("outer tmp is still: ", tmp)

# esc(): a macro that deliberately reaches OUT and mutates the caller's own
# variables
macro swap!(a, b)
    quote
        held = $(esc(a))
        $(esc(a)) = $(esc(b))
        $(esc(b)) = held
    end
end

x = 1
y = 2
@swap!(x, y)
println("after @swap!(x, y): x = ", x, ", y = ", y)

# a macro that generates control flow
macro repeat(n, body)
    quote
        for i in 1:$n
            $body
        end
    end
end
@repeat(3, println("  repeated"))

# a macro wrapping a whole STATEMENT (a declaration, a loop) rather than a
# trailing expression -- the shape real package source uses constantly. The
# compiler-hint macros are pure identity here, changing nothing but parsing.
@inline function greet(who)
    return "hello, $who"
end
println(greet("shiro"))

@inbounds for i in 1:2
    println("  hinted loop ", i)
end
