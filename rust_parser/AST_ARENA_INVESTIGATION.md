# Would arena-allocating the Rust AST actually help? Measured, not guessed

Written after nyanrus asked to switch `rust_parser/src/ast.rs`'s `Expr`/`Stmt`
(currently `Box<Expr>`-recursive, `Vec<Stmt>` bodies) to an arena, having
heard it affects performance a lot. Following the same discipline
`DOP_MIGRATION.md` used for its own two fixes -- real numbers, not guesses --
before touching any code, this investigation measured the two ways an arena
could plausibly help here, and neither shows a real win for this crate's own
benchmarks. **Recommendation: don't do it**, at least not the way it was
proposed. Details below.

## What "arena" would have to mean here, and why that's a bigger deal than it sounds

A "real" arena AST (`&'a Expr<'a>`, e.g. via `bumpalo`) isn't a drop-in change
for this crate specifically: `FuncDef`, `ClosureDef`, `CtorDef`, and
`MacroDef` (`value.rs`) all currently store an OWNED `Vec<Stmt>` body,
cloned in from the parsed tree at declaration time. A borrowed arena would
need a lifetime parameter threaded through all four of those, `Value`, and
`Env` itself -- essentially all of `value.rs` (2935 lines). That's exactly
the scope `DOP_MIGRATION.md` explicitly ruled out for the equivalent
`Value`/`Env` struct-of-arrays rewrite, for the same reason: this crate's own
README says it's "a demo of what's reachable in an afternoon-scale project,
not a foundation to build on without expecting to rewrite large parts of
it." So before signing up for that, this investigation checked whether the
two things an arena could actually buy -- less cloning, better cache
locality -- are real costs here at all.

## Check 1: how much does this crate actually clone AST nodes at runtime?

`Expr::Lambda`, `Stmt::FuncDecl`, a struct's inner constructors, and
`Stmt::MacroDecl` (`value.rs:1170,2607,2631,2712` before this investigation)
each deep-clone a `Vec<Stmt>` body into a runtime definition. An arena with
`Rc`-shared storage (or index handles) would turn that into an O(1) handle
copy instead of an O(subtree size) clone. Real question: how big is that
subtree, times how many times does this actually happen, across this
project's own workloads?

Instrumented all four sites with a counter (temporary, removed after
measuring -- same pattern `DOP_MIGRATION.md` used for `new_child_scope`,
which also never landed in shipped `value.rs`), counting total `Expr`/`Stmt`
nodes cloned, not just call count:

| Program | nodes cloned (whole run) |
|---|---|
| `fib.jl` | 15 |
| `mandel.jl` | 55 |
| `pisum.jl` | 25 |
| `quicksort.jl` | 121 |
| all 30 `program_snippets/*.jl` combined (incl. lambdas, macros, structs with ctors -- everything the 4 numeric benchmarks don't exercise) | 247 |

For comparison, `DOP_MIGRATION.md` measured **10,001,002** `Rc<ScopeNode>`
allocations for `pisum` alone before its own fix. AST-clone volume here is
5+ orders of magnitude smaller, across every corpus file this project has,
not just the 4 numeric ones. None of the 4 benchmarks use closures at all
(`grep -n '\->' examples/*.jl` -- zero matches), so `Expr::Lambda` never even
fires for them; `FuncDecl`/struct-ctor/`MacroDecl` only run once each, at
declaration time, regardless of how many times the declared function is
later called. **This cost is real but negligible for everything this project
actually runs.**

## Check 2: does packing a small, hot-loop-sized tree contiguously actually speed up the walk?

The other thing an arena could win on even with zero clone-volume benefit:
`pisum`'s inner loop body (`s += 1.0 / (k * k)`) gets walked 10,000 x 500 =
5,000,000 times. If those handful of `Expr` nodes are scattered across the
heap as individual `Box` allocations, each recursive `eval` call could be a
cache miss; a contiguous arena groups them together.

Tested this directly and cheaply, without touching the real crate: a
standalone throwaway benchmark (`arena_locality_bench`, not part of this
repo) builds the SAME ~21-node tree shape (an 8-leaf balanced `BinOp` tree
plus an `Assign`/`If` wrapper, matching a typical loop-body's size) two ways
-- as scattered `Box<Node>` allocations with unrelated junk `Vec<u8>`
allocations interleaved between every node (simulating a real heap, not a
freshly-booted allocator's best case), and as one contiguous `Vec<Node>`
addressed by `u32` index -- then walks each 5,000,000 times, varying the
input every iteration so nothing constant-folds away.

10 runs, release build:

| | boxed (scattered) | arena (contiguous, index-addressed) |
|---|---|---|
| typical | ~16.6 ns/iter | ~18.4 ns/iter |
| range across 10 runs | 16.1-17.9 | 18.2-21.1 |

**The scattered `Box` version was consistently ~8-12% FASTER**, not slower,
in 9 of 10 runs. The likely reason: a ~21-node tree (a few hundred bytes) is
tiny enough to sit entirely inside L1 cache regardless of allocation
strategy, so there's no cache-miss cost for an arena to eliminate in the
first place -- while the arena's `pool[id as usize]` indexed access pays for
a bounds check and index arithmetic on every recursive call that a direct
`Box` pointer deref doesn't. Any locality win an arena provides shows up on
trees too big for cache (or under heavy allocation churn evicting things
between visits) -- neither describes a single loop body in `fib`/`mandel`/
`pisum`/`quicksort`.

## Conclusion

Both of the concrete ways an arena AST could help this crate turn out not to
apply to what this project actually runs: clone volume is 5+ orders of
magnitude below the threshold that mattered for scopes, and the hot-loop
trees involved are small enough that contiguous packing doesn't pay for
itself over plain `Box` -- if anything it costs a bit more. Given that,
and given the scope of what a real borrowed-arena rewrite would touch
(effectively all of `value.rs`, which this crate's own README already warns
against), **this investigation recommends not doing the arena rewrite**.

If this ever changes -- e.g. a benchmark with a lambda re-declared inside a
hot loop (unlike anything in `examples/` today), or a loop body large enough
to matter for cache -- these two checks are cheap to re-run and would show
it.
