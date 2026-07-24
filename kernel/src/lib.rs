use faer::prelude::*;
use faer::linalg::solvers::{DenseSolveCore, Solve};
use faer::sparse::{SparseColMat, Triplet};
use faer::MatRef;

#[no_mangle]
pub extern "C" fn wasm_alloc(bytes: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(bytes);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[no_mangle]
pub extern "C" fn wasm_dealloc(ptr: *mut u8, bytes: usize) {
    unsafe {
        drop(Vec::from_raw_parts(ptr, 0, bytes));
    }
}

/// a_ptr: row-major n x n f64 matrix, b_ptr: n f64 vector, out_ptr: n f64 output (caller-allocated).
/// This is the real linear-memory <-> WasmGC boundary: no shared refs, only bytes copied in/out.
#[no_mangle]
pub extern "C" fn matvec(a_ptr: *const f64, b_ptr: *const f64, out_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let b_slice = unsafe { std::slice::from_raw_parts(b_ptr, n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let b: MatRef<f64> = MatRef::from_row_major_slice(b_slice, n, 1);
    let y = a * b;
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, n) };
    for i in 0..n {
        out[i] = y[(i, 0)];
    }
}

/// General Matrix*Matrix (and, via n=1, Matrix*Vector): a_ptr is a row-major
/// m x k matrix, b_ptr is a row-major k x n matrix, out_ptr is the
/// caller-allocated row-major m x n result. Unlike `matvec` above (which
/// only ever handled a SQUARE n x n matrix, since `n` there came from the
/// vector's own length), the three dimensions are independent here, so a
/// genuinely rectangular `A * B` (LinearAlgebra compat's whole point) works.
#[no_mangle]
pub extern "C" fn matmul(a_ptr: *const f64, b_ptr: *const f64, out_ptr: *mut f64, m: i32, k: i32, n: i32) {
    let (m, k, n) = (m as usize, k as usize, n as usize);
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, m * k) };
    let b_slice = unsafe { std::slice::from_raw_parts(b_ptr, k * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, m, k);
    let b: MatRef<f64> = MatRef::from_row_major_slice(b_slice, k, n);
    let c = a * b;
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, m * n) };
    for i in 0..m {
        for j in 0..n {
            out[(i * n) + j] = c[(i, j)];
        }
    }
}

/// det(A) for a row-major n x n matrix -- faer's own `MatRef::determinant`,
/// via an LU decomposition internally. Returns 0.0 for a singular matrix
/// (real Julia's `det` does the same; it does NOT raise for a singular
/// input, only `\`/`inv` can hit trouble there -- see `solve`/`inverse`).
#[no_mangle]
pub extern "C" fn det(a_ptr: *const f64, n: i32) -> f64 {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    a.determinant()
}

/// inv(A) for a row-major n x n matrix, via LU with partial pivoting
/// (`partial_piv_lu().inverse()`). A genuinely singular `A` isn't detected
/// here -- partial-pivoting LU doesn't reliably notice exact singularity,
/// so this can silently produce NaN/Inf rather than raising real Julia's
/// `SingularException`. Disclosed gap, not attempted: doing that properly
/// needs inspecting the LU's own U diagonal for a near-zero pivot, which
/// this ergonomic `faer` entry point doesn't expose.
#[no_mangle]
pub extern "C" fn inverse(a_ptr: *const f64, out_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let inv = a.partial_piv_lu().inverse();
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            out[(i * n) + j] = inv[(i, j)];
        }
    }
}

/// solves A*x = b (A: row-major n x n, b/out: length n) via LU with partial
/// pivoting. Same disclosed gap as `inverse` above: a genuinely singular A
/// isn't detected, unlike real Julia's `\`.
#[no_mangle]
pub extern "C" fn solve(a_ptr: *const f64, b_ptr: *const f64, out_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let b_slice = unsafe { std::slice::from_raw_parts(b_ptr, n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let mut x = faer::Mat::from_fn(n, 1, |i, _| b_slice[i]);
    a.partial_piv_lu().solve_in_place(&mut x);
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, n) };
    for i in 0..n {
        out[i] = x[(i, 0)];
    }
}

/// rank(A) for a row-major m x n matrix, via a thin SVD -- matches real
/// Julia's own default (SVD-based, not LU-pivot counting, which is less
/// numerically robust). The tolerance (largest singular value * max(m,n) *
/// machine epsilon) is the same default LAPACK/Julia's `rank` itself uses.
#[no_mangle]
pub extern "C" fn matrix_rank(a_ptr: *const f64, m: i32, n: i32) -> i32 {
    let (m, n) = (m as usize, n as usize);
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, m * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, m, n);
    match a.thin_svd() {
        Ok(svd) => {
            let s = svd.S().column_vector();
            let smax = s.iter().cloned().fold(0.0_f64, f64::max);
            let tol = smax * (m.max(n) as f64) * f64::EPSILON;
            s.iter().filter(|&&x| x > tol).count() as i32
        }
        Err(_) => 0,
    }
}

/// eigvals(A) for a SYMMETRIC row-major n x n matrix -- the OCaml side
/// checks symmetry before ever calling this (see the "\A" Dispatch method
/// for why: real Julia's own general (non-symmetric) eigendecomposition
/// can produce Complex eigenvalues, which Tsubaki has no Complex-Vector type
/// for; only the symmetric case, where everything stays real, is covered).
/// Cheaper than `eigen_symmetric` below -- faer's own eigenvalues-only path
/// (`self_adjoint_eigenvalues`), no eigenvector computation at all.
/// Eigenvalues come back sorted nondecreasing, same as real Julia's own
/// `eigvals` on a `Symmetric`.
#[no_mangle]
pub extern "C" fn eigvals_symmetric(a_ptr: *const f64, out_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let vals = a
        .self_adjoint_eigenvalues(faer::Side::Lower)
        .expect("self-adjoint eigenvalues: faer failed to converge");
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, n) };
    out.copy_from_slice(&vals);
}

/// eigen(A)/eigvecs(A) for a SYMMETRIC row-major n x n matrix: the full
/// eigendecomposition (eigenvalues, sorted nondecreasing, AND the matching
/// eigenvectors as columns of a row-major n x n matrix) -- same symmetry
/// precondition as `eigvals_symmetric` above.
#[no_mangle]
pub extern "C" fn eigen_symmetric(a_ptr: *const f64, out_vals_ptr: *mut f64, out_vecs_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let eig = a
        .self_adjoint_eigen(faer::Side::Lower)
        .expect("self-adjoint eigendecomposition: faer failed to converge");
    let s = eig.S().column_vector();
    let out_vals = unsafe { std::slice::from_raw_parts_mut(out_vals_ptr, n) };
    for i in 0..n {
        out_vals[i] = s[i];
    }
    let u = eig.U();
    let out_vecs = unsafe { std::slice::from_raw_parts_mut(out_vecs_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            out_vecs[(i * n) + j] = u[(i, j)];
        }
    }
}

/// eigen(A)/eigvals(A)/eigvecs(A) for a GENERAL (possibly non-symmetric)
/// row-major n x n matrix -- faer's own general eigendecomposition
/// (`MatRef::eigen`), whose eigenvalues/eigenvectors are genuinely Complex
/// even for a real input (unlike `eigen_symmetric` above, which only ever
/// needs the real, symmetric-guaranteed case -- verified directly: faer's
/// `.eigen()` on `[[0,-1],[1,0]]` returns eigenvalues `+-i`, exactly the
/// textbook answer for that rotation matrix). Real and imaginary parts come
/// back as separate flat arrays (rather than interleaved) -- simpler on the
/// OCaml side, matching how `VComplex` there is already a (float, float)
/// pair rather than one combined encoding.
#[no_mangle]
pub extern "C" fn eigen_general(
    a_ptr: *const f64,
    out_vals_re_ptr: *mut f64,
    out_vals_im_ptr: *mut f64,
    out_vecs_re_ptr: *mut f64,
    out_vecs_im_ptr: *mut f64,
    n: i32,
) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let eig = a.eigen().expect("general eigendecomposition: faer failed to converge");
    let s = eig.S().column_vector();
    let out_vals_re = unsafe { std::slice::from_raw_parts_mut(out_vals_re_ptr, n) };
    let out_vals_im = unsafe { std::slice::from_raw_parts_mut(out_vals_im_ptr, n) };
    for i in 0..n {
        out_vals_re[i] = s[i].re;
        out_vals_im[i] = s[i].im;
    }
    let u = eig.U();
    let out_vecs_re = unsafe { std::slice::from_raw_parts_mut(out_vecs_re_ptr, n * n) };
    let out_vecs_im = unsafe { std::slice::from_raw_parts_mut(out_vecs_im_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            let v = u[(i, j)];
            out_vecs_re[(i * n) + j] = v.re;
            out_vecs_im[(i * n) + j] = v.im;
        }
    }
}

/// lu(A) for a square row-major n x n matrix -- partial-pivoting LU
/// (`faer::linalg::solvers::PartialPivLu`, the same decomposition `solve`/
/// `inverse` above already compute internally, just exposing its L/U/P
/// instead of only the solved result). L is unit lower-triangular, U is
/// upper-triangular, and P is the row permutation such that A[p, :] == L*U
/// -- p comes back 0-based (faer's own convention); the OCaml side adds 1
/// to match real Julia's 1-based `LU.p::Vector{Int}`.
#[no_mangle]
pub extern "C" fn lu(a_ptr: *const f64, out_l_ptr: *mut f64, out_u_ptr: *mut f64, out_p_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let f = a.partial_piv_lu();
    let l = f.L();
    let u = f.U();
    let (fwd, _bwd) = f.P().arrays();
    let out_l = unsafe { std::slice::from_raw_parts_mut(out_l_ptr, n * n) };
    let out_u = unsafe { std::slice::from_raw_parts_mut(out_u_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            out_l[(i * n) + j] = l[(i, j)];
            out_u[(i * n) + j] = u[(i, j)];
        }
    }
    let out_p = unsafe { std::slice::from_raw_parts_mut(out_p_ptr, n) };
    for i in 0..n {
        out_p[i] = fwd[i] as f64;
    }
}

/// qr(A) for a row-major m x n matrix (any shape) -- thin/economy QR, the
/// same `k = min(m, n)` convention `matrix_rank`'s thin SVD below already
/// uses: Q is m x k with orthonormal columns, R is k x n upper-trapezoidal,
/// and Q*R reconstructs A. Matches real Julia's own default `qr(A)`
/// (LAPACK's economy-size decomposition), not the full square-Q variant.
#[no_mangle]
pub extern "C" fn qr(a_ptr: *const f64, out_q_ptr: *mut f64, out_r_ptr: *mut f64, m: i32, n: i32) {
    let (m, n) = (m as usize, n as usize);
    let k = m.min(n);
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, m * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, m, n);
    let f = a.qr();
    let q = f.compute_thin_Q();
    let r = f.thin_R();
    let out_q = unsafe { std::slice::from_raw_parts_mut(out_q_ptr, m * k) };
    for i in 0..m {
        for j in 0..k {
            out_q[(i * k) + j] = q[(i, j)];
        }
    }
    let out_r = unsafe { std::slice::from_raw_parts_mut(out_r_ptr, k * n) };
    for i in 0..k {
        for j in 0..n {
            out_r[(i * n) + j] = r[(i, j)];
        }
    }
}

/// cholesky(A) for a SYMMETRIC POSITIVE-DEFINITE row-major n x n matrix --
/// the L*L^T decomposition (`faer::linalg::solvers::Llt`). Only L is
/// computed here; U = L' is a pure reindex, done on the OCaml side the same
/// way `transpose` already is, so there's no separate Rust output for it.
/// Same disclosed gap as `eigen_symmetric` above: a non-positive-definite
/// input isn't turned into a Julia-style `PosDefException`, it panics
/// (`.expect`) -- the OCaml side only checks plain symmetry first (cheap),
/// since positive-definiteness genuinely requires attempting the
/// factorization to know either way.
#[no_mangle]
pub extern "C" fn cholesky(a_ptr: *const f64, out_l_ptr: *mut f64, n: i32) {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    let f = a.llt(faer::Side::Lower).expect("cholesky: matrix is not positive definite");
    let l = f.L();
    let out_l = unsafe { std::slice::from_raw_parts_mut(out_l_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            out_l[(i * n) + j] = l[(i, j)];
        }
    }
}

/// isposdef(A) for a SYMMETRIC row-major n x n matrix (caller-verified
/// symmetric on the OCaml side, same convention as eigen_symmetric/
/// cholesky above) -- attempts the exact same Cholesky factorization
/// `cholesky` above does, but returns whether it succeeded (1) or not (0)
/// instead of panicking on failure, since this function's entire point is
/// to be a safe, non-panicking check (unlike `cholesky` itself, whose
/// panic-on-failure is fine there precisely because the OCaml side never
/// calls it without already wanting the factorization to exist).
#[no_mangle]
pub extern "C" fn is_posdef(a_ptr: *const f64, n: i32) -> i32 {
    let n = n as usize;
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, n * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, n, n);
    match a.llt(faer::Side::Lower) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}

/// Internal helper for `nullspace` only (not exposed as its own Tsubaki
/// builtin) -- the FULL svd's V matrix (n x n, unlike the thin `svd`
/// below, whose V is only n x min(m,n)) plus the usual singular values
/// (length min(m,n)). Real Julia's own `nullspace` needs exactly this: a
/// wide A (m < n) has (n - m) "extra" null directions a thin V structurally
/// has no columns to hold at all, since it only ever has min(m,n) of them.
#[no_mangle]
pub extern "C" fn svd_full_v(a_ptr: *const f64, out_v_ptr: *mut f64, out_s_ptr: *mut f64, m: i32, n: i32) {
    let (m, n) = (m as usize, n as usize);
    let k = m.min(n);
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, m * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, m, n);
    let f = a.svd().expect("svd: faer failed to converge");
    let v = f.V();
    let out_v = unsafe { std::slice::from_raw_parts_mut(out_v_ptr, n * n) };
    for i in 0..n {
        for j in 0..n {
            out_v[(i * n) + j] = v[(i, j)];
        }
    }
    let s = f.S().column_vector();
    let out_s = unsafe { std::slice::from_raw_parts_mut(out_s_ptr, k) };
    for (i, &val) in s.iter().enumerate() {
        out_s[i] = val;
    }
}

/// svd(A) for a row-major m x n matrix (any shape) -- thin SVD, the same
/// `k = min(m, n)` convention `qr` above and `matrix_rank` (further below)
/// both use, and the exact same faer call `matrix_rank` already makes: U is
/// m x k, S is length k (singular values, sorted nonincreasing, same as
/// real Julia's `svd`), V is n x k -- NOT V transpose, matching real
/// Julia's `SVD.V` field (some other LAPACK bindings expose Vt instead).
#[no_mangle]
pub extern "C" fn svd(a_ptr: *const f64, out_u_ptr: *mut f64, out_s_ptr: *mut f64, out_v_ptr: *mut f64, m: i32, n: i32) {
    let (m, n) = (m as usize, n as usize);
    let k = m.min(n);
    let a_slice = unsafe { std::slice::from_raw_parts(a_ptr, m * n) };
    let a: MatRef<f64> = MatRef::from_row_major_slice(a_slice, m, n);
    let f = a.thin_svd().expect("svd: faer failed to converge");
    let u = f.U();
    let v = f.V();
    let s = f.S().column_vector();
    let out_u = unsafe { std::slice::from_raw_parts_mut(out_u_ptr, m * k) };
    for i in 0..m {
        for j in 0..k {
            out_u[(i * k) + j] = u[(i, j)];
        }
    }
    let out_v = unsafe { std::slice::from_raw_parts_mut(out_v_ptr, n * k) };
    for i in 0..n {
        for j in 0..k {
            out_v[(i * k) + j] = v[(i, j)];
        }
    }
    let out_s = unsafe { std::slice::from_raw_parts_mut(out_s_ptr, k) };
    for (i, &val) in s.iter().enumerate() {
        out_s[i] = val;
    }
}

/// shared by `sparse_matvec`/`sparse_solve` below -- builds a faer
/// `SparseColMat` from the same COO/triplet convention real Julia's own
/// `sparse(I, J, V, m, n)` uses: parallel row-index/col-index/value arrays,
/// one entry per nonzero (row/col already 0-based -- the OCaml side
/// converts from Julia's 1-based `I`/`J` before crossing this boundary,
/// same as `lu`'s permutation does in the other direction).
unsafe fn sparse_from_triplets(
    row_ptr: *const i32,
    col_ptr: *const i32,
    val_ptr: *const f64,
    nnz: i32,
    m: i32,
    n: i32,
) -> SparseColMat<usize, f64> {
    let nnz = nnz as usize;
    let rows = unsafe { std::slice::from_raw_parts(row_ptr, nnz) };
    let cols = unsafe { std::slice::from_raw_parts(col_ptr, nnz) };
    let vals = unsafe { std::slice::from_raw_parts(val_ptr, nnz) };
    let triplets: Vec<Triplet<usize, usize, f64>> = (0..nnz)
        .map(|i| Triplet::new(rows[i] as usize, cols[i] as usize, vals[i]))
        .collect();
    SparseColMat::try_new_from_triplets(m as usize, n as usize, &triplets)
        .expect("sparse: invalid triplet indices (out of bounds or overflow)")
}

/// A(m x n, sparse, COO/triplet input) * x(n) -> y(m) -- faer's own sparse
/// matmul (via `SparseColMat`'s `Mul` impl), same "no shortcut needed, faer
/// already has this" story as every dense operation above.
#[no_mangle]
pub extern "C" fn sparse_matvec(
    row_ptr: *const i32,
    col_ptr: *const i32,
    val_ptr: *const f64,
    nnz: i32,
    m: i32,
    n: i32,
    x_ptr: *const f64,
    out_ptr: *mut f64,
) {
    let m = m as usize;
    let n = n as usize;
    let a = unsafe { sparse_from_triplets(row_ptr, col_ptr, val_ptr, nnz, m as i32, n as i32) };
    let x_slice = unsafe { std::slice::from_raw_parts(x_ptr, n) };
    let x = faer::Mat::from_fn(n, 1, |i, _| x_slice[i]);
    let y = &a * &x;
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, m) };
    for i in 0..m {
        out[i] = y[(i, 0)];
    }
}

/// A(n x n, sparse, COO/triplet input) \ b(n) -> x(n) -- faer's own sparse
/// LU (`sp_lu`, real partial-pivoting Gaussian elimination exploiting the
/// sparsity pattern, not a dense fallback) plus the same `Solve` trait
/// `solve_in_place` the dense `solve`/`lu` above already use -- verified
/// directly against a dense reference solve of the same system (identical
/// answer). Same disclosed gap as every other `\`/`inv` in this file: a
/// genuinely singular A isn't detected, just panics or produces NaN/Inf.
#[no_mangle]
pub extern "C" fn sparse_solve(
    row_ptr: *const i32,
    col_ptr: *const i32,
    val_ptr: *const f64,
    nnz: i32,
    n: i32,
    b_ptr: *const f64,
    out_ptr: *mut f64,
) {
    let n = n as usize;
    let a = unsafe { sparse_from_triplets(row_ptr, col_ptr, val_ptr, nnz, n as i32, n as i32) };
    let lu = a.sp_lu().expect("sparse solve: faer failed to factorize (singular?)");
    let b_slice = unsafe { std::slice::from_raw_parts(b_ptr, n) };
    let mut x = faer::Mat::from_fn(n, 1, |i, _| b_slice[i]);
    lu.solve_in_place(x.as_mut());
    let out = unsafe { std::slice::from_raw_parts_mut(out_ptr, n) };
    for i in 0..n {
        out[i] = x[(i, 0)];
    }
}

/// Experiment only: the smallest possible FFI round-trip (no allocation, no
/// computation), used to measure pure crossing overhead in isolation from
/// any actual work -- see the AST-in-Rust report.
#[no_mangle]
pub extern "C" fn noop() -> f64 {
    0.0
}

/// Experiment only (see ROADMAP.md / the AST-in-Rust report next to it):
/// the exact same computation as examples/pisum.jl's `pisum()`, hand-ported
/// to Rust, to measure "what if this whole loop body ran natively instead
/// of through Tsubaki's tree-walking interpreter" -- one FFI call in, one
/// f64 out, no per-operation crossing at all. Not a general mechanism (see
/// the report for why turning this into one isn't a small follow-up).
#[no_mangle]
pub extern "C" fn pisum_native() -> f64 {
    let mut s = 0.0_f64;
    for _j in 0..500 {
        s = 0.0;
        for k in 1..=10000_i64 {
            s += 1.0 / ((k * k) as f64);
        }
    }
    s
}

/// The real, general mechanism `pisum_native` above was an experiment
/// leading up to: a small bytecode VM for restricted numeric Tsubaki
/// functions (see the `Compile` module in bin/main.ml). One f64 word per
/// operand keeps the wire format simple -- every operand this compiler
/// ever emits (a slot index, a jump target, a literal int, or a literal
/// float) fits exactly in an f64, so there's no bit-casting on either
/// side of the FFI boundary, unlike a byte-for-byte encoding would need.
#[derive(Clone, Copy)]
enum BValue {
    I(i64),
    F(f64),
    B(bool),
}

impl BValue {
    fn as_f64(self) -> f64 {
        match self {
            BValue::I(n) => n as f64,
            BValue::F(f) => f,
            BValue::B(b) => if b { 1.0 } else { 0.0 },
        }
    }
}

/// mirrors bin/main.ml's `num2` promotion rule exactly: Int op Int stays
/// Int, anything else promotes both sides to Float first.
#[inline(always)]
fn num_binop(a: BValue, b: BValue, iop: fn(i64, i64) -> i64, fop: fn(f64, f64) -> f64) -> BValue {
    match (a, b) {
        (BValue::I(x), BValue::I(y)) => BValue::I(iop(x, y)),
        _ => BValue::F(fop(a.as_f64(), b.as_f64())),
    }
}

#[inline(always)]
fn cmp_binop(a: BValue, b: BValue, icmp: fn(i64, i64) -> bool, fcmp: fn(f64, f64) -> bool) -> BValue {
    match (a, b) {
        (BValue::I(x), BValue::I(y)) => BValue::B(icmp(x, y)),
        _ => BValue::B(fcmp(a.as_f64(), b.as_f64())),
    }
}

/// one of the 11 binops (+ - * / % < <= > >= == !=), by its index in
/// Compile.bin_ops (bin/main.ml) -- shared by all three shapes (Generic,
/// LL, LC) below so the actual arithmetic is written exactly once,
/// regardless of where the operands came from.
#[inline(always)]
fn apply_binop(op_index: i32, a: BValue, b: BValue) -> BValue {
    match op_index {
        0 => num_binop(a, b, |x, y| x + y, |x, y| x + y),
        1 => num_binop(a, b, |x, y| x - y, |x, y| x - y),
        2 => num_binop(a, b, |x, y| x * y, |x, y| x * y),
        // division ALWAYS produces Float, matching Tsubaki's "/" (num2 in bin/main.ml)
        3 => BValue::F(a.as_f64() / b.as_f64()),
        4 => num_binop(a, b, |x, y| x % y, |x, y| x % y),
        5 => cmp_binop(a, b, |x, y| x < y, |x, y| x < y),
        6 => cmp_binop(a, b, |x, y| x <= y, |x, y| x <= y),
        7 => cmp_binop(a, b, |x, y| x > y, |x, y| x > y),
        8 => cmp_binop(a, b, |x, y| x >= y, |x, y| x >= y),
        9 => cmp_binop(a, b, |x, y| x == y, |x, y| x == y),
        10 => cmp_binop(a, b, |x, y| x != y, |x, y| x != y),
        _ => unreachable!("unknown binop index -- Compile.bin_ops and this match must stay in sync"),
    }
}

/// code_ptr/code_words: the flat f64-encoded bytecode, 3 words per
/// instruction: [opcode_tag, operand1, operand2] -- see Compile.encode in
/// bin/main.ml for the exact tag numbering (a fused Bin's (shape, op) pair
/// gets its own tag number, so every instruction stays exactly 3 words),
/// kept in sync by hand on both sides. nslots: how many local variable
/// slots to allocate (computed at compile time in OCaml, includes hidden
/// temps like a for-loop's own upper bound). out_tag_ptr/out_val_ptr: the
/// function's single result, written back as (tag: 0=Int/1=Float/2=Bool,
/// value). Zero-argument functions only for now -- see Eval.SFuncDecl for
/// why -- so there's no separate args buffer.
///
/// Every `locals[i]` access below uses `get_unchecked`/`get_unchecked_mut`
/// instead of plain indexing: real Julia's own `@code_llvm` for these
/// restricted-numeric functions has no bounds check anywhere in the hot
/// path at all (there's nothing to check -- everything lives in SSA
/// registers), and this VM's equivalent is closer to that than a plain
/// safe `Vec` index would be. Sound because `i` always comes from
/// `Compile.slot_for`/`fresh_temp_slot` in bin/main.ml, which only ever
/// hands out indices `< nslots` (the exact count `run_bytecode` was called
/// with) -- there is no code path, malformed input, or Tsubaki-level bug
/// that can make a slot index in this bytecode stream out of range.
#[no_mangle]
pub extern "C" fn run_bytecode(
    code_ptr: *const f64,
    code_words: i32,
    nslots: i32,
    out_tag_ptr: *mut f64,
    out_val_ptr: *mut f64,
) {
    let code = unsafe { std::slice::from_raw_parts(code_ptr, code_words as usize) };
    let n_instr = code.len() / 3;
    let mut locals: Vec<BValue> = vec![BValue::I(0); nslots as usize];
    let mut stack: Vec<BValue> = Vec::with_capacity(16);
    let mut pc: usize = 0;
    loop {
        if pc >= n_instr {
            break;
        }
        let tag = code[pc * 3] as i32;
        let op1 = code[(pc * 3) + 1];
        let op2 = code[(pc * 3) + 2];
        match tag {
            0 => stack.push(BValue::I(op1 as i64)), // Const_int
            1 => stack.push(BValue::F(op1)),         // Const_float
            2 => stack.push(unsafe { *locals.get_unchecked(op1 as usize) }), // Load
            3 => unsafe { *locals.get_unchecked_mut(op1 as usize) = stack.pop().unwrap() }, // Store
            4..=14 => {
                // Generic: both operands already on the stack
                let b = stack.pop().unwrap();
                let a = stack.pop().unwrap();
                stack.push(apply_binop(tag - 4, a, b));
            }
            15 => {
                // Jump
                pc = op1 as usize;
                continue;
            }
            16 => {
                // Jump_if_false
                let cond = match stack.pop().unwrap() {
                    BValue::B(b) => b,
                    _ => unreachable!("Jump_if_false always pops a Bool -- Compile only ever pushes one there"),
                };
                if !cond {
                    pc = op1 as usize;
                    continue;
                }
            }
            17 => {
                stack.pop(); // Pop
            }
            18 => {
                // Return
                let (t, v) = match stack.pop().unwrap() {
                    BValue::I(n) => (0.0, n as f64),
                    BValue::F(f) => (1.0, f),
                    BValue::B(b) => (2.0, if b { 1.0 } else { 0.0 }),
                };
                unsafe {
                    *out_tag_ptr = t;
                    *out_val_ptr = v;
                }
                return;
            }
            19..=29 => {
                // LL fused: both operands read straight from locals, no stack traffic at all
                let a = unsafe { *locals.get_unchecked(op1 as usize) };
                let b = unsafe { *locals.get_unchecked(op2 as usize) };
                stack.push(apply_binop(tag - 19, a, b));
            }
            30..=40 => {
                // LC_int fused: left is a local, right is a literal int
                let a = unsafe { *locals.get_unchecked(op1 as usize) };
                let b = BValue::I(op2 as i64);
                stack.push(apply_binop(tag - 30, a, b));
            }
            41..=51 => {
                // LC_float fused: left is a local, right is a literal float
                let a = unsafe { *locals.get_unchecked(op1 as usize) };
                let b = BValue::F(op2);
                stack.push(apply_binop(tag - 41, a, b));
            }
            52 => {
                // Jump_if_true -- the loop-rotation transform's single backward branch
                let cond = match stack.pop().unwrap() {
                    BValue::B(b) => b,
                    _ => unreachable!("Jump_if_true always pops a Bool -- Compile only ever pushes one there"),
                };
                if cond {
                    pc = op1 as usize;
                    continue;
                }
            }
            53..=63 => {
                // LS fused: left is a local, right is already on the stack
                // (a nested expression's result) -- one pop instead of two
                let a = unsafe { *locals.get_unchecked(op1 as usize) };
                let b = stack.pop().unwrap();
                stack.push(apply_binop(tag - 53, a, b));
            }
            64..=74 => {
                // CS_int fused: left is a literal int, right is already on the stack
                let a = BValue::I(op1 as i64);
                let b = stack.pop().unwrap();
                stack.push(apply_binop(tag - 64, a, b));
            }
            75..=85 => {
                // CS_float fused: left is a literal float, right is already on the stack
                let a = BValue::F(op1);
                let b = stack.pop().unwrap();
                stack.push(apply_binop(tag - 75, a, b));
            }
            _ => unreachable!("unknown opcode tag -- Compile.encode and this match must stay in sync"),
        }
        pc += 1;
    }
}
