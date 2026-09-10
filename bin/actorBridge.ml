(* ===================== browser bridge: a host drives Tsubaki ==================
   For a host page (a noraneko drop, say) that keeps Tsubaki as its logic and
   draws with its own JS: three plain JS globals, and values that cross the
   boundary as ordinary JS values.

     tsubakiEval(src)          run source at top level; state carries over
                               (the same persistent global scope the REPL uses)
     tsubakiCall(name, args)   call a Tsubaki function by name with a JS array
     tsubakiOnReady            if the host defined this function before the
                               script loaded, it is called once Tsubaki is up
     tsubakiEmbedded = true    tells main.ml not to run the CLI / demo

   Values: Int/Float <-> number, Bool <-> boolean, String <-> string,
   nothing <-> null, Vector <-> Array (numeric Arrays become the numeric
   Vector), Dict <-> object, Tuple -> Array, struct -> { __type, ...fields },
   a closure -> a real JS function. Anything else comes across as its printed
   form. The conversions themselves live in Runtime (js_of_value /
   value_of_js), next to the `VJS` handle they share a boundary with.

   Errors raised on the Tsubaki side become a JS Error with the same message.
   `init` exists for the same reason as CurveBridge.init: to be linked. *)
open Runtime
open Js_of_ocaml

(* A Tsubaki-side error must reach the host as a JS Error. An exception
   thrown across the wasm boundary arrives as an opaque WebAssembly.Exception,
   so nothing is thrown here: the result is { ok } or { error }, and the small
   JS wrapper installed below is the one that throws. *)
let guarded (f : unit -> value) : Js.Unsafe.any =
  let ok v = Js.Unsafe.obj [| ("ok", v) |] in
  let error msg = Js.Unsafe.obj [| ("error", Js.Unsafe.inject (Js.string msg)) |] in
  match js_of_value (f ()) with
  | v -> ok v
  | exception Failure msg -> error msg
  | exception JuliaError v -> error (show v)
  | exception Ast.Parse_error msg -> error msg
  | exception e -> error (Printexc.to_string e)

let eval_raw (src : Js.js_string Js.t) : Js.Unsafe.any =
  guarded (fun () -> Eval.eval_toplevel (Js.to_string src))

let call_raw (name : Js.js_string Js.t) (args : Js.Unsafe.any) : Js.Unsafe.any =
  guarded (fun () ->
    let args = List.map value_of_js (Array.to_list (Js.to_array (Js.Unsafe.coerce args))) in
    let result = ref VNothing in
    Async.run_effectful (fun () -> result := Dispatch.call (Js.to_string name) args);
    !result)

let () =
  let unwrap =
    Js.Unsafe.js_expr
      "(raw) => (...args) => { const r = raw(...args); if (r.error !== undefined) throw new Error(r.error); return r.ok; }"
  in
  let export name f = Js.Unsafe.set Js.Unsafe.global name (Js.Unsafe.fun_call unwrap [| Js.Unsafe.inject (Js.wrap_callback f) |]) in
  export "tsubakiEval" eval_raw;
  export "tsubakiCall" call_raw;
  Js.Unsafe.set Js.Unsafe.global "tsubakiReady" (Js.bool true)

(* Unlike every other bridge's, this `init` does something: it tells the host
   Tsubaki is up. That has to happen from main.ml rather than from this
   module's own top level, because a module's top level runs at LINK time --
   and the modules linked after this one (JsBridge, among them) have not
   registered their methods yet at that point. A host callback that reached
   for `jsglobal` got "no method matching jsglobal(String)": true at that
   instant, and gone a moment later. main.ml's body runs after every module
   is initialized, so from there the language really is whole. *)
let init () =
  (* the host's own callback: whatever it raises is the host's to see, and
     must not take Tsubaki's initialization down with it *)
  if Js.to_bool (Js.Unsafe.js_expr "typeof globalThis.tsubakiOnReady === 'function'") then
    ignore
      (Js.Unsafe.fun_call
         (Js.Unsafe.js_expr
            "() => { try { globalThis.tsubakiOnReady(); } catch (e) { console.error('tsubaki: tsubakiOnReady raised:', e); } }")
         [||])
