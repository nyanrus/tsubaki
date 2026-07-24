# Running a math-heavy block natively in Rust instead of interpreting it

**Question:** for a math-heavy block of Tsubaki code, is it sometimes faster to
execute it via one FFI call into Rust than to walk the AST in the OCaml
interpreter? Started as a light experiment (hand-porting one benchmark to
prove the concept); turned into a real, if deliberately narrow, feature —
see "A real mechanism: a bytecode VM" below. Between the two, a genuine JIT
(compiling Tsubaki to native code or wasm at runtime) was considered and
rejected: there's no runtime codegen path available inside a wasm host the
way a native JIT would have one, so a small, restricted bytecode
interpreter in Rust is the realistic version of this idea, not a full
compiler backend.

## Setup

`pisum()` (`examples/pisum.jl`) was picked as the test subject: it's already
this repo's own math-heavy microbenchmark (500 × 10,000 = 5,000,000 inner
iterations of `s += 1.0 / (k * k)`), and its answer is already known-correct
(`~1.6449340668`), so a mismatch would be obvious.

Added to `kernel/src/lib.rs` (all marked "experiment only" in their own
comments, not part of the real language surface):

- `pisum_native()` — the exact same loop, hand-ported to Rust, computed
  entirely inside one call, no per-operation crossing at all.
- `noop()` — the smallest possible FFI round-trip (no allocation, no
  computation), to measure crossing overhead in isolation from any real work.
- Wired through `preload.js` (`host_pisum_native`) and exposed as a Tsubaki
  builtin `native_pisum()` (see `native_pisum` in `bin/main.ml`) so it could
  be measured with the exact same `time()` harness the other benchmarks use.

## Results

Measured two ways — once through Tsubaki's own benchmark harness (`time()`
before/after, matching how every other benchmark in this repo is measured),
once with a standalone Node script calling the wasm exports directly
(`process.hrtime`, bypassing the OCaml interpreter and its `Js.Unsafe`
crossing entirely, to isolate raw FFI cost):

| Measurement | Result |
|---|---|
| `pisum()` — Tsubaki interpreter, via `time()` | ~0.80 s |
| `native_pisum()` — Rust, one FFI call, via `time()` | ~0.003 s |
| `native_pisum()` — Rust, one FFI call, via `process.hrtime` (no OCaml in the loop) | ~0.017 s |
| `noop()` × 5,000,000 — pure FFI crossing, no computation | ~2.2 ns/call (0.011 s total) |

Both `pisum()` and `native_pisum()` returned the identical result
(`1.6448340718480652`), confirming this was a faithful port, not a
coincidentally-similar computation.

The two `native_pisum()` numbers (0.003 s vs 0.017 s) disagree with each
other by roughly 5×, and that's the measurement noise between `Sys.time()`
(CPU time, coarser and going through one more OCaml→JS crossing) and
`process.hrtime` (wall-clock, called directly) — not a contradiction. The
real takeaway is the order of magnitude either way: **hoisting this loop
into Rust entirely was 50×–250× faster than interpreting it**, depending on
which pair of numbers you compare.

## Why the speedup happens (and where it doesn't come from)

The `noop()` measurement is the important control: crossing the FFI boundary
costs about 2 nanoseconds. That's negligible — nowhere near enough to
explain a 50×–250× difference by itself. The entire speedup comes from
**avoiding the interpreter's per-operation cost** (AST node dispatch,
`Dispatch.call_cached`'s method-table lookup, tag comparisons, environment
lookups) 5,000,000 times over, not from batching FFI calls to dodge crossing
overhead. This matters for judging whether the idea generalizes:

- Calling into Rust **once per loop iteration** (instead of once for the
  whole loop) would still only cost ~2 ns of crossing overhead per call —
  genuinely cheap. But Rust would then need to do the SAME kind of
  interpretation work (figure out what operation this AST node represents,
  what type the operands are, dispatch accordingly) that OCaml already does
  reasonably fast. Fine-grained, per-operation crossing isn't obviously a
  win; the whole benefit here came from running the ENTIRE loop body
  natively, with no interpretation happening inside it at all.

## From experiment to a real (if narrow) mechanism: a bytecode VM

`pisum_native()` was a hand-written, hardcoded Rust port of one specific
computation — nothing there read Tsubaki's AST at runtime. Per steering
partway through this work: build the real, general version as **a
restricted bytecode interpreter in Rust**, not a full JIT — there's no
runtime codegen path available inside a wasm host the way a native JIT
would have one (see "Where this could still go" below for what a genuine
step further, emitting real wasm instead of a custom bytecode, would take).

**What got built** (`Compile` module in `bin/main.ml`, VM in
`kernel/src/lib.rs`'s `run_bytecode`):

- A restricted numeric bytecode ISA: Int/Float/Bool arithmetic and
  comparisons, local variable slots, `for`/`while`, `if`/`elseif`/`else`,
  return (explicit or implicit-last-expression).
- An eligibility-checking compiler pass (`Compile.try_compile`) that walks
  a function body ONCE, at declaration time, and either produces real
  bytecode or bails out (`Not_eligible`) — exactly `Resolve`'s existing
  conservative-fallback philosophy elsewhere in this interpreter. Currently
  limited to zero-parameter functions (parameterized/recursive functions,
  structs, arrays, strings, `&&`/`||` as control flow are all explicitly
  out of scope — anything ineligible keeps running through the ordinary
  tree-walking interpreter, completely unchanged, verified by testing both
  eligible and ineligible shapes side by side).
- **Superinstruction fusion**: the overwhelmingly common shape in a hot
  numeric loop is "combine a local variable with another local, or with a
  literal" (`k*k`, `i+1`, a for-loop's own `var <= hi` check) — these get
  their own fused opcodes that read straight out of the locals array with
  no stack traffic at all, instead of the generic `Load; Load; Op` (or
  `Load; Const; Op`) sequence. Chosen automatically at compile time
  whenever both operands of a binop are already-simple atoms (a bare
  variable or a literal); anything nested still falls back to the generic,
  stack-based form.

**Results, on the real, unmodified `pisum()` — nothing hand-ported this
time**:

| Version | `pisum()` wall time | vs. tree-walking interpreter |
|---|---|---|
| Tree-walking interpreter (baseline) | ~0.80 s | 1× |
| Bytecode VM, no fusion | ~0.147 s | ~5.4× faster |
| Bytecode VM, with fusion (naive, no inline hints) | ~0.169 s | ~4.7× faster (**slower than no fusion**) |
| Bytecode VM, with fusion + `#[inline(always)]` | ~0.122 s | ~6.6× faster |
| (`pisum_native()`, the hand-ported reference from above) | ~0.003–0.017 s | ~50×–250× faster |

Every eligible/ineligible test case (a `while`-based function, nested
`if`/`elseif`/`else`, implicit-return, a parameterized function, one
calling `sqrt`, one using `&&`) produced correct results, with ineligible
ones correctly and silently falling back to tree-walking.

**The fusion result is the most interesting finding here**: adding fused
opcodes REDUCED the instruction count per inner-loop iteration by roughly
35% (17 instructions down to 11, by hand-counting `pisum`'s compiled
bytecode), yet the FIRST fused version was actually *slower* than the
unfused one. The cause: consolidating all 11 ops × 3 operand shapes behind
one shared `apply_binop` function meant the Rust compiler could no longer
specialize/inline each (opcode, shape) pair the way it could when every
opcode had its own directly-written match arm — the abstraction cost
briefly exceeded the savings from fewer instructions. Adding
`#[inline(always)]` recovered this (and then some): a reminder that
"fewer bytecode instructions" doesn't automatically mean "faster" in a
compiled host language — it depends on what the optimizer actually does
with the shared code, and that's only knowable by measuring, not assuming.

## A JIT, not an AOT — and what "compile cache" means here

Worth being precise about the terminology: this whole mechanism compiles
lazily, the first time a given `function ... end` is actually *evaluated*
as a statement (which normally means "declared"), not ahead of time before
the program runs at all — that makes it JIT-like, not AOT-like, even
though nothing here re-compiles mid-loop the way a tracing JIT would.

That raised a real question: does the SAME declaration site ever get
evaluated more than once? Yes — a function declared inside another
function's body (re-declared on every call) or inside a loop (re-declared
every iteration) hits `SFuncDecl`'s evaluation repeatedly, with the
IDENTICAL, unchanged AST body every time. Before this was addressed,
`Compile.try_compile` re-ran, and re-decided the exact same eligibility
question, every single time — wasted, since the answer can never change
for a given declaration site.

Fixed with a genuine compile cache: `SFuncDecl` now carries a
`Runtime.funcdecl_cache`, a mutable cell allocated once at PARSE time and
owned by that exact declaration site — the same established pattern this
interpreter already uses for `var_cache` (cached scope-depth) and
`Dispatch.call_cache` (cached dispatch target). The first evaluation of a
given site runs `try_compile` and remembers the outcome (its bytecode, or
"ineligible"); every later evaluation of that SAME site skips
recompilation entirely and reuses the cached decision. Verified directly:
a function declared inside a `for outer in 1:5` loop, with a temporary
counter placed inside `try_compile` itself, showed exactly ONE compile
attempt across all 5 loop iterations, not 5 — confirmed correct results
either way (compilation is a pure function of the AST, so correctness
never depended on this), with the cache purely removing the redundant
recompilation work.

**Measured, not just verified-correct** — a synthetic case that redeclares
an eligible function 200,000 times inside a loop (calling it once per
iteration each time), comparing the cache active (real behavior) against
temporarily forcing every evaluation through the "not yet compiled" path
regardless of actual cache state (a controlled way to get a same-code
no-cache baseline, reverted immediately after measuring):

| Function body | With cache | Forced always-recompile | Saved |
|---|---|---|---|
| Small (one `for` loop, ~10 AST nodes) | ~1.26 s | ~1.35 s | ~7% |
| Bigger (`if`/`elseif`/`else` + nested `while`, ~25 AST nodes) | ~3.18 s | ~3.69 s | ~14% |

(Machine load varies run to run enough to shift absolute numbers by
10-20% — these are paired, back-to-back comparisons under the same
conditions, not isolated absolute measurements; the relative saving is
the meaningful number here.) The saving scales with how much there is to
recompile, as expected — `try_compile` is a cheap, linear scan of the AST,
so this cache mostly matters for the "declared inside a loop, or inside a
frequently-called function" pattern specifically, not for the common case
of a function declared once at the top level (which only ever compiles
once regardless, cache or not).

## A further round: reading real Julia's own LLVM IR, not just guessing

The bytecode VM above was reasoned out from first principles (what does a
hot numeric loop actually need). A further round instead started from
concrete evidence: `@code_llvm` on real Julia's own `pisum()`, to see what
LLVM actually does with this exact loop once type inference has proven
every value's concrete type, and to check the VM here for any real gap
against it.

```
julia> using InteractiveUtils
julia> @code_llvm debuginfo=:none pisum()

define double @julia_pisum_132() #0 {
top:
  br label %L2
L2:
  %value_phi = phi i64 [ 1, %top ], [ %5, %L21 ]
  br label %L3
L3:
  %value_phi1 = phi double [ 0.000000e+00, %L2 ], [ %3, %L3 ]
  %value_phi2 = phi i64 [ 1, %L2 ], [ %4, %L3 ]
  %0 = mul i64 %value_phi2, %value_phi2
  %1 = sitofp i64 %0 to double
  %2 = fdiv double 1.000000e+00, %1
  %3 = fadd double %value_phi1, %2
  %.not.not = icmp eq i64 %value_phi2, 10000
  %4 = add nuw nsw i64 %value_phi2, 1
  br i1 %.not.not, label %L21, label %L3
L21:
  %.not.not9 = icmp eq i64 %value_phi, 500
  %5 = add nuw nsw i64 %value_phi, 1
  br i1 %.not.not9, label %L31, label %L2
L31:
  ret double %3
}
```

Two concrete, actionable differences from this VM's bytecode, neither
guessed at:

1. **One branch per iteration, not two.** The inner loop's `br i1 ...,
   label %L21, label %L3` is the ONLY branch instruction per iteration —
   there's no separate unconditional "jump back to the top" the way this
   VM's `for`/`while` compiled to (`Bin("<=", ...); Jump_if_false end; body;
   increment; Jump loop_start` — a conditional forward exit AND an
   unconditional backward jump, every iteration). This is **loop rotation**:
   hoist one entry check before the loop (skips the whole loop for an
   empty range, matching real Julia's own semantics for `for i in 5:3`),
   then let the loop body's own tail re-check and conditionally branch
   straight back — one branch dispatched per iteration instead of two.
   `Compile.compile_for`/`compile_while` (`bin/main.ml`) now emit exactly
   this shape, via a new `Jump_if_true` opcode (tag 52).
2. **An atom folded directly into the operation never round-trips through
   a stack slot.** `fdiv double 1.000000e+00, %1` takes the literal `1.0`
   as a plain immediate operand — LLVM never materializes it as a separate
   SSA value that then gets "popped." Compare: this VM's fused shapes
   (`LL`/`LC_int`/`LC_float`) only fired when BOTH sides of a `Bin` were
   already-simple atoms, so `1.0 / (k * k)` — left side a literal, right
   side the nested (already-fused) `k * k` — still fell back to the fully
   generic stack form (`Const_float 1.0` pushed, then popped back off
   alongside the division's other operand). Same story for `s + (...)`:
   `s` is a bare local, but the right side is a nested division, so the
   old compiler emitted a `Load s` (push) purely to have something to pop
   two instructions later. Three new fused shapes cover this — `LS`
   (local on the left, nested-on-stack on the right), `CS_int`, `CS_float`
   (an int/float literal on the left, nested-on-stack on the right, tags
   53–85) — each popping exactly ONE stack value instead of two. Only the
   "atom on the left" direction is covered, matching `LC_int`/`LC_float`'s
   own pre-existing "var on the left" limit; "nested op atom" still falls
   back to `Generic`, unchanged, exactly as documented in `bin/main.ml`.

A third change came from the same IR, read the other way — what's
*absent*, not what's present: there is no bounds check anywhere in this
function. Nothing needs one (every value lives in an SSA register), but
it's also true that `run_bytecode`'s own `locals[i]` accesses were plain
`Vec` indexing, paying for a bounds check on every `Load`/`Store`/fused-op
even though `i` only ever comes from `Compile.slot_for`/`fresh_temp_slot`,
which can't produce an out-of-range index for the `nslots` `run_bytecode`
was called with. Switched to `get_unchecked`/`get_unchecked_mut`.

**Measured, same session, paired (machine load moves absolute numbers
between separate sessions — see the caution elsewhere in this repo about
comparing across them):**

| Version | `pisum()` wall time |
|---|---|
| Before this round (fusion + `#[inline(always)]`, as shipped above) | ~0.227 s |
| + loop rotation (`for`/`while`) + `LS`/`CS_int`/`CS_float` fusion | ~0.193 s |
| + unchecked `locals` access | ~0.188 s |

Loop rotation and the new fused shapes account for most of the win (~15%);
removing the bounds check on top of that is real but small (~3%) and, on
a noisier run, briefly vanished into session-to-session variance —
consistent with this project's earlier finding (the original seven
optimizations) that comparison/dispatch overhead, not memory-safety
bookkeeping, tends to dominate this interpreter's hot paths. Every
`examples/*.jl` benchmark (`fib`, `mandel`, `pisum`, `quicksort`) still
produces its expected answer, and a small hand-written test covering the
new shapes plus the loop-rotation edge cases that would actually expose a
rotation bug (an empty `for` range, a single-iteration range, a `while`
whose condition is false from the start) was checked against real Julia's
own output for the same expressions, not just hand-computed.

## Where this could still go: real AOT via emitted wasm, not a custom VM

A further idea, raised after the bytecode VM above was working: instead of
shipping a CUSTOM bytecode that a hand-written Rust loop interprets
(`run_bytecode`, still fundamentally an interpreter, however fused/fast),
`Compile` could emit an actual, valid **wasm module binary** for an
eligible function — real `local.get`/`i64.add`/`f64.div`/`loop`/`br_if`
instructions, not a custom ISA — and instantiate it via the exact same
synchronous `WebAssembly.Module`/`WebAssembly.Instance` machinery
`preload.js` already uses for the Rust kernel. The host's own wasm engine
(V8's Liftoff/TurboFan under Node) would then compile THAT to real machine
code, the same way it compiles the Rust kernel today — genuinely AOT-like,
and the honest way to approach native speed rather than "a faster
interpreter, however fused."

This is a real, further step, not a small one: it means hand-writing a
valid wasm binary encoder (LEB128 varints, the module's type/function/
code/export sections, real stack-machine instruction encoding) rather than
a flat f64 array — a different, larger kind of work than the bytecode VM
above, closer in kind to what a `wasm-encoder`-style crate does. The
per-declaration-site compile cache above (see "A JIT, not an AOT") would
carry over directly — same idea, just caching emitted wasm module bytes
instead of the flat bytecode array — and would matter MORE here, since
emitting and instantiating a real wasm module is real, repeatable work,
unlike `try_compile`'s cheap linear AST scan. Not started — a real next
stage, not attempted in this round given its size relative to what's been
built so far.

## A real correctness bug this caught: free variables silently became phantom locals

Found later, from an unrelated direction — `rust_parser/` (see its own
README) grew a small tree-walking evaluator for `if`/`for`/`while`/`return`
and, eventually, `function` declarations, specifically to differential-test
against this real interpreter on statement-level programs, not just bare
expressions. The very first function-declaration test that used a
zero-parameter function reading/writing what looked like an outer variable
disagreed with the Rust port:

```
counter = 0
function bump()
    counter = counter + 1
    return counter
end
println(bump())
println(bump())
println(counter)
```

Expected (and what the Rust port printed): `1`, `2`, `2`. What this
interpreter actually printed: `1`, `1`, `0` — `bump()` never touched the
real `counter` at all.

**Root cause**: `Compile.try_compile`'s `slot_for` (`bin/compile.ml`)
allocated a bytecode local slot for ANY identifier it encountered, with no
check for whether that name was a real local this function itself had
declared. Zero-parameter functions have no other source of locals, so any
bare reference to an outer/global variable was silently compiled as a
`Load`/`Store` against a private slot instead — and `run_bytecode`
zero-initializes its `locals` array fresh on every single call (`vec![BValue::I(0);
nslots]`, `kernel/src/lib.rs`), so that phantom local reset to `0` every
time. Wrong answer, not a crash — worse than the alternative, since nothing
signals anything went wrong. This had been sitting underneath every
zero-parameter function's `try_compile` pass since the bytecode VM above was
first built; parameterized functions were never affected (multi-argument
`try_compile` isn't attempted at all, per its own documented scope), which
is presumably why hand-testing never surfaced it.

**Fix**: split `slot_for` into two functions. Assignment targets
(`SExpr (EAssign ...)`, a `for` loop's own header variable) still use the
original create-if-missing `slot_for` — those really are this function
declaring a fresh local. Every READ of a bare variable (`EVar` in
`compile_expr`, including as an operand of a fused binop shape) now goes
through a new `slot_for_read`, which only succeeds if that name is ALREADY
a known slot; otherwise it raises `Not_eligible`, falling back to the
ordinary tree-walking interpreter — the same conservative-bailout
philosophy this file already documents for every other unsupported shape.

Verified: the `bump()` example above now prints `1`, `2`, `2` on both
sides; a function reading (but not writing) an outer variable still gets
`Not_eligible`'d the same way (previously it silently returned `0` for a
never-assigned free name instead of `UndefVarError`); every `examples/*.jl`
benchmark still produces its expected answer at unchanged speed (`pisum()`
only references its own for-loop variable and its own local `s`, both
genuine declarations, so its eligibility — and the whole point of this
mechanism — is untouched).

## Reproducing this

```
make build
node -r ./preload.js _build/default/bin/main.bc.wasm.js examples/pisum.jl   # now bytecode-compiled automatically, no source changes
node -r ./preload.js _build/default/bin/main.bc.wasm.js <(cat examples/pisum.jl; echo 'println(native_pisum())')  # vs. the original hand-ported reference
```

`noop()`/`pisum_native()` stay in `kernel/src/lib.rs`, clearly marked as
the experiment that led here, so the original numbers are still
reproducible without reconstructing anything.
