(* ===================== await, without a Tsubaki-level `await` keyword ======================
   `gpu/`'s real wgpu API is genuinely async (`await gpu_init()`, `await
   read_buffer(...)`, ...) -- Eval.eval is a plain synchronous recursive
   function, so calling one of those from a Tsubaki builtin needs the WHOLE
   interpreter call stack (not just this one FFI call) to suspend and later
   resume, without Eval.eval itself ever being rewritten in CPS by hand.

   OCaml 5's effect handlers do exactly this. `AwaitJs` is performed by a
   builtin's OCaml implementation (see GpuBridge's async defmethods); nothing
   about EVAL, ECall, or any AST node needs to know awaiting happened at all
   -- from Eval's point of view, the builtin function just "returned a value"
   (eventually). That's what makes this transparent to Tsubaki source: no new
   syntax, `gpu_init()` reads and behaves like any other synchronous call.

   wasm_of_ocaml's default effect implementation (`--effects=jspi`) needs the
   browser/Node's own JavaScript Promise Integration support, which isn't
   available in a plain `node` invocation (confirmed directly: "the
   JavaScript Promise Integration API is not enabled"). `bin/dune` instead
   builds with `--effects=cps` (a whole-program CPS transform, no runtime
   flag needed anywhere) -- confirmed working, including a SECOND perform
   inside the resumed continuation (see the `match_with` re-wrap in
   `resume` below), via a standalone spike before writing this file. *)

open Effect
open Effect.Deep

type _ Effect.t += AwaitJs : Js_of_ocaml.Js.Unsafe.any -> Js_of_ocaml.Js.Unsafe.any Effect.t

(* a JS value's own `String(x)` coercion -- works for an Error (its message),
   a plain string, or anything else a rejected Promise might carry, same
   "always get SOME readable text back" spirit as `exn_of_failure_message`
   already applies on the Tsubaki-exception side of this. *)
let js_to_string (v : Js_of_ocaml.Js.Unsafe.any) : string =
  let open Js_of_ocaml in
  Js.to_string (Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global "String") [| v |])

(* re-declared `rec` because `effc` below closes over `handler` itself --
   every resume re-installs THIS SAME handler (see the comment on `resume`) *)
let rec handler =
  { retc = (fun () -> ())
  ; exnc = (fun e -> raise e)
  ; effc =
      (fun (type a) (eff : a Effect.t) ->
        match eff with
        | AwaitJs promise ->
          Some
            (fun (k : (a, unit) continuation) ->
              let open Js_of_ocaml in
              (* `continue`/`discontinue` resume the captured computation
                 wherever THIS call happens to run (here, inside a Promise
                 callback with no handler of its own in scope) -- if that
                 resumed computation performs a SECOND AwaitJs (e.g. a
                 script that calls `gpu_init()` then `create_pipeline(...)`),
                 it needs a handler installed around ITS OWN dynamic
                 extent too, so `resume` below re-wraps every continue/
                 discontinue in a fresh `match_with` against this same
                 `handler` -- verified necessary and sufficient for chained
                 sequential awaits by a standalone spike before this file
                 was written. *)
              let resume (f : unit -> unit) = ignore (match_with f () handler) in
              let on_fulfilled = Js.wrap_callback (fun v -> resume (fun () -> continue k v)) in
              let on_rejected =
                Js.wrap_callback (fun reason -> resume (fun () -> discontinue k (Failure (js_to_string reason))))
              in
              ignore (Js.Unsafe.meth_call promise "then" [| Js.Unsafe.inject on_fulfilled; Js.Unsafe.inject on_rejected |]))
        | _ -> None)
  }

(* the two real entry points a Tsubaki program's own await-capable code can
   run through -- Eval.run (top-level script execution) and GpuBridge's
   run_frame (the per-animation-frame re-entry) -- both call this instead of
   invoking their body directly.

   handler を実際に張るのは、await するものがある build だけ。await が
   出てくるのは gpu/ の橋からで、それを持たない build(drop に積むほう)は
   ただ呼ぶ -- `--effects=disabled` で建てた wasm では `match_with` 自体が
   通らないので(「trying to suspend without WebAssembly.promising」)、
   張らないことが要ります。差し込むのは Async.install、呼ぶのは main.ml。 *)
let runner : ((unit -> unit) -> unit) ref = ref (fun f -> f ())
let run_effectful (f : unit -> unit) : unit = !runner f
let install () = runner := fun f -> ignore (match_with f () handler)
