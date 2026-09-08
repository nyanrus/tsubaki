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
   Vector), Dict <-> object, Tuple -> Array, struct -> { __type, ...fields }.
   Anything else comes across as its printed form. Closures do not cross.

   Errors raised on the Tsubaki side become a JS Error with the same message.
   `init` exists for the same reason as CurveBridge.init: to be linked. *)
open Runtime
open Js_of_ocaml

let rec js_of_value (v : value) : Js.Unsafe.any =
  let inject = Js.Unsafe.inject in
  let num f = inject (Js.number_of_float f) in
  match v with
  | VInt i -> num (float_of_int i)
  | VFloat f -> num f
  | VBool b -> inject (Js.bool b)
  | VStr s -> inject (Js.string s)
  | VNothing -> inject Js.null
  | VVec { vdata; vlen } -> inject (Js.array (Array.init vlen (fun i -> Js.number_of_float vdata.(i))))
  | VArr { cells; _ } -> inject (Js.array (Array.init cells.alen (fun i -> js_of_value cells.adata.(i))))
  | VTuple a -> inject (Js.array (Array.map js_of_value a))
  | VDict d ->
    let entries = Hashtbl.fold (fun _ (stamp, k, v) acc -> (stamp, k, v) :: acc) d.dtbl [] in
    let entries = List.sort (fun (a, _, _) (b, _, _) -> compare a b) entries in
    let key = function VStr s -> s | VSymbol (s, _) -> s | k -> show k in
    Js.Unsafe.obj (Array.of_list (List.map (fun (_, k, v) -> (key k, js_of_value v)) entries))
  | VStruct { kind; fields } ->
    Js.Unsafe.obj
      (Array.append [| ("__type", inject (Js.string kind)) |] (Array.map (fun (n, r) -> (n, js_of_value !r)) fields))
  | other -> inject (Js.string (show other))

let rec value_of_js (x : Js.Unsafe.any) : value =
  let typeof = Js.to_string (Js.typeof x) in
  if typeof = "number" then (
    let f = Js.float_of_number (Js.Unsafe.coerce x) in
    if Float.is_integer f && Float.abs f < 9007199254740992.0 then VInt (int_of_float f) else VFloat f)
  else if typeof = "string" then VStr (Js.to_string (Js.Unsafe.coerce x))
  else if typeof = "boolean" then VBool (Js.to_bool (Js.Unsafe.coerce x))
  else if typeof = "undefined" || x == Js.Unsafe.inject Js.null then VNothing
  else if Js.to_bool (Js.Unsafe.fun_call (Js.Unsafe.js_expr "Array.isArray") [| x |]) then (
    let arr = Js.to_array (Js.Unsafe.coerce x) in
    let all_numbers = Array.for_all (fun e -> Js.to_string (Js.typeof e) = "number") arr in
    if all_numbers then VVec (vecbuf_of_array (Array.map (fun e -> Js.float_of_number (Js.Unsafe.coerce e)) arr))
    else
      let cells = Array.map value_of_js arr in
      VArr { declared = None; cells = { adata = cells; alen = Array.length cells; atag = None } })
  else (
    let d = { dtbl = Hashtbl.create 8; dnext = 0 } in
    let keys = Js.to_array (Js.Unsafe.fun_call (Js.Unsafe.js_expr "Object.keys") [| x |]) in
    Array.iter
      (fun k ->
        let ks = Js.to_string k in
        dict_set d (VStr ks) (value_of_js (Js.Unsafe.get x (Js.string ks))))
      keys;
    VDict d)

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
  | exception Parser.Parse_error msg -> error msg
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
  Js.Unsafe.set Js.Unsafe.global "tsubakiReady" (Js.bool true);
  (* the host's own callback: whatever it raises is the host's to see, and
     must not take Tsubaki's initialization down with it *)
  if Js.to_bool (Js.Unsafe.js_expr "typeof globalThis.tsubakiOnReady === 'function'") then
    ignore
      (Js.Unsafe.fun_call
         (Js.Unsafe.js_expr
            "() => { try { globalThis.tsubakiOnReady(); } catch (e) { console.error('tsubaki: tsubakiOnReady raised:', e); } }")
         [||])

(* called from main.ml purely to force this module to be linked *)
let init () = ()
