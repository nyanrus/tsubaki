# Tsubaki, the language

The basics of the language, for someone about to write it (a drop's logic, a
script, a test). This does **not** cover what the interpreter is built out of,
the GPU work, or the benchmarks — those are in the [README](../README.md),
[`ROADMAP.md`](../ROADMAP.md), [`GAME_DX_VISION.md`](../GAME_DX_VISION.md) and
[`AST_IN_RUST_EXPERIMENT.md`](../AST_IN_RUST_EXPERIMENT.md). It covers what you
actually type.

If you came here to write a **noraneko drop**, [`for-drops.md`](for-drops.md)
is the same language at exactly that depth. This page is the general one.

Tsubaki is a toy Julia-like language: the syntax and the semantics aim at
*real Julia*, so the fastest way to read a Tsubaki program is to read it as
Julia. Where it deliberately differs, this page says so, and the difference is
pinned by a test ([`tests/known_gaps.jl`](../tests/known_gaps.jl)).

## Running

```sh
make repl                      # an interactive prompt
make run                       # the embedded demo
make run FILE=examples/fib.jl  # run a file
make test                      # every tests/*.jl against its recorded output
```

Or, without `make`:

```sh
node -r ./preload.js _build/default/bin/main.bc.wasm.js examples/fib.jl
```

## A program

```julia
# comments start with #
function square(n)      # a function, declared or one-liner
    return n * n
end

square2(n) = n * n      # the one-liner shape

struct Point            # a type
    x
    y
end

abstract type Shape end       # an abstract type
struct Circle <: Shape        # with a supertype
    r
end

println(square(7), " ", square2(7))
println(Point(1, 2).x)
```

- **Top level is a module.** A `module Name ... end` makes a namespace; `using`
  / `import` bring names in. `import Shapes` with no `module Shapes` declared
  reads `Shapes.jl` (then `Shapes.tsubaki`) beside the file that asked — the
  same rule `include` keeps, and the only way one file reaches another.
- **File = top level.** `include("other.jl")` splices a file in and runs it
  right there.

## Values and types

| | |
|---|---|
| numbers | `Int` / `Float64` (the defaults), `Int8`…`UInt64`, `Rational` (`1//3`), `Complex` |
| strings | `"hi $name"`, `"$(a + b)"`, escapes `\"` `\\` `\n` `\t` `\$` |
| booleans | `true` / `false`, and `&&` / `\|\|` with real short-circuit |
| `Symbol` | `:name` — a name as a value. `:type`, `:end` (keywords) work too |
| `Pair` | `"a" => 1` — `.first`, `.second` |
| `Nothing` | `nothing` |
| tuples | `(1, 2)`, `(1,)`, and destructuring `a, b = pair` |
| vectors | `[1, 2, 3]`, comprehensions, `push!`, 1-indexed |
| matrices | `[1.0 2.0; 3.0 4.0]` (real Julia's syntax) |
| `Dict` | `Dict("a" => 1)`, `Dict(pairs)`, `Dict()` |
| `Array` / `Matrix{T}` | boxed containers that can hold anything |

`struct` / `mutable struct` register real runtime types; `abstract type X <: Y`
builds the hierarchy. Parametric structs work: `struct Box{T}` and `Box{Int}`
is registered on the fly (`Box{Int} <: Box`). Field type annotations are
enforced at construction. `@kwdef` gives keyword-with-default construction.
`new` / `new{T}` in an inner constructor builds the raw struct (and may take
fewer args than fields — which is how self-referential structs are built at
all).

```julia
@kwdef struct Cfg
    width = 320
    dark = false
end
Cfg()            # Cfg(320, false)
Cfg(dark = true)
```

## Functions, dispatch, closures

- **Multiple dispatch**, close to Julia's real algorithm: most-specific wins,
  an ambiguity error when two candidates tie.
- **Keyword arguments**: `f(a; k = default)`.
- **Varargs**: `f(xs...)`.
- **Closures**: `x -> x * x`, `(a, b) -> a + b`. A named `function` inside
  another function is a true local of that call: it closes over that call's
  variables (read and *mutate*), can recurse by its own name, and each call of
  the enclosing function makes a genuinely new one.
- **A function is a value** and can be dispatched on: `f = square`, `map(f, xs)`.
- **A call is a value too**: `make_adder(5)(10)`, `fs[1](x)`, `(x -> x*x)(7)`,
  `d["double"](8)`.
- **`a[i]` is a call** to `getindex(a, i)`; `a[i] = v` to `setindex!`. So you
  can dispatch on indexing.

```julia
abstract type Animal end
struct Cat <: Animal end
struct Dog <: Animal end

speak(::Animal) = "..."
speak(::Cat) = "nyan"

speak(Cat())        # "nyan"
speak(Dog())        # "..."
```

## Control flow

```julia
if n < 0
    "negative"
elseif n == 0
    "zero"
else
    "positive"
end

for x in 1:2:9       # ranges, stepped ranges, vectors
    total += x
end

while i <= n
    i += 1
end

try
    risky()
catch e
    println(e)
end

x = cond ? a : b           # ternary
```

`&&` / `||` short-circuit. Compound assignment works on fields and indices
too, but on an index target the store-back is refused (aliasing); do
`a[i] = a[i] + 1` there. `break` / `continue` work in loops.

## Operators

`+ - * / // ^ % ÷` and comparison `== != < <= > >=`; bitwise `& | ⊻ >> << >>>`;
`!`; ranges `a:b`, `a:step:b`; the numeric-literal coefficient `2x` /
`2(x+1)` (which is `2*(x+1)`).

**Where Tsubaki differs on purpose** (each pinned by a test): `3x^2` is
`3*(x^2)` (Julia's binding), `round` rounds to even like Julia, and integer
overflow wraps the way a fixed-width Int does — `Rational` is Int-backed, so
it overflows too (`1 // 0` raises).

## Modules

```julia
module Shapes
    struct Circle
        r
    end
    area(c::Circle) = 3.14 * c.r * c.r
end

using .Shapes
Shapes.area(Shapes.Circle(2))   # qualified call, any chain length
```

`import Name: a, b` binds only the named members bare. A module read from a
file runs as its own top level. Namespacing covers `function`, `struct`,
`abstract type`, `macro`. What is *not* there: export lists, `as`, and a
first-class module value (a plain variable isn't namespaced). Macros are
namespaced by module and are **not** merged by `using` (unlike functions/types).

## Macros

```julia
macro twice(ex)
    quote
        $(esc(ex))
        $(esc(ex))
    end
end

@twice println("hi")     # prints twice
```

`:( expr )` / `quote ... end` quote as `Expr`/`Symbol`; `$(x)` / `$name`
splice; `macro name(args...) ... end` + `@name(args)`. **Hygiene** renames a
macro's own template variables so they can't collide with the call site
(`esc(x)` reaches the caller's scope). A statement-position macro works
(`@inline function f() ... end`), and a fixed set of compiler-hint macros
(`@inline`, `@inbounds`, …) are pure identity.

## Strings and printing

`println`, `print`, `string(x)`, `"… $var …"` interpolation. A float prints
the shortest decimal that reads back as the same float, and switches to
scientific notation on Julia's own thresholds.

## What it deliberately does not do

- **No package system.** `include("x.jl")` splices a file; `import Foo` reads
  `Foo.jl` beside you. No registry, no `Project.toml`, no search path.
- **No `BigFloat`** (spiked and abandoned for a reason — see README).
- **`module` / `using` / `import` are a real but narrow subset** (no export
  lists, no `as`, a same-named type in two modules is treated as related).
- **Macros / quoting cover a scoped subset** (a call on a computed callee
  isn't quotable, etc.).
- **No JIT in the real sense.** There are eleven targeted optimizations and
  one static pass, plus a *separate* restricted bytecode compiler for
  hot numeric functions (`AST_IN_RUST_EXPERIMENT.md`).
- **Threads / real parallelism**: a worker pool exists as a host bridge, not
  as language threads.

The README's "What it deliberately does not do" is the complete, always-current
list — read it there.

## Where an error happened

A runtime error names its file, its line, and the chain of calls that reached
it. One exception: a zero-parameter function that took the bytecode/Host path
contributes no frame (it doesn't run through the tree-walker), though the
functions it calls still do.

```
ERROR: MethodError: no method matching square(String, Int)
  at prog.jl:12  in square
  ...
```

## Reading more

- [`for-drops.md`](for-drops.md) — the same language, tuned for writing a noraneko drop's logic
- [`../README.md`](../README.md) — the interpreter, WasmGC, the numeric kernel, the GPU work
- [`../ROADMAP.md`](../ROADMAP.md) — the `LinearAlgebra` plan
- [`../tests/`](../tests) — the regression suite; `known_gaps.jl` pins every deliberate difference from Julia
- [`../examples/`](../examples) — real programs, including JuliaLang's own microbenchmarks
