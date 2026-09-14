(* ============================= Math ============================= *)
(* 行列とベクトルと、そのまわりの線形代数。Runtime から出してある。

   ここに居るものは、どれも「数をまとめて扱う」ための道具です --
   Vector と Matrix の四則、転置、内積、ノルム、行列式、逆行列、固有値、
   LU/QR/Cholesky/SVD、三角行列と対称行列と三重対角行列、疎行列。

   drop の logic は、こういうものを持たない。ボタンを並べて、pref を読んで、
   幅を覚えるだけの仕事に、固有値分解は要らない。Runtime に居たころは、
   誰も呼ばなくても一緒に配られていました -- 137KB のうちの、いちばん大きな
   ひとかたまり。

   重い計算そのものは kernel/(Rust の wasm)に降りていて、ここはその呼び方と、
   Tsubaki の値との行き来だけ。 *)
open Runtime

let () =
  (* Vector,Vector elementwise arithmetic *)
  Dispatch.defmethod "+" [ [ "Vector" ]; [ "Vector" ] ] (function
    | [ VVec a; VVec b ] -> VVec (vecbuf_of_array (Array.map2 ( +. ) (vecbuf_to_array a) (vecbuf_to_array b)))
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "Vector" ]; [ "Vector" ] ] (function
    | [ VVec a; VVec b ] -> VVec (vecbuf_of_array (Array.map2 ( -. ) (vecbuf_to_array a) (vecbuf_to_array b)))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Number" ]; [ "Vector" ] ] (function
    | [ s; VVec b ] -> VVec (vecbuf_of_array (Array.map (fun x -> as_float s *. x) (vecbuf_to_array b)))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Vector" ]; [ "Number" ] ] (function
    | [ VVec a; s ] -> VVec (vecbuf_of_array (Array.map (fun x -> x *. as_float s) (vecbuf_to_array a)))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Number" ]; [ "Matrix" ] ] (function
    | [ s; VMat rows ] -> VMat (Array.map (Array.map (fun x -> as_float s *. x)) rows)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Matrix" ]; [ "Number" ] ] (function
    | [ VMat rows; s ] -> VMat (Array.map (Array.map (fun x -> x *. as_float s)) rows)
    | _ -> assert false);
  (* the real cross-module call: Matrix * Vector/Matrix via Rust/faer.
     host_matmul (unlike the older host_matvec rotate2d still uses) isn't
     square-only -- a Vector is just treated as its own k x 1 Matrix. Both
     check inner dimensions agree before crossing the FFI boundary --
     host_matmul itself trusts its m/k/n args completely (see its own
     comment), so a real Julia-style DimensionMismatch has to be raised
     here, on the OCaml side, or a mismatched call would silently read
     past what the smaller side actually has. *)
  Dispatch.defmethod "*" [ [ "Matrix" ]; [ "Vector" ] ] (function
    | [ VMat rows; VVec b ] ->
      let b = vecbuf_to_array b in
      let k = if Array.length rows = 0 then 0 else Array.length rows.(0) in
      if k <> Array.length b then
        failwith
          (Printf.sprintf "DimensionMismatch: Matrix has %d columns, Vector has %d elements" k (Array.length b))
      else (
        let col = Array.map (fun x -> [| x |]) b in
        VVec (vecbuf_of_array (Array.map (fun row -> row.(0)) (host_matmul rows col))))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Matrix" ]; [ "Matrix" ] ] (function
    | [ VMat a; VMat b ] ->
      let ka = if Array.length a = 0 then 0 else Array.length a.(0) in
      let kb = Array.length b in
      if ka <> kb then
        failwith (Printf.sprintf "DimensionMismatch: %d-column Matrix times %d-row Matrix" ka kb)
      else VMat (host_matmul a b)
    | _ -> assert false);
  (* transpose(A)/A' -- for a Matrix, a fresh Matrix with rows/cols
     swapped; for a Vector, real Julia's `transpose` returns a lazy 1xN
     row-vector view (`Transpose{Float64, Vector{Float64}}`), a genuinely
     different type from Matrix -- Tsubaki has no such wrapper type, so
     this materializes an actual 1xN Matrix instead. Disclosed
     simplification, not a lazy view; a later transpose of THAT result
     still round-trips correctly (just pays for a second real copy). *)
  Dispatch.defmethod "transpose" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      VMat (Array.init n (fun j -> Array.init m (fun i -> rows.(i).(j))))
    | _ -> assert false);
  Dispatch.defmethod "transpose" [ [ "Vector" ] ] (function
    | [ VVec v ] -> VMat [| Array.copy (vecbuf_to_array v) |]
    | _ -> assert false);
  (* dot(a,b)/a⋅b -- real LinearAlgebra's Euclidean inner product; both
     spellings share this one impl, registered under both names *)
  let dot_impl = function
    | [ VVec a; VVec b ] ->
      let a = vecbuf_to_array a and b = vecbuf_to_array b in
      if Array.length a <> Array.length b then
        failwith "DimensionMismatch: dot product needs two Vectors of the same length"
      else VFloat (Array.fold_left ( +. ) 0.0 (Array.map2 ( *. ) a b))
    | _ -> assert false
  in
  Dispatch.defmethod "dot" [ [ "Vector" ]; [ "Vector" ] ] dot_impl;
  Dispatch.defmethod "\xe2\x8b\x85" [ [ "Vector" ]; [ "Vector" ] ] dot_impl;
  (* norm(v) (Euclidean/2-norm) and norm(v,p) (general p-norm) -- matrix
     norms (operator/spectral norm, needing an SVD) aren't covered, same
     "vector case only" scope as the rest of this LinearAlgebra round *)
  Dispatch.defmethod "norm" [ [ "Vector" ] ] (function
    | [ VVec v ] -> VFloat (sqrt (Array.fold_left (fun acc x -> acc +. (x *. x)) 0.0 (vecbuf_to_array v)))
    | _ -> assert false);
  Dispatch.defmethod "norm" [ [ "Vector" ]; [ "Number" ] ] (function
    | [ VVec v; p ] ->
      let p = as_float p in
      VFloat (Array.fold_left (fun acc x -> acc +. (Float.abs x ** p)) 0.0 (vecbuf_to_array v) ** (1.0 /. p))
    | _ -> assert false);
  (* zeros/ones -- Vector for one dimension, Matrix for two, matching real
     Julia's own zeros(n)/zeros(n,m) overload shape *)
  Dispatch.defmethod "zeros" [ [ "Int" ] ] (function
    | [ VInt n ] -> VVec (vecbuf_of_array (Array.make n 0.0))
    | _ -> assert false);
  Dispatch.defmethod "ones" [ [ "Int" ] ] (function
    | [ VInt n ] -> VVec (vecbuf_of_array (Array.make n 1.0))
    | _ -> assert false);
  Dispatch.defmethod "zeros" [ [ "Int" ]; [ "Int" ] ] (function
    | [ VInt n; VInt m ] -> VMat (Array.make_matrix n m 0.0)
    | _ -> assert false);
  Dispatch.defmethod "ones" [ [ "Int" ]; [ "Int" ] ] (function
    | [ VInt n; VInt m ] -> VMat (Array.make_matrix n m 1.0)
    | _ -> assert false);
  (* size(A) -- a Matrix's (rows, cols) tuple, or a single dimension via
     size(A, dim); size(v) for a Vector matches real Julia's own 1-tuple *)
  Dispatch.defmethod "size" [ [ "Matrix" ] ] (function
    | [ VMat rows ] -> VTuple [| VInt (Array.length rows); VInt (if Array.length rows = 0 then 0 else Array.length rows.(0)) |]
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "Matrix" ]; [ "Int" ] ] (function
    | [ VMat rows; VInt 1 ] -> VInt (Array.length rows)
    | [ VMat rows; VInt 2 ] -> VInt (if Array.length rows = 0 then 0 else Array.length rows.(0))
    | [ VMat _; VInt d ] -> failwith (Printf.sprintf "BoundsError: a Matrix has no dimension %d" d)
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "Vector" ] ] (function
    | [ VVec v ] -> VTuple [| VInt (vecbuf_length v) |]
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "ComplexVector" ] ] (function
    | [ VComplexVec v ] -> VTuple [| VInt (Array.length !v) |]
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "ComplexMatrix" ] ] (function
    | [ VComplexMat rows ] ->
      VTuple [| VInt (Array.length rows); VInt (if Array.length rows = 0 then 0 else Array.length rows.(0)) |]
    | _ -> assert false);
  (* the generic boxed Matrix{T} (VGenMat) -- same size(A)/size(A,dim)/
     length(A) shape as the numeric Matrix above, registered once against
     the shared "GenericMatrix" base so it matches every concrete element
     type at once (see Types' "GenericMatrix" entry). *)
  Dispatch.defmethod "size" [ [ "GenericMatrix" ] ] (function
    | [ VGenMat { rows; cols; _ } ] -> VTuple [| VInt rows; VInt cols |]
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "GenericMatrix" ]; [ "Int" ] ] (function
    | [ VGenMat { rows; _ }; VInt 1 ] -> VInt rows
    | [ VGenMat { cols; _ }; VInt 2 ] -> VInt cols
    | [ VGenMat _; VInt d ] -> failwith (Printf.sprintf "BoundsError: a Matrix has no dimension %d" d)
    | _ -> assert false);
  Dispatch.defmethod "length" [ [ "GenericMatrix" ] ] (function
    | [ VGenMat { rows; cols; _ } ] -> VInt (rows * cols)
    | _ -> assert false);
  (* elementwise +/-, scalar *; each cell's operation is resolved through
     Tsubaki's OWN multiple dispatch on the element type (Dispatch.call),
     not hardcoded arithmetic -- so a Matrix{Named} works as long as
     Named itself has +/-/* methods defined, same as real Julia's generic
     LinearAlgebra over any T. Deliberately no faer acceleration. *)
  Dispatch.defmethod "+" [ [ "GenericMatrix" ]; [ "GenericMatrix" ] ] (function
    | [ VGenMat a; VGenMat b ] ->
      if a.rows <> b.rows || a.cols <> b.cols then
        failwith
          (Printf.sprintf "DimensionMismatch: matrices have sizes (%d,%d) and (%d,%d)" a.rows a.cols b.rows b.cols)
      else mk_gen_mat a.rows a.cols (Array.init (a.rows * a.cols) (fun k -> Dispatch.call "+" [ a.cells.(k); b.cells.(k) ]))
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "GenericMatrix" ]; [ "GenericMatrix" ] ] (function
    | [ VGenMat a; VGenMat b ] ->
      if a.rows <> b.rows || a.cols <> b.cols then
        failwith
          (Printf.sprintf "DimensionMismatch: matrices have sizes (%d,%d) and (%d,%d)" a.rows a.cols b.rows b.cols)
      else mk_gen_mat a.rows a.cols (Array.init (a.rows * a.cols) (fun k -> Dispatch.call "-" [ a.cells.(k); b.cells.(k) ]))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Number" ]; [ "GenericMatrix" ] ] (function
    | [ s; VGenMat a ] -> mk_gen_mat a.rows a.cols (Array.map (fun c -> Dispatch.call "*" [ s; c ]) a.cells)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "GenericMatrix" ]; [ "Number" ] ] (function
    | [ VGenMat a; s ] -> mk_gen_mat a.rows a.cols (Array.map (fun c -> Dispatch.call "*" [ c; s ]) a.cells)
    | _ -> assert false);
  (* A \ b, det(A), inv(A) -- square-A only (a genuine least-squares `\`
     for a rectangular A, via QR, isn't attempted here). All three go
     through faer/LU on the Rust side; a genuinely singular A is NOT
     detected (real Julia's `SingularException`) -- see kernel/src/lib.rs's
     own comments on `solve`/`inverse` for why that's a real, disclosed gap
     rather than a small follow-up. *)
  Dispatch.defmethod "\\" [ [ "Matrix" ]; [ "Vector" ] ] (function
    | [ VMat rows; VVec b ] ->
      let b = vecbuf_to_array b in
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: A \\ b only supports a square A (no least-squares here)"
      else if n <> Array.length b then
        failwith (Printf.sprintf "DimensionMismatch: A is %dx%d, b has %d elements" m n (Array.length b))
      else VVec (vecbuf_of_array (host_solve rows b n))
    | _ -> assert false);
  Dispatch.defmethod "det" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: det needs a square Matrix"
      else VFloat (host_det rows n)
    | _ -> assert false);
  Dispatch.defmethod "inv" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: inv needs a square Matrix"
      else VMat (host_inverse rows n)
    | _ -> assert false);
  (* tr(A) -- sum of the diagonal, plain OCaml (no FFI needed, same as
     dot/norm above -- there's no real work here for faer to do faster) *)
  Dispatch.defmethod "tr" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: tr needs a square Matrix"
      else VFloat (Array.fold_left ( +. ) 0.0 (Array.init m (fun i -> rows.(i).(i))))
    | _ -> assert false);
  (* rank(A) -- any shape, not just square; via a thin SVD (see
     kernel/src/lib.rs's matrix_rank), matching real Julia's own default
     method rather than a less robust LU-pivot count *)
  Dispatch.defmethod "rank" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      VInt (host_rank rows m n)
    | _ -> assert false);
  (* eigvals(A)/eigvecs(A)/eigen(A) -- square Matrix. A SYMMETRIC input
     takes the cheaper, real-valued path (`eigvals_symmetric`/
     `eigen_symmetric` -- no eigenvector computation at all for
     `eigvals`, and eigenvalues come back pre-sorted nondecreasing,
     matching real Julia's own `Symmetric` path exactly, same as before
     this round). A NON-symmetric input now takes faer's general
     eigendecomposition (`eigen_general`, ROADMAP.md's Stage 4 "small
     genericity slice") instead of raising -- its eigenvalues/eigenvectors
     are genuinely `ComplexVector`/`ComplexMatrix` even for an all-real
     input (verified directly against faer: `[[0,-1],[1,0]]`, a real
     rotation matrix, produces eigenvalues `+-i` exactly, the textbook
     answer), matching real Julia's own general (non-`Symmetric`) `eigen`
     always going through the non-symmetric LAPACK path. `ComplexVector`/
     `ComplexMatrix` are deliberately NOT `Vector`/`Matrix` subtypes (see
     their own `Types.declare` comment above) -- a caller pattern-matching
     on `eigvals(A)`'s result needs to handle BOTH a real `Vector` and a
     `ComplexVector` now, exactly the ambiguity real Julia's own
     `eigen(::Matrix)` return type already has. *)
  let is_symmetric rows =
    let n = Array.length rows in
    let ok = ref true in
    for i = 0 to n - 1 do
      for j = i + 1 to n - 1 do
        if Float.abs (rows.(i).(j) -. rows.(j).(i)) > 1e-9 then ok := false
      done
    done;
    !ok
  in
  let require_square_for rows who =
    let m = Array.length rows in
    let n = if m = 0 then 0 else Array.length rows.(0) in
    if m <> n then failwith (Printf.sprintf "DimensionMismatch: %s needs a square Matrix" who) else n
  in
  Dispatch.defmethod "eigvals" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let n = require_square_for rows "eigvals" in
      if is_symmetric rows then VVec (vecbuf_of_array (host_eigvals_symmetric rows n))
      else (
        let vals, _ = host_eigen_general rows n in
        VComplexVec (ref vals))
    | _ -> assert false);
  Dispatch.defmethod "eigvecs" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let n = require_square_for rows "eigvecs" in
      if is_symmetric rows then (
        let _, vecs = host_eigen_symmetric rows n in
        VMat vecs)
      else (
        let _, vecs = host_eigen_general rows n in
        VComplexMat vecs)
    | _ -> assert false);
  Dispatch.defmethod "eigen" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let n = require_square_for rows "eigen" in
      if is_symmetric rows then (
        let vals, vecs = host_eigen_symmetric rows n in
        VTuple [| VVec (vecbuf_of_array vals); VMat vecs |])
      else (
        let vals, vecs = host_eigen_general rows n in
        VTuple [| VComplexVec (ref vals); VComplexMat vecs |])
    | _ -> assert false);
  (* lu(A)/qr(A)/cholesky(A)/svd(A) -- real Julia's factorization objects,
     here as VStruct values registered directly via declare_struct (not
     through a parsed `struct ... end`, since these are host-defined result
     types, not user code) so field names match real Julia's own
     (`.L`/`.U`/`.p`, `.Q`/`.R`, `.L`/`.U`, `.U`/`.S`/`.V`). *)
  declare_struct ~mutable_:false "LU" ~parent:"Any" ~type_params:[]
    [ "L"; "U"; "p" ] [ [ "Matrix" ]; [ "Matrix" ]; [ "Vector" ] ];
  declare_struct ~mutable_:false "QR" ~parent:"Any" ~type_params:[] [ "Q"; "R" ]
    [ [ "Matrix" ]; [ "Matrix" ] ];
  declare_struct ~mutable_:false "Cholesky" ~parent:"Any" ~type_params:[] [ "L"; "U" ]
    [ [ "Matrix" ]; [ "Matrix" ] ];
  declare_struct ~mutable_:false "SVD" ~parent:"Any" ~type_params:[] [ "U"; "S"; "V" ]
    [ [ "Matrix" ]; [ "Vector" ]; [ "Matrix" ] ];
  (* lu(A) -- square Matrix only, via faer's partial-pivoting LU (same
     decomposition `solve`/`inv` already use internally). *)
  Dispatch.defmethod "lu" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: lu needs a square Matrix"
      else (
        let l, u, p = host_lu rows n in
        construct "LU" [ VMat l; VMat u; VVec (vecbuf_of_array p) ])
    | _ -> assert false);
  (* qr(A) -- any shape, thin/economy QR (k = min(m, n)), matching real
     Julia's own default `qr` rather than the full square-Q variant. *)
  Dispatch.defmethod "qr" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      let q, r = host_qr rows m n in
      construct "QR" [ VMat q; VMat r ]
    | _ -> assert false);
  (* cholesky(A) -- SYMMETRIC POSITIVE-DEFINITE square Matrix only. Plain
     symmetry is cheap to check up front (reusing `is_symmetric` above, but
     NOT `check_symmetric`'s message -- that one is worded for eigen's
     Complex-result concern, irrelevant here). Positive-definiteness itself
     isn't cheaply checkable up front -- a non-PD (but symmetric) input
     reaches the Rust side and panics there (see kernel/src/lib.rs's own
     comment on `cholesky` for why that's a disclosed gap, same as
     eigen_symmetric's non-convergence case). *)
  Dispatch.defmethod "cholesky" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      if m <> n then failwith "DimensionMismatch: cholesky needs a square Matrix"
      else if not (is_symmetric rows) then
        failwith "cholesky needs a symmetric Matrix (real Julia requires an explicit `Symmetric` wrapper here too)"
      else (
        let l = host_cholesky rows n in
        let u = Array.init n (fun i -> Array.init n (fun j -> l.(j).(i))) in
        construct "Cholesky" [ VMat l; VMat u ])
    | _ -> assert false);
  (* svd(A) -- any shape, thin SVD (k = min(m, n)), the same faer call
     `rank` above already makes. *)
  Dispatch.defmethod "svd" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      let u, s, v = host_svd rows m n in
      construct "SVD" [ VMat u; VVec (vecbuf_of_array s); VMat v ]
    | _ -> assert false);
  (* --- Stage 3: Symmetric/Diagonal/UpperTriangular/LowerTriangular --
     ordinary structs wrapping a dense Matrix (or, for Diagonal, a Vector),
     CORRECT for `*`/`\`/`det`/`inv`/`tr` -- matching real Julia's own
     field names (`data` for the three Matrix-wrappers, `diag` for
     Diagonal). Matching real Julia's actual COMPUTATIONAL COMPLEXITY is a
     separate, harder goal (see ROADMAP.md Stage 3) -- Diagonal gets the
     real O(n)/O(n^2) treatment below since it costs nothing extra, but
     Symmetric/UpperTriangular/LowerTriangular fall back to densifying to
     a plain Matrix and redispatching through the already-existing dense
     methods (still O(n^3) under the hood, just correct). *)
  declare_struct ~mutable_:false "Symmetric" ~parent:"Any" ~type_params:[] [ "data" ] [ [ "Matrix" ] ];
  declare_struct ~mutable_:false "UpperTriangular" ~parent:"Any" ~type_params:[] [ "data" ] [ [ "Matrix" ] ];
  declare_struct ~mutable_:false "LowerTriangular" ~parent:"Any" ~type_params:[] [ "data" ] [ [ "Matrix" ] ];
  declare_struct ~mutable_:false "Diagonal" ~parent:"Any" ~type_params:[] [ "diag" ] [ [ "Vector" ] ];
  let mat_field = function
    | VStruct { fields; _ } -> (
      match !(snd fields.(0)) with
      | VMat m -> m
      | _ -> assert false)
    | _ -> assert false
  in
  let vec_field = function
    | VStruct { fields; _ } -> (
      match !(snd fields.(0)) with
      | VVec v -> vecbuf_to_array v
      | _ -> assert false)
    | _ -> assert false
  in
  (* Symmetric(A) always takes the UPPER triangle as the source of truth
     (real Julia's own default -- `Symmetric(A, :L)` for the lower-triangle
     variant isn't attempted here); mirrored eagerly into a genuinely
     symmetric dense Matrix whenever one is actually needed, rather than
     lazily at read time. *)
  let symmetric_dense rows =
    let n = Array.length rows in
    Array.init n (fun i -> Array.init n (fun j -> if j >= i then rows.(i).(j) else rows.(j).(i)))
  in
  let upper_dense rows =
    let n = Array.length rows in
    Array.init n (fun i -> Array.init n (fun j -> if j >= i then rows.(i).(j) else 0.0))
  in
  let lower_dense rows =
    let n = Array.length rows in
    Array.init n (fun i -> Array.init n (fun j -> if j <= i then rows.(i).(j) else 0.0))
  in
  let require_square rows who =
    let m = Array.length rows in
    let n = if m = 0 then 0 else Array.length rows.(0) in
    if m <> n then failwith (Printf.sprintf "DimensionMismatch: %s needs a square Matrix" who)
  in
  (* custom 1-arg constructors, purely to raise a real DimensionMismatch
     immediately (matching real Julia) rather than only failing later, the
     first time something actually operates on a non-square wrapped Matrix *)
  Dispatch.defmethod "Symmetric" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      require_square rows "Symmetric";
      construct "Symmetric" [ VMat rows ]
    | _ -> assert false);
  Dispatch.defmethod "UpperTriangular" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      require_square rows "UpperTriangular";
      construct "UpperTriangular" [ VMat rows ]
    | _ -> assert false);
  Dispatch.defmethod "LowerTriangular" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      require_square rows "LowerTriangular";
      construct "LowerTriangular" [ VMat rows ]
    | _ -> assert false);
  (* `*` -- Diagonal gets its real O(n)/O(n^2) shape directly; the other
     three densify and redispatch to the plain-Matrix `*` already above. *)
  Dispatch.defmethod "*" [ [ "Diagonal" ]; [ "Vector" ] ] (function
    | [ d; VVec v ] -> VVec (vecbuf_of_array (Array.map2 ( *. ) (vec_field d) (vecbuf_to_array v)))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Diagonal" ]; [ "Matrix" ] ] (function
    | [ d; VMat rows ] ->
      let dv = vec_field d in
      VMat (Array.mapi (fun i row -> Array.map (fun x -> x *. dv.(i)) row) rows)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Matrix" ]; [ "Diagonal" ] ] (function
    | [ VMat rows; d ] ->
      let dv = vec_field d in
      VMat (Array.map (fun row -> Array.mapi (fun j x -> x *. dv.(j)) row) rows)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Diagonal" ]; [ "Diagonal" ] ] (function
    | [ a; b ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map2 ( *. ) (vec_field a) (vec_field b))) ]
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Number" ]; [ "Diagonal" ] ] (function
    | [ s; d ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> as_float s *. x) (vec_field d))) ]
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Diagonal" ]; [ "Number" ] ] (function
    | [ d; s ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> x *. as_float s) (vec_field d))) ]
    | _ -> assert false);
  List.iter
    (fun kind ->
      let densify = if kind = "Symmetric" then symmetric_dense else if kind = "UpperTriangular" then upper_dense else lower_dense in
      Dispatch.defmethod "*" [ [ kind ]; [ "Vector" ] ] (fun args ->
          match args with
          | [ w; v ] -> Dispatch.call "*" [ VMat (densify (mat_field w)); v ]
          | _ -> assert false);
      Dispatch.defmethod "*" [ [ kind ]; [ "Matrix" ] ] (fun args ->
          match args with
          | [ w; m ] -> Dispatch.call "*" [ VMat (densify (mat_field w)); m ]
          | _ -> assert false);
      Dispatch.defmethod "\\" [ [ kind ]; [ "Vector" ] ] (fun args ->
          match args with
          | [ w; b ] -> Dispatch.call "\\" [ VMat (densify (mat_field w)); b ]
          | _ -> assert false);
      Dispatch.defmethod "inv" [ [ kind ] ] (fun args ->
          match args with
          | [ w ] -> Dispatch.call "inv" [ VMat (densify (mat_field w)) ]
          | _ -> assert false))
    [ "Symmetric"; "UpperTriangular"; "LowerTriangular" ];
  (* `\` -- Diagonal's own O(n) shape (elementwise divide); same disclosed
     gap as the plain-Matrix `\` above -- a zero diagonal entry isn't
     turned into a `SingularException`, it silently produces Inf/NaN. *)
  Dispatch.defmethod "\\" [ [ "Diagonal" ]; [ "Vector" ] ] (function
    | [ d; VVec b ] -> VVec (vecbuf_of_array (Array.map2 ( /. ) (vecbuf_to_array b) (vec_field d)))
    | _ -> assert false);
  (* `det` -- Diagonal AND the two triangular wrappers all have a real,
     cheap O(n) shortcut (product of the diagonal) that real Julia's own
     `det` uses too for these types; Symmetric has no such shortcut (a
     symmetric matrix's determinant still needs a real factorization), so
     it densifies and redispatches like the others above. *)
  Dispatch.defmethod "det" [ [ "Diagonal" ] ] (function
    | [ d ] -> VFloat (Array.fold_left ( *. ) 1.0 (vec_field d))
    | _ -> assert false);
  let triangular_det kind =
    Dispatch.defmethod "det" [ [ kind ] ] (function
      | [ w ] ->
        let rows = mat_field w in
        VFloat (Array.fold_left ( *. ) 1.0 (Array.init (Array.length rows) (fun i -> rows.(i).(i))))
      | _ -> assert false)
  in
  triangular_det "UpperTriangular";
  triangular_det "LowerTriangular";
  Dispatch.defmethod "det" [ [ "Symmetric" ] ] (function
    | [ w ] -> Dispatch.call "det" [ VMat (symmetric_dense (mat_field w)) ]
    | _ -> assert false);
  (* `inv` -- Diagonal's own O(n) shape (elementwise reciprocal); same
     disclosed not-a-`SingularException` gap as `\` above. *)
  Dispatch.defmethod "inv" [ [ "Diagonal" ] ] (function
    | [ d ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> 1.0 /. x) (vec_field d))) ]
    | _ -> assert false);
  (* `tr` -- all four read straight off the stored diagonal (Symmetric's
     diagonal is shared between the upper/lower triangles it never
     actually mirrors, so this needs no densifying at all). *)
  Dispatch.defmethod "tr" [ [ "Diagonal" ] ] (function
    | [ d ] -> VFloat (Array.fold_left ( +. ) 0.0 (vec_field d))
    | _ -> assert false);
  List.iter
    (fun kind ->
      Dispatch.defmethod "tr" [ [ kind ] ] (function
        | [ w ] ->
          let rows = mat_field w in
          VFloat (Array.fold_left ( +. ) 0.0 (Array.init (Array.length rows) (fun i -> rows.(i).(i))))
        | _ -> assert false))
    [ "Symmetric"; "UpperTriangular"; "LowerTriangular" ];
  (* eigvals(F)/eigvecs(F)/eigen(F)/cholesky(F) for F::Symmetric -- the
     real-Julia-idiomatic way to ask for these (dispatching on TYPE, not
     the runtime `is_symmetric` value-check the plain-Matrix methods above
     still need for a bare Matrix argument). Densifying first guarantees
     genuine symmetry no matter what `data`'s untouched lower triangle
     happened to hold, so redispatching to the already-checked
     plain-Matrix method always succeeds. *)
  List.iter
    (fun name ->
      Dispatch.defmethod name [ [ "Symmetric" ] ] (function
        | [ w ] -> Dispatch.call name [ VMat (symmetric_dense (mat_field w)) ]
        | _ -> assert false))
    [ "eigvals"; "eigvecs"; "eigen"; "cholesky" ];
  (* --- Tridiagonal(dl, d, du) -- the one Stage 3 wrapper NOT built on a
     single dense-Matrix/Vector field: three separate Vectors (real
     Julia's own field names), `dl`/`du` one shorter than `d`. Unlike
     Symmetric/UpperTriangular/LowerTriangular above, `*`/`\`/`det`/`tr`
     all get their REAL O(n) shape here (not a densify-and-redispatch
     fallback) -- the whole point of a Tridiagonal type in real Julia is
     that these algorithms (banded matvec, the Thomas algorithm, the
     3-term determinant recurrence) are genuinely simple at this
     bandwidth, not merely possible. Only `inv` still densifies: a
     tridiagonal matrix's inverse is generally DENSE (no shortcut shape to
     return it in), so there's nothing cheaper to do than the plain-Matrix
     path. *)
  declare_struct ~mutable_:false "Tridiagonal" ~parent:"Any" ~type_params:[] [ "dl"; "d"; "du" ]
    [ [ "Vector" ]; [ "Vector" ]; [ "Vector" ] ];
  let tridiag_fields = function
    | VStruct { fields; _ } ->
      let get i = match !(snd fields.(i)) with VVec v -> vecbuf_to_array v | _ -> assert false in
      get 0, get 1, get 2
    | _ -> assert false
  in
  let tridiag_dense dl d du =
    let n = Array.length d in
    Array.init n (fun i ->
        Array.init n (fun j ->
            if i = j then d.(i)
            else if j = i - 1 then dl.(j)
            else if j = i + 1 then du.(i)
            else 0.0))
  in
  (* real Julia raises DimensionMismatch immediately for mismatched
     lengths, same as the square-check the other three wrappers do at
     construction *)
  Dispatch.defmethod "Tridiagonal" [ [ "Vector" ]; [ "Vector" ]; [ "Vector" ] ] (function
    | [ VVec dl; VVec d; VVec du ] ->
      let n = vecbuf_length d in
      if vecbuf_length dl <> n - 1 || vecbuf_length du <> n - 1 then
        failwith
          (Printf.sprintf
             "DimensionMismatch: Tridiagonal needs dl/du one shorter than d (got %d/%d/%d)"
             (vecbuf_length dl) n (vecbuf_length du))
      else construct "Tridiagonal" [ VVec dl; VVec d; VVec du ]
    | _ -> assert false);
  (* A * v -- each row touches at most 3 entries, real O(n). *)
  Dispatch.defmethod "*" [ [ "Tridiagonal" ]; [ "Vector" ] ] (function
    | [ t; VVec v ] ->
      let dl, d, du = tridiag_fields t in
      let v = vecbuf_to_array v in
      let n = Array.length d in
      VVec
        (vecbuf_of_array
           (Array.init n (fun i ->
                let diag_term = d.(i) *. v.(i) in
                let lower_term = if i > 0 then dl.(i - 1) *. v.(i - 1) else 0.0 in
                let upper_term = if i < n - 1 then du.(i) *. v.(i + 1) else 0.0 in
                diag_term +. lower_term +. upper_term)))
    | _ -> assert false);
  (* A * B (Matrix) -- no banded shortcut worth the code for a right-hand
     side that's already dense; densify and redispatch, same as
     Symmetric/UpperTriangular/LowerTriangular's own Matrix case. *)
  Dispatch.defmethod "*" [ [ "Tridiagonal" ]; [ "Matrix" ] ] (function
    | [ t; m ] ->
      let dl, d, du = tridiag_fields t in
      Dispatch.call "*" [ VMat (tridiag_dense dl d du); m ]
    | _ -> assert false);
  (* A \ b -- the Thomas algorithm: one forward elimination sweep, one back-
     substitution sweep, O(n) total instead of a full O(n^3) dense solve.
     Naive Thomas (unlike real LAPACK's `dgtsv`, which partial-pivots)
     has NO pivoting at all, so a zero pivot can turn up mid-sweep even
     for a perfectly well-conditioned, nonsingular A -- verified this
     actually happens, not just a theoretical worry (a hand-picked 4x4
     tridiagonal test case hit `m = 0.0` on the third row and produced
     NaN throughout before this fallback was added). Rather than ship
     that silent NaN, a zero pivot bails out to the dense `\` above
     (still correct, just not the O(n) fast path) -- a genuinely singular
     A still isn't detected as such, same disclosed gap as every other
     `\`/`inv` in this file, just via the dense path's own LU instead of
     Thomas's arithmetic blowing up directly. *)
  Dispatch.defmethod "\\" [ [ "Tridiagonal" ]; [ "Vector" ] ] (function
    | [ t; VVec b ] ->
      let dl, d, du = tridiag_fields t in
      let b = vecbuf_to_array b in
      let n = Array.length d in
      let dense_fallback () = Dispatch.call "\\" [ VMat (tridiag_dense dl d du); VVec (vecbuf_of_array b) ] in
      if n = 0 then VVec (vecbuf_of_array [||])
      else if n = 1 then VVec (vecbuf_of_array [| b.(0) /. d.(0) |])
      else if d.(0) = 0.0 then dense_fallback ()
      else (
        let cp = Array.make n 0.0 and dp = Array.make n 0.0 in
        cp.(0) <- du.(0) /. d.(0);
        dp.(0) <- b.(0) /. d.(0);
        let singular = ref false in
        let i = ref 1 in
        while (not !singular) && !i <= n - 2 do
          let m = d.(!i) -. (dl.(!i - 1) *. cp.(!i - 1)) in
          if m = 0.0 then singular := true
          else (
            cp.(!i) <- du.(!i) /. m;
            dp.(!i) <- (b.(!i) -. (dl.(!i - 1) *. dp.(!i - 1))) /. m);
          incr i
        done;
        if !singular then dense_fallback ()
        else (
          let m = d.(n - 1) -. (dl.(n - 2) *. cp.(n - 2)) in
          if m = 0.0 then dense_fallback ()
          else (
            dp.(n - 1) <- (b.(n - 1) -. (dl.(n - 2) *. dp.(n - 2))) /. m;
            let x = Array.make n 0.0 in
            x.(n - 1) <- dp.(n - 1);
            for i = n - 2 downto 0 do
              x.(i) <- dp.(i) -. (cp.(i) *. x.(i + 1))
            done;
            VVec (vecbuf_of_array x))))
    | _ -> assert false);
  (* det(A) -- the standard 3-term recurrence for a tridiagonal
     determinant (D_0 = 1, D_1 = d_1, D_k = d_k*D_{k-1} - dl_{k-1}*du_{k-1}*D_{k-2}),
     real O(n) instead of a full O(n^3) LU-based det. *)
  Dispatch.defmethod "det" [ [ "Tridiagonal" ] ] (function
    | [ t ] ->
      let dl, d, du = tridiag_fields t in
      let n = Array.length d in
      if n = 0 then VFloat 1.0
      else (
        let g0 = ref 1.0 and g1 = ref d.(0) in
        for k = 2 to n do
          let gk = (d.(k - 1) *. !g1) -. (dl.(k - 2) *. du.(k - 2) *. !g0) in
          g0 := !g1;
          g1 := gk
        done;
        VFloat !g1)
    | _ -> assert false);
  (* inv(A) -- a tridiagonal matrix's inverse is generally dense (no
     compact shape to return it in), so there's no shortcut here: densify
     and redispatch, same as Symmetric's own `inv` above. *)
  Dispatch.defmethod "inv" [ [ "Tridiagonal" ] ] (function
    | [ t ] ->
      let dl, d, du = tridiag_fields t in
      Dispatch.call "inv" [ VMat (tridiag_dense dl d du) ]
    | _ -> assert false);
  (* tr(A) -- sum of `d`, real O(n). *)
  Dispatch.defmethod "tr" [ [ "Tridiagonal" ] ] (function
    | [ t ] ->
      let _, d, _ = tridiag_fields t in
      VFloat (Array.fold_left ( +. ) 0.0 d)
    | _ -> assert false);
  (* --- the "long tail" of smaller LinearAlgebra functions (ROADMAP.md
     Stage 4's own list): issymmetric/ishermitian, isposdef, logdet, cond,
     pinv, nullspace, kron. Each is either a cheap OCaml-only check/reuse
     of an existing method (`logdet` redispatches to `det`, `cond`/`pinv`/
     `nullspace` all redispatch to `svd`) or, for `isposdef`, one small new
     Rust FFI export (`is_posdef` -- the same Cholesky attempt `cholesky`
     above makes, just reporting success/failure instead of panicking). *)
  let is_square_symmetric rows =
    let m = Array.length rows in
    let n = if m = 0 then 0 else Array.length rows.(0) in
    m = n && is_symmetric rows
  in
  (* issymmetric(A)/ishermitian(A) -- identical for Tsubaki's real-only
     Matrix (Hermitian collapses to symmetric with no imaginary part to
     conjugate away); a non-square Matrix is simply not symmetric, same as
     real Julia, rather than an error. *)
  List.iter
    (fun name ->
      Dispatch.defmethod name [ [ "Matrix" ] ] (function
        | [ VMat rows ] -> VBool (is_square_symmetric rows)
        | _ -> assert false);
      (* a Symmetric wrapper is trivially symmetric/Hermitian by
         construction -- no need to even look at its `data` *)
      Dispatch.defmethod name [ [ "Symmetric" ] ] (function
        | [ _ ] -> VBool true
        | _ -> assert false))
    [ "issymmetric"; "ishermitian" ];
  (* isposdef(A) -- real Julia's own definition requires symmetry first
     (`issymmetric(A) && isposdef(cholesky(A; check=false))`); a
     Symmetric wrapper skips straight to the Cholesky attempt, same as
     `eigvals`/`cholesky` on Symmetric above. *)
  Dispatch.defmethod "isposdef" [ [ "Matrix" ] ] (function
    | [ VMat rows ] -> VBool (is_square_symmetric rows && host_is_posdef rows (Array.length rows))
    | _ -> assert false);
  Dispatch.defmethod "isposdef" [ [ "Symmetric" ] ] (function
    | [ w ] ->
      let rows = symmetric_dense (mat_field w) in
      VBool (host_is_posdef rows (Array.length rows))
    | _ -> assert false);
  (* logdet(A) -- avoids the overflow a naive `log(det(A))` risks (an
     enormous `A` can overflow `det` to `Inf` before `log` ever runs) by
     summing logs of individual factors instead of multiplying them all
     together first, the same idea real Julia's own factorization-based
     `logdet` uses. Real Julia also raises for a negative determinant
     (the honest result would be Complex, which `logdet` promises never
     to return) -- matched here as a plain `failwith` rather than
     actually producing a Complex. *)
  let raise_negative_logdet () =
    failwith "DomainError: logdet requires a nonnegative determinant (real Julia would return a Complex here)"
  in
  (* the parity of a 0-based permutation array (+1 even / -1 odd number of
     transpositions) -- via cycle decomposition, a cycle of length L
     contributes (L-1) transpositions. Needed to recover det's SIGN from
     an LU factorization's `P` (det(A) = sign(P) * prod(U_ii): `P*A = L*U`,
     det(L) = 1 since L is unit lower-triangular, and det(P) = sign(P) is
     its own inverse since P is a permutation matrix). *)
  let permutation_sign p =
    let n = Array.length p in
    let visited = Array.make n false in
    let sign = ref 1 in
    for i = 0 to n - 1 do
      if not visited.(i) then (
        let cycle_len = ref 0 in
        let j = ref i in
        while not visited.(!j) do
          visited.(!j) <- true;
          j := p.(!j);
          incr cycle_len
        done;
        if (!cycle_len - 1) mod 2 = 1 then sign := - !sign)
    done;
    !sign
  in
  (* Matrix -- redispatches to the existing `lu`, then sums log|U_ii| with
     sign tracking (permutation parity * sign of each U_ii), instead of
     computing the full product (= det) first. *)
  Dispatch.defmethod "logdet" [ [ "Matrix" ] ] (function
    | [ v ] -> (
      match Dispatch.call "lu" [ v ] with
      | VStruct { fields; _ } -> (
        match !(snd fields.(1)), !(snd fields.(2)) with
        | VMat u, VVec p ->
          let n = Array.length u in
          let p0 = Array.map (fun x -> int_of_float x - 1) (vecbuf_to_array p) in
          let sign = ref (permutation_sign p0) in
          let logsum = ref 0.0 in
          for i = 0 to n - 1 do
            let uii = u.(i).(i) in
            if uii < 0.0 then sign := - !sign;
            logsum := !logsum +. log (Float.abs uii)
          done;
          if !sign < 0 then raise_negative_logdet () else VFloat !logsum
        | _ -> assert false)
      | _ -> assert false)
    | _ -> assert false);
  (* Diagonal / UpperTriangular / LowerTriangular -- the determinant is
     already a plain product of diagonal entries (see `det` above for
     each), so the overflow-avoiding form is even simpler here: sum
     log|entry| directly, no factorization needed at all. *)
  Dispatch.defmethod "logdet" [ [ "Diagonal" ] ] (function
    | [ d ] ->
      let diag = vec_field d in
      let sign = ref 1 and logsum = ref 0.0 in
      Array.iter
        (fun x ->
          if x < 0.0 then sign := - !sign;
          logsum := !logsum +. log (Float.abs x))
        diag;
      if !sign < 0 then raise_negative_logdet () else VFloat !logsum
    | _ -> assert false);
  List.iter
    (fun kind ->
      Dispatch.defmethod "logdet" [ [ kind ] ] (function
        | [ w ] ->
          let rows = mat_field w in
          let sign = ref 1 and logsum = ref 0.0 in
          for i = 0 to Array.length rows - 1 do
            let x = rows.(i).(i) in
            if x < 0.0 then sign := - !sign;
            logsum := !logsum +. log (Float.abs x)
          done;
          if !sign < 0 then raise_negative_logdet () else VFloat !logsum
        | _ -> assert false))
    [ "UpperTriangular"; "LowerTriangular" ];
  (* Symmetric -- no shortcut of its own (same as `det`/`inv` above):
     densify and redispatch to the now-overflow-avoiding Matrix method. *)
  Dispatch.defmethod "logdet" [ [ "Symmetric" ] ] (function
    | [ w ] -> Dispatch.call "logdet" [ VMat (symmetric_dense (mat_field w)) ]
    | _ -> assert false);
  (* Tridiagonal -- **disclosed gap, narrower than before**: still
     `log(det(A))` via the existing 3-term recurrence, which itself can
     overflow for a large enough `A` before `log` ever runs. A genuinely
     overflow-safe version would need to carry the recurrence's running
     sign and log-magnitude through its OWN subtraction step (`D_k = d_k *
     D_{k-1} - dl_{k-1} * du_{k-1} * D_{k-2}`), which -- unlike the
     product-only Matrix/Diagonal/triangular cases above -- can't be done
     by just summing logs; it needs real log-domain arithmetic through a
     subtraction, a harder numerical-analysis problem than this "long
     tail" round attempts. Falls through to the generic fallback below. *)
  Dispatch.defmethod "logdet" [ [ "Any" ] ] (function
    | [ v ] ->
      let d = as_float (Dispatch.call "det" [ v ]) in
      if d < 0.0 then raise_negative_logdet () else VFloat (log d)
    | _ -> assert false);
  (* cond(A) -- the 2-norm condition number (largest singular value /
     smallest), real Julia's own default `cond(A, 2)`; redispatches to
     the existing `svd`, whose `S` already comes back sorted
     nonincreasing (see kernel/src/lib.rs's own comment on `svd`). *)
  Dispatch.defmethod "cond" [ [ "Matrix" ] ] (function
    | [ VMat rows ] -> (
      match Dispatch.call "svd" [ VMat rows ] with
      | VStruct { fields; _ } -> (
        match !(snd fields.(1)) with
        | VVec s ->
          let s = vecbuf_to_array s in
          let k = Array.length s in
          if k = 0 then VFloat 0.0 else VFloat (s.(0) /. s.(k - 1))
        | _ -> assert false)
      | _ -> assert false)
    | _ -> assert false);
  (* pinv(A) -- the Moore-Penrose pseudoinverse via the existing thin SVD:
     pinv(A) = V * Sigma+ * U', Sigma+ zeroing out any singular value at
     or below the same rank-tolerance `rank`/`nullspace` already use.
     Correct for any shape (unlike `nullspace` below, this needs nothing
     beyond what the thin SVD already provides -- pinv never needs the
     "extra" null directions a wide matrix's FULL SVD would add). *)
  Dispatch.defmethod "pinv" [ [ "Matrix" ] ] (function
    | [ VMat rows ] -> (
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      match Dispatch.call "svd" [ VMat rows ] with
      | VStruct { fields; _ } -> (
        match !(snd fields.(0)), !(snd fields.(1)), !(snd fields.(2)) with
        | VMat u, VVec s, VMat v ->
          let s = vecbuf_to_array s in
          let k = Array.length s in
          let smax = Array.fold_left Float.max 0.0 s in
          let tol = smax *. float_of_int (max m n) *. epsilon_float in
          VMat
            (Array.init n (fun i ->
                 Array.init m (fun j ->
                     let acc = ref 0.0 in
                     for r = 0 to k - 1 do
                       if s.(r) > tol then acc := !acc +. (v.(i).(r) *. u.(j).(r) /. s.(r))
                     done;
                     !acc)))
        | _ -> assert false)
      | _ -> assert false)
    | _ -> assert false);
  (* cond/pinv on the Stage 3 wrapper types -- Diagonal gets its own real
     O(n) shortcut (same spirit as `det`/`inv`/`tr` on Diagonal above);
     the other four densify and redispatch to the plain-Matrix methods
     just above. *)
  Dispatch.defmethod "cond" [ [ "Diagonal" ] ] (function
    | [ d ] ->
      let diag = Array.map Float.abs (vec_field d) in
      let dmax = Array.fold_left Float.max 0.0 diag in
      let dmin = Array.fold_left Float.min Float.infinity diag in
      VFloat (dmax /. dmin)
    | _ -> assert false);
  Dispatch.defmethod "pinv" [ [ "Diagonal" ] ] (function
    | [ d ] ->
      let diag = vec_field d in
      let dmax = Array.fold_left (fun acc x -> Float.max acc (Float.abs x)) 0.0 diag in
      let tol = dmax *. float_of_int (Array.length diag) *. epsilon_float in
      construct "Diagonal"
        [ VVec (vecbuf_of_array (Array.map (fun x -> if Float.abs x > tol then 1.0 /. x else 0.0) diag)) ]
    | _ -> assert false);
  List.iter
    (fun kind ->
      let densify = if kind = "Symmetric" then symmetric_dense else if kind = "UpperTriangular" then upper_dense else lower_dense in
      Dispatch.defmethod "cond" [ [ kind ] ] (fun args ->
          match args with
          | [ w ] -> Dispatch.call "cond" [ VMat (densify (mat_field w)) ]
          | _ -> assert false);
      Dispatch.defmethod "pinv" [ [ kind ] ] (fun args ->
          match args with
          | [ w ] -> Dispatch.call "pinv" [ VMat (densify (mat_field w)) ]
          | _ -> assert false))
    [ "Symmetric"; "UpperTriangular"; "LowerTriangular" ];
  Dispatch.defmethod "cond" [ [ "Tridiagonal" ] ] (function
    | [ t ] ->
      let dl, d, du = tridiag_fields t in
      Dispatch.call "cond" [ VMat (tridiag_dense dl d du) ]
    | _ -> assert false);
  Dispatch.defmethod "pinv" [ [ "Tridiagonal" ] ] (function
    | [ t ] ->
      let dl, d, du = tridiag_fields t in
      Dispatch.call "pinv" [ VMat (tridiag_dense dl d du) ]
    | _ -> assert false);
  (* nullspace(A) -- an orthonormal basis for A's null space. Uses the
     FULL svd's V (host_svd_full_v, n x n -- unlike the thin `svd` builtin
     above, whose V only has min(m,n) columns), the same way real Julia's
     own `nullspace` internally calls `svd(A; full=true)` rather than its
     own thin default: a column index beyond `k = min(m,n)` has no
     corresponding singular value AT ALL (not even a zero one) and is
     therefore automatically in the null space -- exactly the `(n - m)`
     "extra" directions a wide `A` (m < n) has, which a thin V structurally
     has no room to hold. This used to raise for `m < n` before
     `svd_full_v` existed; now handles every shape uniformly. *)
  Dispatch.defmethod "nullspace" [ [ "Matrix" ] ] (function
    | [ VMat rows ] ->
      let m = Array.length rows in
      let n = if m = 0 then 0 else Array.length rows.(0) in
      let v, s = host_svd_full_v rows m n in
      let k = Array.length s in
      let smax = Array.fold_left Float.max 0.0 s in
      let tol = smax *. float_of_int (max m n) *. epsilon_float in
      let null_idx = List.filter (fun r -> r >= k || s.(r) <= tol) (List.init n (fun i -> i)) in
      let ncols = List.length null_idx in
      let null_idx = Array.of_list null_idx in
      VMat (Array.init n (fun i -> Array.init ncols (fun c -> v.(i).(null_idx.(c)))))
    | _ -> assert false);
  (* kron(A, B) -- the Kronecker product, pure combinatorics (no FFI
     needed): each (i,j) block of the result is A[ia,ja] * B, so reading
     it back out is just index arithmetic. Vector,Vector is the same idea
     one dimension down. *)
  Dispatch.defmethod "kron" [ [ "Matrix" ]; [ "Matrix" ] ] (function
    | [ VMat a; VMat b ] ->
      let ma = Array.length a and na = if Array.length a = 0 then 0 else Array.length a.(0) in
      let mb = Array.length b and nb = if Array.length b = 0 then 0 else Array.length b.(0) in
      VMat
        (Array.init (ma * mb) (fun i ->
             let ia = i / mb and ib = i mod mb in
             Array.init (na * nb) (fun j ->
                 let ja = j / nb and jb = j mod nb in
                 a.(ia).(ja) *. b.(ib).(jb))))
    | _ -> assert false);
  Dispatch.defmethod "kron" [ [ "Vector" ]; [ "Vector" ] ] (function
    | [ VVec a; VVec b ] ->
      let a = vecbuf_to_array a and b = vecbuf_to_array b in
      let na = Array.length a and nb = Array.length b in
      VVec (vecbuf_of_array (Array.init (na * nb) (fun i -> a.(i / nb) *. b.(i mod nb))))
    | _ -> assert false);
  (* --- SparseMatrixCSC (ROADMAP.md Stage 4's sparse-matrix design sketch)
     -- a plain COO/triplet list (see VSparseMat's own comment for why),
     rebuilt into a real faer `SparseColMat` fresh on every operation, the
     same "no cached factorization state across FFI calls" convention
     every dense decomposition in this file already follows. *)
  (* sparse(I, J, V, m, n) -- real Julia's own COO constructor: I/J are
     1-based row/col Vectors, V the matching values, converted to 0-based
     here before ever crossing into OCaml's own VSparseMat, let alone
     Rust. *)
  Dispatch.defmethod "sparse" [ [ "Vector" ]; [ "Vector" ]; [ "Vector" ]; [ "Int" ]; [ "Int" ] ] (function
    | [ VVec i; VVec j; VVec v; VInt m; VInt n ] ->
      let rows = Array.map (fun x -> int_of_float x - 1) (vecbuf_to_array i) in
      let cols = Array.map (fun x -> int_of_float x - 1) (vecbuf_to_array j) in
      VSparseMat { m; n; rows; cols; vals = Array.copy (vecbuf_to_array v) }
    | _ -> assert false);
  (* spzeros(m, n) -- an empty sparse Matrix, zero stored entries. *)
  Dispatch.defmethod "spzeros" [ [ "Int" ]; [ "Int" ] ] (function
    | [ VInt m; VInt n ] -> VSparseMat { m; n; rows = [||]; cols = [||]; vals = [||] }
    | _ -> assert false);
  (* sparse(A) -- densify's inverse: extract A's nonzero entries into a
     SparseMatrixCSC. Exactly zero entries are dropped, matching real
     Julia's own `sparse(::Matrix)` (an entry that's merely small, not
     exactly 0.0, is still kept -- no tolerance-based thresholding here,
     same as real Julia). *)
  Dispatch.defmethod "sparse" [ [ "Matrix" ] ] (function
    | [ VMat rows_m ] ->
      let m = Array.length rows_m in
      let n = if m = 0 then 0 else Array.length rows_m.(0) in
      let rows = ref [] and cols = ref [] and vals = ref [] in
      for i = 0 to m - 1 do
        for j = 0 to n - 1 do
          if rows_m.(i).(j) <> 0.0 then (
            rows := i :: !rows;
            cols := j :: !cols;
            vals := rows_m.(i).(j) :: !vals)
        done
      done;
      VSparseMat
        { m; n; rows = Array.of_list !rows; cols = Array.of_list !cols; vals = Array.of_list !vals }
    | _ -> assert false);
  (* Matrix(A) -- densify a SparseMatrixCSC back to a plain dense Matrix. *)
  Dispatch.defmethod "Matrix" [ [ "SparseMatrixCSC" ] ] (function
    | [ VSparseMat { m; n; rows; cols; vals } ] ->
      let dense = Array.make_matrix m n 0.0 in
      Array.iteri (fun k r -> dense.(r).(cols.(k)) <- vals.(k)) rows;
      VMat dense
    | _ -> assert false);
  Dispatch.defmethod "nnz" [ [ "SparseMatrixCSC" ] ] (function
    | [ VSparseMat { rows; _ } ] -> VInt (Array.length rows)
    | _ -> assert false);
  Dispatch.defmethod "size" [ [ "SparseMatrixCSC" ] ] (function
    | [ VSparseMat { m; n; _ } ] -> VTuple [| VInt m; VInt n |]
    | _ -> assert false);
  (* A * v -- faer's own sparse matmul (`sparse_matvec` in
     kernel/src/lib.rs), any shape (m x n times an n-vector). *)
  Dispatch.defmethod "*" [ [ "SparseMatrixCSC" ]; [ "Vector" ] ] (function
    | [ VSparseMat { m; n; rows; cols; vals }; VVec x ] ->
      let x = vecbuf_to_array x in
      if n <> Array.length x then
        failwith (Printf.sprintf "DimensionMismatch: A is %dx%d, x has %d elements" m n (Array.length x))
      else VVec (vecbuf_of_array (host_sparse_matvec rows cols vals m n x))
    | _ -> assert false);
  (* A \ b -- faer's own sparse LU (`sp_lu`, exploiting the sparsity
     pattern, not a dense fallback), square A only, same disclosed
     singularity gap as every other `\` in this file. *)
  Dispatch.defmethod "\\" [ [ "SparseMatrixCSC" ]; [ "Vector" ] ] (function
    | [ VSparseMat { m; n; rows; cols; vals }; VVec b ] ->
      let b = vecbuf_to_array b in
      if m <> n then failwith "DimensionMismatch: A \\ b only supports a square sparse A"
      else if n <> Array.length b then
        failwith (Printf.sprintf "DimensionMismatch: A is %dx%d, b has %d elements" m n (Array.length b))
      else VVec (vecbuf_of_array (host_sparse_solve rows cols vals n b))
    | _ -> assert false);
  (* LinearAlgebra.I (UniformScaling) -- lazy, only becomes concrete when
     combined with a real Matrix/Vector/scalar. `c*I`/`I*c` stays a scaled
     UniformScaling (so `2I`, `A - 3I` work); `A ± I` needs A square
     (real Julia's own constraint -- adding a scaled identity to a
     non-square Matrix is a DimensionMismatch there too). *)
  let add_scaled_identity rows c sign =
    let m = Array.length rows in
    let n = if m = 0 then 0 else Array.length rows.(0) in
    if m <> n then failwith "DimensionMismatch: A ± I needs a square Matrix"
    else Array.mapi (fun i row -> Array.mapi (fun j x -> if i = j then x +. (sign *. c) else x) row) rows
  in
  Dispatch.defmethod "+" [ [ "Matrix" ]; [ "UniformScaling" ] ] (function
    | [ VMat rows; VUniformScaling c ] -> VMat (add_scaled_identity rows c 1.0)
    | _ -> assert false);
  Dispatch.defmethod "+" [ [ "UniformScaling" ]; [ "Matrix" ] ] (function
    | [ VUniformScaling c; VMat rows ] -> VMat (add_scaled_identity rows c 1.0)
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "Matrix" ]; [ "UniformScaling" ] ] (function
    | [ VMat rows; VUniformScaling c ] -> VMat (add_scaled_identity rows c (-1.0))
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "UniformScaling" ]; [ "Matrix" ] ] (function
    (* I - A = -(A - I) *)
    | [ VUniformScaling c; VMat rows ] -> VMat (Array.map (Array.map ( ~-. )) (add_scaled_identity rows c (-1.0)))
    | _ -> assert false);
  (* `-I` itself never reaches a genuine 1-arg call: unary minus desugars
     to `0 - e` (see parse_unary), so what actually needs a method here is
     Int - UniformScaling, not a standalone negation *)
  Dispatch.defmethod "-" [ [ "Int" ]; [ "UniformScaling" ] ] (function
    | [ VInt 0; VUniformScaling c ] -> VUniformScaling (-.c)
    | [ VInt _; VUniformScaling _ ] -> failwith "Int - UniformScaling is only supported for 0 - I (unary negation)"
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Number" ]; [ "UniformScaling" ] ] (function
    | [ s; VUniformScaling c ] -> VUniformScaling (as_float s *. c)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "UniformScaling" ]; [ "Number" ] ] (function
    | [ VUniformScaling c; s ] -> VUniformScaling (c *. as_float s)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Matrix" ]; [ "UniformScaling" ] ] (function
    | [ VMat rows; VUniformScaling c ] -> VMat (Array.map (Array.map (fun x -> x *. c)) rows)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "UniformScaling" ]; [ "Matrix" ] ] (function
    | [ VUniformScaling c; VMat rows ] -> VMat (Array.map (Array.map (fun x -> x *. c)) rows)
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "UniformScaling" ]; [ "Vector" ] ] (function
    | [ VUniformScaling c; VVec v ] -> VVec (vecbuf_of_array (Array.map (fun x -> x *. c) (vecbuf_to_array v)))
    | _ -> assert false);
  Dispatch.defmethod "*" [ [ "Vector" ]; [ "UniformScaling" ] ] (function
    | [ VVec v; VUniformScaling c ] -> VVec (vecbuf_of_array (Array.map (fun x -> x *. c) (vecbuf_to_array v)))
    | _ -> assert false);
  (* `± I` on the five Stage 3 wrapper types -- ROADMAP.md originally
     flagged UniformScaling as needing "its own dedicated design" for
     anything beyond plain Matrix/Vector/Number, but adding a scaled
     identity only ever touches the DIAGONAL, and every one of these
     wrapper types can absorb that without densifying at all: real
     Julia's own `Diagonal(v) + I`, `Symmetric(A) + I`, `UpperTriangular
     (A) + I`, `LowerTriangular(A) + I`, and `Tridiagonal(dl,d,du) + I`
     all stay the SAME wrapper kind (only `d`/`diag`/the stored triangle's
     diagonal changes), cheaper than Matrix's own densify-then-add. No
     square check needed here (unlike Matrix's own `±I`): Symmetric/
     UpperTriangular/LowerTriangular are already guaranteed square at
     construction, and Diagonal/Tridiagonal are square by construction. *)
  Dispatch.defmethod "+" [ [ "Diagonal" ]; [ "UniformScaling" ] ] (function
    | [ d; VUniformScaling c ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> x +. c) (vec_field d))) ]
    | _ -> assert false);
  Dispatch.defmethod "+" [ [ "UniformScaling" ]; [ "Diagonal" ] ] (function
    | [ VUniformScaling c; d ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> x +. c) (vec_field d))) ]
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "Diagonal" ]; [ "UniformScaling" ] ] (function
    | [ d; VUniformScaling c ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> x -. c) (vec_field d))) ]
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "UniformScaling" ]; [ "Diagonal" ] ] (function
    | [ VUniformScaling c; d ] -> construct "Diagonal" [ VVec (vecbuf_of_array (Array.map (fun x -> c -. x) (vec_field d))) ]
    | _ -> assert false);
  List.iter
    (fun kind ->
      let add_diag sign rows c =
        Array.mapi (fun i row -> Array.mapi (fun j x -> if i = j then x +. (sign *. c) else x) row) rows
      in
      Dispatch.defmethod "+" [ [ kind ]; [ "UniformScaling" ] ] (function
        | [ w; VUniformScaling c ] -> construct kind [ VMat (add_diag 1.0 (mat_field w) c) ]
        | _ -> assert false);
      Dispatch.defmethod "+" [ [ "UniformScaling" ]; [ kind ] ] (function
        | [ VUniformScaling c; w ] -> construct kind [ VMat (add_diag 1.0 (mat_field w) c) ]
        | _ -> assert false);
      Dispatch.defmethod "-" [ [ kind ]; [ "UniformScaling" ] ] (function
        | [ w; VUniformScaling c ] -> construct kind [ VMat (add_diag (-1.0) (mat_field w) c) ]
        | _ -> assert false);
      Dispatch.defmethod "-" [ [ "UniformScaling" ]; [ kind ] ] (function
        | [ VUniformScaling c; w ] ->
          let rows = mat_field w in
          let negated = Array.map (Array.map ( ~-. )) rows in
          construct kind [ VMat (add_diag 1.0 negated c) ]
        | _ -> assert false))
    [ "Symmetric"; "UpperTriangular"; "LowerTriangular" ];
  Dispatch.defmethod "+" [ [ "Tridiagonal" ]; [ "UniformScaling" ] ] (function
    | [ t; VUniformScaling c ] ->
      let dl, d, du = tridiag_fields t in
      construct "Tridiagonal" [ VVec (vecbuf_of_array dl); VVec (vecbuf_of_array (Array.map (fun x -> x +. c) d)); VVec (vecbuf_of_array du) ]
    | _ -> assert false);
  Dispatch.defmethod "+" [ [ "UniformScaling" ]; [ "Tridiagonal" ] ] (function
    | [ VUniformScaling c; t ] ->
      let dl, d, du = tridiag_fields t in
      construct "Tridiagonal" [ VVec (vecbuf_of_array dl); VVec (vecbuf_of_array (Array.map (fun x -> x +. c) d)); VVec (vecbuf_of_array du) ]
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "Tridiagonal" ]; [ "UniformScaling" ] ] (function
    | [ t; VUniformScaling c ] ->
      let dl, d, du = tridiag_fields t in
      construct "Tridiagonal" [ VVec (vecbuf_of_array dl); VVec (vecbuf_of_array (Array.map (fun x -> x -. c) d)); VVec (vecbuf_of_array du) ]
    | _ -> assert false);
  Dispatch.defmethod "-" [ [ "UniformScaling" ]; [ "Tridiagonal" ] ] (function
    | [ VUniformScaling c; t ] ->
      let dl, d, du = tridiag_fields t in
      construct "Tridiagonal"
        [ VVec (vecbuf_of_array (Array.map ( ~-. ) dl)); VVec (vecbuf_of_array (Array.map (fun x -> c -. x) d)); VVec (vecbuf_of_array (Array.map ( ~-. ) du)) ]
    | _ -> assert false);
  (* needed to run mandelperf's own real-benchmark body verbatim:
     `sum(mandelperf())`, where mandelperf() is a 2D comprehension (a Matrix) *)
  Dispatch.defmethod "sum" [ [ "Matrix" ] ] (function
    | [ VMat rows ] -> VFloat (Array.fold_left (fun acc row -> acc +. Array.fold_left ( +. ) 0.0 row) 0.0 rows)
    | _ -> assert false);
  ()

(* CurveBridge.init と同じ理由でここに居ます -- この module を確かにリンク
   させるため。中で何かをするわけではなく、呼ばれること自体が用事です
   (module の top level は、誰かが参照しないと走らない)。 *)
let init () = ()
