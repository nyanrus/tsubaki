# NOT julia: yes -- real Julia's `import Foo` goes through a package
# environment; here it reads Foo.jl (or Foo.tsubaki) beside the file that
# asked, and nothing else is on the path.
#
# The importing happens in tests/imports/main.jl, one directory down, because
# that is the point: where a module file is looked for follows the file doing
# the asking, not the process, and not the file that started the program.

include("imports/main.jl")

# A name with no module and no file beside us is still a no-op, which is how a
# real Julia program's first line gets past.
using LinearAlgebra
using SomethingNobodyWrote
println("a name with nothing behind it: still fine")
