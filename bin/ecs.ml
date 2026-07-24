(* ===================== ECS: entity/component storage ======================
   Two component-storage layouts, chosen automatically per struct kind
   (Bevy-scale archetype/columnar layout across ALL kinds is still out of
   scope -- this is just per-kind, not per-entity-shape):

   - AoS (array of structs): entity id -> a boxed VStruct option, for any
     kind (the general case -- arbitrary field types, arbitrary shape).
   - SoA (struct of arrays): one flat `float array` PER FIELD, all indexed
     directly by entity id, plus one shared presence bitmap -- only for a
     kind whose every field is declared `::Float` AND whose struct is a
     plain (non-mutable) `struct` (see Runtime.soa_eligible, the single
     shared rule both this file's table_for and Compile.try_compile_host's
     compile-time aliasing agree on). No VStruct is ever boxed for
     reads/writes THROUGH the SoA-aware raw functions below when a compiled
     call site can prove it's dealing with one (see
     Runtime.Host.HEcsSoaFieldRead/HEcsSoaWrite) -- ordinary (uncompiled)
     get_component/add_component! still box/unbox transparently. The
     non-mutable requirement is what makes "nothing about the Julia-visible
     behavior of either layout differs, only speed" actually true: SoA's
     get_component always hands back a fresh copy built from the columns,
     so a field assigned on it never writes through to storage -- fine for
     an immutable struct (Runtime.set_field already refuses to assign into
     one at all, so the question never comes up), but silently wrong for a
     `mutable struct`, which promises the opposite. A `mutable struct` with
     every field `::Float` therefore stays on the AoS path instead, where
     get_component really does hand back the same boxed VStruct sitting in
     the table.

   Either way, this is pure OCaml, no host_*/JS bridge at all: runs
   identically in Node and the browser. A component is just an ordinary
   Tsubaki struct instance (Runtime.value's VStruct { kind; fields }, see
   runtime.ml) -- no separate component-registration step.

   Entity ids are handed out sequentially from 0 (never reused, see
   create_entity below) and never removed from a column's own array once
   grown, only cleared back to "absent" -- so every array here only ever
   grows (`ensure_len`), sized to the largest entity id it's ever seen.

   `init` below exists ONLY to force this module to be linked, same reason
   CurveBridge.init/GpuBridge.init do (see either's own comment). *)
open Runtime

let next_id = ref 0

(* grows `arr` (in place, via the ref cell) until index `n` is valid,
   doubling each time -- shared by `alive` and every column below, all of
   which are "grow on write, never shrink" for the same reason. *)
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

(* shared with the workers, like the columns and the presence bitmaps -- a
   worker mints no entities of its own, so if this stayed its own private array
   every entity would look dead to it and every query would come back empty
   (which is exactly what happened, the first time this was run). *)
let alive : Host.bcol ref = ref (Host.bcol_create 64)
let is_alive e = e < Bigarray.Array1.dim !alive && Host.bcol_get !alive e

type soa_column =
  { field_names : string array (* declaration order, matches Runtime.struct_def.field_names *)
  ; cols : Host.fcol ref array (* one column per field, SAME order as field_names -- see Runtime.Host.fcol for why a Bigarray *)
  ; present : Host.bcol ref (* shared by every field in this column -- see Runtime.Host.bcol *)
  }

type column =
  | AoS of value option array ref
  | SoA of soa_column

let tables : (string, column) Hashtbl.t = Hashtbl.create 16

let field_index_opt (names : string array) (field : string) : int option =
  let n = Array.length names in
  let rec go i = if i >= n then None else if names.(i) = field then Some i else go (i + 1) in
  go 0

(* one column per LEAF float, named by its path -- for a flat all-::Float
   struct that is exactly its own field names (unchanged), for a nested one
   ("pos.x", "pos.y", ...) it's the flattening. See Runtime.soa_leaf_paths. *)
let make_soa_column kind =
  incr Host.storage_gen;
  let field_names = Array.of_list (soa_leaf_paths kind) in
  SoA { field_names; cols = Array.map (fun _ -> ref (Host.fcol_create 64)) field_names; present = ref (Host.bcol_create 64) }

let table_for kind =
  match Hashtbl.find_opt tables kind with
  | Some t -> t
  | None ->
    let t = if soa_eligible kind then make_soa_column kind else AoS (ref (Array.make 64 None)) in
    Hashtbl.add tables kind t;
    t

let column_get t e = if e < Array.length !t then !t.(e) else None

(* --- raw, Dispatch-free implementations: what Dispatch.defmethod below
   actually calls, and also what Runtime.Host's compiled ECS opcodes call
   directly (see the ecs_hooks registration at the bottom of this file) --
   bypassing Dispatch.call_cached's name/argument-type resolution entirely
   for a compiled call site that already knows, at compile time, exactly
   which of these it means. *)
let create_entity_raw () =
  (* not left to the grow guard (Runtime.Host.grow_guard): a worker's own
     next_id is 0, so if there happened to be spare capacity this would hand back
     an id main is already using and quietly overwrite that entity. Spawning is
     the main thread's, and says so. *)
  if !Host.in_worker then
    failwith "parallel system: cannot create entities inside a worker -- spawning belongs on the main thread";
  let e = !next_id in
  incr next_id;
  Host.ensure_bcol alive e;
  Host.bcol_set !alive e true;
  e

let destroy_entity_raw e =
  if !Host.in_worker then
    failwith "parallel system: cannot destroy entities inside a worker -- despawning belongs on the main thread";
  if e < Bigarray.Array1.dim !alive then Host.bcol_set !alive e false;
  Hashtbl.iter
    (fun _ t ->
      match t with
      | AoS t -> if e < Array.length !t then !t.(e) <- None
      | SoA col -> if e < Bigarray.Array1.dim !(col.present) then Host.bcol_set !(col.present) e false)
    tables

(* walk a struct value down to its leaf floats and write them into the columns,
   in the SAME depth-first declaration order soa_leaf_paths laid them out. For
   a flat struct this is just "one field, one column"; for a nested one it
   descends through the inner struct instead of trying to store it as a float. *)
let soa_put col e (c : value) kind =
  let rec put v k next =
    match v, Hashtbl.find_opt struct_defs k with
    | VStruct { fields; _ }, Some sd ->
      let rec go ftypes idx i =
        match ftypes with
        | [] -> i
        | ft :: rest ->
          let _, r = fields.(idx) in
          let i' =
            match ft with
            | [ "Float" ] ->
              Bigarray.Array1.set !(col.cols.(i)) e (as_float !r);
              i + 1
            | [ k' ] -> put !r k' i
            | _ -> failwith "SoA column: unexpected field type"
          in
          go rest (idx + 1) i'
      in
      go sd.field_types 0 next
    | other, _ -> failwith (Printf.sprintf "add_component!: expected a struct instance, got %s" (tag other))
  in
  ignore (put c kind 0)

let add_component_raw e c =
  match c with
  | VStruct { kind; _ } -> (
    match table_for kind with
    | AoS t ->
      ensure_len t None e;
      !t.(e) <- Some c
    | SoA col ->
      Array.iteri (fun i _ -> Host.ensure_fcol col.cols.(i) e) col.cols;
      soa_put col e c kind;
      Host.ensure_bcol col.present e;
      Host.bcol_set !(col.present) e true)
  | other -> failwith (Printf.sprintf "add_component!: expected a struct instance, got %s" (tag other))

let has_component_raw e kind =
  match Hashtbl.find_opt tables kind with
  | Some (AoS t) -> column_get t e <> None
  | Some (SoA col) -> e < Bigarray.Array1.dim !(col.present) && Host.bcol_get !(col.present) e
  | None -> false

(* the exact inverse of soa_put: rebuild the struct (nested inner structs and
   all) from the leaf columns, consuming them in the same depth-first order.
   The index is threaded explicitly rather than kept in a ref, because OCaml
   doesn't promise the evaluation order of a List.map2 over the fields. *)
let soa_take col e kind =
  let rec build k next =
    match Hashtbl.find_opt struct_defs k with
    | None -> failwith "SoA column: unknown struct"
    | Some sd ->
      let rec go ftypes i acc =
        match ftypes with
        | [] -> (List.rev acc, i)
        | [ "Float" ] :: rest -> go rest (i + 1) (VFloat (Bigarray.Array1.get !(col.cols.(i)) e) :: acc)
        | [ k' ] :: rest ->
          let v, i' = build k' i in
          go rest i' (v :: acc)
        | _ -> failwith "SoA column: unexpected field type"
      in
      let args, i' = go sd.field_types next [] in
      (construct k args, i')
  in
  fst (build kind 0)

let get_component_raw e kind =
  match Hashtbl.find_opt tables kind with
  | Some (AoS t) -> ( match column_get t e with Some c -> c | None -> VNothing)
  | Some (SoA col) ->
    if e < Bigarray.Array1.dim !(col.present) && Host.bcol_get !(col.present) e then soa_take col e kind else VNothing
  | None -> VNothing

let remove_component_raw e kind =
  match Hashtbl.find_opt tables kind with
  | Some (AoS t) -> if e < Array.length !t then !t.(e) <- None
  | Some (SoA col) -> if e < Bigarray.Array1.dim !(col.present) then Host.bcol_set !(col.present) e false
  | None -> ()

(* --- the slice a worker is currently working on (parallelBridge.ml sets it) --
   A parallel system is an ORDINARY system: a zero-argument function whose body
   loops over `query([...])`. That shape is what the Host VM compiles (see
   Compile.try_compile_host) and what makes it fast, so a parallel system must
   keep it -- which means the way a worker gets "its share" of the entities
   cannot be an extra argument. Instead, inside a worker running a job, `query`
   answers with the ids that job handed THIS worker, so the very same function
   runs over the whole world when you call it directly and over one slice when
   parallel_each runs it. (This is what an ECS scheduler's per-system query view
   is; nothing about the body changes.)

   The kinds are checked, not ignored: a system that queries something OTHER
   than what parallel_each declared would be reading a slice computed for a
   different set of components, so it says so and stops. *)
let current_job : (string list * int * int) option ref = ref None

(* how many entity ids have ever been minted -- what parallel_each splits into
   ranges, one per worker *)
let entity_count () = !next_id

(* entity ids alive and present in every named table (set intersection).
   The Tsubaki script calls get_component itself per kind it actually needs --
   keeps this builtin's own surface small instead of a fixed-arity variadic
   query. *)
(* entity ids alive and present in every named kind, scanning only the id range
   [lo, hi). Serially that range is the whole world; under parallel_each each
   worker gets a slice of it, so the SCAN is split across cores too -- not just
   the system body. (Handing the workers a ready-made id list instead would have
   left this scan on the main thread, serial: measured, it was most of what a
   4-worker run failed to speed up.) *)
let query_range kinds lo hi : int array =
  match kinds with
  | [] -> [||]
  | first :: rest ->
    let acc = ref [] in
    let keep e = is_alive e && List.for_all (fun k -> has_component_raw e k) rest in
    (match Hashtbl.find_opt tables first with
    | Some (AoS t) ->
      let hi = min hi (Array.length !t) in
      for e = hi - 1 downto lo do
        if !t.(e) <> None && keep e then acc := e :: !acc
      done
    | Some (SoA col) ->
      let p = !(col.present) in
      let hi = min hi (Bigarray.Array1.dim p) in
      for e = hi - 1 downto lo do
        if Host.bcol_get p e && keep e then acc := e :: !acc
      done
    | None -> ());
    Array.of_list !acc

let query_raw kinds : int array =
  match !current_job with
  | Some (job_kinds, lo, hi) ->
    if kinds <> job_kinds then
      failwith
        (Printf.sprintf
           "parallel system: this system queries [%s], but parallel_each was given [%s] -- they must name the same components"
           (String.concat ", " kinds) (String.concat ", " job_kinds));
    query_range kinds lo hi
  | None -> query_range kinds 0 max_int

(* kind -> (field names in decl order, one ref per field's column, the
   shared presence ref), or None if `kind` isn't SoA-eligible -- see
   Runtime.Host.ecs_hooks's own comment for why these are the actual
   mutable ref cells, not a snapshot. *)
let soa_column_info kind : (string array * Host.fcol ref array * Host.bcol ref) option =
  match table_for kind with
  | SoA col -> Some (col.field_names, col.cols, col.present)
  | AoS _ -> None

(* bulk-exports a SoA-eligible kind's own columns directly into a flat
   `Vector` -- one OCaml pass over the shared presence bitmap, no
   query/get_component/push! round trip through the Tsubaki interpreter at
   all. Built specifically so `write_buffer(buf, soa_flatten("Position",
   ["x", "y"]))` (bin/gpuBridge.ml, Stage 1) can hand an ECS component's
   entire live column set to gpu/ in one call -- SoA storage (see the file
   header comment above) is ALREADY a flat `float array` per field, so
   there was never a real need to box it back into per-entity VStructs and
   re-flatten it in userland just to reach a GPU buffer. Only meaningful
   for a SoA-eligible kind (see Runtime.soa_eligible) -- an AoS kind's
   storage isn't a flat column at all, so there's nothing to bulk-read
   here; a script needing that shape still goes through the ordinary
   query/get_component path. *)
let soa_flatten_raw kind (fields : string array) : value =
  if not (soa_eligible kind) then
    failwith (Printf.sprintf "soa_flatten: %s is not SoA-eligible (needs a plain, non-mutable, all-::Float struct)" kind);
  match Hashtbl.find_opt tables kind with
  | None -> VVec (vecbuf_of_array [||]) (* never populated -- same "empty, not an error" convention query_raw's own missing-table case uses *)
  | Some (AoS _) -> assert false (* soa_eligible kind always gets a SoA table, see table_for/make_soa_column *)
  | Some (SoA col) ->
    let field_cols =
      Array.map
        (fun f ->
          match field_index_opt col.field_names f with
          | Some i -> col.cols.(i)
          | None -> failwith (Printf.sprintf "soa_flatten: %s has no field %s" kind f))
        fields
    in
    let present = !(col.present) in
    let cap = Bigarray.Array1.dim present in
    let n_alive = ref 0 in
    for e = 0 to cap - 1 do
      if Host.bcol_get present e then incr n_alive
    done;
    let out = Array.make (!n_alive * Array.length fields) 0.0 in
    let w = ref 0 in
    for e = 0 to cap - 1 do
      if Host.bcol_get present e then
        Array.iter
          (fun col_ref ->
            out.(!w) <- Bigarray.Array1.get !col_ref e;
            incr w)
          field_cols
    done;
    VVec (vecbuf_of_array out)

let () =
  Dispatch.defmethod "soa_flatten" [ [ "String" ]; [ "Array" ] ] (function
    | [ VStr kind; VArr { cells; _ } ] ->
      let fields =
        Array.map
          (function VStr s -> s | v -> failwith (Printf.sprintf "soa_flatten: expected an Array of Strings, got %s" (tag v)))
          (arrbuf_to_array cells)
      in
      soa_flatten_raw kind fields
    | _ -> assert false)

let () = Dispatch.defmethod "create_entity" [] (fun _ -> VInt (create_entity_raw ()))

let () =
  Dispatch.defmethod "destroy_entity!" [ [ "Int" ] ] (function
    | [ VInt e ] ->
      destroy_entity_raw e;
      VNothing
    | _ -> assert false)

let () =
  Dispatch.defmethod "add_component!" [ [ "Int" ]; [ "Any" ] ] (function
    | [ VInt e; c ] ->
      add_component_raw e c;
      VNothing
    | _ -> assert false)

let () =
  Dispatch.defmethod "has_component" [ [ "Int" ]; [ "String" ] ] (function
    | [ VInt e; VStr kind ] -> VBool (has_component_raw e kind)
    | _ -> assert false)

let () =
  Dispatch.defmethod "get_component" [ [ "Int" ]; [ "String" ] ] (function
    | [ VInt e; VStr kind ] -> get_component_raw e kind
    | _ -> assert false)

let () =
  Dispatch.defmethod "remove_component!" [ [ "Int" ]; [ "String" ] ] (function
    | [ VInt e; VStr kind ] ->
      remove_component_raw e kind;
      VNothing
    | _ -> assert false)

(* --- naming a component kind by its TYPE (`get_component(e, Position)`)
   rather than by a string (`get_component(e, "Position")`). The storage,
   the columns and the raw functions above are all unchanged: a type key is
   only a different SPELLING of the same kind name, resolved one step
   earlier. What it buys is that a misspelled `Positon` is now an
   UndefVarError at the call instead of a silently-empty `VNothing` -- a
   bare name that isn't a bound variable only becomes a VType at all when it
   names a declared type (see Eval's EVar case), so a typo never reaches
   here. Compiled call sites get the same spelling for free: see
   Compile.try_compile_host's `kind_key`, which resolves the identifier at
   compile time and then emits the very same SoA opcodes the string form
   already did -- type keys cost nothing and specialize identically. *)
let () =
  Dispatch.defmethod "get_component" [ [ "Int" ]; [ "Type" ] ] (function
    | [ VInt e; VType kind ] -> get_component_raw e kind
    | _ -> assert false)

let () =
  Dispatch.defmethod "has_component" [ [ "Int" ]; [ "Type" ] ] (function
    | [ VInt e; VType kind ] -> VBool (has_component_raw e kind)
    | _ -> assert false)

let () =
  Dispatch.defmethod "remove_component!" [ [ "Int" ]; [ "Type" ] ] (function
    | [ VInt e; VType kind ] ->
      remove_component_raw e kind;
      VNothing
    | _ -> assert false)

let () =
  Dispatch.defmethod "query" [ [ "Array" ] ] (function
    | [ VArr { cells; _ } ] ->
      let kinds =
        Array.to_list
          (Array.map
             (function
               | VStr s -> s
               | VType s -> s (* query([Position, Velocity]) -- see the type-key comment above *)
               | v -> failwith (Printf.sprintf "query: expected an Array of component types (or Strings), got %s" (tag v)))
             (arrbuf_to_array cells))
      in
      mk_arr (Array.map (fun e -> VInt e) (query_raw kinds))
    | _ -> assert false)

(* --- what a worker needs to see the same world -----------------------------
   Main hands these over (parallelBridge.ml turns each column into the JS typed
   array it already is); a worker points its OWN tables at them. Nothing is
   copied in either direction. *)
let alive_col () : Host.bcol ref = alive

let all_soa_columns () : (string * string array * Host.fcol ref array * Host.bcol ref) list =
  Hashtbl.fold
    (fun kind t acc ->
      match t with
      | SoA col -> (kind, col.field_names, col.cols, col.present) :: acc
      | AoS _ -> acc)
    tables []

(* The ref CELLS are the very ones Compile baked into this instance's already-
   compiled opcodes (see Runtime.Host's ecs_hooks comment), so replacing their
   CONTENTS -- never the cells -- is exactly what makes an already-compiled
   system read and write main's memory instead of its own. *)
let attach_shared kind (cols : Host.fcol array) (present : Host.bcol) : unit =
  match table_for kind with
  | SoA col ->
    if Array.length cols <> Array.length col.cols then
      failwith
        (Printf.sprintf "parallel: %s has %d columns here but %d were sent -- the worker is running a different script"
           kind (Array.length col.cols) (Array.length cols));
    Array.iteri (fun i c -> col.cols.(i) := c) cols;
    col.present := present
  | AoS _ -> failwith (Printf.sprintf "parallel: %s is not an SoA component kind, so it cannot be shared with a worker" kind)

(* lets Runtime.Host's compiled ECS opcodes (see Compile.try_compile_host,
   which specializes get_component/add_component!/query/... call sites
   directly to these) call straight into the raw functions above instead of
   through Dispatch.call_cached -- Ecs can't be depended on from Runtime
   directly (Ecs depends on Runtime, not the other way around), so Runtime
   holds an indirection cell that this module fills in once, at load time,
   the same side-channel-ref pattern current_kwargs/current_end/
   current_module_prefix already use elsewhere in runtime.ml. *)
let () =
  Host.register_ecs_hooks
    { Host.get_component = get_component_raw
    ; add_component = add_component_raw
    ; query = query_raw
    ; create_entity = create_entity_raw
    ; destroy_entity = destroy_entity_raw
    ; has_component = has_component_raw
    ; remove_component = remove_component_raw
    ; soa_column_info
    }

(* see the comment at the top of this file -- called from main.ml purely
   to force this module to be linked *)
let init () = ()
