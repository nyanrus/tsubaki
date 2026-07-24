# Profiling fib/mandel/quicksort: a real cost `pisum` could never show

`pisum` has been profiled twice before (README.md:120-234, `node --prof` /
`--prof-process`), and every one of the project's optimizations trace back
to those two rounds. `fib`, `mandel`, `quicksort` had never been profiled at
all. Same method, same tool, this time on all four -- and one genuinely new,
well-localized cost turned up that `pisum` structurally could never have
shown.

## Method

`make build`, then for each benchmark: `node --prof -r ./preload.js
_build/default/bin/main.bc.wasm.js <file>` followed by `node --prof-process
isolate-*.log`. `fib`/`mandel`/`quicksort` as shipped finish in 5-26ms --
far too little wall-clock for V8's ~1kHz sampler to collect a trustworthy
tick count (single-digit samples). Profiled amplified copies instead (same
source, wrapped in `for i in 1:N ... end` around the existing timed call --
400x for `fib`, 150x for `mandel`, 80x for `quicksort`; not committed to the
repo), landing each run at ~2s and ~1,700 ticks, comparable to `pisum`'s own
historical profiling runs.

## `pisum` re-profiled first -- and it's no longer a useful profiling target

```
[Summary]: 229 ticks total
   150 (53.4%)  run_bytecode
    79 (28.1%)  *run_bytecode
     0 ( 0.0%)  GC
```

`pisum()` is zero-parameter, so `bin/compile.ml`'s bytecode "pseudo-JIT"
(added after the original profiling rounds) now compiles it on first call
and runs the whole 5,000,000-iteration loop as a single FFI call into the
Rust kernel's `run_bytecode`. The historical tree-walker profile
(`eval_expr`/`call_cached`/`str_assoc_opt`/...) simply doesn't exist for
`pisum` anymore -- **`pisum` is the one shipped benchmark that bypasses the
tree-walking interpreter almost entirely**, which is exactly why it can no
longer surface anything about AST-handling performance. `fib`, `mandel`,
`quicksort` all take positional parameters, so none of them qualify for
`compile.ml` today (see "Recommendation" below) -- they're the only three
benchmarks left that actually exercise the tree-walker's own hot path.

## `fib`, `mandel`, `quicksort` -- same shape shows up in all three

```
                          fib      mandel   quicksort
eval_expr                39.8%    39.2%    45.4%
call_cached               11.4%    8.5%     7.8%
caml_string_equal_1205   11.3%   13.0%     9.1%
caml_hash                 1.7%    2.1%     0.1%
caml_string_concat_1205   2.3%    2.0%     0.1%
GC                        3.0%    2.1%     3.2%
```

GC stays flat at 2-3% across all three, same as every historical `pisum`
round -- confirms the README's own finding (allocation was never the
dominant cost here) generalizes past `pisum`, not just a `pisum`-specific
fluke.

The new thing: `caml_string_equal`/`caml_hash`/`caml_string_concat` together
account for **13-17% of total runtime** in `fib` and `mandel` -- far above
what interning drove `pisum`'s own string-comparison cost down to
(README.md:220-234: `str_assoc_opt`'s share went from ~2.4% to ~0%). `pisum`
never surfaced this because its hot loop (`s += 1.0 / (k * k)`) is pure
`EBinOp` -- zero named function calls. `fib` calls itself twice per
invocation, `mandel`/`mandelperf` call `real`/`imag`/`complex`/`mandel`
repeatedly, `quicksort` recurses and swaps -- all `ECall`. Traced to
`bin/eval.ml:258-295` (`ECall`'s handling), three things happen on **every
single named call, unconditionally, before `Dispatch.call_cached`'s own
inline cache (the thing "seven optimizations" #1/#3 built) is ever
consulted**:

1. **eval.ml:263** `lookup_opt env name` -- a full, uncached parent-chain
   walk checking whether `name` is shadowed by a local closure. Initially
   assumed this scales with recursion depth; checked against eval.ml:846
   (`SFuncDecl`) and it doesn't -- `def_env` is captured lexically at
   declaration (`let def_env = env in`), and every call's scope is
   `new_scope def_env`, so a top-level function's call-frame is always
   exactly ONE hop from `def_env` (global for `fib`/`mandel`/`quicksort`),
   regardless of recursion depth. The real cost is simpler: a small, FIXED
   number of uncached `str_assoc_opt` scans per call (not growing with
   depth), paid millions of times -- for a plain top-level function this is
   never true, but the walk still runs every time. This is the single
   largest new contributor: `caml_string_equal` inside `str_assoc_opt`.
2. **eval.ml:276** `Hashtbl.mem struct_defs name` -- a second unconditional
   lookup (default OCaml `Hashtbl`, polymorphic hash + structural equality
   on the string key, i.e. `caml_hash` + `caml_string_equal` again) to check
   whether `name` might be a struct constructor, on every call regardless of
   whether it ever is one.
3. **eval.ml:287** `!current_module_prefix ^ name` -- OCaml's `^` always
   allocates and copies into a fresh string, even when
   `current_module_prefix` is `""` (true for all four benchmarks -- none use
   `module`). This runs on every call whether or not the result is ever
   used, and is exactly `caml_string_concat`'s share above.

None of this is touched by the inline cache (`call_cache`'s `gen`/`entry`
cells) -- these three checks all happen *before* `Dispatch.call_cached` is
reached, on every call, cache hit or not. `pisum`'s own profiling could
never have found this: it has no named calls in its hot loop at all.

`quicksort`'s own extra line, not shared with `fib`/`mandel`:
`exec_stmt` 7.1%, `assign_lvalue` 4.0% -- its `a[i], a[j] = a[j], a[i]` swap
idiom goes through `SDestructure`/`assign_lvalue` per target
(eval.ml:740-777). This is real, expected cost for that specific idiom, not
a new inefficiency the way the `ECall` finding above is -- noted for
completeness, not flagged as actionable.

## Fix 1 applied: skip the unconditional qualified-name concat

`!current_module_prefix ^ name` (eval.ml:287) ran on every `ECall`
regardless of whether `current_module_prefix` was ever non-empty -- OCaml's
`^` always allocates, even against `""`. None of the four benchmarks use
`module`, so this was pure waste on every single named call. Changed to only
build `qualified` inside the `current_module_prefix <> ""` branch (the
existing comment already claimed this was "cheap when not inside a module"
-- it wasn't, until now). Semantics unchanged (`differential_test.sh`:
63/63, including `modules_using.jl`, the one test that actually exercises
this branch).

Re-profiled after the fix:

| | `caml_string_concat_1205` | wall clock (amplified run) |
|---|---|---|
| `fib` before | 2.3% | 2.058s |
| `fib` after | gone (not in top 15) | 2.016s (~2% faster) |
| `mandel` before | 2.0% | 2.076s |
| `mandel` after | gone (not in top 15) | 2.006s (~3.4% faster) |
| `quicksort` before | 0.1% (barely present) | 1.991s |
| `quicksort` after | gone | 1.983s (within noise) |

`caml_string_equal`/`caml_hash` (the bigger two contributors) are unchanged
-- expected, this fix only targeted the concat.

## Fix 2 applied: a self-correcting cache for the closure-shadow pre-check

Reconsidered the "extend `resolve.ml` to statically prove a call site is
never shadowed" idea from the first draft of this section and rejected it:
unlike `var_cache`'s depth hint (always re-verified at runtime, a wrong
guess just costs a redundant walk), a blind static skip has no fallback --
if `Resolve`'s conservative walk ever missed a real case (e.g. a
macro-hygiene-renamed binding -- `symbol_concat` already shows up in these
same profiles), the interpreter would silently dispatch to the wrong
function, not crash. Same risk `rust_parser/src/ast.rs`'s own doc comment
gives for why that port never built an equivalent pass. Built a
self-correcting CACHE instead, matching `var_cache`/`Dispatch.call_cache`'s
own established design:

`lookup_opt`'s walk from any call site to `global` (the interpreter's one
and only scope with no parent) has exactly one STABLE link: `global` itself
-- everything between a call site and `global` (the call's own frame, any
enclosing `for`/`if`/`while` body) is fresh per call/iteration and has to be
walked for real regardless. Added `global_generation` (`eval.ml`), bumped
only when `bind` adds a genuinely new key into `global` specifically; each
call site's existing `Dispatch.call_cache` cell (extended with one more
field, `shadow_gen`) remembers the generation as of which it last confirmed
"not found in `global`," and skips re-scanning `global.vars` only when that
generation hasn't moved since. A stale/unset value just falls back to the
exact real scan `lookup_opt` always did -- this can only ever cost a
redundant scan, never produce a wrong dispatch (verified manually: a local
closure introduced partway through a function body, or reassigned globally
between two loops, is still picked up correctly both before and after
this change; `differential_test.sh` stayed 63/63 throughout).

**A real regression, caught before shipping.** The first version defined
the scope-walk as a `let rec walk e = ...` NESTED inside
`lookup_opt_shadow_free`, closing over `skip_global`/`cache`/`name`. This
made `fib`/`mandel` faster as expected, but made `quicksort` measurably
SLOWER (~1.98s to ~2.10s, consistently reproducible over 6 runs) despite a
99.99% cache-hit rate (measured directly: 174,801 skips vs. 12 misses over
one run, via a temporary debug counter). Root cause: `quicksort`'s
call site sits behind two MORE always-walked block scopes (`if` inside
`while`) before reaching `global`, so skipping `global`'s own (small)
scan saves proportionally less of the total per-call work than it does for
`fib` (a 1-hop call site) -- and OCaml/`wasm_of_ocaml`'s compilation
pipeline apparently doesn't elide the nested closure's per-call heap
allocation the way native `flambda` might, so every call paid a fixed
closure-allocation cost that `quicksort`'s smaller proportional win couldn't
cover. Fixed by lifting `walk` to a top-level, non-capturing
`lookup_opt_shadow_free_walk` (passing `name`/`skip_global`/`cache` as
plain arguments instead) -- no closure allocation, same logic. Re-measured:
`quicksort` returned to baseline (no longer regressed), `fib`/`mandel` kept
their wins.

Final numbers (wall clock, amplified runs; `caml_string_equal` = the
targeted cost):

| | before (baseline) | after Fix 1 | after Fix 2 | `caml_string_equal` before → after |
|---|---|---|---|---|
| `fib` | 2.058s | 2.016s | ~1.82s (~11.5% faster than baseline) | 11.3% → 8.3% |
| `mandel` | 2.076s | 2.006s | ~1.81s (~12.8% faster than baseline) | 13.0% → 11.1% |
| `quicksort` | 1.991s | 1.983s | ~1.995s (essentially unchanged) | 9.1% → 9.1% |

`quicksort` not moving is expected, not a shortfall: its call site's
skippable fraction of total per-call work is small (2 extra always-walked
scopes dwarf the one skipped scan), so there was never much to win there --
the fix is still correct and harmless for it, just not impactful.

## Fix 3 applied: same pattern for `Hashtbl.mem struct_defs name`

Same self-correcting-cache shape as Fix 2, applied to the OTHER ECall
pre-check (`eval.ml:332`, originally `Hashtbl.mem struct_defs name && not
(Hashtbl.mem Dispatch.methods name)` -- "is `name` a struct with no custom
constructor?"). Added `struct_defs_generation` (`runtime.ml`, bumped only in
`declare_struct` -- a separate table from `global`, a separate invalidation
event from `bind`) and a fourth `call_cache` field, `struct_gen`, gated the
same way `shadow_gen` is: skip the real `Hashtbl.mem struct_defs name` only
when `cache.struct_gen` already matches the current
`struct_defs_generation`; a stale/unset value falls back to the real check,
same never-trust-blindly guarantee. Verified `is_struct && not (Hashtbl.mem
Dispatch.methods name)` preserves the EXACT original boolean (only the
first conjunct's `true`/`false` computation gets a cached fast path when
it's `false`) -- `differential_test.sh` stayed 63/63, including every
struct-focused test. Deliberately did NOT touch `EQualifiedCall`'s identical
check (`eval.ml:379`): none of the four benchmarks (or anything else
profiled) exercise `Name.member(...)` calls, so there's no measurement
backing that change -- left alone rather than applied on spec.

Written top-level/non-capturing from the start this time (no nested `let
rec`), avoiding Fix 2's closure-allocation trap up front.

Numbers (wall clock, amplified runs; cumulative across all three fixes):

| | baseline | Fix 1 | Fix 2 | Fix 3 | total improvement |
|---|---|---|---|---|---|
| `fib` | 2.058s | 2.016s | ~1.82s | ~1.74s | ~15.5% faster |
| `mandel` | 2.076s | 2.006s | ~1.81s | ~1.70s | ~18.1% faster |
| `quicksort` | 1.991s | 1.983s | ~1.995s | ~2.01s | ~flat (as expected -- no struct use in this benchmark) |

`caml_hash` (1.7-2.1% before, tied to the two `Hashtbl.mem` calls) is gone
from `fib`/`mandel`'s top-15 profile entries entirely after this fix.

## What's left

Nothing else measured and actionable turned up in this investigation.
`caml_string_equal` (now 8-11%, down from 9-13%) is what's left of the
`lookup_opt_shadow_free_walk`/`str_assoc_opt` cost for scopes strictly
between a call site and `global` -- those are fresh per call/iteration by
design (closures need real per-call scopes to capture) and there's no
further safe caching to apply there without changing what gets allocated,
not just what gets looked up. The two originally-flagged bigger levers
(`compile.ml`'s zero-param eligibility gap, real-wasm-emission) remain valid
future work, now on top of a measurably faster tree-walking baseline than
when this document started.
