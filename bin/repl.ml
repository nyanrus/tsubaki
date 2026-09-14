(* ============================= REPL =============================
   Read a line, evaluate it, show what it came to, keep the result around for
   the next line. Everything runs against Eval's single `global` scope, so a
   struct declared at one prompt is still declared at the next.

   Two things a one-line-at-a-time loop has to get right:

   - A declaration spans several lines. `function f(x)` alone is not a
     program; the loop keeps reading until every block that was opened has
     been closed (see `block_depth`) and only then evaluates the whole thing.
   - Nothing here may be fatal. A parse error, a MethodError, an
     UndefVarError -- each is reported and the prompt comes straight back,
     with everything defined so far still defined.

   Input comes through `host_read_line` (preload.js) rather than OCaml's own
   `read_line`: under wasm_of_ocaml there is no stdin channel wired up to
   read from, so the host has to hand lines over the same synchronous FFI
   every other bridge here uses. *)

let banner =
  "Tsubaki -- a Julia-like language. Ctrl-D to leave.\n\
   Type an expression to see its value; end a line with ; to keep it quiet.\n"

let prompt = "tsubaki> "
let continuation_prompt = "      .. "

(* None at end of input (Ctrl-D): `host_read_line` returns JS null there, and
   Js.Opt is exactly the type that reads a null as an absence *)
let read_line_host () : string option =
  let open Js_of_ocaml in
  let v : Js.js_string Js.t Js.opt =
    Js.Unsafe.fun_call (Js.Unsafe.get Js.Unsafe.global "host_read_line") [||]
  in
  Option.map Js.to_string (Js.Opt.to_option v)

(* How many blocks are still open in what has been typed so far -- 0 means
   this is a complete program and can be run.

   Counted over real TOKENS, not raw text, so a `# comment about end` or an
   "end" inside a string literal can't confuse it. An `end` inside brackets is
   real Julia's index-of-last-element (`v[end]`), a completely different
   meaning of the same keyword, so bracket depth is tracked alongside and
   those are skipped. `mutable`/`type` are deliberately NOT counted: `mutable
   struct X ... end` and `abstract type X end` each open exactly one block,
   counted by `struct` and `abstract` respectively.

   A source that does not even tokenize -- an unterminated string literal
   being the ordinary case -- counts as still open, so the loop keeps reading
   rather than reporting an error about a line the writer has not finished. *)
let block_depth (src : string) : int =
  match Lexer.tokenize src with
  | exception _ -> 1
  | toks ->
    let depth = ref 0 in
    let brackets = ref 0 in
    List.iter
      (fun (t, _, _, _) ->
        match t with
        | Lexer.TOP ("[" | "(") -> incr brackets
        | Lexer.TOP ("]" | ")") -> decr brackets
        | Lexer.TKW ("function" | "if" | "for" | "while" | "struct" | "macro" | "module" | "quote" | "try" | "abstract")
          -> incr depth
        | Lexer.TKW "end" when !brackets <= 0 -> decr depth
        | _ -> ())
      toks;
    max 0 !depth

let report_error msg =
  (* a REPL entry is one line as far as the writer is concerned, so a file
     name and a line number of 1 would be noise -- only a genuinely deeper
     position (a multi-line entry) is worth printing *)
  let line = !Runtime.current_line in
  let where = if !Runtime.current_file = "" && line > 1 then Printf.sprintf " (line %d)" line else "" in
  print_endline ("ERROR: " ^ msg ^ where);
  List.iter
    (fun (name, l) -> print_endline (Printf.sprintf "  in %s, called from line %d" name l))
    (Runtime.frames_snapshot ())

(* real Julia's rule: a trailing `;` means "run it, don't show me the value" *)
let ends_with_semicolon src =
  let s = String.trim src in
  String.length s > 0 && s.[String.length s - 1] = ';'

(* Each entry starts from a clean slate and, however it ends, leaves one: an
   error deliberately does not unwind the position or the frame stack (that is
   what lets them be reported), so the prompt is the place that puts them
   back -- the same job Eval's STry does for a `catch`. *)
let eval_and_show src =
  let entered = Runtime.here () in
  Runtime.current_line := 0;
  let finish () = Runtime.restore_site { entered with Runtime.s_line = 0 } in
  match Eval.eval_toplevel src with
  | Runtime.VNothing -> finish ()
  | v ->
    if not (ends_with_semicolon src) then print_endline (Runtime.show v);
    finish ()
  | exception Ast.Parse_error msg ->
    print_endline ("ERROR: " ^ msg);
    finish ()
  | exception Runtime.JuliaError v ->
    report_error (Runtime.show v);
    finish ()
  | exception Failure msg ->
    report_error msg;
    finish ()

let run () =
  print_string banner;
  let pending = Buffer.create 256 in
  let rec loop () =
    print_string (if Buffer.length pending > 0 then continuation_prompt else prompt);
    flush stdout;
    match read_line_host () with
    | None ->
      (* Ctrl-D. A half-typed block just goes away with it. *)
      print_newline ()
    | Some line ->
      Buffer.add_string pending line;
      Buffer.add_char pending '\n';
      let src = Buffer.contents pending in
      if block_depth src > 0 then loop ()
      else (
        Buffer.clear pending;
        if String.trim src <> "" then eval_and_show src;
        flush stdout;
        loop ())
  in
  loop ()
