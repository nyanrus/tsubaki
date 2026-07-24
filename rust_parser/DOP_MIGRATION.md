# A targeted DOP migration -- what changed and why this scope, not the whole evaluator

Written after investigating why this crate's tree-walker was still slower than
`bin/eval.ml`'s fully-optimized interpreter despite being compiled (see
`AST_IN_RUST_EXPERIMENT.md`-style measurement discipline: real numbers, not
guesses). Two verified, structural causes came out of that investigation:

1. **Scope allocation volume.** `pisum` alone triggers **10,001,002**
   `Rc<ScopeNode>` heap allocations (measured via a counter in
   `new_child_scope`) -- one per `for`/`while` iteration, since every
   iteration builds a brand new scope through Rust's general-purpose
   allocator. OCaml's equivalent (a plain assoc list, `[]` until something is
   bound) comes from its GC's minor-heap **bump allocator** -- pointer
   increment, no free-list search, no locking. Both are "one allocation," but
   they cost very differently; this is the single biggest measured gap.
2. **A fat `Value` enum.** `size_of::<Value>()` measured **48 bytes**;
   `size_of::<SResult<Value>>()` (what `eval()` returns on every recursive
   call) measured **56 bytes**. OCaml's boxed `value` is a uniform 8 bytes
   (an immediate int or one pointer) on every copy, always. The cause here:
   two quoting-only variants, `Symbol(String, Option<u64>)` (40 bytes) and
   `ExprV(String, Vec<Value>)` (48 bytes), are large enough that Rust sizes
   the *whole enum* to fit them -- so even a hot-path `Int`/`Float` pays for
   48 bytes on every clone/move/return, not just quoted syntax data.

Both are exactly what Data-Oriented Programming targets in general terms: a
graph of individually-heap-allocated nodes linked by pointers, and a
heterogeneous tagged union sized to its biggest case. The question this
document answers is **how far to take that idea here** -- because the honest
range runs from "two bounded, low-risk fixes" to "rewrite the evaluator as
flat parallel arrays, essentially a register machine," and those differ in
cost by an order of magnitude.

## What this migration does NOT do, and why

A "real" DOP conversion would restructure `Value` into a struct-of-arrays (a
tag array + per-shape payload arrays, index-addressed) and rebuild `Env`'s
scopes as a flat stack/arena instead of a parent-linked `Rc` chain. Two things
rule that out as the right scope for this crate specifically:

- **Closures need scopes to escape.** `Scope` is `Rc<ScopeNode>` *because* a
  `Lambda`/`FuncDecl`/inner-constructor captures the scope it was declared in
  (`ClosureDef.captured`, `FuncDef.def_env`, `CtorDef.def_env` -- see
  `value.rs`) and that capture must outlive the frame that created it. A flat
  arena/stack of frames is wrong the moment a closure can outlive its
  creating scope; fixing that properly means adding real escape analysis (a
  static pass proving which frames never escape), which is a genuine
  language-runtime feature, not a data-layout change.
- **This crate's own README already says what it is.** "A differential-
  testing tool, not a second production implementation... treat it as a demo
  of what's reachable in an afternoon-scale project, not as a foundation to
  build on without expecting to rewrite large parts of it." A full SoA
  rewrite is exactly that "rewrite large parts of it" -- reasonable for a
  production language runtime, disproportionate here.

So this migration takes the **bounded** path: keep the existing
`Rc<ScopeNode>` / tagged-`Value` architecture, and remove the two *specific*,
*measured* costs above wherever it's provably safe to do so, falling back to
the original (always-correct) behavior wherever it isn't provable.

## Fix 1: scope pooling for capture-free loop bodies

**The idea.** A `for`/`while` loop's iterations run strictly sequentially, in
one Rust call frame (`exec_stmt`'s own invocation for that `Stmt::For`/
`Stmt::While` node). If nothing inside the loop body can make an iteration's
scope outlive that iteration -- no closure, no nested function/struct
constructor capturing it -- then reusing ONE `ScopeNode` across all
iterations (clearing its bindings between iterations) is observationally
identical to allocating a fresh one every time, and turns N allocations into
1.

**The hazard.** If the body *can* let a closure capture the iteration's
scope (e.g. a lambda pushed into an array, read back after the loop), reusing
one scope object would be a real correctness bug: every captured closure
would alias the same mutable bindings and see only the last iteration's
values -- the classic "loop variable capture" bug family (the reason
JavaScript grew `let` alongside `var`). Pooling must never apply there.

**The check.** `body_may_capture_scope` (`value.rs`) walks a loop body's
statements and expressions looking for anything that stores a `Scope`
reference beyond this iteration:

- `Expr::Lambda`, `Stmt::FuncDecl`, `Stmt::StructDecl` with a non-empty
  `constructors` list -- these directly construct a `ClosureDef`/`FuncDef`/
  `CtorDef` that captures the CURRENT scope by field (`captured`/`def_env`).
  Found anywhere reachable → **unsafe, don't pool**.
- `Stmt::ModuleDecl` -- not fully audited for whether its body opens a fresh
  scope layer; treated as unsafe unconditionally rather than reasoning it out
  for a pattern ("declare a module inside a hot loop") that doesn't occur in
  practice.
- `Expr::MacroCall`/`Stmt::MacroCall` -- a macro's *expansion* is arbitrary
  code produced at runtime by running the macro's own body; there's no way
  to know statically whether it splices in a closure. Treated as unsafe.
- `Stmt::MacroDecl` -- safe to skip entirely. `MacroDef` (`value.rs`) has no
  captured-`Scope` field at all: a macro's body doesn't close over its
  declaration site, and every macro call builds a fresh scope rooted at
  `env.global` (never the call site's scope), matching this crate's own
  hygiene design.
- `Expr::Quote`, `Expr::QuoteBlock` -- deliberately **not** recursed into.
  Quoted syntax is data until something evaluates it, and when it IS
  evaluated (`eval(...)` on a `Symbol`/`Expr` value), it runs in whatever
  scope is CURRENT at that later point -- not a scope captured at quote-time.
  This mirrors a lesson this project already learned the hard way: the
  static `Resolve` pass write-up (`ast.rs`'s own note on why it wasn't built)
  describes exactly this -- quoted control-flow doesn't open a real static
  scope, and treating it as if it did was a real, caught bug on the OCaml
  side. Same reasoning applies here in the opposite direction: quoted
  content isn't a capture risk precisely because it isn't live code yet.
- Everything else (`If`/`For`/`While`/`Try`/`Destructure`/ordinary
  expressions, including nested loops and comprehensions) is walked
  recursively, since a closure nested arbitrarily deep still closes over
  every ancestor scope via the parent chain -- a lambda three loops deep
  still captures the outermost loop's scope too.

Computed **once per loop-statement execution**, not once per iteration --
for `pisum`'s nested loops that's 501 checks total (1 outer + 500 inner, one
per outer iteration), each a cheap walk over a handful of AST nodes, nowhere
near the cost of the millions of allocations it replaces.

**The mechanism.** `ScopeNode::clear_vars` empties a scope's bindings in
place; `Env::with_existing_scope` swaps a *given* `Scope` in as current (vs.
`with_child_scope`, which always allocates a fresh one). The pooled path
allocates one `Scope` before the loop starts, then each iteration clears it
and reuses it. The unsafe path is untouched -- byte-for-byte the same
`new_child_scope` per iteration as before.

**What this does NOT extend to.** Function calls (`call_user_function`)
still allocate a fresh scope every call, deliberately. Recursive calls are
not sequential the way loop iterations are -- `fib(n-1)` and `fib(n-2)` both
need independently-alive frames on the Rust call stack at the same time, so
"reuse one scope object across calls" would corrupt recursion. A per-
recursion-depth pool (a free-list keyed by call depth) could in principle
achieve something similar, but that's a materially bigger, riskier piece of
work than this migration's bounded scope -- left as a possible future step,
not attempted here.

## Fix 2: shrink `Value` by boxing its two oversized variants

`Symbol(String, Option<u64>)` and `ExprV(String, Vec<Value>)` exist for
exactly one purpose -- representing quoted syntax (`:x`, `:(a + b)`,
`quote...end`) for macros. They're never produced by ordinary numeric or
control-flow code (`fib`/`pisum`/`quicksort`/`mandel` never touch them), yet
their size (40 and 48 bytes) sets the size of the *entire* `Value` type,
because Rust sizes a tagged union to its largest variant.

Boxing both payloads (`Symbol(Box<(String, Option<u64>)>)`,
`ExprV(Box<(String, Vec<Value>)>)`) shrinks each to a single pointer (8
bytes), so `Value`'s size is governed by the next-largest variant instead
(`Array(Rc<RefCell<Vec<Value>>>, Option<String>)` at 32 bytes) -- shrinking
every `Value` copy, including the hot-path `Int`/`Float` ones that dominate
the four benchmarks, by roughly a third. The cost is purely mechanical: every
one of the ~71 construction/pattern-match sites for these two variants
(`value.rs`, almost entirely inside the quoting/macro-expansion machinery)
needs an extra `Box::new((...))`/`&*boxed` -- no new reasoning required, and
no behavior changes (quoting/macro semantics are identical; only the memory
layout of the two variants that represent them changed).

## Net effect

Both fixes stay inside the existing `Rc<ScopeNode>` / tagged-`Value`
architecture; nothing about closures, dispatch, or quoting semantics changes.
Verified against `./differential_test.sh` (63/63) after each fix, plus two
targeted manual checks that a closure escaping a capture-unsafe loop still
sees its own iteration's value (`for i in 1:3; push!(fns, () -> i); end`
prints `1 2 3`, not `3 3 3`).

| | `sizeof(Value)` | `sizeof(SResult<Value>)` |
|---|---|---|
| before | 48 bytes | 56 bytes |
| after | 32 bytes | 40 bytes |

| Benchmark | before this migration | after scope pooling | after `Value` boxing |
|---|---|---|---|
| `fib(20)` | 0.010 s | 0.010 s | 0.009 s |
| `qsort!` 5,000 floats | 0.032 s | 0.032 s | 0.030 s |
| `pisum` (5M divisions) | 1.30 s | 1.03 s | 0.98 s |
| `mandelperf` | 0.019 s | 0.018 s | 0.017 s |

`pisum` -- the benchmark with the most loop-scope churn -- is where scope
pooling shows up clearly (~21% faster). `Value` boxing's win is smaller but
spread across all four, since it shrinks every value regardless of which
benchmark is running. `fib`/`mandelperf` barely move either way: `fib` is
recursion-bound (scope pooling doesn't apply to function calls, see above),
and `mandelperf`'s hot loop is inside a comprehension, a different code path
from `Stmt::For`/`Stmt::While`.
