# A Rust src→AST port — OCaml stays canonical, this covers the full grammar

**Why this exists.** `bin/main.ml`'s own Lexer/Parser is the one and only
canonical implementation of Tsubaki's grammar. This crate is NOT a second
implementation to keep in lockstep with that forever — it's valued for two
things that don't need lockstep at all:

1. **Differential testing.** Feed the identical source snippet to both
   parsers (and evaluators) and diff the results. This is how several real
   bugs in the OCaml side (see "Bugs this crate actually caught" below) were
   found by a machine instead of by hand.
2. **The project's own running question, one language further.** The
   README's own opening hook is "how does OCaml's exhaustiveness checking
   compare to JavaScript's `switch` for this?" Rust's `match` is ALSO
   exhaustively checked at compile time (unlike JS) — a natural next data
   point for the same question, not a new one.

**History.** This crate started as a deliberately narrow "frozen snapshot"
(expression grammar plus `if`/`for`/`while`/`return` only, no structs/
modules/macros/lambdas) — the idea being that a full Tsubaki grammar mirrored
twice and kept in sync forever would be disproportionate maintenance for an
"afternoon-scale project". That framing changed: this crate now covers
`Ast.expr`/`Ast.stmt`'s full grammar, 1:1 — every one of the 29 `expr`
constructors and 15 `stmt` constructors in `bin/ast.ml` has a matching
variant in `src/ast.rs`, parsed and (to the extent described below)
evaluated. No obligation to track future OCaml-side syntax ADDITIONS,
though — if Tsubaki grows a brand new expression form tomorrow, this crate
simply doesn't parse it until someone deliberately updates it.

Verified end to end against `bin/main.ml`'s own embedded demo program (the
~540-line script `Eval.run` falls back to when given no file argument,
covering closures, try/catch, parametric structs with inner constructors
and field-type enforcement, modules/`using`, macros with real hygiene/
`gensym`/`esc`, quoting/`eval`, keyword arguments, comprehensions,
`isa`/`typeof`, and covariant `Array{T}`/`Pair{K,V}` subtyping) — this
crate's output matches the real interpreter's BYTE FOR BYTE, aside from two
lines that call into the actual Rust/faer linear-algebra kernel (`rotate`,
a Matrix×Vector product), which are genuinely out of scope (see "Known
simplifications" below).

## Scope — what's parsed and evaluated

Full expression grammar, mirroring `Parser`'s `parse_expr`/`parse_range`/
`parse_binary`/`parse_matrix_elem`/`parse_unary`/`parse_postfix`/
`parse_atom` in `bin/main.ml`, function-for-function: literals (`Int`,
`Float` incl. scientific notation, `Str` incl. `$`/`$(...)` interpolation,
`Bool`, `Nothing`), the full operator precedence table with `&&`/`||`
short-circuiting, unary minus, ternary, ranges, array/matrix literals
(including the whitespace-sensitive row-parsing dance), function calls
(positional AND keyword args), field access/assignment, indexing/index-
assignment, qualified calls (`Name.member(...)`), lambdas (`x -> expr`,
`(a,b) -> expr`, `function (args) ... end`), comprehensions, `Array{T}()`,
quoting (`:(expr)`, `:name`, `quote ... end`), `$`-interpolation/splicing,
macro calls (`@name(args)`, `@name expr`), and `end` inside indexing.

Full statement grammar, mirroring `Parser`'s `parse_stmt`/`parse_stmt_list`/
`parse_if`/`parse_struct_body`: `if`/`elseif`/`else`, `for`/`while`,
`function name(params) ... end` (typed AND keyword params, real
recursion), short-form (`name(params) = expr`) and compound-assignment
(`+=`/`-=`/`*=`/`/=`) desugaring, destructuring assignment (including index
targets, e.g. the classic `a[i], a[j] = a[j], a[i]` swap), `struct`/
`mutable struct` (with type params, a supertype, and inner constructors —
`new`/`new{T}`), `abstract type`, `try`/`catch`, `module`/`using`, `macro`
declarations, `export`, and `@name <stmt>` (a macro wrapping a whole
statement, with the fixed set of inert compiler-hint macros — `@inline`,
`@inbounds`, etc. — treated as pure identity).

A real lexical scope chain (`Scope` in `src/value.rs`, a parent-linked
`Rc` chain — not a flat stack) backs all of this: closures capture whatever
scope they were CREATED in (a lambda declared inside a loop or another
function's body genuinely closes over that call's own locals, not just
globals), assigning a name that exists somewhere up the chain mutates it in
place, and a name that exists nowhere becomes a fresh local in the scope
where the assignment is written — mirrors `bin/eval.ml`'s own
`bind`/`assign`/`lookup` exactly.

**Real multiple dispatch.** Functions (and struct constructors) resolve by
argument TYPE at call time, not just by name/arity — `env.functions` is a
name-keyed list of overloads, each scored by how closely its declared
param types match the actual argument tags (`Env::resolve_overload`,
mirroring `Dispatch.resolve`'s own applicable/specificity/ambiguity
algorithm), with the same built-in type hierarchy (`Int`/`Float`/`Complex`
`<: Number`, etc.) and the same "redefining a method with the identical
signature replaces it" rule `Dispatch.defmethod` uses. This matters in
practice, not just in principle: the canonical demo declares
`update!(e::Entity, dt)` and `update!(w::Wall, dt)` as two overloads of one
name, and a name-only dispatch table (this crate's first cut) silently let
the second overwrite the first, breaking every entity's own position
update — caught by the demo diverging, not by reasoning about it upfront.

**Parametric struct tags are inferred, not just stored.** `struct Box{T}`
infers `T`'s concrete tag from whichever field is declared exactly `::T`
(`Box(5)` tags as `"Box{Int}"`, not bare `"Box"`), and `isa`/dispatch
recognize BOTH a plain "the base type" relationship (`Box{Int} <: Box`) AND
covariant matching between two instantiations of the same family
(`Array{Player} <: Array{Entity}` because `Player <: Entity`) — mirrors
`Types.distance_to`'s own ancestor-walk-then-covariant-fallback shape.

**Struct field types ARE enforced**, at both construction and field
assignment (`TypeError: field y::Float cannot hold a String`) — except a
field typed with one of the struct's own type parameters (`::T`) or a
self-referential parametric reference (`next::Node{T}` inside `Node`'s own
declaration), whose concrete type is inferred FROM the value rather than
checked against it, same as `Runtime.construct`/`set_field`.

**`try`/`catch` catches real, typed values.** `error(msg)`/`throw(v)`
produce a genuine catchable value (`Signal::Thrown`, mirroring
`JuliaError`), and an internal interpreter failure gets reconstructed into
one of the six typed exception structs (`BoundsError`, `TypeError`,
`MethodError`, `UndefVarError`, `DomainError`, `DimensionMismatch`) or a
generic `ErrorException` from its own "Kind: message" string convention
(`Env::exn_of_failure_message`, mirroring `Runtime.exn_of_failure_message`
— every `EvalError` in this file follows that convention for exactly this
reason).

**Macros have real hygiene.** `expr_to_value`/`stmt_to_value` reify parsed
syntax as `Symbol`/`Expr` data (mirrors `bin/eval.ml`'s own quoting), each
name tagged with the CURRENT macro-expansion id; `value_to_expr`/
`value_to_stmt_list` splice a macro's result back in, renaming any symbol
tagged with THAT expansion's id to a fresh `##name#N` (memoized so every
occurrence agrees), while `esc(x)` strips a symbol's tag so it resolves at
the call site instead. `gensym()` mints a guaranteed-fresh, untagged
Symbol. `eval(quoted)` runs a `Symbol`/`Expr` as real code with no active
hygiene context (a sentinel expansion id that never matches).

**`Vector`/`Matrix`/`Array`/struct instances all have REFERENCE
semantics** (`Rc<RefCell<...>>`/`Rc<StructInstance>` in `src/value.rs`'s
`Value`, never a plain owned `Vec`/struct) — mirrors `bin/runtime.ml`'s
`VVec`/`VMat`/`VArr`/`VStruct` exactly (all already alias-on-assignment on
the OCaml side, never deep-copied). Found the hard way for `Vector`: a
first cut using a plain `Vec<f64>` made `qsort!(a, lo, hi)`
(`examples/quicksort.jl`) silently sort into the wrong array on every
recursive call, since each call's own array parameter was an independent
deep copy.

## Known simplifications (documented, not accidental)

This crate is a differential-testing tool, not a second production
implementation — see `src/value.rs`'s own module doc comment for the full
list, in short:

- No full standard library / FFI. `eval_call` covers only the narrow set of
  builtins this crate's own test snippets actually exercise (`sqrt`, `abs`,
  `length`, `push!`, `transpose`, `sum`, complex arithmetic, ...) — linear
  algebra (`matmul`, `eigen`, `svd`, sparse matrices, ...) and anything that
  calls into the real Rust/faer kernel (`rotate`, a Matrix×Vector product)
  are out of scope entirely.
- Parameter/field type annotations are enforced via a flat `isa` walk, not
  Julia's real abstract-type LATTICE — good enough for the hierarchies this
  project's own code actually declares, not a general type-system stand-in.
- An ambiguous-dispatch tie picks the first-registered candidate rather
  than raising Julia's real "ambiguous method" error in every case
  `Dispatch.resolve` would.

## Structure

- `src/lexer.rs` — mirrors OCaml's `tokenize` field-for-field: same keyword
  list, same operator table (including the 3-byte unicode `≤`/`≥`/`⋅`
  aliases), same triple-quoted string handling, same scientific-notation
  rule, same per-token `space_before`/`(line, col)` tracking, same `\u{1}`
  sentinel for an escaped `\$` (translated back by `interpolate_string`,
  see below).
- `src/ast.rs` — `Ast.expr`/`Ast.stmt`'s full grammar, 1:1 (see above).
- `src/parser.rs` — the recursive-descent parser, function-for-function
  against `bin/parser.ml`: the two-attempt whitespace-sensitive matrix-row
  dance (post-bugfix, see below), `interpolate_string` (string
  interpolation, desugared at PARSE time into an `Str`/
  `Call("string", [expr])` chain joined by `BinOp("+", ...)`, no dedicated
  AST node, same as the OCaml side), and the full statement grammar
  (`struct`/`module`/`macro`/`try`/lambdas/quoting/...).
- `src/value.rs` — the evaluator: a real `Scope` chain (closures, real
  lexical capture), multiple dispatch (`Env::resolve_overload`), struct
  construction/field access with parametric-tag inference and type
  enforcement, `try`/`catch` with typed exceptions, macro hygiene
  (`expr_to_value`/`value_to_expr`), module namespacing
  (`current_module_prefix`-equivalent + `use_module`), and `show` matching
  `Runtime.show`'s own two DIFFERENT float formats (a bare scalar `Float`'s
  `%.3f` vs. a `Vector`/`Matrix` element's `%.12g`-ish `string_of_float` —
  see `ocaml_string_of_float`'s own comment, verified against `ocaml`'s own
  REPL directly rather than guessed).
- `src/main.rs` — CLI, two modes: `tsubaki-rust-parser '<snippet>'` parses
  and evaluates ONE bare expression, printed in the same format
  `println(<snippet>)` would through the real interpreter;
  `tsubaki-rust-parser --program '<source>'` parses and RUNS a whole
  statement-level program the way `bin/main.ml`'s own `Eval.run` does
  (nothing auto-printed — only explicit `println`/`print` calls inside the
  source produce output).
- `program_snippets/*.jl` — the statement-level regression suite (one whole
  script per file, run through `--program` on both sides), separate from
  the single-line expression snippets embedded directly in
  `differential_test.sh`.

## Bugs this crate actually caught

- **Matrix-literal row parsing.** Every row of a matrix literal AFTER THE
  FIRST one parsed its own leading element with the plain (non-whitespace-
  sensitive) expression grammar, so a tight-bound sign there
  (`-16.0 -43.0`) silently collapsed into one ordinary subtraction instead
  of two elements, shortening that row by one and tripping "all rows must
  have the same length" for the wrong reason. Fixed in `bin/main.ml` by
  giving every row the same two-attempt dance the first row already had;
  this crate mirrors the FIXED version.
- **A free variable silently becoming a phantom local.** `Compile.try_compile`'s
  bytecode compiler (see `AST_IN_RUST_EXPERIMENT.md`) allocated a private
  slot for ANY identifier a zero-parameter function referenced, with no
  check for whether it was a real local — so a function reading/writing
  what looked like an outer variable silently got its own always-zero copy
  instead. Caught by this crate's tree-walking evaluator (built to
  differential-test exactly this shape) disagreeing with the real
  interpreter on a simple counter function.
- **Real multiple dispatch, not name-only.** This crate's own first cut at
  function dispatch resolved purely by name, silently letting a second
  same-named overload (`update!(w::Wall, dt)`) overwrite a first
  (`update!(e::Entity, dt)`) — caught by the canonical demo's tick loop
  never actually moving any entity, diverging from the real interpreter's
  output.

## Running the differential test

```
./differential_test.sh
```

Builds this crate, then runs two passes: a curated list of single-expression
snippets (diffing `println(<snippet>)` output against `tsubaki-rust-parser
<snippet>`), and every whole script under `program_snippets/*.jl` (diffing
its raw stdout+stderr against `tsubaki-rust-parser --program`). Requires
`../_build` to already exist (`make build` from the repo root).
