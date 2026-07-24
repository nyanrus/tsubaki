# Roadmap: `LinearAlgebra`-equivalent behavior

This tracks what it would take to make Tsubaki's linear algebra behave the
same as real Julia's `LinearAlgebra` stdlib — not a promise to build all of
it, a plan for *if* asked to keep going, staged so each step is independently
useful and separately measurable (same philosophy as everything else in this
repo: verified by running real code, not assumed).

## Where this stands today

- `kernel/` (Rust) already depends on `faer` with `features = ["linalg"]`
  enabled. Checking faer 0.24.4's own source confirms it already implements
  `linalg/{lu,qr,cholesky,evd,gevd,svd}` plus a unified `Solve`/
  `DenseSolveCore` trait (`solve`, `reconstruct`, `inverse`) — the numerical
  engine this roadmap needs already exists and is not the bottleneck.
- Only one FFI entry point is exposed today: `matvec` (`Matrix * Vector`,
  row-major `f64`, byte-copied across the wasm boundary — see
  `kernel/src/lib.rs`).
- Tsubaki's `VMat` is `float array array` (row-major, 2D, `Float64` only, no
  generic element type). No transpose operator, no `Matrix * Matrix`, no
  factorizations, no wrapper types (`Symmetric`/`Diagonal`/...), no `\`.

The blocker, if there is one, was never "can the math be done" — it's how
much OCaml/Rust plumbing (FFI entry points, value representations,
dispatch methods, struct definitions, parser syntax) sits between "faer can
compute this" and "Tsubaki source code that looks like real Julia can ask for
it and get the same answer."

## Stage 1 — Core dense operations + syntax

**Goal:** `A * B`, `A \ b`, `A'`, `det(A)`, `inv(A)`, `tr(A)`, `norm(v)`,
`dot(a, b)` all work and agree with real Julia's answers for ordinary dense
`Float64` matrices.

- Rust: `matmul` (Mat×Mat, same byte-copy convention as `matvec`), `solve`
  (wraps faer's `Solve` trait for `\`), `det`, `inv`. Transpose doesn't need
  Rust at all — just reindex row-major storage on the OCaml side.
- Tsubaki: `'` as a new postfix operator (needs a lexer/parser addition —
  currently no postfix operators other than `.field`/`[index]` exist at
  all); `\` as a new binary operator. `norm`/`dot` need no Rust — they're
  reductions expressible directly as OCaml loops over `VVec`.
- Roughly the same size as one of this session's already-completed rounds
  (e.g. the module system, or the macro system) — a single, bounded unit of
  work.

## Stage 2 — Factorizations

**Goal:** `lu(A)`, `qr(A)`, `cholesky(A)`, `svd(A)`, `eigen(A)` return
struct-like values whose fields match real Julia's naming (`.L`/`.U`/`.p`,
`.Q`/`.R`, `.U`/`.S`/`.V`, `.values`/`.vectors`), and those results are
numerically consistent with what real Julia produces for the same input
(exact bit-for-bit equality isn't the bar — see the compatibility limits
below for why).

- **Done:** `lu`/`qr`/`cholesky`/`svd` (see README.md's own entry on these
  for the full details — square-only `lu`, thin/economy `qr`/`svd` on any
  shape, symmetric-only `cholesky`). Each got its own three-part chain: a
  Rust FFI function in `kernel/src/lib.rs` returning multiple matrices
  (byte-copied, same convention as `matmul`/`solve`/..., just more than one
  output buffer), an OCaml-side struct registered directly via
  `declare_struct` (not parsed from Tsubaki source — these are host-defined
  result types), and a Tsubaki-level function (`lu`/`qr`/`cholesky`/`svd`)
  constructing it.
- **Not done:** `eigen` still only covers the symmetric case (Stage 1/the
  existing `eigvals`/`eigvecs`/`eigen` trio) and hasn't been widened to the
  general non-symmetric case. That's the hard one: a general real matrix can
  have complex eigenvalues. Tsubaki already has `VComplex`, but it's a value
  type entirely separate from `VMat` — `eigen`'s general-case result needs
  complex-valued eigenvector storage, which the current `Matrix`
  representation has no slot for at all (see Stage 4).

## Stage 3 — Specialized wrapper types

**Goal:** `Symmetric(A)`, `Diagonal(v)`, `UpperTriangular(A)`,
`LowerTriangular(A)`, `Tridiagonal(...)` exist and produce CORRECT results
for `*`, `\`, `det`, etc.

- **Done:** `Symmetric`/`Diagonal`/`UpperTriangular`/`LowerTriangular` (see
  README.md's own entry for the full details). Each is an ordinary
  `VStruct` (registered via `declare_struct`, same as the Stage 2
  factorization types) wrapping a dense `Matrix` (`Symmetric`/
  `UpperTriangular`/`LowerTriangular`'s `data` field) or a `Vector`
  (`Diagonal`'s `diag` field), with dispatch methods for `*`/`\`/`det`/
  `inv`/`tr` — real Julia's own field names throughout. `Diagonal` got the
  real O(n)/O(n²) treatment (elementwise ops, row/column scaling) since it
  cost nothing extra to do properly; the two triangular wrappers get the
  free O(n) `det` shortcut (product of the diagonal) real Julia uses too,
  but otherwise — like `Symmetric` entirely — densify to a plain `Matrix`
  and redispatch to the already-existing dense methods above (correct, not
  Julia's actual complexity — see the second bullet below, still true).
  Bonus: `eigvals`/`eigvecs`/`eigen`/`cholesky` now also dispatch directly
  on `Symmetric` (densify-then-redispatch to the existing runtime-checked
  Matrix methods), the real-Julia-idiomatic way to ask for these, resolving
  the "a real `Symmetric` wrapper type... is a further step" gap Stage 1/2
  had disclosed.
- **Done:** `Tridiagonal(dl, d, du)` (see README.md's own entry for the full
  details) — a three-vector shape, different enough from the single-field
  wrappers above that it got its own round. Unlike the other three, its
  `*`/`\`/`det`/`tr` all get their REAL O(n) algorithm (banded matvec, the
  Thomas algorithm, the 3-term determinant recurrence) rather than a
  densify-and-redispatch fallback — only `inv` still densifies, since a
  tridiagonal matrix's inverse is generally dense (no compact shape to
  return it in). **Caught during verification, not before:** naive Thomas
  has no pivoting, so it hit an exact zero pivot on a genuinely nonsingular
  hand-picked 4×4 test case (real LAPACK's own `dgtsv` partial-pivots
  specifically to avoid this) — fixed by falling back to the dense `\`
  above whenever a pivot is exactly zero, rather than shipping the silent
  NaN that naive Thomas produced.
- Matching real Julia's actual COMPUTATIONAL COMPLEXITY for `Symmetric`/
  `UpperTriangular`/`LowerTriangular` (e.g. a triangular `\` being a real
  O(n²) forward/back-substitution, not a full O(n³) dense solve) is a
  separate, harder goal — see the compatibility limits below. "Same
  behavior" (the user's actual ask) only requires correctness, which is
  what's done above.

## Stage 4 — Generality, and where full parity stops being reachable

This is the open-ended layer. Some of it is buildable with enough further
sessions; some of it is a genuine, structural incompatibility with how
Tsubaki is built today, disclosed here rather than glossed over:

- **Numeric type genericity.** Real Julia's `LinearAlgebra` is written once
  and works over `Float32`, `Float64`, `Complex{T}`, `Rational{T}`,
  `BigFloat`, and any user type implementing the right interface, via
  Julia's actual parametric generic programming. Tsubaki's `Matrix` is
  hardcoded to `float array array` (`Float64` only) at the OCaml type
  level — supporting even just `Matrix{Complex}` means either a parallel
  complex-matrix representation or a real generalization of `VMat` itself,
  each a substantial representation change, not an incremental addition.
  **This is the single biggest reason "the exact same behavior" can't be a
  short-term promise** — most of real `LinearAlgebra`'s actual surface
  area is this genericity, not the algorithms themselves.
- **Bit-for-bit numerical agreement.** Real Julia's `LinearAlgebra` calls
  OpenBLAS/LAPACK; Tsubaki's would call faer. Both are correct, IEEE-754
  dense linear algebra implementations, but different implementations of
  (say) LU with partial pivoting can legitimately produce different
  results in the last few bits of precision, or choose different pivots
  for a matrix with tied pivot candidates, or handle near-singular /
  singular matrices differently. "Same behavior" can mean "numerically
  equivalent to reasonable tolerance," never "identical to the last bit" —
  this is a genuine, structural limit, not a gap to be fixed later.
- **The exception hierarchy.** Real Julia raises specific typed exceptions
  for numerical failure — `SingularException`, `PosDefException`,
  `LAPACKException`, `RankDeficientException` — each catchable and
  dispatchable on its own. Tsubaki's error model is a single generic
  `JuliaError`/`Failure` pair (see the language README) with no typed
  exception hierarchy at all; matching this needs Tsubaki's exception system
  to grow real user-facing exception TYPES first, a prerequisite this
  roadmap doesn't cover.
- **`UniformScaling` (`I`) — narrower than first thought.** This was
  originally filed here as needing "its own dedicated design," but on
  closer look, most of what was actually missing was mechanical, not
  structural: `± I` on all five Stage 3 wrapper types is **now done** (see
  README.md's own entry) — adding a scaled identity only ever touches the
  diagonal, so `Diagonal`/`Symmetric`/`UpperTriangular`/`LowerTriangular`/
  `Tridiagonal` all absorb it and stay the SAME wrapper kind, the same
  pattern the pre-existing Matrix/Vector/Number `± I` methods already used.
  **The genuinely hard part that remains** — real Julia's `I` behaving as a
  first-class, arbitrarily-sized `AbstractMatrix` citizen (participating in
  `hcat`, generic algorithms that iterate a matrix's shape) — really would
  need Tsubaki's dispatch to represent a value with no fixed size at all,
  which nothing here does today. Not attempted; a `Matrix(I, m, n)`
  materializing constructor alone (concrete identity on demand, not a
  genuinely lazily-sized citizen) would cover the overwhelming majority of
  real uses without touching dispatch's core assumptions.
- **Sparse matrices.** Real `LinearAlgebra` interoperates with
  `SparseArrays` throughout (specialized factorizations, storage). Tsubaki
  has no sparse representation of any kind — dense-only, full stop, unless
  a sparse `Matrix` variant is designed from scratch.
- **The long tail of smaller functions.** `rank` was already done back in
  Stage 1. **Now also done** (see README.md's own entry for the full
  details): `issymmetric`/`ishermitian` (identical for Tsubaki's real-only
  Matrix), `isposdef` (one small new Rust FFI export, `is_posdef` — the
  same Cholesky attempt `cholesky` makes, reporting success/failure instead
  of panicking), `cond`/`pinv` (redispatch to the existing thin `svd`, PLUS
  Diagonal/Symmetric/both triangular wrappers/Tridiagonal overloads — see
  below, this was itself a disclosed gap closed in a follow-up round), and
  `kron` (pure combinatorics, no FFI).
  **Two of this section's own disclosed gaps have since been closed, in a
  follow-up round after this Stage first shipped** (see README.md's own
  entries for the full details of each):
  - `nullspace` originally redispatched to the thin `svd`, correct only for
    `m ≥ n`. Fixed by adding one new Rust FFI export, `svd_full_v`
    (`kernel/src/lib.rs`) — faer's FULL `svd()` (not `thin_svd()`), whose
    `V` is genuinely `n x n` regardless of shape, giving `nullspace` the
    `(n - m)` "extra" null directions a wide `A`'s thin SVD structurally
    had no columns to hold. `nullspace` now handles every shape uniformly;
    the special-cased "raises for a wide A" behavior is gone.
  - `logdet` originally computed `det` first, then `log`'d it — overflow
    for an enormous `A` before `log` ever ran. Fixed for Matrix (redispatch
    to the existing `lu`, then sum `log|U_ii|` with sign tracking via
    permutation parity, instead of multiplying the U diagonal into a
    single `det` first), Diagonal and both triangular wrappers (sum
    `log|entry|` directly, no factorization needed), and Symmetric
    (densifies and redispatches to the now-fixed Matrix method).
    **Narrower remaining gap:** Tridiagonal's `logdet` still computes
    `det` first via the existing 3-term recurrence, which can itself
    overflow — a genuinely overflow-safe version would need real
    log-domain arithmetic through the recurrence's own subtraction step,
    a harder numerical-analysis problem than a straight sum-of-logs, not
    attempted.
  Still not attempted, and likely to stay that way (there are dozens more
  of these, and "same behavior as real Julia" technically means all of
  them, forever expanding as real Julia's own `LinearAlgebra` grows):
  anything not named above.

## Stage 4 design sketches — recalibrating "structural"

Asked to either close these or design them properly, each of the four
remaining items below got a real look — not just re-reading the bullet
above, but reading faer's own vendored source (`~/.cargo/registry/.../
faer-0.24.4/src/...`) and this file's actual dispatch/type-hierarchy
machinery to find out what's *actually* still missing versus what the
original one-line bullet assumed. Two findings changed shape entirely
(numeric genericity has a small, cheap slice hiding inside the "big"
version; the exception hierarchy's "hard part" turns out to already
exist). Two stayed genuinely hard, for reasons now stated precisely
instead of gestured at.

### Numeric type genericity — small slice DONE, large slice DONE except `BigFloat`, which is now permanently out of scope

The original bullet treated this as one monolithic wall. It splits into
two very differently-sized pieces.

**The small slice — DONE: `eigen`/`eigvals`/`eigvecs` on a general
(non-symmetric) Matrix, returning real Complex results.** This was the
single most-cited disclosed gap across Stages 1–3 ("eigen only covers
symmetric matrices... a real Complex-Matrix type... not attempted"), and
turned out to be exactly the size predicted below. Implemented as
designed, no surprises:

- Two new, wholly disjoint `Runtime.value` variants, `VComplexVec of
  (float * float) array ref` and `VComplexMat of (float * float) array
  array` — a raw pair, matching the existing `VComplex` convention exactly
  (not OCaml's own `Complex.t` module, kept consistent with what was
  already there). Every existing `| VMat rows -> ... | _ -> assert false`
  handler across the file needed zero changes.
- `"ComplexVector"`/`"ComplexMatrix"` registered with `parent:"Any"`,
  deliberately NOT `"Vector"`/`"Matrix"` — exactly the danger this design
  flagged, sidestepped as planned.
- Rust: one new FFI export, `eigen_general` (`kernel/src/lib.rs`), calling
  faer's `.eigen()` — confirmed directly against faer on `[[0,-1],[1,0]]`
  (a real rotation matrix), whose eigenvalues are exactly `+-i`, the
  textbook answer.
- `eigvals`/`eigvecs`/`eigen` on a Matrix now branch on symmetry at
  runtime: symmetric keeps the existing cheaper real-valued path
  unchanged (verified: still returns a plain `Vector`/`Matrix`, not
  Complex); non-symmetric now returns `ComplexVector`/`(ComplexVector,
  ComplexMatrix)` instead of raising. Indexing (`v[i]`, `A[i,j]`) and
  `size` both work on the new types; `typeof` correctly reports
  `"ComplexVector"`/`"ComplexMatrix"`.

Verified against real Julia's own answer for the rotation-matrix case
above, confirmed the symmetric fast-path is unaffected by testing a real
symmetric matrix still returns a plain `Vector`, and confirmed a
non-symmetric-but-real-eigenvalued matrix (upper-triangular-shaped, `[[2,1,0],[0,3,0],[0,0,4]]`)
correctly returns eigenvalues `2, 3, 4` with ~0 imaginary parts via the
general path. Sized almost exactly like one Stage 2 factorization, as
predicted — not a rewrite.

**The large slice — DONE for `Matrix{T}` and `Rational`, still correctly
deferred for `BigFloat`.** `Matrix{T}` genericity was implemented exactly as
this section originally sketched it, no surprises: `VGenMat`, a new,
wholly disjoint boxed-`value`-backed variant (the same `declared: string
option` split `VArr` already uses for `Array{Player}` vs. a plain,
inferred `Array`), built *alongside* (never instead of) `VMat`'s existing
flat-`float array array` backing — `Matrix{Float64}` (the overwhelming
common case, and the only one that can ever cross into faer) keeps its
current representation and FFI path completely untouched, confirmed
byte-for-byte via `pisum`/`mandel`/`quicksort`. `Matrix{T}(undef, m, n)`
for any other `T` gets a slower, pure-OCaml path with no faer acceleration
— the same "densify/fallback, no faer shortcut" posture Stage 3's wrapper
types already established — with elementwise `+`/`-`/scalar-`*` dispatching
each cell through Tsubaki's own multiple dispatch on `T` rather than
hardcoded arithmetic. Registered as a hierarchy SIBLING of `Matrix` (same
`parent:"Any"` trick as `ComplexMatrix` above), not a subtype, so none of
`Matrix`'s existing dispatch bodies are ever handed one — the disclosed
cost being `f(x::Matrix)` never matches a `Matrix{T}` value (see README
for the full writeup). `Rational` also landed, Int-backed rather than
pulling in `zarith` (a `VRational of int * int`, GCD-reduced, same raw-pair
convention as `VComplex`) — deliberately not BigInt-backed, so it silently
overflows the same way any other `VInt` arithmetic here does.

`BigFloat` was spiked and then deliberately dropped, not just deferred.
The spike built a minimal `Z`/`Q` program and compiled it through every
mode this project actually ships (`byte`, `native`, `js`, `wasm`) using
`zarith` + `zarith_stubs_js` (the JS shim that lets `zarith`'s
GMP-backed C stubs run under `js_of_ocaml`). `byte`/`native`/`js` all ran
correctly; `wasm` failed at runtime with `Error: ml_z_init not
implemented` — `zarith_stubs_js` only covers the classic `js_of_ocaml` JS
backend, not the newer `wasm_of_ocaml` backend, and this project's actual
shipping artifact IS the wasm one (`main.bc.wasm.js`, run via `node -r
./preload.js ...` and loaded by `web/demo.html` — the plain `.js` output
is a build byproduct nobody actually runs). So `zarith` doesn't work here,
full stop, not a matter of taste. The remaining option — a self-contained,
pure-OCaml bignum (arbitrary-precision add/sub/mul/div, correct rounding,
parsing/printing) — was assessed as real, error-prone engineering, bigger
than any other stage in this effort, and the user chose to close out the
numeric-genericity work without it rather than take that on. `BigFloat`
is therefore permanently out of scope for this project, not merely
postponed — the same category as the "No REPL, no package system" and
bit-for-bit-agreement exclusions in `README.md`'s "What it deliberately
does not do" section (the latter also covered in this document's own
"Bit-for-bit numerical agreement" section above).

### Bit-for-bit numerical agreement — not a design problem, an identity choice

This one isn't "hard," it's **structurally in tension with the project's
own stated reason to exist.** The only way to get LAPACK-identical bits is
to call actual LAPACK (or OpenBLAS) — and this project's own opening
paragraph is "a pure-Rust linear algebra library (no BLAS/LAPACK, no C, no
Fortran)." Chasing bit-for-bit agreement means abandoning faer for a real
Fortran/C LAPACK binding, which deletes the entire premise the README leads
with. There is no design that gets both. **Recommendation: keep this a
permanent, explicit non-goal, not a backlog item** — the honest framing is
"numerically equivalent to reasonable tolerance," full stop, and every
verification this whole roadmap's work has done (Stage 1 through the long
tail) already only ever checked that tolerance, never bit-identity.

### Exception hierarchy — DONE, and cheaper than either version of this section predicted

Rereading `bin/main.ml`'s own `STry`/`catch` handling and `VStruct`
machinery turned up that what real Julia's typed exceptions need — a real
type hierarchy, checkable via `isa`, with named fields — **already
existed** in this codebase, built for an unrelated reason: `VStruct` plus
`Types.declare`/`Types.distance_to`, and even an `exception JuliaError of
value` already sitting there (built for `throw`, which already accepted
ANY value, not just strings). Nothing needed designing for the type-system
half of this at all.

The first draft of this section still predicted the expensive part would
be rewriting every one of this file's ~90 `failwith "Kind: message"` call
sites individually. Implementing it turned up something better: **every
one of those call sites already tags its own message with a Julia-style
kind prefix by pre-existing convention** (`"DimensionMismatch: ..."`,
`"MethodError: ..."`, `"BoundsError: ..."`, `"UndefVarError: ..."`,
`"TypeError: ..."`, `"DomainError: ..."`). That means the SAME information
the call-site-rewrite plan needed is already sitting in the string, at the
one place every such failure is actually caught — so the whole thing
collapses to a single choke-point fix, not 90 individual ones:

- `declare_struct` for `DimensionMismatch`/`BoundsError`/`UndefVarError`/
  `TypeError`/`MethodError`/`DomainError`/`ErrorException`, each a
  one-field (`msg::String`) struct parented to a new abstract `Exception`
  type — mirroring how thinly real Julia's own built-in exceptions are
  usually defined.
- One new function, `exn_of_failure_message`, that parses a caught
  `Failure`'s string for a recognized `"Kind: "` prefix and constructs the
  matching typed struct (`msg` = the text after the prefix); an
  unrecognized prefix becomes a generic `ErrorException` — real Julia's
  own catch-all for a plain `error(msg)`.
- `STry`'s `Failure` handler calls this instead of wrapping a bare
  `VStr msg` — the ONLY change needed to the interpreter's actual control
  flow. `error(s)` (the `JuliaError` path) now constructs `ErrorException`
  too, for the same `isa` support; `throw(x)` is untouched, still passing
  any user value through raw.
- `show` gained two special cases so the caught value still DISPLAYS
  exactly as before: an `ErrorException` shows as just its bare `msg` (no
  prefix — matches real Julia's own `ErrorException` display, and matches
  this project's own pre-existing, unpinned demo output exactly); the six
  named kinds show as `"Kind: msg"` (matches real Julia's own
  `showerror` convention for these).

Verified: the project's own built-in demo (`main.bc.wasm.js` run with no
file argument)'s try/catch section prints byte-for-byte identically before
and after (`caught:  division by zero` / `caught:  MethodError: no method
matching describe(String)`); `isa(e, DimensionMismatch)` /
`isa(e, MethodError)` / `isa(e, Exception)` all resolve correctly for
their respective real failures and correctly `false` for the wrong kind;
`e.msg` field access works; an unprefixed internal failure (`range step
cannot be 0`) becomes `ErrorException` as designed; and `throw(MyError(42))`
for a user-defined struct still passes through completely unwrapped
(`e.code == 42`), confirming `throw`'s existing behavior wasn't disturbed.

### Sparse matrices — DONE; the numerical engine really was already there

Checked directly: `faer`'s own `Cargo.toml` lists `sparse` as a real
feature (and `sparse-linalg` is even in faer's own **default** feature
set — `kernel/Cargo.toml` just wasn't enabling it). faer's vendored source
under `src/sparse/` has `SparseColMat` (real CSC storage), a
`try_new_from_triplets` constructor — the exact "list of `(row, col,
value)` triples" shape real Julia's own `sparse(I, J, V, m, n)` uses — and
`sparse/solvers.rs` exposes `sp_lu` directly, implementing the SAME
`Solve`/`solve_in_place` trait the dense `lu`/`solve` already use. The
original framing ("no sparse representation... unless designed from
scratch") undersold this, same as every prior Stage's opening line.
Implemented exactly as designed:

- `sparse` Cargo feature flipped on in `kernel/Cargo.toml`.
- Two new Rust FFI exports, `sparse_matvec`/`sparse_solve`
  (`kernel/src/lib.rs`) — COO/triplet input (parallel row/col/value flat
  arrays, same byte-copy convention as everything else), building a fresh
  `SparseColMat` per call (no cached factorization state across FFI calls,
  same posture every dense decomposition already has). Verified `sp_lu`'s
  answer against a dense `partial_piv_lu` solve of the identical (small,
  3×3) system — printed digit-for-digit identically at full `f64`
  precision for this case, though nothing here claims that generalizes to
  every input (see the bit-for-bit section above for why that's never a
  safe assumption in general).
- A new `VSparseMat` value variant — a plain COO/triplet list (`m`, `n`,
  parallel `rows`/`cols`/`vals` arrays), disjoint from `VMat`, registered
  `parent:"Any"` (same reasoning as `ComplexMatrix` above). `sparse(I, J,
  V, m, n)` (1-based COO, real Julia's own constructor signature),
  `spzeros(m, n)`, and `sparse(A::Matrix)` (dense → sparse, dropping exact
  zeros) as constructors; `Matrix(A::SparseMatrixCSC)` densifies back.
  `nnz`, `size`, `*` (Vector), and `\` (Vector, square-only, same
  disclosed non-singular-detection gap as every other `\` here) as the
  "handful of operations that matter most."

Verified: `sparse_matvec`/`sparse_solve` both agree with a dense reference
computation of the identical system (a 3×3 case) to the same precision as
every other faer-backed operation in this file; `sparse(A::Matrix)` then
`Matrix(...)` round-trips back to the original dense values; a larger
10×10 tridiagonal-shaped sparse system (28 nonzeros) solves correctly,
confirmed via `A * (A \ b) ≈ b`; both dimension-mismatch and non-square
`\` raise the expected `DimensionMismatch`. **Not attempted:** `sp_qr`/
`sp_cholesky` (only `sp_lu`-backed `\` was wired up — the "handful of
operations that matter most" scope, not the full sparse factorization
suite), and `*`/`\` against a dense Matrix right-hand side (Vector only).

## Honest summary

Feasible, not blocked — the hard numerical work (faer) is already sitting
there unused, and that turned out to be true again for two of Stage 4's
own four hardest items (general `eigen`'s Complex path, and sparse
matrices) once actually checked against faer's vendored source rather than
assumed. Stage 1 is a same-sized, boundable unit of work (comparable to
one of this session's completed features). Stage 2 is several such units.
Stage 3 is cheap for correctness, expensive for matching real Julia's
performance characteristics. **Of Stage 4's four hardest items, three are
now DONE** — the general-`eigen` Complex slice, the exception hierarchy,
and sparse matrices, each shipped close to (or, for the exception
hierarchy, cheaper than) its own design sketch predicted. Only TWO things
in this whole roadmap remain genuinely, permanently structural: full
`Matrix{T}` genericity for arbitrary `T` (a real representation change,
not an incremental one) and bit-for-bit numerical agreement (in direct
tension with this project's own pure-Rust, no-LAPACK premise — not
fixable without abandoning what makes it interesting, and deliberately
skipped rather than chased). Pick whatever's left; each piece still stands
on its own.
