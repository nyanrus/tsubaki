(* ============================= Runtime ============================= *)
  type value =
    | VInt of int
    | VFloat of float
    | VBool of bool
    | VStr of string
    | VNothing
    | VFixedInt of { bits : int; signed : bool; v : int }
      (* real Julia's Int8/Int16/Int32 and UInt8/Int16/UInt32 -- a fixed
         BIT WIDTH, silently wrapping on overflow (matching real Julia's own
         fixed-width integer arithmetic), unlike the default `VInt` above
         (which plays `Int`/`Int64`'s role and never wraps at this width).
         Int64/UInt64/Int128/UInt128 are NOT attempted: OCaml's native `int`
         is 63-bit, one bit short of even signed Int64 -- representing those
         correctly needs a genuinely different backing representation this
         round doesn't add. See `Runtime.wrap_fixed` for the actual
         mask/sign-extend logic. *)
    | VRange of int * int * int (* start, step, stop *)
    | VFRange of float * float * float (* start, step, stop -- a Float range, e.g. -1.0:0.1:1.0 *)
    | VVec of vecbuf (* numeric vector -- heap-allocated, grows dynamically *)
    | VArr of
        { declared : string option
          (* Some "Player" if this array was built via the real `Array{Player}()`
             constructor -- a fixed, ENFORCED element type (checked on every
             push!/index-assignment, like a struct field's declared type),
             kept even while empty. None means the ordinary, inferred-from-
             current-contents Array (see `tag`'s VArr case) -- what every
             array LITERAL and comprehension still produces. *)
        ; cells : arrbuf
        }
      (* a Vector holding ANY value (structs, strings, ...), not just numbers --
         a literal like [1.0, 2.0] still becomes the numeric VVec above (kept
         FFI-friendly for the Rust boundary); one with a non-numeric element,
         like [player1, player2], becomes this instead. *)
    | VMat of float array array (* numeric matrix, row-major *)
    | VGenMat of
        { declared : string option
          (* Some "T" if built via the real `Matrix{T}(undef, m, n)`
             constructor -- same declared/enforced-vs-inferred split as
             VArr's `declared` above. None means the result of an
             elementwise op on declared matrices (the element type is
             recomputed from current contents, same as VArr's inferred
             Array case). *)
        ; rows : int
        ; cols : int
        ; cells : value array (* row-major, length rows*cols -- ANY value, not just numbers *)
        }
      (* a boxed, arbitrary-element-type Matrix -- Matrix{Named},
         Matrix{Rational}, ... Deliberately a disjoint sibling of VMat
         (never a Matrix subtype -- see Types' "GenericMatrix" entry below
         for why), the same reasoning that already keeps
         ComplexMatrix/SparseMatrixCSC out of the Matrix hierarchy: every
         existing `[VMat rows] -> ... | _ -> assert false` dispatch body in
         this file must never be handed one of these. No `faer`
         acceleration for this variant -- elementwise +/-/scalar-* and
         indexing dispatch through Tsubaki's OWN multiple dispatch on the
         element type, one cell at a time, rather than hardcoding
         arithmetic (see the "GenericMatrix" Dispatch methods below). *)
    | VStruct of
        { kind : string (* concrete runtime type name -- this is what dispatch sees *)
        ; fields : (string * value ref) array
        }
    | VClosure of int * (value list -> value)
      (* an anonymous function value -- callable when bound to a name, unlike
         Dispatch methods it carries no declared type signature at all. The
         int is the closure's declared param count (arity), so a host caller
         like on_frame can decide whether to pass an extra arg (dt) without
         invoking the closure first. *)
    | VTuple of value array (* multiple return values: `return a, b` produces this *)
    | VComplex of float * float (* re, im *)
    | VRational of int * int
      (* real Julia's exact `Rational` (`n // d`) -- Int-BACKED, not
         BigInt-backed like real Julia's own default `Rational{BigInt}`
         (a disclosed, deliberate scope cut: arbitrary-precision integers
         are their own separate dependency decision, see BigFloat's own
         spike). Always kept in canonical form (GCD-reduced, denominator
         strictly positive, sign lives in the numerator) by `mk_rational`,
         the only place allowed to construct one directly -- every
         arithmetic method below goes through it, so no other code needs
         to re-reduce. *)
    | VComplexVec of (float * float) array ref
      (* a Vector of Complex numbers -- ONLY produced by `eigen`/`eigvals`/
         `eigvecs` on a general (non-symmetric) Matrix, whose eigenvalues
         are genuinely Complex even for a real input. Deliberately a
         wholly separate, disjoint variant from `VVec` (same reasoning
         that already put `VComplex` in its own variant instead of
         teaching `VFloat` to hold a pair): every existing `[VVec v] ->
         ... | _ -> assert false` handler across this file keeps working
         completely unmodified, since a `VComplexVec` is never routed to
         them -- see `tag`'s "ComplexVector" case, deliberately NOT
         declared a "Vector" subtype, for why. *)
    | VComplexMat of (float * float) array array
      (* a Matrix of Complex numbers -- same reasoning and same disjoint-
         from-`VMat` design as `VComplexVec` above, for `eigen`'s general
         eigenvectors. *)
    | VSparseMat of
        { m : int
        ; n : int
        ; rows : int array (* 0-based row index, one per nonzero, parallel to cols/vals *)
        ; cols : int array (* 0-based col index *)
        ; vals : float array (* the nonzero value itself *)
        }
      (* real Julia's `SparseArrays.SparseMatrixCSC` -- a plain COO/triplet
         list here (not an actual compressed CSC layout; faer's own
         `SparseColMat` does the real CSC compression, rebuilt fresh from
         these triplets on every operation, same "no cached factorization
         state across FFI calls" convention every other decomposition in
         this file already follows). Deliberately its own disjoint variant,
         same reasoning as `VComplexMat` above -- a completely different
         internal shape from `VMat`'s `float array array`, so it must NOT
         be declared a "Matrix" subtype (see `tag`'s "SparseMatrixCSC" case). *)
    | VDict of dictbuf
      (* real Julia's `Dict` -- a mapping, which Tsubaki had no way to express
         at all (keel's own comment says so, and works around it: every node
         carries its physics handle as a field BECAUSE there was no Dict to
         put one in).

         Keyed by a NORMALIZED STRING form of the key value (see `dict_key`),
         which is what makes `d[1]` and `d[1.0]` the same entry -- the place
         real Julia arrives at by way of `hash(1) == hash(1.0)`. Iteration and
         printing come out in insertion order (`dnext` stamps each new key);
         real Julia promises no order at all, and choosing the reproducible
         end of that freedom costs nothing here. *)
    | VUniformScaling of float
      (* real Julia's `LinearAlgebra.I` -- a lazy "identity, scaled by this
         coefficient" that only becomes a concrete size when combined with
         a Matrix/Vector (`A + I`, `2I`, `I * v`, ...). The bare constant
         `I` is `VUniformScaling 1.0` (bound as a global, see `bind global
         "I"` below); nothing here ever materializes an actual n*n identity
         Matrix, matching real Julia's own laziness. *)
    | VSymbol of string * int option
      (* a quoted identifier (real Julia's `Symbol`/`:name`) -- the int is a
         HYGIENE tag: `Some id` if this symbol came from literal text inside
         a macro's own quoted template (stamped with the CURRENT macro
         expansion's id when that quote is evaluated -- see
         Eval.expr_to_value), meaning it gets renamed to a fresh gensym'd
         name when the expansion's result is spliced back into real code, so
         it can't collide with anything at the call site. `None` means an
         ordinary symbol -- one that came from `$`-interpolating a call-site
         argument, one `esc(...)` was applied to, or a symbol quoted outside
         any macro entirely -- which resolves at the call site unchanged. *)
    | VExpr of { head : string; args : value array }
      (* a quoted expression node (real Julia's `Expr(head, args...)`), e.g.
         `:(a + b)` reifies as VExpr{head="call"; args=[|VSymbol("+",_); ...|]}.
         See Eval.expr_to_value/stmt_to_value (Ast -> value, quoting) and
         Eval.value_to_expr (value -> Ast, splicing a macro's result back
         into real code) for the full scheme, including which head strings
         are used and which constructs are and aren't quotable. *)
    | VType of string
      (* a first-class reference to a type itself (real Julia's `DataType`),
         e.g. the bare expression `Vector`, `Deque{Int}`, or `Int` used as a
         VALUE rather than a constructor call -- found necessary for
         `::Type{X}` dispatch parameters (`Base.eltype(::Type{Deque{T}})`,
         `factor(::Type{A}, n) where {A<:AbstractArray}`), which need a
         real type ARGUMENT to dispatch and bind against, not just Tsubaki's
         existing "a bare identifier used as a literal type name" special
         cases (`isa`, a struct constructor call). The string is the same
         composite-name convention used everywhere else (`ptype`,
         `parse_type_expr`'s "Dict{Int,String}"). See `tag`'s own case for
         how this integrates with ordinary dispatch, and Types.ancestors
         for why a compound name like "Deque{Int}" can still reach "Any". *)

  (* backing storage for VVec/VArr: a physical array that may be BIGGER than
     the logical contents (`vlen`/`alen`), so push! can grow it geometrically
     (double capacity when full) instead of reallocating an exact-size copy
     on every single push -- see vecbuf_push/arrbuf_push below. Every other
     reader must go through vlen/alen, never `Array.length vdata/adata`
     directly, or it'll see uninitialized padding slots past the logical
     end. *)
  and dictbuf =
    { dtbl : (string, int * value * value) Hashtbl.t
      (* normalized key -> (insertion stamp, the key as written, the value) --
         the key is kept alongside so `keys(d)` hands back real values (`:x`,
         `"name"`), not the internal strings they hash to *)
    ; mutable dnext : int
    }

  and vecbuf = { mutable vdata : float array; mutable vlen : int }

  and arrbuf =
    { mutable adata : value array
    ; mutable alen : int
    ; mutable atag : string option
      (* the element tag of the CURRENT contents ("Any" when empty or mixed),
         cached -- `None` means "not known, work it out on demand". An
         inferred Array's tag is what dispatch compares on every single call
         involving it, and it used to be rescanned, element by element, every
         time: fine while `[]` was numeric and no hot loop ever held an
         Array, and quadratic the moment `[]` became the ordinary way to
         build a list (20k `push!`es: 0.03s -> 6.5s, measured). `push!`
         updates this in O(1) (see its own method); anything that can NARROW
         the element type -- an index assignment, a pop! -- just clears it and
         lets the next reader pay the scan once. *)
    }

  (* --- vecbuf/arrbuf: construct, read, and grow -- the only places that are
     allowed to know a physical array can be bigger than its logical
     contents. Everything elsewhere in this file goes through these. *)
  let vecbuf_of_array (a : float array) : vecbuf = { vdata = a; vlen = Array.length a }
  let vecbuf_length (v : vecbuf) : int = v.vlen
  let vecbuf_to_array (v : vecbuf) : float array =
    if v.vlen = Array.length v.vdata then v.vdata else Array.sub v.vdata 0 v.vlen
  let vecbuf_get (v : vecbuf) (i : int) : float = v.vdata.(i)
  let vecbuf_set (v : vecbuf) (i : int) (x : float) : unit = v.vdata.(i) <- x
  let vecbuf_replace (v : vecbuf) (a : float array) : unit =
    v.vdata <- a;
    v.vlen <- Array.length a
  (* geometric growth (double capacity, or start at 1) -- amortized O(1),
     unlike rebuilding an exact-size copy on every single push *)
  let vecbuf_push (v : vecbuf) (x : float) : unit =
    let cap = Array.length v.vdata in
    if v.vlen >= cap then (
      let newcap = if cap = 0 then 1 else cap * 2 in
      let bigger = Array.make newcap 0.0 in
      Array.blit v.vdata 0 bigger 0 v.vlen;
      v.vdata <- bigger);
    v.vdata.(v.vlen) <- x;
    v.vlen <- v.vlen + 1

  let arrbuf_of_array (a : value array) : arrbuf = { adata = a; alen = Array.length a; atag = None }
  let arrbuf_length (v : arrbuf) : int = v.alen
  let arrbuf_to_array (v : arrbuf) : value array =
    if v.alen = Array.length v.adata then v.adata else Array.sub v.adata 0 v.alen
  let arrbuf_get (v : arrbuf) (i : int) : value = v.adata.(i)

  let arrbuf_set (v : arrbuf) (i : int) (x : value) : unit =
    v.adata.(i) <- x;
    v.atag <- None

  let arrbuf_replace (v : arrbuf) (a : value array) : unit =
    v.adata <- a;
    v.alen <- Array.length a;
    v.atag <- None

  (* the cached element tag (see arrbuf's own comment) -- `tag_of` is passed in
     because `tag` itself isn't defined until much further down this file *)
  let arrbuf_elem_tag (tag_of : value -> string) (c : arrbuf) : string =
    match c.atag with
    | Some t -> t
    | None ->
      let t =
        if c.alen = 0 then "Any"
        else (
          let t0 = tag_of c.adata.(0) in
          let same = ref true in
          let i = ref 1 in
          while !same && !i < c.alen do
            if tag_of c.adata.(!i) <> t0 then same := false;
            incr i
          done;
          if !same then t0 else "Any")
      in
      c.atag <- Some t;
      t

  (* push!'s O(1) tag maintenance: the only mutation that can't narrow the
     element type, so it's the only one that gets to keep the cache instead of
     clearing it. Called by the push! method AFTER arrbuf_push (which, like
     every other mutator, cleared it). *)
  let arrbuf_retag_after_push (tag_of : value -> string) (c : arrbuf) (before : string option) (x : value) : unit =
    c.atag <-
      (match before with
      | None -> None (* unknown before, still unknown -- one scan, later, on demand *)
      | Some _ when c.alen = 1 -> Some (tag_of x) (* it was empty; now it's exactly this *)
      | Some t -> if t = tag_of x then Some t else Some "Any")
  let arrbuf_push (v : arrbuf) (x : value) : unit =
    let cap = Array.length v.adata in
    if v.alen >= cap then (
      let newcap = if cap = 0 then 1 else cap * 2 in
      let bigger = Array.make newcap VNothing in
      Array.blit v.adata 0 bigger 0 v.alen;
      v.adata <- bigger);
    v.adata.(v.alen) <- x;
    v.alen <- v.alen + 1;
    v.atag <- None

  (* a user-raised error (via the `error` builtin) or `throw` -- catchable by
     try/catch, distinct from the interpreter's own internal `Failure` (which
     try/catch also catches, so MethodError etc. are themselves catchable) *)
  exception JuliaError of value

  (* --- Julia-style abstract type hierarchy: single-inheritance parent chain up to "Any" ---
     moved up here (ahead of `tag`, which now needs it for Array{T} -- see below) *)
  module Types = struct
    let parent : (string, string) Hashtbl.t = Hashtbl.create 32
    let declare child ~parent:p = Hashtbl.replace parent child p

    (* splits a concrete instantiation's name into its base and parameters,
       e.g. "Array{Int}" -> Some ("Array", ["Int"]), "Pair{Int,String}" ->
       Some ("Pair", ["Int"; "String"]), "Any" -> None *)
    let parse_concrete name =
      match String.index_opt name '{' with
      | None -> None
      | Some i ->
        let base = String.sub name 0 i in
        let inner = String.sub name (i + 1) (String.length name - i - 2) in
        Some (base, String.split_on_char ',' inner)

    let ancestors name =
      let rec go n acc =
        if n = "Any" then List.rev ("Any" :: acc)
        else
          match Hashtbl.find_opt parent n with
          | Some p -> go p (n :: acc)
          | None -> (
            (* a compound/parametric name that was never itself `declare`d
               (e.g. "Deque{Int}" -- only the bare "Deque" base ever is)
               still needs to reach "Any" through its OWN base's chain, or
               `Type{Deque{Int}}` could never match a `Type{Any}`-shaped
               (unconstrained where-var) dispatch pattern. Found necessary
               adding VType/`::Type{X}` support. *)
            match parse_concrete n with
            | Some (base, _) when base <> n -> go base (n :: acc)
            | _ -> List.rev (n :: acc))
      in
      go name []

    (* covariant subtyping between two concrete instantiations of the SAME
       parametric family: `Array{Int} <: Array{Number}` holds because `Array`
       matches `Array` and, position by position, `Int <: Number` -- neither
       side needs to have been pre-registered via `declare` for this to work,
       unlike the plain ancestor-chain walk below. Recursive, so it composes
       for nested parametrics (`Array{Array{Int}} <: Array{Array{Number}}`)
       for free, though nothing in this project actually nests that deep. *)
    let rec distance_to sub sup =
      let rec idx i = function
        | [] -> None
        | x :: xs -> if x = sup then Some i else idx (i + 1) xs
      in
      match idx 0 (ancestors sub) with
      | Some d -> Some d
      | None -> (
        match parse_concrete sup, parse_concrete sub with
        | Some (sup_base, sup_params), Some (sub_base, sub_params)
          when sub_base = sup_base && List.length sub_params = List.length sup_params ->
          let param_distances = List.map2 distance_to sub_params sup_params in
          if List.for_all Option.is_some param_distances then
            Some (1 + List.fold_left max 0 (List.map Option.get param_distances))
          else None
        | _ -> None)

    let () =
      List.iter
        (fun (child, p) -> declare child ~parent:p)
        [ "Type", "Any"
          (* VType's own tag is always "Type{...}" (a compound name, see
             `tag`), never bare "Type" -- registered anyway so
             `ancestors`'s compound-name fallback (above) has a real base
             to walk up from. *)
        ; "Number", "Any"
        ; "Integer", "Number"
        ; "Signed", "Integer"
        ; "Unsigned", "Integer"
        ; (* reparented from directly under "Number" -- real Julia's own
             `Int <: Signed <: Integer <: Number`. Safe: every existing
             Int-argument dispatch already resolves via an EXACT tag match
             (distance 0), which always wins over the generic Number,Number
             fallback regardless of how many extra hops Int's own ancestor
             chain now has to Number. *)
          "Int", "Signed"
        ; "Int8", "Signed"
        ; "Int16", "Signed"
        ; "Int32", "Signed"
        ; "UInt8", "Unsigned"
        ; "UInt16", "Unsigned"
        ; "UInt32", "Unsigned"
        ; (* Int64/UInt64/Int128/UInt128 not attempted -- see VFixedInt's own
             comment for why (OCaml's native int is 63-bit) *)
          "Float", "Number"
        ; "Complex", "Number"
        ; "Rational", "Number"
        ; "Bool", "Any"
        ; "String", "Any"
        ; "Nothing", "Any"
        ; "Range", "Any"
        ; "Vector", "Any"
        ; "Array", "Any"
        ; "Matrix", "Any"
        ; "Function", "Any"
        ; "Tuple", "Any"
        ; "Dict", "Any"
        ; "Symbol", "Any"
        ; "Expr", "Any"
        ; "UniformScaling", "Any"
        ; (* deliberately "Any", NOT "Vector"/"Matrix" -- every existing
             `[["Vector"]]`/`[["Matrix"]]`-signature method in this file
             unpacks its operand via a hard structural pattern (`| [VVec v]
             -> ... | _ -> assert false`), with no graceful fallback the
             way the generic Number,Number methods have via `as_float`. If
             ComplexVector/ComplexMatrix were declared real subtypes, the
             dispatcher could legally hand one to any such method, whose
             catch-all would hard-crash rather than raise a catchable
             error. Keeping them hierarchy siblings sidesteps this. *)
          "ComplexVector", "Any"
        ; "ComplexMatrix", "Any"
        ; (* same reasoning as ComplexVector/ComplexMatrix above -- a
             completely different internal shape from `VMat`, so NOT a
             "Matrix" subtype *)
          "SparseMatrixCSC", "Any"
        ; (* the common declared base every concrete "Matrix{T}" (VGenMat)
             instantiation is registered under on the fly -- same trick as
             "Array" is for "Array{T}" below, letting a Dispatch signature
             of ["GenericMatrix"] match any element type at once. Deliberately
             NOT parented under "Matrix" itself: VGenMat's boxed-value
             layout is incompatible with every existing `[VMat rows] -> ...`
             dispatch body, so `f(x::Matrix)` must never resolve to one of
             these (same reasoning as ComplexMatrix/SparseMatrixCSC above). *)
          "GenericMatrix", "Any"
        ]
  end

  (* an Array holding elements that are all the same runtime type T is tagged
     "Array{T}" (registered on the fly as a subtype of "Array", same trick as
     a parametric struct's "Box{Int}"), so `f(a::Array{Player})` can
     out-specify `f(a::Array)` -- an empty or genuinely mixed-type Array
     just stays plain "Array" (nothing to infer, same as real Julia's
     `Any[]`/`Vector{Any}`). Recomputed from the CURRENT contents every time
     (not stamped once at construction), so it stays correct across
     `push!`/index-assignment without any extra bookkeeping there -- there's
     no hot loop over Array (as opposed to the numeric Vector) in this
     project's benchmarks, so the O(n) rescan here has never needed to be
     cached. *)
  let array_elem_tag (tag_of : 'v -> string) (a : 'v array) : string =
    if Array.length a = 0 then "Any"
    else (
      let t0 = tag_of a.(0) in
      if Array.for_all (fun v -> tag_of v = t0) a then t0 else "Any")

  (* one shared string allocation per built-in tag, reused on every `tag`
     call for that variant -- lets the hot dispatch-cache comparison
     (Dispatch.tags_match) short-circuit on physical equality (`==`)
     instead of a byte-by-byte String.equal for the overwhelmingly common
     case of comparing two built-in types (profiled: string comparison was
     ~16% of pisum's runtime, entirely Int/Float tags compared against
     themselves every iteration). Struct kinds and dynamically-built
     parametric names (Array{T}, Box{Int}, ...) are still ordinary fresh
     strings -- there's no fixed constant to share for those, they're
     genuinely constructed per concrete type. *)
  let tag_int = "Int"
  let tag_float = "Float"
  let tag_bool = "Bool"
  let tag_string = "String"
  let tag_nothing = "Nothing"
  let tag_range = "Range"
  let tag_vector = "Vector"
  let tag_matrix = "Matrix"
  let tag_function = "Function"
  let tag_tuple = "Tuple"
  let tag_dict = "Dict"
  let tag_complex = "Complex"
  let tag_rational = "Rational"
  let tag_symbol = "Symbol"
  let tag_expr = "Expr"
  let tag_uniform_scaling = "UniformScaling"
  let tag_complex_vec = "ComplexVector"
  let tag_complex_mat = "ComplexMatrix"
  let tag_sparse_mat = "SparseMatrixCSC"
  let tag_int8 = "Int8"
  let tag_int16 = "Int16"
  let tag_int32 = "Int32"
  let tag_uint8 = "UInt8"
  let tag_uint16 = "UInt16"
  let tag_uint32 = "UInt32"

  let fixed_int_tag bits signed =
    match bits, signed with
    | 8, true -> tag_int8
    | 16, true -> tag_int16
    | 32, true -> tag_int32
    | 8, false -> tag_uint8
    | 16, false -> tag_uint16
    | 32, false -> tag_uint32
    | _ -> failwith (Printf.sprintf "no fixed-width integer type for %d-bit signed=%b" bits signed)

  (* masks to `bits` bits, then sign-extends the top bit back out for a
     signed type -- real Julia's own wraparound-on-overflow arithmetic for
     fixed-width integers (`Int8`/`UInt8`/...), not the checked/throwing
     behavior a `T(x)` CONVERSION uses (see the def_fixed_conv constructors
     below, which call this to detect out-of-range input and raise instead
     of silently accepting the wrapped result) *)
  let wrap_fixed bits signed v =
    if bits >= 63 then v
    else (
      let m = v land ((1 lsl bits) - 1) in
      if signed && (m lsr (bits - 1)) land 1 = 1 then m - (1 lsl bits) else m)

  let rec tag = function
    | VInt _ -> tag_int
    | VFloat _ -> tag_float
    | VBool _ -> tag_bool
    | VStr _ -> tag_string
    | VNothing -> tag_nothing
    | VRange _ -> tag_range
    | VFRange _ -> tag_range
    | VVec _ -> tag_vector
    | VArr { declared = Some t; _ } ->
      (* declared via the real `Array{T}()` constructor -- fixed, enforced,
         kept even while empty (see the constructor and push!/index-assign) *)
      let concrete = Printf.sprintf "Array{%s}" t in
      Types.declare concrete ~parent:"Array";
      concrete
    | VArr { declared = None; cells } -> (
      match arrbuf_elem_tag tag cells with
      | "Any" -> "Array"
      | elem_ty ->
        let concrete = Printf.sprintf "Array{%s}" elem_ty in
        Types.declare concrete ~parent:"Array";
        concrete)
    | VMat _ -> tag_matrix
    | VGenMat { declared = Some t; _ } ->
      let concrete = Printf.sprintf "Matrix{%s}" t in
      Types.declare concrete ~parent:"GenericMatrix";
      concrete
    | VGenMat { declared = None; cells; _ } -> (
      match array_elem_tag tag cells with
      | "Any" -> "GenericMatrix"
      | elem_ty ->
        let concrete = Printf.sprintf "Matrix{%s}" elem_ty in
        Types.declare concrete ~parent:"GenericMatrix";
        concrete)
    | VStruct s -> s.kind
    | VClosure _ -> tag_function
    | VTuple _ -> tag_tuple
    | VComplex _ -> tag_complex
    | VRational _ -> tag_rational
    | VSymbol _ -> tag_symbol
    | VExpr _ -> tag_expr
    | VDict _ -> tag_dict
    | VUniformScaling _ -> tag_uniform_scaling
    | VComplexVec _ -> tag_complex_vec
    | VComplexMat _ -> tag_complex_mat
    | VSparseMat _ -> tag_sparse_mat
    | VFixedInt { bits; signed; _ } -> fixed_int_tag bits signed
    | VType s ->
      (* same "declare the compound name on first sight" convention
         VArr/VGenMat's own concrete-element tags already use above *)
      let concrete = Printf.sprintf "Type{%s}" s in
      Types.declare concrete ~parent:"Type";
      concrete

  (* shared by VComplex/VComplexVec/VComplexMat's own `show` cases below *)
  let show_complex_pair re im = Printf.sprintf "%.3f %s %.3fim" re (if im < 0.0 then "-" else "+") (Float.abs im)

  let rec show = function
    | VInt n -> string_of_int n
    | VFloat f -> Printf.sprintf "%.3f" f
    | VBool b -> string_of_bool b
    | VStr s -> s
    | VNothing -> "nothing"
    | VRange (a, 1, b) -> Printf.sprintf "%d:%d" a b
    | VRange (a, s, b) -> Printf.sprintf "%d:%d:%d" a s b
    | VFRange (a, s, b) when s = 1.0 -> Printf.sprintf "%.3f:%.3f" a b
    | VFRange (a, s, b) -> Printf.sprintf "%.3f:%.3f:%.3f" a s b
    | VVec v -> "[" ^ String.concat ", " (Array.to_list (Array.map string_of_float (vecbuf_to_array v))) ^ "]"
    | VArr { cells; _ } -> "[" ^ String.concat ", " (Array.to_list (Array.map show (arrbuf_to_array cells))) ^ "]"
    | VMat rows ->
      "["
      ^ String.concat "; "
          (Array.to_list
             (Array.map
                (fun row -> String.concat " " (Array.to_list (Array.map string_of_float row)))
                rows))
      ^ "]"
    | VGenMat { rows; cols; cells; _ } ->
      "["
      ^ String.concat "; "
          (List.init rows (fun i -> String.concat " " (List.init cols (fun j -> show cells.((i * cols) + j)))))
      ^ "]"
    | VStruct { kind = "ErrorException"; fields } ->
      (* real Julia's own `ErrorException` shows as just the bare message,
         no "ErrorException: " prefix -- matches `error(msg)`'s existing,
         already-tested display exactly (see exn_of_failure_message /
         the `error` builtin below) *)
      (match Array.find_opt (fun (n, _) -> n = "msg") fields with
       | Some (_, r) -> ( match !r with VStr m -> m | v -> show v)
       | None -> "ErrorException")
    | VStruct { kind; fields }
      when List.mem kind
             [ "DimensionMismatch"; "BoundsError"; "UndefVarError"; "TypeError"; "MethodError"; "DomainError"
             ; "InexactError"
             ] ->
      (* real Julia's own typed exceptions show as "Kind: message" (e.g.
         `showerror(io, e::DimensionMismatch) = print(io, "DimensionMismatch: ", e.msg)`) --
         matches every one of this file's own pre-existing `failwith
         "Kind: message"` call sites' displayed text exactly *)
      (match Array.find_opt (fun (n, _) -> n = "msg") fields with
       | Some (_, r) -> ( match !r with VStr m -> kind ^ ": " ^ m | v -> kind ^ ": " ^ show v)
       | None -> kind)
    | VStruct s ->
      s.kind ^ "("
      ^ String.concat ", " (Array.to_list (Array.map (fun (n, r) -> n ^ "=" ^ show !r) s.fields))
      ^ ")"
    | VClosure _ -> "#<function>"
    | VDict d ->
      (* real Julia's own display shape, minus the {K,V} it can't know here.
         Insertion order (see dict_pairs), so this is reproducible. *)
      let pairs =
        Hashtbl.fold (fun _ (seq, k, v) acc -> (seq, k, v) :: acc) d.dtbl []
        |> List.sort (fun (a, _, _) (b, _, _) -> compare a b)
      in
      "Dict(" ^ String.concat ", " (List.map (fun (_, k, v) -> show k ^ " => " ^ show v) pairs) ^ ")"
    | VTuple vs -> "(" ^ String.concat ", " (Array.to_list (Array.map show vs)) ^ ")"
    | VComplex (re, im) -> show_complex_pair re im
    | VRational (n, d) -> Printf.sprintf "%d//%d" n d
    | VSymbol (name, _) -> ":" ^ name
    | VExpr { head; args } ->
      ":(" ^ head ^ " " ^ String.concat " " (Array.to_list (Array.map show args)) ^ ")"
    | VUniformScaling c -> if c = 1.0 then "I" else Printf.sprintf "%.3f*I" c
    | VComplexVec v ->
      "[" ^ String.concat ", " (Array.to_list (Array.map (fun (re, im) -> show_complex_pair re im) !v)) ^ "]"
    | VComplexMat rows ->
      "["
      ^ String.concat "; "
          (Array.to_list
             (Array.map
                (fun row ->
                  String.concat " " (Array.to_list (Array.map (fun (re, im) -> show_complex_pair re im) row)))
                rows))
      ^ "]"
    | VSparseMat { m; n; rows; _ } ->
      (* a compact one-line summary rather than real Julia's own aligned,
         multi-line "4.0  \xc2\xb7  1.0" grid -- informative without needing
         column-alignment logic for a sparse display *)
      Printf.sprintf "%dx%d SparseMatrixCSC with %d stored entries" m n (Array.length rows)
    | VFixedInt { v; _ } -> string_of_int v
    | VType s -> s

  (* --- struct field access, the thing that replaces bespoke record types --- *)
  let get_field v name =
    match v with
    | VStruct s -> (
      match Array.find_opt (fun (n, _) -> n = name) s.fields with
      | Some (_, r) -> !r
      | None -> failwith (Printf.sprintf "type %s has no field %s" s.kind name))
    | VExpr { head; args } -> (
      (* real Julia's own `Expr.head`/`Expr.args` -- what lets a macro body
         actually inspect the quoted syntax it was handed (which call, which
         operator, how many arguments), not just splice it in unexamined the
         way every pre-existing macro in this file (@double/@my_max/@swap!/
         @repeat) happens to. *)
      match name with
      | "head" -> VSymbol (head, None)
      | "args" -> VArr { declared = None; cells = arrbuf_of_array (Array.copy args) }
      | _ -> failwith (Printf.sprintf "Expr has no field %s (only .head/.args)" name))
    | _ -> failwith (Printf.sprintf "%s is not a struct, has no fields" (tag v))

  let as_float = function
    | VInt n -> float_of_int n
    | VFloat f -> f
    | VFixedInt { v; _ } -> float_of_int v
    | VRational (n, d) -> float_of_int n /. float_of_int d
    | v -> failwith (Printf.sprintf "expected a number, got %s" (tag v))

  (* --- Rational: always kept GCD-reduced with a strictly positive
     denominator (sign lives in the numerator) -- mk_rational is the only
     place allowed to build a VRational directly; every method below goes
     through it. Int-backed, so this silently overflows the same way any
     other `VInt` arithmetic here does -- a disclosed scope cut, not
     BigInt-backed like real Julia's own default `Rational{BigInt}`. *)
  let rec gcd a b = if b = 0 then abs a else gcd b (a mod b)

  let mk_rational (n : int) (d : int) : value =
    if d = 0 then failwith "ArgumentError: invalid rational: zero denominator"
    else (
      let sign = if d < 0 then -1 else 1 in
      let n, d = n * sign, d * sign in
      let g = gcd n d in
      let g = if g = 0 then 1 else g in
      VRational (n / g, d / g))

  (* real Julia's `===`/`!==` (egal) -- deliberately NOT a Dispatch method:
     real Julia's own === is a compiler intrinsic too, never a generic
     function a user can add methods to, so handling it directly here (see
     Eval's EBinOp case) is the more faithful shape, not a shortcut. Bits-
     like immutable values compare by value (real Julia's === agrees with ==
     for these); everything else (structs, arrays, ...) is real Julia's own
     reference identity, which OCaml's physical `==` already gives for free
     since each construct/array-literal allocates its own fresh block. *)
  let is_identical a b =
    match a, b with
    | VInt x, VInt y -> x = y
    | VFloat x, VFloat y -> x = y
    | VBool x, VBool y -> x = y
    | VStr x, VStr y -> x = y
    | VNothing, VNothing -> true
    | VFixedInt { bits = b1; signed = s1; v = v1 }, VFixedInt { bits = b2; signed = s2; v = v2 } ->
      b1 = b2 && s1 = s2 && v1 = v2
    | _ -> a == b

  (* an ordinary, inferred (not `Array{T}()`-declared) Array -- what every
     array literal, comprehension, and slice still produces *)
  let mk_arr (arr : value array) : value = VArr { declared = None; cells = arrbuf_of_array arr }

  (* --- Dict: keys, and the three things you can do to one --------------
     A key is normalized to a string, and the normalization is where the
     semantics live: an integral Float normalizes to the same string an Int
     does, so `d[1]` and `d[1.0]` are one entry (real Julia arrives at the
     same place by way of `hash(1) == hash(1.0)`). Only values with an
     obvious, stable identity are allowed to be keys -- a mutable struct
     would be a key that can change out from under its own entry, and saying
     so is better than hashing it and hoping. *)
  let dict_key (v : value) : string =
    match v with
    | VInt n -> "i" ^ string_of_int n
    | VFloat f -> if Float.is_integer f && Float.abs f < 1e18 then "i" ^ string_of_int (int_of_float f) else "f" ^ string_of_float f
    | VBool b -> if b then "bt" else "bf"
    | VStr s -> "s" ^ s
    | VSymbol (n, _) -> "y" ^ n
    | VNothing -> "n"
    | VFixedInt { v; _ } -> "i" ^ string_of_int v
    | v ->
      failwith
        (Printf.sprintf "KeyError: a %s can't be a Dict key -- keys are Int, Float, Bool, String, Symbol or nothing" (tag v))

  let dict_get (d : dictbuf) (k : value) : value option =
    match Hashtbl.find_opt d.dtbl (dict_key k) with
    | Some (_, _, v) -> Some v
    | None -> None

  (* an existing key keeps its place in the order, a new one goes to the end
     (see VDict's own comment on why the order is pinned down at all) *)
  let dict_set (d : dictbuf) (k : value) (v : value) : unit =
    let key = dict_key k in
    match Hashtbl.find_opt d.dtbl key with
    | Some (seq, _, _) -> Hashtbl.replace d.dtbl key (seq, k, v)
    | None ->
      Hashtbl.replace d.dtbl key (d.dnext, k, v);
      d.dnext <- d.dnext + 1

  let dict_delete (d : dictbuf) (k : value) : unit = Hashtbl.remove d.dtbl (dict_key k)
  let dict_length (d : dictbuf) : int = Hashtbl.length d.dtbl

  (* every (key, value) pair, in insertion order -- the one place that order
     is actually reconstructed, so lookup/insert stay O(1) and only walking
     the whole Dict pays for being tidy *)
  let dict_pairs (d : dictbuf) : (value * value) list =
    Hashtbl.fold (fun _ (seq, k, v) acc -> (seq, k, v) :: acc) d.dtbl []
    |> List.sort (fun (a, _, _) (b, _, _) -> compare a b)
    |> List.map (fun (_, k, v) -> k, v)

  let mk_dict () : value = VDict { dtbl = Hashtbl.create 8; dnext = 0 }

  (* an inferred (not `Matrix{T}(undef,...)`-declared) generic Matrix -- what
     an elementwise op on VGenMat operands produces *)
  let mk_gen_mat (rows : int) (cols : int) (cells : value array) : value = VGenMat { declared = None; rows; cols; cells }

  (* keyword arguments are a side-channel, not part of the dispatch signature --
     exactly Julia's actual semantics (kwargs never participate in multiple
     dispatch). Set by the caller just before Dispatch.call, read by a
     user function's own impl closure when binding its kwparams. *)
  let current_kwargs : (string * value) list ref = ref []

  (* another side-channel, same idea: `end` inside `v[...]` means "the length
     of whatever v is", set right before evaluating the index expression *)
  let current_end : int ref = ref 0

  (* the module namespace whatever code is CURRENTLY EXECUTING was declared
     in, "" at the top level -- e.g. "Geometry." while running something
     declared inside `module Geometry ... end`. A third side-channel, same
     idea as the two above: set once when a module's declarations run (or a
     module-scoped function/closure's body starts), read by every bare
     name lookup (calls, constructors, struct/parent/parameter type names)
     so unqualified code inside a module resolves within it. Deliberately a
     plain string prefix, not a real nested-scope stack -- see README for
     what this simplified module system does and doesn't do. *)
  let current_module_prefix : string ref = ref ""

  (* directory of the source file currently being run ("" if unknown, e.g. the
     built-in demo). `include("x.jl")` resolves its argument against this --
     real Julia's rule, so a file can include a sibling by bare name no matter
     what directory the process was started from -- and swaps in the included
     file's own directory while it runs, so includes nest correctly. Set by
     Main for the top-level script, pushed/popped by Eval's `include`. *)
  let current_file_dir : string ref = ref ""

  (* a side-channel like current_module_prefix above: `Some name` while one
     of struct `name`'s own inner constructors is running (set right before
     running its body, restored right after -- see Eval.SStructDecl), so
     `new`/`new{T}` inside it knows which struct to build. Real Julia
     restricts `new` lexically (only valid literally inside that type's own
     constructor definitions); this is a dynamic stand-in for that, so it's
     only meaningful as long as ordinary code never happens to call
     something named "new" itself. *)
  let current_constructing_struct : string option ref = ref None

  (* --- macro hygiene state --- one shared counter mints both fresh hygiene
     expansion ids AND gensym names, since both need the same thing: a number
     nobody else is using. `current_hygiene_id` is a side-channel like
     `current_module_prefix` above: `Some id` while a macro's OWN body is
     executing (set right before running it, restored right after -- see
     Eval's EMacroCall), so every quote/quote-block IT evaluates during that
     window tags the symbols it introduces with `id`. Nothing outside a
     macro body ever sees anything but `None`. *)
  let hygiene_counter = ref 0
  let new_hygiene_id () = incr hygiene_counter; !hygiene_counter
  let current_hygiene_id : int option ref = ref None

  (* `esc(x)` -- strips every symbol's hygiene tag inside a quoted value,
     recursively, so that part of a macro's expansion resolves at the call
     site instead of being renamed. Needs to be defined before it's
     registered as a builtin further down, and before value_to_expr (Eval)
     needs to know what "already escaped" looks like -- but esc itself only
     needs `value`, so it lives here in Runtime. *)
  let rec esc_value = function
    | VSymbol (name, _) -> VSymbol (name, None)
    | VExpr { head; args } -> VExpr { head; args = Array.map esc_value args }
    | v -> v

  (* a bare type name mentioned in a struct's `<: Parent`, a field's `::T`, a
     function parameter's `::T`, or a `Union{...}` alternative -- resolved
     against the CURRENT module first (so a struct/function can refer to a
     sibling type declared earlier in the same module by its bare name),
     falling back to the bare name itself (a builtin like "Any"/"Number", or
     an already-`using`'d name). For a parametric instantiation string like
     "Array{Entity}", only the OUTER base ("Array") is resolved this way --
     a type parameter NESTED inside the braces that's itself module-local
     isn't (a disclosed, narrower scope: reference it after `using`, or use
     a builtin/already-global type there instead). A type-parameter
     placeholder like "T" is never itself a registered type, so it always
     safely falls through unchanged regardless. *)
  let resolve_type_name n =
    if !current_module_prefix = "" then n
    else (
      match String.index_opt n '{' with
      | None ->
        let qualified = !current_module_prefix ^ n in
        if Hashtbl.mem Types.parent qualified then qualified else n
      | Some i ->
        let base = String.sub n 0 i in
        let rest = String.sub n i (String.length n - i) in
        let qualified_base = !current_module_prefix ^ base in
        if Hashtbl.mem Types.parent qualified_base then qualified_base ^ rest else n)

  (* --- the one door out to the JS host ---------------------------------
     Every bridge (gpu, physics, audio, curve, parallel) reaches its host the
     same way: a `host_*` function that the EMBEDDING defines -- preload.js
     under Node, the page's own script in a browser. Which means every bridge
     can also be handed an embedding that simply doesn't have the one it
     wants, and until this existed, that read as `TypeError: a is not a
     function`: no host name, no bridge, no idea. (That exact line is what a
     `beep()` produced under Node for a long time -- see preload.js's
     host_audio_tone.) So the call goes through here instead, and a missing
     host says which host, from which bridge, and where hosts are defined.
     A host that exists but THROWS is wrapped the same way, keeping the JS
     error's own message instead of letting an opaque OCaml exception name
     surface in its place. *)
  let host_exists name =
    let open Js_of_ocaml in
    Js.to_string (Js.typeof (Js.Unsafe.get Js.Unsafe.global name : Js.Unsafe.any)) = "function"

  let host_call ~(area : string) (name : string) (args : Js_of_ocaml.Js.Unsafe.any array) =
    let open Js_of_ocaml in
    if not (host_exists name) then
      failwith
        (Printf.sprintf
           "HostError: the %s bridge needs `%s`, and this host doesn't define it -- under Node that's preload.js, in a browser it's the page's own script (see web/demo.html)"
           area name);
    match Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global name) args with
    | v -> v
    | exception e ->
      let msg =
        match Js_error.of_exn e with
        | Some err -> Js_error.message err
        | None -> Printexc.to_string e
      in
      failwith (Printf.sprintf "HostError: `%s` (the %s bridge) threw: %s" name area msg)

  (* --- multiple dispatch: most-specific applicable method wins, exact ties are
     a genuine ambiguity error -- same algorithm regardless of whether the method
     was registered by built-in setup code or parsed from user `function` syntax. --- *)
  module Dispatch = struct
    (* each parameter's declared type is a list of alternatives -- a plain type
       is a singleton, "Any" is ["Any"], and Union{A,B,C} is ["A";"B";"C"] *)
    type method_ = { sig_ : string list list; impl : value list -> value }

    let methods : (string, method_ list) Hashtbl.t = Hashtbl.create 64

    (* bumped on every (re)definition, anywhere -- an inline cache's stamped
       generation no longer matching this means "something might have
       changed since you were resolved, redo the full lookup" *)
    let generation = ref 0

    let defmethod name sig_ impl =
      incr generation;
      let existing = Option.value (Hashtbl.find_opt methods name) ~default:[] in
      (* redefining a method with the exact same signature replaces it --
         matching real Julia -- rather than accumulating an ever-growing
         pile of identical, eventually-ambiguous candidates *)
      let existing = List.filter (fun m -> m.sig_ <> sig_) existing in
      Hashtbl.replace methods name ({ sig_; impl } :: existing)

    let matches_alt arg alts = List.exists (fun alt -> Types.distance_to arg alt <> None) alts
    let best_distance arg alts = List.filter_map (Types.distance_to arg) alts |> List.fold_left min max_int

    let applicable m arg_tags =
      List.length m.sig_ = List.length arg_tags
      && List.for_all2 (fun alts arg -> matches_alt arg alts) m.sig_ arg_tags

    let specificity m arg_tags =
      List.fold_left2 (fun acc alts arg -> acc + best_distance arg alts) 0 m.sig_ arg_tags

    let show_sig sig_ = String.concat ", " (List.map (String.concat "|") sig_)

    (* the actual resolution algorithm, shared by both the uncached and the
       inline-cached call paths below *)
    let resolve name arg_tags =
      let candidates = Option.value (Hashtbl.find_opt methods name) ~default:[] in
      match List.filter (fun m -> applicable m arg_tags) candidates with
      | [] ->
        failwith
          (Printf.sprintf "MethodError: no method matching %s(%s)" name
             (String.concat ", " arg_tags))
      | ms -> (
        let scored = List.map (fun m -> specificity m arg_tags, m) ms in
        let sorted = List.sort (fun (s1, _) (s2, _) -> compare s1 s2) scored in
        match sorted with
        | (best, m1) :: (second, _) :: _ when second = best ->
          failwith
            (Printf.sprintf "MethodError: ambiguous method for %s(%s) -- signature (%s) ties"
               name (String.concat ", " arg_tags) (show_sig m1.sig_))
        | (_, m) :: _ -> m
        | [] -> assert false)

    let call name args =
      let arg_tags = List.map tag args in
      (resolve name arg_tags).impl args

    (* --- monomorphic inline cache: one call site (one EBinOp AST node)
       remembers the argument tags and resolved impl it saw last time. A hot
       loop calling `+` on (Int,Int) a million times pays the full
       candidate-filter/specificity/ambiguity resolution exactly once, then
       just compares a short string list and jumps straight to the cached
       closure -- the same "pseudo-JIT" trick real dynamic-language runtimes
       use (inline caching), just without ever emitting machine code. *)
    type call_cache = {
      mutable gen : int;
      mutable entry : (string list * (value list -> value)) option;
      (* self-correcting absence cache for ECall's own closure-shadow
         pre-check (see Eval.lookup_opt_shadow_free) -- not part of dispatch
         resolution itself, just riding along on the one cache cell every
         ECall node already owns. -1 = never confirmed; else the value of
         Eval.global_generation as of which "no local closure named this
         call's own `name` exists anywhere up to `global`" was last
         confirmed. A stale value (global_generation has moved on since)
         just triggers a real re-check, exactly like gen/entry above --
         never trusted blindly. See PROFILE_FIB_MANDEL_QUICKSORT.md. *)
      mutable shadow_gen : int;
      (* same idea as `shadow_gen`, for ECall's OTHER pre-check ("is `name`
         possibly a struct constructor?", `Hashtbl.mem struct_defs name`) --
         gated on the separate `struct_defs_generation` counter (bumped in
         `declare_struct`, not by `bind`) since it's a different table with
         a different invalidation event. -1 = never confirmed; else the
         value of `struct_defs_generation` as of which "`name` is not in
         `struct_defs`" was last confirmed. *)
      mutable struct_gen : int;
    }

    let new_cache () : call_cache = { gen = -1; entry = None; shadow_gen = -1; struct_gen = -1 }

    (* compares cached tags against args WITHOUT building a fresh `List.map
       tag args` list first -- on a cache hit (the overwhelmingly common
       case in a hot loop) this is zero allocations, where the naive
       "compute arg_tags, then compare" order always allocated one. The `==`
       check first is a real fast path, not a redundant one: every built-in
       tag is one shared string constant (see `tag` above), so comparing two
       built-in-typed args (the common case in any numeric hot loop) hits
       physical equality and skips String.equal's byte comparison entirely. *)
    let rec tags_match tags args =
      match tags, args with
      | [], [] -> true
      | t :: ts, a :: rest ->
        let a_tag = tag a in
        (t == a_tag || String.equal t a_tag) && tags_match ts rest
      | _ -> false

    let call_cached (cache : call_cache) name args =
      if cache.gen <> !generation then (
        cache.gen <- !generation;
        cache.entry <- None);
      match cache.entry with
      | Some (tags, impl) when tags_match tags args -> impl args
      | _ ->
        let arg_tags = List.map tag args in
        let m = resolve name arg_tags in
        cache.entry <- Some (arg_tags, m.impl);
        m.impl args
  end

  (* a variable-read cache cell, one per EVar AST node: remembers how many
     `parent` hops up the scope chain this name resolved to last time. The
     scope *shape* at a given call site doesn't change between evaluations
     (recursion doesn't add depth here -- a closure's call frame's parent is
     always its static definition environment, never the dynamic caller), so
     this is a safe accelerator, not a change to lookup semantics: a wrong
     guess just falls back to the ordinary full walk and re-learns the depth. *)
  type var_cache = { mutable depth : int }

  let new_var_cache () : var_cache = { depth = 0 }

  (* funcdecl_cache_state/funcdecl_cache are defined further below, right
     after the Host module -- FC_host_compiled needs Host.program, and Host
     needs get_field/construct/Dispatch, all defined between here and there.
     See that later comment for the full rationale. *)

  (* --- struct constructors: a struct/abstract-type declaration is data, produced
     by the parser, not a hardcoded OCaml type. A struct declared `Box{T}` (or
     `Dict{K,V}`, any number of parameters) is "parametric": at construction
     time, whichever field was itself declared `::T` (one field per
     parameter) has its argument's *runtime* type tag substituted for T,
     producing a concrete instantiated type name like "Box{Int}" or
     "Dict{Int,String}", registered on the fly as a subtype of the base name. --- *)
  type struct_def =
    { canonical_name : string
      (* the fully-qualified name this struct was declared under -- "Circle"
         at the top level, "Shapes.Circle" inside `module Shapes`. `construct`
         ALWAYS tags instances with this, regardless of which key (the
         canonical one, or a bare alias `using` set up) was used to find this
         struct_def, so a Circle built from inside its module and one built
         via bare access after `using` end up with the exact same tag --
         see `construct` and `use_module`. *)
    ; field_names : string list
    ; type_params : string list (* e.g. ["T"] for Box{T}, ["K";"V"] for Dict{K,V}, [] if not parametric *)
    ; field_types : string list list (* parallel to field_names *)
    ; mutable_ : bool (* `mutable struct` vs plain `struct` -- see set_field and soa_eligible *)
    }

  let struct_defs : (string, struct_def) Hashtbl.t = Hashtbl.create 32

  (* bumped on every struct declaration -- lets ECall's own "is `name`
     possibly a struct constructor" pre-check (see Eval, `call_cache`'s
     `struct_gen` field) know whether `struct_defs` could possibly have
     changed since it last confirmed a given name absent, without a real
     `Hashtbl.mem struct_defs name` on every single call. Same pattern as
     `Dispatch.generation`/`shadow_gen`, just gated on a different event.
     See PROFILE_FIB_MANDEL_QUICKSORT.md. *)
  let struct_defs_generation = ref 0

  (* `name` is already fully qualified (the caller -- SStructDecl's eval --
     prepends the current module prefix, if any) *)
  let declare_struct ~mutable_ name ~parent ~type_params field_names field_types =
    incr struct_defs_generation;
    Types.declare name ~parent;
    Hashtbl.replace struct_defs name { canonical_name = name; field_names; type_params; field_types; mutable_ }

  let declare_abstract name ~parent = Types.declare name ~parent

  (* true if `ftype` is either bare `::T` (one of the struct's own type
     parameters), a self-referential parametric reference to the struct
     ITSELF (`next::Node{T}` inside Node's own declaration -- the linked-
     list/tree shape `new`/`new{T}` exists to enable, see deque.jl in the
     README), or a builtin generic container over one of the struct's own
     type parameters (`data::Vector{T}`, same deque.jl -- Vector{T}(undef,n)
     is the value actually stored there). All three have their concrete
     type filled in dynamically rather than being a fixed constraint to
     check a value against, so field type-checking (construct, set_field)
     treats them alike: skip enforcement entirely, rather than comparing
     against the literal unresolved string "Node{T}"/"Vector{T}" (which
     could never match a real concrete tag like "Node{Int}"). Shared so both
     places agree. *)
  let is_type_param_field ftype (sd : struct_def) =
    match ftype with
    | [ t ] ->
      List.mem t sd.type_params
      || (match String.index_opt t '{' with
         | Some i ->
           let base = String.sub t 0 i in
           let inner = String.sub t (i + 1) (String.length t - i - 2) in
           (base = sd.canonical_name || base = "Vector" || base = "Array" || base = "Matrix")
           && List.mem inner sd.type_params
         | None -> false)
    | _ -> false

  (* ~allow_partial is only ever true for `new`/`new{T}` (see Eval's ECall) --
     real Julia lets an inner constructor provide fewer args than there are
     fields, leaving the rest to be assigned afterward (the standard way to
     build a self-referential/circular struct: constructing it can't
     possibly supply a value for a field that has to point back at the very
     value being constructed). Missing TRAILING fields are padded with
     VNothing here -- a loose stand-in for real Julia's genuinely
     uninitialized slot (which raises UndefRefError if read before being
     set); reading one early here just silently sees VNothing instead. An
     ordinary `StructName(args)` call (no custom constructor at all) always
     uses the default, still requiring every field, exactly as before. *)
  let construct ?(allow_partial = false) name args =
    match Hashtbl.find_opt struct_defs name with
    | None -> failwith (Printf.sprintf "no such struct type: %s" name)
    | Some sd ->
      let nargs = List.length args in
      let nfields = List.length sd.field_names in
      if allow_partial then (
        if nargs > nfields then
          failwith (Printf.sprintf "%s has %d field(s), new(...) given %d" name nfields nargs))
      else if nargs <> nfields then
        failwith (Printf.sprintf "%s expects %d args, got %d" name nfields nargs);
      let is_type_param ftype = is_type_param_field ftype sd in
      (* real Julia CONVERTS into a declared field type rather than demanding an
         exact match -- `convert(Float64, 1) == 1.0` -- so an Int literal lands
         in a `::Float` field instead of raising. Doing the same here is what
         lets a Float-typed value struct still be written the obvious way
         (`Vec2(0, 0)`, not `Vec2(0.0, 0.0)`); without it, typing a field
         `::Float` makes it hostile to plain integer literals, which is exactly
         why some structs were left untyped. Only this one widening (Int ->
         Float) is performed; every other mismatch still raises just below. *)
      let field_types_arr = Array.of_list sd.field_types in
      let args =
        List.mapi
          (fun i v ->
            if i < Array.length field_types_arr then (
              match field_types_arr.(i), v with
              | [ "Float" ], VInt n -> VFloat (float_of_int n)
              | _ -> v)
            else v)
          args
      in
      let args_arr = Array.of_list args in
      (* enforce field type annotations now -- except a field typed with one of
         the struct's own type parameters (`::T`), whose concrete type is
         *inferred from* this argument rather than a constraint it must
         already satisfy; a field beyond the args actually given (partial
         construction) has nothing to check yet *)
      List.iteri
        (fun i ftype ->
          if i < nargs && (not (is_type_param ftype)) && ftype <> [ "Any" ] then (
            let arg = args_arr.(i) in
            if not (Dispatch.matches_alt (tag arg) ftype) then
              failwith
                (Printf.sprintf "TypeError: field %s::%s cannot hold a %s"
                   (List.nth sd.field_names i) (String.concat "|" ftype) (tag arg))))
        sd.field_types;
      let kind =
        (* ALWAYS the struct_def's own canonical name, not the (possibly
           bare-aliased) `name` this construct call was actually looked up
           under -- see struct_def.canonical_name's comment for why *)
        if sd.type_params = [] then sd.canonical_name
        else (
          (* infer each declared parameter's concrete tag from whichever field
             was itself declared exactly `::T` -- one param, one field, same
             rule Box{T} always used, just applied once per parameter now
             (only among the fields actually given -- see i < nargs above) *)
          let infer tparam =
            let rec find_idx i types =
              match types with
              | [] -> None
              | t :: _ when t = [ tparam ] && i < nargs -> Some i
              | _ :: rest -> find_idx (i + 1) rest
            in
            Option.map (fun i -> tag args_arr.(i)) (find_idx 0 sd.field_types)
          in
          let resolved = List.map infer sd.type_params in
          if List.for_all Option.is_some resolved then (
            let concrete =
              Printf.sprintf "%s{%s}" sd.canonical_name (String.concat "," (List.map Option.get resolved))
            in
            Types.declare concrete ~parent:sd.canonical_name;
            concrete)
          else sd.canonical_name (* at least one param has no field typed exactly `::T` -- stays generic *))
      in
      let padded_args = if nargs >= nfields then args else args @ List.init (nfields - nargs) (fun _ -> VNothing) in
      VStruct
        { kind; fields = Array.of_list (List.map2 (fun n v -> n, ref v) sd.field_names padded_args) }

  (* a struct is eligible for Ecs's SoA (columnar) component storage --
     see Ecs.table_for and Host.HEcsSoaFieldRead/HEcsSoaWrite below -- only
     when every one of its fields is DECLARED `::Float` (real Julia's
     `Float64`, this project's own tag name, see README's own "struct
     Point; x::Float; y::Float; end" example), not parametric, has at
     least one field, and is declared as a plain (non-mutable) `struct`.
     That last condition is load-bearing, not incidental: SoA's whole
     point is that get_component hands back a FRESH copy built straight
     from the columns (see Ecs.get_component_raw), so a field assigned on
     that copy (`p.x = ...`) never writes through to storage -- only
     `add_component!` does. A `mutable struct` promises the opposite (that
     mutating a field you were handed changes the real thing), so it stays
     on the AoS path, where get_component really does hand back the same
     boxed VStruct that's sitting in the table. Keeping SoA restricted to
     immutable structs is what makes that promise checkable: `set_field`
     already refuses to mutate an immutable struct's fields at all, so
     "does p.x = ... write through" is never even askable for a kind that
     took the SoA path. Defined here (not in Ecs, which depends on this
     module) so BOTH Ecs.table_for (deciding AoS vs SoA storage for a
     kind) and Compile.try_compile_host (deciding whether to alias a
     get_component result to a direct column read/write instead of a real
     boxed struct) call the exact SAME rule -- if the two ever disagreed,
     compiled code could read/write a column shape that doesn't match what
     Ecs actually allocated. *)
  (* A field counts when it is DECLARED `::Float`, or when it is declared as
     another struct that is itself made only of such fields, all the way down
     -- so `pos::Vec2` (Vec2 being a plain `struct` of two `::Float`s) is fine
     and flattens into two columns. The nested struct must be immutable for the
     same reason the outer one must (see above): SoA hands back a fresh copy,
     so nothing you're handed may promise write-through. `depth` only guards a
     struct that (illegally) contains itself -- real code never approaches it. *)
  (* Shared core for BOTH soa_eligible (below -- ECS SoA storage) and
     Compile.vec_arity (bin/compile.ml -- GPU vecN construction, "own
     check, not a reuse" no longer applies as of this refactor): is
     `kind` an immutable, non-parametric, non-empty-field struct whose
     fields are EITHER directly `::Float`, OR another struct passing
     this SAME check -- up to `max_depth` levels of struct-in-struct
     nesting? Each nesting level consumes one unit of `max_depth`
     budget, checked before recursing; a Float terminal never consumes
     budget, so a chain up to `max_depth` levels deep, Float-terminated,
     always passes regardless of how much budget is left at the leaf --
     only an ATTEMPT to nest one level past the budget fails.
     `vec_arity`'s own call passes `max_depth:0` (no nesting allowed at
     all -- a raw WGSL/GLSL vecN has no sub-structure whatsoever);
     `soa_eligible` below passes `max_depth:7` (an ECS component built
     from small nested POD types like `pos::Vec2` -- purely a guard
     against a struct that illegally contains itself; real code never
     approaches it either way, so the exact number is a safety margin,
     not a tested contract). *)
  let rec float_shaped ~max_depth (kind : string) : bool =
    match Hashtbl.find_opt struct_defs kind with
    | None -> false
    | Some sd ->
      (not sd.mutable_) && sd.type_params = [] && sd.field_names <> []
      && List.for_all
           (function
             | [ "Float" ] -> true
             | [ k ] -> max_depth > 0 && float_shaped ~max_depth:(max_depth - 1) k
             | _ -> false)
           sd.field_types

  let soa_eligible kind = float_shaped ~max_depth:7 kind

  (* the flat float columns a SoA-eligible kind actually gets, named by their
     path and laid out depth-first in declaration order: a FLAT all-`::Float`
     struct yields exactly its own field names (so nothing about the existing
     layout moves), while `struct T; pos::Vec2; vel::Vec2; end` yields
     ["pos.x"; "pos.y"; "vel.x"; "vel.y"]. Ecs builds its columns from this and
     Compile resolves `t.pos.x` against the same list, so the two can't
     disagree about the shape (see soa_eligible's comment). *)
  let soa_leaf_paths kind : string list =
    let rec of_struct prefix k =
      match Hashtbl.find_opt struct_defs k with
      | None -> []
      | Some sd ->
        List.concat
          (List.map2
             (fun fname ftype ->
               let path = if prefix = "" then fname else prefix ^ "." ^ fname in
               match ftype with
               | [ "Float" ] -> [ path ]
               | [ k' ] -> of_struct path k'
               | _ -> [])
             sd.field_names sd.field_types)
    in
    of_struct "" kind

  (* --- typed exception hierarchy: real Julia catches `DimensionMismatch`,
     `MethodError`, etc. as real, `isa`-checkable TYPES, not strings. Every
     `failwith` in this file already tags its own message with one of these
     exact kind names by convention (`"DimensionMismatch: ..."`,
     `"MethodError: ..."`, ...) -- rather than touching each of this file's
     ~90 `failwith` call sites individually, this reconstructs a real typed
     value from that SAME string convention at the one place every such
     failure is actually caught (`STry`, see Eval below). A message with no
     recognized prefix (an internal interpreter error, not one of these six
     named kinds) becomes a generic `ErrorException` -- real Julia's own
     catch-all for a plain `error(msg)`. *)
  let () =
    Types.declare "Exception" ~parent:"Any";
    List.iter
      (fun k -> declare_struct ~mutable_:false k ~parent:"Exception" ~type_params:[] [ "msg" ] [ [ "String" ] ])
      [ "DimensionMismatch"; "BoundsError"; "UndefVarError"; "TypeError"; "MethodError"; "DomainError"
      ; "InexactError"; "ErrorException"
      ]

  let exception_kinds =
    [ "DimensionMismatch"; "BoundsError"; "UndefVarError"; "TypeError"; "MethodError"; "DomainError"; "InexactError" ]

  let exn_of_failure_message msg =
    match String.index_opt msg ':' with
    | Some i when i + 1 < String.length msg && msg.[i + 1] = ' ' ->
      let kind = String.sub msg 0 i in
      if List.mem kind exception_kinds then construct kind [ VStr (String.sub msg (i + 2) (String.length msg - i - 2)) ]
      else construct "ErrorException" [ VStr msg ]
    | _ -> construct "ErrorException" [ VStr msg ]

  (* struct_defs is keyed by the base name ("Box"), but a parametric struct's
     values carry a concrete instantiated kind ("Box{Int}") -- strip that back
     off to find the declaration when checking a field's declared type. *)
  let struct_def_for kind =
    match Hashtbl.find_opt struct_defs kind with
    | Some sd -> Some sd
    | None -> (
      match String.index_opt kind '{' with
      | Some i -> Hashtbl.find_opt struct_defs (String.sub kind 0 i)
      | None -> None)

  let field_type_of sd field_name =
    let rec go names types =
      match names, types with
      | n :: _, t :: _ when n = field_name -> Some t
      | _ :: ns, _ :: ts -> go ns ts
      | _ -> None
    in
    go sd.field_names sd.field_types

  (* set_field lives here, not next to get_field, because it needs struct_defs
     and Dispatch.matches_alt to enforce field types -- the same check
     `construct` does, now also applied on assignment, not just at birth. *)
  let set_field v name newv =
    match v with
    | VStruct s -> (
      match Array.find_opt (fun (n, _) -> n = name) s.fields with
      | Some (_, r) ->
        let newv =
          match struct_def_for s.kind with
          | None -> newv
          | Some sd -> (
            if not sd.mutable_ then
              failwith (Printf.sprintf "setfield!: immutable struct of type %s cannot be changed" s.kind);
            match field_type_of sd name with
            | None -> newv
            | Some ftype ->
              let is_type_param = is_type_param_field ftype sd in
              (* same Int -> Float convert `construct` does -- see there *)
              let newv = (match ftype, newv with [ "Float" ], VInt n -> VFloat (float_of_int n) | _ -> newv) in
              if (not is_type_param) && ftype <> [ "Any" ] && not (Dispatch.matches_alt (tag newv) ftype)
              then
                failwith
                  (Printf.sprintf "TypeError: field %s::%s cannot hold a %s" name
                     (String.concat "|" ftype) (tag newv));
              newv)
        in
        r := newv
      | None -> failwith (Printf.sprintf "type %s has no field %s" s.kind name))
    | _ -> failwith (Printf.sprintf "%s is not a struct, has no fields" (tag v))

  (* `using Name` -- merges everything `Name` declared into the bare/global
     namespace:
     - each qualified "Name.foo"'s candidate dispatch methods get unioned
       into bare "foo"'s list, so two modules' same-named, unrelated
       functions coexist as extra candidates of one generic function --
       exactly how same-named top-level `function` declarations already
       behaved before modules existed; no new dispatch semantics invented
       for this.
     - each qualified struct's struct_def gets ALIASED (not copied) onto its
       bare name, so `Foo(...)` and `Shapes.Foo(...)` construct through the
       exact same struct_def -- and since `construct` always tags with
       `sd.canonical_name` (see above), both produce the identical
       "Shapes.Foo" tag regardless of which name found it.
     - each qualified type's ancestor chain gets the bare name SPLICED in
       between it and its original parent ("Shapes.Foo" -> "Foo" -> whatever
       "Shapes.Foo" used to point to directly), rather than just given the
       same parent (which would make them unrelated siblings) -- so
       `isa`/dispatch against the bare name recognizes an already-qualified-
       tagged instance as related, the same "same bare name -> related"
       simplification the function case already makes, applied consistently
       to types too. Guarded against re-`using` the same module twice (or
       two modules sharing a same-named type) ever creating a self-loop.
     Collected into snapshots first, then applied, so mutating a table
     doesn't happen while folding over it. *)
  let use_module modname =
    let qp = modname ^ "." in
    let qplen = String.length qp in
    let has_prefix s = String.length s > qplen && String.equal (String.sub s 0 qplen) qp in
    let bare_of s = String.sub s qplen (String.length s - qplen) in
    let methods_to_merge =
      Hashtbl.fold (fun k v acc -> if has_prefix k then (bare_of k, v) :: acc else acc) Dispatch.methods []
    in
    List.iter
      (fun (bare, ms) ->
        let existing = Option.value (Hashtbl.find_opt Dispatch.methods bare) ~default:[] in
        Hashtbl.replace Dispatch.methods bare (ms @ existing))
      methods_to_merge;
    if methods_to_merge <> [] then incr Dispatch.generation;
    let structs_to_merge =
      Hashtbl.fold (fun k v acc -> if has_prefix k then (bare_of k, v) :: acc else acc) struct_defs []
    in
    List.iter (fun (bare, sd) -> Hashtbl.replace struct_defs bare sd) structs_to_merge;
    let types_to_merge =
      Hashtbl.fold (fun k v acc -> if has_prefix k then (bare_of k, v) :: acc else acc) Types.parent []
    in
    List.iter
      (fun (bare, qualified_parent) ->
        if qualified_parent <> bare then (
          (* not already spliced (guards re-`using` / a shared bare name from
             a previous module from turning this into a self-loop) *)
          Hashtbl.replace Types.parent bare qualified_parent;
          Hashtbl.replace Types.parent (qp ^ bare) bare))
      types_to_merge

  (* `import Name: a, b` -- same merge machinery as `use_module` above, just
     filtered down to the requested bare names first: only "Name.a"/"Name.b"
     (methods, or the struct/type they belong to) get merged onto the bare
     namespace, so any OTHER thing `Name` declared stays reachable solely as
     `Name.thing`, unlike `using` which pulls in everything. *)
  let import_module modname names =
    let qp = modname ^ "." in
    let qplen = String.length qp in
    let wanted = List.mem in
    let has_wanted_prefix s =
      String.length s > qplen && String.equal (String.sub s 0 qplen) qp
      && wanted (String.sub s qplen (String.length s - qplen)) names
    in
    let bare_of s = String.sub s qplen (String.length s - qplen) in
    let methods_to_merge =
      Hashtbl.fold (fun k v acc -> if has_wanted_prefix k then (bare_of k, v) :: acc else acc) Dispatch.methods []
    in
    List.iter
      (fun (bare, ms) ->
        let existing = Option.value (Hashtbl.find_opt Dispatch.methods bare) ~default:[] in
        Hashtbl.replace Dispatch.methods bare (ms @ existing))
      methods_to_merge;
    if methods_to_merge <> [] then incr Dispatch.generation;
    let structs_to_merge =
      Hashtbl.fold (fun k v acc -> if has_wanted_prefix k then (bare_of k, v) :: acc else acc) struct_defs []
    in
    List.iter (fun (bare, sd) -> Hashtbl.replace struct_defs bare sd) structs_to_merge;
    let types_to_merge =
      Hashtbl.fold (fun k v acc -> if has_wanted_prefix k then (bare_of k, v) :: acc else acc) Types.parent []
    in
    List.iter
      (fun (bare, qualified_parent) ->
        if qualified_parent <> bare then (
          Hashtbl.replace Types.parent bare qualified_parent;
          Hashtbl.replace Types.parent (qp ^ bare) bare))
      types_to_merge

  (* --- the cross-boundary call: Matrix * Vector, computed by the Rust/faer kernel
     living in a *separate*, non-GC wasm module -- unchanged from before. --- *)
  let host_matvec (rows : float array array) (b : float array) : float array =
    let open Js_of_ocaml in
    let n = Array.length b in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri
      (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row)
      rows;
    let barr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i x -> Typed_array.set barr i (Js.float x)) b;
    let f = Js.Unsafe.get Js.Unsafe.global "host_matvec" in
    let result =
      Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject barr; Js.Unsafe.inject n |]
    in
    Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get result i))

  (* general A(m x k) * B(k x n), the LinearAlgebra-compat entry point --
     unlike host_matvec above (square-only, `n` borrowed from the vector's
     own length), the three dimensions here are independent, so a genuinely
     rectangular Matrix * Matrix (or Matrix * Vector, via k x 1) works. *)
  let host_matmul (a_rows : float array array) (b_rows : float array array) : float array array =
    let open Js_of_ocaml in
    let m = Array.length a_rows in
    let k = if m = 0 then 0 else Array.length a_rows.(0) in
    let n = if Array.length b_rows = 0 then 0 else Array.length b_rows.(0) in
    let flat_of rows rows_n cols_n =
      let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (rows_n * cols_n) |] in
      Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * cols_n) + j) (Js.float x)) row) rows;
      flat
    in
    let flat_a = flat_of a_rows m k in
    let flat_b = flat_of b_rows k n in
    let f = Js.Unsafe.get Js.Unsafe.global "host_matmul" in
    let result =
      Js.Unsafe.fun_call f
        [| Js.Unsafe.inject flat_a
         ; Js.Unsafe.inject flat_b
         ; Js.Unsafe.inject m
         ; Js.Unsafe.inject k
         ; Js.Unsafe.inject n
        |]
    in
    Array.init m (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get result ((i * n) + j))))

  (* det(A) for a square n x n Matrix -- a plain float straight back, no
     output buffer needed on either side of the FFI boundary. *)
  let host_det (rows : float array array) (n : int) : float =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_det" in
    Js.to_float (Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |])

  (* inv(A) for a square n x n Matrix. *)
  let host_inverse (rows : float array array) (n : int) : float array array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_inverse" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get result ((i * n) + j))))

  (* A \ b : solves A*x = b for a square n x n A and a length-n b. *)
  let host_solve (rows : float array array) (b : float array) (n : int) : float array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let barr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i x -> Typed_array.set barr i (Js.float x)) b;
    let f = Js.Unsafe.get Js.Unsafe.global "host_solve" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject barr; Js.Unsafe.inject n |] in
    Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get result i))

  (* rank(A) for an m x n Matrix (any shape, not just square) -- a plain Int
     straight back, via a thin SVD on the Rust side. *)
  let host_rank (rows : float array array) (m : int) (n : int) : int =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (m * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_rank" in
    int_of_float
      (Js.to_float (Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject m; Js.Unsafe.inject n |]))

  (* eigvals(A) for a (caller-verified) SYMMETRIC square n x n Matrix. *)
  let host_eigvals_symmetric (rows : float array array) (n : int) : float array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_eigvals_symmetric" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get result i))

  (* eigen(A)/eigvecs(A) for a (caller-verified) SYMMETRIC square n x n
     Matrix -- (eigenvalues, eigenvectors-as-columns). *)
  let host_eigen_symmetric (rows : float array array) (n : int) : float array * float array array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_eigen_symmetric" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    let vals = Js.Unsafe.get result 0 and vecs = Js.Unsafe.get result 1 in
    ( Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get vals i))
    , Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get vecs ((i * n) + j)))) )

  (* eigen(A)/eigvals(A)/eigvecs(A) for a GENERAL (possibly non-symmetric)
     n x n Matrix -- (eigenvalues (length n, Complex), eigenvectors-as-
     columns (n x n, Complex)). *)
  let host_eigen_general (rows : float array array) (n : int) : (float * float) array * (float * float) array array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_eigen_general" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    let vals_re = Js.Unsafe.get result 0
    and vals_im = Js.Unsafe.get result 1
    and vecs_re = Js.Unsafe.get result 2
    and vecs_im = Js.Unsafe.get result 3 in
    ( Array.init n (fun i ->
          Js.to_float (Typed_array.unsafe_get vals_re i), Js.to_float (Typed_array.unsafe_get vals_im i))
    , Array.init n (fun i ->
          Array.init n (fun j ->
              ( Js.to_float (Typed_array.unsafe_get vecs_re ((i * n) + j))
              , Js.to_float (Typed_array.unsafe_get vecs_im ((i * n) + j)) ))) )

  (* lu(A) for a square n x n Matrix -- (L (n x n), U (n x n), p (length n,
     1-based -- the Rust side hands back faer's own 0-based row permutation,
     converted here to match real Julia's `LU.p::Vector{Int}`)). *)
  let host_lu (rows : float array array) (n : int) : float array array * float array array * float array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_lu" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    let l = Js.Unsafe.get result 0 and u = Js.Unsafe.get result 1 and p = Js.Unsafe.get result 2 in
    ( Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get l ((i * n) + j))))
    , Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get u ((i * n) + j))))
    , Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get p i) +. 1.0) )

  (* qr(A) for an m x n Matrix (any shape) -- thin/economy QR, k = min(m, n):
     (Q (m x k), R (k x n)). *)
  let host_qr (rows : float array array) (m : int) (n : int) : float array array * float array array =
    let open Js_of_ocaml in
    let k = min m n in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (m * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_qr" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject m; Js.Unsafe.inject n |] in
    let q = Js.Unsafe.get result 0 and r = Js.Unsafe.get result 1 in
    ( Array.init m (fun i -> Array.init k (fun j -> Js.to_float (Typed_array.unsafe_get q ((i * k) + j))))
    , Array.init k (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get r ((i * n) + j)))) )

  (* cholesky(A) for a (caller-verified symmetric) SYMMETRIC POSITIVE-DEFINITE
     n x n Matrix -- the lower-triangular L (A == L*L'). *)
  let host_cholesky (rows : float array array) (n : int) : float array array =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_cholesky" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |] in
    Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get result ((i * n) + j))))

  (* isposdef(A) for a (caller-verified symmetric) SYMMETRIC n x n Matrix --
     attempts a Cholesky factorization and reports whether it succeeded,
     without panicking on failure the way `host_cholesky` above does. *)
  let host_is_posdef (rows : float array array) (n : int) : bool =
    let open Js_of_ocaml in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (n * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_is_posdef" in
    Js.to_float (Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject n |]) <> 0.0

  (* Internal helper for `nullspace` only -- the FULL svd's V (n x n) plus
     S (length min(m, n)). *)
  let host_svd_full_v (rows : float array array) (m : int) (n : int) : float array array * float array =
    let open Js_of_ocaml in
    let k = min m n in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (m * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_svd_full_v" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject m; Js.Unsafe.inject n |] in
    let v = Js.Unsafe.get result 0 and s = Js.Unsafe.get result 1 in
    ( Array.init n (fun i -> Array.init n (fun j -> Js.to_float (Typed_array.unsafe_get v ((i * n) + j))))
    , Array.init k (fun i -> Js.to_float (Typed_array.unsafe_get s i)) )

  (* shared by host_sparse_matvec/host_sparse_solve below -- row/col indices
     cross the FFI boundary as plain float64 (same Typed_array convention
     every other host_* function here already uses, rather than teaching
     this file a second, Int32Array-based crossing convention just for
     these two); preload.js's own `new Int32Array(...).set(...)` on the JS
     side truncates them back to real Int32 for Rust, same as JS's normal
     ToInt32 coercion on any array `.set()` call. *)
  let host_sparse_matvec (rows : int array) (cols : int array) (vals : float array) (m : int) (n : int)
      (x : float array) : float array =
    let open Js_of_ocaml in
    let nnz = Array.length vals in
    let row_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    let col_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    let val_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    Array.iteri (fun i r -> Typed_array.set row_arr i (Js.float (float_of_int r))) rows;
    Array.iteri (fun i c -> Typed_array.set col_arr i (Js.float (float_of_int c))) cols;
    Array.iteri (fun i v -> Typed_array.set val_arr i (Js.float v)) vals;
    let x_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i v -> Typed_array.set x_arr i (Js.float v)) x;
    let f = Js.Unsafe.get Js.Unsafe.global "host_sparse_matvec" in
    let result =
      Js.Unsafe.fun_call f
        [| Js.Unsafe.inject row_arr
         ; Js.Unsafe.inject col_arr
         ; Js.Unsafe.inject val_arr
         ; Js.Unsafe.inject nnz
         ; Js.Unsafe.inject m
         ; Js.Unsafe.inject n
         ; Js.Unsafe.inject x_arr
        |]
    in
    Array.init m (fun i -> Js.to_float (Typed_array.unsafe_get result i))

  let host_sparse_solve (rows : int array) (cols : int array) (vals : float array) (n : int) (b : float array)
      : float array =
    let open Js_of_ocaml in
    let nnz = Array.length vals in
    let row_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    let col_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    let val_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject nnz |] in
    Array.iteri (fun i r -> Typed_array.set row_arr i (Js.float (float_of_int r))) rows;
    Array.iteri (fun i c -> Typed_array.set col_arr i (Js.float (float_of_int c))) cols;
    Array.iteri (fun i v -> Typed_array.set val_arr i (Js.float v)) vals;
    let b_arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i v -> Typed_array.set b_arr i (Js.float v)) b;
    let f = Js.Unsafe.get Js.Unsafe.global "host_sparse_solve" in
    let result =
      Js.Unsafe.fun_call f
        [| Js.Unsafe.inject row_arr
         ; Js.Unsafe.inject col_arr
         ; Js.Unsafe.inject val_arr
         ; Js.Unsafe.inject nnz
         ; Js.Unsafe.inject n
         ; Js.Unsafe.inject b_arr
        |]
    in
    Array.init n (fun i -> Js.to_float (Typed_array.unsafe_get result i))

  (* svd(A) for an m x n Matrix (any shape) -- thin SVD, k = min(m, n):
     (U (m x k), S (length k), V (n x k, NOT V transpose)). *)
  let host_svd (rows : float array array) (m : int) (n : int)
      : float array array * float array * float array array
    =
    let open Js_of_ocaml in
    let k = min m n in
    let flat = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject (m * n) |] in
    Array.iteri (fun i row -> Array.iteri (fun j x -> Typed_array.set flat ((i * n) + j) (Js.float x)) row) rows;
    let f = Js.Unsafe.get Js.Unsafe.global "host_svd" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject flat; Js.Unsafe.inject m; Js.Unsafe.inject n |] in
    let u = Js.Unsafe.get result 0 and s = Js.Unsafe.get result 1 and v = Js.Unsafe.get result 2 in
    ( Array.init m (fun i -> Array.init k (fun j -> Js.to_float (Typed_array.unsafe_get u ((i * k) + j))))
    , Array.init k (fun i -> Js.to_float (Typed_array.unsafe_get s i))
    , Array.init n (fun i -> Array.init k (fun j -> Js.to_float (Typed_array.unsafe_get v ((i * k) + j)))) )

  let rotate2d (x : float) (y : float) (angle : float) : float * float =
    let c = cos angle and s = sin angle in
    let rot = [| [| c; -.s |]; [| s; c |] |] in
    let r = host_matvec rot [| x; y |] in
    r.(0), r.(1)

  (* experiment only, not a real language feature -- see ROADMAP.md and the
     AST-in-Rust report next to it. examples/pisum.jl's exact loop body,
     hand-ported to Rust and run there entirely: ONE FFI crossing for the
     whole computation, instead of Tsubaki's interpreter walking the AST
     5,000,000 times. *)
  let native_pisum () : float =
    let open Js_of_ocaml in
    let f = Js.Unsafe.get Js.Unsafe.global "host_pisum_native" in
    Js.to_float (Js.Unsafe.fun_call f [||])

  (* the real mechanism the experiment above led to -- runs bytecode
     compiled by the Compile module (see there) via the Rust VM, one FFI
     crossing for the whole function body, and turns its tagged (Int/
     Float/Bool) result back into a real Runtime.value. *)
  let run_bytecode (code : float array) (nslots : int) : value =
    let open Js_of_ocaml in
    let n = Array.length code in
    let arr = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i x -> Typed_array.set arr i (Js.float x)) code;
    let f = Js.Unsafe.get Js.Unsafe.global "host_run_bytecode" in
    let result = Js.Unsafe.fun_call f [| Js.Unsafe.inject arr; Js.Unsafe.inject nslots |] in
    let tag = Js.to_float (Js.Unsafe.get result 0) in
    let v = Js.to_float (Js.Unsafe.get result 1) in
    if tag = 0.0 then VInt (int_of_float v) else if tag = 1.0 then VFloat v else VBool (v <> 0.0)

  (* --- A second, separate compile target from run_bytecode above: an
     ECS-"system"-shaped function (query a set of entities, read struct
     fields, construct a new struct, call host builtins like
     get_component/add_component!) never qualifies for Compile.try_compile's
     restricted numeric ISA at all -- no structs, no strings, no function
     calls with arguments exist in that instruction set. This doesn't hoist
     anything into Rust (there is no native codegen path for structs/
     dispatch, same reason a genuine JIT was rejected for run_bytecode's own
     numeric case); the entire saving is staying inside OCaml but skipping
     Eval.eval_expr/exec_stmt's full AST-node pattern match (dozens of cases,
     most irrelevant to this shape) and Eval's environment/scope-chain walk,
     in favor of a flat locals array indexed by a slot resolved once at
     compile time. Every actual field read, struct construction, and host
     call below still goes through the exact same get_field/construct/
     Dispatch.call_cached the tree-walking interpreter itself uses --
     nothing about *how* those work is reimplemented, only *how they're
     reached* per call is made more direct. Lives here (not in Compile,
     which depends on Ast) so the AST-walking compiler in Compile can build
     a Host.program without this module ever depending on Ast -- same split
     as run_bytecode/Compile.encode just above. *)
  module Host = struct
    (* Ecs (bin/ecs.ml) depends on Runtime, not the other way around, so
       this module can't call straight into it -- the same problem, and the
       same solution, as current_kwargs/current_end/current_module_prefix
       elsewhere in this file: a side-channel ref that the OTHER module
       fills in once, at its own load time. Compile.try_compile_host
       specializes get_component/add_component!/query/... call sites
       directly to the opcodes below (see there) when it can prove, at
       compile time, that the name hasn't been given some OTHER, unrelated
       overload (Dispatch.methods has exactly the one method Ecs itself
       registered) -- bypassing Dispatch.call_cached's name/argument-type
       resolution entirely for those, not just the AST/environment overhead
       every other Host opcode already skips. *)
    (* --- where an SoA column's floats actually live -----------------------
       A Bigarray, not an OCaml `float array`. Under wasm_of_ocaml a Bigarray
       IS a JS typed array: the runtime's own bigarray.wat holds its data as an
       `(ref extern)` built by a `ta_create` call out to JS. An OCaml float
       array, by contrast, lives in the WasmGC heap, which JS cannot address at
       all -- every element has to be boxed across one at a time (measured:
       handing 100k entities' Position to JS that way costs ~6.7ms, more than
       a whole frame's budget). A column that is already a Float64Array can
       instead be laid straight over a SharedArrayBuffer and read by a worker
       with no copy at all.

       The price is that every element access is now a call out to JS. On the
       raw loop that is 12.7x (0.167ms -> 2.117ms per 100k-entity frame's worth
       of column arithmetic) -- but the interpreter around it spends 43.4ms on
       that same frame, so against the whole system it is about +4.5%. Measured
       both ways before this was written; see the SoA scale bench. *)
    type fcol = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t

    (* the presence bitmap shares a column's fate: a worker reading a column
       also has to know WHICH entities are in it, and a compiled
       HEcsSoaFieldRead checks exactly this before every read. If the floats
       are shared but the bitmap isn't, a worker sees a full column and an
       empty world. So it is a Bigarray as well -- a Uint8Array on the JS
       side, 0/1 rather than OCaml's `bool`. *)
    type bcol = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

    (* a Bigarray can be laid directly over a typed array JS already owns
       (`caml_ba_from_typed_array` is a wasm_of_ocaml runtime primitive, see its
       bigarray.wat) -- which is how a column comes to live on a
       SharedArrayBuffer: JS allocates the buffer, OCaml just points at it.
       Verified end to end before this was written: OCaml writes, a worker's JS
       reads the same bytes, no copy anywhere. *)
    external ba_of_ta : Js_of_ocaml.Js.Unsafe.any -> ('a, 'b, Bigarray.c_layout) Bigarray.Array1.t
      = "caml_ba_from_typed_array"

    external ta_of_ba : ('a, 'b, Bigarray.c_layout) Bigarray.Array1.t -> Js_of_ocaml.Js.Unsafe.any
      = "caml_ba_to_typed_array"

    (* the host allocates every column, so that it CAN be shared -- but only if
       the host offers to. A plain browser page has no SharedArrayBuffer unless
       it's cross-origin-isolated (COOP/COEP), and a bare `node` run of a test
       harness may have no host functions at all; both fall back to an ordinary
       Bigarray, which is correct in every way except that no worker can see it.
       Nothing silently half-works: parallel_each is what asks for sharing, and
       it says so plainly if it isn't there. *)
    let host_alloc (name : string) (n : int) : Js_of_ocaml.Js.Unsafe.any option =
      let open Js_of_ocaml in
      let f : Js.Unsafe.any = Js.Unsafe.get Js.Unsafe.global name in
      if Js.to_string (Js.typeof f) = "function" then Some (Js.Unsafe.fun_call f [| Js.Unsafe.inject n |]) else None

    let fcol_create (n : int) : fcol =
      match host_alloc "host_shared_f64" n with
      | Some ta -> ba_of_ta ta
      | None ->
        let c = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
        Bigarray.Array1.fill c 0.0;
        c

    let bcol_create (n : int) : bcol =
      match host_alloc "host_shared_u8" n with
      | Some ta -> ba_of_ta ta
      | None ->
        let c = Bigarray.Array1.create Bigarray.int8_unsigned Bigarray.c_layout n in
        Bigarray.Array1.fill c 0;
        c

    let bcol_get (c : bcol) (i : int) : bool = Bigarray.Array1.get c i <> 0
    let bcol_set (c : bcol) (i : int) (v : bool) : unit = Bigarray.Array1.set c i (if v then 1 else 0)

    (* --- storage identity, for the worker pool (see parallelBridge.ml) -------
       Every column is grow-on-write and doubles by ALLOCATING A NEW BUFFER. A
       worker holding a view of the old buffer would then be writing into
       memory nobody reads any more -- silently, which is the one thing this
       codebase keeps refusing to do. So two things guard it:

       - `storage_gen` counts every reallocation (and every new column). A
         worker rebinds its views whenever it sees a generation it hasn't bound
         yet, so a grow on the main thread is simply the next frame's rebind.
       - inside a worker, a grow is an ERROR rather than a silent divergence:
         the worker's fresh buffer would be its own, unshared. A parallel system
         may write components an entity ALREADY has (that's a column write, in
         shared memory) but may not spawn entities or give one a component it
         didn't have -- exactly the "systems don't change the world's shape"
         rule an ECS scheduler needs anyway. *)
    let storage_gen = ref 0
    let in_worker = ref false

    let grow_guard (what : string) =
      if !in_worker then
        failwith
          (Printf.sprintf
             "parallel system: cannot grow %s storage inside a worker -- a parallel system may only write \
              components an entity already has (no create_entity!/new component kinds). Do that on the main thread."
             what)

    (* the same grow-on-write, doubling, never-shrink policy `ensure_len` above
       applies to every other column -- a Bigarray just can't reuse it, having
       no `Array.make`/`Array.blit`. *)
    let ensure_fcol (col : fcol ref) (n : int) : unit =
      let len = Bigarray.Array1.dim !col in
      if n >= len then (
        let new_len = ref (max 1 len) in
        while n >= !new_len do
          new_len := !new_len * 2
        done;
        grow_guard "component column";
        let bigger = fcol_create !new_len in
        Bigarray.Array1.blit !col (Bigarray.Array1.sub bigger 0 len);
        col := bigger;
        incr storage_gen)

    let ensure_bcol (col : bcol ref) (n : int) : unit =
      let len = Bigarray.Array1.dim !col in
      if n >= len then (
        let new_len = ref (max 1 len) in
        while n >= !new_len do
          new_len := !new_len * 2
        done;
        grow_guard "presence bitmap";
        let bigger = bcol_create !new_len in
        Bigarray.Array1.blit !col (Bigarray.Array1.sub bigger 0 len);
        col := bigger;
        incr storage_gen)

    type ecs_hooks =
      { get_component : int -> string -> value
      ; add_component : int -> value -> unit
      ; query : string list -> int array
      ; create_entity : unit -> int
      ; destroy_entity : int -> unit
      ; has_component : int -> string -> bool
      ; remove_component : int -> string -> unit
      ; (* None if `kind` isn't SoA-eligible (see soa_eligible above) --
           otherwise the field names in declaration order, one column (see
           `fcol` below)
           ref cell per field (SAME order), and the shared presence-bitmap
           ref cell for the whole column. These are the ACTUAL mutable ref
           cells Ecs's own storage uses, not a snapshot: Compile.
           try_compile_host resolves this ONCE per compiled call site (at
           compile time) and bakes the returned ref cells directly into the
           HEcsSoaFieldRead/HEcsSoaWrite opcode below, so a later `ensure_len`
           grow (Ecs replaces a ref cell's CONTENTS, never the cell itself)
           stays visible with no re-resolution needed, ever -- same
           "resolve once, cache forever" idea as every other inline cache in
           this file. *)
        soa_column_info : string -> (string array * fcol ref array * bcol ref) option
      }

    let ecs_hooks : ecs_hooks option ref = ref None
    let register_ecs_hooks h = ecs_hooks := Some h
    let ecs () = match !ecs_hooks with Some h -> h | None -> failwith "ECS is not linked into this build"

    let as_entity_id = function
      | VInt e -> e
      | v -> failwith (Printf.sprintf "expected an Int entity id, got %s" (tag v))

    (* grows `arr` (via its ref cell, in place) until index `n` is valid --
       same helper Ecs.ensure_len provides for its own storage, duplicated
       (not shared) for the same reason Host.iterate duplicates Eval's
       iter_values_do: no dependency from this module onto Ecs. A compiled
       SoA write can't call Ecs.ensure_len directly, but needs the exact
       same grow-on-write policy since it writes straight into Ecs's own
       ref cells. *)
    let ensure_len (arr : 'a array ref) (fill : 'a) (n : int) : unit =
      let len = Array.length !arr in
      if n >= len then (
        let new_len = ref (max 1 len) in
        while n >= !new_len do
          new_len := !new_len * 2
        done;
        let bigger = Array.make !new_len fill in
        Array.blit !arr 0 bigger 0 len;
        arr := bigger)

    type hexpr =
      | HConst of value
      | HLoad of int
      | HField of hexpr * string
      | HMakeArray of hexpr list
      | HConstruct of string * hexpr list
      | HCallHost of string * hexpr list * Dispatch.call_cache
      | HBin of string * hexpr * hexpr * Dispatch.call_cache
      | HEcsGetComponent of hexpr * string
      | HEcsAddComponent of hexpr * hexpr
      | HEcsCreateEntity
      | HEcsDestroyEntity of hexpr
      | HEcsHasComponent of hexpr * string
      | HEcsRemoveComponent of hexpr * string
      | HEcsQuery of string list
      | HEcsSoaFieldRead of hexpr * fcol ref * bcol ref * string * string
        (* entity expr, this field's column ref, the column's shared
           presence ref, kind name, field name -- the last two only used
           to phrase an error if the component turns out absent *)
      | HEcsSoaWrite of hexpr * (fcol ref * hexpr) array * bcol ref
        (* entity expr, one (column ref, compiled value expr) pair per
           field IN DECLARATION ORDER, the column's shared presence ref *)

    type hstmt =
      | HAssign of int * hexpr
      | HExprStmt of hexpr
      | HIf of (hexpr * hstmt array) list * hstmt array option
      | HForEach of int * hexpr * hstmt array
      | HReturn of hexpr option

    type program = hstmt array

    exception Return_val of value

    (* the same four iterable kinds Eval.iter_values_do supports, duplicated
       (not shared) deliberately -- this module has no dependency on Eval
       (which depends on Compile, which depends on this), and the logic is
       small enough that sharing it would mean inverting that dependency
       direction just to save a dozen lines. *)
    let iterate (v : value) (f : value -> unit) : unit =
      match v with
      | VRange (a, s, b) ->
        if s = 0 then failwith "range step cannot be 0"
        else (
          let i = ref a in
          while (if s > 0 then !i <= b else !i >= b) do
            f (VInt !i);
            i := !i + s
          done)
      | VFRange (a, s, b) ->
        if s = 0.0 then failwith "range step cannot be 0"
        else (
          let count = int_of_float (Float.round ((b -. a) /. s)) in
          for i = 0 to count do
            f (VFloat (a +. (float_of_int i *. s)))
          done)
      | VVec r -> Array.iter (fun x -> f (VFloat x)) (vecbuf_to_array r)
      | VArr { cells; _ } -> Array.iter f (arrbuf_to_array cells)
      | _ -> failwith "expected a Range, Vector, or Array to iterate"

    let rec eval_expr (locals : value array) (e : hexpr) : value =
      match e with
      | HConst v -> v
      | HLoad slot -> locals.(slot)
      | HField (obj, name) -> get_field (eval_expr locals obj) name
      | HMakeArray es -> mk_arr (Array.of_list (List.map (eval_expr locals) es))
      | HConstruct (name, es) -> construct name (List.map (eval_expr locals) es)
      | HCallHost (name, es, cache) -> Dispatch.call_cached cache name (List.map (eval_expr locals) es)
      | HBin (op, a, b, cache) -> Dispatch.call_cached cache op [ eval_expr locals a; eval_expr locals b ]
      | HEcsGetComponent (e, kind) -> (ecs ()).get_component (as_entity_id (eval_expr locals e)) kind
      | HEcsAddComponent (e, c) ->
        (ecs ()).add_component (as_entity_id (eval_expr locals e)) (eval_expr locals c);
        VNothing
      | HEcsCreateEntity -> VInt ((ecs ()).create_entity ())
      | HEcsDestroyEntity e ->
        (ecs ()).destroy_entity (as_entity_id (eval_expr locals e));
        VNothing
      | HEcsHasComponent (e, kind) -> VBool ((ecs ()).has_component (as_entity_id (eval_expr locals e)) kind)
      | HEcsRemoveComponent (e, kind) ->
        (ecs ()).remove_component (as_entity_id (eval_expr locals e)) kind;
        VNothing
      | HEcsQuery kinds -> mk_arr (Array.map (fun e -> VInt e) ((ecs ()).query kinds))
      | HEcsSoaFieldRead (e, col, present, kind, field) ->
        let eid = as_entity_id (eval_expr locals e) in
        if eid < Bigarray.Array1.dim !present && eid < Bigarray.Array1.dim !col && bcol_get !present eid then
          VFloat (Bigarray.Array1.get !col eid)
        else failwith (Printf.sprintf "type %s has no field %s (component not present on this entity)" kind field)
      | HEcsSoaWrite (e, field_writes, present) ->
        let eid = as_entity_id (eval_expr locals e) in
        Array.iter
          (fun (col, val_e) ->
            let v =
              match eval_expr locals val_e with
              | VFloat f -> f
              | VInt n -> float_of_int n
              | v -> failwith (Printf.sprintf "expected a number, got %s" (tag v))
            in
            ensure_fcol col eid;
            Bigarray.Array1.set !col eid v)
          field_writes;
        ensure_bcol present eid;
        bcol_set !present eid true;
        VNothing

    let rec exec_stmt (locals : value array) (s : hstmt) : unit =
      match s with
      | HAssign (slot, e) -> locals.(slot) <- eval_expr locals e
      | HExprStmt e -> ignore (eval_expr locals e)
      | HIf (branches, else_body) ->
        let rec go = function
          | [] -> (
            match else_body with
            | Some b -> exec_stmts locals b
            | None -> ())
          | (cond, body) :: rest -> (
            match eval_expr locals cond with
            | VBool true -> exec_stmts locals body
            | VBool false -> go rest
            | v -> failwith (Printf.sprintf "expected a Bool, got %s" (tag v)))
        in
        go branches
      | HForEach (slot, iter_e, body) ->
        let v = eval_expr locals iter_e in
        iterate v (fun item ->
          locals.(slot) <- item;
          exec_stmts locals body)
      | HReturn e -> raise (Return_val (match e with Some e -> eval_expr locals e | None -> VNothing))

    and exec_stmts locals stmts = Array.iter (exec_stmt locals) stmts

    let run (prog : program) (nslots : int) : value =
      let locals = Array.make nslots VNothing in
      try
        exec_stmts locals prog;
        VNothing
      with Return_val v -> v
  end

  (* a JIT-style compile cache for `function` declarations: allocated once
     at PARSE time (see Parser), attached to this exact declaration SITE,
     and reused across every EVALUATION of it -- same idea as var_cache
     above. Compile.try_compile/try_compile_host only need to run once per
     declaration site, not once per evaluation: a function declared inside a
     loop body (or inside another function, re-declared on every call) has
     the exact same AST body every time, so the eligibility decision and any
     resulting bytecode can never change and are worth remembering rather
     than recomputing. Two independent compiled forms can apply to the same
     site now: FC_compiled (Compile's restricted numeric ISA, run_bytecode,
     crosses into Rust) is tried first (best win for pure arithmetic, see
     AST_IN_RUST_EXPERIMENT.md); FC_host_compiled (Host, just above) is the
     fallback for the ECS/struct/host-call shape that numeric compilation
     can never accept, and never leaves OCaml at all. Stores the
     ALREADY-ENCODED forms (a plain float array for the former, a
     Host.program for the latter) rather than Compile's own instr array
     type, so this module doesn't need to depend on Compile (which depends
     on Ast, which depends on this) at all. *)
  type funcdecl_cache_state =
    | FC_unattempted
    | FC_compiled of float array * int (* encoded bytecode, nslots *)
    | FC_host_compiled of Host.program * int (* program, nslots *)
    | FC_ineligible

  type funcdecl_cache = { mutable fc_state : funcdecl_cache_state }

  let new_funcdecl_cache () : funcdecl_cache = { fc_state = FC_unattempted }

  (* --- built-in operators/functions, registered the same way user `function`
     declarations are -- there is no privileged syntax, "+" is just a name. --- *)
  let () =
    let num2 name intop floatop =
      Dispatch.defmethod name [ [ "Int" ]; [ "Int" ] ] (function
        | [ VInt a; VInt b ] -> intop a b
        | _ -> assert false);
      Dispatch.defmethod name [ [ "Float" ]; [ "Float" ] ] (function
        | [ VFloat a; VFloat b ] -> floatop a b
        | _ -> assert false);
      Dispatch.defmethod name [ [ "Number" ]; [ "Number" ] ] (function
        | [ a; b ] -> floatop (as_float a) (as_float b)
        | _ -> assert false)
    in
    num2 "+" (fun a b -> VInt (a + b)) (fun a b -> VFloat (a +. b));
    num2 "-" (fun a b -> VInt (a - b)) (fun a b -> VFloat (a -. b));
    num2 "*" (fun a b -> VInt (a * b)) (fun a b -> VFloat (a *. b));
    num2 "/" (fun a b -> VFloat (float_of_int a /. float_of_int b)) (fun a b -> VFloat (a /. b));
    num2 "%" (fun a b -> VInt (a mod b)) (fun a b -> VFloat (Float.rem a b));
    (* mod(x,y): unlike `%` (truncated remainder, sign follows x), real
       Julia's mod is FLOORED -- sign follows y (or zero). `a mod b`/
       `Float.rem` above already gave us the truncated remainder; nudge it
       by one `b` when its sign disagrees with `b`'s. *)
    num2 "mod"
      (fun a b ->
        let r = a mod b in
        VInt (if r <> 0 && (r < 0) <> (b < 0) then r + b else r))
      (fun a b ->
        let r = Float.rem a b in
        VFloat (if r <> 0.0 && (r < 0.0) <> (b < 0.0) then r +. b else r));
    (* logical not -- see Parser.parse_unary for why `!x` is just an
       ordinary call to this, not a dedicated AST node *)
    Dispatch.defmethod "!" [ [ "Bool" ] ] (function
      | [ VBool b ] -> VBool (not b)
      | _ -> assert false);
    (* logical (unsigned) right shift -- Int-only, matching how real Julia's
       >>> is actually used in practice (midpoint index computation etc.) *)
    Dispatch.defmethod ">>>" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a lsr b)
      | _ -> assert false);
    (* plain (sign-preserving/arithmetic) shifts -- `<<` is direction-
       agnostic between logical/arithmetic (no sign bit to preserve when
       shifting left), `>>` is real Julia's own arithmetic right shift,
       distinct from `>>>`'s logical one above *)
    Dispatch.defmethod "<<" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a lsl b)
      | _ -> assert false);
    Dispatch.defmethod ">>" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a asr b)
      | _ -> assert false);
    (* Bitwise Int / logical (non-short-circuit) Bool `&`/`|`/`⊻` -- real
       Julia gives these arithmetic-like precedence (see Parser.prec), not
       `&&`/`||`'s, and they work on both Int and Bool *)
    Dispatch.defmethod "&" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a land b)
      | _ -> assert false);
    Dispatch.defmethod "&" [ [ "Bool" ]; [ "Bool" ] ] (function
      | [ VBool a; VBool b ] -> VBool (a && b)
      | _ -> assert false);
    Dispatch.defmethod "|" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a lor b)
      | _ -> assert false);
    Dispatch.defmethod "|" [ [ "Bool" ]; [ "Bool" ] ] (function
      | [ VBool a; VBool b ] -> VBool (a || b)
      | _ -> assert false);
    Dispatch.defmethod "\xe2\x8a\xbb" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a lxor b)
      | _ -> assert false);
    Dispatch.defmethod "\xe2\x8a\xbb" [ [ "Bool" ]; [ "Bool" ] ] (function
      | [ VBool a; VBool b ] -> VBool (a <> b)
      | _ -> assert false);
    (* Fixed-width integers (Int8/Int16/Int32/UInt8/UInt16/UInt32): a
       CHECKED, real-Julia-style conversion constructor (`UInt8(x)` raises
       InexactError for a non-integral or out-of-range `x`, exactly the way
       real Julia's own `T(x)` does -- silent truncation is a SEPARATE
       operation in real Julia, `x % T`, not attempted here) plus wrapping
       (overflow-silent) same-type arithmetic. *)
    let def_fixed_conv name bits signed =
      Dispatch.defmethod name [ [ "Number" ] ] (function
        | [ x ] ->
          let f = as_float x in
          let i = int_of_float f in
          if float_of_int i <> f then
            failwith (Printf.sprintf "InexactError: %s(%s) is not an exact integer" name (show x));
          let wrapped = wrap_fixed bits signed i in
          if wrapped <> i then
            failwith (Printf.sprintf "InexactError: %s: %d out of range" name i);
          VFixedInt { bits; signed; v = i }
        | _ -> assert false)
    in
    let fixed_int_ops bits signed =
      let t = fixed_int_tag bits signed in
      let wrap v = wrap_fixed bits signed v in
      let un2 name f =
        Dispatch.defmethod name [ [ t ]; [ t ] ] (function
          | [ VFixedInt { v = a; _ }; VFixedInt { v = b; _ } ] -> VFixedInt { bits; signed; v = wrap (f a b) }
          | _ -> assert false)
      in
      let cmp2 name f =
        Dispatch.defmethod name [ [ t ]; [ t ] ] (function
          | [ VFixedInt { v = a; _ }; VFixedInt { v = b; _ } ] -> VBool (f a b)
          | _ -> assert false)
      in
      un2 "+" ( + );
      un2 "-" ( - );
      un2 "*" ( * );
      un2 "%" ( mod );
      Dispatch.defmethod "/" [ [ t ]; [ t ] ] (function
        | [ VFixedInt { v = a; _ }; VFixedInt { v = b; _ } ] -> VFloat (float_of_int a /. float_of_int b)
        | _ -> assert false);
      cmp2 "==" ( = );
      cmp2 "!=" ( <> );
      cmp2 "<" ( < );
      cmp2 "<=" ( <= );
      cmp2 ">" ( > );
      cmp2 ">=" ( >= )
    in
    List.iter
      (fun (name, bits, signed) ->
        def_fixed_conv name bits signed;
        fixed_int_ops bits signed)
      [ "Int8", 8, true
      ; "Int16", 16, true
      ; "Int32", 32, true
      ; "UInt8", 8, false
      ; "UInt16", 16, false
      ; "UInt32", 32, false
      ];
    (* Int(x): the native Int tag itself was missing from the loop just
       above (that one only covers the FIXED-width Int8/UInt32/etc family)
       -- same real-Julia "InexactError on non-integral input" contract as
       those, just without a bit-width wrap since VInt already IS this
       platform's native int. *)
    Dispatch.defmethod "Int" [ [ "Number" ] ] (function
      | [ VInt n ] -> VInt n
      | [ x ] ->
        let f = as_float x in
        let i = int_of_float f in
        if float_of_int i <> f then failwith (Printf.sprintf "InexactError: Int(%s) is not an exact integer" (show x));
        VInt i
      | _ -> assert false);
    (* Complex arithmetic, only for mandelperf's needs: +, -, * and ^ with a
       non-negative Int exponent (repeated multiplication -- no general
       floating-point power here, mandel only ever squares) *)
    Dispatch.defmethod "+" [ [ "Complex" ]; [ "Complex" ] ] (function
      | [ VComplex (ar, ai); VComplex (br, bi) ] -> VComplex (ar +. br, ai +. bi)
      | _ -> assert false);
    Dispatch.defmethod "-" [ [ "Complex" ]; [ "Complex" ] ] (function
      | [ VComplex (ar, ai); VComplex (br, bi) ] -> VComplex (ar -. br, ai -. bi)
      | _ -> assert false);
    Dispatch.defmethod "*" [ [ "Complex" ]; [ "Complex" ] ] (function
      | [ VComplex (ar, ai); VComplex (br, bi) ] -> VComplex ((ar *. br) -. (ai *. bi), (ar *. bi) +. (ai *. br))
      | _ -> assert false);
    Dispatch.defmethod "^" [ [ "Complex" ]; [ "Int" ] ] (function
      | [ VComplex (re, im); VInt n ] ->
        let rec go (ar, ai) k =
          if k <= 0 then ar, ai
          else go ((ar *. re) -. (ai *. im), (ar *. im) +. (ai *. re)) (k - 1)
        in
        let rr, ri = go (1.0, 0.0) n in
        VComplex (rr, ri)
      | _ -> assert false);
    (* Int^Int: repeated squaring, same as real Julia -- and, matching real
       Julia exactly, a negative exponent is a DomainError (an Int base
       can't represent the fractional result; write Float^Int instead). *)
    Dispatch.defmethod "^" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt _; VInt e ] when e < 0 ->
        failwith
          (Printf.sprintf "DomainError: Cannot raise an integer x to a negative power %d" e)
      | [ VInt b; VInt e ] ->
        let rec ipow b e =
          if e = 0 then 1
          else (
            let half = ipow b (e / 2) in
            let half2 = half * half in
            if e mod 2 = 0 then half2 else half2 * b)
        in
        VInt (ipow b e)
      | _ -> assert false);
    Dispatch.defmethod "^" [ [ "Float" ]; [ "Int" ] ] (function
      | [ VFloat b; VInt e ] -> VFloat (b ** float_of_int e)
      | _ -> assert false);
    Dispatch.defmethod "^" [ [ "Float" ]; [ "Float" ] ] (function
      | [ VFloat b; VFloat e ] -> VFloat (b ** e)
      | _ -> assert false);
    Dispatch.defmethod "^" [ [ "Number" ]; [ "Number" ] ] (function
      | [ a; b ] -> VFloat (as_float a ** as_float b)
      | _ -> assert false);
    Dispatch.defmethod "abs" [ [ "Int" ] ] (function
      | [ VInt a ] -> VInt (abs a)
      | _ -> assert false);
    Dispatch.defmethod "abs" [ [ "Float" ] ] (function
      | [ VFloat a ] -> VFloat (Float.abs a)
      | _ -> assert false);
    Dispatch.defmethod "abs" [ [ "Complex" ] ] (function
      | [ VComplex (re, im) ] -> VFloat (Float.hypot re im)
      | _ -> assert false);
    Dispatch.defmethod "complex" [ [ "Float" ]; [ "Float" ] ] (function
      | [ VFloat re; VFloat im ] -> VComplex (re, im)
      | _ -> assert false);
    Dispatch.defmethod "complex" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt re; VInt im ] -> VComplex (float_of_int re, float_of_int im)
      | _ -> assert false);
    Dispatch.defmethod "real" [ [ "Complex" ] ] (function
      | [ VComplex (re, _) ] -> VFloat re
      | _ -> assert false);
    Dispatch.defmethod "imag" [ [ "Complex" ] ] (function
      | [ VComplex (_, im) ] -> VFloat im
      | _ -> assert false);
    (* Rational -- `n // d` (and the equivalent `Rational(n, d)` constructor
       spelling) plus exact +/-/*//==/comparisons against another Rational
       OR a plain Int (promoted to n/1, kept exact -- NOT routed through
       `as_float`, unlike the generic `Number,Number` fallback `num2`
       registers, which would silently downgrade to Float and is only ever
       reached here for a Float operand, matching real Julia's own
       Float64+Rational -> Float64 promotion). *)
    Dispatch.defmethod "//" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt n; VInt d ] -> mk_rational n d
      | _ -> assert false);
    Dispatch.defmethod "Rational" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt n; VInt d ] -> mk_rational n d
      | _ -> assert false);
    (let as_pair = function
       | VRational (n, d) -> n, d
       | VInt n -> n, 1
       | v -> failwith (Printf.sprintf "expected a Rational or Int, got %s" (tag v))
     in
     let rat_op name (f : int * int -> int * int -> value) =
       Dispatch.defmethod name [ [ "Rational" ]; [ "Rational" ] ] (function
         | [ a; b ] -> f (as_pair a) (as_pair b)
         | _ -> assert false);
       Dispatch.defmethod name [ [ "Int" ]; [ "Rational" ] ] (function
         | [ a; b ] -> f (as_pair a) (as_pair b)
         | _ -> assert false);
       Dispatch.defmethod name [ [ "Rational" ]; [ "Int" ] ] (function
         | [ a; b ] -> f (as_pair a) (as_pair b)
         | _ -> assert false)
     in
     rat_op "+" (fun (an, ad) (bn, bd) -> mk_rational ((an * bd) + (bn * ad)) (ad * bd));
     rat_op "-" (fun (an, ad) (bn, bd) -> mk_rational ((an * bd) - (bn * ad)) (ad * bd));
     rat_op "*" (fun (an, ad) (bn, bd) -> mk_rational (an * bn) (ad * bd));
     rat_op "/" (fun (an, ad) (bn, bd) -> mk_rational (an * bd) (ad * bn));
     (* denominators are always strictly positive by mk_rational's own
        invariant, so a plain cross-multiply, with no sign correction, is a
        valid order-preserving comparison for both equality and ordering *)
     rat_op "==" (fun (an, ad) (bn, bd) -> VBool ((an * bd) = (bn * ad)));
     rat_op "!=" (fun (an, ad) (bn, bd) -> VBool ((an * bd) <> (bn * ad)));
     rat_op "<" (fun (an, ad) (bn, bd) -> VBool ((an * bd) < (bn * ad)));
     rat_op "<=" (fun (an, ad) (bn, bd) -> VBool ((an * bd) <= (bn * ad)));
     rat_op ">" (fun (an, ad) (bn, bd) -> VBool ((an * bd) > (bn * ad)));
     rat_op ">=" (fun (an, ad) (bn, bd) -> VBool ((an * bd) >= (bn * ad))));
    Dispatch.defmethod "abs" [ [ "Rational" ] ] (function
      | [ VRational (n, d) ] -> VRational (abs n, d)
      | _ -> assert false);
    Dispatch.defmethod "numerator" [ [ "Rational" ] ] (function
      | [ VRational (n, _) ] -> VInt n
      | _ -> assert false);
    Dispatch.defmethod "denominator" [ [ "Rational" ] ] (function
      | [ VRational (_, d) ] -> VInt d
      | _ -> assert false);
    Dispatch.defmethod "numerator" [ [ "Int" ] ] (function
      | [ VInt n ] -> VInt n
      | _ -> assert false);
    Dispatch.defmethod "denominator" [ [ "Int" ] ] (function
      | [ VInt _ ] -> VInt 1
      | _ -> assert false);
    num2 "<" (fun a b -> VBool (a < b)) (fun a b -> VBool (a < b));
    num2 "<=" (fun a b -> VBool (a <= b)) (fun a b -> VBool (a <= b));
    num2 ">" (fun a b -> VBool (a > b)) (fun a b -> VBool (a > b));
    num2 ">=" (fun a b -> VBool (a >= b)) (fun a b -> VBool (a >= b));
    num2 "==" (fun a b -> VBool (a = b)) (fun a b -> VBool (a = b));
    num2 "!=" (fun a b -> VBool (a <> b)) (fun a b -> VBool (a <> b));
    (* String support: concatenation via "+" too, same name, different signature *)
    Dispatch.defmethod "+" [ [ "String" ]; [ "String" ] ] (function
      | [ VStr a; VStr b ] -> VStr (a ^ b)
      | _ -> assert false);
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
    Dispatch.defmethod "sqrt" [ [ "Float" ] ] (function
      | [ VFloat f ] -> VFloat (sqrt f)
      | _ -> assert false);
    Dispatch.defmethod "sqrt" [ [ "Int" ] ] (function
      | [ VInt n ] -> VFloat (sqrt (float_of_int n))
      | _ -> assert false);
    (* trig/general math -- thin wrappers over OCaml's own Stdlib, same
       "Number" + as_float convention `def_fixed_conv`/`^` above already use
       (accepts Int or Float uniformly, one overload instead of two). Real
       Julia's `atan(y, x)` two-arg form IS its own `atan2` (no separate
       name) -- kept as a distinct `atan2` here too, since that's what
       `rotate2d` above and every other C-family/WGSL caller already expects
       to type. *)
    let def_math1 name f = Dispatch.defmethod name [ [ "Number" ] ] (function [ x ] -> VFloat (f (as_float x)) | _ -> assert false) in
    def_math1 "cos" cos;
    def_math1 "sin" sin;
    def_math1 "tan" tan;
    def_math1 "asin" asin;
    def_math1 "acos" acos;
    def_math1 "atan" atan;
    def_math1 "exp" exp;
    def_math1 "log" log;
    def_math1 "floor" floor;
    def_math1 "ceil" ceil;
    def_math1 "round" Float.round;
    Dispatch.defmethod "atan2" [ [ "Number" ]; [ "Number" ] ] (function
      | [ y; x ] -> VFloat (atan2 (as_float y) (as_float x))
      | _ -> assert false);
    Dispatch.defmethod "hypot" [ [ "Number" ]; [ "Number" ] ] (function
      | [ a; b ] -> VFloat (Float.hypot (as_float a) (as_float b))
      | _ -> assert false);
    (* push! : Vector, Number -> Vector -- amortized O(1): vecbuf_push only
       reallocates (doubling capacity) when the backing array is actually
       full, not on every single push (see vecbuf's own comment). *)
    Dispatch.defmethod "push!" [ [ "Vector" ]; [ "Float" ] ] (function
      | [ VVec r; VFloat x ] ->
        vecbuf_push r x;
        VVec r
      | _ -> assert false);
    Dispatch.defmethod "push!" [ [ "Vector" ]; [ "Int" ] ] (function
      | [ VVec r; VInt x ] ->
        vecbuf_push r (float_of_int x);
        VVec r
      | _ -> assert false);
    (* offset_xy(vec, dx, dy): adds (dx, dy) to every (x, y) pair in a flat
       Vector -- one OCaml pass, non-mutating (matches +/- on VVec, which
       already build a fresh vecbuf rather than writing through). The actual
       motivating use: rebasing large-magnitude world coordinates (UTM-style
       meters, hundreds of thousands) onto a small LOCAL origin BEFORE they
       ever cross into a GPU buffer -- WebGPU has no f64 buffer type at all
       (see README's own "Only f32" note), so a raw large coordinate loses
       real precision the instant `write_buffer` narrows it; the same small
       numbers this produces are also just what a `soa_flatten`-fed camera
       shader wants to receive (see `examples/ecs_gpu_camera.jl`). Works on
       ANY flat Vector of (x, y) pairs, not just one from `soa_flatten` --
       no ECS dependency here. *)
    Dispatch.defmethod "offset_xy" [ [ "Vector" ]; [ "Number" ]; [ "Number" ] ] (function
      | [ VVec v; dx; dy ] ->
        let dx = as_float dx and dy = as_float dy in
        let src = vecbuf_to_array v in
        let n = Array.length src in
        let out = Array.make n 0.0 in
        let i = ref 0 in
        while !i < n do
          out.(!i) <- src.(!i) +. dx;
          if !i + 1 < n then out.(!i + 1) <- src.(!i + 1) +. dy;
          i := !i + 2
        done;
        VVec (vecbuf_of_array out)
      | _ -> assert false);
    (* rotate(Vec2-shaped struct, angle) -- Vec2 is a user struct (declared in
       source), but this builtin is happy to work on any struct with x/y fields *)
    Dispatch.defmethod "rotate" [ [ "Vec2" ]; [ "Float" ] ] (function
      | [ v; VFloat a ] ->
        let x = as_float (get_field v "x") and y = as_float (get_field v "y") in
        let rx, ry = rotate2d x y a in
        construct "Vec2" [ VFloat rx; VFloat ry ]
      | _ -> assert false);
    Dispatch.defmethod "error" [ [ "String" ] ] (function
      | [ VStr s ] -> raise (JuliaError (construct "ErrorException" [ VStr s ]))
      | _ -> assert false);
    (* throw(x) -- unlike error, takes ANY value, not just a message string
       (real Julia code very commonly does `throw(ArgumentError("..."))`,
       found running JuliaMath/Primes.jl -- Tsubaki has no exception TYPE
       hierarchy of its own, see ROADMAP.md's honest-limits section for why
       that's a real gap, not just this one function). JuliaError already
       carries an arbitrary value, so this is just raising it directly. *)
    Dispatch.defmethod "throw" [ [ "Any" ] ] (function
      | [ v ] -> raise (JuliaError v)
      | _ -> assert false);
    (* divrem/isqrt/widemul -- three small missing builtins, also found
       running Primes.jl. widemul is NOT actually widened (no arbitrary-
       precision integer type here) -- a disclosed approximation, plain
       multiplication, correct as long as the true product still fits in
       a normal Int. *)
    Dispatch.defmethod "divrem" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VTuple [| VInt (a / b); VInt (a mod b) |]
      | _ -> assert false);
    Dispatch.defmethod "isqrt" [ [ "Int" ] ] (function
      | [ VInt n ] ->
        let r = int_of_float (sqrt (float_of_int n)) in
        (* sqrt is correctly-rounded IEEE 754, but truncating it to an Int
           can still land one off for a perfect square right at a float
           precision boundary -- nudge back onto the true floor *)
        let r = if (r + 1) * (r + 1) <= n then r + 1 else r in
        let r = if r * r > n then r - 1 else r in
        VInt r
      | _ -> assert false);
    Dispatch.defmethod "widemul" [ [ "Int" ]; [ "Int" ] ] (function
      | [ VInt a; VInt b ] -> VInt (a * b)
      | _ -> assert false);
    Dispatch.defmethod "length" [ [ "Vector" ] ] (function
      | [ VVec r ] -> VInt (vecbuf_length r)
      | _ -> assert false);
    (* push!/length for Array (holds any value, e.g. a Vector of structs) --
       same amortized-growth trick as the numeric Vector overloads above
       (see arrbuf_push). A DECLARED Array (built via the real
       `Array{T}()` constructor) enforces its element type here, the same
       TypeError a struct field's declared type already gets on
       assignment -- an inferred (declared = None) Array stays permissive,
       same as before. *)
    Dispatch.defmethod "push!" [ [ "Array" ]; [ "Any" ] ] (function
      | [ VArr { declared; cells }; x ] ->
        (match declared with
        | Some t when not (Dispatch.matches_alt (tag x) [ t ]) ->
          failwith (Printf.sprintf "TypeError: Array{%s} cannot hold a %s" t (tag x))
        | _ -> ());
        let before = cells.atag in
        arrbuf_push cells x;
        (* keep the inferred element tag instead of forcing a full rescan on
           the next call -- see arrbuf_retag_after_push. This is what keeps
           `for ... push!(xs, x)` linear now that a plain `[]` is an Array. *)
        arrbuf_retag_after_push tag cells before x;
        VArr { declared; cells }
      | _ -> assert false);
    Dispatch.defmethod "length" [ [ "Array" ] ] (function
      | [ VArr { cells; _ } ] -> VInt (arrbuf_length cells)
      | _ -> assert false);
    (* Vector(x::Array)/Array(x::Vector): the missing interop between
       Runtime's two collection types -- VVec (flat numeric, what
       draw_rects/get_data/put_data/push!'s fast path all want) and VArr
       (holds anything, what `query`/comprehensions/plain `[]` literals
       holding non-numeric elements produce). Without these, code that
       assembled a numeric result via the general Array machinery (or vice
       versa) had no way to hand it to a Vector-only builtin short of
       rebuilding it by hand with a loop. Vector(x) requires every element
       to actually be a Number -- same InexactError-style "say exactly what
       was wrong" contract as Int(x) above, not a silent skip/coerce. *)
    Dispatch.defmethod "Vector" [ [ "Array" ] ] (function
      | [ VArr { cells; _ } ] ->
        VVec
          (vecbuf_of_array
             (Array.map
                (function
                  | VInt n -> float_of_int n
                  | VFloat f -> f
                  | v -> failwith (Printf.sprintf "Vector(x): every element must be a Number, got a %s" (tag v)))
                (arrbuf_to_array cells)))
      | _ -> assert false);
    Dispatch.defmethod "Array" [ [ "Vector" ] ] (function
      | [ VVec v ] -> VArr { declared = None; cells = arrbuf_of_array (Array.map (fun x -> VFloat x) (vecbuf_to_array v)) }
      | _ -> assert false);
    (* used by string interpolation ("hi $name") to stringify any value *)
    Dispatch.defmethod "string" [ [ "Any" ] ] (function
      | [ v ] -> VStr (show v)
      | _ -> assert false);
    (* string(sym) -- the BARE name, no leading ":" (real Julia's own
       `string(:foo) == "foo"`, unlike `show`'s `":foo"` display form,
       which is what the generic Any overload above would otherwise give a
       Symbol) -- what a macro body needs to turn a quoted type/field name
       back into the plain String get_component/query etc. actually want. *)
    Dispatch.defmethod "string" [ [ "Symbol" ] ] (function
      | [ VSymbol (name, _) ] -> VStr name
      | _ -> assert false);
    Dispatch.defmethod "lowercase" [ [ "String" ] ] (function
      | [ VStr s ] -> VStr (String.lowercase_ascii s)
      | _ -> assert false);
    (* Expr(head, args) -- real Julia's own quoted-syntax constructor,
       letting a macro body BUILD new quoted syntax (not just inspect what
       it was handed via .head/.args above) -- e.g. Expr(:call, [:query, ...]). *)
    Dispatch.defmethod "Expr" [ [ "Symbol" ]; [ "Array" ] ] (function
      | [ VSymbol (head, _); VArr { cells; _ } ] -> VExpr { head; args = arrbuf_to_array cells }
      | _ -> assert false);
    (* Symbol(s) -- the inverse of string(sym): wrap a plain String back
       into a Symbol, e.g. to build an EVar/field-name/binding target from
       a name a macro computed at expansion time (see e.g. `lowercase`d
       component-kind names becoming local variable names). Not tagged with
       any hygiene id (`None`) -- same as any other value a macro computes
       and splices in, it resolves at the call site, same as $-interpolation
       or esc() would. *)
    Dispatch.defmethod "Symbol" [ [ "String" ] ] (function
      | [ VStr s ] -> VSymbol (s, None)
      | _ -> assert false);
    (* vcat(a, b) : Array, Array -> Array -- lets a macro body prepend/append
       quoted statements (e.g. new component bindings ahead of the caller's
       original loop body) instead of only ever splicing exactly one thing
       in unexamined. *)
    Dispatch.defmethod "vcat" [ [ "Array" ]; [ "Array" ] ] (function
      | [ VArr { cells = c1; _ }; VArr { cells = c2; _ } ] ->
        mk_arr (Array.append (arrbuf_to_array c1) (arrbuf_to_array c2))
      | _ -> assert false);
    (* for benchmarking: wall/CPU seconds since program start, and a couple of
       real Julia's `rand` overloads (plain -> one Float in [0,1), rand(n) ->
       an n-element Vector of them, matching real Julia's rand(n::Int)) *)
    Dispatch.defmethod "time" [] (fun _ -> VFloat (Sys.time ()));
    (* experiment only -- see native_pisum's own comment *)
    Dispatch.defmethod "native_pisum" [] (fun _ -> VFloat (native_pisum ()));
    Dispatch.defmethod "rand" [] (fun _ -> VFloat (Random.float 1.0));
    Dispatch.defmethod "rand" [ [ "Int" ] ] (function
      | [ VInt n ] -> VVec (vecbuf_of_array (Array.init n (fun _ -> Random.float 1.0)))
      | _ -> assert false);
    (* macro-writing builtins: gensym() for a fresh, guaranteed-unique
       Symbol (untagged -- its whole point is that the raw name is already
       unique, so it passes through hygiene renaming unchanged); esc(x) to
       opt part of a macro's expansion out of hygiene *)
    Dispatch.defmethod "gensym" [] (fun _ ->
        VSymbol (Printf.sprintf "##gensym#%d" (new_hygiene_id ()), None));
    Dispatch.defmethod "gensym" [ [ "String" ] ] (function
      | [ VStr base ] -> VSymbol (Printf.sprintf "##%s#%d" base (new_hygiene_id ()), None)
      | _ -> assert false);
    Dispatch.defmethod "esc" [ [ "Any" ] ] (function [ v ] -> esc_value v | _ -> assert false);

    (* ==================== Base: the collection vocabulary ====================
       max/min/clamp, and map/filter/sort/any/all/count/sum/maximum/minimum/
       pop! over the same four iterables `for` itself already walks (Range,
       Vector, Array, Tuple).

       These were all missing, and their absence didn't read as "a small
       standard library" -- it read as the language being unable to say
       ordinary things. Keeping a paddle on screen took two `if`s. keel's own
       `despawn!` rebuilds its node list with a hand-written loop, and says so
       in a comment, because there was no `filter` to call. Every one of them
       is a few lines here and was being re-written by hand at each call site
       instead, which is as close to a definition of "belongs in Base" as it
       gets.

       Two conventions hold throughout:
       - a callback is any `Function` value: a lambda, or -- now -- a named
         function used as a value (`filter(fell, balls)`, see Eval's EVar case)
       - ordering and equality go through Tsubaki's OWN `<`/`==` dispatch, never
         OCaml's polymorphic compare, so a user's `<` on their own struct is
         what `sort`/`maximum` actually use. *)
    let elements (v : value) : value array =
      match v with
      | VVec r -> Array.map (fun x -> VFloat x) (vecbuf_to_array r)
      | VArr { cells; _ } -> arrbuf_to_array cells
      | VTuple t -> Array.copy t
      | VDict d -> Array.of_list (List.map (fun (k, v) -> VTuple [| k; v |]) (dict_pairs d))
      | VRange (a, s, b) ->
        if s = 0 then failwith "range step cannot be 0";
        let n = if (s > 0 && a > b) || (s < 0 && a < b) then 0 else ((b - a) / s) + 1 in
        Array.init n (fun i -> VInt (a + (i * s)))
      | VFRange (a, s, b) ->
        if s = 0.0 then failwith "range step cannot be 0";
        let n = int_of_float (floor (((b -. a) /. s) +. 1e-9)) + 1 in
        let n = if n < 0 then 0 else n in
        Array.init n (fun i -> VFloat (a +. (float_of_int i *. s)))
      | v -> failwith (Printf.sprintf "expected a Vector, Array, Range or Tuple, got a %s" (tag v))
    in
    (* Rebuild in the shape the input had: a numeric Vector (or Range) maps to
       a numeric Vector, so the result still fits every Vector-only builtin
       (draw_rects, matvec) without a conversion; a DECLARED Array{Ball} whose
       elements are all still Balls stays an Array{Ball}, which is what makes
       `filter` a drop-in for keel's hand-rolled rebuild loop; anything else is
       a general Array. *)
    let rebuild (src : value) (vs : value array) : value =
      let all_numeric = Array.for_all (function VInt _ | VFloat _ -> true | _ -> false) vs in
      let all_pairs = Array.for_all (function VTuple [| _; _ |] -> true | _ -> false) vs in
      match src with
      | (VVec _ | VRange _ | VFRange _) when all_numeric -> VVec (vecbuf_of_array (Array.map as_float vs))
      | VArr { declared = Some t; _ } when Array.for_all (fun x -> Dispatch.matches_alt (tag x) [ t ]) vs ->
        VArr { declared = Some t; cells = arrbuf_of_array vs }
      | VTuple _ -> VTuple vs
      (* filter(f, dict) gives a Dict back, as in Julia -- but only while the
         elements are still (key, value) pairs: `map` over a Dict is free to
         return anything at all, and then an Array is what it is *)
      | VDict _ when all_pairs ->
        let d = { dtbl = Hashtbl.create 8; dnext = 0 } in
        Array.iter (function VTuple [| k; v |] -> dict_set d k v | _ -> assert false) vs;
        VDict d
      | _ -> mk_arr vs
    in
    let apply1 f x = match f with VClosure (_, impl) -> impl [ x ] | _ -> assert false in
    let pred f x =
      match apply1 f x with
      | VBool b -> b
      | v -> failwith (Printf.sprintf "the predicate must return a Bool, got a %s" (tag v))
    in
    let less a b = match Dispatch.call "<" [ a; b ] with VBool b -> b | _ -> failwith "`<` must return a Bool" in
    (* every collection-taking method below accepts the same five -- a Dict
       included, where an "element" is a (key, value) Tuple, exactly what
       iterating one gives you *)
    let coll = [ "Vector"; "Array"; "Range"; "Tuple"; "Dict" ] in
    let promote2 int_op float_op a b =
      match a, b with
      | VInt x, VInt y -> VInt (int_op x y)
      | _ -> VFloat (float_op (as_float a) (as_float b))
    in
    Dispatch.defmethod "max" [ [ "Number" ]; [ "Number" ] ] (function
      | [ a; b ] -> promote2 Stdlib.max Stdlib.max a b
      | _ -> assert false);
    Dispatch.defmethod "min" [ [ "Number" ]; [ "Number" ] ] (function
      | [ a; b ] -> promote2 Stdlib.min Stdlib.min a b
      | _ -> assert false);
    (* clamp(x, lo, hi) -- the two `if`s a game writes over and over (a paddle
       against the screen edges, a health bar, a camera). Int in, Int out;
       any Float anywhere and the answer is a Float, same promotion `max`
       above uses. *)
    Dispatch.defmethod "clamp" [ [ "Number" ]; [ "Number" ]; [ "Number" ] ] (function
      | [ x; lo; hi ] ->
        if as_float lo > as_float hi then
          failwith (Printf.sprintf "clamp(x, lo, hi): lo (%s) must not be above hi (%s)" (show lo) (show hi));
        promote2 Stdlib.min Stdlib.min (promote2 Stdlib.max Stdlib.max x lo) hi
      | _ -> assert false);
    let fold_extreme name keep = function
      | [ c ] ->
        let vs = elements c in
        if Array.length vs = 0 then failwith (Printf.sprintf "%s: the collection is empty" name);
        Array.fold_left (fun acc x -> if keep x acc then x else acc) vs.(0) vs
      | _ -> assert false
    in
    Dispatch.defmethod "maximum" [ coll ] (fold_extreme "maximum" (fun x acc -> less acc x));
    Dispatch.defmethod "minimum" [ coll ] (fold_extreme "minimum" (fun x acc -> less x acc));
    Dispatch.defmethod "map" [ [ "Function" ]; coll ] (function
      | [ f; c ] -> rebuild c (Array.map (apply1 f) (elements c))
      | _ -> assert false);
    Dispatch.defmethod "filter" [ [ "Function" ]; coll ] (function
      | [ f; c ] -> rebuild c (Array.of_list (List.filter (pred f) (Array.to_list (elements c))))
      | _ -> assert false);
    Dispatch.defmethod "any" [ [ "Function" ]; coll ] (function
      | [ f; c ] -> VBool (Array.exists (pred f) (elements c))
      | _ -> assert false);
    Dispatch.defmethod "all" [ [ "Function" ]; coll ] (function
      | [ f; c ] -> VBool (Array.for_all (pred f) (elements c))
      | _ -> assert false);
    Dispatch.defmethod "count" [ [ "Function" ]; coll ] (function
      | [ f; c ] -> VInt (Array.fold_left (fun n x -> if pred f x then n + 1 else n) 0 (elements c))
      | _ -> assert false);
    (* sum over a collection -- `+` by dispatch, so summing Vec2s (a user
       struct with its own `+`) works exactly like summing numbers. The
       existing sum(::Matrix) overload is untouched. An empty sum is 0,
       matching real Julia. *)
    Dispatch.defmethod "sum" [ coll ] (function
      | [ c ] -> (
        match elements c with
        | [||] -> VInt 0
        | vs -> Array.fold_left (fun acc x -> Dispatch.call "+" [ acc; x ]) vs.(0) (Array.sub vs 1 (Array.length vs - 1)))
      | _ -> assert false);
    (* sort(c; by = f, rev = true) -- a stable sort through Tsubaki's own `<`,
       with real Julia's two keyword arguments (read from current_kwargs, the
       same side channel play_tone's own `volume`/`wave` use). *)
    Dispatch.defmethod "sort" [ coll ] (function
      | [ c ] ->
        let by = List.assoc_opt "by" !current_kwargs in
        let rev = match List.assoc_opt "rev" !current_kwargs with Some (VBool b) -> b | _ -> false in
        let key x = match by with Some (VClosure _ as f) -> apply1 f x | Some _ -> failwith "sort(...; by = f): by must be a Function" | None -> x in
        let vs = elements c in
        let keyed = Array.map (fun x -> key x, x) vs in
        let cmp (ka, _) (kb, _) = if less ka kb then -1 else if less kb ka then 1 else 0 in
        Array.stable_sort (fun a b -> if rev then cmp b a else cmp a b) keyed;
        rebuild c (Array.map snd keyed)
      | _ -> assert false);
    (* ---------------------------- Dict ----------------------------------
       `d = Dict()`, then `d[k] = v` / `d[k]` (see Eval's EIndex/EIndexAssign,
       which is where indexing a Dict is wired), plus the handful of things
       you actually do to one. No `Dict("a" => 1)` literal yet: `=>` isn't a
       token Tsubaki's lexer knows, and inventing a Pair type to carry it is a
       bigger decision than this -- a plainly disclosed gap, not an oversight.

       `keys`/`values` hand back Arrays (not Julia's lazy KeySet), which is
       the shape everything else here -- for, map, filter, length -- already
       eats. Iterating the Dict ITSELF yields (key, value) Tuples, so
       `for (k, v) in d` works, the same tuple-destructuring for-target a
       comprehension already had. *)
    Dispatch.defmethod "Dict" [] (fun _ -> mk_dict ());
    Dispatch.defmethod "length" [ [ "Dict" ] ] (function
      | [ VDict d ] -> VInt (dict_length d)
      | _ -> assert false);
    Dispatch.defmethod "haskey" [ [ "Dict" ]; [ "Any" ] ] (function
      | [ VDict d; k ] -> VBool (dict_get d k <> None)
      | _ -> assert false);
    (* get(d, k, default) -- the "look, but don't raise if it isn't there"
       half of indexing; `d[k]` on a missing key is a KeyError, as in Julia *)
    Dispatch.defmethod "get" [ [ "Dict" ]; [ "Any" ]; [ "Any" ] ] (function
      | [ VDict d; k; default ] -> ( match dict_get d k with Some v -> v | None -> default)
      | _ -> assert false);
    Dispatch.defmethod "delete!" [ [ "Dict" ]; [ "Any" ] ] (function
      | [ (VDict d as dict); k ] ->
        dict_delete d k;
        dict
      | _ -> assert false);
    Dispatch.defmethod "keys" [ [ "Dict" ] ] (function
      | [ VDict d ] -> mk_arr (Array.of_list (List.map fst (dict_pairs d)))
      | _ -> assert false);
    Dispatch.defmethod "values" [ [ "Dict" ] ] (function
      | [ VDict d ] -> mk_arr (Array.of_list (List.map snd (dict_pairs d)))
      | _ -> assert false);

    (* pop!: push!'s other half. Mutates in place and hands back the element it
       removed (real Julia's own contract), so a stack is finally a stack. *)
    Dispatch.defmethod "pop!" [ [ "Vector" ] ] (function
      | [ VVec r ] ->
        if r.vlen = 0 then failwith "pop!: the Vector is empty";
        r.vlen <- r.vlen - 1;
        VFloat r.vdata.(r.vlen)
      | _ -> assert false);
    Dispatch.defmethod "pop!" [ [ "Array" ] ] (function
      | [ VArr { cells; _ } ] ->
        if cells.alen = 0 then failwith "pop!: the Array is empty";
        cells.alen <- cells.alen - 1;
        let v = cells.adata.(cells.alen) in
        (* the slot past the logical end must not keep the popped value alive;
           and removing an element can NARROW the element type, so the cached
           tag has to go (see arrbuf's own comment) *)
        cells.adata.(cells.alen) <- VNothing;
        cells.atag <- None;
        v
      | _ -> assert false)
