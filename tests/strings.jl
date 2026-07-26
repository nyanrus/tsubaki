# julia: yes
# Strings: escapes, interpolation of both a bare name and a whole expression,
# and triple-quoted text.

name = "shiro"
a = 3
b = 4

println("hi $name")
println("$a + $b = $(a + b)")
println("nested: $(a + b * 2)")
println("adjacent: $a$b")

# escapes
println("quote: \"q\"")
println("backslash: \\")
println("tab:\tafter")
println("dollar: \$name is not interpolated")

# a string is a value like any other
function loud(s)
    return "$(s)!!"
end
println(loud("ok"))

parts = ["a", "b", "c"]
println(parts)
println(length(parts), " ", length("hello"))

# comparison and equality
println("abc" == "abc", " ", "abc" == "abd", " ", "a" < "b")

# triple-quoted, the shape real package source uses for docstrings
"""
    doc_target(x)

A real docstring, closed by three quotes rather than one.
"""
doc_target(x) = x * 2
println(doc_target(21))

# interpolation of non-strings
println("a struct field: $(loud("y"))")
println("a bool: $(3 > 2), a float: $(1 / 4)")
