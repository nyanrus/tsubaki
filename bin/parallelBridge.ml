(* ===================== the worker pool: systems on more than one core =======
   `parallel_each(:movement!, [Position, Velocity])` runs an ordinary system on
   every core instead of one.

   Why it has to be built out here, on JS, rather than in OCaml: this project
   ships to wasm, and wasm_of_ocaml has no threads -- `Domain.spawn` compiles
   and runs, but sequentially (measured: four domains take four times as long as
   one, not the same time). So the cores come from the host: Node's
   worker_threads (browser Web Workers next), each running its OWN Tsubaki
   instance of the same script.

   What crosses between them is NOT data. Every SoA column is a Bigarray, which
   under wasm_of_ocaml is a JS typed array (see Runtime.Host.fcol), and the host
   allocates it on a SharedArrayBuffer -- so main and every worker read and write
   the same bytes. Copying them instead was measured first, and it is exactly
   what kills this: handing 100k entities' Position across the JS boundary
   element by element costs ~6.7ms, where the whole frame's compute is ~43ms
   across four cores. The columns don't move; the workers come to them.

   The shape a parallel system must have:

       function movement!()                     # zero-argument, like any system
           for id in query([Position, Velocity])
               p = get_component(id, Position)
               v = get_component(id, Velocity)
               add_component!(id, p + v)
           end
       end
       parallel_each(:movement!, [Position, Velocity])

   It stays a zero-argument function on purpose: that is the only shape the Host
   VM compiles (Eval's SFuncDecl gate), and the compiled SoA path is the whole
   reason there is anything worth parallelizing. So a worker's share does not
   arrive as an argument -- inside a worker, `query` answers with the slice that
   worker was handed (Ecs.current_job). The same function therefore runs over the
   whole world when you call it directly, and over one slice under
   parallel_each, with no second spelling of the body.

   Two rules a parallel system lives by, both enforced rather than assumed:
   - it may only WRITE components an entity already has. Growing a column
     allocates a new buffer, which in a worker would be the worker's own and
     shared with nobody, so Runtime.Host.grow_guard makes it an error there.
     Spawning and despawning belong on the main thread.
   - it must query exactly the components parallel_each names (Ecs.query_raw
     says so if it doesn't) -- otherwise it would be looping over a slice
     computed for a different set of entities.

   `init` below exists ONLY to force this module to be linked, same reason
   CurveBridge.init/PhysicsBridge.init do. *)
open Runtime
open Js_of_ocaml

let host name args = Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global name) args
let host_exists name = Js.to_string (Js.typeof (Js.Unsafe.get Js.Unsafe.global name : Js.Unsafe.any)) = "function"

let is_worker () = host_exists "host_is_worker" && Js.to_bool (Js.Unsafe.coerce (host "host_is_worker" [||]))

(* what main last told the workers about where the columns are. Bumped by every
   reallocation (Runtime.Host.storage_gen), so a grow on the main thread is just
   the next frame's rebind, never a worker writing into a dead buffer. *)
let bound_gen = ref (-1)
let pool_started = ref false

let kind_of = function
  | VStr s -> s
  | VType s -> s (* parallel_each(:move!, [Position, Velocity]) -- type keys, same as query's *)
  | v -> failwith (Printf.sprintf "parallel_each: expected component types, got %s" (tag v))

(* hand every SoA column over as the typed array it already is. Structured-clone
   of a SharedArrayBuffer-backed typed array shares the buffer -- it does not
   copy it -- which is the entire trick. *)
let bind_columns () =
  let payload =
    List.map
      (fun (kind, leaf_names, cols, present) ->
        Js.Unsafe.obj
          [| "kind", Js.Unsafe.inject (Js.string kind)
           ; "leaves", Js.Unsafe.inject (Js.array (Array.map (fun n -> Js.string n) leaf_names))
           ; "cols", Js.Unsafe.inject (Js.array (Array.map (fun c -> Host.ta_of_ba !c) cols))
           ; "present", Host.ta_of_ba !present
          |])
      (Ecs.all_soa_columns ())
  in
  ignore
    (host "host_pool_bind"
       [| Js.Unsafe.inject (Js.array (Array.of_list payload)); Host.ta_of_ba !(Ecs.alive_col ()) |]);
  bound_gen := !Host.storage_gen

let parallel_each fname kinds =
  (* a worker runs the whole script too -- that is how it learns the systems --
     so it reaches this call as well. Scheduling is main's job; here it is simply
     nothing, and the worker goes on to serve() instead. *)
  if is_worker () then ()
  else if not (host_exists "host_pool_run") then
    failwith "parallel_each: this host has no worker pool (Node's preload.js provides one; a browser page needs COOP/COEP for SharedArrayBuffer)";
  if not !pool_started then (
    ignore (host "host_pool_start" [||]);
    pool_started := true);
  (* main hands out ranges of entity ids, not a list of entities: the query
     itself then happens inside each worker, over its own range, instead of once
     up front on this thread. That scan is O(entities) and would otherwise be the
     serial part that caps the whole speedup (measured: with the id list built
     here, four workers bought only 1.9x). *)
  let n = Ecs.entity_count () in
  if n > 0 then (
    if !bound_gen <> !Host.storage_gen then bind_columns ();
    let errs : Js.js_string Js.t Js.js_array Js.t =
      Js.Unsafe.coerce
        (host "host_pool_run"
           [| Js.Unsafe.inject (Js.string fname)
            ; Js.Unsafe.inject n
            ; Js.Unsafe.inject (Js.array (Array.of_list (List.map (fun k -> Js.string k) kinds)))
           |])
    in
    match Array.to_list (Array.map Js.to_string (Js.to_array errs)) with
    | [] -> ()
    | msg :: _ -> failwith msg)

(* --- the worker side -------------------------------------------------------
   Runs after the script has been evaluated (so every struct and function this
   instance needs is already declared, and its systems are already compiled),
   and never returns: park, take a job, run it, say done. All of it synchronous
   -- the waiting happens in Atomics.wait on the JS side, so nothing here needs
   to know about promises or the event loop. *)
let serve () =
  Host.in_worker := true;
  let cache = Dispatch.new_cache () in
  let rec loop () =
    let job = host "host_worker_wait" [||] in
    if Js.to_bool (Js.Unsafe.get job "stop") then ()
    else (
      let gen = Js.Unsafe.get job "gen" in
      if !bound_gen <> gen then (
        let payload = host "host_worker_columns" [||] in
        let tables : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.get payload "tables" in
        Array.iter
          (fun (t : Js.Unsafe.any) ->
            let kind = Js.to_string (Js.Unsafe.get t "kind") in
            let cols : Js.Unsafe.any Js.js_array Js.t = Js.Unsafe.get t "cols" in
            let cols = Array.map Host.ba_of_ta (Js.to_array cols) in
            Ecs.attach_shared kind cols (Host.ba_of_ta (Js.Unsafe.get t "present")))
          (Js.to_array tables);
        Ecs.alive_col () := Host.ba_of_ta (Js.Unsafe.get payload "alive");
        bound_gen := gen);
      let fname = Js.to_string (Js.Unsafe.get job "fn") in
      let lo : int = Js.Unsafe.get job "lo" in
      let hi : int = Js.Unsafe.get job "hi" in
      let kinds =
        Array.to_list (Array.map Js.to_string (Js.to_array (Js.Unsafe.get job "kinds" : Js.js_string Js.t Js.js_array Js.t)))
      in
      Ecs.current_job := Some (kinds, lo, hi);
      (* an error in a worker goes BACK to the main thread rather than to this
         worker's stdout: a worker's output is piped asynchronously and can be
         lost entirely when the process exits (it was, the first time this was
         tried -- one of the two rules below reported itself and the other simply
         vanished). parallel_each re-raises it there, so a broken parallel system
         fails as loudly as a broken serial one. *)
      let err : Js.Unsafe.any =
        try
          ignore (Dispatch.call_cached cache fname []);
          Js.Unsafe.inject Js.null
        with Failure msg -> Js.Unsafe.inject (Js.string msg)
      in
      Ecs.current_job := None;
      ignore (host "host_worker_done" [| err |]);
      loop ())
  in
  loop ()

let () =
  Dispatch.defmethod "parallel_each" [ [ "Symbol" ]; [ "Array" ] ] (function
    | [ VSymbol (fname, _); VArr { cells; _ } ] ->
      parallel_each fname (Array.to_list (Array.map kind_of (arrbuf_to_array cells)));
      VNothing
    | _ -> assert false)

let () = Dispatch.defmethod "is_worker" [] (fun _ -> VBool (is_worker ()))

let init () = ()
