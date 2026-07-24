(* ===================== browser+node bridge: 2D physics ======================
   Registers physics_world_new/physics_add_circle/physics_add_box/physics_step/
   physics_get_bodies/physics_set_velocity so a Tsubaki script can drive
   physics/'s circle+AABB rigid-body world. Unlike gpuBridge.ml (browser-only,
   WebGPU) this works in BOTH Node (preload.js) and the browser
   (web/demo.html) -- physics/ has no web-sys/DOM dependency, same posture as
   kernel/'s host_matvec etc, just fetched instead of read from disk on the
   browser side. Same synchronous `host_physics_*` FFI convention as every
   other bridge in this project.

   World/body handles cross the boundary as plain Tsubaki Ints (the u32 index
   physics/src/lib.rs itself uses) -- no new Runtime.value variant needed.
   `physics_get_bodies` needs to know how many body slots a world holds to size
   its output buffer; it asks physics_body_count for that. (This file used to
   count adds itself, but physics_remove's free list means an add can reuse a
   slot instead of growing the world, so the add count is no longer the slot
   count -- the Rust side is now the single source of truth.)

   `init` below exists ONLY to force this module to be linked, same reason
   CurveBridge.init/GpuBridge.init do (see either's own comment). *)
open Runtime

let as_float = function
  | VFloat v -> v
  | VInt v -> float_of_int v
  | _ -> failwith "physics bridge: expected a number"

let as_int = function
  | VInt v -> v
  | VFloat v -> int_of_float v
  | _ -> failwith "physics bridge: expected a number"

let host name args = Runtime.host_call ~area:"physics" name args

let inject_float f = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.float f)
let inject_int (i : int) = Js_of_ocaml.Js.Unsafe.inject i

let () =
  Dispatch.defmethod "physics_world_new" [ [ "Number" ]; [ "Number" ] ] (function
    | [ gx; gy ] ->
      let handle = int_of_float (Js_of_ocaml.Js.to_float (host "host_physics_world_new" [| inject_float (as_float gx); inject_float (as_float gy) |])) in
      VInt handle
    | _ -> assert false)

let () =
  Dispatch.defmethod "physics_add_circle"
    [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ]
    (function
      | [ world; x; y; vx; vy; radius; mass; restitution ] ->
        let w = as_int world in
        let body =
          int_of_float
            (Js_of_ocaml.Js.to_float
               (host "host_physics_add_circle"
                  [| inject_int w
                   ; inject_float (as_float x)
                   ; inject_float (as_float y)
                   ; inject_float (as_float vx)
                   ; inject_float (as_float vy)
                   ; inject_float (as_float radius)
                   ; inject_float (as_float mass)
                   ; inject_float (as_float restitution)
                  |]))
        in
        VInt body
      | _ -> assert false)

let () =
  Dispatch.defmethod "physics_add_box"
    [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ]
    (function
      | [ world; x; y; vx; vy; hw; hh; mass; restitution ] ->
        let w = as_int world in
        let body =
          int_of_float
            (Js_of_ocaml.Js.to_float
               (host "host_physics_add_box"
                  [| inject_int w
                   ; inject_float (as_float x)
                   ; inject_float (as_float y)
                   ; inject_float (as_float vx)
                   ; inject_float (as_float vy)
                   ; inject_float (as_float hw)
                   ; inject_float (as_float hh)
                   ; inject_float (as_float mass)
                   ; inject_float (as_float restitution)
                  |]))
        in
        VInt body
      | _ -> assert false)

let () =
  Dispatch.defmethod "physics_step" [ [ "Number" ]; [ "Number" ] ] (function
    | [ world; dt ] ->
      let collisions = int_of_float (Js_of_ocaml.Js.to_float (host "host_physics_step" [| inject_int (as_int world); inject_float (as_float dt) |])) in
      VInt collisions
    | _ -> assert false)

let () =
  Dispatch.defmethod "physics_set_velocity" [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ] (function
    | [ world; body; vx; vy ] ->
      ignore (host "host_physics_set_velocity" [| inject_int (as_int world); inject_int (as_int body); inject_float (as_float vx); inject_float (as_float vy) |]);
      VNothing
    | _ -> assert false)

(* physics_remove tombstones a body and frees its slot for reuse (see
   physics/src/lib.rs). The slot stays in place, so physics_get_bodies still
   reports it -- every surviving body's handle keeps lining up with its row. *)
let () =
  Dispatch.defmethod "physics_remove" [ [ "Number" ]; [ "Number" ] ] (function
    | [ world; body ] ->
      ignore (host "host_physics_remove" [| inject_int (as_int world); inject_int (as_int body) |]);
      VNothing
    | _ -> assert false)

(* returns a flat Vector [x0,y0,vx0,vy0, x1,y1,vx1,vy1, ...], one group of 4
   per body slot, in index order. The slot count comes from physics_body_count
   (the Rust side owns it now -- see this file's header). *)
let () =
  let open Js_of_ocaml in
  Dispatch.defmethod "physics_get_bodies" [ [ "Number" ] ] (function
    | [ world ] ->
      let w = as_int world in
      let n = int_of_float (Js.to_float (host "host_physics_body_count" [| inject_int w |])) in
      let result = host "host_physics_get_bodies" [| inject_int w; inject_int n |] in
      let arr = Array.init (n * 4) (fun i -> Js.to_float (Typed_array.unsafe_get result i)) in
      VVec (vecbuf_of_array arr)
    | _ -> assert false)

(* see the comment at the top of this file -- called from main.ml purely
   to force this module to be linked *)
let init () = ()
