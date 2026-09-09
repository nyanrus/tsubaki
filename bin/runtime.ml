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
    | VPair of value * value
      (* real Julia's `Pair` (`"a" => 1`) -- what a Dict is written with, and
         its own value the rest of the time (`p.first`, `p.second`). Deliberately
         not a 2-Tuple in disguise: `("a", 1)` and `"a" => 1` show differently,
         dispatch differently, and only one of them means "this goes in a Dict". *)
    | VJS of Js_of_ocaml.Js.Unsafe.any
      (* a JS value held AS IT IS: `document`, a `<browser>` element, Preact's
         `h`. Nothing is copied -- this is the same object the host has, which
         is the whole point (a copy of `document` is `document` lost). Values
         still cross by copy in the direction where copying is what's wanted:
         see js_of_value going out. Coming back, a field read or a call result
         stops at the surface (value_of_js_shallow) and anything that isn't a
         number/string/boolean/null stays one of these. *)

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

    (* Real Julia spells the two default numeric types `Int64` and `Float64`;
       Tsubaki's own tags are "Int" and "Float". `Int` is a real Julia alias
       for `Int64`, so that half already agreed -- but `x::Float64`,
       `Float64[]`, `Vector{Float64}(undef, n)` and `isa(x, Float64)` were all
       simply wrong here, and they are the first thing anyone arriving from
       Julia writes. `Float64[]` was the worst of them: it built a real
       `Array{Float64}` that then refused every Float it was handed.

       They are accepted as ALIASES rather than renaming the tags: "Int" and
       "Float" appear as literal strings in about 120 method signatures across
       runtime/compile/ecs/gpuBridge, and renaming those is a rewrite no type
       checker would supervise. So a type name written in SOURCE is normalized
       here, at each of the handful of points where one enters the system
       (Runtime.resolve_type_name, Eval's ETypeExpr / typed-array and -matrix
       constructors / `isa` / `::Type{...}` patterns). Nothing downstream --
       dispatch, `tag`, the hierarchy -- ever sees the alias.

       `typeof(1.0)` still answers "Float", not "Float64": that is the tag,
       and changing it is the rename above. See tests/known_gaps.jl. *)
    let alias = function "Float64" -> "Float" | "Int64" -> "Int" | n -> n

    (* like `alias`, but reaching inside a parametric name too, so
       `Dict{Int64,Float64}` and `Pair{Int64,Box{Float64}}` normalize as
       whole. Splitting on ',' tracks brace depth -- a nested parameter list
       has commas of its own that are not this level's separators. *)
    let rec canonical (n : string) : string =
      let len = String.length n in
      match String.index_opt n '{' with
      | Some i when len > 0 && n.[len - 1] = '}' ->
        let inner = String.sub n (i + 1) (len - i - 2) in
        let parts = ref [] and buf = Buffer.create 16 and depth = ref 0 in
        String.iter
          (fun c ->
            match c with
            | '{' ->
              incr depth;
              Buffer.add_char buf c
            | '}' ->
              decr depth;
              Buffer.add_char buf c
            | ',' when !depth = 0 ->
              parts := Buffer.contents buf :: !parts;
              Buffer.clear buf
            | c -> Buffer.add_char buf c)
          inner;
        parts := Buffer.contents buf :: !parts;
        (* `parts` was built back-to-front, and rev_map puts it right again *)
        let parts = List.rev_map (fun s -> canonical (String.trim s)) !parts in
        alias (String.sub n 0 i) ^ "{" ^ String.concat "," parts ^ "}"
      | _ -> alias n

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
        ; "JSValue", "Any"
        ; "Pair", "Any"
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
  let tag_jsvalue = "JSValue"
  let tag_pair = "Pair"

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
    | VJS _ -> tag_jsvalue
    | VPair _ -> tag_pair
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

  (* How a float is DISPLAYED -- real Julia's own rule, both halves of it.
     This used to be `%.3f`, which is not a formatting preference but a lie:
     it printed 1.5e-8 as "0.000", -0.0 as "0.000", and 1e100 as a hundred-
     and-one digit fixed-point number. This file's own pisum benchmark
     printed its answer as "1.645" while claiming to match real Julia's
     1.6449340668 -- true, and unverifiable from the output.

     Julia prints the SHORTEST decimal that reads back as the exact same
     float (so `0.1 + 0.2` shows its real value, `0.30000000000000004`, not
     a rounded one), and switches to scientific notation outside decimal
     exponents -4..5 -- checked against real Julia 1.12.5 across magnitudes
     from 1e-300 to 1e100, not assumed. A float always keeps a fractional
     part, so it never reads back as an Int. *)
  let float_repr (f : float) : string =
    if Float.is_nan f then "NaN"
    else if f = Float.infinity then "Inf"
    else if f = Float.neg_infinity then "-Inf"
    else if f = 0.0 then if 1.0 /. f < 0.0 then "-0.0" else "0.0"
    else begin
      (* fewest significant digits that still round-trips, as normalized
         "d.ddde±XX" -- 17 always suffices for a binary64 *)
      let rec shortest p =
        let s = Printf.sprintf "%.*e" p f in
        if p >= 16 || float_of_string s = f then s else shortest (p + 1)
      in
      let s = shortest 0 in
      let epos = String.index s 'e' in
      let mant = String.sub s 0 epos in
      let exp = int_of_string (String.sub s (epos + 1) (String.length s - epos - 1)) in
      let neg = mant.[0] = '-' in
      let mant = if neg then String.sub mant 1 (String.length mant - 1) else mant in
      let digits = String.concat "" (String.split_on_char '.' mant) in
      let nd = String.length digits in
      let sign = if neg then "-" else "" in
      if exp >= -4 && exp <= 5 then
        if exp >= 0 then begin
          let int_len = exp + 1 in
          if nd <= int_len then sign ^ digits ^ String.make (int_len - nd) '0' ^ ".0"
          else sign ^ String.sub digits 0 int_len ^ "." ^ String.sub digits int_len (nd - int_len)
        end
        else sign ^ "0." ^ String.make ((-exp) - 1) '0' ^ digits
      else begin
        let frac = if nd = 1 then "0" else String.sub digits 1 (nd - 1) in
        Printf.sprintf "%s%c.%se%d" sign digits.[0] frac exp
      end
    end

  (* shared by VComplex/VComplexVec/VComplexMat's own `show` cases below *)
  let show_complex_pair re im =
    Printf.sprintf "%s %s %sim" (float_repr re) (if im < 0.0 then "-" else "+") (float_repr (Float.abs im))

  let rec show = function
    | VInt n -> string_of_int n
    | VFloat f -> float_repr f
    | VBool b -> string_of_bool b
    | VStr s -> s
    | VNothing -> "nothing"
    | VRange (a, 1, b) -> Printf.sprintf "%d:%d" a b
    | VRange (a, s, b) -> Printf.sprintf "%d:%d:%d" a s b
    | VFRange (a, s, b) when s = 1.0 -> Printf.sprintf "%s:%s" (float_repr a) (float_repr b)
    | VFRange (a, s, b) -> Printf.sprintf "%s:%s:%s" (float_repr a) (float_repr s) (float_repr b)
    | VVec v -> "[" ^ String.concat ", " (Array.to_list (Array.map float_repr (vecbuf_to_array v))) ^ "]"
    | VArr { cells; _ } -> "[" ^ String.concat ", " (Array.to_list (Array.map show_elem (arrbuf_to_array cells))) ^ "]"
    | VMat rows ->
      "["
      ^ String.concat "; "
          (Array.to_list
             (Array.map (fun row -> String.concat " " (Array.to_list (Array.map float_repr row))) rows))
      ^ "]"
    | VGenMat { rows; cols; cells; _ } ->
      "["
      ^ String.concat "; "
          (List.init rows (fun i -> String.concat " " (List.init cols (fun j -> show_elem cells.((i * cols) + j)))))
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
      ^ String.concat ", " (Array.to_list (Array.map (fun (n, r) -> n ^ "=" ^ show_elem !r) s.fields))
      ^ ")"
    | VClosure _ -> "#<function>"
    | VJS x -> "JSValue(" ^ Js_of_ocaml.Js.to_string (Js_of_ocaml.Js.typeof x) ^ ")"
    | VDict d ->
      (* real Julia's own display shape, minus the {K,V} it can't know here.
         Insertion order (see dict_pairs), so this is reproducible. *)
      let pairs =
        Hashtbl.fold (fun _ (seq, k, v) acc -> (seq, k, v) :: acc) d.dtbl []
        |> List.sort (fun (a, _, _) (b, _, _) -> compare a b)
      in
      "Dict(" ^ String.concat ", " (List.map (fun (_, k, v) -> show_elem k ^ " => " ^ show_elem v) pairs) ^ ")"
    | VTuple vs -> "(" ^ String.concat ", " (Array.to_list (Array.map show_elem vs)) ^ ")"
    | VPair (a, b) -> show_elem a ^ " => " ^ show_elem b
    | VComplex (re, im) -> show_complex_pair re im
    | VRational (n, d) -> Printf.sprintf "%d//%d" n d
    | VSymbol (name, _) -> ":" ^ name
    | VExpr { head; args } ->
      ":(" ^ head ^ " " ^ String.concat " " (Array.to_list (Array.map show args)) ^ ")"
    | VUniformScaling c -> if c = 1.0 then "I" else float_repr c ^ "*I"
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

  (* An element shown INSIDE a container, where real Julia switches from
     `print` to `show`: a bare `println("hi")` prints hi, but the same string
     inside a Vector/Tuple/Dict/struct prints "hi", quotes and all -- which is
     the difference between reading a container's contents and guessing at
     them (`(1, a)` gave no way to tell the string "a" from a variable's
     value). Nothing else displays differently between the two. *)
  and show_elem = function
    | VStr s ->
      let b = Buffer.create (String.length s + 2) in
      Buffer.add_char b '"';
      String.iter
        (fun c ->
          match c with
          | '"' -> Buffer.add_string b "\\\""
          | '\\' -> Buffer.add_string b "\\\\"
          | '\n' -> Buffer.add_string b "\\n"
          | '\t' -> Buffer.add_string b "\\t"
          | c -> Buffer.add_char b c)
        s;
      Buffer.add_char b '"';
      Buffer.contents b
    | v -> show v

  (* --- values crossing to the JS host ---------------------------------
     Two directions, and deliberately not symmetric.

     OUT (`js_of_value`) COPIES, deeply: a Dict becomes a plain object, an
     Array an Array, a closure a real JS function. That is what a host
     function -- `h(tag, props, children)`, `addEventListener` -- wants to be
     handed, and none of it is something Tsubaki still has a claim on
     afterwards.

     IN (`value_of_js_shallow`) does NOT copy: a number/string/boolean/null
     becomes the Tsubaki value it obviously is, and everything else stays a
     `VJS` handle. So a field read and a call result both stop at the
     surface, and `document` survives being touched. `fromjs(x)` (see
     JsBridge) is the deep read, for a JS object that really is only data. *)
  let value_of_js_shallow (x : Js_of_ocaml.Js.Unsafe.any) : value =
    let open Js_of_ocaml in
    match Js.to_string (Js.typeof x) with
    | "number" ->
      let f = Js.float_of_number (Js.Unsafe.coerce x) in
      if Float.is_integer f && Float.abs f < 9007199254740992.0 then VInt (int_of_float f) else VFloat f
    | "string" -> VStr (Js.to_string (Js.Unsafe.coerce x))
    | "boolean" -> VBool (Js.to_bool (Js.Unsafe.coerce x))
    | "undefined" -> VNothing
    | _ -> if x == Js.Unsafe.inject Js.null then VNothing else VJS x

  let rec js_of_value (v : value) : Js_of_ocaml.Js.Unsafe.any =
    let open Js_of_ocaml in
    let inject = Js.Unsafe.inject in
    let num f = inject (Js.number_of_float f) in
    match v with
    | VInt i -> num (float_of_int i)
    | VFloat f -> num f
    | VFixedInt { v; _ } -> num (float_of_int v)
    | VBool b -> inject (Js.bool b)
    | VStr s -> inject (Js.string s)
    | VNothing -> inject Js.null
    | VJS x -> x
    | VVec { vdata; vlen } -> inject (Js.array (Array.init vlen (fun i -> Js.number_of_float vdata.(i))))
    | VArr { cells; _ } -> inject (Js.array (Array.init cells.alen (fun i -> js_of_value cells.adata.(i))))
    | VTuple a -> inject (Js.array (Array.map js_of_value a))
    | VPair (a, b) -> inject (Js.array [| js_of_value a; js_of_value b |])
    | VDict d ->
      let entries = Hashtbl.fold (fun _ (stamp, k, v) acc -> (stamp, k, v) :: acc) d.dtbl [] in
      let entries = List.sort (fun (a, _, _) (b, _, _) -> compare a b) entries in
      let key = function VStr s -> s | VSymbol (s, _) -> s | k -> show k in
      Js.Unsafe.obj (Array.of_list (List.map (fun (_, k, v) -> (key k, js_of_value v)) entries))
    | VStruct { kind; fields } ->
      Js.Unsafe.obj
        (Array.append
           [| ("__type", inject (Js.string kind)) |]
           (Array.map (fun (n, r) -> (n, js_of_value !r)) fields))
    | VClosure (arity, impl) ->
      (* handed over as a real JS function -- an event listener, a Preact
         `onClick`. JS calls it with whatever it likes; the closure receives
         exactly as many arguments as it declared (any it doesn't get is
         `nothing`), so `() -> refresh()` survives being called with an
         event. *)
      inject
        (Js.Unsafe.callback_with_arguments (fun (args : Js.Unsafe.any_js_array) ->
             let args : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.coerce args in
             let arg i =
               match Js.Optdef.to_option (Js.array_get args i) with
               | Some a -> value_of_js_shallow a
               | None -> VNothing
             in
             js_of_value (impl (List.init arity arg))))
    | other -> inject (Js.string (show other))

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
    | VPair (a, b) -> (
      match name with
      | "first" -> a
      | "second" -> b
      | _ -> failwith (Printf.sprintf "Pair has no field %s (only .first/.second)" name))
    | VJS x ->
      (* a property of a JS object, read at the surface -- `el.value`,
         `win.document`. A method read this way arrives UNBOUND (a plain
         handle to the function); calling it as `obj.meth(...)` keeps the
         receiver instead, which is why Eval takes that shape apart itself
         rather than reading the field first. *)
      value_of_js_shallow (Js_of_ocaml.Js.Unsafe.get x (Js_of_ocaml.Js.string name))
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

  (* the deep read coming IN -- the counterpart of what js_of_value already
     does going out. Reached only when asked for (`fromjs`), never behind the
     reader's back: an object becomes a Dict, an all-numeric Array a Vector.
     A function stays a handle, because there is nothing to copy it into. *)
  let rec value_of_js (x : Js_of_ocaml.Js.Unsafe.any) : value =
    let open Js_of_ocaml in
    let is_array () = Js.to_bool (Js.Unsafe.fun_call (Js.Unsafe.js_expr "Array.isArray") [| x |]) in
    if Js.to_string (Js.typeof x) <> "object" || x == Js.Unsafe.inject Js.null then value_of_js_shallow x
    else if is_array () then (
      let arr = Js.to_array (Js.Unsafe.coerce x) in
      let all_numbers = Array.for_all (fun e -> Js.to_string (Js.typeof e) = "number") arr in
      if all_numbers then VVec (vecbuf_of_array (Array.map (fun e -> Js.float_of_number (Js.Unsafe.coerce e)) arr))
      else (
        let cells = Array.map value_of_js arr in
        VArr { declared = None; cells = { adata = cells; alen = Array.length cells; atag = None } }))
    else (
      let d = { dtbl = Hashtbl.create 8; dnext = 0 } in
      let keys = Js.to_array (Js.Unsafe.fun_call (Js.Unsafe.js_expr "Object.keys") [| x |]) in
      Array.iter
        (fun k ->
          let ks = Js.to_string k in
          dict_set d (VStr ks) (value_of_js (Js.Unsafe.get x (Js.string ks))))
        keys;
      VDict d)

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

  (* Where execution currently IS: the source file's name and the line of the
     statement being run. `current_line` is set by evaluating an `SLine`
     marker (see Ast) -- the whole reason those markers exist. Together they
     turn "MethodError: no method matching describe(String)" into the same
     message with a place attached.

     The frame stack holds what lies between the top level and here: for each
     call, the function's name and the line its CALLER was on, which is what
     makes a traceback readable ("f, called from line 12"). Pushed and popped
     around every tree-walked call in Eval.

     Two parallel growable arrays, not a list of tuples. A list allocated two
     blocks on EVERY call, which measured at +14% on `fib(25)` -- this
     interpreter's most call-dense benchmark -- and that is far too much to
     pay for something only an error ever reads. A push is now two array
     writes and an increment; a pop is a decrement; and a real list is built
     only where one is genuinely wanted, at the moment an error is captured. *)
  let current_file : string ref = ref ""
  let current_line : int ref = ref 0
  let frame_names = ref (Array.make 256 "")
  let frame_lines = ref (Array.make 256 0)
  let frame_top = ref 0

  let push_frame name line =
    let cap = Array.length !frame_names in
    if !frame_top >= cap then (
      let names' = Array.make (cap * 2) "" and lines' = Array.make (cap * 2) 0 in
      Array.blit !frame_names 0 names' 0 cap;
      Array.blit !frame_lines 0 lines' 0 cap;
      frame_names := names';
      frame_lines := lines');
    !frame_names.(!frame_top) <- name;
    !frame_lines.(!frame_top) <- line;
    incr frame_top

  let pop_frame () = if !frame_top > 0 then decr frame_top

  (* the live frames, innermost first *)
  let frames_snapshot () =
    List.init !frame_top (fun i ->
        let j = !frame_top - 1 - i in
        !frame_names.(j), !frame_lines.(j))

  (* Everything an error report needs is simply where execution stood when the
     error was raised -- nothing unwinds it on the way out (see Eval's
     tree_walk_impl), so `current_file`, `current_line` and the frames are
     still exactly there by the time the top level prints them.

     Which means whoever CATCHES an error is the one who has to put things
     back: Eval's STry saves this triple on the way in and restores it in its
     handler, and the REPL does the same around each entry. *)
  type site = { s_file : string; s_line : int; s_top : int }

  let here () = { s_file = !current_file; s_line = !current_line; s_top = !frame_top }

  let restore_site s =
    current_file := s.s_file;
    current_line := s.s_line;
    frame_top := s.s_top

  (* Whether execution is currently inside a Tsubaki function's body. A frame
     is pushed only by a tree-walked call, which is exactly the question --
     used by Eval's `function` declaration to decide whether the name being
     declared is a local of the call that is running, or a global. *)
  let inside_function_body () = !frame_top > 0


  (* "file:line", "" if unknown (the built-in demo has no file, and nothing
     has run yet at startup) *)
  let position_of file line =
    if line = 0 then "" else if file = "" then Printf.sprintf "line %d" line else Printf.sprintf "%s:%d" file line

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
    (* real Julia's `Float64`/`Int64` spellings normalize to this file's own
       tags first, before any module qualification -- see Types.canonical *)
    let n = Types.canonical n in
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

    (* 番号 -> セル。AST のノードが持っているのは Caches.fresh_call () で
       もらった番号だけで、セルはここにある。番号は単調に増えるので、要る
       ところまで倍々に伸ばす(伸ばすのは初回だけ、あとは配列を引くだけ)。 *)
    let cache_table : call_cache array ref = ref (Array.init 256 (fun _ -> new_cache ()))

    let grow_cache_table (i : int) : call_cache =
      let t = !cache_table in
      let old_n = Array.length t in
      let n = max (i + 1) (2 * old_n) in
      let bigger = Array.init n (fun k -> if k < old_n then Array.unsafe_get t k else new_cache ()) in
      cache_table := bigger;
      Array.unsafe_get bigger i

    let cache_at (i : int) : call_cache =
      let t = !cache_table in
      if i < Array.length t then Array.unsafe_get t i else grow_cache_table i

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

  (* 同じ形の表を var_cache にも。EVar/EAssign が持つのは番号だけ。 *)
  let var_cache_table : var_cache array ref = ref (Array.init 256 (fun _ -> { depth = 0 }))

  let grow_var_cache_table (i : int) : var_cache =
    let t = !var_cache_table in
    let old_n = Array.length t in
    let n = max (i + 1) (2 * old_n) in
    let bigger = Array.init n (fun k -> if k < old_n then Array.unsafe_get t k else { depth = 0 }) in
    var_cache_table := bigger;
    Array.unsafe_get bigger i

  let var_cache_at (i : int) : var_cache =
    let t = !var_cache_table in
    if i < Array.length t then Array.unsafe_get t i else grow_var_cache_table i

  (* funcdecl_cache_state/funcdecl_cache are defined further below --
     they need get_field/construct/Dispatch, defined between here and there. *)

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
    | VJS x -> Js_of_ocaml.Js.Unsafe.set x (Js_of_ocaml.Js.string name) (js_of_value newv)
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
    (* the same method record can already be on the bare name -- `using X` twice,
       or `import X` (which is a `using` here) followed by `using X`. Appending
       it again would make every call to it ambiguous with itself, so only what
       isn't already there is merged, and the generation moves only if something
       really did. *)
    let merged = ref false in
    List.iter
      (fun (bare, ms) ->
        let existing = Option.value (Hashtbl.find_opt Dispatch.methods bare) ~default:[] in
        match List.filter (fun m -> not (List.memq m existing)) ms with
        | [] -> ()
        | fresh ->
          merged := true;
          Hashtbl.replace Dispatch.methods bare (fresh @ existing))
      methods_to_merge;
    if !merged then incr Dispatch.generation;
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
    (* the same method record can already be on the bare name -- `using X` twice,
       or `import X` (which is a `using` here) followed by `using X`. Appending
       it again would make every call to it ambiguous with itself, so only what
       isn't already there is merged, and the generation moves only if something
       really did. *)
    let merged = ref false in
    List.iter
      (fun (bare, ms) ->
        let existing = Option.value (Hashtbl.find_opt Dispatch.methods bare) ~default:[] in
        match List.filter (fun m -> not (List.memq m existing)) ms with
        | [] -> ()
        | fresh ->
          merged := true;
          Hashtbl.replace Dispatch.methods bare (fresh @ existing))
      methods_to_merge;
    if !merged then incr Dispatch.generation;
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
     AST_IN_RUST_EXPERIMENT.md); FC_host_compiled (bin/host.ml) is the
     fallback for the ECS/struct/host-call shape that numeric compilation
     can never accept, and never leaves OCaml at all. Stores the
     ALREADY-ENCODED forms (a plain float array for the former, a
     Host.program for the latter) rather than Compile's own instr array
     type, so this module doesn't need to depend on Compile (which depends
     on Ast, which depends on this) at all. *)
  type funcdecl_cache_state =
    | FC_unattempted
    | FC_compiled of float array * int (* encoded bytecode, nslots *)
    | FC_host_compiled of (unit -> value)
      (* もう「呼ぶだけ」の形。中で何が走るか(Host の program)は、ここでは
         知らない -- そのおかげで Runtime は Host を知らなくていい *)
    | FC_ineligible

  type funcdecl_cache = { mutable fc_state : funcdecl_cache_state }

  let new_funcdecl_cache () : funcdecl_cache = { fc_state = FC_unattempted }

  (* SFuncDecl の分。宣言の場所ひとつにセルひとつ、というのは前と同じ。 *)
  let funcdecl_cache_table : funcdecl_cache array ref =
    ref (Array.init 64 (fun _ -> { fc_state = FC_unattempted }))

  let grow_funcdecl_cache_table (i : int) : funcdecl_cache =
    let t = !funcdecl_cache_table in
    let old_n = Array.length t in
    let n = max (i + 1) (2 * old_n) in
    let bigger = Array.init n (fun k -> if k < old_n then Array.unsafe_get t k else { fc_state = FC_unattempted }) in
    funcdecl_cache_table := bigger;
    Array.unsafe_get bigger i

  let funcdecl_cache_at (i : int) : funcdecl_cache =
    let t = !funcdecl_cache_table in
    if i < Array.length t then Array.unsafe_get t i else grow_funcdecl_cache_table i

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
    (* A conversion is a CALL, not a type annotation, so Types.canonical never
       sees it -- `Int64(3)` and `Float64(3)` need methods of their own. And
       widening to Float had no spelling at all before this: `Float(3)` was as
       absent as `Float64(3)`, so the only way to get a Float from an Int was
       arithmetic. *)
    Dispatch.defmethod "Int64" [ [ "Number" ] ] (fun args -> Dispatch.call "Int" args);
    let to_float = function
      | [ x ] -> VFloat (as_float x)
      | _ -> assert false
    in
    Dispatch.defmethod "Float" [ [ "Number" ] ] to_float;
    Dispatch.defmethod "Float64" [ [ "Number" ] ] to_float;
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
    (* Integer division, all three of real Julia's roundings -- `7 % 2` was
       here but `div(7, 2)` was not, so there was no way to write the other
       half of a divmod at all. `÷` is real Julia's own spelling of `div`
       (U+00F7), lexed as its own operator. Truncated / floored / ceiling,
       exactly as real Julia defines them: div(-7,2) = -3, fld(-7,2) = -4,
       cld(7,2) = 4. *)
    let to_i v = match v with VInt n -> n | VFixedInt { v; _ } -> v | other -> int_of_float (as_float other) in
    let int2 name f =
      Dispatch.defmethod name [ [ "Integer" ]; [ "Integer" ] ] (function
        | [ a; b ] -> (
          let x = to_i a and y = to_i b in
          match y with 0 -> failwith "DivideError: integer division error" | _ -> VInt (f x y))
        | _ -> assert false)
    in
    int2 "div" (fun x y -> x / y);
    int2 "\xc3\xb7" (fun x y -> x / y);
    int2 "fld" (fun x y -> if x * y < 0 && x mod y <> 0 then (x / y) - 1 else x / y);
    int2 "cld" (fun x y -> if x * y > 0 && x mod y <> 0 then (x / y) + 1 else x / y);
    Dispatch.defmethod "sign" [ [ "Integer" ] ] (function
      | [ a ] -> VInt (compare (to_i a) 0)
      | _ -> assert false);
    Dispatch.defmethod "sign" [ [ "Float" ] ] (function
      | [ VFloat a ] -> VFloat (if a > 0.0 then 1.0 else if a < 0.0 then -1.0 else a)
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
    (* `==` used to answer for Numbers and NOTHING else, so `true == true`,
       `"a" == "a"`, `nothing == nothing`, `:a == :a` and comparing two
       structs all raised a MethodError -- one of the first things anyone
       sitting down to write a program reaches for.

       Real Julia's `==` falls back to `===`, which for an IMMUTABLE struct
       compares field by field and for a `mutable struct` is object identity.
       This mirrors that, and recurses into containers by DISPATCHING each
       element back through `==`, so a user's own `==` method on their own
       type still governs its own values, even nested inside a Tuple or an
       Array. Physical equality short-circuits first, which is also what
       keeps a self-referential struct (`n.next === n`) from recursing
       forever. Registered on (Any, Any), the least specific signature there
       is, so every existing and future more-specific `==` still wins. *)
    let elem_eq a b = match Dispatch.call "==" [ a; b ] with VBool r -> r | _ -> false in
    let array_eq xs ys = Array.length xs = Array.length ys && (
      let ok = ref true in
      Array.iteri (fun i x -> if !ok && not (elem_eq x ys.(i)) then ok := false) xs;
      !ok)
    in
    let generic_eq a b =
      if a == b then true
      else
        match a, b with
        | VStr x, VStr y -> String.equal x y
        | VBool x, VBool y -> x = y
        | VNothing, VNothing -> true
        | VSymbol (x, _), VSymbol (y, _) -> String.equal x y
        | VType x, VType y -> String.equal x y
        | VRange (a1, s1, b1), VRange (a2, s2, b2) -> a1 = a2 && s1 = s2 && b1 = b2
        | VTuple xs, VTuple ys -> array_eq xs ys
        | VArr { cells = xs; _ }, VArr { cells = ys; _ } -> array_eq (arrbuf_to_array xs) (arrbuf_to_array ys)
        | VVec xs, VVec ys -> vecbuf_to_array xs = vecbuf_to_array ys
        | VMat xs, VMat ys -> xs = ys
        | VDict d1, VDict d2 ->
          dict_length d1 = dict_length d2
          && List.for_all
               (fun (k, v) ->
                 match Hashtbl.find_opt d2.dtbl (dict_key k) with
                 | Some (_, _, v2) -> elem_eq v v2
                 | None -> false)
               (dict_pairs d1)
        | VStruct s1, VStruct s2 ->
          String.equal s1.kind s2.kind
          && (match Hashtbl.find_opt struct_defs s1.kind with
             (* a mutable struct is compared by identity, which the physical
                check above already settled -- two distinct ones are not
                equal however alike their fields look, same as real Julia *)
             | Some sd when sd.mutable_ -> false
             | _ ->
               Array.length s1.fields = Array.length s2.fields
               && array_eq (Array.map (fun (_, r) -> !r) s1.fields) (Array.map (fun (_, r) -> !r) s2.fields))
        | _ -> false
    in
    Dispatch.defmethod "==" [ [ "Any" ]; [ "Any" ] ] (function
      | [ a; b ] -> VBool (generic_eq a b)
      | _ -> assert false);
    Dispatch.defmethod "!=" [ [ "Any" ]; [ "Any" ] ] (function
      | [ a; b ] -> VBool (not (generic_eq a b))
      | _ -> assert false);
    (* lexicographic String ordering, real Julia's own -- what `sort` on a
       Vector of names needs, since sorting goes through this `<` *)
    let str_cmp name op =
      Dispatch.defmethod name [ [ "String" ]; [ "String" ] ] (function
        | [ VStr a; VStr b ] -> VBool (op (compare a b) 0)
        | _ -> assert false)
    in
    str_cmp "<" ( < );
    str_cmp "<=" ( <= );
    str_cmp ">" ( > );
    str_cmp ">=" ( >= );
    (* String support: concatenation via "+" too, same name, different signature *)
    Dispatch.defmethod "+" [ [ "String" ]; [ "String" ] ] (function
      | [ VStr a; VStr b ] -> VStr (a ^ b)
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
    (* real Julia's `round` breaks a tie toward the EVEN neighbour
       (RoundNearest, IEEE-754's default): round(2.5) is 2.0, round(3.5) is
       4.0. OCaml's own Float.round rounds a tie away from zero, which quietly
       disagreed on exactly the halves. *)
    def_math1 "round" (fun x ->
      let r = Float.round x in
      if Float.abs (x -. Float.trunc x) <> 0.5 then r
      else if Float.rem r 2.0 = 0.0 then r
      else r -. Float.copy_sign 1.0 x);
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
    (* `a[begin]` and `a[end]`, as ordinary functions -- for when the index is
       worked out somewhere else. `a[begin + i]` is how an index that came from
       a 0-origin world (a JS array, Python) is applied without writing the +1
       by hand, and it says which world the +1 belongs to. Everything indexable
       here starts at 1, so firstindex is a constant; if that ever stops being
       true, this is where it stops. *)
    Dispatch.defmethod "firstindex" [ [ "Vector"; "Array"; "Tuple" ] ] (function
      | [ _ ] -> VInt 1
      | _ -> assert false);
    Dispatch.defmethod "lastindex" [ [ "Vector"; "Array"; "Tuple" ] ] (function
      | [ VVec r ] -> VInt (vecbuf_length r)
      | [ VArr { cells; _ } ] -> VInt (arrbuf_length cells)
      | [ VTuple vs ] -> VInt (Array.length vs)
      | _ -> assert false);
    (* a Range knew how to be summed, maximized and iterated, but not how
       many elements it has -- `length(1:2:9)` raised a MethodError. Counted,
       never materialized, and empty when the step points away from the stop
       (`length(5:1)` is 0, same as real Julia). *)
    Dispatch.defmethod "length" [ [ "Range" ] ] (function
      | [ VRange (a, s, b) ] -> VInt (if s = 0 then 0 else max 0 (((b - a) / s) + 1))
      | [ VFRange (a, s, b) ] -> VInt (if s = 0.0 then 0 else max 0 (int_of_float (Float.floor ((b -. a) /. s)) + 1))
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
    Dispatch.defmethod "uppercase" [ [ "String" ] ] (function
      | [ VStr s ] -> VStr (String.uppercase_ascii s)
      | _ -> assert false);
    (* `length` already answered for every container here EXCEPT the one type
       most likely to be asked -- `length("hello")` raised a MethodError.
       Bytes, not codepoints, same as real Julia's own `length`-vs-`sizeof`
       split resolves for ASCII (which is all this lexer accepts in a string
       literal anyway). *)
    Dispatch.defmethod "length" [ [ "String" ] ] (function
      | [ VStr s ] -> VInt (String.length s)
      | _ -> assert false);
    (* real Julia concatenates strings with `*`, not `+` (`+` is deliberately
       NOT defined for strings there at all, since concatenation isn't
       commutative). Tsubaki's own pre-existing `+` stays -- removing it would
       break existing programs for no gain -- but `*` is what someone writing
       Julia reaches for, and its absence made real Julia source stop dead. *)
    Dispatch.defmethod "*" [ [ "String" ]; [ "String" ] ] (function
      | [ VStr a; VStr b ] -> VStr (a ^ b)
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
