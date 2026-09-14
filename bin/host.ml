(* ============================= Host ============================= *)
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
   as run_bytecode/Compile.encode just above.

   Runtime から出してあるのは、この道が要るのは ecs を使う人だけだから
   -- drop の logic は system を持たないので、走らせる側にこれが要らない。
   Runtime に居たころは、誰も呼ばなくても一緒に配られていた。 *)
open Runtime

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
