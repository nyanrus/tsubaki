(* ============================= Eval ============================= *)
  open Ast
  open Runtime

  exception Return_exc of value

  (* the actual integers a step range denotes, e.g. range_ints 1 2 7 = [1;3;5;7] *)
  let range_ints (a : int) (step : int) (b : int) : int list =
    if step = 0 then failwith "range step cannot be 0"
    else (
      let acc = ref [] in
      let i = ref a in
      while (if step > 0 then !i <= b else !i >= b) do
        acc := !i :: !acc;
        i := !i + step
      done;
      List.rev !acc)

  (* same idea for a Float range, e.g. range_floats (-1.0) 0.1 1.0 = [-1.0; -0.9; ...; 1.0].
     Element i is computed as a +. i*.step directly (not by repeated addition), the same
     trick real Julia's own StepRangeLen uses, so floating-point error can't accumulate
     across a long range -- only the element count is ever rounded. *)
  let range_floats (a : float) (step : float) (b : float) : float list =
    if step = 0.0 then failwith "range step cannot be 0"
    else (
      let count = int_of_float (Float.round ((b -. a) /. step)) in
      if count < 0 then []
      else List.init (count + 1) (fun i -> a +. (float_of_int i *. step)))

  (* shared by SFor and EComprehension: the values to bind the loop/comprehension
     variable to, for any of the four iterable kinds *)
  let iter_values (v : value) : value list =
    match v with
    | VRange (a, s, b) -> List.map (fun i -> VInt i) (range_ints a s b)
    | VFRange (a, s, b) -> List.map (fun f -> VFloat f) (range_floats a s b)
    | VVec r -> Array.to_list (Array.map (fun x -> VFloat x) (vecbuf_to_array r))
    | VArr { cells; _ } -> Array.to_list (arrbuf_to_array cells)
    (* a Dict iterates as its (key, value) pairs, so `for (k, v) in d` is the
       tuple-destructuring for-target this already had, pointed at a Dict *)
    | VDict d -> List.map (fun (k, v) -> VTuple [| k; v |]) (dict_pairs d)
    | _ -> failwith "expected a Range, Vector, Array, or Dict to iterate"

  (* same iterables as iter_values, but calling `f` directly on each element
     instead of building an intermediate `value list` first -- SFor's hot
     path (profiled: `for k in 1:10000` run 500 times in pisum was paying
     for a fresh 10,000-cons-cell list AND a full List.map over it, on every
     single outer iteration, entirely to support the same four iterable
     kinds iter_values does). Range walking is reimplemented directly here
     (not built on range_ints/range_floats) specifically to avoid ever
     materializing the intermediate int/float list those build. *)
  let iter_values_do (v : value) (f : value -> unit) : unit =
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
    | VDict d -> List.iter (fun (k, v) -> f (VTuple [| k; v |])) (dict_pairs d)
    | _ -> failwith "expected a Range, Vector, Array, or Dict to iterate"

  (* A plain assoc list, not a Hashtbl: almost every scope here is a function
     call frame or a single loop iteration with a handful of variables, and a
     `for` loop creates a brand new scope on EVERY iteration -- pisum's inner
     loop alone does that 5,000,000 times. Hashtbl.create eagerly allocates a
     bucket array every time; an empty list is a zero-cost `[]` until
     something is actually bound into it. Linear scan is fine at this size,
     and it's what actually got measured to matter (see README benchmarks). *)
  type env = { mutable vars : (string * value ref) list; parent : env option }

  let new_scope parent = { vars = []; parent = Some parent }

  (* the one scope with no parent -- every lookup that walks off the top of
     its chain ends up here. Defined this early (before `bind`) so `bind`
     itself can recognize a write landing directly into it -- see
     `global_generation` below. *)
  let global = { vars = []; parent = None }

  (* bumped only when `bind` adds a genuinely NEW key into `global` itself
     (never for any other scope, and never for an overwrite of an existing
     key) -- lets ECall's closure-shadow pre-check
     (`lookup_opt_shadow_free` below) know whether anything could possibly
     have changed about global's own bindings since it last confirmed a
     given name absent there, without re-scanning global.vars on every
     single call. See PROFILE_FIB_MANDEL_QUICKSORT.md. *)
  let global_generation = ref 0

  (* `List.assoc_opt` is polymorphic -- comparing keys goes through OCaml's
     generic runtime equality (type-dispatch first, THEN compare), not a
     direct string compare, even though every key here is always a string.
     A profiler run (see README) showed this generic-compare path costing
     real time on its own, separate from the actual string comparison work.
     This does the same lookup with `String.equal` directly, monomorphic,
     no runtime dispatch -- plus a `==` fast path first, which actually
     fires: every identifier is interned at lex time (see Lexer.intern), so
     `k` at a binding site (a for-loop header, a parameter) and `k` at every
     reference to it are the SAME physical string, not just equal content.
     A later profiler run found variable-name comparison, not dispatch-tag
     comparison, was the dominant share of this cost in a tight loop. *)
  let rec str_assoc_opt name = function
    | [] -> None
    | (k, v) :: rest -> if k == name || String.equal k name then Some v else str_assoc_opt name rest

  (* create-or-overwrite a binding in exactly this scope, no chain walk --
     used for parameter binding, loop variables, catch variables, and the
     "not found anywhere" fallback of `assign` below *)
  let bind env name v =
    match str_assoc_opt name env.vars with
    | Some cell -> cell := v
    | None ->
      env.vars <- (name, ref v) :: env.vars;
      if env == global then incr global_generation

  (* a for-loop OR comprehension clause's own loop-variable binding -- a
     plain name, or real Julia's tuple-unpacking `(s, d)` shorthand (shared
     by SFor and EComprehension, see for_target's own comment) *)
  let bind_for_target scope target v =
    match target with
    | FVSingle name -> bind scope name v
    | FVTuple names -> (
      match v with
      | VTuple vs when Array.length vs = List.length names -> List.iteri (fun i name -> bind scope name vs.(i)) names
      | VTuple vs ->
        failwith
          (Printf.sprintf "BoundsError: for-loop destructure expected %d values, got %d" (List.length names)
             (Array.length vs))
      | _ -> failwith "for-loop destructure target requires a Tuple-valued iterator element")

  let rec lookup_opt env name =
    match str_assoc_opt name env.vars with
    | Some cell -> Some !cell
    | None -> ( match env.parent with Some p -> lookup_opt p name | None -> None)

  (* "win.document" -> the JS object it names, when the first segment is a
     bound variable holding a JS handle and every later one is a plain
     property of it. None for anything else, so a real module keeps the path
     it always had. Used by EQualifiedCall, which is the shape `obj.meth(x)`
     parses into when the receiver is a bare name (see Parser's
     dotted_chain). *)
  let js_receiver env (dotted : string) : Js_of_ocaml.Js.Unsafe.any option =
    match String.split_on_char '.' dotted with
    | [] -> None
    | first :: rest -> (
      match lookup_opt env first with
      | Some v ->
        List.fold_left
          (fun acc f -> match acc with Some (VJS _ as o) -> Some (get_field o f) | _ -> None)
          (Some v) rest
        |> (function Some (VJS o) -> Some o | _ -> None)
      | None -> None)

  (* like `lookup_opt`, but knows `global` is the one point in any lookup
     chain whose CONTENTS can be proven unchanged since a previous call at
     the SAME AST node (tracked via `global_generation`) -- every scope
     strictly between `env` and `global` is fresh per call/iteration and
     always walked for real, nothing safe to cache about those. Used only
     by ECall's own "is this name shadowed by a local closure" pre-check
     (`cache` is that call site's own `Dispatch.call_cache`, already
     threaded through for dispatch's inline cache) -- not a general
     replacement for `lookup_opt`. A stale `cache.shadow_gen` (global's
     generation moved on since) just falls back to scanning `global.vars`
     for real, same as `lookup_opt` always did -- never trusted blindly, so
     this can only ever cost a redundant scan, never a wrong dispatch. See
     PROFILE_FIB_MANDEL_QUICKSORT.md. *)
  (* top-level (not nested inside `lookup_opt_shadow_free`) so it takes
     `name`/`skip_global`/`cache` as plain arguments instead of closing over
     them -- a nested `let rec` here would allocate a fresh closure on
     EVERY call regardless of whether `skip_global` ever pays for itself,
     which measurably regressed `quicksort` (shallow, 1-hop-to-global call
     sites like `fib`'s win outright; `quicksort`'s call site sits behind
     2 more always-walked block scopes, so the skipped scan is a smaller
     share of the total and the closure allocation ate the win). *)
  let rec lookup_opt_shadow_free_walk name skip_global (cache : Dispatch.call_cache) e =
    match e.parent with
    | None ->
      if skip_global then None
      else (
        match str_assoc_opt name e.vars with
        | Some cell -> Some !cell
        | None ->
          cache.Dispatch.shadow_gen <- !global_generation;
          None)
    | Some p -> (
      match str_assoc_opt name e.vars with
      | Some cell -> Some !cell
      | None -> lookup_opt_shadow_free_walk name skip_global cache p)

  let lookup_opt_shadow_free env name (cache : Dispatch.call_cache) =
    let skip_global = cache.Dispatch.shadow_gen = !global_generation && cache.Dispatch.shadow_gen >= 0 in
    lookup_opt_shadow_free_walk name skip_global cache env

  let lookup env name =
    match lookup_opt env name with
    | Some v -> v
    | None -> failwith (Printf.sprintf "UndefVarError: %s not defined" name)

  (* same lookup, but a `var_cache` (owned by one EVar AST node) remembers how
     many parent-hops away the name was found last time and jumps straight
     there first. If that guess is wrong (or was never made yet), falls back
     to the exact same walk `lookup` does, and re-learns the depth for next
     time -- purely an accelerator, never a different answer. *)
  let lookup_cached env name (cache : var_cache) =
    let rec nth_parent e n =
      if n <= 0 then Some e else match e.parent with Some p -> nth_parent p (n - 1) | None -> None
    in
    let full_walk () =
      let rec walk e d =
        match str_assoc_opt name e.vars with
        | Some cell ->
          cache.depth <- d;
          !cell
        | None -> (
          match e.parent with
          | Some p -> walk p (d + 1)
          | None -> failwith (Printf.sprintf "UndefVarError: %s not defined" name))
      in
      walk env 0
    in
    match nth_parent env cache.depth with
    | Some target -> ( match str_assoc_opt name target.vars with Some cell -> !cell | None -> full_walk ())
    | None -> full_walk ()

  (* Assigning a name that already exists *somewhere* up the chain mutates
     that binding in place (this is what lets a closure/nested function
     mutate a captured outer variable, like the bump() counter demo below).
     A name that exists NOWHERE, though, must become a fresh local in the
     scope where the assignment itself is written -- NOT in whatever the
     outermost scope happens to be. Walking all the way to the root for an
     unrecognized name (the previous behavior) was a real bug: every "new"
     local in every function body -- i, j in a quicksort, for instance --
     silently became one shared global, so recursive calls stomped on each
     other's supposedly-local state instead of getting their own. *)
  let assign env name v =
    let rec walk_and_set e =
      match str_assoc_opt name e.vars with
      | Some cell ->
        cell := v;
        true
      | None -> ( match e.parent with Some p -> walk_and_set p | None -> false)
    in
    if not (walk_and_set env) then bind env name v

  (* same depth-cache trick as lookup_cached, for the write side: `s += ...`
     both reads AND writes `s` every time, so leaving assign uncached would
     leave half of every compound-assignment's cost unaddressed. Falls back
     to the exact same walk-or-create-locally semantics as plain `assign`
     whenever the cached guess doesn't pan out. *)
  let assign_cached env name v (cache : var_cache) =
    let rec nth_parent e n =
      if n <= 0 then Some e else match e.parent with Some p -> nth_parent p (n - 1) | None -> None
    in
    let full_walk () =
      let rec walk e d =
        match str_assoc_opt name e.vars with
        | Some cell ->
          cache.depth <- d;
          cell := v;
          true
        | None -> ( match e.parent with Some p -> walk p (d + 1) | None -> false)
      in
      if not (walk env 0) then (
        cache.depth <- 0;
        bind env name v)
    in
    match nth_parent env cache.depth with
    | Some target -> (
      match str_assoc_opt name target.vars with
      | Some cell -> cell := v
      | None -> full_walk ())
    | None -> full_walk ()

  let () = bind global "pi" (VFloat Float.pi)
  let () = bind global "I" (VUniformScaling 1.0)

  (* macros live in their own namespace, never Dispatch.methods -- they're
     matched purely by NAME and ARGUMENT COUNT (never type, since a macro
     never sees an evaluated value, only quoted syntax), so a real
     dispatch-style method table would be the wrong shape entirely. *)
  let macros : (string, string list * stmt list) Hashtbl.t = Hashtbl.create 16

  (* struct full-name -> (field, default-expr) list, populated only when a
     struct is declared under @kwdef. Powers the fresh keyword constructor
     `T(; field=val, ...)` in the ECall construct path; a struct not declared
     with @kwdef never gets an entry, so its keyword form stays the
     partial-update-only one. Default exprs are kept unevaluated and run in the
     caller's env at each construct, same as a function's keyword defaults. *)
  let kwdef_defaults : (string, (string * expr) list) Hashtbl.t = Hashtbl.create 16

  (* a macro declared inside `module M ... end` registers under "M.name", not
     bare "name" -- so two different modules' same-named macros never
     collide the way `using` intentionally lets same-named FUNCTIONS coexist
     as dispatch candidates (macros have no such multi-candidate concept).
     Lookup tries the qualified name first (only meaningful while currently
     executing inside that same module's own body, where a macro can call
     itself/a sibling bare), then falls back to bare -- same qualified-then-
     bare shape as Runtime.resolve_type_name. *)
  let find_macro name =
    if !current_module_prefix <> "" then (
      match Hashtbl.find_opt macros (!current_module_prefix ^ name) with
      | Some m -> Some m
      | None -> Hashtbl.find_opt macros name)
    else Hashtbl.find_opt macros name

  (* is `name` a real, registered type (built-in or user struct/abstract)?
     Used only to disambiguate real Julia's `T[]`/`T[1,2,3]` typed-array-
     literal shorthand from ordinary indexing -- see EIndex below, which
     only reaches this check once looking `name` up as a bound variable has
     already failed. *)
  (* through Types.canonical, so real Julia's `Float64[1.0, 2.0]` is
     recognized as a typed-array literal rather than read as indexing into an
     undefined variable named Float64 *)
  let is_recognized_elem_type name = Hashtbl.mem Types.parent (Types.canonical name)

  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest

  (* the arity range a param list (with a possible trailing run of
     positional defaults, `f(a, b=1)`) accepts -- from the first param
     carrying its own default up to the full param count. Every arity in
     that range gets its own `Dispatch.methods` entry (all sharing the same
     impl -- `bind_params` below pads whatever trailing params argv didn't
     reach from their own defaults), the same way real Julia effectively
     registers one method per optional-arg arity. *)
  let param_arity_range (params : param list) : int * int =
    let n_total = List.length params in
    let rec first_default i = function
      | [] -> n_total
      | p :: rest -> if p.pdefault <> None then i else first_default (i + 1) rest
    in
    first_default 0 params, n_total

  (* a `::Type{X}` dispatch parameter's alt is built from its type_pattern,
     not its (irrelevant, always ["Any"]) `ptype` -- reusing the ordinary
     `Types.distance_to`/`parse_concrete` machinery UNCHANGED: a VType's own
     tag is always "Type{<actual name>}" (see Runtime.tag), so an alt of
     "Type{Bound}" is exactly the existing covariant-parametric-match rule,
     one level up. Where-bound variables (TPWhole/TPNested's own inner var)
     are substituted with their own bound ("Any" if unconstrained) so e.g.
     Primes.jl's four `factor(::Type{X}, ...) where {X<:Family}` overloads
     each get a genuinely different, correctly-scored alt instead of
     colliding on one identical "any type" pattern. *)
  (* each name goes through Types.canonical for the same reason every other
     source-written type name does -- so `f(::Type{Float64})` names the same
     type `x::Float64` does *)
  let type_pattern_alt = function
    | TPMatch name -> Printf.sprintf "Type{%s}" (Types.canonical name)
    | TPWhole (_, bound) -> Printf.sprintf "Type{%s}" (Types.canonical bound)
    | TPNested (outer, _) -> Printf.sprintf "Type{%s{Any}}" (Types.canonical outer)

  let param_sig_alt p =
    match p.ptypepattern with
    | Some pat -> [ type_pattern_alt pat ]
    | None -> List.map resolve_type_name p.ptype

  (* the inverse of `Types.parse_concrete`'s SAME base check, scoped to one
     specific outer name -- extracts T from "Deque{T}" if the actual
     wrapped name really does have that exact "outer{...}" shape (nothing
     else reaches here: Dispatch already only routed a call to this method
     if the argument's own tag matched the registered `Type{Outer{Any}}`
     alt in the first place). *)
  let strip_type_wrapper outer s =
    let prefix = outer ^ "{" in
    let plen = String.length prefix in
    if String.length s > plen && String.sub s 0 plen = prefix && s.[String.length s - 1] = '}' then
      Some (String.sub s plen (String.length s - plen - 1))
    else None

  let rec eval_expr env (e : expr) : value =
    match e with
    | EInt n -> VInt n
    | EFloat f -> VFloat f
    | EStr s -> VStr s
    | EBool b -> VBool b
    | ENothing -> VNothing
    | EVar (n, cache) -> (
      match lookup_cached env n cache with
      | v -> v
      | exception Failure msg ->
        (* same exception-driven "not a bound variable -- is it a
           recognized type instead?" dispensation EIndex's own `T[1,2,3]`
           shorthand already gets just below, so an ordinary bound-variable
           lookup (the overwhelmingly common case) never pays for this
           check. A bare type name used as a plain expression (`Vector`,
           `factor(Vector, n)`) becomes a first-class VType this way --
           found necessary for `::Type{X}` dispatch parameters. *)
        if is_recognized_elem_type n then VType (Types.canonical n)
        else (
          (* ...and a bare FUNCTION name used as a plain expression is that
             function, as a value. `f = double`, `filter(fell, balls)`,
             `sort(xs; by = weight)` -- all of which used to be
             `UndefVarError: double not defined`, because a lambda was a
             value while a `function` lived only inside the dispatch table.
             That split is not a Julia one, and it quietly cost every
             higher-order style there is: you could pass `b -> fell(b)` but
             not `fell`.

             The value is a closure that re-enters dispatch on each call, so
             it is the whole GENERIC function -- every method of it, chosen by
             the arguments it actually gets -- not the one method that
             happened to exist when the name was read. Its arity is taken from
             a method it has (they're what on_frame reads to decide whether to
             pass dt); with several methods of different arity, the first
             registered one names it, and dispatch still picks the real one at
             call time. *)
          match Hashtbl.find_opt Dispatch.methods n with
          | Some (m :: _) -> VClosure (List.length m.Dispatch.sig_, fun args -> Dispatch.call n args)
          | _ -> failwith msg))
    (* a bare type name as a value -- `Float64`, `Vector`, `Deque{Int64}`.
       Normalized so a first-class type value and a `::T` annotation agree
       on what they are naming (see Types.canonical). *)
    | ETypeExpr name -> VType (Types.canonical name)
    (* calling what an expression evaluated to (see Ast's EApply). A closure
       value, or a JS function held as a handle: dispatch resolves on a NAME,
       and there isn't one here -- `f()()` has already thrown away every name
       by the time the second call happens.

       `obj.meth(...)` is taken apart here rather than evaluated as an
       ordinary field read, because a JS method must keep its receiver: a
       get-then-call would lose `this`. *)
    | EApply (callee_e, arg_es) -> (
      let js_args () = Array.of_list (List.map (fun e -> js_of_value (eval_expr env e)) arg_es) in
      let call_value f =
        match f with
        | VClosure (_, impl) -> impl (List.map (eval_expr env) arg_es)
        | VJS jf -> value_of_js_shallow (Js_of_ocaml.Js.Unsafe.fun_call jf (js_args ()))
        | other -> failwith (Printf.sprintf "MethodError: objects of type %s are not callable" (tag other))
      in
      match callee_e with
      | EField (obj_e, meth) -> (
        match eval_expr env obj_e with
        | VJS o -> value_of_js_shallow (Js_of_ocaml.Js.Unsafe.meth_call o meth (js_args ()))
        | obj -> call_value (get_field obj meth))
      | _ -> call_value (eval_expr env callee_e))
    | EBinOp (":", lo, hi, _) -> (
      match eval_expr env lo, eval_expr env hi with
      | VInt a, VInt b -> VRange (a, 1, b)
      | ((VInt _ | VFloat _) as a), ((VInt _ | VFloat _) as b) -> VFRange (as_float a, 1.0, as_float b)
      | _ -> failwith "range bounds must be Int or Float")
    | ERangeStep (lo, step, hi) -> (
      match eval_expr env lo, eval_expr env step, eval_expr env hi with
      | VInt a, VInt s, VInt b -> VRange (a, s, b)
      | ((VInt _ | VFloat _) as a), ((VInt _ | VFloat _) as s), ((VInt _ | VFloat _) as b) ->
        VFRange (as_float a, as_float s, as_float b)
      | _ -> failwith "range bounds must be Int or Float")
    | ETernary (c, t, f) -> (
      match eval_expr env c with
      | VBool true -> eval_expr env t
      | VBool false -> eval_expr env f
      | _ -> failwith "ternary condition must be Bool")
    | EEnd -> VInt !current_end
    (* short-circuit: the right side must not even be evaluated when the left
       side already decides the result -- this can't be plain Dispatch.call,
       which would eagerly evaluate both operands first *)
    | EBinOp ("&&", a, b, _) -> (
      match eval_expr env a with
      | VBool false -> VBool false
      | VBool true -> (
        match eval_expr env b with
        | VBool r -> VBool r
        | _ -> failwith "&& operand must be Bool")
      | _ -> failwith "&& operand must be Bool")
    | EBinOp ("||", a, b, _) -> (
      match eval_expr env a with
      | VBool true -> VBool true
      | VBool false -> (
        match eval_expr env b with
        | VBool r -> VBool r
        | _ -> failwith "|| operand must be Bool")
      | _ -> failwith "|| operand must be Bool")
    | EBinOp ("=>", a, b, _) -> VPair (eval_expr env a, eval_expr env b)
    | EBinOp ("===", a, b, _) -> VBool (is_identical (eval_expr env a) (eval_expr env b))
    | EBinOp ("!==", a, b, _) -> VBool (not (is_identical (eval_expr env a) (eval_expr env b)))
    | EBinOp ("<:", EVar (sub, _), EVar (sup, _), _) ->
      (* `T <: BigInt` as an ordinary runtime subtype-test expression
         (found in Primes.jl), not just inside a `::`/struct-parent/`where`
         bound -- both sides deliberately NOT evaluated as variables, the
         same dispensation `isa`'s second argument already gets, since
         Tsubaki has no first-class type values *)
      VBool (Types.distance_to sub sup <> None)
    | EBinOp ("in", item_e, coll_e, _) ->
      (* `x in y` (found in Primes.jl, `if U in 0`) -- a plain Number RHS is
         its own singleton "collection" for `in`'s purposes, matching real
         Julia's `Base.in(x, y::Number) = x == y`; anything else is scanned
         via the same four iterable kinds SFor/EComprehension already share
         (iter_values). Equality reuses the real `==` dispatch (not raw
         OCaml `=`) so this respects Rational/Complex/struct `==` overloads
         the same way a plain `==` comparison already would. *)
      let item = eval_expr env item_e in
      let eq v = match Dispatch.call "==" [ item; v ] with VBool b -> b | _ -> false in
      (match eval_expr env coll_e with
      | (VInt _ | VFloat _) as scalar -> VBool (eq scalar)
      | coll -> VBool (List.exists eq (iter_values coll)))
    | EBinOp (op, a, b, cache) ->
      Dispatch.call_cached cache op [ eval_expr env a; eval_expr env b ]
    (* real Julia's `println(a, b, c)` puts NOTHING between its arguments.
       The separator this used to insert meant every program here had to be
       written around it (`println("x = ", v)` came out as `x =  v`, two
       spaces) -- and, more to the point, meant no Tsubaki program's output
       could ever be compared against the same source run under real Julia. *)
    | ECall ("println", args, _, _) ->
      print_endline (String.concat "" (List.map (fun a -> show (eval_expr env a)) args));
      VNothing
    | ECall ("print", args, _, _) ->
      print_string (String.concat "" (List.map (fun a -> show (eval_expr env a)) args));
      VNothing
    | ECall ("typeof", [ x_e ], _, _) -> VStr (tag (eval_expr env x_e))
    | ECall ("Dict", (_ :: _ as arg_es), [], _) ->
      (* real Julia's `Dict("a" => 1, "b" => 2)`, and `Dict(pairs)` for a list
         of them. Taken here rather than as a Dispatch method for the same
         reason println is: it is variadic, and a method carries one fixed
         arity. The 0-argument `Dict()` stays an ordinary method. *)
      let d = { dtbl = Hashtbl.create 8; dnext = 0 } in
      let put = function
        | VPair (k, v) -> dict_set d k v
        | VTuple [| k; v |] -> dict_set d k v
        | other -> failwith (Printf.sprintf "Dict: expected `key => value` pairs, got a %s" (tag other))
      in
      (match List.map (eval_expr env) arg_es with
      | [ VArr { cells; _ } ] -> Array.iter put (arrbuf_to_array cells)
      | [ VVec _ ] -> failwith "Dict: expected `key => value` pairs, got numbers"
      | args -> List.iter put args);
      VDict d
    | ECall ("isa", [ x_e; EVar (tname, _) ], _, _) ->
      (* tname is looked up ONLY to check for a genuinely bound first-class
         VType (e.g. a `::Type{X}`-dispatched where-var used as
         `isa(x, T)` inside the method body) -- anything else (unbound, or
         bound to a non-VType value) falls back to Tsubaki's original
         dispensation of taking the bare identifier itself as a literal
         type name, the same one struct-constructor calls already get, so
         the ubiquitous `isa(x, Int)`/`isa(x, MyStruct)` (never actually
         bound variables) keeps working exactly as before. *)
      let type_name = Types.canonical (match lookup_opt env tname with Some (VType s) -> s | _ -> tname) in
      VBool (Types.distance_to (tag (eval_expr env x_e)) type_name <> None)
    | ECall (name, args, kwargs, cache) -> (
      let argv = List.map (eval_expr env) args in
      (* a local variable shadowing the name as a closure wins, same as Julia
         (closures don't support kwargs, which is fine -- neither does Julia's
         arrow-lambda syntax without extra ceremony) *)
      match lookup_opt_shadow_free env name cache with
      | Some (VClosure (_, f)) -> f argv
      | Some (VJS jf) when Js_of_ocaml.Js.to_string (Js_of_ocaml.Js.typeof jf) = "function" ->
        (* the same shadowing rule, for a JS function held in a variable:
           `render(h, state)` is handed Preact's own `h`, and the `h(...)`
           inside the body is that. A handle that ISN'T callable falls
           through to the ordinary path, and gets the ordinary error. *)
        value_of_js_shallow (Js_of_ocaml.Js.Unsafe.fun_call jf (Array.of_list (List.map js_of_value argv)))
      | _ ->
        if name = "new" then (
          (* new(...)/new{T}(...) -- only valid while one of a struct's own
             inner constructors is directly running (see
             current_constructing_struct); builds the raw struct the exact
             same way the auto-generated default constructor would, never
             re-entering a user constructor (that's what would make this
             recurse forever) *)
          match !current_constructing_struct with
          | Some sname -> construct ~allow_partial:true sname argv
          | None -> failwith "UndefVarError: new can only be used inside a struct's own inner constructor")
        else if
          (* self-correcting absence cache for `Hashtbl.mem struct_defs
             name`, same principle as `lookup_opt_shadow_free` above, gated
             on `struct_defs_generation` (bumped only by `declare_struct`)
             instead of `global_generation` -- a stale/unset value just
             falls back to the real `Hashtbl.mem`, never trusted blindly.
             See PROFILE_FIB_MANDEL_QUICKSORT.md. *)
          (let is_struct =
             if cache.Dispatch.struct_gen = !struct_defs_generation && cache.Dispatch.struct_gen >= 0 then false
             else (
               let r = Hashtbl.mem struct_defs name in
               if not r then cache.Dispatch.struct_gen <- !struct_defs_generation;
               r)
           in
           is_struct && not (Hashtbl.mem Dispatch.methods name))
        then (
          (* a struct with at least one user-defined (inner) constructor is
             dispatched through those instead, just below -- only a struct
             with NO custom constructor still gets built directly *)
          match kwargs, argv with
          | _, [] when Hashtbl.mem kwdef_defaults name ->
            (* fresh keyword constructor for an @kwdef struct, with no base
               instance: StructName(; field=val, ...) or even StructName() for
               all-defaults. Each field takes its named override if given, else
               its @kwdef default (run now, in the caller's env, so a default
               like `pos = ZERO` sees globals); a field with neither is an
               error. *)
            let sd = Hashtbl.find struct_defs name in
            let defaults = Hashtbl.find kwdef_defaults name in
            let overrides = List.map (fun (k, e) -> k, eval_expr env e) kwargs in
            List.iter
              (fun (k, _) -> if not (List.mem k sd.field_names) then failwith (Printf.sprintf "type %s has no field %s" name k))
              overrides;
            construct name
              (List.map
                 (fun fname ->
                   match List.assoc_opt fname overrides with
                   | Some v -> v
                   | None -> (
                     match List.assoc_opt fname defaults with
                     | Some e -> eval_expr env e
                     | None -> failwith (Printf.sprintf "%s: field %s has no default, so it must be given as a keyword" name fname)))
                 sd.field_names)
          | [], _ -> construct name argv
          | _ :: _, [ (VStruct { kind; _ } as base) ] when kind = name ->
            (* partial-update constructor: StructName(existing; field=val, ...)
               copies every field from `existing`, then applies the named
               overrides -- real Julia has no built-in for this (only
               Setfield.jl's @set), but it's a general extension here: works
               for any struct, no per-type code needed *)
            let sd = Hashtbl.find struct_defs name in
            let overrides = List.map (fun (k, e) -> k, eval_expr env e) kwargs in
            List.iter
              (fun (k, _) -> if not (List.mem k sd.field_names) then failwith (Printf.sprintf "type %s has no field %s" name k))
              overrides;
            construct name
              (List.map
                 (fun fname -> match List.assoc_opt fname overrides with Some v -> v | None -> get_field base fname)
                 sd.field_names)
          | _ :: _, _ ->
            failwith (Printf.sprintf "%s(...; kwargs): keyword form only supported as %s(existing; field=val, ...)" name name))
        else (
          (* inside a module, a bare call resolves within it first (so code in
             `module M` calling `helper(...)` finds `M.helper`) -- falling
             back to the bare name for builtins and anything already
             `using`'d. Cheap when not inside a module at all: the `<> ""`
             check short-circuits before ever building `qualified` (`^`
             always allocates, even against `""` -- profiling `fib`/`mandel`
             found this running, and allocating, on every single call site
             regardless of whether any code anywhere uses `module`, see
             PROFILE_FIB_MANDEL_QUICKSORT.md). *)
          let resolved_name =
            if !current_module_prefix <> "" then (
              let qualified = !current_module_prefix ^ name in
              if Hashtbl.mem Dispatch.methods qualified then qualified else name)
            else name
          in
          current_kwargs := List.map (fun (k, e) -> k, eval_expr env e) kwargs;
          let result = Dispatch.call_cached cache resolved_name argv in
          current_kwargs := [];
          result))
    | EQualifiedCall (modname, member, args, kwargs, cache) -> (
      let argv = List.map (eval_expr env) args in
      let qualified = modname ^ "." ^ member in
      (* unlike a bare call, this is STRICT: the user explicitly asked for
         Name.member, so if that exact qualified name doesn't exist, this
         fails clearly rather than silently falling back to some unrelated
         same-named bare/global thing *)
      if Hashtbl.mem struct_defs qualified && not (Hashtbl.mem Dispatch.methods qualified) then
        construct qualified argv
      else if Hashtbl.mem Dispatch.methods qualified then (
        current_kwargs := List.map (fun (k, e) -> k, eval_expr env e) kwargs;
        let result = Dispatch.call_cached cache qualified argv in
        current_kwargs := [];
        result)
      else (
        (* `win.document.getElementById(id)` -- `win` is not a module at all,
           it is a VARIABLE holding a JS value. Nothing at parse time can
           tell that apart from `Outer.Inner.f(x)`, so it is decided here:
           the same lookup-fails-so-reinterpret dispensation EIndex already
           gets. Only a JS handle takes this path; everything else keeps the
           exact error it had. *)
        match js_receiver env modname with
        | Some o ->
          if kwargs <> [] then
            failwith (Printf.sprintf "%s.%s is a JS method, and JS has no keyword arguments" modname member);
          value_of_js_shallow
            (Js_of_ocaml.Js.Unsafe.meth_call o member (Array.of_list (List.map js_of_value argv)))
        | None -> failwith (Printf.sprintf "UndefVarError: %s not defined" qualified)))
    | EField (e, f) -> get_field (eval_expr env e) f
    | EAssign (n, rhs, cache) ->
      let v = eval_expr env rhs in
      assign_cached env n v cache;
      v
    | EFieldAssign (e, f, rhs) ->
      let v = eval_expr env rhs in
      set_field (eval_expr env e) f v;
      v
    (* `[]` is Julia's `Vector{Any}()` -- an empty list of ANYTHING, not an
       empty list of numbers. It used to be the latter (an all-numeric check
       over zero elements is vacuously true, so an empty literal fell into the
       numeric VVec branch below), which meant the most ordinary line a game
       writes -- `balls = []` and then `push!(balls, ball)` -- failed with
       `MethodError: no method matching push!(Vector, Ball)`, and the way out
       was to know about `Array{Ball}()` first. An empty literal says nothing
       about element type; taking it as a promise of numbers was us putting
       words in its mouth.

       A numeric list built up from `[]` still ends up somewhere numeric-
       friendly: draw_rects (and anything else wanting a flat float Vector)
       takes an all-numeric Array too, and `Vector(x)` converts explicitly. *)
    | EArrayLit [] -> mk_arr [||]
    | EArrayLit es ->
      let vs = Array.of_list (List.map (eval_expr env) es) in
      if Array.for_all (function VInt _ | VFloat _ -> true | _ -> false) vs then
        VVec (vecbuf_of_array (Array.map as_float vs)) (* all-numeric: keep the FFI-friendly form *)
      else mk_arr vs
    | ETuple es -> VTuple (Array.of_list (List.map (eval_expr env) es))
    | EMatrixLit rows ->
      VMat
        (Array.of_list
           (List.map (fun row -> Array.of_list (List.map (fun e -> as_float (eval_expr env e)) row)) rows))
    (* `x[]` on a BOUND variable is real Julia's 0-argument getindex (how an
       Observable is read: `score[]`), not an empty typed array -- the parser
       can't tell those two apart (`Float[]` and `score[]` are the same shape,
       see its own comment), so the choice lands here, and lands the way Julia
       makes it: a bound variable wins over a type name. Only reachable for the
       genuinely empty `[]`; `Float[1,2]` still means what it always did. *)
    | ETypedArrayNew (name, []) when lookup_opt env name <> None ->
      Dispatch.call_cached (Dispatch.new_cache ()) "getindex" [ Option.get (lookup_opt env name) ]
    | ETypedArrayNew (elem_ty, elements) ->
      (* `Float64[1.0, 2.0]` used to build a real Array{Float64} that then
         refused every Float handed to it *)
      let elem_ty = Types.canonical elem_ty in
      let vs = Array.of_list (List.map (eval_expr env) elements) in
      Array.iter
        (fun x ->
          if not (Dispatch.matches_alt (tag x) [ elem_ty ]) then
            failwith (Printf.sprintf "TypeError: Array{%s} cannot hold a %s" elem_ty (tag x)))
        vs;
      VArr { declared = Some elem_ty; cells = arrbuf_of_array vs }
    | ETypedArrayUndef (elem_ty, n_e) ->
      let elem_ty = Types.canonical elem_ty in
      let n = (match eval_expr env n_e with VInt n -> n | v -> failwith (Printf.sprintf "Vector{%s}(undef, n): n must be an Int, got %s" elem_ty (tag v))) in
      if n < 0 then failwith (Printf.sprintf "Vector{%s}(undef, n): n must be >= 0, got %d" elem_ty n);
      VArr { declared = Some elem_ty; cells = arrbuf_of_array (Array.make n VNothing) }
    | ETypedMatrixUndef (elem_ty, m_e, n_e) ->
      let elem_ty = Types.canonical elem_ty in
      let dim what e =
        match eval_expr env e with
        | VInt n -> n
        | v -> failwith (Printf.sprintf "Matrix{%s}(undef, m, n): %s must be an Int, got %s" elem_ty what (tag v))
      in
      let m = dim "m" m_e and n = dim "n" n_e in
      if m < 0 || n < 0 then
        failwith (Printf.sprintf "Matrix{%s}(undef, m, n): m and n must be >= 0, got %d, %d" elem_ty m n);
      VGenMat { declared = Some elem_ty; rows = m; cols = n; cells = Array.make (m * n) VNothing }
    | EIndex (e, idx_e) -> (
      (* container evaluated before the index expression, on purpose: `end`
         inside idx_e needs to already know this container's length *)
      let dispatch_index container =
        (match container with
        | VVec r -> current_end := vecbuf_length r
        | VArr { cells; _ } -> current_end := arrbuf_length cells
        | VTuple vs -> current_end := Array.length vs
        | _ -> ());
        match container, eval_expr env idx_e with
        | VVec r, VInt i ->
          if i < 1 || i > vecbuf_length r then failwith (Printf.sprintf "BoundsError: index %d" i)
          else VFloat (vecbuf_get r (i - 1)) (* Julia is 1-indexed *)
        | VVec r, VRange (a, s, b) ->
          (* a slice: v[2:end] or v[2:4] -- a fresh Vector, not a view *)
          let idxs = range_ints a s b in
          if List.exists (fun i -> i < 1 || i > vecbuf_length r) idxs then
            failwith "BoundsError: slice index out of range"
          else VVec (vecbuf_of_array (Array.of_list (List.map (fun i -> vecbuf_get r (i - 1)) idxs)))
        | VVec _, _ -> failwith "Vector index must be an Int or a Range"
        | VArr { cells; _ }, VInt i ->
          if i < 1 || i > arrbuf_length cells then failwith (Printf.sprintf "BoundsError: index %d" i)
          else arrbuf_get cells (i - 1)
        | VArr { declared; cells }, VRange (lo, s, hi) ->
          let idxs = range_ints lo s hi in
          if List.exists (fun i -> i < 1 || i > arrbuf_length cells) idxs then
            failwith "BoundsError: slice index out of range"
          else VArr { declared; cells = arrbuf_of_array (Array.of_list (List.map (fun i -> arrbuf_get cells (i - 1)) idxs)) }
        | VArr _, _ -> failwith "Array index must be an Int or a Range"
        | VMat rows, VTuple [| VInt i; VInt j |] ->
          (* A[i,j] -- Tsubaki's Matrix is only ever 2-D dense, so a bare pair
             of Ints is the only shape supported; `end`/ranges/single-Int
             row-or-column indexing aren't (a real, documented gap, same
             spirit as this file's other honestly-scoped limits) *)
          if i < 1 || i > Array.length rows then failwith (Printf.sprintf "BoundsError: row %d" i)
          else if j < 1 || j > Array.length rows.(0) then failwith (Printf.sprintf "BoundsError: column %d" j)
          else VFloat rows.(i - 1).(j - 1)
        | VMat _, _ -> failwith "Matrix index must be a pair of Ints, A[i,j]"
        | VGenMat { rows; cols; cells; _ }, VTuple [| VInt i; VInt j |] ->
          if i < 1 || i > rows then failwith (Printf.sprintf "BoundsError: row %d" i)
          else if j < 1 || j > cols then failwith (Printf.sprintf "BoundsError: column %d" j)
          else cells.(((i - 1) * cols) + (j - 1))
        | VGenMat _, _ -> failwith "Matrix index must be a pair of Ints, A[i,j]"
        | VComplexVec r, VInt i ->
          (* read-only -- eigen's own result, not a general-purpose Complex
             container anyone constructs and mutates by hand *)
          if i < 1 || i > Array.length !r then failwith (Printf.sprintf "BoundsError: index %d" i)
          else (
            let re, im = !r.(i - 1) in
            VComplex (re, im))
        | VComplexVec _, _ -> failwith "ComplexVector index must be an Int"
        | VComplexMat rows, VTuple [| VInt i; VInt j |] ->
          if i < 1 || i > Array.length rows then failwith (Printf.sprintf "BoundsError: row %d" i)
          else if j < 1 || j > Array.length rows.(0) then failwith (Printf.sprintf "BoundsError: column %d" j)
          else (
            let re, im = rows.(i - 1).(j - 1) in
            VComplex (re, im))
        | VComplexMat _, _ -> failwith "ComplexMatrix index must be a pair of Ints, A[i,j]"
        (* t[1] -- a Tuple indexes like everything else here. It couldn't, until
           now, which only became load-bearing once a Dict started handing its
           (key, value) pairs out as Tuples: `filter(p -> p[2] > 20, d)`. *)
        | VTuple vs, VInt i ->
          if i < 1 || i > Array.length vs then failwith (Printf.sprintf "BoundsError: index %d" i) else vs.(i - 1)
        | VTuple _, _ -> failwith "Tuple index must be an Int"
        (* d[k] -- a missing key is a KeyError, as in Julia (use get(d, k, default)
           to ask without raising) *)
        | VDict d, k -> (
          match dict_get d k with
          | Some v -> v
          | None -> failwith (Printf.sprintf "KeyError: key %s not found" (show k)))
        | _ -> failwith "indexing is only supported on Vector, Array, Matrix, or Dict"
      in
      match e with
      | EVar (name, cache) -> (
        match lookup_cached env name cache with
        | exception Failure msg ->
          (* real Julia's `T[1,2,3]` typed-array-literal shorthand is
             indistinguishable from ordinary indexing at parse time (both
             are IDENT immediately followed by "[") -- resolved HERE,
             exception-driven so ordinary indexing (the overwhelmingly
             common case) never pays for this check: only once looking
             `name` up as a bound variable has ALREADY failed do we ask
             whether it's a recognized type instead. `lookup_cached` only
             ever fails with exactly this UndefVarError, never anything
             else, so re-raising `msg` unchanged for an unrecognized name
             preserves the original error exactly. *)
          if is_recognized_elem_type name then (
            let elements = match idx_e with ETuple es -> es | single -> [ single ] in
            eval_expr env (ETypedArrayNew (name, elements)))
          else failwith msg
        | container -> dispatch_index container)
      | _ -> dispatch_index (eval_expr env e))
    | EIndexAssign (e, idx_e, rhs) -> (
      let container = eval_expr env e in
      (match container with
      | VVec r -> current_end := vecbuf_length r
      | VArr { cells; _ } -> current_end := arrbuf_length cells
      | _ -> ());
      match container, eval_expr env idx_e with
      | VVec r, VInt i ->
        if i < 1 || i > vecbuf_length r then failwith (Printf.sprintf "BoundsError: index %d" i)
        else (
          let v = as_float (eval_expr env rhs) in
          vecbuf_set r (i - 1) v;
          VFloat v)
      | VVec _, _ -> failwith "Vector index must be an Int"
      | VArr { declared; cells }, VInt i ->
        if i < 1 || i > arrbuf_length cells then failwith (Printf.sprintf "BoundsError: index %d" i)
        else (
          let v = eval_expr env rhs in
          (match declared with
          | Some t when not (Dispatch.matches_alt (tag v) [ t ]) ->
            failwith (Printf.sprintf "TypeError: Array{%s} cannot hold a %s" t (tag v))
          | _ -> ());
          arrbuf_set cells (i - 1) v;
          v)
      | VArr _, _ -> failwith "Array index must be an Int"
      | VMat rows, VTuple [| VInt i; VInt j |] ->
        if i < 1 || i > Array.length rows then failwith (Printf.sprintf "BoundsError: row %d" i)
        else if j < 1 || j > Array.length rows.(0) then failwith (Printf.sprintf "BoundsError: column %d" j)
        else (
          let v = as_float (eval_expr env rhs) in
          rows.(i - 1).(j - 1) <- v;
          VFloat v)
      | VMat _, _ -> failwith "Matrix index must be a pair of Ints, A[i,j]"
      | VGenMat { declared; rows; cols; cells }, VTuple [| VInt i; VInt j |] ->
        if i < 1 || i > rows then failwith (Printf.sprintf "BoundsError: row %d" i)
        else if j < 1 || j > cols then failwith (Printf.sprintf "BoundsError: column %d" j)
        else (
          let v = eval_expr env rhs in
          (match declared with
          | Some t when not (Dispatch.matches_alt (tag v) [ t ]) ->
            failwith (Printf.sprintf "TypeError: Matrix{%s} cannot hold a %s" t (tag v))
          | _ -> ());
          cells.(((i - 1) * cols) + (j - 1)) <- v;
          v)
      | VGenMat _, _ -> failwith "Matrix index must be a pair of Ints, A[i,j]"
      (* d[k] = v -- an absent key is CREATED here (that's what a Dict is for),
         unlike every indexed container above, where an out-of-range index is a
         BoundsError *)
      | VDict d, k ->
        let v = eval_expr env rhs in
        dict_set d k v;
        v
      | _ -> failwith "indexing is only supported on Vector, Array, Matrix, or Dict")
    | ELambda (params, body) ->
      (* same module-prefix capture as SFuncDecl, and the same def_prefix=""
         fast path, so a closure created inside a module still resolves bare
         calls within it when later invoked from anywhere else *)
      let def_prefix = !current_module_prefix in
      VClosure
        ( List.length params,
          fun argv ->
          let call_env = new_scope env in
          List.iter2 (fun p v -> bind call_env p v) params argv;
          let run_body () = try exec_stmt_list call_env body with Return_exc v -> v in
          if def_prefix = "" then run_body ()
          else (
            let saved = !current_module_prefix in
            current_module_prefix := def_prefix;
            match run_body () with
            | v ->
              current_module_prefix := saved;
              v
            | exception e ->
              current_module_prefix := saved;
              raise e))
    | EComprehension (body_e, [ (var, iter_e) ]) ->
      (* one `for` clause: collect raw values, then decide the result shape
         exactly like an array literal does -- all-numeric stays the
         FFI-friendly Vector, anything else becomes an Array *)
      let results =
        List.map
          (fun v ->
            let scope = new_scope env in
            bind_for_target scope var v;
            eval_expr scope body_e)
          (iter_values (eval_expr env iter_e))
      in
      let vs = Array.of_list results in
      (* an EMPTY result is an Array, the same answer `[]` already gives: with
         no elements, "every element is a number" is true of nothing, and
         calling the result a numeric Vector is a guess that then refuses the
         first thing put in it. (`[f(x) for x in xs]` over an empty xs, then
         `vcat` with an Array of anything: found in a real program, a noraneko
         drop's view, where the strip has no buttons yet.) *)
      if Array.length vs > 0 && Array.for_all (function VInt _ | VFloat _ -> true | _ -> false) vs then
        VVec (vecbuf_of_array (Array.map as_float vs))
      else mk_arr vs
    | EComprehension (body_e, [ (var1, iter1_e); (var2, iter2_e) ]) ->
      (* two `for` clauses, e.g. mandel's [f(r,i) for i=.., r=..] -- a genuine
         2D result, matching real Julia's size (length(clause1), length(clause2))
         with element [a,b] = body(clause1[a], clause2[b]). Same rule as the
         1-clause case above, one dimension up: collect raw values first, then
         decide the shape -- all-numeric stays the FFI-friendly Matrix
         (unchanged from before this generalization, still what mandel's own
         benchmark produces); anything else becomes a genuine 2-D
         Array-of-Array (row-major: the outer Array's cells are themselves
         row Arrays), so e.g. a struct-producing 2D comprehension no longer
         has to coerce through Float64. *)
      let vs1 = iter_values (eval_expr env iter1_e) in
      let vs2 = iter_values (eval_expr env iter2_e) in
      let raw_rows =
        List.map
          (fun v1 ->
            Array.of_list
              (List.map
                 (fun v2 ->
                   let scope = new_scope env in
                   bind_for_target scope var1 v1;
                   bind_for_target scope var2 v2;
                   eval_expr scope body_e)
                 vs2))
          vs1
      in
      if List.for_all (Array.for_all (function VInt _ | VFloat _ -> true | _ -> false)) raw_rows then
        VMat (Array.of_list (List.map (Array.map as_float) raw_rows))
      else mk_arr (Array.of_list (List.map mk_arr raw_rows))
    | EComprehension (_, _) ->
      failwith "comprehensions support at most 2 for-clauses (no N-dimensional array type)"
    | EQuote inner -> expr_to_value env inner
    | EQuoteSymbol name -> VSymbol (name, !current_hygiene_id)
    | EQuoteBlock stmts -> stmt_list_to_value env stmts
    | EInterp inner -> eval_expr env inner
    | EInterpAssign (_, _) -> failwith "$(...) = ... is only meaningful inside a quote"
    | EBlock stmts -> exec_stmt_list env stmts
    | EMacroCall (name, arg_exprs) -> (
      match find_macro name with
      | None -> failwith (Printf.sprintf "UndefVarError: @%s not defined" name)
      | Some (params, body) ->
        if List.length params <> List.length arg_exprs then
          failwith
            (Printf.sprintf "macro @%s expects %d argument(s), got %d" name (List.length params)
               (List.length arg_exprs));
        (* macro arguments are passed UNEVALUATED -- reified as quoted syntax,
           exactly what a real :(...) quote of that same expr would produce. *)
        let argv = List.map (expr_to_value env) arg_exprs in
        let macro_env = new_scope global in
        List.iter2 (bind macro_env) params argv;
        (* a fresh hygiene id for this ONE expansion: every symbol the
           macro's own quote/quote-block constructs while this runs gets
           tagged with it, so it can be renamed consistently (and only
           it -- nothing from outside this window) when splicing the
           result back in below *)
        let expansion_id = new_hygiene_id () in
        let saved_hygiene = !current_hygiene_id in
        current_hygiene_id := Some expansion_id;
        let result =
          Fun.protect
            ~finally:(fun () -> current_hygiene_id := saved_hygiene)
            (fun () -> try exec_stmt_list macro_env body with Return_exc v -> v)
        in
        let rename_table = Hashtbl.create 8 in
        eval_expr env (value_to_expr ~expansion_id ~rename_table result))

  (* --- quoting: Ast -> value, reifying parsed syntax as data (real Julia's
     Symbol/Expr). `env` is only ever used for EInterp ($-splices), which
     evaluate NORMALLY and splice the resulting value in directly (a value
     IS already in the right shape -- see EInterp's case). Every other case
     just walks the AST shape into an equivalent VSymbol/VExpr tree, tagging
     each name with the CURRENT hygiene id (`None` outside any macro
     expansion). Deliberately covers only what a real macro needs to build
     (literals, calls/operators, field/index (get and set), tuples, ternary,
     3-arg ranges, qualified calls, nested quotes, and the control-flow
     statement shapes below) -- see the comment on the catch-all cases for
     what's NOT quotable and why. *)
  and expr_to_value env (e : expr) : value =
    match e with
    | EInt n -> VInt n
    | EFloat f -> VFloat f
    | EStr s -> VStr s
    | EBool b -> VBool b
    | ENothing -> VNothing
    | EVar (name, _) -> VSymbol (name, !current_hygiene_id)
    | ETypeExpr name ->
      (* a type name, not a variable -- no hygiene renaming needed (it's a
         nominal, module-scoped reference, not a local binding a macro
         could ever collide with), unlike EVar's own VSymbol above *)
      VExpr { head = "typeexpr"; args = [| VStr name |] }
    | EInterp inner -> eval_expr env inner
    | EInterpAssign (target_e, rhs) -> (
      match eval_expr env target_e with
      | VSymbol (name, tag) -> VExpr { head = "="; args = [| VSymbol (name, tag); expr_to_value env rhs |] }
      | v ->
        failwith
          (Printf.sprintf "quoting: $(...) = ... needs the interpolated target to be a Symbol, got a %s"
             (tag v)))
    | EBinOp (op, a, b, _) ->
      VExpr { head = "call"; args = [| VSymbol (op, !current_hygiene_id); expr_to_value env a; expr_to_value env b |] }
    | ECall (_, _, _ :: _, _) -> failwith "quoting a call with keyword arguments isn't supported"
    | EApply _ ->
      (* a quoted "call" carries its callee as a Symbol (below); a computed
         one has no name to put there, and would need a head of its own on
         both sides of the quote/unquote pair. Same scope cut as keyword
         arguments just above. *)
      failwith "quoting a call on a computed callee (f()(x)) isn't supported"
    | ECall (name, args, [], _) ->
      VExpr
        { head = "call"
        ; args = Array.of_list (VSymbol (name, !current_hygiene_id) :: List.map (expr_to_value env) args)
        }
    | EField (obj, f) -> VExpr { head = "."; args = [| expr_to_value env obj; VSymbol (f, !current_hygiene_id) |] }
    | EAssign (name, rhs, _) ->
      VExpr { head = "="; args = [| VSymbol (name, !current_hygiene_id); expr_to_value env rhs |] }
    | EFieldAssign (obj, f, rhs) ->
      VExpr
        { head = "field="
        ; args = [| expr_to_value env obj; VSymbol (f, !current_hygiene_id); expr_to_value env rhs |]
        }
    | EIndex (obj, idx) -> VExpr { head = "ref"; args = [| expr_to_value env obj; expr_to_value env idx |] }
    | EIndexAssign (obj, idx, rhs) ->
      VExpr { head = "index="; args = [| expr_to_value env obj; expr_to_value env idx; expr_to_value env rhs |] }
    | ETuple es -> VExpr { head = "tuple"; args = Array.of_list (List.map (expr_to_value env) es) }
    | ETernary (c, t, f) ->
      VExpr { head = "if"; args = [| expr_to_value env c; expr_to_value env t; expr_to_value env f |] }
    | ERangeStep (a, s, b) ->
      VExpr { head = "range3"; args = [| expr_to_value env a; expr_to_value env s; expr_to_value env b |] }
    | EQualifiedCall (m, mem, args, [], _) ->
      VExpr
        { head = "modcall"
        ; args =
            Array.of_list
              (VSymbol (m, !current_hygiene_id) :: VSymbol (mem, !current_hygiene_id)
              :: List.map (expr_to_value env) args)
        }
    | EQualifiedCall (_, _, _, _ :: _, _) ->
      failwith "quoting a qualified call with keyword arguments isn't supported"
    | EQuote inner -> VExpr { head = "quoted"; args = [| expr_to_value env inner |] }
    | EQuoteSymbol name -> VSymbol (name, !current_hygiene_id)
    | EQuoteBlock stmts -> stmt_list_to_value env stmts
    (* real Julia's own `:vect` head -- an array LITERAL specifically (not
       Array{T}()/comprehensions/matrices below, which stay unsupported),
       needed so a macro body can build one (e.g. a fresh `query([...])`
       call site) via Expr(:vect, [...]) instead of only ever splicing in
       one unexamined from the call site. *)
    | EArrayLit es -> VExpr { head = "vect"; args = Array.of_list (List.map (expr_to_value env) es) }
    | EMatrixLit rows ->
      VExpr
        { head = "matrix"
        ; args =
            Array.of_list
              (List.map
                 (fun row -> VExpr { head = "row"; args = Array.of_list (List.map (expr_to_value env) row) })
                 rows)
        }
    | ELambda (params, body) ->
      (* params are a BINDING position, not structural -- tagged with the
         current hygiene id just like any other name a macro's own quote
         introduces, so value_to_expr's resolve_symbol can rename them
         consistently on splice-back (see the hygiene follow-up note there) *)
      VExpr
        { head = "lambda"
        ; args =
            Array.of_list
              (List.map (fun p -> VSymbol (p, !current_hygiene_id)) params @ [ stmt_list_to_value env body ])
        }
    | EComprehension (body_e, clauses) ->
      (* a clause's own loop variable is a BINDING position too, same as a
         lambda param above -- FVTuple's names are hygiene-tagged the same
         way, wrapped in a "tuple"-headed VExpr matching how SDestructure's
         own targets are already quoted *)
      let target_to_value = function
        | FVSingle v -> VSymbol (v, !current_hygiene_id)
        | FVTuple names ->
          VExpr
            { head = "tuple"; args = Array.of_list (List.map (fun n -> VSymbol (n, !current_hygiene_id)) names) }
      in
      VExpr
        { head = "comprehension"
        ; args =
            Array.of_list
              (expr_to_value env body_e
              :: List.map
                   (fun (target, iter_e) ->
                     VExpr { head = "genfor"; args = [| target_to_value target; expr_to_value env iter_e |] })
                   clauses)
        }
    | ETypedArrayNew (tname, elems) ->
      VExpr
        { head = "typedarray"
        ; args = Array.of_list (VSymbol (tname, !current_hygiene_id) :: List.map (expr_to_value env) elems)
        }
    | EMacroCall (name, arg_exprs) ->
      VExpr
        { head = "macrocall"
        ; args = Array.of_list (VSymbol (name, !current_hygiene_id) :: List.map (expr_to_value env) arg_exprs)
        }
    | EEnd | ETypedArrayUndef _ | ETypedMatrixUndef _ | EBlock _ ->
      failwith
        "quoting this kind of expression isn't supported (Vector{T}(undef, n), Matrix{T}(undef, m, n), \
         and a bare evaluated block can't appear inside a quote)"

  (* an elseif chain quotes as real Julia represents it: nested
     Expr(:if, cond, block, Expr(:if, ...)) rather than one flat node --
     `branches = []` is the base case (ran out of `elseif`s), producing
     either the trailing `else` block or VNothing, exactly what the single-
     branch case already produced before elseif chains were supported. *)
  and if_stmt_to_value env branches else_body : value =
    match branches with
    | [] -> (match else_body with Some eb -> stmt_list_to_value env eb | None -> VNothing)
    | (cond, body) :: rest ->
      VExpr
        { head = "if_stmt"
        ; args = [| expr_to_value env cond; stmt_list_to_value env body; if_stmt_to_value env rest else_body |]
        }

  and stmt_to_value env (s : stmt) : value =
    match s with
    | SLine _ -> VNothing (* filtered out by stmt_list_to_value before it gets here *)
    | SExpr e -> expr_to_value env e
    | SIf (branches, else_body) -> if_stmt_to_value env branches else_body
    | SFor (FVSingle var, iter, body) ->
      VExpr
        { head = "for"
        ; args = [| VSymbol (var, !current_hygiene_id); expr_to_value env iter; stmt_list_to_value env body |]
        }
    | SFor (FVTuple _, _, _) ->
      failwith "quoting a tuple-destructuring for-loop isn't supported -- only a single loop variable"
    | SWhile (cond, body) -> VExpr { head = "while"; args = [| expr_to_value env cond; stmt_list_to_value env body |] }
    | SReturn None -> VExpr { head = "return"; args = [||] }
    | SReturn (Some e) -> VExpr { head = "return"; args = [| expr_to_value env e |] }
    | SDestructure (targets, rhs) ->
      (* a per-target `::T` annotation doesn't round-trip through quoting --
         not disclosed as needed, and Expr's own real shape has no room for
         it anyway (`(a, b) = rhs` reifies as an ordinary `:tuple` head) *)
      VExpr
        { head = "destructure"
        ; args =
            [| VExpr { head = "tuple"; args = Array.of_list (List.map (fun (t, _) -> expr_to_value env t) targets) }
             ; expr_to_value env rhs
            |]
        }
    | SFuncDecl _ | SStructDecl _ | SAbstractDecl _ | STry _ | SModuleDecl _ | SUsing _ | SImport _
    | SMacroDecl _ | SExport _ | SMacroCall _ | SLocalTypedAssign _ ->
      failwith
        "quoting this kind of statement isn't supported (function/struct/abstract-type/module/macro \
         declarations, export, nested macro calls, and try/catch can't appear inside a quote)"

  and stmt_list_to_value env (stmts : stmt list) : value =
    (* line markers are scaffolding, not syntax -- a quoted block reifies the
       statements someone actually wrote, so they are dropped here rather
       than turning into stray elements of the quoted block *)
    let stmts = List.filter (function SLine _ -> false | _ -> true) stmts in
    VExpr { head = "block"; args = Array.of_list (List.map (stmt_to_value env) stmts) }

  (* --- unquoting: value -> Ast, splicing a macro's returned Symbol/Expr (or
     plain literal) back into real code. The inverse of expr_to_value/
     stmt_to_value above, structurally -- every head string produced there
     is consumed here. This is also where hygiene actually happens: a
     VSymbol tagged with THIS expansion's id gets renamed (once per
     distinct original name, memoized in rename_table so every occurrence
     agrees) to a fresh gensym'd name; anything else (untagged, or
     `esc`-stripped) passes through as the bare name, resolving at the
     splice site's own scope. Statement-shaped values (block/if/for/while/
     return/destructure) get wrapped in EBlock so the whole thing is always
     a single Ast.expr regardless of what shape the macro actually
     returned. *)
  and value_to_expr ~expansion_id ~rename_table (v : value) : expr =
    let resolve_symbol name tag =
      match tag with
      | Some id when id = expansion_id -> (
        match Hashtbl.find_opt rename_table name with
        | Some fresh -> fresh
        | None ->
          let fresh = Printf.sprintf "##%s#%d" name (new_hygiene_id ()) in
          Hashtbl.replace rename_table name fresh;
          fresh)
      | _ -> name
    in
    let rec ve v =
      match v with
      | VInt n -> EInt n
      | VFloat f -> EFloat f
      | VStr s -> EStr s
      | VBool b -> EBool b
      | VNothing -> ENothing
      | VType s -> ETypeExpr s
      | VFixedInt { bits; signed; v = n } ->
        (* no dedicated literal syntax for a fixed-width integer (no `5i8`
           token) -- splice it back as the equivalent conversion call
           instead, e.g. `UInt8(5)` *)
        ECall (fixed_int_tag bits signed, [ EInt n ], [], Dispatch.new_cache ())
      | VSymbol (name, tag) -> EVar (resolve_symbol name tag, new_var_cache ())
      (* NOTE: a "call"'s function/operator name, a "."/"field="'s field
         name, and a "modcall"'s module/member names are mostly STRUCTURAL --
         they identify WHAT to call or WHICH field, not a local variable
         the macro's expansion introduces, so none of them go through
         resolve_symbol (which would invent a FRESH gensym for anything
         tagged, including "+"/"println"). Only names in actual variable-
         binding/reference positions (a bare value, an assignment target, a
         for-loop/lambda/comprehension variable) do -- that's the whole
         distinction hygiene is about: `+`/`println`/a struct's `.x` must
         keep meaning what they always mean, while a macro-introduced `tmp`
         must not collide with the call site's own `tmp`.

         One narrow exception: a "call"'s callee CAN be a macro-local
         variable holding a closure (`f = x -> x*2; f(21)`), and that `f`
         WAS already hygienically renamed at its own assignment/lambda-name
         binding site. So a call's callee only reuses an ALREADY-established
         rename (never invents one) -- `rename_only`, not the general
         `resolve_symbol`. This depends on the binding-position occurrence
         being unquoted before this call's occurrence (true for the
         ordinary "define, then call" order every real macro uses; a
         local closure calling itself recursively by name is a known
         residual gap, not attempted here). *)
      | VExpr { head = "call"; args } when Array.length args >= 1 -> (
        let rename_only fname tag =
          match tag with
          | Some id when id = expansion_id -> Option.value (Hashtbl.find_opt rename_table fname) ~default:fname
          | _ -> fname
        in
        match args.(0) with
        | VSymbol (fname, tag) ->
          let fname = rename_only fname tag in
          let rest = List.map ve (Array.to_list (Array.sub args 1 (Array.length args - 1))) in
          (match rest with
          | [ a; b ]
            when List.mem fname
                   [ "+"; "-"; "*"; "/"; "%"; "^"; ">>>"; "<"; "<="; ">"; ">="; "=="; "!="; "&&"; "||"; ":" ]
            ->
            EBinOp (fname, a, b, Dispatch.new_cache ())
          | _ -> ECall (fname, rest, [], Dispatch.new_cache ()))
        | _ -> failwith "macro expansion: a quoted call's head must be a Symbol")
      | VExpr { head = "typeexpr"; args = [| VStr name |] } -> ETypeExpr name
      | VExpr { head = "."; args = [| obj; VSymbol (f, _) |] } -> EField (ve obj, f)
      | VExpr { head = "="; args = [| VSymbol (name, tag); rhs |] } ->
        EAssign (resolve_symbol name tag, ve rhs, new_var_cache ())
      | VExpr { head = "field="; args = [| obj; VSymbol (f, _); rhs |] } -> EFieldAssign (ve obj, f, ve rhs)
      | VExpr { head = "ref"; args = [| obj; idx |] } -> EIndex (ve obj, ve idx)
      | VExpr { head = "index="; args = [| obj; idx; rhs |] } -> EIndexAssign (ve obj, ve idx, ve rhs)
      | VExpr { head = "tuple"; args } -> ETuple (Array.to_list (Array.map ve args))
      | VExpr { head = "vect"; args } -> EArrayLit (Array.to_list (Array.map ve args))
      | VExpr { head = "if"; args = [| c; t; f |] } -> ETernary (ve c, ve t, ve f)
      | VExpr { head = "range3"; args = [| a; s; b |] } -> ERangeStep (ve a, ve s, ve b)
      | VExpr { head = "modcall"; args } when Array.length args >= 2 -> (
        match args.(0), args.(1) with
        | VSymbol (m, _), VSymbol (mem, _) ->
          let rest = List.map ve (Array.to_list (Array.sub args 2 (Array.length args - 2))) in
          EQualifiedCall (m, mem, rest, [], Dispatch.new_cache ())
        | _ -> failwith "macro expansion: a quoted qualified call's head must be two Symbols")
      | VExpr { head = "matrix"; args } ->
        EMatrixLit
          (Array.to_list
             (Array.map
                (function
                  | VExpr { head = "row"; args = row_args } -> Array.to_list (Array.map ve row_args)
                  | _ -> failwith "macro expansion: malformed quoted matrix row")
                args))
      | VExpr { head = "lambda"; args } when Array.length args >= 1 ->
        let n = Array.length args in
        let params' =
          Array.to_list (Array.sub args 0 (n - 1))
          |> List.map (function
               | VSymbol (p, tag) -> resolve_symbol p tag
               | _ -> failwith "macro expansion: a quoted lambda's params must be Symbols")
        in
        ELambda (params', vs_list args.(n - 1))
      | VExpr { head = "comprehension"; args } when Array.length args >= 1 ->
        let clauses =
          Array.to_list (Array.sub args 1 (Array.length args - 1))
          |> List.map (function
               | VExpr { head = "genfor"; args = [| VSymbol (v, tag); iter_v |] } ->
                 FVSingle (resolve_symbol v tag), ve iter_v
               | VExpr { head = "genfor"; args = [| VExpr { head = "tuple"; args = names }; iter_v |] } ->
                 let names' =
                   Array.to_list names
                   |> List.map (function
                        | VSymbol (v, tag) -> resolve_symbol v tag
                        | _ -> failwith "macro expansion: a quoted comprehension's tuple clause must be Symbols")
                 in
                 FVTuple names', ve iter_v
               | _ -> failwith "macro expansion: malformed quoted comprehension clause")
        in
        EComprehension (ve args.(0), clauses)
      | VExpr { head = "typedarray"; args } when Array.length args >= 1 -> (
        match args.(0) with
        | VSymbol (tname, _) ->
          ETypedArrayNew (tname, List.map ve (Array.to_list (Array.sub args 1 (Array.length args - 1))))
        | _ -> failwith "macro expansion: a quoted typed-array's head must be a Symbol")
      | VExpr { head = "macrocall"; args } when Array.length args >= 1 -> (
        match args.(0) with
        | VSymbol (name, _) -> EMacroCall (name, List.map ve (Array.to_list (Array.sub args 1 (Array.length args - 1))))
        | _ -> failwith "macro expansion: a quoted macro call's head must be a Symbol")
      | VExpr { head = "quoted"; args = [| inner |] } -> EQuote (ve inner)
      | VExpr { head = ("block" | "if_stmt" | "for" | "while" | "return" | "destructure"); _ } ->
        EBlock (vs_list v)
      | VExpr { head; args } ->
        failwith
          (Printf.sprintf "macro expansion: don't know how to un-quote Expr(:%s, ...) with %d arg(s)" head
             (Array.length args))
      | VTuple _ | VStruct _ | VClosure _ | VVec _ | VArr _ | VMat _ | VGenMat _ | VRange _ | VFRange _
      | VComplex _ | VRational _ | VUniformScaling _ | VComplexVec _ | VComplexMat _ | VSparseMat _ | VDict _
      | VJS _ | VPair _ ->
        failwith
          (Printf.sprintf "macro expansion: a macro must return quoted syntax (a Symbol/Expr) or a plain \
                            literal, got a %s"
             (tag v))
    and vs v : stmt =
      match v with
      | VExpr { head = "if_stmt"; args = [| cond; then_v; else_v |] } ->
        let then_body = vs_list then_v in
        let else_body = match else_v with VNothing -> None | ev -> Some (vs_list ev) in
        SIf ([ ve cond, then_body ], else_body)
      | VExpr { head = "for"; args = [| VSymbol (var, tag); iter; body |] } ->
        SFor (FVSingle (resolve_symbol var tag), ve iter, vs_list body)
      | VExpr { head = "while"; args = [| cond; body |] } -> SWhile (ve cond, vs_list body)
      | VExpr { head = "return"; args } -> SReturn (if Array.length args = 0 then None else Some (ve args.(0)))
      | VExpr { head = "destructure"; args = [| VExpr { head = "tuple"; args = targets }; rhs |] } ->
        SDestructure (Array.to_list (Array.map (fun t -> ve t, None) targets), ve rhs)
      | VExpr { head = "block"; args } when Array.length args = 1 -> vs args.(0)
      | _ -> SExpr (ve v)
    and vs_list v : stmt list =
      match v with
      | VExpr { head = "block"; args } -> Array.to_list (Array.map vs args)
      | _ -> [ vs v ]
    in
    ve v

  (* SMacroCall needs the macro's result as a real stmt LIST to splice
     directly into the surrounding statement sequence (not wrapped in
     EBlock, which is only for splicing into an expression POSITION) --
     reuses value_to_expr as-is rather than duplicating its internals:
     a stmt-shaped result already comes back as `EBlock stmts` from there
     (see its own "block"/"if_stmt"/... case), so unwrap that; anything
     else is a plain expression, treated as one expression-statement. *)
  and value_to_stmt_list ~expansion_id ~rename_table (v : value) : stmt list =
    match value_to_expr ~expansion_id ~rename_table v with
    | EBlock stmts -> stmts
    | e -> [ SExpr e ]

  (* binds one already-evaluated argument to its param -- a plain name,
     (DataStructures.jl's `deque.jl`: `(cb, i) = default`) a tuple pattern
     unpacked the same way SDestructure's own targets are, or a `::Type{X}`
     dispatch parameter's own where-bound variable(s) (see type_pattern) --
     Dispatch already verified `v` matches this param's registered alt (see
     param_sig_alt), so the shape checks below can never actually fail in
     practice; they're there for a clear error instead of a silent wrong
     answer if that invariant were ever violated. *)
  and bind_one_param call_env p v =
    match p.ptypepattern with
    | Some (TPMatch _) -> () (* pure dispatch-time match, nothing to bind *)
    | Some (TPWhole (var, _)) -> (
      match v with
      | VType _ -> bind call_env var v
      | _ -> failwith (Printf.sprintf "expected a Type argument for %s, got a %s" var (tag v)))
    | Some (TPNested (outer, var)) -> (
      match v with
      | VType s -> (
        match strip_type_wrapper outer s with
        | Some inner -> bind call_env var (VType inner)
        | None -> failwith (Printf.sprintf "expected a Type{%s{...}} argument, got Type{%s}" outer s))
      | _ -> failwith (Printf.sprintf "expected a Type argument for %s, got a %s" var (tag v)))
    | None -> (
      match p.pdestructure with
      | Some names -> (
        match v with
        | VTuple vs when Array.length vs = List.length names ->
          List.iteri (fun i n -> bind call_env n vs.(i)) names
        | VTuple vs ->
          failwith
            (Printf.sprintf "cannot destructure a %d-tuple into %d parameters" (Array.length vs)
               (List.length names))
        | _ -> failwith (Printf.sprintf "cannot destructure a %s into parameter %s" (tag v) p.pname))
      | None -> bind call_env p.pname v)

  (* argv may be shorter than params -- any params past the end fall back to
     their own `pdefault`, evaluated in this same call_env so a later
     default can see an earlier param already bound (`f(a, b=a+1)`).
     Dispatch resolution (see `param_arity_range`) guarantees argv is never
     longer than params, and never shorter than a required (defaultless)
     prefix. *)
  and bind_params call_env params argv =
    match params, argv with
    | [], [] -> ()
    | p :: prest, v :: vrest ->
      bind_one_param call_env p v;
      bind_params call_env prest vrest
    | p :: prest, [] ->
      let d = match p.pdefault with Some d -> d | None -> assert false in
      bind_one_param call_env p (eval_expr call_env d);
      bind_params call_env prest []
    | [], _ :: _ -> assert false

  (* a keyword param: passed value if the caller supplied one (via
     `current_kwargs`), else its own default expression, evaluated fresh in
     this call's own scope -- with an optional `::T` (`check::Bool = true`,
     found in Primes.jl) enforced on the actual value ending up bound,
     whichever of the two it came from, the same on-this-assignment-only way
     a positional param's own `::T` already is. *)
  and bind_kwparam call_env (kname, ty, default_e) =
    let v =
      match List.assoc_opt kname !current_kwargs with
      | Some v -> v
      | None -> eval_expr call_env default_e
    in
    if not (Dispatch.matches_alt (tag v) ty) then
      failwith (Printf.sprintf "TypeError: %s::%s cannot hold a %s" kname (String.concat "|" ty) (tag v));
    bind call_env kname v

  (* used by SDestructure: a, b = ... targets can be any lvalue-shaped expr,
     not just a bare name -- a[i], a[j] = a[j], a[i] is a real in-place swap *)
  and assign_lvalue env target v =
    match target with
    | EVar (n, _) -> assign env n v
    | EField (oe, f) -> set_field (eval_expr env oe) f v
    | EIndex (oe, idx_e) -> (
      match eval_expr env oe, eval_expr env idx_e with
      | VVec r, VInt i ->
        if i < 1 || i > vecbuf_length r then failwith (Printf.sprintf "BoundsError: index %d" i)
        else vecbuf_set r (i - 1) (as_float v)
      | VArr { declared; cells }, VInt i ->
        if i < 1 || i > arrbuf_length cells then failwith (Printf.sprintf "BoundsError: index %d" i)
        else (
          (match declared with
          | Some t when not (Dispatch.matches_alt (tag v) [ t ]) ->
            failwith (Printf.sprintf "TypeError: Array{%s} cannot hold a %s" t (tag v))
          | _ -> ());
          arrbuf_set cells (i - 1) v)
      | _ -> failwith "invalid destructuring index target")
    | _ -> failwith "invalid destructuring target"

  (* Julia semantics: every statement is an expression -- a block's value is the
     value of its last statement, and `return` short-circuits via an exception.
     `and`, not `let rec`, on purpose: ELambda's multi-statement body (below,
     in eval_expr) needs to call exec_stmt_list, so they're one recursive group. *)
  and exec_stmt env (s : stmt) : value =
    match s with
    (* the only thing that moves the reported source position -- see Ast's
       SLine. Yields nothing, so it can never become a block's value. *)
    | SLine n ->
      current_line := n;
      VNothing
    | SExpr e -> eval_expr env e
    | SReturn None -> raise (Return_exc VNothing)
    | SReturn (Some e) -> raise (Return_exc (eval_expr env e))
    | SDestructure (targets, rhs) -> (
      let v = eval_expr env rhs in
      match v with
      | VTuple vs ->
        if Array.length vs <> List.length targets then
          failwith
            (Printf.sprintf "cannot destructure a %d-tuple into %d targets" (Array.length vs)
               (List.length targets));
        List.iteri
          (fun i (t, ty) ->
            let tv = vs.(i) in
            (match t, ty with
            | EVar (n, _), Some ty when not (Dispatch.matches_alt (tag tv) ty) ->
              failwith (Printf.sprintf "TypeError: %s::%s cannot hold a %s" n (String.concat "|" ty) (tag tv))
            | _ -> ());
            assign_lvalue env t tv)
          targets;
        v
      | _ ->
        failwith
          (Printf.sprintf "cannot destructure a %s into %d targets" (tag v) (List.length targets)))
    | SLocalTypedAssign (name, ty, rhs) ->
      let v = eval_expr env rhs in
      if not (Dispatch.matches_alt (tag v) ty) then
        failwith (Printf.sprintf "TypeError: %s::%s cannot hold a %s" name (String.concat "|" ty) (tag v));
      assign env name v;
      v
    | STry (body, catchvar, catch_body) -> (
      (* both a user `error(...)`/`throw(...)` (JuliaError) and the
         interpreter's own MethodError/UndefVarError/etc. (Failure) are
         catchable, matching how Julia's built-in exceptions are ordinary
         catchable objects too. `Failure`'s raw string becomes a real typed
         VStruct (DimensionMismatch/MethodError/.../ErrorException) via
         `exn_of_failure_message` -- see that function's own comment for
         why this one choke point covers every `failwith` site in the file
         without touching any of them individually; `e isa DimensionMismatch`
         and `e.msg` both work on the result. *)
      (* A raised error leaves the source position and the frame stack sitting
         exactly where it happened -- nothing unwinds them, which is what lets
         the top level report the place (see tree_walk_impl). So catching one
         is where they get put back: this handler is already here, and paying
         for the bookkeeping HERE costs one save per `try`, where doing it on
         the way out cost one exception handler per call. *)
      let entered = here () in
      try exec_stmt_list (new_scope env) body with
      | JuliaError v ->
        restore_site entered;
        let scope = new_scope env in
        Option.iter (fun n -> bind scope n v) catchvar;
        exec_stmt_list scope catch_body
      | Failure msg ->
        restore_site entered;
        let scope = new_scope env in
        Option.iter (fun n -> bind scope n (exn_of_failure_message msg)) catchvar;
        exec_stmt_list scope catch_body)
    | SAbstractDecl (name, parent) ->
      declare_abstract
        (!current_module_prefix ^ name)
        ~parent:(resolve_type_name (Option.value parent ~default:"Any"));
      VNothing
    | SStructDecl { mutable_; name; parent; type_params; fields; constructors; kwdefaults = _ } ->
      let full_name = !current_module_prefix ^ name in
      declare_struct ~mutable_ full_name
        ~parent:(resolve_type_name (Option.value parent ~default:"Any"))
        ~type_params
        (List.map (fun f -> f.fname) fields)
        (List.map (fun f -> List.map resolve_type_name f.ftype) fields);
      (* an inner constructor lives in the SAME namespace a struct's own
         (auto-generated) constructor call would look up -- registering at
         least one here is what tells ECall to dispatch through these
         instead of building the struct directly (see ECall's eval) *)
      let def_env = env in
      List.iter
        (fun (params, kwparams, body) ->
          let sig_ = List.map param_sig_alt params in
          let n_required, n_total = param_arity_range params in
          let impl argv =
            let call_env = new_scope def_env in
            bind_params call_env params argv;
            List.iter (bind_kwparam call_env) kwparams;
            let saved = !current_constructing_struct in
            current_constructing_struct := Some full_name;
            Fun.protect
              ~finally:(fun () -> current_constructing_struct := saved)
              (fun () -> try exec_stmt_list call_env body with Return_exc v -> v)
          in
          for k = n_required to n_total do
            Dispatch.defmethod full_name (take k sig_) impl
          done)
        constructors;
      VNothing
    | SFuncDecl (name, params, kwparams, body, fcache) ->
      (* offer this method to the Host VM's inliner. Registered under the name
         a CALL SITE writes -- so inside `module M` it registers as "M.f",
         which a bare `f(...)` never matches: module code just doesn't get
         inlined (correct, only slower). Compile decides for itself whether the
         shape is safe; see Compile.inline_methods. *)
      Compile.register_inlinable (!current_module_prefix ^ name) params kwparams body;
      let sig_ = List.map param_sig_alt params in
      (* close over the environment this `function` was declared in -- same as
         ELambda, so a function declared inside another function's body can see
         that function's locals. At the top level `env` is just `global`, so
         this doesn't change anything for the common case. *)
      let def_env = env in
      (* both functions AND struct/abstract-type names are namespaced by
         module now (registered as "M.name" inside `module M`) -- see
         resolve_type_name's comment for how field/parameter/parent type
         references to another in-module type get resolved consistently
         with this. *)
      let def_prefix = !current_module_prefix in
      (* which FILE this function was written in, captured the same way the
         module prefix just above is. A function declared in an `include`d
         file is called long after that include finished and put the outer
         file back, so without this its errors would be reported against the
         caller's file with the callee's line -- a position that belongs to
         neither. *)
      let def_file = !current_file in
      let tree_walk_impl argv =
        let call_env = new_scope def_env in
        bind_params call_env params argv;
        List.iter (bind_kwparam call_env) kwparams;
        let inner () = try exec_stmt_list call_env body with Return_exc v -> v in
        (* One traceback frame per Tsubaki-level call: this function's name,
           and the line the CALLER was on when it made the call. The caller's
           line and file are restored on the way out -- without that, an error
           in `f(g(x))` raised by `f` would be reported at whatever line `g`
           finished on.

           Restored only on the way out through a RETURN. An error deliberately
           leaves all of it exactly as it stood where it was raised, which is
           what the report wants to read; whoever catches it puts it back
           (Eval's STry, or the top level in Main/Repl). The first version of
           this did unwind carefully, snapshotting the stack at the innermost
           frame -- correct, and it cost an exception handler installed on
           every single call: +14% on `fib(25)`, measured. Nothing here is
           worth that, so the handler is gone. *)
        let run_body () =
          let caller_line = !current_line and caller_file = !current_file in
          push_frame name caller_line;
          (* physical comparison, and skipped entirely in the overwhelmingly
             common single-file case where both are the same string *)
          if def_file != caller_file then current_file := def_file;
          let v = inner () in
          pop_frame ();
          current_line := caller_line;
          if def_file != caller_file then current_file := caller_file;
          v
        in
        (* a module-scoped function's body must see its OWN module as
           current (so a bare call inside it resolves within that module,
           regardless of which module the CALLER is currently in) --
           skipped entirely at def_prefix = "" (the overwhelmingly common,
           perf-sensitive top-level case) so this costs nothing there *)
        if def_prefix = "" then run_body ()
        else (
          let saved = !current_module_prefix in
          current_module_prefix := def_prefix;
          match run_body () with
          | v ->
            current_module_prefix := saved;
            v
          | exception e ->
            current_module_prefix := saved;
            raise e)
      in
      (* zero-parameter functions only get a shot at bytecode compilation
         (see Compile's own module comment for why) -- anything the
         compiler can't handle, or any function that takes arguments at
         all, keeps running through the ordinary tree-walking closure
         above, completely unchanged. `fcache` is a JIT-style compile
         cache OWNED BY THIS DECLARATION SITE (allocated once at parse
         time, see Runtime.funcdecl_cache): the first time this exact
         `function ... end` is EVALUATED, try_compile runs once and the
         decision (eligible + its bytecode, or ineligible) is remembered;
         every later evaluation of the SAME site -- e.g. a function
         declared inside a loop body, or inside another function re-
         declaring it on every call -- reuses that decision instead of
         recompiling an AST that hasn't changed and never will. *)
      let impl =
        if params = [] && kwparams = [] then (
          match fcache.fc_state with
          | FC_compiled (encoded, nslots) -> fun _argv -> run_bytecode encoded nslots
          | FC_host_compiled (prog, nslots) -> fun _argv -> Host.run prog nslots
          | FC_ineligible -> tree_walk_impl
          | FC_unattempted -> (
            match Compile.try_compile body with
            | Some (code, nslots) ->
              let encoded = Compile.encode code in
              fcache.fc_state <- FC_compiled (encoded, nslots);
              fun _argv -> run_bytecode encoded nslots
            | None -> (
              (* not eligible for the restricted numeric ISA (no structs, no
                 calls, no strings there at all) -- try the broader Host
                 path before giving up to the tree-walking interpreter. See
                 Compile.try_compile_host's own comment for what it accepts. *)
              match Compile.try_compile_host body with
              | Some (prog, nslots) ->
                fcache.fc_state <- FC_host_compiled (prog, nslots);
                fun _argv -> Host.run prog nslots
              | None ->
                fcache.fc_state <- FC_ineligible;
                tree_walk_impl)))
        else tree_walk_impl
      in
      (* one Dispatch entry per arity a trailing positional default allows
         (see param_arity_range) -- all share the SAME impl; bind_params
         pads whatever params argv didn't reach from their own defaults,
         however many args this particular arity actually supplies. *)
      let n_required, n_total = param_arity_range params in
      for k = n_required to n_total do
        Dispatch.defmethod (def_prefix ^ name) (take k sig_) impl
      done;
      (* A `function` declared INSIDE another function's body is ALSO bound as
         an ordinary local, holding a closure over THIS invocation's scope.

         Without that it exists only as a method on the global generic
         function of its name -- and `defmethod` replaces a same-signature
         method, so calling a factory twice does not make two closures, it
         makes the second replace the first, and every value handed out
         (before or after) resolves by name to that one:

             function counter()
                 n = 0
                 function bump()
                     n = n + 1
                     return n
                 end
                 return bump
             end
             a = counter(); b = counter()
             a(); a(); b()      # 1, 2, 3 -- one counter, not two

         Both lookup paths already prefer a local binding -- ECall consults
         lookup_opt_shadow_free before dispatch, EVar consults lookup_cached
         before falling back to "a bare function name is that function" -- so
         this needs no new resolution machinery, only the binding itself. The
         global registration stays exactly as it was, and is what everything
         below falls back to.

         Two deliberate limits, each falling back to precisely the old
         behavior rather than to anything worse:
         - a function with KEYWORD parameters isn't bound locally, because
           ECall's local-closure branch passes positional arguments only;
         - a call whose arguments don't match this method's own signature
           re-enters ordinary dispatch, so several same-named inner methods
           still choose by type the way they did before.

         Declared inside an `if`/`for` inside a function, the binding lives in
         that block's scope and is gone after it -- there, the global
         registration is still the whole story, unchanged. *)
      if inside_function_body () && kwparams = [] then (
        let local_impl argv =
          let k = List.length argv in
          if k >= n_required && k <= n_total
             && Dispatch.applicable { Dispatch.sig_ = take k sig_; impl } (List.map tag argv)
          then impl argv
          else Dispatch.call (def_prefix ^ name) argv
        in
        bind env name (VClosure (n_total, local_impl)));
      VNothing
    | SIf (branches, else_body) ->
      let rec try_branches = function
        | [] -> (
          match else_body with
          | Some b -> exec_stmt_list (new_scope env) b
          | None -> VNothing)
        | (cond, body) :: rest -> (
          match eval_expr env cond with
          | VBool true -> exec_stmt_list (new_scope env) body
          | VBool false -> try_branches rest
          | _ -> failwith "if condition must be Bool")
      in
      try_branches branches
    | SFor (target, iter_e, body) ->
      iter_values_do (eval_expr env iter_e) (fun v ->
          let scope = new_scope env in
          bind_for_target scope target v;
          ignore (exec_stmt_list scope body));
      VNothing
    | SWhile (cond, body) ->
      let continue_ = ref true in
      while !continue_ do
        match eval_expr env cond with
        | VBool true -> ignore (exec_stmt_list (new_scope env) body)
        | VBool false -> continue_ := false
        | _ -> failwith "while condition must be Bool"
      done;
      VNothing
    | SModuleDecl (name, body) ->
      (* run the body's declarations once, under this module's prefix --
         nesting (a `module` inside a `module`) falls out for free, since
         this just concatenates onto whatever prefix was already active.
         Executed against the SAME env (not a fresh scope): plain variable
         assignments inside a module body are deliberately not namespaced,
         so they land wherever they would if the `module ... end` wrapper
         weren't there at all -- see README. *)
      let saved = !current_module_prefix in
      current_module_prefix := saved ^ name ^ ".";
      ignore (exec_stmt_list env body);
      current_module_prefix := saved;
      VNothing
    | SUsing name ->
      use_module name;
      VNothing
    | SImport (name, members) ->
      import_module name members;
      VNothing
    | SMacroDecl (name, params, body) ->
      (* namespaced under the current module prefix (see find_macro above) --
         a macro declared at top level (prefix "") still registers bare, as
         before *)
      Hashtbl.replace macros (!current_module_prefix ^ name) (params, body);
      VNothing
    | SExport _ -> VNothing
    | SMacroCall ("kwdef", inner) ->
      (* @kwdef struct T ... end -- declare the struct exactly as normal, then
         record its field defaults so `T(; field=val, ...)` can construct fresh
         (see the ECall keyword-construct path). Gating the registration here,
         rather than in SStructDecl, is what keeps a *bare* struct that happens
         to carry a `field = default` from silently gaining a keyword ctor. *)
      (match inner with
       | SStructDecl { name; kwdefaults; _ } ->
         ignore (exec_stmt env inner);
         if kwdefaults <> [] then Hashtbl.replace kwdef_defaults (!current_module_prefix ^ name) kwdefaults
       | _ -> failwith "@kwdef expects a struct declaration");
      VNothing
    | SMacroCall (name, inner) ->
      if Hints.is_inert_hint_macro name then
        (* a real Julia compiler hint (@inline, @inbounds, ...) -- never
           changes behavior here, only ever codegen in real Julia, so the
           wrapped statement just runs exactly as if the annotation weren't
           there at all *)
        exec_stmt env inner
      else (
        match find_macro name with
        | None -> failwith (Printf.sprintf "UndefVarError: @%s not defined" name)
        | Some (params, body) ->
          if List.length params <> 1 then
            failwith
              (Printf.sprintf "macro @%s expects %d argument(s), got 1" name (List.length params));
          (* the wrapped statement is passed to the macro UNEVALUATED, same
             as EMacroCall's arguments -- reified via stmt_to_value, which
             only accepts the statement shapes already supported inside an
             ordinary quote (SIf/SFor/SWhile/SReturn/SDestructure/SExpr);
             anything else (a nested function/struct declaration, say)
             raises the same clear "not supported" error it already does
             for quoting *)
          let argv = [ stmt_to_value env inner ] in
          let macro_env = new_scope global in
          List.iter2 (bind macro_env) params argv;
          let expansion_id = new_hygiene_id () in
          let saved_hygiene = !current_hygiene_id in
          current_hygiene_id := Some expansion_id;
          let result =
            Fun.protect
              ~finally:(fun () -> current_hygiene_id := saved_hygiene)
              (fun () -> try exec_stmt_list macro_env body with Return_exc v -> v)
          in
          let rename_table = Hashtbl.create 8 in
          let expanded_stmts = value_to_stmt_list ~expansion_id ~rename_table result in
          exec_stmt_list env expanded_stmts)

  and exec_stmt_list env stmts : value =
    match stmts with
    | [] -> VNothing
    | [ s ] -> exec_stmt env s
    | s :: rest ->
      ignore (exec_stmt env s);
      exec_stmt_list env rest

  (* eval(quoted) -- runs a Symbol/Expr (or plain literal) as real code in
     the global scope, real Julia's actual `eval`. `expansion_id:(-1)` is a
     sentinel no real macro expansion ever uses (those start at 1), so this
     never renames anything -- exactly right for a plain top-level eval call
     with no active hygiene context of its own. *)
  let () =
    Dispatch.defmethod "eval" [ [ "Any" ] ] (function
      | [ v ] -> eval_expr global (value_to_expr ~expansion_id:(-1) ~rename_table:(Hashtbl.create 0) v)
      | _ -> assert false)

  (* to_wgsl(quoted_kernel, buffers) -- compiles a QUOTED (see :(...)/
     quote...end) block of code into real WGSL source text for a GPU
     compute kernel, reusing the exact same quote-reification machinery
     `eval` above does (`value_to_stmt_list`, not a live function-body
     lookup -- see Compile.Wgsl's own doc comment for why a quote is the
     natural input shape here, not a function name). `buffers` is a Dict
     mapping each buffer's name (String) to its tsubaki-gpu BindingKind
     (String: "storage-read" / "storage-read-write" / "uniform"), in
     Dict's own insertion order -- which becomes the binding INDEX, the
     same positional convention gpu/src/lib.rs's own `bindingKinds`
     already uses, so the result can be handed straight to
     `create_pipeline(wgsl, "main", bindingKinds)` with zero translation
     on the caller's side. This only ever COMPILES text -- it never calls
     the GPU itself -- though `examples/wgsl_double.jl` chains straight
     into `create_pipeline`/`dispatch`/`read_buffer` right after this
     call anyway, since Eval's real async support (bin/async.ml, see
     README) already makes that path read as ordinary synchronous Tsubaki
     code. A body outside the supported restricted subset is a real,
     clear error, not a silent partial result -- same "real errors over
     silent wrongness" policy as `create_pipeline`'s own WGSL-syntax-
     error path in Rust. *)
  let () =
    Dispatch.defmethod "to_wgsl" [ [ "Any" ]; [ "Dict" ] ] (function
      | [ v; VDict d ] ->
        let stmts = value_to_stmt_list ~expansion_id:(-1) ~rename_table:(Hashtbl.create 0) v in
        let buffers =
          List.map
            (fun (k, v) ->
              match k, v with
              | VStr name, VStr kind -> name, kind
              | _ -> failwith "to_wgsl: buffers Dict must map String buffer names to String binding kinds")
            (dict_pairs d)
        in
        (match Compile.Wgsl.try_compile stmts buffers with
        | Some wgsl -> VStr wgsl
        | None ->
          failwith
            "to_wgsl: kernel body outside the supported numeric/buffer subset (see Compile.Wgsl's doc comment for exactly what's eligible)")
      | _ -> assert false)

  (* to_glsl(vertex_kernel, fragment_kernel, uniforms) -- the same idea as
     to_wgsl above, but for real GLSL ES 3.00 (WebGL2's actual shading
     language), as a VERTEX+FRAGMENT pair rather than a compute kernel --
     WebGL2 has no compute stage at all (see Compile.Glsl's own doc
     comment for why that rules out mirroring to_wgsl's shape here).
     `vertex_kernel`/`fragment_kernel` are both quoted blocks, same
     reification as to_wgsl. `uniforms` is a Dict mapping each uniform's
     name (String) to its type (String: "Float", the name of an already-
     declared vecN-eligible struct like "Vec2"/"Vec3"/"Vec4", or "mat4"),
     readable as that type from EITHER kernel. Returns a 2-element Array
     `[vertexGlsl, fragmentGlsl]` -- there's no single `create_pipeline`-
     shaped sink to hand both to yet (no raw-WebGL2 render path exists in
     tsubaki-gpu itself), so this is foundational: real, runnable GLSL
     text, verified directly against a real WebGL2 context (see README),
     not yet wired into a full tsubaki-gpu execution path. *)
  let () =
    Dispatch.defmethod "to_glsl" [ [ "Any" ]; [ "Any" ]; [ "Dict" ] ] (function
      | [ vv; fv; VDict d ] ->
        let vertex_stmts = value_to_stmt_list ~expansion_id:(-1) ~rename_table:(Hashtbl.create 0) vv in
        let fragment_stmts = value_to_stmt_list ~expansion_id:(-1) ~rename_table:(Hashtbl.create 0) fv in
        let uniforms =
          List.map
            (fun (k, v) ->
              match k, v with
              | VStr name, VStr type_name -> name, type_name
              | _ -> failwith "to_glsl: uniforms Dict must map String names to String types")
            (dict_pairs d)
        in
        let compiled stage stmts =
          match Compile.Glsl.compile_stage stage stmts uniforms with
          | Some src -> src
          | None ->
            failwith
              (Printf.sprintf
                 "to_glsl: %s kernel body outside the supported numeric/uniform subset (see Compile.Glsl's doc comment for exactly what's eligible)"
                 (match stage with `Vertex -> "vertex" | `Fragment -> "fragment"))
        in
        mk_arr [| VStr (compiled `Vertex vertex_stmts); VStr (compiled `Fragment fragment_stmts) |]
      | _ -> assert false)

  (* include("other.jl") -- read a sibling source file and run it, right here,
     in the global scope, exactly as if its text had been pasted in. Real
     Julia's `include`, with real Julia's path rule: the argument resolves
     against the DIRECTORY OF THE INCLUDING FILE (not the process's cwd), so
     `include("keel.jl")` from examples/keel_bounce.jl finds examples/keel.jl
     however the process was started. While the included file runs it becomes
     the "including file" itself, so its own includes resolve against ITS
     directory (includes nest).

     Reading the file goes through `host_read_file`, the same synchronous
     `host_*` FFI convention every other bridge here uses -- Node backs it with
     fs.readFileSync (preload.js), the browser with a synchronous XHR
     (web/demo.html). That's the only part that can't be shared: OCaml's own
     open_in has no filesystem to reach for in a browser. *)
  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "include" [ [ "String" ] ] (function
      | [ VStr path ] ->
        let resolved = if !current_file_dir = "" then path else Filename.concat !current_file_dir path in
        let src =
          try Js.to_string (Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global "host_read_file") [| Js.Unsafe.inject (Js.string resolved) |])
          with _ -> failwith (Printf.sprintf "include: could not read %s" resolved)
        in
        let prog = Parser.parse_program src in
        Resolve.resolve_program prog;
        let saved = !current_file_dir in
        (* the reported source position follows the included file while it
           runs, and the including file's own line comes back afterwards --
           otherwise an error inside an included file would name the outer
           file and a line number belonging to neither *)
        let entered = here () in
        current_file_dir := Filename.dirname resolved;
        current_file := resolved;
        (* restored on the way out through a RETURN only, the same rule a
           returning call frame follows: an error propagating out of an
           included file leaves the position inside that file, which is where
           it belongs *)
        ignore (exec_stmt_list global prog);
        current_file_dir := saved;
        restore_site entered;
        VNothing
      | _ -> assert false)

  (* the return value of a whole program's last expression statement, if any *)
  let run (src : string) : unit =
    let prog = Parser.parse_program src in
    Resolve.resolve_program prog;
    Async.run_effectful (fun () -> ignore (exec_stmt_list global prog))

  (* `run`, but handing back the value of the last statement so the REPL can
     show it. Runs against the SAME `global` scope every time, which is what
     makes a REPL a REPL: a function declared at one prompt is still there at
     the next. Resolve's own global scope persists across calls for the same
     reason, so a variable introduced earlier resolves at its real depth
     instead of falling back to a runtime search. *)
  let eval_toplevel (src : string) : value =
    let prog = Parser.parse_program src in
    Resolve.resolve_program prog;
    let result = ref VNothing in
    Async.run_effectful (fun () -> result := exec_stmt_list global prog);
    !result
