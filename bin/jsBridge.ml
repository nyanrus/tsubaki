(* ============ JS values: the handle, and the two doors beside it ==========
   `VJS` (see Runtime) is a JS value held as it is -- `document`, a
   `<browser>` element, Preact's `h`. This file is only the surface a Tsubaki
   program sees:

     jsglobal(name)  the host's global of that name ("document", "Math",
                     "globalThis"). The one way IN; everything past it is
                     reached by ordinary field reads and calls --
                     `doc.getElementById("panel")`, `el.hidden = true`.
     tojs(v)         a deep copy OUT: Dict -> object, Array -> Array, a
                     closure -> a real JS function. Seldom needed by hand,
                     since the arguments of a JS call already go through it.
     fromjs(x)       the deep read back IN: object -> Dict, Array -> Vector.
                     For a JS value that really is only data (a parsed JSON,
                     a small record), not something to keep hold of.

   `init` exists for the same reason as CurveBridge.init: to be linked. *)
open Runtime

let () =
  Dispatch.defmethod "jsglobal" [ [ "String" ] ] (function
    | [ VStr name ] ->
      let open Js_of_ocaml in
      let v = Js.Unsafe.get Js.Unsafe.global (Js.string name) in
      if Js.to_string (Js.typeof v) = "undefined" then
        failwith (Printf.sprintf "UndefVarError: this host has no global named %s" name);
      value_of_js_shallow v
    | _ -> assert false);
  Dispatch.defmethod "tojs" [ [ "Any" ] ] (function
    | [ v ] -> VJS (js_of_value v)
    | _ -> assert false);
  Dispatch.defmethod "fromjs" [ [ "JSValue" ] ] (function
    | [ VJS x ] -> value_of_js x
    | _ -> assert false)

(* see the comment at the top of this file -- called from main.ml purely
   to force this module to be linked *)
let init () = ()
