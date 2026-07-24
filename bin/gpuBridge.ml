(* ===================== browser bridge: game-engine primitives ======================
   Registers a handful of builtins (clear_screen/draw_rect/draw_rects/key_down/
   mouse_x/mouse_y/on_frame) so a Tsubaki script can drive gpu/'s existing WebGPU
   render pipeline and read keyboard/mouse state, plus exposes `tsubakiRunFrame`
   to JS so a browser page's own `requestAnimationFrame` loop can re-enter
   this same live interpreter every frame.

   Every draw/input builtin below calls a `host_gpu_*`/`host_*` JS global,
   same synchronous FFI convention `host_matvec`/`host_det` already use
   (`Js.Unsafe.get Js.Unsafe.global "name"` + `Js.Unsafe.fun_call`) --
   deliberately kept synchronous: all the ASYNC WebGPU setup (`gpu_init`,
   `create_render_pipeline`, `configure_canvas`) happens once in the host
   page's own bootstrap script, before this interpreter ever runs a Tsubaki
   program, so nothing here needs `Js_of_ocaml_lwt` (no precedent for that
   anywhere in this codebase).

   `init` below exists ONLY to force this module to be linked, same reason
   `CurveBridge.init` does (see that file's own comment) -- a module nothing
   else references by name has its top-level `let () = ...` bindings
   (everything that actually matters below) silently dropped from the
   compiled wasm/js output otherwise. *)
  open Runtime

  let as_float = function
    | VFloat v -> v
    | VInt v -> float_of_int v
    | _ -> failwith "gpu bridge: expected a number"

  let host0 name = Runtime.host_call ~area:"gpu" name [||]
  let host name args = Runtime.host_call ~area:"gpu" name args

  (* every existing float-crossing-into-JS site in runtime.ml goes through
     `Js.float` first (e.g. `Typed_array.set flat i (Js.float x)`) -- a raw
     OCaml float injected directly is NOT a usable JS number on this
     WasmGC target (confirmed the hard way: it threw "Cannot convert object
     to primitive value" the first time this file skipped the wrap). *)
  let inject_float f = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.float f)

  let () =
    Dispatch.defmethod "clear_screen" [ [ "Number" ]; [ "Number" ]; [ "Number" ] ] (function
      | [ r; g; b ] ->
        ignore (host "host_gpu_clear" [| inject_float (as_float r); inject_float (as_float g); inject_float (as_float b) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "draw_rect"
      [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ]
      (function
        | [ x; y; w; h; r; g; b; a ] ->
          ignore
            (host "host_gpu_draw_rect"
               [| inject_float (as_float x)
                ; inject_float (as_float y)
                ; inject_float (as_float w)
                ; inject_float (as_float h)
                ; inject_float (as_float r)
                ; inject_float (as_float g)
                ; inject_float (as_float b)
                ; inject_float (as_float a)
               |]);
          VNothing
        | _ -> assert false)

  (* draw_rects: draw_rect's many-at-once sibling. Crossing the Tsubaki->JS
     host FFI once per entity is fine at move_rect.jl's scale (one rect) but
     starts to matter once an ECS query is drawing hundreds of entities a
     frame -- so this takes ONE flat numeric Vector of [x,y,w,h,r,g,b,a]
     repeated per rect (same field order/units as draw_rect's own 8 args,
     just concatenated) and crosses the FFI once for the whole batch.
     `[ "Vector" ]`, not `[ "Array" ]`: a bare `rects = []` literal built up
     by all-float `push!`s (the natural way to assemble this -- see
     ecs_bounce_batched.jl) is Runtime's dedicated numeric VVec, distinct
     from the general VArr `query`'s `["Position","Velocity"]` argument
     uses (see ecs_scale_bench.jl's own comment on this same VVec-vs-VArr
     split). `vecbuf_to_array` hands back a plain `float array` directly, no
     per-cell VFloat unboxing needed -- then the same float64Array-of-
     flattened-floats convention every other bulk OCaml->JS crossing in
     this codebase already uses (see runtime.ml's host_matvec/host_matmul
     and friends). *)
  let draw_rects_flat (flat : float array) =
    let open Js_of_ocaml in
    let n = Array.length flat in
    if n mod 8 <> 0 then
      failwith (Printf.sprintf "draw_rects: expected a flat Vector of x,y,w,h,r,g,b,a per rect (length a multiple of 8), got length %d" n);
    let buf = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject n |] in
    Array.iteri (fun i x -> Typed_array.set buf i (Js.float x)) flat;
    ignore (host "host_gpu_draw_rects" [| Js.Unsafe.inject buf |]);
    VNothing

  let () =
    Dispatch.defmethod "draw_rects" [ [ "Vector" ] ] (function
      | [ VVec v ] -> draw_rects_flat (vecbuf_to_array v)
      | _ -> assert false);
    (* the same batch, handed in as a general Array -- which is what a plain
       `rects = []` built up by `push!`es now IS (see Eval's EArrayLit: an
       empty literal is Vector{Any}, not a promise of numbers). Every element
       still has to actually be a number; this converts, it doesn't skip. *)
    Dispatch.defmethod "draw_rects" [ [ "Array" ] ] (function
      | [ VArr { cells; _ } ] ->
        draw_rects_flat
          (Array.map
             (function
               | VInt n -> float_of_int n
               | VFloat f -> f
               | v -> failwith (Printf.sprintf "draw_rects: every element must be a Number, got a %s" (tag v)))
             (arrbuf_to_array cells))
      | _ -> assert false)

  (* draw_text: a minimal BUILT-IN bitmap font (4 cols x 6 rows per glyph),
     each "on" pixel drawn as its own scale x scale rect through the exact
     same host_gpu_draw_rect draw_rect above already calls -- no new host_*
     global, no GPU texture/font atlas (a real font renderer was the
     expensive alternative here, deliberately not taken). Digits, uppercase
     A-Z, space, and a handful of punctuation; anything else (lowercase
     included) draws as blank, same as space. Glyphs are 4 wide with 1
     column of spacing between characters (5*scale advance per char). *)
  let glyph_pixels = function
    | '0' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | '1' -> [ 2, 0; 1, 1; 2, 1; 2, 2; 2, 3; 2, 4; 1, 5; 2, 5; 3, 5 ]
    | '2' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 3, 2; 2, 3; 1, 4; 0, 5; 1, 5; 2, 5; 3, 5 ]
    | '3' -> [ 0, 0; 1, 0; 2, 0; 3, 1; 2, 2; 3, 2; 3, 3; 3, 4; 0, 5; 1, 5; 2, 5 ]
    | '4' -> [ 2, 0; 3, 0; 1, 1; 3, 1; 0, 2; 3, 2; 0, 3; 1, 3; 2, 3; 3, 3; 3, 4; 3, 5 ]
    | '5' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 0, 1; 0, 2; 1, 2; 2, 2; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | '6' -> [ 2, 0; 3, 0; 1, 1; 0, 2; 0, 3; 1, 3; 2, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | '7' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 3, 1; 2, 2; 1, 3; 1, 4; 1, 5 ]
    | '8' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 1, 2; 2, 2; 0, 3; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | '9' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 1, 3; 2, 3; 3, 3; 2, 4; 0, 5; 1, 5 ]
    | 'A' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 1, 3; 2, 3; 3, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'B' -> [ 0, 0; 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 1, 2; 2, 2; 0, 3; 3, 3; 0, 4; 3, 4; 0, 5; 1, 5; 2, 5 ]
    | 'C' -> [ 1, 0; 2, 0; 3, 0; 0, 1; 0, 2; 0, 3; 0, 4; 1, 5; 2, 5; 3, 5 ]
    | 'D' -> [ 0, 0; 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 0, 5; 1, 5; 2, 5 ]
    | 'E' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 0, 1; 0, 2; 1, 2; 2, 2; 0, 3; 0, 4; 0, 5; 1, 5; 2, 5; 3, 5 ]
    | 'F' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 0, 1; 0, 2; 1, 2; 2, 2; 0, 3; 0, 4; 0, 5 ]
    | 'G' -> [ 1, 0; 2, 0; 3, 0; 0, 1; 0, 2; 2, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5; 3, 5 ]
    | 'H' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 0, 2; 1, 2; 2, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'I' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 2, 1; 2, 2; 2, 3; 2, 4; 0, 5; 1, 5; 2, 5; 3, 5 ]
    | 'J' -> [ 2, 0; 3, 0; 3, 1; 3, 2; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | 'K' -> [ 0, 0; 3, 0; 0, 1; 2, 1; 0, 2; 1, 2; 0, 3; 2, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'L' -> [ 0, 0; 0, 1; 0, 2; 0, 3; 0, 4; 0, 5; 1, 5; 2, 5; 3, 5 ]
    | 'M' -> [ 0, 0; 3, 0; 0, 1; 1, 1; 2, 1; 3, 1; 0, 2; 1, 2; 2, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'N' -> [ 0, 0; 3, 0; 0, 1; 1, 1; 3, 1; 0, 2; 1, 2; 2, 2; 3, 2; 0, 3; 2, 3; 3, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'O' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | 'P' -> [ 0, 0; 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 1, 2; 2, 2; 0, 3; 0, 4; 0, 5 ]
    | 'Q' -> [ 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 2, 3; 3, 3; 0, 4; 2, 4; 1, 5; 2, 5 ]
    | 'R' -> [ 0, 0; 1, 0; 2, 0; 0, 1; 3, 1; 0, 2; 1, 2; 2, 2; 0, 3; 2, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'S' -> [ 1, 0; 2, 0; 3, 0; 0, 1; 1, 2; 2, 2; 3, 3; 3, 4; 0, 5; 1, 5; 2, 5 ]
    | 'T' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 2, 1; 2, 2; 2, 3; 2, 4; 2, 5 ]
    | 'U' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 3, 3; 0, 4; 3, 4; 1, 5; 2, 5 ]
    | 'V' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 3, 3; 1, 4; 2, 4; 1, 5; 2, 5 ]
    | 'W' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 0, 2; 3, 2; 0, 3; 1, 3; 2, 3; 3, 3; 0, 4; 1, 4; 2, 4; 3, 4; 0, 5; 3, 5 ]
    | 'X' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 1, 2; 2, 2; 1, 3; 2, 3; 0, 4; 3, 4; 0, 5; 3, 5 ]
    | 'Y' -> [ 0, 0; 3, 0; 0, 1; 3, 1; 1, 2; 2, 2; 2, 3; 2, 4; 2, 5 ]
    | 'Z' -> [ 0, 0; 1, 0; 2, 0; 3, 0; 3, 1; 2, 2; 1, 3; 0, 4; 0, 5; 1, 5; 2, 5; 3, 5 ]
    | '.' -> [ 2, 5 ]
    | ',' -> [ 2, 4; 1, 5 ]
    | ':' -> [ 2, 1; 2, 4 ]
    | '-' -> [ 0, 2; 1, 2; 2, 2; 3, 2 ]
    | '+' -> [ 2, 1; 1, 2; 2, 2; 3, 2; 2, 3 ]
    | '/' -> [ 3, 0; 3, 1; 2, 2; 1, 3; 0, 4; 0, 5 ]
    | '%' -> [ 0, 0; 3, 0; 3, 1; 2, 2; 1, 3; 0, 4; 0, 5; 3, 5 ]
    | _ (* space, lowercase, anything else *) -> []

  let () =
    Dispatch.defmethod "draw_text"
      [ [ "Number" ]; [ "Number" ]; [ "String" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ]
      (function
        | [ x; y; VStr text; scale; r; g; b; a ] ->
          let x = as_float x and y = as_float y and scale = as_float scale in
          let r = as_float r and g = as_float g and b = as_float b and a = as_float a in
          String.iteri
            (fun i ch ->
              let cx = x +. (float_of_int i *. 5.0 *. scale) in
              List.iter
                (fun (col, row) ->
                  ignore
                    (host "host_gpu_draw_rect"
                       [| inject_float (cx +. (float_of_int col *. scale))
                        ; inject_float (y +. (float_of_int row *. scale))
                        ; inject_float scale
                        ; inject_float scale
                        ; inject_float r
                        ; inject_float g
                        ; inject_float b
                        ; inject_float a
                       |]))
                (glyph_pixels ch))
            text;
          VNothing
        | _ -> assert false)

  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "key_down" [ [ "String" ] ] (function
      | [ VStr name ] -> VBool (Js.to_bool (host "host_key_down" [| Js.Unsafe.inject (Js.string name) |]))
      | _ -> assert false)

  (* key_down(:ArrowRight) as a sibling of key_down("ArrowRight") -- a Symbol
     key reads as its bare name (the hygiene id is irrelevant for input), so
     this just forwards the name to the same host_key_down. Lets scripts write
     the lighter :Name form without quoting; the String overload is untouched. *)
  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "key_down" [ [ "Symbol" ] ] (function
      | [ VSymbol (name, _) ] -> VBool (Js.to_bool (host "host_key_down" [| Js.Unsafe.inject (Js.string name) |]))
      | _ -> assert false)

  let () = Dispatch.defmethod "mouse_x" [] (fun _ -> VFloat (Js_of_ocaml.Js.to_float (host0 "host_mouse_x")))
  let () = Dispatch.defmethod "mouse_y" [] (fun _ -> VFloat (Js_of_ocaml.Js.to_float (host0 "host_mouse_y")))

  (* mouse_down(button): key_down's mouse-button sibling -- was missing
     entirely, so a script had no way to tell "hovering" from "dragging"
     (both are just mouse_x/mouse_y, held or not). Click/drag/hover
     themselves are still userland Tsubaki logic (compare this frame's
     position+mouse_down against last frame's, the same edge-detection
     trick key_down-based input already needs) -- this is only the missing
     level-triggered "is it held" primitive underneath that. `button` is a
     host-defined name ("left"/"right"/"middle"), same free-string
     convention key_down already uses for key names. *)
  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "mouse_down" [ [ "String" ] ] (function
      | [ VStr button ] -> VBool (Js.to_bool (host "host_mouse_down" [| Js.Unsafe.inject (Js.string button) |]))
      | _ -> assert false)

  (* ===================== gpu/'s own raw wgpu API, reachable directly =====================
     Everything above this point is the fixed-function 2D rect renderer
     (clear_screen/draw_rect(s)/on_frame), left completely untouched. This
     section instead exposes gpu/src/lib.rs's OWN exported names one-to-one
     (`gpu_init`, `create_buffer`, `create_pipeline`, `dispatch`, ...) -- same
     names as the README's own JS-facing documentation, so there's nothing
     new to learn switching from "the JS host page calls this" to "a Tsubaki
     script calls this directly."

     The real blocker this section closes: `gpu_init`/`create_pipeline`/
     `create_render_pipeline`/`read_buffer`/`gpu_on_device_lost` are
     genuinely async in gpu/'s own Rust source (`pub async fn ...`,
     wasm-bindgen turns that into a JS function returning a Promise) -- and
     Eval.eval is a plain synchronous recursive function with no notion of
     awaiting anything. `Async.AwaitJs` (see async.ml) is what makes
     `perform`-ing on that Promise suspend the WHOLE interpreter call stack,
     not just this one builtin, and resume later when the Promise settles --
     without Eval/ECall/the parser ever learning a new `await` keyword.
     `gpu_init()` reads and behaves exactly like an ordinary synchronous
     Tsubaki call from the script's own point of view.

     The non-async members of gpu/'s API (`create_buffer`, `write_buffer`,
     `dispatch`, ...) still return `Result<T, JsValue>` on the Rust side --
     wasm-bindgen turns an `Err` there into a SYNCHRONOUS JS throw (not a
     rejected Promise), so `host_checked` below catches that too and
     re-raises as an OCaml `Failure`, the exact same exception
     `STry`/`exn_of_failure_message` already turns into a catchable Tsubaki
     exception -- meaning a WGSL compile error surfaces to a script's own
     `try/catch` the same way whether it came from an async `create_pipeline`
     rejection or a sync throw, with no new exception plumbing either way. *)

  let as_int = function
    | VInt v -> v
    | VFloat v -> int_of_float v
    | v -> failwith (Printf.sprintf "gpu bridge: expected a number, got %s" (tag v))

  let as_str = function
    | VStr s -> s
    | v -> failwith (Printf.sprintf "gpu bridge: expected a String, got %s" (tag v))

  let inject_int (i : int) = Js_of_ocaml.Js.Unsafe.inject i
  let inject_str (s : string) = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.string s)

  (* `Async.AwaitJs`'s resolved value is a monomorphic `Js.Unsafe.any` (the
     effect's own declared return type), unlike `host`/`host0` above (fully
     polymorphic via `Js.Unsafe.fun_call`, so `Js.to_float (host ...)`
     already unifies without help) -- a resolved value needs an explicit
     `Js.Unsafe.coerce` before `Js.to_float`/`Js.to_string` accept it. *)
  let js_to_float (v : Js_of_ocaml.Js.Unsafe.any) : float = Js_of_ocaml.Js.to_float (Js_of_ocaml.Js.Unsafe.coerce v)

  (* a sync gpu/ call can throw a real JS exception (Result::Err on a
     non-async export) -- caught here and re-raised as `Failure`, same
     convention every OTHER failure path in this codebase already uses (see
     the comment above). *)
  let host_checked name args =
    try host name args with
    | Failure _ as e -> raise e
    | e -> failwith (Printexc.to_string e)

  (* builds a plain JS Array from already-`Js.Unsafe.inject`ed elements --
     same `new_obj` + indexed `Js.Unsafe.set` idiom `draw_rects` above
     already uses for a Float64Array, just the plain-Array constructor
     instead (wasm-bindgen's generated glue for a `Vec<T>` PARAMETER accepts
     any array-like via `TypedArray.prototype.set`, so a plain Array of
     numbers/strings is enough -- no need for an actual Float32Array/
     Uint32Array on this side). *)
  let js_array_of (elems : Js_of_ocaml.Js.Unsafe.any array) : Js_of_ocaml.Js.Unsafe.any =
    let open Js_of_ocaml in
    let arr = Js.Unsafe.new_obj (Js.Unsafe.get Js.Unsafe.global "Array") [| Js.Unsafe.inject (Array.length elems) |] in
    Array.iteri (fun i x -> Js.Unsafe.set arr i x) elems;
    Js.Unsafe.inject arr

  (* a Tsubaki `[buf_in, buf_out]`/`[1.5, 2.0, ...]` literal of Ints/Floats is
     always the numeric `VVec` (never `VArr`) -- same convention `draw_rects`
     above already relies on. Used for resource-handle lists (dispatch/
     draw_frame) and float payloads (write_buffer). *)
  let js_array_of_vec (v : vecbuf) : Js_of_ocaml.Js.Unsafe.any =
    js_array_of (Array.map (fun x -> Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.float x)) (vecbuf_to_array v))

  (* a Tsubaki `["storage-read", "uniform", ...]` literal of Strings is the
     general `VArr` (Strings aren't numeric) -- same extraction Ecs.query's
     own `[ "Array" ]` argument already does. *)
  let js_array_of_string_arr (cells : arrbuf) : Js_of_ocaml.Js.Unsafe.any =
    js_array_of
      (Array.map
         (function
           | VStr s -> inject_str s
           | v -> failwith (Printf.sprintf "gpu bridge: expected an Array of Strings, got %s" (tag v)))
         (arrbuf_to_array cells))

  (* reads a JS array-like's `.length` plus each numeric element back into a
     Tsubaki Vector -- `read_buffer`'s resolved Promise value is a `Vec<f32>`
     crossing the wasm-bindgen boundary, which shows up as either a
     Float32Array or a plain Array depending on wasm-bindgen's own glue;
     either way it's array-like (has `.length`, numeric indices), same as
     gpu/test.html's own `Array.from(result)` treats it. *)
  let vvec_of_js_arraylike (v : Js_of_ocaml.Js.Unsafe.any) : value =
    let open Js_of_ocaml in
    let n = int_of_float (Js.to_float (Js.Unsafe.get v "length")) in
    VVec (vecbuf_of_array (Array.init n (fun i -> Js.to_float (Js.Unsafe.get v i))))

  (* get_data(name): the missing host->Tsubaki direction -- draw_rects/key_down/
     mouse_x/mouse_y already let a script push draws out and pull input in,
     but there was no way to pull arbitrary LIVE data in (a moving bus's
     current position, say) without baking it into the source as a literal.
     Same synchronous convention as mouse_x/key_down: calls a JS global the
     host page defines (`host_get_data(name)`), which can compute or look up
     a fresh value on every call -- not a one-time snapshot taken at
     startup. Always a flat numeric Vector (same convention draw_rects/
     read_buffer already use for a variable-length numeric payload); a
     single scalar is just a length-1 Vector. *)
  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "get_data" [ [ "String" ] ] (function
      | [ VStr name ] -> vvec_of_js_arraylike (host "host_get_data" [| Js.Unsafe.inject (Js.string name) |])
      | _ -> assert false)

  (* put_data(name, data): get_data's mirror image, Tsubaki->JS this time --
     draw_rects is Tsubaki->JS too, but it's committed to meaning "a rect to
     paint this frame", not "here is a named result, please keep it"
     (localStorage, a save button, POSTing to a backend, whatever the host
     page wants to do with it). Same flat-numeric-Vector convention as
     get_data/draw_rects; `name` picks which thing on the host side this is
     ("route_x", "edited_nodes", ...). *)
  let () =
    let open Js_of_ocaml in
    Dispatch.defmethod "put_data" [ [ "String" ]; [ "Vector" ] ] (function
      | [ VStr name; VVec v ] ->
        ignore (host "host_put_data" [| Js.Unsafe.inject (Js.string name); js_array_of_vec v |]);
        VNothing
      | _ -> assert false)

  (* `gpu_init`'s resolved value -- `{name, backend, deviceType, driver}`,
     what the browser actually granted (see README's own doc comment on
     `gpu_init`) -- registered as a real struct, not a loosely-typed dict,
     same posture as the existing `LU`/`QR`/`Cholesky`/`SVD` structs
     (Runtime, near `declare_struct ~mutable_:false "LU" ...`). *)
  let () = declare_struct ~mutable_:false "GpuAdapterInfo" ~parent:"Any" ~type_params:[] [ "name"; "backend"; "deviceType"; "driver" ] [ [ "String" ]; [ "String" ]; [ "String" ]; [ "String" ] ]

  let gpu_adapter_info_of_js (v : Js_of_ocaml.Js.Unsafe.any) : value =
    let open Js_of_ocaml in
    let field f = VStr (Js.to_string (Js.Unsafe.get v f)) in
    construct "GpuAdapterInfo" [ field "name"; field "backend"; field "deviceType"; field "driver" ]

  let () =
    Dispatch.defmethod "gpu_init" [] (fun _ ->
      let open Js_of_ocaml in
      gpu_adapter_info_of_js (Effect.perform (Async.AwaitJs (host_checked "host_gpu_init" [| Js.Unsafe.inject Js.undefined |]))))

  let () =
    Dispatch.defmethod "gpu_init" [ [ "String" ] ] (function
      | [ pref ] -> gpu_adapter_info_of_js (Effect.perform (Async.AwaitJs (host_checked "host_gpu_init" [| inject_str (as_str pref) |])))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "gpu_on_device_lost" [] (fun _ -> VStr (Async.js_to_string (Effect.perform (Async.AwaitJs (host_checked "host_gpu_on_device_lost" [||])))))

  let () =
    Dispatch.defmethod "create_buffer" [ [ "Number" ]; [ "String" ] ] (function
      | [ size_bytes; kind ] ->
        let open Js_of_ocaml in
        VInt (int_of_float (Js.to_float (host_checked "host_create_buffer" [| inject_int (as_int size_bytes); inject_str (as_str kind) |])))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "write_buffer" [ [ "Int" ]; [ "Vector" ] ] (function
      | [ handle; VVec data ] ->
        ignore (host_checked "host_write_buffer" [| inject_int (as_int handle); js_array_of_vec data |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "read_buffer" [ [ "Int" ] ] (function
      | [ handle ] -> vvec_of_js_arraylike (Effect.perform (Async.AwaitJs (host_checked "host_read_buffer" [| inject_int (as_int handle) |])))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "destroy_buffer" [ [ "Int" ] ] (function
      | [ handle ] ->
        ignore (host_checked "host_destroy_buffer" [| inject_int (as_int handle) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "create_texture" [ [ "Int" ]; [ "Int" ]; [ "Vector" ] ] (function
      | [ width; height; VVec rgba ] ->
        let open Js_of_ocaml in
        VInt
          (int_of_float
             (Js.to_float
                (host_checked "host_create_texture" [| inject_int (as_int width); inject_int (as_int height); js_array_of_vec rgba |])))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "destroy_texture" [ [ "Int" ] ] (function
      | [ handle ] ->
        ignore (host_checked "host_destroy_texture" [| inject_int (as_int handle) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "create_sampler" [ [ "String" ] ] (function
      | [ filter ] ->
        let open Js_of_ocaml in
        VInt (int_of_float (Js.to_float (host_checked "host_create_sampler" [| inject_str (as_str filter) |])))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "destroy_sampler" [ [ "Int" ] ] (function
      | [ handle ] ->
        ignore (host_checked "host_destroy_sampler" [| inject_int (as_int handle) |]);
        VNothing
      | _ -> assert false)

  (* text_texture/draw_texture: REAL (browser/system) font rendering, unlike
     draw_text's built-in 4x6 bitmap block font above -- rasterization
     itself happens host-side (Canvas2D has real font shaping/hinting/
     antialiasing this crate has no business reimplementing), uploaded as
     an ordinary create_texture texture and drawn through a SEPARATE
     textured-quad render pipeline the host page sets up alongside
     RECT_WGSL's solid-color one (see web/text-demo.html) -- same "host
     does the browser-native heavy lifting, this file only orchestrates"
     posture create_texture/gpu_init already use. *)
  let () =
    declare_struct ~mutable_:false "TextTexture" ~parent:"Any" ~type_params:[] [ "handle"; "width"; "height" ] [ [ "Int" ]; [ "Int" ]; [ "Int" ] ]

  let text_texture_of_js (v : Js_of_ocaml.Js.Unsafe.any) : value =
    let open Js_of_ocaml in
    let field i = int_of_float (Js.to_float (Js.Unsafe.get v i)) in
    construct "TextTexture" [ VInt (field 0); VInt (field 1); VInt (field 2) ]

  (* host_text_texture(text, font, size) rasterizes + uploads + caches by
     (text, font, size) host-side (see web/text-demo.html) and hands back a
     plain [handle, width, height] JS array -- synchronous the same way
     create_texture itself is (Canvas2D calls and create_texture are both
     sync), so this is a plain host_checked call, no AwaitJs needed. *)
  let () =
    Dispatch.defmethod "text_texture" [ [ "String" ]; [ "String" ]; [ "Number" ] ] (function
      | [ VStr text; VStr font; size ] ->
        text_texture_of_js
          (host_checked "host_text_texture" [| inject_str text; inject_str font; inject_float (as_float size) |])
      | _ -> assert false)

  (* draw_texture: draw_rect's textured sibling -- (r,g,b,a) TINTS the
     texture (multiplied in the fragment shader, see the WGSL in
     web/text-demo.html) rather than describing a solid fill, so the same
     cached TextTexture can be redrawn in a different color without
     re-rasterizing. *)
  let () =
    Dispatch.defmethod "draw_texture"
      [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Int" ]; [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ]
      (function
        | [ x; y; w; h; texture_handle; r; g; b; a ] ->
          ignore
            (host "host_gpu_draw_texture"
               [| inject_float (as_float x)
                ; inject_float (as_float y)
                ; inject_float (as_float w)
                ; inject_float (as_float h)
                ; inject_int (as_int texture_handle)
                ; inject_float (as_float r)
                ; inject_float (as_float g)
                ; inject_float (as_float b)
                ; inject_float (as_float a)
               |]);
          VNothing
        | _ -> assert false)

  let () =
    Dispatch.defmethod "create_pipeline" [ [ "String" ]; [ "String" ]; [ "Array" ] ] (function
      | [ wgsl; entry_point; VArr { cells; _ } ] ->
        VInt
          (int_of_float
             (js_to_float
                (Effect.perform
                   (Async.AwaitJs
                      (host_checked "host_create_pipeline" [| inject_str (as_str wgsl); inject_str (as_str entry_point); js_array_of_string_arr cells |])))))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "destroy_pipeline" [ [ "Int" ] ] (function
      | [ handle ] ->
        ignore (host_checked "host_destroy_pipeline" [| inject_int (as_int handle) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "dispatch" [ [ "Int" ]; [ "Vector" ]; [ "Int" ]; [ "Int" ]; [ "Int" ] ] (function
      | [ pipeline; VVec handles; wg_x; wg_y; wg_z ] ->
        ignore
          (host_checked "host_dispatch"
             [| inject_int (as_int pipeline); js_array_of_vec handles; inject_int (as_int wg_x); inject_int (as_int wg_y); inject_int (as_int wg_z) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "configure_canvas" [ [ "String" ]; [ "Int" ]; [ "Int" ]; [ "String" ] ] (function
      | [ canvas_id; width; height; alpha_mode ] ->
        ignore
          (host_checked "host_configure_canvas"
             [| inject_str (as_str canvas_id); inject_int (as_int width); inject_int (as_int height); inject_str (as_str alpha_mode) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "create_render_pipeline" [ [ "String" ]; [ "String" ]; [ "String" ]; [ "Array" ]; [ "String" ]; [ "String" ] ] (function
      | [ wgsl; vertex_entry; fragment_entry; VArr { cells; _ }; topology; blend ] ->
        VInt
          (int_of_float
             (js_to_float
                (Effect.perform
                   (Async.AwaitJs
                      (host_checked "host_create_render_pipeline"
                         [| inject_str (as_str wgsl)
                          ; inject_str (as_str vertex_entry)
                          ; inject_str (as_str fragment_entry)
                          ; js_array_of_string_arr cells
                          ; inject_str (as_str topology)
                          ; inject_str (as_str blend)
                         |])))))
      | _ -> assert false)

  let () =
    Dispatch.defmethod "destroy_render_pipeline" [ [ "Int" ] ] (function
      | [ handle ] ->
        ignore (host_checked "host_destroy_render_pipeline" [| inject_int (as_int handle) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "begin_frame" [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ] (function
      | [ r; g; b; a ] ->
        ignore
          (host_checked "host_begin_frame" [| inject_float (as_float r); inject_float (as_float g); inject_float (as_float b); inject_float (as_float a) |]);
        VNothing
      | _ -> assert false)

  let draw_frame_impl pipeline handles vertex_count instance_count =
    ignore
      (host_checked "host_draw_frame"
         [| inject_int (as_int pipeline); js_array_of_vec handles; inject_int (as_int vertex_count); inject_int (as_int instance_count) |]);
    VNothing

  (* instance_count defaults to 1 (the old, only-ever-possible behavior) when
     omitted -- see gpu/src/lib.rs's own draw_frame doc comment for what a
     Tsubaki script actually gets from passing more: the WGSL shader reads
     `@builtin(instance_index)` itself, e.g. to index a bound storage buffer
     of per-entity positions (exactly what `soa_flatten`, bin/ecs.ml, hands
     back). *)
  let () =
    Dispatch.defmethod "draw_frame" [ [ "Int" ]; [ "Vector" ]; [ "Int" ] ] (function
      | [ pipeline; VVec handles; vertex_count ] -> draw_frame_impl pipeline handles vertex_count (VInt 1)
      | _ -> assert false)

  let () =
    Dispatch.defmethod "draw_frame" [ [ "Int" ]; [ "Vector" ]; [ "Int" ]; [ "Int" ] ] (function
      | [ pipeline; VVec handles; vertex_count; instance_count ] -> draw_frame_impl pipeline handles vertex_count instance_count
      | _ -> assert false)

  let () =
    Dispatch.defmethod "end_frame" [] (fun _ ->
      ignore (host_checked "host_end_frame" [||]);
      VNothing)

  let () =
    Dispatch.defmethod "gpu_shutdown" [] (fun _ ->
      ignore (host_checked "host_gpu_shutdown" [||]);
      VNothing)

  (* the one closure a Tsubaki script registers to be called once per animation
     frame -- `VClosure` is Tsubaki's only first-class function value (a bare
     NAMED `function` isn't itself passable), so a script writes
     `on_frame(function() ... end)` or `on_frame(() -> ...)`. *)
  let frame_callback : value option ref = ref None

  let () =
    Dispatch.defmethod "on_frame" [ [ "Function" ] ] (function
      | [ (VClosure _ as f) ] ->
        frame_callback := Some f;
        VNothing
      | _ -> assert false)

  (* called from JS (`tsubakiRunFrame()`, wired below) once per animation
     frame -- an exception here must NOT propagate into the caller's own
     `requestAnimationFrame` loop (that would kill the loop after the very
     first Tsubaki-side error instead of just that one frame), so it's caught
     and reported the same way this crate already reports any other runtime
     error: printed, not silently swallowed.

     `false` back means "this frame raised". The browser loop ignores that and
     keeps going (the frame after a bad one usually still draws something, and
     there's no console to exit to anyway); the headless `--frames N` runner in
     main.ml stops. That difference matters more than it looks: a frame body
     that dies HALFWAY through leaves the world half-updated -- the despawn!
     that came after the failing call didn't run -- so every later frame is
     working on a state the program never meant to reach. Six hundred lines of
     the same error, and a score counted twice, is what that looked like before
     anyone stopped. *)
  let run_frame (dt : float) : bool =
    match !frame_callback with
    | Some (VClosure (arity, f)) -> (
      (* arity-aware: a callback declared with ONE param gets the frame delta
         (seconds); zero-arg callbacks -- the shape every existing example
         uses -- are still called with no args and keep working unchanged.
         A callback with >=2 params also gets [], which then fails cleanly in
         the closure's own List.iter2 param-binding and is reported below,
         rather than silently receiving a stray dt. *)
      let args = if arity = 1 then [ VFloat dt ] else [] in
      let fail msg =
        print_endline ("tsubaki: on_frame error: " ^ msg);
        false
      in
      try
        Async.run_effectful (fun () -> ignore (f args));
        true
      with
      | Failure msg -> fail msg
      (* a user `error(...)`/`throw(...)` raises this, not Failure (see
         STry's own comment on the same split) -- without this arm it fell
         through to the generic Printexc.to_string below, which has no
         printer for JuliaError and shows the useless OCaml constructor name
         instead of the actual message. *)
      | JuliaError v -> fail (show v)
      | e -> fail (Printexc.to_string e))
    | _ -> true

  let () =
    let open Js_of_ocaml in
    Js.Unsafe.set Js.Unsafe.global "tsubakiRunFrame" (Js.wrap_callback (fun dt -> ignore (run_frame dt)))

  (* see the comment at the top of this file -- called from main.ml purely
     to force this module to be linked *)
  let init () = ()
