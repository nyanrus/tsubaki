(* ===================== browser bridge: audio ======================
   Registers `play_tone(freq, duration; volume=0.3, wave="sine")` so a Tsubaki
   script can get a fire-and-forget beep -- hit sounds / feedback, not a
   music/sample-loading system. Browser-only (Web Audio API has no Node
   equivalent), same posture as gpuBridge.ml: calls a `host_audio_tone` JS
   global, defined by web/demo.html, using the same
   `Js.Unsafe.fun_call`/`inject_float` FFI convention every other bridge here
   uses.

   `volume`/`wave` are keyword args, read from `Runtime.current_kwargs` --
   the same side-channel a user-defined function's own kwparams read from
   (see that ref's comment in runtime.ml): eval.ml's ECall case sets it right
   before calling ANY resolved impl, builtin or not, so this builtin reads it
   exactly the way a `function play_tone(freq, duration; volume=0.3, ...)`
   written in Tsubaki itself would.

   `init` below exists ONLY to force this module to be linked, same reason
   CurveBridge.init/GpuBridge.init do (see either's own comment). *)
open Runtime

let as_float = function
  | VFloat v -> v
  | VInt v -> float_of_int v
  | _ -> failwith "audio bridge: expected a number"

let host name args = Runtime.host_call ~area:"audio" name args

let inject_float f = Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.float f)

let () =
  Dispatch.defmethod "play_tone" [ [ "Number" ]; [ "Number" ] ] (function
    | [ freq; duration ] ->
      let volume = match List.assoc_opt "volume" !current_kwargs with Some v -> as_float v | None -> 0.3 in
      let wave = match List.assoc_opt "wave" !current_kwargs with Some (VStr s) -> s | _ -> "sine" in
      ignore
        (host "host_audio_tone"
           [| inject_float (as_float freq)
            ; inject_float (as_float duration)
            ; inject_float volume
            ; Js_of_ocaml.Js.Unsafe.inject (Js_of_ocaml.Js.string wave)
           |]);
      VNothing
    | _ -> assert false)

(* see the comment at the top of this file -- called from main.ml purely
   to force this module to be linked *)
let init () = ()
