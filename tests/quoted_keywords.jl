# julia: yes
# A Symbol is a name, as a value -- and "any name" includes the ones that
# happen to be spelled like a keyword. Which words are keywords is a fact
# about this language, not about the data: a Dict handed over from outside
# can have a key called `type`, and reading it should not need a different
# spelling from the others.
#
# `println(:type)` is deliberately not used here: Tsubaki shows a Symbol with
# its colon and real Julia shows it bare, which is a different corner.

println(string(:type), " ", string(:end), " ", string(:begin))
println(string(:in), " ", string(:where), " ", string(:function))
println(string(:if), " ", string(:else), " ", string(:for), " ", string(:while))
println(string(:const), " ", string(:module), " ", string(:struct))
println(string(:nothing), " ", string(:return), " ", string(:let))

# ordinary Symbols, not a shape of their own -- one of them is `string`'d
# above, and here they compare like any other name. (`Symbol("type")` would
# say the same thing more directly, but the Rust VM has no `Symbol` builtin
# yet, and then it couldn't check any of this.)
println(:type == :type, " ", :type == :end)

# `true` and `false` are values, not names -- quoting one hands the value
# back, not a Symbol (real Julia does the same)
println(:true, " ", typeof(:true), " ", :false, " ", typeof(:false))

# where this came from: keys read by name, one of them called `type`
d = Dict(:type => "web", :id => 3)
println(d[:type], " ", get(d, :type, "-"), " ", get(d, :where, "-"))
