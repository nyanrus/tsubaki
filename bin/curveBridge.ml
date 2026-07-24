(* ===================== browser bridge: elliptic curve toy ======================
   museum.atfedi.de's EcCurveGpu toy wants its curve math (f/add) to actually run
   through Tsubaki instead of a hand-copied JS port. This registers real Julia
   source for both, then exports two plain-float JS functions -- `f` and `add`
   deal in the same Runtime.value ADT everything else in this file uses, so the
   JS side never sees it; it only sees floats/nulls/Float64Arrays, same
   convention as `host_matvec` below.

   `init` below exists ONLY to give `main.ml` something to call: now that
   this lives in its own compilation unit (post file-split), nothing else
   in the program ever references this module by name -- and unlike a
   single-file build (where every top-level structure item unconditionally
   runs as part of initializing the one enclosing compilation unit), a
   never-referenced module here was ACTUALLY DROPPED by the wasm/js output
   (verified directly: `tsubakiCurveF`/`tsubakiCurveAdd` were entirely absent
   from the compiled output before this fix -- 0 occurrences, not a
   theoretical worry). Calling `init ()` from `main.ml` forces this module
   to be linked, which runs its own top-level `let () = ...` bindings below
   as an ordinary side effect of module initialization -- `init` itself
   does nothing. *)
  open Runtime

  (* `^`, `abs`, and scientific-notation float literals were all real gaps
     when this was first written (see git history / the blog post) -- now
     real builtins, so this reads like ordinary Julia instead of working
     around any of the three. *)
  let () =
    Eval.run
      {|
A = -2.0
B = 2.0

f(x) = x^3 + A * x + B

function add(p1x, p1y, qx, qy)
    if abs(p1x - qx) < 1e-12 && abs(p1y + qy) < 1e-12
        return nothing
    end
    m = abs(p1x - qx) < 1e-12 ? (3 * p1x^2 + A) / (2 * p1y) : (qy - p1y) / (qx - p1x)
    x = m^2 - p1x - qx
    y = m * (x - p1x) + p1y
    return x, -y, m, p1y - m * p1x
end
|}

  let as_float = function
    | VFloat v -> v
    | VInt v -> float_of_int v
    | _ -> failwith "curve bridge: expected a number"

  let curve_f (x : float) : float = as_float (Dispatch.call "f" [ VFloat x ])

  (* `null` for the point-at-infinity case (mirrors the original JS `return
     null`); otherwise a 4-element Float64Array `[x, y, m, c]`. *)
  let curve_add (p1x : float) (p1y : float) (qx : float) (qy : float) =
    let open Js_of_ocaml in
    match Dispatch.call "add" [ VFloat p1x; VFloat p1y; VFloat qx; VFloat qy ] with
    | VNothing -> Js.Unsafe.inject Js.null
    | VTuple [| x; y; m; c |] ->
      let out = Js.Unsafe.new_obj Typed_array.float64Array [| Js.Unsafe.inject 4 |] in
      Typed_array.set out 0 (as_float x);
      Typed_array.set out 1 (as_float y);
      Typed_array.set out 2 (as_float m);
      Typed_array.set out 3 (as_float c);
      Js.Unsafe.inject out
    | _ -> failwith "add: unexpected result shape"

  let () =
    let open Js_of_ocaml in
    Js.Unsafe.set Js.Unsafe.global "tsubakiCurveF" (Js.wrap_callback curve_f);
    Js.Unsafe.set Js.Unsafe.global "tsubakiCurveAdd" (Js.wrap_callback curve_add)

  (* see the comment at the top of this file -- called from main.ml purely
     to force this module to be linked *)
  let init () = ()
