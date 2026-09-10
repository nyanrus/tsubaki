(* ============================= Compile ============================= *)
(* An experimental SECOND execution path, alongside the tree-walking
   interpreter, not a replacement for it: a restricted numeric bytecode
   compiler, for functions whose entire body is "pisum-shaped" (integer/
   float arithmetic, comparisons, if/for/while, local variables, one
   result) -- see AST_IN_RUST_EXPERIMENT.md for why hoisting a hot loop
   like this to Rust helps (avoiding per-node interpreter dispatch, not
   FFI-crossing cost) and why a full "compile arbitrary Tsubaki AST to
   native code" mechanism was deliberately NOT what got built instead: a
   small, restricted bytecode VM in Rust is realistic where a real JIT
   inside a wasm host is not.

   `try_compile` walks a function body ONCE, at declaration time, and
   either succeeds (returns real bytecode, cached and used for every
   future call) or raises Not_eligible (falls back to the ordinary
   tree-walking interpreter, unchanged, exactly like Resolve's own
   conservative fallback elsewhere in this file). Deliberately narrow for
   now: only zero-parameter functions (see Eval.SFuncDecl for why), only
   Int/Float/Bool values, only `+ - * / % < <= > >= == !=`, only
   `for var in lo:hi` (step 1), `while`, `if`/`elseif`/`else`, and a
   final return (explicit or the implicit "last expression" form). *)
  open Ast
  open Runtime

  exception Not_eligible

  module Bytecode = struct
    (* a binop's operands, chosen at compile time by what the two AST
       subexpressions actually look like -- this is the "superinstruction"
       optimization: the overwhelmingly common shape in a hot numeric loop
       is "combine a local variable with another local, or with a literal"
       (`k*k`, `i+1`, `x > 0`, a for-loop's own `var <= hi` bound check),
       so THOSE read straight out of the locals array with no stack
       traffic at all, instead of the fully generic Load;Load;Op (or
       Load;Const;Op) sequence -- fewer instructions dispatched, and a
       tight, concrete Rust match arm the compiler can specialize, instead
       of a generic pop-pop-compute-push path. Only reachable when BOTH
       operands are already-simple atoms; anything nested still falls back
       to Generic, unchanged. *)
    (* real Julia's own LLVM IR for pisum() (`@code_llvm`) never spills
       either operand of `1.0 / (k * k)` or `s + (...)` to a stack slot --
       one side is a bare SSA register, the other an immediate embedded
       directly in the `fdiv`/`fadd` instruction. LL/LC_int/LC_float above
       only fire when BOTH sides are already-simple atoms, so an atom
       combined with a NESTED subexpression (exactly this pisum shape: the
       division's left side is the literal 1.0, its right side is the
       nested `k*k`; the addition's left side is the local `s`, its right
       side is the nested division) still fell back to Generic, paying for
       a push AND a pop on the atom side even though its value is already
       known at compile time. LS/CS_int/CS_float below cover that: the
       nested side compiles normally (leaves one value on the stack), and
       the atom is folded directly into the instruction -- one stack pop
       instead of two. Only the "atom on the left" direction is covered
       (matching LC_int/LC_float's own existing "var on the left" limit
       above) since that's the shape `try_compile` actually produces below;
       "nested op atom" still falls back to Generic, unchanged. *)
    type shape =
      | Generic (* stack-based: both operands already pushed by the caller *)
      | LL of int * int (* slot_a, slot_b -- both a bare local variable *)
      | LC_int of int * int (* slot, literal int -- var on the left, int literal on the right *)
      | LC_float of int * float (* slot, literal float *)
      | LS of int (* slot -- local on the left, a nested expr's stack result on the right *)
      | CS_int of int (* literal int on the left, a nested expr's stack result on the right *)
      | CS_float of float (* literal float on the left, a nested expr's stack result on the right *)

    type instr =
      | Const_int of int
      | Const_float of float
      | Load of int
      | Store of int
      | Bin of string (* one of + - * / % < <= > >= == != *) * shape
      | Jump of int
      | Jump_if_false of int
      | Jump_if_true of int (* see compile_for: the loop-rotation transform's single backward branch *)
      | Pop
      | Return
  end

  open Bytecode

  let bin_ops = [ "+"; "-"; "*"; "/"; "%"; "<"; "<="; ">"; ">="; "=="; "!=" ]

  (* this op's position in bin_ops -- used to compute a unique wire-format
     opcode tag per (shape family, op) combination, see encode below *)
  let op_index op =
    let rec go i = function
      | [] -> raise Not_eligible
      | o :: _ when o = op -> i
      | _ :: rest -> go (i + 1) rest
    in
    go 0 bin_ops

  (* a growable instruction buffer with position-based patching -- jump
     targets aren't known until the code AFTER them is compiled, so a
     jump is first emitted as a placeholder and the position it was
     written at is remembered for patching once the real target is known *)
  type buf = { mutable instrs : instr array; mutable len : int }

  let mk_buf () = { instrs = Array.make 16 Pop; len = 0 }

  let emit b i =
    if b.len >= Array.length b.instrs then (
      let bigger = Array.make (Array.length b.instrs * 2) Pop in
      Array.blit b.instrs 0 bigger 0 b.len;
      b.instrs <- bigger);
    b.instrs.(b.len) <- i;
    b.len <- b.len + 1;
    b.len - 1

  let patch b pos i = b.instrs.(pos) <- i

  (* Removes the parser's source-position markers (Ast's SLine) from a body,
     at every nesting level, before any of the compilers in this file look at
     it. Everything here decides ELIGIBILITY by matching exact statement
     shapes -- `[ SExpr (EAssign ...) ]`, a body of exactly one statement, and
     so on -- and a marker sitting between those would not fail loudly, it
     would silently stop the body from compiling and quietly hand back the
     tree-walking interpreter instead. Stripping once, at each entry point,
     means every shape-match below sees exactly the list it saw before line
     numbers existed. *)
  let rec strip_lines (body : stmt list) : stmt list =
    List.filter_map
      (function
        | SLine _ -> None
        | SIf (branches, else_body) ->
          Some (SIf (List.map (fun (c, b) -> c, strip_lines b) branches, Option.map strip_lines else_body))
        | SFor (t, e, b) -> Some (SFor (t, e, strip_lines b))
        | SWhile (c, b) -> Some (SWhile (c, strip_lines b))
        | STry (b, name, handler) -> Some (STry (strip_lines b, name, strip_lines handler))
        | SFuncDecl (n, p, kw, b, cache) -> Some (SFuncDecl (n, p, kw, strip_lines b, cache))
        | SModuleDecl (n, b) -> Some (SModuleDecl (n, strip_lines b))
        | SMacroDecl (n, p, b) -> Some (SMacroDecl (n, p, strip_lines b))
        | SMacroCall (n, s) -> Some (SMacroCall (n, List.hd (strip_lines [ s ])))
        | ( SExpr _ | SReturn _ | SBreak | SContinue | SDestructure _ | SLocalTypedAssign _
          | SStructDecl _ | SAbstractDecl _ | SUsing _ | SImport _ | SExport _ ) as s -> Some s)
      body

  (* compiles a function body that takes no parameters (see the module
     comment) into bytecode; None if anything in the body falls outside
     the restricted subset above -- never raises to the caller *)
  let try_compile (body : stmt list) : (instr array * int) option =
    let body = strip_lines body in
    let buf = mk_buf () in
    let slots : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let next_slot = ref 0 in
    let slot_for name =
      match Hashtbl.find_opt slots name with
      | Some s -> s
      | None ->
        let s = !next_slot in
        incr next_slot;
        Hashtbl.replace slots name s;
        s
    in
    (* a REFERENCE (read) to a name only ever compiles if that name is
       already a known local -- i.e. this function itself already assigned
       it (via `slot_for` at a Store) or bound it (a `for` loop variable)
       earlier in this same walk. Zero-parameter functions have no other
       source of locals, so a name reaching here that ISN'T already known
       is necessarily a free reference to an outer/global variable, which
       this restricted compiler has no way to read OR write correctly (see
       `run_bytecode`'s own `locals` array, kernel/src/lib.rs: it's a
       flat, zero-initialized-every-call scratch space with no connection
       to the tree-walking interpreter's real environment at all). Bails
       to `Not_eligible` (the ordinary, safe tree-walking interpreter)
       instead of `slot_for`'s previous behavior of silently allocating a
       FRESH, zero-initialized slot for it -- that silently treated any
       outer-variable reference as a same-named but entirely disconnected
       local, giving wrong answers without so much as a crash (confirmed
       directly: a `bump()` with zero params that read-modify-wrote what
       looked like an outer `counter` returned 1 on every call, and never
       actually changed the real outer `counter` at all). *)
    let slot_for_read name =
      match Hashtbl.find_opt slots name with
      | Some s -> s
      | None -> raise Not_eligible
    in
    let fresh_temp_slot () =
      let s = !next_slot in
      incr next_slot;
      s
    in
    let rec compile_expr (e : expr) : unit =
      match e with
      | EInt n -> ignore (emit buf (Const_int n))
      | EFloat f -> ignore (emit buf (Const_float f))
      | EVar (name, _) -> ignore (emit buf (Load (slot_for_read name)))
      | EBinOp (op, a, b, _) ->
        if not (List.mem op bin_ops) then
          raise Not_eligible
          (* NOT eligible: "&&"/"||" (real Julia short-circuits -- this
             would need genuine lazy control flow, not a plain binop),
             ":" (ranges are only supported as a for-loop's own iterator,
             see compile_stmt's SFor case, not as a value), string/struct/
             array ops (nothing here represents those at all) *);
        (match a, b with
        | EVar (na, _), EVar (nb, _) ->
          ignore (emit buf (Bin (op, LL (slot_for_read na, slot_for_read nb))))
        | EVar (na, _), EInt n -> ignore (emit buf (Bin (op, LC_int (slot_for_read na, n))))
        | EVar (na, _), EFloat f -> ignore (emit buf (Bin (op, LC_float (slot_for_read na, f))))
        | EVar (na, _), _ ->
          (* left is a bare local, right is nested (e.g. `s + (1.0/(k*k))`)
             -- compile the nested side, then fold the local straight into
             the op instead of paying for an extra Load's push/pop *)
          compile_expr b;
          ignore (emit buf (Bin (op, LS (slot_for_read na))))
        | EInt n, _ ->
          compile_expr b;
          ignore (emit buf (Bin (op, CS_int n)))
        | EFloat f, _ ->
          (* this is pisum's own `1.0 / (k * k)`: left is the literal 1.0,
             right is the nested `k*k` -- see the shape comment above *)
          compile_expr b;
          ignore (emit buf (Bin (op, CS_float f)))
        | _ ->
          (* either side is itself a nested computation with no atom to
             fold in -- no fused shape applies, fall back to the fully
             generic stack-based form *)
          compile_expr a;
          compile_expr b;
          ignore (emit buf (Bin (op, Generic))))
      | _ -> raise Not_eligible
    and compile_stmt (s : stmt) : unit =
      match s with
      | SExpr (EAssign (name, rhs, _)) ->
        compile_expr rhs;
        ignore (emit buf (Store (slot_for name)))
      | SExpr _ -> raise Not_eligible
      | SReturn (Some e) ->
        compile_expr e;
        ignore (emit buf Return)
      | SReturn None -> raise Not_eligible
      | SIf (branches, else_body) -> compile_if branches else_body
      | SFor (FVSingle var, EBinOp (":", lo, hi, _), body) -> compile_for var lo hi body
      | SFor _ -> raise Not_eligible (* a step range, a tuple-destructure target, or a non-range iterable *)
      | SWhile (cond, body) -> compile_while cond body
      | _ -> raise Not_eligible
    and compile_if branches else_body =
      let end_jumps = ref [] in
      let rec go = function
        | [] -> (
          match else_body with
          | Some b -> List.iter compile_stmt b
          | None -> ())
        | (cond, body) :: rest ->
          compile_expr cond;
          let jf_pos = emit buf (Jump_if_false 0) in
          List.iter compile_stmt body;
          let j_pos = emit buf (Jump 0) in
          end_jumps := j_pos :: !end_jumps;
          patch buf jf_pos (Jump_if_false buf.len);
          go rest
      in
      go branches;
      List.iter (fun p -> patch buf p (Jump buf.len)) !end_jumps
    and compile_for var lo hi body =
      let var_slot = slot_for var in
      let hi_slot = fresh_temp_slot () in
      compile_expr lo;
      ignore (emit buf (Store var_slot));
      (* the upper bound is evaluated ONCE, at loop entry -- matches real
         Julia (and Tsubaki's own tree-walking SFor), not re-evaluated
         every iteration *)
      compile_expr hi;
      ignore (emit buf (Store hi_slot));
      (* loop rotation: real Julia's own LLVM IR for this exact loop
         (`@code_llvm pisum`) never emits a conditional forward-exit branch
         AND an unconditional backward branch per iteration -- one entry
         guard runs once before the loop, then each iteration ends with a
         single conditional branch back to the top (`icmp eq ...; br i1
         ..., label %exit, label %body`), not two branches. Mirrored here:
         the guard below only runs once (skips the whole loop for an empty
         range, matching real Julia), and the loop body's own trailing
         check is one Jump_if_true straight back to loop_start -- no
         separate unconditional Jump instruction dispatched per iteration
         at all. *)
      ignore (emit buf (Bin ("<=", LL (var_slot, hi_slot))));
      let guard_pos = emit buf (Jump_if_false 0) in
      let loop_start = buf.len in
      List.iter compile_stmt body;
      ignore (emit buf (Bin ("+", LC_int (var_slot, 1))));
      ignore (emit buf (Store var_slot));
      ignore (emit buf (Bin ("<=", LL (var_slot, hi_slot))));
      ignore (emit buf (Jump_if_true loop_start));
      patch buf guard_pos (Jump_if_false buf.len)
    and compile_while cond body =
      (* same loop-rotation transform as compile_for above -- cond is a
         pure expression in this restricted subset (no side effects reach
         here, or try_compile would already have bailed), so compiling it
         twice (once as the entry guard, once at the loop's own tail) is
         safe and gets the same "one branch per iteration" shape *)
      compile_expr cond;
      let guard_pos = emit buf (Jump_if_false 0) in
      let loop_start = buf.len in
      List.iter compile_stmt body;
      compile_expr cond;
      ignore (emit buf (Jump_if_true loop_start));
      patch buf guard_pos (Jump_if_false buf.len)
    in
    try
      (match List.rev body with
      | [] -> raise Not_eligible
      | last :: rest_rev ->
        List.iter compile_stmt (List.rev rest_rev);
        (match last with
        | SReturn (Some e) ->
          compile_expr e;
          ignore (emit buf Return)
        | SExpr (EAssign _) -> raise Not_eligible (* nothing meaningful to implicitly return *)
        | SExpr e ->
          compile_expr e;
          ignore (emit buf Return)
        | _ -> raise Not_eligible (* body ends in if/for/while/... with no explicit return -- bail *)));
      Some (Array.sub buf.instrs 0 buf.len, !next_slot)
    with Not_eligible -> None

  (* flat f64 encoding for the FFI boundary: 3 words per instruction,
     [opcode_tag; operand1; operand2]. Every operand (slot index, jump
     target, literal int, even Const_float's/LC_float's payload) fits
     exactly in an f64 for any value this compiler would ever actually
     produce -- no bit-casting needed, unlike a byte-for-byte encoding
     would require. A fused Bin's (family, op) pair gets its OWN opcode
     tag number (rather than a shared "Bin" tag plus an op sub-tag) so
     every instruction still fits in exactly 3 words: tags 4-14 are the
     11 ops Generic, 19-29 the same 11 ops LL-fused, 30-40 LC_int-fused,
     41-51 LC_float-fused, 53-63 LS-fused, 64-74 CS_int-fused, 75-85
     CS_float-fused -- kept in sync by hand with kernel/src/lib.rs's
     run_bytecode, which must decode the exact same numbering. *)
  let encode (code : instr array) : float array =
    let out = Array.make (Array.length code * 3) 0.0 in
    Array.iteri
      (fun i instr ->
        let tag, op1, op2 =
          match instr with
          | Const_int n -> 0.0, float_of_int n, 0.0
          | Const_float f -> 1.0, f, 0.0
          | Load s -> 2.0, float_of_int s, 0.0
          | Store s -> 3.0, float_of_int s, 0.0
          | Bin (op, Generic) -> 4.0 +. float_of_int (op_index op), 0.0, 0.0
          | Bin (op, LL (a, b)) -> 19.0 +. float_of_int (op_index op), float_of_int a, float_of_int b
          | Bin (op, LC_int (s, n)) -> 30.0 +. float_of_int (op_index op), float_of_int s, float_of_int n
          | Bin (op, LC_float (s, f)) -> 41.0 +. float_of_int (op_index op), float_of_int s, f
          | Jump t -> 15.0, float_of_int t, 0.0
          | Jump_if_false t -> 16.0, float_of_int t, 0.0
          | Jump_if_true t -> 52.0, float_of_int t, 0.0
          | Pop -> 17.0, 0.0, 0.0
          | Return -> 18.0, 0.0, 0.0
          | Bin (op, LS s) -> 53.0 +. float_of_int (op_index op), float_of_int s, 0.0
          | Bin (op, CS_int n) -> 64.0 +. float_of_int (op_index op), float_of_int n, 0.0
          | Bin (op, CS_float f) -> 75.0 +. float_of_int (op_index op), f, 0.0
        in
        out.((i * 3) + 0) <- tag;
        out.((i * 3) + 1) <- op1;
        out.((i * 3) + 2) <- op2)
      code;
    out

  (* ========================= WGSL compute-kernel path ========================= *)
  (* A THIRD compiler in this file, sharing try_compile's exact restricted
     numeric-expression subset (arithmetic/comparison, if/for/while, no
     closures/strings/structs/dynamic dispatch) but targeting real WGSL
     SOURCE TEXT instead of the Bytecode/run_bytecode pair above -- for a
     quoted Tsubaki block meant to run as an actual GPU compute kernel via
     tsubaki-gpu (gpu/src/lib.rs's create_pipeline/dispatch), not the
     numeric-bytecode VM. See tsubaki-lang's own WGPUCompute.jl research
     note for the real-Julia precedent this mirrors (a `@wgpukernel`-style
     Julia-to-WGSL path already exists there via WGSLTypes).

     Unlike try_compile (which only ever sees Int/Float/Bool LOCALS and
     has no notion of an outer/free variable at all -- see its own
     slot_for_read comment), a real compute kernel's whole POINT is to
     read/write buffers bound OUTSIDE the function -- WGSL entry points
     have no "arguments" at all, only free-standing @binding globals. So
     `buffers` (caller-supplied: name -> WGSL binding kind,
     "storage-read" / "storage-read-write" / "uniform", in INSERTION
     ORDER = binding index -- the exact same vocabulary and positional
     convention gpu/src/lib.rs's BindingKind already uses, so the emitted
     text's bindings line up with create_pipeline's own bindingKinds list
     with zero translation) is the one deliberate exception to
     try_compile's "no free variables" rule: `EIndex(EVar b, i)` for a
     name IN buffers compiles to a real WGSL global reference instead of
     raising Not_eligible. A second, single magic free name, "gid", is
     always available inside a kernel -- the invocation's own element
     index (`@builtin(global_invocation_id)`); real Julia has nothing
     built in shaped like it, so there's no natural non-magic spelling.

     Every buffer is f32 (see tsubaki-gpu's own disclosed f32-only note --
     `create_buffer`/`write_buffer`/`read_buffer` are all Float32Array-
     shaped, no per-buffer element type exists to plumb through here
     either), so a buffer READ always infers Float; a buffer WRITE
     requires a Float-typed right-hand side, checked the same way an
     ordinary local reassignment's type is.

     Real, disclosed type gap (not chased): try_compile's own Bytecode VM
     treats every value uniformly as f64 (the Rust wire format is a flat
     float array, see encode's own comment above) -- WGSL's i32/f32 are
     genuinely DIFFERENT types with different semantics (integer division
     truncates, float doesn't; mixing them needs an explicit cast). This
     compiler does simple, first-assignment-wins type inference per local
     (an Int-shaped source -- gid, int literals, other Int locals,
     combined only with each other -- infers i32; a Float-shaped source
     -- a buffer read, float literals, other Float locals -- infers f32)
     and bails to Not_eligible the moment an EBinOp would need an
     IMPLICIT cross-type combination, since this compiler never emits an
     `f32()`/`i32()` cast -- refusing beats silently emitting invalid
     WGSL or a wrong answer. For the same reason, a COMPARISON's result
     (`<`/`<=`/...) is only ever accepted directly in an `if`/`while`
     condition position (compile_cond, below) -- never stored into a
     local -- so this compiler never needs a third, `bool`-typed local at
     all; try_compile's tree-walked bytecode twin has no such split
     (everything is a uniform f64 register there), so this restriction is
     specific to the WGSL path, not inherited from it.

     `SReturn (Some e)` is refused (Not_eligible), unlike try_compile: a
     WGSL @compute entry point returns nothing at all, so there's no
     "implicit last expression becomes the result" convention to mirror
     here -- only a bare `SReturn None` (an early `return;`) makes sense.
     Workgroup size is a fixed 64 (a common, reasonable default) and the
     entry point is always named "main" -- both a disclosed v1 cut, not
     independently configurable yet. *)

  (* Shared between Wgsl and Glsl below: a Tsubaki struct is "vecN-eligible"
     when it's flat (no nesting -- `Runtime.float_shaped ~max_depth:0`,
     see that function's own doc comment), has 2-4 fields, and the field
     NAMES are exactly `x`/`y`[/`z`[/`w`]] in that order -- the same
     names WGSL's/GLSL's own swizzle syntax uses, so `.x`/`.y`/`.z`/`.w`
     compiles to a real swizzle with zero name remapping needed anywhere.
     The "immutable/non-parametric/all-`::Float`-fields" part is shared
     with `Runtime.soa_eligible` (the ECS SoA-storage check) via
     `float_shaped` -- this only layers its OWN, stricter field-count and
     -naming requirements on top (soa_eligible allows nesting and any
     field names/count; a raw vecN allows neither). *)
  let vec_field_names = [| "x"; "y"; "z"; "w" |]

  let vec_arity (kind : string) : int option =
    match Hashtbl.find_opt struct_defs kind with
    | Some sd
      when float_shaped ~max_depth:0 kind
           && List.length sd.field_names >= 2
           && List.length sd.field_names <= 4
           && sd.field_names = Array.to_list (Array.sub vec_field_names 0 (List.length sd.field_names)) ->
      Some (List.length sd.field_names)
    | _ -> None

  (* A Tsubaki matrix LITERAL (`[a b c d; ...]`, exactly 4 rows of 4
     Float-shaped elements) is the one recognized mat4x4 shape -- NOT a
     `Matrix` runtime value read from a local, since this compiler works
     on static AST shape only and a `Matrix`'s real dimensions are a
     runtime fact it has no way to verify ahead of time. `EMatrixLit`
     already carries `expr list list` (rows), exactly what's needed here. *)
  let is_mat4_lit (rows : expr list list) : bool = List.length rows = 4 && List.for_all (fun r -> List.length r = 4) rows

  module Wgsl = struct
    type ty = TInt | TFloat | TVec of int | TMat4

    let wgsl_ty = function TInt -> "i32" | TFloat -> "f32" | TVec n -> Printf.sprintf "vec%d<f32>" n | TMat4 -> "mat4x4<f32>"

    (* WGSL float literals must always look like a float ("1.0", not "1")
       -- OCaml's %g/string_of_float can produce a bare integer-looking
       string for a whole number, invalid as a WGSL f32 literal. 9
       significant digits (not 17 -- that's the f64 round-trip bound) is
       the well-known sufficient bound to round-trip an IEEE-754 f32
       exactly, which is all either WGSL or GLSL ever actually store this
       as -- 17 digits just prints float64 representation noise a human
       never wrote (`0.6` -> `0.59999999999999998`). *)
    let float_literal f =
      let s = Printf.sprintf "%.9g" f in
      if String.contains s '.' || String.contains s 'e' || String.contains s 'n' (* nan/inf *) then s else s ^ ".0"

    let indent n = String.make (n * 2) ' '

    (* `raw` is a Dict value from the caller: either a bare BindingKind
       ("storage-read"/"storage-read-write"/"uniform" -- unchanged,
       scalar f32, exactly to_wgsl's original shape) or
       "<kind>:<ElementType>" where ElementType is either the name of an
       already-declared vecN-eligible Tsubaki struct (see vec_arity above
       this module) or the literal "mat4". Parsed once per buffer, up
       front -- both the body walk (buffer reads/writes need to know
       their element type) and the final declaration/guard emission share
       this one parse. *)
    let parse_binding (raw : string) : string * ty =
      match String.split_on_char ':' raw with
      | [ base ] -> base, TFloat
      | [ base; "mat4" ] -> base, TMat4
      | [ base; type_name ] -> (
        match vec_arity type_name with
        | Some n -> base, TVec n
        | None ->
          failwith
            (Printf.sprintf
               "to_wgsl: unknown element type %S in binding kind %S -- expected the name of an already-declared 2-4-field Float struct (e.g. \"Vec2\") or \"mat4\""
               type_name raw))
      | _ -> failwith (Printf.sprintf "to_wgsl: malformed binding kind %S -- expected \"<kind>\" or \"<kind>:<ElementType>\"" raw)

    let try_compile (body : stmt list) (buffers : (string * string) list) : string option =
      let body = strip_lines body in
      let buffer_info : (string, string * ty) Hashtbl.t = Hashtbl.create 4 in
      List.iter (fun (n, raw) -> Hashtbl.replace buffer_info n (parse_binding raw)) buffers;
      let locals : (string, ty) Hashtbl.t = Hashtbl.create 8 in
      (* names owned by a `for`'s OWN header (`for (var i: i32 = ...)`),
         excluded from the top-level pre-declaration pass below -- see
         try_compile's own two-pass comment for why *)
      let for_loop_vars : (string, unit) Hashtbl.t = Hashtbl.create 4 in
      let local_ty_opt name = Hashtbl.find_opt locals name in
      (* a plain (non-buffer, non-"gid") name must already be a known,
         already-typed local from an earlier assignment in this same
         walk -- same conservative policy as try_compile's own
         slot_for_read, and for the same reason: no other source of
         locals exists inside a zero-argument kernel body *)
      let rec compile_expr (e : expr) : string * ty =
        match e with
        | EInt n -> string_of_int n, TInt
        | EFloat f -> float_literal f, TFloat
        (* unary minus: parser.ml's parse_unary desugars EVERY `-e` (a
           negative literal included -- `-0.6` is `EBinOp("-", EInt 0,
           EFloat 0.6, _)`, not its own literal shape) to this exact form,
           never a dedicated AST node. Special-cased BEFORE the generic
           EBinOp case below: falling through there would compile it as
           an ordinary binary `-` and reject it the instant `e` isn't
           already an Int (mixing EInt 0 with a Float operand trips the
           same-type check) -- which would make literally every negative
           float literal ineligible, not a real cross-type situation at
           all. Keeps `e`'s own type, matching real negation's meaning. *)
        | EBinOp ("-", EInt 0, e, _) ->
          let text, ty = compile_expr e in
          Printf.sprintf "(-%s)" text, ty
        | EVar ("gid", _) -> "gid", TInt
        (* a "uniform"-kind binding is a single value, readable bare
           (unlike storage-read/storage-read-write, which are always
           arrays and only ever readable through EIndex, below) *)
        | EVar (name, _) when Hashtbl.mem buffer_info name -> (
          match Hashtbl.find buffer_info name with
          | "uniform", ty -> name, ty
          | _ -> raise Not_eligible (* a whole storage buffer isn't a scalar value -- must be indexed *))
        | EVar (name, _) -> (
          match local_ty_opt name with
          | Some ty -> name, ty
          | None -> raise Not_eligible)
        | EIndex (EVar (name, _), idx) when Hashtbl.mem buffer_info name ->
          let idx_text, idx_ty = compile_expr idx in
          if idx_ty <> TInt then raise Not_eligible;
          let _, elem_ty = Hashtbl.find buffer_info name in
          Printf.sprintf "%s[%s]" name idx_text, elem_ty
        (* vecN construction: `Vec2(a, b)` / `Vec3(a, b, c)` / `Vec4(a,
           b, c, d)` -- kind must be vecN-eligible (see vec_arity) and
           supply exactly N Float-typed positional args. *)
        | ECall (kind, args, [], _) when vec_arity kind <> None ->
          let n = Option.get (vec_arity kind) in
          if List.length args <> n then raise Not_eligible;
          let compiled = List.map compile_expr args in
          if not (List.for_all (fun (_, t) -> t = TFloat) compiled) then raise Not_eligible;
          Printf.sprintf "vec%d<f32>(%s)" n (String.concat ", " (List.map fst compiled)), TVec n
        (* swizzle: `.x`/`.y`/`.z`/`.w` on a vecN value, N large enough
           to actually have that component *)
        | EField (obj, field) -> (
          let obj_text, obj_ty = compile_expr obj in
          match obj_ty with
          | TVec n when Array.exists (( = ) field) (Array.sub vec_field_names 0 n) -> Printf.sprintf "%s.%s" obj_text field, TFloat
          | _ -> raise Not_eligible)
        (* a 4x4 matrix LITERAL (see is_mat4_lit above this module) --
           Tsubaki's `EMatrixLit` rows are ROW-major (`rows.(i).(j)` is row
           i, column j, matching how a human reads `[a b; c d]`), but
           WGSL's OWN 16-scalar `mat4x4<f32>(...)` constructor fills
           COLUMN-major -- transposed here (iterate columns outer, rows
           inner) so the emitted matrix means the SAME thing positionally
           as what was written, not its transpose. Verified against a
           real translation-matrix * point multiplication, not assumed
           correct from the spec alone -- see examples/glsl_triangle.jl's
           matrix test. *)
        | EMatrixLit rows when is_mat4_lit rows ->
          let row_arr = Array.of_list (List.map Array.of_list rows) in
          let cols = ref [] in
          for col = 3 downto 0 do
            for row = 3 downto 0 do
              cols := row_arr.(row).(col) :: !cols
            done
          done;
          let compiled = List.map compile_expr !cols in
          if not (List.for_all (fun (_, t) -> t = TFloat) compiled) then raise Not_eligible;
          Printf.sprintf "mat4x4<f32>(%s)" (String.concat ", " (List.map fst compiled)), TMat4
        | EBinOp (op, a, b, _) ->
          if not (List.mem op bin_ops) then raise Not_eligible;
          if List.mem op [ "<"; "<="; ">"; ">="; "=="; "!=" ] then
            raise Not_eligible (* a comparison's result may not be stored/combined further -- only compile_cond accepts these ops *);
          let a_text, a_ty = compile_expr a in
          let b_text, b_ty = compile_expr b in
          let result_ty =
            match op, a_ty, b_ty with
            | _, t1, t2 when t1 = t2 -> t1 (* same-type: componentwise +/-/*// for vec, +/- for mat4, matches WGSL's own operators *)
            | ("*" | "/"), TVec n, TFloat -> TVec n (* vector scaled by a scalar *)
            | "*", TFloat, TVec n -> TVec n (* scalar * vector *)
            | "*", TMat4, TVec 4 -> TVec 4 (* matrix * column vector -- a real transform application *)
            | "*", TMat4, TMat4 -> TMat4 (* composing two transforms *)
            | _ -> raise Not_eligible (* the disclosed cross-type gap -- see module comment *)
          in
          Printf.sprintf "(%s %s %s)" a_text op b_text, result_ty
        | _ -> raise Not_eligible
      in
      (* comparisons ONLY -- the sole place this compiler ever produces a
         WGSL `bool` value, consumed immediately by an if/while and never
         stored (see module comment) *)
      let compile_cond (e : expr) : string =
        match e with
        | EBinOp (op, a, b, _) when List.mem op [ "<"; "<="; ">"; ">="; "=="; "!=" ] ->
          let a_text, a_ty = compile_expr a in
          let b_text, b_ty = compile_expr b in
          (* WGSL's `==`/`!=` on a vecN/mat4 returns a component-wise
             vecN<bool>, not a scalar bool -- not valid directly inside
             an if/while condition (which needs a real bool), so
             comparisons here stay scalar-only, same restriction
             try_compile's own numeric ISA never had to think about. *)
          (match a_ty, b_ty with
          | (TInt | TFloat), (TInt | TFloat) -> ()
          | _ -> raise Not_eligible);
          if a_ty <> b_ty then raise Not_eligible;
          Printf.sprintf "(%s %s %s)" a_text op b_text
        | _ -> raise Not_eligible (* no bare-bool locals/&&/|| in this restricted subset -- see module comment *)
      in
      let buf = Buffer.create 256 in
      let emit_line depth s =
        Buffer.add_string buf (indent depth);
        Buffer.add_string buf s;
        Buffer.add_char buf '\n'
      in
      let rec compile_stmt depth (s : stmt) : unit =
        match s with
        | SExpr (EAssign (name, rhs, _)) ->
          let text, ty = compile_expr rhs in
          (match local_ty_opt name with
          | Some prev_ty ->
            if prev_ty <> ty then raise Not_eligible (* reassigned with a different inferred type -- ambiguous, bail *);
            emit_line depth (Printf.sprintf "%s = %s;" name text)
          | None ->
            Hashtbl.replace locals name ty;
            emit_line depth (Printf.sprintf "var %s: %s = %s;" name (wgsl_ty ty) text))
        | SExpr (EIndexAssign (EVar (name, _), idx, rhs)) when Hashtbl.mem buffer_info name ->
          let base_kind, elem_ty = Hashtbl.find buffer_info name in
          if base_kind <> "storage-read-write" then raise Not_eligible (* writing to a non-writable binding *);
          let idx_text, idx_ty = compile_expr idx in
          if idx_ty <> TInt then raise Not_eligible;
          let rhs_text, rhs_ty = compile_expr rhs in
          if rhs_ty <> elem_ty then raise Not_eligible (* must match the buffer's own declared element type *);
          emit_line depth (Printf.sprintf "%s[%s] = %s;" name idx_text rhs_text)
        | SExpr _ -> raise Not_eligible
        | SReturn None -> emit_line depth "return;"
        | SReturn (Some _) -> raise Not_eligible (* a compute entry returns nothing -- see module comment *)
        | SIf (branches, else_body) -> compile_if depth branches else_body
        | SFor (FVSingle var, EBinOp (":", lo, hi, _), body) -> compile_for depth var lo hi body
        | SFor _ -> raise Not_eligible
        | SWhile (cond, body) ->
          emit_line depth (Printf.sprintf "while (%s) {" (compile_cond cond));
          List.iter (compile_stmt (depth + 1)) body;
          emit_line depth "}"
        | _ -> raise Not_eligible
      and compile_if depth branches else_body =
        let rec go first = function
          | [] -> (
            match else_body with
            | Some b ->
              emit_line depth "else {";
              List.iter (compile_stmt (depth + 1)) b;
              emit_line depth "}"
            | None -> ())
          | (cond, body) :: rest ->
            emit_line depth (Printf.sprintf "%s (%s) {" (if first then "if" else "else if") (compile_cond cond));
            List.iter (compile_stmt (depth + 1)) body;
            emit_line depth "}";
            go false rest
        in
        go true branches
      and compile_for depth var lo hi body =
        let lo_text, lo_ty = compile_expr lo in
        let hi_text, hi_ty = compile_expr hi in
        if lo_ty <> TInt || hi_ty <> TInt then raise Not_eligible (* a loop bound must be an index, not a float *);
        (match local_ty_opt var with
        | Some TInt -> () (* re-entering the same loop variable is fine *)
        | Some (TFloat | TVec _ | TMat4) -> raise Not_eligible
        | None -> Hashtbl.replace locals var TInt);
        Hashtbl.replace for_loop_vars var ();
        emit_line depth
          (Printf.sprintf "for (var %s: i32 = %s; %s <= %s; %s = %s + 1) {" var lo_text var hi_text var var);
        List.iter (compile_stmt (depth + 1)) body;
        emit_line depth "}"
      in
      try
        (* TWO passes, not one: WGSL blocks (if/else/for/while) are real
           lexical scopes, same as C -- a `var` first assigned INSIDE a
           branch is only visible in that branch, so declaring it there
           (the naive "declare on first sight, wherever that happens to
           be" approach this compiler used before vec/mat support) breaks
           the instant a local's FIRST assignment is inside a conditional
           and a LATER branch or the code after the if also uses it (a
           real bug, caught by actually compiling
           examples/glsl_triangle.jl's Vec2 position -- first assigned
           inside an `if`, needed in the `else` branches and after).
           Pass 1 runs the exact same walk into a throwaway buffer purely
           to populate `locals` (first-assignment-wins type inference,
           unchanged); pass 2 re-runs the SAME walk for real, but by then
           every name is already `Some _` in `locals`, so `compile_stmt`'s
           existing "already known -> plain reassignment, no declare"
           branch fires for EVERY assignment, everywhere -- zero new
           logic needed there. In between, every name pass 1 discovered
           that ISN'T a for-loop's own induction variable (already scoped
           correctly by its own header) gets ONE flat top-level
           declaration, before any control flow, so every branch that
           reads or writes it later can. Known, disclosed gap this
           doesn't handle: a for-loop's OWN variable read after its loop
           ends (real WGSL/GLSL would refuse that -- out of scope -- but
           this compiler doesn't specifically check for it, since no
           test program here does that). *)
        let pre_existing = Hashtbl.copy locals in
        List.iter (compile_stmt 1) body;
        Buffer.clear buf;
        let predecl = Buffer.create 128 in
        Hashtbl.iter
          (fun name ty ->
            if (not (Hashtbl.mem pre_existing name)) && not (Hashtbl.mem for_loop_vars name) then
              Buffer.add_string predecl (Printf.sprintf "  var %s: %s;\n" name (wgsl_ty ty)))
          locals;
        List.iter (compile_stmt 1) body;
        let body_text = Buffer.contents predecl ^ Buffer.contents buf in
        let prelude = Buffer.create 256 in
        List.iteri
          (fun i (name, raw) ->
            let base_kind, elem_ty = Hashtbl.find buffer_info name in
            (* WGSL's own array-stride rule bites specifically at vec3:
               `array<vec3<f32>>`'s stride is rounded up to 16 bytes (vec3
               is 12 bytes, but ALIGNS to 16), not 12 -- a caller filling
               a plain tightly-packed Float32Array via write_buffer would
               silently misalign every element past the first. vec2 (8-
               byte stride, no rounding) and vec4 (16, already exact) have
               no such gap; refused here as a real, disclosed limitation
               rather than emitting a buffer layout write_buffer's own
               natural JS-side data can't actually match. A single
               (non-array) vec3 UNIFORM has no such issue -- there's no
               array to stride at all -- so only storage kinds are
               refused. mat4 buffers are refused too: a real limitation,
               not yet built (array-of-matrix has its own, unexplored
               layout questions), only a mat4 UNIFORM is supported. *)
            (match base_kind, elem_ty with
            | ("storage-read" | "storage-read-write"), TVec 3 ->
              failwith
                (Printf.sprintf
                   "to_wgsl: buffer %S can't hold vec3 elements -- WGSL's array<vec3<f32>> pads every element to a 16-byte stride (vec3 is 12 bytes), which a plain tightly-packed write_buffer call can't match; use a vec4 buffer (waste one component) or a vec2 buffer instead"
                   name)
            | ("storage-read" | "storage-read-write"), TMat4 ->
              failwith (Printf.sprintf "to_wgsl: buffer %S can't hold mat4 elements -- only a mat4 UNIFORM (a single value, not an array) is supported" name)
            | _ -> ());
            let decl =
              match base_kind with
              | "storage-read" -> Printf.sprintf "var<storage, read> %s: array<%s>;" name (wgsl_ty elem_ty)
              | "storage-read-write" -> Printf.sprintf "var<storage, read_write> %s: array<%s>;" name (wgsl_ty elem_ty)
              | "uniform" -> Printf.sprintf "var<uniform> %s: %s;" name (wgsl_ty elem_ty)
              | other ->
                failwith
                  (Printf.sprintf "to_wgsl: unknown binding kind %S (from %S) -- expected \"storage-read\", \"storage-read-write\", or \"uniform\"" other raw)
            in
            Buffer.add_string prelude (Printf.sprintf "@group(0) @binding(%d) %s\n" i decl))
          buffers;
        (* bounds-guard against over-dispatching past a buffer's real
           length -- tsubaki-gpu's own dispatch(wgX,...) launches wgX*64
           invocations along X (workgroup_size 64, see module comment),
           which the caller is free to round up past any one buffer's
           actual element count. Guards against whichever buffer this
           kernel actually WRITES (the one whose length matters); falls
           back to the first buffer if none are writable. Uniforms are
           never a guard candidate -- they're not arrays, arrayLength
           doesn't apply. *)
        let array_buffers = List.filter (fun (n, _) -> fst (Hashtbl.find buffer_info n) <> "uniform") buffers in
        let guard_buffer =
          match List.find_opt (fun (n, _) -> fst (Hashtbl.find buffer_info n) = "storage-read-write") array_buffers with
          | Some (n, _) -> Some n
          | None -> (
            match array_buffers with
            | (n, _) :: _ -> Some n
            | [] -> None)
        in
        let guard =
          match guard_buffer with
          | Some n -> Printf.sprintf "  if (gid >= i32(arrayLength(&%s))) { return; }\n" n
          | None -> ""
        in
        Some
          (Printf.sprintf
             "%s\n@compute @workgroup_size(64)\nfn main(@builtin(global_invocation_id) global_id: vec3<u32>) {\n  let gid: i32 = i32(global_id.x);\n%s%s}\n"
             (Buffer.contents prelude) guard body_text)
      with Not_eligible -> None
  end

  (* ========================= GLSL render-kernel path ========================= *)
  (* A FOURTH compiler, structurally a near-twin of Wgsl above (same
     restricted expression subset, same first-assignment-wins Int/Float
     inference, same "no premature abstraction between similar-shaped
     compilers" choice this file already made for try_compile vs.
     try_compile_host) but targeting GLSL ES 3.00 -- the shading language
     WebGL2 actually runs, for a VERTEX+FRAGMENT pair, not a compute
     kernel.

     WHY NOT compute: real WebGL2 has NO compute shader stage AT ALL --
     that needs OpenGL ES 3.1, one major version past WebGL2's ES 3.0
     base (confirmed directly, not assumed: the real GL adapter surfaced
     while verifying tsubaki-gpu's own WebGL fallback this session reported
     `max_compute_workgroups_per_dimension: 0`). Naga can translate WGSL
     compute to GLSL as plain TEXT (`naga::back::glsl`, ~100KB of the
     WebGL-fallback wasm bloat researched earlier this session) but there
     would be nowhere to actually RUN it -- neither tsubaki-gpu nor any
     browser has a GLSL compute entry point to hand it to. Vertex+fragment
     is where GLSL is real and runnable on WebGL2, so that's what this
     compiles to instead -- see nyanrus's own choice between the two.

     Two independent kernels compile separately (`compile_stage` below,
     parameterized only by `stage`): a VERTEX one, whose only magic INPUT
     is `vertex_index` (Int, GLSL's `gl_VertexID` -- the
     `@builtin(vertex_index)`-free-standing-shader shape every WGSL
     example in this repo already uses, no vertex-buffer/attribute system
     existing here to feed it any other way) and whose two magic OUTPUTS
     are `pos_x`/`pos_y` (Float each -- assembled into `gl_Position =
     vec4(pos_x, pos_y, 0.0, 1.0)` at the very end, z/w fixed, matching
     every 2-D shader in this repo); and a FRAGMENT one, whose four magic
     OUTPUTS are `frag_r`/`frag_g`/`frag_b`/`frag_a` (assembled into the
     real `out vec4 fragColor`). All six magic names are simply
     PRE-SEEDED into `locals` (already Float-typed, already "declared")
     before the body walk starts, so ordinary assignment handling needs
     no special-casing at all to treat them as outputs instead of no-op
     writes to true build-of-nowhere locals.

     `uniforms` is a Dict mapping each uniform's name (String) to its
     TYPE (String): `"Float"` for a plain scalar, the name of an already-
     declared vecN-eligible Tsubaki struct (e.g. `"Vec2"`, same convention
     `Compile.Wgsl`'s buffers use) for a `vec2`/`vec3`/`vec4`, or the
     literal `"mat4"` for a `mat4`. (Not a plain Array of bare names
     anymore, unlike this module's first version -- a type now needs
     somewhere to live, and real WebGL2 already sets a uniform by NAME
     via `gl.getUniformLocation`, not a positional `@binding` index, so a
     Dict was the natural, minimal place, matching Wgsl's own choice for
     its buffers for the same reason.) Readable as that type, from
     EITHER stage. No varyings exist yet (the vertex stage can't hand the
     fragment stage anything beyond `gl_Position`) -- a real, disclosed
     v1 cut. Unlike Wgsl's buffers, there's no array-stride pitfall to
     worry about here at all: a uniform is always a single value, never
     an array element, so vec3 and mat4 are both fully supported. *)
  module Glsl = struct
    type ty = TInt | TFloat | TVec of int | TMat4

    let glsl_ty = function TInt -> "int" | TFloat -> "float" | TVec n -> Printf.sprintf "vec%d" n | TMat4 -> "mat4"
    let float_literal = Wgsl.float_literal
    let indent = Wgsl.indent

    let parse_uniform_type (type_name : string) : ty =
      match type_name with
      | "Float" -> TFloat
      | "mat4" -> TMat4
      | other -> (
        match vec_arity other with
        | Some n -> TVec n
        | None ->
          failwith
            (Printf.sprintf
               "to_glsl: unknown uniform type %S -- expected \"Float\", the name of an already-declared 2-4-field Float struct (e.g. \"Vec2\"), or \"mat4\""
               type_name))

    let compile_stage (stage : [ `Vertex | `Fragment ]) (body : stmt list) (uniforms : (string * string) list) : string option =
      let body = strip_lines body in
      let uniform_ty : (string, ty) Hashtbl.t = Hashtbl.create 4 in
      List.iter (fun (n, t) -> Hashtbl.replace uniform_ty n (parse_uniform_type t)) uniforms;
      let locals : (string, ty) Hashtbl.t = Hashtbl.create 8 in
      let magic_outputs = match stage with `Vertex -> [ "pos_x"; "pos_y" ] | `Fragment -> [ "frag_r"; "frag_g"; "frag_b"; "frag_a" ] in
      List.iter (fun n -> Hashtbl.replace locals n TFloat) magic_outputs;
      (* see Wgsl.try_compile's own identical field for why -- GLSL
         blocks are real lexical scopes too *)
      let for_loop_vars : (string, unit) Hashtbl.t = Hashtbl.create 4 in
      let local_ty_opt name = Hashtbl.find_opt locals name in
      let rec compile_expr (e : expr) : string * ty =
        match e with
        | EInt n -> string_of_int n, TInt
        | EFloat f -> float_literal f, TFloat
        (* unary minus -- see Wgsl.compile_expr's identical case for why
           this must come before the generic EBinOp case below *)
        | EBinOp ("-", EInt 0, e, _) ->
          let text, ty = compile_expr e in
          Printf.sprintf "(-%s)" text, ty
        | EVar ("vertex_index", _) when stage = `Vertex -> "gl_VertexID", TInt
        | EVar (name, _) when Hashtbl.mem uniform_ty name -> name, Hashtbl.find uniform_ty name
        | EVar (name, _) -> (
          match local_ty_opt name with
          | Some ty -> name, ty
          | None -> raise Not_eligible)
        (* vecN construction -- see Wgsl.compile_expr's identical case *)
        | ECall (kind, args, [], _) when vec_arity kind <> None ->
          let n = Option.get (vec_arity kind) in
          if List.length args <> n then raise Not_eligible;
          let compiled = List.map compile_expr args in
          if not (List.for_all (fun (_, t) -> t = TFloat) compiled) then raise Not_eligible;
          Printf.sprintf "vec%d(%s)" n (String.concat ", " (List.map fst compiled)), TVec n
        (* swizzle -- see Wgsl.compile_expr's identical case *)
        | EField (obj, field) -> (
          let obj_text, obj_ty = compile_expr obj in
          match obj_ty with
          | TVec n when Array.exists (( = ) field) (Array.sub vec_field_names 0 n) -> Printf.sprintf "%s.%s" obj_text field, TFloat
          | _ -> raise Not_eligible)
        (* mat4 literal -- see Wgsl.compile_expr's identical case for the
           row-major-source/column-major-constructor transposition *)
        | EMatrixLit rows when is_mat4_lit rows ->
          let row_arr = Array.of_list (List.map Array.of_list rows) in
          let cols = ref [] in
          for col = 3 downto 0 do
            for row = 3 downto 0 do
              cols := row_arr.(row).(col) :: !cols
            done
          done;
          let compiled = List.map compile_expr !cols in
          if not (List.for_all (fun (_, t) -> t = TFloat) compiled) then raise Not_eligible;
          Printf.sprintf "mat4(%s)" (String.concat ", " (List.map fst compiled)), TMat4
        | EBinOp (op, a, b, _) ->
          if not (List.mem op bin_ops) then raise Not_eligible;
          if List.mem op [ "<"; "<="; ">"; ">="; "=="; "!=" ] then
            raise Not_eligible (* only compile_cond accepts these -- see Wgsl's own identical restriction *);
          let a_text, a_ty = compile_expr a in
          let b_text, b_ty = compile_expr b in
          (* GLSL ES 3.00 has NO `%` operator for float at all (only for
             signed/unsigned integers) -- `mod()` is the real builtin for
             that case. *)
          if op = "%" && a_ty = TFloat && b_ty = TFloat then Printf.sprintf "mod(%s, %s)" a_text b_text, TFloat
          else
            let result_ty =
              match op, a_ty, b_ty with
              | _, t1, t2 when t1 = t2 -> t1
              | ("*" | "/"), TVec n, TFloat -> TVec n
              | "*", TFloat, TVec n -> TVec n
              | "*", TMat4, TVec 4 -> TVec 4
              | "*", TMat4, TMat4 -> TMat4
              | _ -> raise Not_eligible
            in
            Printf.sprintf "(%s %s %s)" a_text op b_text, result_ty
        | _ -> raise Not_eligible
      in
      let compile_cond (e : expr) : string =
        match e with
        | EBinOp (op, a, b, _) when List.mem op [ "<"; "<="; ">"; ">="; "=="; "!=" ] ->
          let a_text, a_ty = compile_expr a in
          let b_text, b_ty = compile_expr b in
          (match a_ty, b_ty with
          | (TInt | TFloat), (TInt | TFloat) -> ()
          | _ -> raise Not_eligible (* GLSL's `==`/`!=` on a vecN/mat4 needs `all()`, not valid bare in an if/while -- see Wgsl's identical restriction *));
          if a_ty <> b_ty then raise Not_eligible;
          Printf.sprintf "(%s %s %s)" a_text op b_text
        | _ -> raise Not_eligible
      in
      let buf = Buffer.create 256 in
      let emit_line depth s =
        Buffer.add_string buf (indent depth);
        Buffer.add_string buf s;
        Buffer.add_char buf '\n'
      in
      let rec compile_stmt depth (s : stmt) : unit =
        match s with
        | SExpr (EAssign (name, rhs, _)) ->
          let text, ty = compile_expr rhs in
          (match local_ty_opt name with
          | Some prev_ty ->
            if prev_ty <> ty then raise Not_eligible;
            emit_line depth (Printf.sprintf "%s = %s;" name text)
          | None ->
            Hashtbl.replace locals name ty;
            emit_line depth (Printf.sprintf "%s %s = %s;" (glsl_ty ty) name text))
        | SExpr _ -> raise Not_eligible
        | SReturn None -> emit_line depth "return;"
        | SReturn (Some _) -> raise Not_eligible (* the magic outputs ARE the return value -- see module comment *)
        | SIf (branches, else_body) -> compile_if depth branches else_body
        | SFor (FVSingle var, EBinOp (":", lo, hi, _), body) -> compile_for depth var lo hi body
        | SFor _ -> raise Not_eligible
        | SWhile (cond, body) ->
          emit_line depth (Printf.sprintf "while (%s) {" (compile_cond cond));
          List.iter (compile_stmt (depth + 1)) body;
          emit_line depth "}"
        | _ -> raise Not_eligible
      and compile_if depth branches else_body =
        let rec go first = function
          | [] -> (
            match else_body with
            | Some b ->
              emit_line depth "else {";
              List.iter (compile_stmt (depth + 1)) b;
              emit_line depth "}"
            | None -> ())
          | (cond, body) :: rest ->
            emit_line depth (Printf.sprintf "%s (%s) {" (if first then "if" else "else if") (compile_cond cond));
            List.iter (compile_stmt (depth + 1)) body;
            emit_line depth "}";
            go false rest
        in
        go true branches
      and compile_for depth var lo hi body =
        let lo_text, lo_ty = compile_expr lo in
        let hi_text, hi_ty = compile_expr hi in
        if lo_ty <> TInt || hi_ty <> TInt then raise Not_eligible;
        (match local_ty_opt var with
        | Some TInt -> ()
        | Some (TFloat | TVec _ | TMat4) -> raise Not_eligible
        | None -> Hashtbl.replace locals var TInt);
        Hashtbl.replace for_loop_vars var ();
        emit_line depth (Printf.sprintf "for (int %s = %s; %s <= %s; %s = %s + 1) {" var lo_text var hi_text var var);
        List.iter (compile_stmt (depth + 1)) body;
        emit_line depth "}"
      in
      try
        (* two passes -- see Wgsl.try_compile's own identical comment for
           why (GLSL blocks are real lexical scopes too, same issue) *)
        let pre_existing = Hashtbl.copy locals in
        List.iter (compile_stmt 1) body;
        Buffer.clear buf;
        let predecl = Buffer.create 128 in
        Hashtbl.iter
          (fun name ty ->
            if (not (Hashtbl.mem pre_existing name)) && not (Hashtbl.mem for_loop_vars name) then
              Buffer.add_string predecl (Printf.sprintf "  %s %s;\n" (glsl_ty ty) name))
          locals;
        List.iter (compile_stmt 1) body;
        let body_text = Buffer.contents predecl ^ Buffer.contents buf in
        let uniform_decls = Buffer.create 64 in
        List.iter
          (fun (n, _) -> Buffer.add_string uniform_decls (Printf.sprintf "uniform %s %s;\n" (glsl_ty (Hashtbl.find uniform_ty n)) n))
          uniforms;
        let out_decls, out_locals, assemble =
          match stage with
          | `Vertex ->
            ( ""
            , "  float pos_x = 0.0;\n  float pos_y = 0.0;\n"
            , "  gl_Position = vec4(pos_x, pos_y, 0.0, 1.0);\n" )
          | `Fragment ->
            ( "precision mediump float;\nout vec4 fragColor;\n"
            , "  float frag_r = 0.0;\n  float frag_g = 0.0;\n  float frag_b = 0.0;\n  float frag_a = 1.0;\n"
            , "  fragColor = vec4(frag_r, frag_g, frag_b, frag_a);\n" )
        in
        (* `out_decls`' `precision mediump float;` (fragment stage only)
           MUST come before any `float`-typed declaration -- GLSL ES has
           no default float precision in a fragment shader at all (unlike
           vertex, which defaults to highp), so a `uniform float` placed
           before it is a real compile error, not just a style nit. *)
        Some
          (Printf.sprintf "#version 300 es\n%s%s\nvoid main() {\n%s%s%s}\n" out_decls (Buffer.contents uniform_decls)
             out_locals body_text assemble)
      with Not_eligible -> None
  end

  (* ========================= Host path ========================= *)
  (* A second, broader compiler, targeting Runtime.Host instead of the
     Bytecode/run_bytecode pair above -- see Host's own module comment
     (runtime.ml) for why this is a separate mechanism rather than an
     extension of the numeric ISA: an ECS "system" function (query a set of
     entities, read struct fields, construct a new struct, call host
     builtins like get_component/add_component!) never qualifies for
     try_compile's restricted numeric ISA at all -- no structs, no strings,
     no function calls with arguments exist in that instruction set.

     Eligible: zero-parameter functions using only plain local variables (a
     free/outer reference still bails via slot_for_read, same policy and
     same reason as try_compile's own -- see its comment for the `bump()`
     bug this exact policy was fixed to prevent), struct field reads
     (`.field`), struct construction (`StructName(...)`, no custom inner
     constructor -- one WITH a custom constructor is dispatched through
     Dispatch like any other call, which is already correct), calls to any
     other already-registered Dispatch method (arithmetic operators,
     get_component, add_component!, query, ...), array literals, if/elseif/
     else, and `for x in <expr>` over an arbitrary iterable (broader than
     try_compile's `lo:hi`-only range -- see Host.iterate).

     Deliberately still bails on: keyword arguments, closures/lambdas,
     `&&`/`||` (real short-circuit control flow, not a plain call), `while`
     (not needed by any ECS-system shape seen so far -- add it the same way
     `for` was added, if that changes), and the handful of ECall forms
     Eval.eval_expr special-cases OUTSIDE Dispatch entirely (println, print,
     typeof, isa, new) -- calling Dispatch.call_cached with any of those
     names would either fail outright (no such Dispatch method exists) or
     silently do the wrong thing, so they're refused here rather than
     miscompiled. *)
  let special_call_forms = [ "println"; "print"; "typeof"; "isa"; "new" ]

  (* ---- inlining the "value vocabulary" back onto the ECS fast path ----------
     The Host VM's SoA write (HEcsSoaWrite, below) only fires when
     add_component!'s second argument is LITERALLY a struct constructor. So the
     moment a component is produced the way one actually wants to write it --
     by an operator or a helper over the components, `p + v` / `step(p, v)` --
     the whole function falls off the compiled path back into the tree-walker.
     Measured: ~12x slower than the same arithmetic spelled as a constructor
     literal (45ms vs 3.8ms per frame at 10k entities), with no nesting or Vec2
     involved at all. THAT is the real "SoA speed vs value vocabulary" seam --
     not the column layout.

     This closes it by rewriting such a call back into the constructor it
     stands for, BEFORE the fast path matches -- so the value vocabulary
     compiles to exactly the same column writes as the hand-expanded form, and
     HEcsSoaWrite itself needs no change at all.

     A method is recorded as inlinable only when inlining cannot change what it
     means: no keyword params or defaults/destructuring/`Type{}` patterns,
     every parameter carries a declared type (needed to select it statically),
     the body is a SINGLE expression, that expression's free variables are
     EXACTLY its parameters (no globals -- so substituting into the caller can
     never capture one of the caller's own locals), and it doesn't call itself
     (no unbounded inlining). And a call site only inlines when the static type
     of EVERY argument is known and exactly one recorded method's declared
     parameter types match it EXACTLY. Exact match is what makes this safe
     under multiple dispatch: nothing is more specific than an exact match, so
     the method real dispatch would have chosen can never be the one skipped.
     Anything else -- unknown argument type, no match, several matches, an
     unrecognized body shape -- simply isn't inlined and compiles exactly as it
     does today. Same "unrecognized shape -> fall back, never a silent wrong
     answer" policy as the rest of this file. *)
  let inline_methods : (string, (string list list * param list * expr) list) Hashtbl.t = Hashtbl.create 32

  (* substitute `env` (parameter name -> the caller's argument expr) through a
     body expression. None for any shape outside the allowed subset, and None
     for a free variable (a name not in `env`) -- either makes the method
     un-inlinable rather than risking a wrong answer. Also used at registration
     time, with each parameter mapped to itself, purely as the validity check. *)
  let rec subst_expr (env : (string * expr) list) (e : expr) : expr option =
    let subst_list es =
      List.fold_right
        (fun x acc -> match acc, subst_expr env x with Some xs, Some x' -> Some (x' :: xs) | _ -> None)
        es (Some [])
    in
    match e with
    | EInt _ | EFloat _ | EStr _ | EBool _ | ENothing -> Some e
    | EVar (n, _) -> List.assoc_opt n env
    | EField (o, f) -> Option.map (fun o' -> EField (o', f)) (subst_expr env o)
    | EBinOp (op, a, b, _) -> (
      match subst_expr env a, subst_expr env b with
      | Some a', Some b' -> Some (EBinOp (op, a', b', Caches.fresh_call ()))
      | _ -> None)
    | ECall (f, args, [], _) ->
      Option.map (fun args' -> ECall (f, args', [], Caches.fresh_call ())) (subst_list args)
    | ETernary (c, t, f) -> (
      match subst_expr env c, subst_expr env t, subst_expr env f with
      | Some c', Some t', Some f' -> Some (ETernary (c', t', f'))
      | _ -> None)
    | _ -> None

  (* called by Eval for every function declaration -- see inline_methods above *)
  let register_inlinable name (params : param list) kwparams (body : stmt list) =
    let simple_param p =
      p.pdefault = None && p.pdestructure = None && p.ptypepattern = None && p.pname <> "" && p.ptype <> [ "Any" ]
    in
    (* NOTE: no "does the body mention its own name" check here, on purpose. It
       would reject every operator: the body of `+(::Position, ::Velocity)` is
       `Position(p.x + v.dx, ...)`, whose inner `+` is the ordinary Float one,
       a different method entirely. Runaway inlining is bounded at the call
       site instead (inline_depth, below), which costs nothing and can't
       misread a same-named method on other types as recursion. *)
    let body_expr =
      match strip_lines body with [ SExpr e ] -> Some e | [ SReturn (Some e) ] -> Some e | _ -> None
    in
    match body_expr with
    | Some e when kwparams = [] && params <> [] && List.for_all simple_param params -> (
      let self = List.map (fun p -> p.pname, EVar (p.pname, Caches.fresh_var ())) params in
      match subst_expr self e with
      | None -> () (* body outside the allowed subset, or captures a global -- never inline *)
      | Some _ ->
        let sig_ = List.map (fun p -> p.ptype) params in
        let prev = try Hashtbl.find inline_methods name with Not_found -> [] in
        (* redefining the same signature replaces it, exactly as dispatch does *)
        let prev = List.filter (fun (s, _, _) -> s <> sig_) prev in
        Hashtbl.replace inline_methods name ((sig_, params, e) :: prev))
    | _ -> ()

  (* The operators Eval answers itself, before Dispatch is ever asked (see its
     own EBinOp cases): short-circuit control flow, a range as a value, and the
     ones whose meaning is built in rather than carried by a method. HBin goes
     straight to Dispatch.call_cached, so compiling one of these here asks for
     a method nobody ever defined -- `f() = "a" => 1` came back as
     "MethodError: no method matching =>(String, Int)" while the same
     expression at the top level was a Pair. Not eligible, tree-walk it.

     "&&"/"||" need real lazy control flow, not a plain binop; ":" is only
     supported as a for-loop's own iterator (see SFor below), not as a
     standalone value; "=>" is a Pair, "==="/"!==" identity, "<:" a subtype
     test on two names that are deliberately NOT evaluated, and "in" knows
     ranges and collections that no method covers. *)
  let not_a_method = [ "&&"; "||"; ":"; "=>"; "==="; "!=="; "<:"; "in" ]

  let try_compile_host (body : stmt list) : (Host.program * int) option =
    let body = strip_lines body in
    let slots : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let next_slot = ref 0 in
    let slot_for name =
      match Hashtbl.find_opt slots name with
      | Some s -> s
      | None ->
        let s = !next_slot in
        incr next_slot;
        Hashtbl.replace slots name s;
        s
    in
    (* see try_compile's own slot_for_read for why a READ must never
       silently allocate a fresh, disconnected local for an unrecognized
       name -- same fix, same reason, applied here too. *)
    let slot_for_read name =
      match Hashtbl.find_opt slots name with
      | Some s -> s
      | None -> raise Not_eligible
    in
    let is_struct_ctor name = Hashtbl.mem struct_defs name && not (Hashtbl.mem Dispatch.methods name) in
    (* true only if `name` currently resolves to EXACTLY the methods Ecs
       itself shipped for it, and nothing else -- i.e. nobody has added a
       conflicting/additional overload of a builtin ECS name. A compiled call
       site below bakes in "this name always means the Ecs builtin"
       permanently (same snapshot-at-compile-time policy is_struct_ctor above
       already uses), so this guard is what keeps that safe: if it's false,
       the generic ECall case further down still handles it correctly (just
       without the Dispatch-bypass), real multiple dispatch intact.

       It takes the WHOLE expected method set, not a single signature,
       because the kind-by-type spelling (`get_component(e, Position)`, see
       kind_key below) gives get_component/has_component/remove_component! a
       second builtin method each -- with "exactly one method" as the rule,
       merely ADDING those would have silently switched every SoA fast path
       here back off. *)
    let is_exactly_builtin name sigs =
      match Hashtbl.find_opt Dispatch.methods name with
      | Some ms ->
        List.length ms = List.length sigs
        && List.for_all (fun s -> List.exists (fun m -> m.Dispatch.sig_ = s) ms) sigs
      | None -> false
    in
    (* the two builtin spellings of "which component kind", as Ecs registers
       them: get_component(e, "Position") and get_component(e, Position). *)
    let kind_sigs = [ [ [ "Int" ]; [ "String" ] ]; [ [ "Int" ]; [ "Type" ] ] ] in
    (* the kind a component-access argument names, when it names one at
       compile time: a string literal, or a bare identifier that IS a
       declared struct and is NOT a local variable here. That second half is
       exactly Eval's own rule for a bare type name (see its EVar case: a
       bound variable always wins; only an unbound name that happens to name
       a type becomes a VType), so the compiled spelling and the tree-walked
       one agree on which of the two a name means. Anything else -- a kind
       held in a variable, a computed string -- is None, and the call falls
       through to the generic path below: still correct, just not specialized. *)
    let kind_key (e : expr) : string option =
      match e with
      | EStr k -> Some k
      | EVar (n, _) when Hashtbl.mem struct_defs n && not (Hashtbl.mem slots n) -> Some n
      | _ -> None
    in
    let field_index_opt (names : string array) (field : string) : int option =
      let n = Array.length names in
      let rec go i = if i >= n then None else if names.(i) = field then Some i else go (i + 1) in
      go 0
    in
    (* name -> (entity slot, SoA kind) -- a local this function assigned
       DIRECTLY from `get_component(<entity>, "<SoA-eligible kind>")` and
       nowhere else (see the SExpr(EAssign...) case below: only created
       when `name` had no real slot yet). Such a name never actually needs
       a real boxed VStruct at all -- every later `name.field` read (see
       EField below) compiles straight to a flat-array read via
       HEcsSoaFieldRead, and the original get_component call is dropped
       entirely (a pure read with no side effect, safe to elide). If `name`
       is ever used any OTHER way (passed whole, reassigned from something
       else, ...), slot_for_read has no real slot to find for it and bails
       to Not_eligible, same conservative "unrecognized shape -> tree-walk
       instead" policy as everywhere else in this file -- never a silent
       wrong answer. *)
    let soa_aliases : (string, int * string) Hashtbl.t = Hashtbl.create 8 in
    (* ---- nested SoA: resolving a field PATH against the leaf columns --------
       A SoA-eligible kind may now nest (`struct T; pos::Vec2; vel::Vec2; end`),
       in which case its columns are the LEAVES -- "pos.x", "pos.y", ... (see
       Runtime.soa_leaf_paths). These three walk that shape: the declared type
       at the end of a path, the (alias, path) a field chain reads from, and
       the flattening of a constructor's arguments into one expr per leaf. *)
    let rec type_at kind path =
      match path with
      | [] -> Some kind
      | f :: rest -> (
        match Hashtbl.find_opt struct_defs kind with
        | None -> None
        | Some sd ->
          let rec find ns ts =
            match ns, ts with
            | n :: _, t :: _ when n = f -> Some t
            | _ :: ns', _ :: ts' -> find ns' ts'
            | _ -> None
          in
          (match find sd.field_names sd.field_types with
          | Some [ "Float" ] -> if rest = [] then Some "Float" else None
          | Some [ k ] -> type_at k rest
          | _ -> None))
    in
    (* `t.pos.x` -> Some ("t", ["pos"; "x"]), but only when `t` is an alias *)
    let rec alias_path (e : expr) : (string * string list) option =
      match e with
      | EVar (n, _) when Hashtbl.mem soa_aliases n -> Some (n, [])
      | EField (o, f) -> (
        match alias_path o with
        | Some (n, p) -> Some (n, p @ [ f ])
        | None -> None)
      | _ -> None
    in
    (* a field chain off an alias: a leaf reads its column directly; an interior
       node (`t.pos`, a whole Vec2) is rebuilt from the columns underneath it --
       still no boxed component, just the small value the caller asked for. *)
    let compile_alias_field (e : expr) : Host.hexpr option =
      match alias_path e with
      | None | Some (_, []) -> None
      | Some (var, path) -> (
        let entity_slot, kind = Hashtbl.find soa_aliases var in
        let field_names, cols, present = Option.get ((Host.ecs ()).soa_column_info kind) in
        let rec build prefix ty =
          if ty = "Float" then
            Option.map
              (fun i -> Host.HEcsSoaFieldRead (Host.HLoad entity_slot, cols.(i), present, kind, prefix))
              (field_index_opt field_names prefix)
          else if not (is_struct_ctor ty) then None (* a custom constructor must not be bypassed *)
          else
            match Hashtbl.find_opt struct_defs ty with
            | None -> None
            | Some sd ->
              let subs =
                List.map2
                  (fun fn ft ->
                    let p = prefix ^ "." ^ fn in
                    match ft with
                    | [ "Float" ] -> build p "Float"
                    | [ k ] -> build p k
                    | _ -> None)
                  sd.field_names sd.field_types
              in
              if List.exists Option.is_none subs then None
              else Some (Host.HConstruct (ty, List.map Option.get subs))
        in
        match type_at kind path with
        | None -> None
        | Some ty -> build (String.concat "." path) ty)
    in
    (* re-reading an expression once per leaf is only safe when reading it has
       no side effect -- a plain variable or field chain, nothing else. *)
    let rec is_pure_path e =
      match e with
      | EVar _ -> true
      | EField (o, _) -> is_pure_path o
      | _ -> false
    in
    (* bounds runaway inlining: a single-expression method whose body calls
       ITSELF with a constructor argument (`f(p::P) = f(P(p.x, p.y))`) would
       otherwise expand forever, since that argument's static kind keeps
       matching. Ordinary code never comes near this depth. *)
    let inline_depth = ref 0 in
    (* the static type of a call argument, when it is knowable at all: a
       get_component alias (its component kind) or a constructor call (that
       struct). Anything else is unknown -- and unknown means "don't inline". *)
    let static_kind (e : expr) : string option =
      match e with
      | EVar (n, _) when Hashtbl.mem soa_aliases n -> Some (snd (Hashtbl.find soa_aliases n))
      | ECall (n, _, [], _) when is_struct_ctor n -> Some n
      (* a field path off an alias has a DECLARED type all the way down, so
         `t.pos` is statically a Vec2 -- which is what lets `t.pos + t.vel` pick
         `+(::Vec2, ::Vec2)` and inline it into column arithmetic. *)
      | EField _ -> (
        match alias_path e with
        | Some (var, path) when path <> [] -> type_at (snd (Hashtbl.find soa_aliases var)) path
        | _ -> None)
      | _ -> None
    in
    (* rewrite one call (or operator) into the body expression it stands for --
       see inline_methods. None whenever it isn't provably the right method. *)
    let inline_of (e : expr) : expr option =
      let attempt name args =
        match Hashtbl.find_opt inline_methods name with
        | None -> None
        | Some methods -> (
          let kinds = List.map static_kind args in
          if List.exists Option.is_none kinds then None
          else
            let want = List.map (fun k -> [ Option.get k ]) kinds in
            match List.filter (fun (s, ps, _) -> s = want && List.length ps = List.length args) methods with
            | [ (_, params, body) ] -> subst_expr (List.map2 (fun p a -> p.pname, a) params args) body
            | _ -> None)
      in
      match e with
      | ECall (name, args, [], _) -> attempt name args
      | EBinOp (op, a, b, _) -> attempt op [ a; b ]
      | _ -> None
    in
    (* one expr per leaf column, from a constructor's own arguments. A flat
       all-::Float struct gives back exactly its arguments (so nothing changes
       for it). A nested one descends: into an inner constructor literal, or a
       pure path (`t.vel` -> its own leaf reads), or -- the whole point -- into
       a COMPUTED inner value like `t.pos + t.vel`, by inlining it first (see
       inline_methods) and flattening the constructor it turns out to be. None
       if any argument doesn't fit, and then the caller simply builds a real
       struct and lets add_component! decompose it: slower, still right.

       This also replaces the old "argument count == column count" test, which
       a one-field inner struct could satisfy by pure coincidence -- `struct V;
       a::One; b::Float; end` has two leaves and two arguments, and would have
       written the `One` STRUCT into a float column. *)
    let rec flatten_ctor (kind : string) (args : expr list) : expr list option =
      match Hashtbl.find_opt struct_defs kind with
      | Some sd when List.length args = List.length sd.field_names ->
        let rec leaves_of base k =
          match Hashtbl.find_opt struct_defs k with
          | None -> None
          | Some sd' ->
            let ls =
              List.map2
                (fun fn ft ->
                  let fe = EField (base, fn) in
                  match ft with
                  | [ "Float" ] -> Some [ fe ]
                  | [ k' ] -> leaves_of fe k'
                  | _ -> None)
                sd'.field_names sd'.field_types
            in
            if List.exists Option.is_none ls then None else Some (List.concat_map Option.get ls)
        in
        let inner k a =
          match a with
          | ECall (n, sub, [], _) when n = k && is_struct_ctor n -> flatten_ctor k sub
          | _ when is_pure_path a -> leaves_of a k
          | _ -> (
            match inline_of a with
            | Some (ECall (n, sub, [], _)) when n = k && is_struct_ctor n -> flatten_ctor k sub
            | _ -> None)
        in
        let parts =
          List.map2
            (fun ft a -> match ft with [ "Float" ] -> Some [ a ] | [ k ] -> inner k a | _ -> None)
            sd.field_types args
        in
        if List.exists Option.is_none parts then None else Some (List.concat_map Option.get parts)
      | _ -> None
    in
    let rec compile_expr (e : expr) : Host.hexpr =
      match e with
      | EInt n -> Host.HConst (VInt n)
      | EFloat f -> Host.HConst (VFloat f)
      | EStr s -> Host.HConst (VStr s)
      | EBool b -> Host.HConst (VBool b)
      | ENothing -> Host.HConst VNothing
      | EVar (name, _) -> Host.HLoad (slot_for_read name)
      (* a field read off a get_component alias -- `p.x` on a flat kind, or a
         whole path like `t.pos.x` / `t.pos` on a nested one. Resolved against
         the same leaf columns Ecs actually allocated (see compile_alias_field);
         anything that doesn't resolve falls back to the tree-walker rather than
         guessing at a column. *)
      | EField _ when alias_path e <> None -> (
        match compile_alias_field e with
        | Some h -> h
        | None -> raise Not_eligible)
      | EField (obj, name) -> Host.HField (compile_expr obj, name)
      | EArrayLit es -> Host.HMakeArray (List.map compile_expr es)
      | EBinOp (op, a, b, _) ->
        if List.mem op not_a_method then raise Not_eligible;
        Host.HBin (op, compile_expr a, compile_expr b, Dispatch.new_cache ())
      (* --- specialized ECS opcodes: skip Dispatch.call_cached's name/
         argument-type resolution entirely for the handful of calls an ECS
         system loop actually makes in its hot path, going straight to
         Ecs's own raw functions via Runtime.Host's ecs_hooks indirection
         (see that module's comment). Each still falls through to the
         generic ECall case below whenever is_exactly_builtin says no --
         e.g. a non-literal kind string (`get_component(e, some_var)`) or a
         user overload -- so an unrecognized shape stays correct, just
         without this specific fast path. *)
      | ECall ("get_component", [ obj; key ], [], _)
        when is_exactly_builtin "get_component" kind_sigs && kind_key key <> None ->
        Host.HEcsGetComponent (compile_expr obj, Option.get (kind_key key))
      (* the value vocabulary: `add_component!(e, p + v)` / `add_component!(e,
         step(p, v))`. Rewrite the call into the constructor it returns, then
         recompile -- so the SoA write just below sees the literal it needs and
         the whole thing becomes plain column writes, no struct allocated and
         no dispatch. Checked BEFORE that case (it produces exactly its input
         shape); anything not provably inlinable returns None here and compiles
         as it always did. See inline_methods. *)
      | ECall ("add_component!", [ obj; c ], [], _)
        when is_exactly_builtin "add_component!" [ [ [ "Int" ]; [ "Any" ] ] ]
             && !inline_depth < 8
             && inline_of c <> None ->
        incr inline_depth;
        let r = compile_expr (ECall ("add_component!", [ obj; Option.get (inline_of c) ], [], Caches.fresh_call ())) in
        decr inline_depth;
        r
      (* SoA write: `add_component!(e, K(args...))` where K is SoA-eligible
         and has no custom constructor -- writes each arg straight into K's
         flat float columns, no VStruct ever allocated. Checked BEFORE the
         generic add_component! case just below (this is a strict subset of
         it); arity mismatch or a non-SoA/AoS kind falls through there,
         still correct (constructs a real struct), just unaccelerated. *)
      | ECall ("add_component!", [ obj; ECall (ctor_name, field_es, [], _) ], [], _)
        when is_exactly_builtin "add_component!" [ [ [ "Int" ]; [ "Any" ] ] ] && is_struct_ctor ctor_name -> (
        (* the constructor's arguments must flatten to exactly one expression
           per leaf column -- for a flat kind that's just its own arguments,
           for a nested one it descends. If they don't, build a real struct and
           let add_component! decompose it: slower, still right. *)
        match (Host.ecs ()).soa_column_info ctor_name, flatten_ctor ctor_name field_es with
        | Some (field_names, cols, present), Some leaf_es when Array.length field_names = List.length leaf_es ->
          let compiled_leaf_es = Array.of_list (List.map compile_expr leaf_es) in
          Host.HEcsSoaWrite (compile_expr obj, Array.map2 (fun col ce -> col, ce) cols compiled_leaf_es, present)
        | _ -> Host.HEcsAddComponent (compile_expr obj, Host.HConstruct (ctor_name, List.map compile_expr field_es)))
      | ECall ("add_component!", [ obj; c ], [], _) when is_exactly_builtin "add_component!" [ [ [ "Int" ]; [ "Any" ] ] ] ->
        Host.HEcsAddComponent (compile_expr obj, compile_expr c)
      | ECall ("create_entity", [], [], _) when is_exactly_builtin "create_entity" [ [] ] -> Host.HEcsCreateEntity
      | ECall ("destroy_entity!", [ obj ], [], _) when is_exactly_builtin "destroy_entity!" [ [ [ "Int" ] ] ] ->
        Host.HEcsDestroyEntity (compile_expr obj)
      | ECall ("has_component", [ obj; key ], [], _)
        when is_exactly_builtin "has_component" kind_sigs && kind_key key <> None ->
        Host.HEcsHasComponent (compile_expr obj, Option.get (kind_key key))
      | ECall ("remove_component!", [ obj; key ], [], _)
        when is_exactly_builtin "remove_component!" kind_sigs && kind_key key <> None ->
        Host.HEcsRemoveComponent (compile_expr obj, Option.get (kind_key key))
      | ECall ("query", [ EArrayLit kind_es ], [], _)
        when is_exactly_builtin "query" [ [ [ "Array" ] ] ] && List.for_all (fun e -> kind_key e <> None) kind_es ->
        Host.HEcsQuery (List.map (fun e -> Option.get (kind_key e)) kind_es)
      | ECall (name, args, kwargs, _) ->
        if kwargs <> [] then raise Not_eligible;
        if List.mem name special_call_forms then raise Not_eligible;
        let cargs = List.map compile_expr args in
        if is_struct_ctor name then Host.HConstruct (name, cargs) else Host.HCallHost (name, cargs, Dispatch.new_cache ())
      | _ -> raise Not_eligible
    in
    let rec compile_stmt (s : stmt) : Host.hstmt =
      match s with
      | SExpr (EAssign (name, ECall ("get_component", [ EVar (entity_name, _); key ], [], _), _))
        when (not (Hashtbl.mem slots name))
             && is_exactly_builtin "get_component" kind_sigs
             && kind_key key <> None
             && Hashtbl.mem slots entity_name
             && Option.is_some ((Host.ecs ()).soa_column_info (Option.get (kind_key key))) ->
        let kind = Option.get (kind_key key) in
        (* alias, don't allocate a real slot for `name` at all -- see
           soa_aliases' own comment above. The get_component call itself is
           dropped: it's a pure read, and every later `name.field` becomes
           its own direct HEcsSoaFieldRead instead (see EField above). *)
        Hashtbl.replace soa_aliases name (Hashtbl.find slots entity_name, kind);
        Host.HExprStmt (Host.HConst VNothing)
      | SExpr (EAssign (name, rhs, _)) -> Host.HAssign (slot_for name, compile_expr rhs)
      | SExpr e -> Host.HExprStmt (compile_expr e)
      | SIf (branches, else_body) ->
        Host.HIf
          ( List.map (fun (cond, b) -> compile_expr cond, Array.of_list (List.map compile_stmt b)) branches,
            Option.map (fun b -> Array.of_list (List.map compile_stmt b)) else_body )
      | SFor (FVSingle var, iter_e, b) ->
        let iter_c = compile_expr iter_e in
        (* the iterator expr is compiled BEFORE this loop's own variable
           gets a slot -- `for e in query(...)` must not let a stray bare
           `e` inside the iterator expr itself (there never is one here,
           but nothing should silently accept it either) resolve to this
           loop's own not-yet-existing slot *)
        let var_slot = slot_for var in
        Host.HForEach (var_slot, iter_c, Array.of_list (List.map compile_stmt b))
      | SFor (FVTuple _, _, _) -> raise Not_eligible (* a tuple-destructure target, outside this host subset *)
      | SReturn e -> Host.HReturn (Option.map compile_expr e)
      | _ -> raise Not_eligible
    in
    (* the last statement gets special treatment for real Julia's implicit-
       return semantics -- same policy try_compile's own body-walk uses,
       widened by exactly one case: a trailing `for` (this module's whole
       reason to exist is ECS systems, which are ALWAYS shaped as "loop
       over entities, mutate components, implicitly return nothing" -- and
       that IS real Julia's own semantics for a `for` loop's value, not a
       guess). A trailing `if`/`while`/anything else whose own implicit
       value would need propagating out still bails, same as try_compile. *)
    let compile_body stmts : Host.hstmt array =
      match List.rev stmts with
      | [] -> [||]
      | last :: rest_rev ->
        let compiled_rest = List.rev (List.rev_map compile_stmt rest_rev) in
        let compiled_last =
          match last with
          | SReturn e -> Host.HReturn (Option.map compile_expr e)
          | SFor _ -> compile_stmt last
          | SExpr (EAssign _) -> raise Not_eligible (* nothing meaningful to implicitly return *)
          | SExpr e -> Host.HReturn (Some (compile_expr e))
          | _ -> raise Not_eligible (* if/while/... as the last stmt: implicit value not handled, bail *)
        in
        Array.of_list (compiled_rest @ [ compiled_last ])
    in
    try
      let prog = compile_body body in
      Some (prog, !next_slot)
    with Not_eligible -> None
