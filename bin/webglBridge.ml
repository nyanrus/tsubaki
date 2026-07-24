(* ===================== browser bridge: raw WebGL2, straight from Tsubaki ======================
   Runs `to_glsl`'s output for real. `to_glsl` (bin/compile.ml's Compile.Glsl)
   turns a Tsubaki `quote...end` vertex+fragment pair into real GLSL ES 3.00
   text -- but until now nothing actually RAN that text: it was foundational
   only, verified against a throwaway WebGL2 page and then left as a stepping
   stone (see eval.ml's to_glsl doc comment, and README's to_glsl section).
   This is the missing sink: a handful of builtins so a Tsubaki script can hand
   its own to_glsl output to a real WebGL2 context and draw.

   Unlike gpu/ (the wgpu/WebGPU crate, reached through wasm-bindgen), NOTHING
   here touches Rust at all -- every call forwards straight to a `host_webgl_*`
   JS global that the host page implements with the plain browser WebGL2 API
   (`gl.createShader`/`compileShader`/`linkProgram`/`uniform*`/`drawArrays`).
   That is what "JS経由でWebGL対応" means here: the GLSL comes from Tsubaki, the
   GL calls happen in JS, no wgpu in the path.

   WebGL2 is entirely SYNCHRONOUS (getting the context, compiling/linking a
   program, setting uniforms, drawing -- none of it returns a Promise, unlike
   WebGPU's adapter/device request). So every builtin below is an ordinary
   synchronous `host_call`, the same shape as GpuBridge's clear_screen/
   draw_rect -- none of async.ml's AwaitJs effect machinery is needed at all.

   `init` below exists only to force this module to be linked, same reason
   CurveBridge.init/GpuBridge.init do -- a module nothing else references by
   name has its top-level `let () = ...` registrations silently dropped from
   the compiled output otherwise. *)
  open Runtime

  let as_float = function
    | VFloat v -> v
    | VInt v -> float_of_int v
    | _ -> failwith "webgl bridge: expected a number"

  let inject_float f = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.float f)
  let inject_int (i : int) = Js_of_ocaml.Js.Unsafe.inject i
  let inject_str s = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.string s)

  let host name args = Runtime.host_call ~area:"webgl" name args

  (* a plain JS Array of numbers from an OCaml float array -- each element
     wrapped through `Js.float` first, same reason GpuBridge does (a raw
     OCaml float injected directly is not a usable JS number on WasmGC). *)
  let js_floats (xs : float array) : Js_of_ocaml.Js.Unsafe.any =
    let open Js_of_ocaml in
    let arr = Js.Unsafe.new_obj (Js.Unsafe.get Js.Unsafe.global "Array") [| Js.Unsafe.inject (Array.length xs) |] in
    Array.iteri (fun i x -> Js.Unsafe.set arr i (Js.Unsafe.inject (Js.float x))) xs;
    Js.Unsafe.inject arr

  (* webgl_program(vertexGlsl, fragmentGlsl) -> an Int program handle. The two
     Strings are exactly what to_glsl returns (shaders[1], shaders[2]). The
     host compiles+links and returns an integer handle; a GLSL compile/link
     error is raised host-side with the real info log (same "real errors, not
     silent reinterpretation" voice as the wgpu crate's own shader path). *)
  let () =
    Dispatch.defmethod "webgl_program" [ [ "String" ]; [ "String" ] ] (function
      | [ VStr vertex; VStr fragment ] ->
        let h = host "host_webgl_program" [| inject_str vertex; inject_str fragment |] in
        VInt (int_of_float (Js_of_ocaml.Js.to_float h))
      | _ -> assert false)

  (* webgl_clear(r, g, b, a) -- clears the whole canvas to that color. *)
  let () =
    Dispatch.defmethod "webgl_clear" [ [ "Number" ]; [ "Number" ]; [ "Number" ]; [ "Number" ] ] (function
      | [ r; g; b; a ] ->
        ignore (host "host_webgl_clear" [| inject_float (as_float r); inject_float (as_float g); inject_float (as_float b); inject_float (as_float a) |]);
        VNothing
      | _ -> assert false)

  (* webgl_uniform(prog, name, values) -- set a uniform by name. The value's
     LENGTH picks the GL call, covering exactly to_glsl's uniform vocabulary:
     1 -> float, 2/3/4 -> vec2/vec3/vec4, 16 -> mat4. A numeric Vector carries
     the scalars/vecN; a Matrix literal (row-major, real Julia's own [.. ; ..]
     syntax) is the natural way to write a mat4 -- both funnel to the same
     host_webgl_uniform, which reads the length and (for 16) uploads with
     transpose=true so a row-major Tsubaki matrix lands correctly in GLSL's
     column-major mat4. *)
  let () =
    Dispatch.defmethod "webgl_uniform" [ [ "Number" ]; [ "String" ]; [ "Vector" ] ] (function
      | [ prog; VStr name; VVec v ] ->
        ignore
          (host "host_webgl_uniform"
             [| inject_int (int_of_float (as_float prog)); inject_str name; js_floats (vecbuf_to_array v) |]);
        VNothing
      | _ -> assert false)

  let () =
    Dispatch.defmethod "webgl_uniform" [ [ "Number" ]; [ "String" ]; [ "Matrix" ] ] (function
      | [ prog; VStr name; VMat rows ] ->
        let flat = Array.concat (Array.to_list rows) in
        ignore
          (host "host_webgl_uniform"
             [| inject_int (int_of_float (as_float prog)); inject_str name; js_floats flat |]);
        VNothing
      | _ -> assert false)

  (* webgl_draw(prog, mode, vertexCount) -- useProgram + drawArrays. `mode` is
     a String ("triangles"/"triangle_strip"/"lines"/"line_strip"/"points"),
     resolved to a real GL enum host-side. No vertex buffers: the shaders drive
     geometry off gl_VertexID (to_glsl's `vertex_index`), same convention the
     WebGPU triangle already uses. *)
  let () =
    Dispatch.defmethod "webgl_draw" [ [ "Number" ]; [ "String" ]; [ "Number" ] ] (function
      | [ prog; VStr mode; count ] ->
        ignore
          (host "host_webgl_draw"
             [| inject_int (int_of_float (as_float prog)); inject_str mode; inject_int (int_of_float (as_float count)) |]);
        VNothing
      | _ -> assert false)

  (* see the module header -- called from main.ml purely to force linking *)
  let init () = ()
