(* ============================= Parser ============================= *)
  open Ast
  open Lexer

  exception Parse_error of string

  (* every statement-level parse error gets recorded here (line, col, message)
     instead of aborting the whole parse on the first one -- see
     parse_stmt_list's recovery loop. Reset at the start of each
     parse_program call. Still an all-or-nothing result in the end (a
     program with any parse error doesn't run), but reports everything
     wrong with it in one pass instead of one fix-and-rerun cycle per
     mistake. *)
  let parse_errors : (int * int * string) list ref = ref []

  type state =
    { toks : token array
    ; space_before : bool array
    ; line : int array
    ; col : int array
    ; mutable pos : int
    }

  let mk quads =
    { toks = Array.of_list (List.map (fun (t, _, _, _) -> t) quads)
    ; space_before = Array.of_list (List.map (fun (_, s, _, _) -> s) quads)
    ; line = Array.of_list (List.map (fun (_, _, l, _) -> l) quads)
    ; col = Array.of_list (List.map (fun (_, _, _, c) -> c) quads)
    ; pos = 0
    }

  let peek st = st.toks.(st.pos)
  (* clamped at the final token (always EOF, since tokenize's last entry
     always is one) -- every other call site only ever advances past a
     token it just matched against a specific pattern, so this only
     actually matters for the unconditional advance in parse_stmt_list's
     error-recovery skip, which could otherwise be asked to step past EOF
     itself when the error was "ran out of tokens" *)
  let advance st = if st.pos < Array.length st.toks - 1 then st.pos <- st.pos + 1
  let save st = st.pos
  let restore st p = st.pos <- p

  (* the token `n` positions ahead of the current one, clamped at EOF --
     used for the one-token lookahead that tells a named function decl
     (`function foo(...)`) apart from an anonymous lambda (`function
     (...)`) when deciding whether `@name` is wrapping a whole statement *)
  let peek_at st n =
    let i = min (st.pos + n) (Array.length st.toks - 1) in
    st.toks.(i)

  (* whether the token at index i had whitespace/a comment directly before it
     -- out-of-range (i.e. past EOF) defaults to true, same as "there's
     nothing tightly bound here" *)
  let space_before st i = i >= Array.length st.space_before || st.space_before.(i)

  (* 1-based (line, col) of the token at index i -- out-of-range clamps to
     the last real token (EOF's own position, put there by the lexer) *)
  let line_col st i =
    let i = if i >= Array.length st.line then Array.length st.line - 1 else i in
    st.line.(i), st.col.(i)

  (* try a parser; on Parse_error, restore position and return None *)
  let try_parse st f =
    let p = save st in
    try Some (f ()) with
    | Parse_error _ ->
      restore st p;
      None

  let show_tok = function
    | TINT n -> Printf.sprintf "INT %d" n
    | TFLOAT f -> Printf.sprintf "FLOAT %f" f
    | TSTR s -> Printf.sprintf "STR %S" s
    | TIDENT s -> Printf.sprintf "IDENT %s" s
    | TKW s -> Printf.sprintf "KW %s" s
    | TOP s -> Printf.sprintf "OP %s" s
    | TEOF -> "EOF"

  let ctx st =
    let lo = max 0 (st.pos - 3) in
    let hi = min (Array.length st.toks - 1) (st.pos + 3) in
    let parts = ref [] in
    for i = hi downto lo do
      let mark = if i = st.pos then ">>" else "" in
      parts := Printf.sprintf "%s%s" mark (show_tok st.toks.(i)) :: !parts
    done;
    let line, col = line_col st st.pos in
    Printf.sprintf "line %d, col %d (pos=%d) [%s]" line col st.pos (String.concat " " !parts)

  let expect_op st op =
    match peek st with
    | TOP o when o = op ->
      advance st
    | _ -> raise (Parse_error (Printf.sprintf "expected '%s' at %s" op (ctx st)))

  let expect_kw st kw =
    match peek st with
    | TKW k when k = kw -> advance st
    | _ -> raise (Parse_error (Printf.sprintf "expected keyword '%s' at %s" kw (ctx st)))

  let ident st =
    match peek st with
    | TIDENT s ->
      advance st;
      s
    | _ -> raise (Parse_error (Printf.sprintf "expected identifier at %s" (ctx st)))

  let at_op st op = match peek st with TOP o -> o = op | _ -> false
  let at_kw st kw = match peek st with TKW k -> k = kw | _ -> false
  let at_eof st = match peek st with TEOF -> true | _ -> false

  let is_block_end st =
    at_kw st "end" || at_kw st "else" || at_kw st "elseif" || at_kw st "catch" || at_eof st

  (* is the CURRENT token the start of a real statement (a declaration or a
     control-flow block), as opposed to an expression? Used only to decide
     whether `@name ...` is wrapping a whole statement (`@inline function
     f(x) ... end`) rather than a trailing expression (`@assert x > 0`) --
     see SMacroCall. `function` alone is ambiguous (a NAMED decl is a
     statement; the anonymous `function (x) ... end` lambda is already a
     perfectly good expression), so it needs the one-token lookahead. *)
  let at_stmt_start st =
    at_kw st "struct" || at_kw st "abstract" || at_kw st "if" || at_kw st "for" || at_kw st "while"
    || at_kw st "try" || at_kw st "mutable" || at_kw st "module" || at_kw st "macro"
    || (at_kw st "function" && match peek_at st 1 with TIDENT _ -> true | _ -> false)

  (* ":" is deliberately NOT here -- ranges (a:b and a:step:b) aren't a normal
     left-associative binary operator, they're parsed specially by
     parse_range below, since a:b:c has three operands, not two. *)
  let prec = function
    | "||" -> 0
    | "&&" -> 1
    | "==" | "!=" | "<" | "<=" | ">" | ">=" | "===" | "!==" | "<:" -> 2
    (* real Julia's own precedence groups `|`/`⊻` with `+`/`-` (its "plus"
       category) and `&` with `*`/`/`/`%` (its "times" category) -- not with
       `&&`/`||`, the common mistake coming from C-family languages *)
    | "+" | "-" | "|" | "\xe2\x8a\xbb" -> 3
    | "*" | "/" | "//" | "%" | ">>>" | "<<" | ">>" | "\xe2\x8b\x85" | "\\" | "&" | "\xc3\xb7" -> 4
    | "^" -> 5
    | _ -> -1

  (* consumes an optional `where T [<: Bound]` / `where {T [<: Bound], U, ...}`
     clause, returning each bound type-variable's name and its own optional
     `<:Bound` -- Tsubaki never type-checks an ORDINARY `x::T` param against
     the bound (see strip_where_param_types, unchanged), but a `::Type{T}`
     dispatch parameter needs it for real (see `finalize_type_pattern`) to
     tell apart e.g. `factor`'s four real overloads in Primes.jl, each
     bound to a different container family. Shared by struct inner
     constructors and plain `function`/one-liner declarations alike. *)
  let skip_where_clause st : (string * string option) list =
    let one_var () =
      let t = ident st in
      let bound = if at_op st "<:" then (advance st; Some (ident st)) else None in
      t, bound
    in
    if at_kw st "where" then (
      advance st;
      if at_op st "{" then (
        advance st;
        let rec loop acc =
          let acc = one_var () :: acc in
          if at_op st "," then (
            advance st;
            loop acc)
          else List.rev acc
        in
        let names = loop [] in
        expect_op st "}";
        names)
      else [ one_var () ])
    else []

  (* `function Base.length(...) ... end` / `Base.length(x) = ...` -- real
     Julia code's standard idiom for adding a new method to one of Base's
     OWN generic functions (not shadowing it in the current module). Since
     every builtin here (length, show, push!, ...) is registered under its
     bare name in the very same global Dispatch.methods table a plain user
     `function length(...) ... end` would also register into (defmethod
     just appends a new method, see Runtime.Dispatch.defmethod), the `Base.`
     qualifier carries no runtime meaning at all -- stripping it and
     declaring the bare name is already exactly correct. A qualifier other
     than `Base` would mean adding a method to some OTHER specific module's
     function from outside a `module ... end` block, a real but different
     (and so far undisclosed as needed) mechanism -- rejected clearly rather
     than silently registering it somewhere wrong. *)
  (* an operator symbol is a valid function-declaration name too --
     `function +(a::Named, b::Named) ... end` adds a new method to the SAME
     `Dispatch.methods "+"` table the builtin numeric `+` is already
     registered in (see `defmethod`'s own comment above), so no separate
     mechanism is needed once the parser accepts the name. Restricted to
     `prec`'s own binary-operator set plus unary `!` -- deliberately NOT
     any `TOP` token, so a bare `(`/`,`/etc where a name was expected still
     fails cleanly instead of being swallowed as a bogus "name". *)
  let is_overloadable_op op = prec op >= 0 || op = "!"

  let ident_or_op st : string =
    match peek st with
    | TOP op when is_overloadable_op op ->
      advance st;
      op
    | _ -> ident st

  let parse_funcdecl_name st : string =
    match peek st with
    | TOP op when is_overloadable_op op ->
      advance st;
      op
    | _ -> (
      let n = ident st in
      if at_op st "." then (
        advance st;
        let member = ident_or_op st in
        if n = "Base" then member
        else
          raise
            (Parse_error
               (Printf.sprintf
                  "function declaration qualified by module `%s` isn't supported (only `Base.%s` is, to add a \
                   method to an existing Base function)"
                  n member)))
      else n)

  (* a plain function's `where T` names a type variable, not a real
     registered type -- a param declared `x::T` for such a T must dispatch
     as unconstrained (`Any`), or every call would raise a spurious
     MethodError against a type name that was never actually registered. *)
  let strip_where_param_types (where_vars : (string * string option) list) (params : param list) : param list =
    List.map
      (fun p ->
        match p.ptype with
        | [ t ] when List.mem_assoc t where_vars -> { p with ptype = [ "Any" ] }
        | _ -> p)
      params

  (* resolves a `::Type{...}` parameter's ambiguous bare-identifier case
     (see parse_type_pattern's own comment): a raw `TPMatch name` becomes a
     real `TPWhole` ONLY if `name` is actually one of this declaration's own
     `where` variables -- substituting name's own `where name<:Bound`
     (or "Any" if it has none) is what lets e.g. Primes.jl's four real
     `factor(::Type{X}, ...) where {X<:SomeFamily}` overloads dispatch on
     four DIFFERENT container families instead of colliding. Anything else
     (TPMatch naming a real registered type, or TPNested) is untouched. *)
  let finalize_type_patterns (where_vars : (string * string option) list) (params : param list) : param list =
    List.map
      (fun p ->
        match p.ptypepattern with
        | Some (TPMatch name) -> (
          match List.assoc_opt name where_vars with
          | Some bound_opt -> { p with ptypepattern = Some (TPWhole (name, Option.value bound_opt ~default:"Any")) }
          | None -> p)
        | _ -> p)
      params

  let rec parse_expr st =
    let lhs = parse_range st in
    if at_op st "?" then (
      advance st;
      (* the true-branch deliberately uses parse_binary, not parse_expr/parse_range --
         otherwise a bare ":" ending the true-branch (`cond ? a : b`) gets
         swallowed by range parsing as if it were `a:b`, and the ternary's own
         ":" is never found. The false-branch stays a full parse_expr so
         ternaries can chain (`a ? b : c ? d : e`). *)
      let t = parse_binary st 0 in
      expect_op st ":";
      let f = parse_expr st in
      ETernary (lhs, t, f))
    else if at_op st "=" then (
      advance st;
      let rhs = parse_expr st in
      match lhs with
      | EVar (n, _) -> EAssign (n, rhs, Runtime.new_var_cache ())
      | EField (o, f) -> EFieldAssign (o, f, rhs)
      | EIndex (o, idx) -> EIndexAssign (o, idx, rhs)
      | EInterp inner -> EInterpAssign (inner, rhs)
      (* `x[] = v` -- real Julia's 0-argument setindex!, how an Observable is
         written (`score[] = 3`). Both spellings the empty-bracket parse can
         produce (see it above: a bare name stays ETypedArrayNew, anything else
         is already a getindex call) land on the same setindex! here. Nothing
         is lost by taking the ETypedArrayNew one: `Float[] = v` was never a
         legal assignment target anyway. *)
      | ETypedArrayNew (name, []) ->
        ECall ("setindex!", [ EVar (name, Runtime.new_var_cache ()); rhs ], [], Runtime.Dispatch.new_cache ())
      | ECall ("getindex", [ obj ], [], _) ->
        ECall ("setindex!", [ obj; rhs ], [], Runtime.Dispatch.new_cache ())
      | _ -> raise (Parse_error "invalid assignment target"))
    else
      match peek st with
      | TOP (("+=" | "-=" | "*=" | "/=" | ">>=") as op) ->
        advance st;
        let rhs = parse_expr st in
        let base_op = String.sub op 0 (String.length op - 1) in
        let combined = EBinOp (base_op, lhs, rhs, Runtime.Dispatch.new_cache ()) in
        (match lhs with
        | EVar (n, _) -> EAssign (n, combined, Runtime.new_var_cache ())
        | EField (o, f) -> EFieldAssign (o, f, combined)
        | EIndex (o, idx) -> EIndexAssign (o, idx, combined)
        (* `score[] += hits` -- same two shapes as the plain `=` case above *)
        | ETypedArrayNew (name, []) ->
          ECall ("setindex!", [ EVar (name, Runtime.new_var_cache ()); combined ], [], Runtime.Dispatch.new_cache ())
        | ECall ("getindex", [ obj ], [], _) ->
          ECall ("setindex!", [ obj; combined ], [], Runtime.Dispatch.new_cache ())
        | _ -> raise (Parse_error "invalid compound-assignment target"))
      | _ -> lhs

  (* a:b (step 1) or a:step:b -- each operand parsed at the normal binary
     level, since e.g. `a:n+1` should mean `a:(n+1)`. *)
  and parse_range st =
    let lo = parse_binary st 0 in
    if at_op st ":" then (
      advance st;
      let mid = parse_binary st 0 in
      if at_op st ":" then (
        advance st;
        let hi = parse_binary st 0 in
        ERangeStep (lo, mid, hi))
      else EBinOp (":", lo, mid, Runtime.Dispatch.new_cache ()))
    else lo

  and parse_binary st min_prec =
    let lhs = ref (parse_unary st) in
    let continue_ = ref true in
    while !continue_ do
      match peek st with
      (* an operator that itself STARTS a new source line (as opposed to
         trailing at the end of the previous one, real Julia's own
         multi-line-expression style: `total = a +\n  b`) never continues
         the expression -- matches real Julia's own newline sensitivity,
         and is what lets a bare operator function declaration (`+(a, b) =
         ...`) on its own line be recognized as a NEW statement rather than
         silently glued onto whatever expression came before it (found
         necessary once operator names became valid statement-starters,
         see parse_funcdecl_name). *)
      | TOP op
        when prec op >= 0 && prec op >= min_prec
             && (st.pos = 0 || fst (line_col st st.pos) = fst (line_col st (st.pos - 1))) ->
        advance st;
        let rhs = parse_binary st (prec op + 1) in
        lhs := EBinOp (op, !lhs, rhs, Runtime.Dispatch.new_cache ())
      (* `x in y` as an ordinary boolean expression (membership test),
         outside a `for`/comprehension header (which consumes its own `in`
         directly via expect_kw, never reaching here) -- found in Primes.jl,
         `if U in 0`. Same comparison-level precedence as `==`/`<`/etc. The
         right side is parsed via parse_range, not parse_binary, so a
         literal range reads correctly as a single unit (`x in 1:5` means
         `x in (1:5)`, not `(x in 1):5` -- parse_range itself already sits
         ABOVE parse_binary for exactly this reason, since `:` needs to see
         a whole lo/hi operand each, not stop at the first thing parse_binary
         would otherwise swallow). *)
      | TKW "in"
        when 2 >= min_prec && (st.pos = 0 || fst (line_col st st.pos) = fst (line_col st (st.pos - 1))) ->
        advance st;
        let rhs = parse_range st in
        lhs := EBinOp ("in", !lhs, rhs, Runtime.Dispatch.new_cache ())
      | _ -> continue_ := false
    done;
    !lhs

  (* parse_binary's twin for elements of a whitespace-separated matrix row:
     identical, except a '+'/'-' that has a space before it and none after
     (tight-bound to the operand that follows) ends the current element
     instead of continuing it as a binary op. This is real Julia's own rule
     for telling `[1 -2]` (two elements) apart from `[1 - 2]` and `[1-2]`
     (one element, ordinary subtraction) -- no other operator is ambiguous
     this way, so only +/- get the check. A comma-separated row never
     reaches this ambiguity at all (each element starts a fresh parse). *)
  and parse_matrix_elem st =
    let rec go min_prec =
      let lhs = ref (parse_unary st) in
      let continue_ = ref true in
      while !continue_ do
        match peek st with
        | TOP ("+" | "-") when space_before st st.pos && not (space_before st (st.pos + 1)) ->
          continue_ := false
        | TOP op when prec op >= 0 && prec op >= min_prec ->
          advance st;
          let rhs = go (prec op + 1) in
          lhs := EBinOp (op, !lhs, rhs, Runtime.Dispatch.new_cache ())
        | _ -> continue_ := false
      done;
      !lhs
    in
    go 0

  and parse_unary st =
    if at_op st "-" then (
      advance st;
      let e = parse_unary st in
      EBinOp ("-", EInt 0, e, Runtime.Dispatch.new_cache ()))
    else if at_op st "!" then (
      (* logical not -- reuses ordinary ECall/dispatch (a "!" method on
         Bool) rather than a dedicated AST node, the same way real Julia's
         own `!x` is just a call to the function named `!` *)
      advance st;
      let e = parse_unary st in
      ECall ("!", [ e ], [], Runtime.Dispatch.new_cache ()))
    else parse_postfix st

  and parse_postfix st =
    let e = ref (parse_atom st) in
    (* tracks a run of plain dotted identifiers (`Outer.Inner.deepmember`) so
       a call at the END of an arbitrarily long chain still becomes a single
       EQualifiedCall with the full dotted prefix as its modname -- module
       nesting registers functions under exactly that flattened
       "Outer.Inner.foo" key (see SModuleDecl in Eval), so no per-level
       unwrapping is needed, just the right string. Reset to [] the moment
       `e` stops being a pure name chain (an index, a call, a broadcast
       dot-call, `'`), so a later `.member(...)` on THAT result is never
       mistaken for still being part of the earlier chain. *)
    let dotted_chain = ref (match !e with EVar (name, _) -> [ name ] | _ -> []) in
    let continue_ = ref true in
    while !continue_ do
      if at_op st "." && (match peek_at st 1 with TOP "(" -> true | _ -> false) then (
        dotted_chain := [];
        (* `f.(container)` -- real Julia's broadcast dot-call, applying `f`
           to each element of ONE Vector/Array/Matrix argument (or just
           calling it directly if the argument isn't a container -- see
           EComprehension's own existing all-numeric/Array result-shape
           logic, reused here as-is). Desugars directly into the same
           single-clause comprehension `[f(x) for x in container]` already
           builds -- no new runtime/eval logic needed at all. Deliberately
           single-argument only: real Julia's fuller multi-argument/scalar-
           mixing broadcast isn't attempted (a further step, not disclosed
           as needed anywhere yet). *)
        advance st;
        advance st;
        match !e with
        | EVar (name, _) ->
          let container = parse_expr st in
          expect_op st ")";
          let bvar = "##bcast" in
          e :=
            EComprehension
              ( ECall (name, [ EVar (bvar, Runtime.new_var_cache ()) ], [], Runtime.Dispatch.new_cache ())
              , [ (FVSingle bvar, container) ] )
        | _ -> raise (Parse_error "broadcast dot-call (f.(...)) requires a bare function name"))
      else if at_op st "." then (
        advance st;
        let f = ident st in
        if !dotted_chain <> [] && at_op st "(" then (
          (* Name.member(args) or Outer.Inner.deepmember(args) -- qualified
             call, any chain length; modname is the full dotted prefix
             accumulated so far, joined back into the same string module
             nesting itself builds internally *)
          advance st;
          let args, kwargs = parse_arglist st in
          expect_op st ")";
          let modname = String.concat "." (List.rev !dotted_chain) in
          e := EQualifiedCall (modname, f, args, kwargs, Runtime.Dispatch.new_cache ());
          dotted_chain := [])
        else (
          (if !dotted_chain <> [] then dotted_chain := f :: !dotted_chain);
          e := EField (!e, f)))
      else if at_op st "[" && (match peek_at st 1 with TOP "]" -> true | _ -> false) then (
        (* `T[]` -- real Julia's typed-EMPTY-array shorthand. Truly empty
           brackets can't parse as an ordinary index expression at all (there's
           no expr between them), so this is the one shape that MUST be
           decided here at parse time rather than deferred to Eval's
           lookup-fails-so-reinterpret fallback (see the non-empty case
           below, and Eval's EIndex case for why that one CAN wait). *)
        dotted_chain := [];
        advance st;
        advance st;
        match !e with
        | EVar (name, _) -> e := ETypedArrayNew (name, [])
        (* the OTHER thing empty brackets say in real Julia: `x[]`, a 0-argument
           getindex -- how an Observable is read (`score[]`). A bare name is
           ambiguous between the two (`Float[]` and `score[]` are the same
           shape), so THAT one stays ETypedArrayNew and Eval decides which it
           was, the same lookup-fails-so-reinterpret dispensation the non-empty
           case gets. Anything that isn't a bare name (`scene.collisions[]`)
           was never a type name, so it can only be this. *)
        | obj -> e := ECall ("getindex", [ obj ], [], Runtime.Dispatch.new_cache ()))
      else if at_op st "[" then (
        dotted_chain := [];
        advance st;
        let first = parse_expr st in
        let rest = ref [] in
        while at_op st "," do
          advance st;
          rest := parse_expr st :: !rest
        done;
        expect_op st "]";
        (* a single index (`v[i]`) stays a bare expr, unchanged from before;
           `A[i,j]` (only ever a Matrix's own row/col pair here -- Tsubaki has
           no genuine N-D array) becomes a 2-tuple, matched against VMat
           below in eval_expr/EIndexAssign. `T[1,2,3]` (real Julia's typed-
           array-literal shorthand) parses through this SAME ordinary path
           -- indistinguishable from indexing at parse time -- and is
           reinterpreted at eval time instead (see Eval's EIndex case). *)
        let idx = match List.rev !rest with [] -> first | more -> ETuple (first :: more) in
        e := EIndex (!e, idx))
      else if at_op st "'" then (
        (* postfix transpose/adjoint, real Julia's `A'` -- unlike some
           languages, `'` has no other meaning here (no char literals), so
           this is unambiguous with no lookahead needed *)
        dotted_chain := [];
        advance st;
        e := ECall ("transpose", [ !e ], [], Runtime.Dispatch.new_cache ()))
      else if at_op st "(" && not (space_before st st.pos) then (
        (* Calling what the expression so far EVALUATED to: `f()()`,
           `v[1](x)`, `(x -> x + 1)(3)`.

           A bare `f(x)` never reaches here -- parse_atom's own TIDENT case
           already took it, as an ECall carrying a name for dispatch to
           resolve on -- and neither does `Name.member(...)`, taken by the
           qualified-call branch above while the dotted chain is still a pure
           run of names. So this only ever fires on shapes that did not parse
           at all before.

           Requiring NO whitespace before the "(" is what stops it from
           swallowing a following statement: a line that merely BEGINS with
           "(" -- `(a, b) = f()` under a preceding expression statement --
           always has whitespace in front of it, the newline itself. Real
           Julia draws the same line between `f(x)` and `f (x)`. *)
        dotted_chain := [];
        advance st;
        let args, kwargs = parse_arglist st in
        expect_op st ")";
        if kwargs <> [] then
          raise (Parse_error "keyword arguments need a named function -- a computed callee is a plain closure");
        e := EApply (!e, args))
      else continue_ := false
    done;
    !e

  (* real Julia's numeric-literal coefficient juxtaposition (`2x`, `2I`,
     `2(x+1)`): a numeral immediately followed (no space) by an identifier or
     "(" is implicit multiplication. Checked right after the literal atom is
     produced.

     The coefficient binds TIGHTER than `*`/`+` but LOOSER than `^` -- real
     Julia's own documented rule ("2x^3 is parsed as 2*(x^3)", alongside
     "2^3x is parsed as 2^(3x)" and "-2x as -(2x)"). So the RHS is parsed at
     exactly `^`'s own precedence level: high enough to swallow a following
     `^`, low enough that a following `*`/`+` still wraps the whole product
     from the outside, which parse_unary/parse_binary already do.

     This used to call parse_postfix -- one level too tight, which made
     `3x^2` mean `(3x)^2`: 144 where real Julia says 48. Caught by running
     the identical file under real Julia 1.12.5 (tests/control.jl, via
     `make test-julia`), not by reading the code. *)
  and maybe_coeff_mult st lit =
    let tight_follow =
      (match peek st with TIDENT _ -> true | TOP "(" -> true | _ -> false)
      && not (space_before st st.pos)
    in
    if tight_follow then EBinOp ("*", lit, parse_binary st (prec "^"), Runtime.Dispatch.new_cache ())
    else lit

  and parse_atom st =
    match peek st with
    | TINT n ->
      advance st;
      maybe_coeff_mult st (EInt n)
    | TFLOAT f ->
      advance st;
      maybe_coeff_mult st (EFloat f)
    | TSTR s ->
      advance st;
      interpolate_string s
    | TKW "true" ->
      advance st;
      EBool true
    | TKW "false" ->
      advance st;
      EBool false
    | TKW "nothing" ->
      advance st;
      ENothing
    | TKW "end" ->
      advance st;
      EEnd
    | TKW "return" ->
      (* `cond && return x` / `cond || return x` -- real Julia's statement-
         level short-circuit control flow. `return` isn't normally a valid
         expression OPERAND at all; this is reached only when it shows up
         mid-expression (as `&&`/`||`'s RHS), reusing the existing `EBlock`
         node ("wraps a stmt list as a single expr") so evaluation falls
         straight through to the ordinary `SReturn`/`Return_exc` machinery
         -- `&&`/`||`'s own short-circuit evaluation (see Eval) already
         means this only actually runs when the return should really
         happen. Deliberately single-value only (`parse_expr`, not
         `parse_comma_exprs`) -- unlike a plain top-level `return a, b`
         statement, this can appear nested inside a wider expression, where
         a bare comma is often something else entirely (a call's own
         argument separator, for instance). *)
      advance st;
      if is_block_end st || at_op st ";" || at_op st ")" || at_op st "," then EBlock [ SReturn None ]
      else EBlock [ SReturn (Some (parse_expr st)) ]
    | TKW "quote" ->
      advance st;
      let body = parse_stmt_list st in
      expect_kw st "end";
      EQuoteBlock body
    | TOP ":" -> (
      advance st;
      match peek st with
      | TOP "(" ->
        advance st;
        let e = parse_expr st in
        expect_op st ")";
        EQuote e
      | TIDENT name ->
        advance st;
        EQuoteSymbol name
      | TOP op ->
        (* :+ , :< , etc -- quoting a single-token operator as a Symbol *)
        advance st;
        EQuoteSymbol op
      | _ -> raise (Parse_error (Printf.sprintf "expected '(' or a name after ':' at %s" (ctx st))))
    | TOP "@" ->
      advance st;
      let name = ident st in
      if at_op st "(" then (
        advance st;
        let args, _kwargs = parse_arglist st in
        expect_op st ")";
        EMacroCall (name, args))
      else (
        (* bareword form: @name expr -- takes ONE trailing expression as the
           sole argument, matching real Julia's common `@time foo()` /
           `@assert x > 0` usage. Multiple space-separated bareword args
           aren't supported -- write @name(a, b) for that. *)
        let arg = parse_expr st in
        EMacroCall (name, [ arg ]))
    | TOP "$" ->
      advance st;
      if at_op st "(" then (
        advance st;
        let e = parse_expr st in
        expect_op st ")";
        EInterp e)
      else EInterp (EVar (ident st, Runtime.new_var_cache ()))
    | TKW "function" ->
      (* anonymous, multi-statement form: function (args) ... end -- as
         opposed to the named `function name(args) ... end` declaration,
         which only parse_stmt recognizes (it always requires a name) *)
      advance st;
      let params, _kwparams = parse_params st in
      let body = parse_stmt_list st in
      expect_kw st "end";
      (* ELambda's own grammar is bare names only -- no tuple-destructure,
         no positional defaults (both are only supported on a NAMED
         function declaration's params, see SFuncDecl's eval) *)
      List.iter
        (fun p ->
          if p.pdestructure <> None || p.pdefault <> None then
            raise
              (Parse_error
                 "anonymous `function (...) ... end` params can't use tuple-destructuring or default values"))
        params;
      ELambda (List.map (fun p -> p.pname) params, body)
    | TOP "(" -> (
      (* try `(a, b) -> expr` (a multi-arg lambda) before falling back to a
         plain parenthesized expression *)
      match
        try_parse st (fun () ->
            advance st;
            let names =
              if at_op st ")" then []
              else (
                let rec loop acc =
                  let n = ident st in
                  let acc = n :: acc in
                  if at_op st "," then (
                    advance st;
                    loop acc)
                  else List.rev acc
                in
                loop [])
            in
            expect_op st ")";
            expect_op st "->";
            names)
      with
      | Some names ->
        let body = parse_expr st in
        ELambda (names, [ SExpr body ])
      | None ->
        advance st;
        let first = parse_expr st in
        (* `(a, b)` as a plain expression (not a destructure/return's own
           comma list, both of which call parse_comma_exprs directly and
           never reach here) -- a parenthesized tuple literal usable
           anywhere a value is expected, e.g. `return (a, b), (c, d)` or
           passed straight into a function call. A lone `(e)` (no comma)
           stays just `e`, matching every other grouping paren already. *)
        let e =
          if at_op st "," then (
            let rec loop acc =
              if at_op st "," then (
                advance st;
                loop (parse_expr st :: acc))
              else List.rev acc
            in
            ETuple (loop [ first ]))
          else first
        in
        expect_op st ")";
        e)
    | TOP "[" ->
      advance st;
      if at_op st "]" then (
        advance st;
        EArrayLit [])
      else (
        let start_pos = save st in
        let first = parse_expr st in
        if at_kw st "for" then (
          advance st;
          (* one or more comma-separated `var in iter` / `var = iter` clauses --
             real Julia treats "in" and "=" as fully interchangeable here, so
             mandel's verbatim `for i = ..., r = ...` parses unmodified.
             `var` can be a tuple-unpacking target too (`(k, v) in ...`,
             found in Primes.jl), same grammar a plain `for` header already
             has -- see parse_for_target. *)
          let parse_clause () =
            let var = parse_for_target st in
            (if at_op st "=" then advance st else expect_kw st "in");
            let iter = parse_expr st in
            var, iter
          in
          let rec loop acc =
            let acc = parse_clause () :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc
          in
          let clauses = loop [] in
          expect_op st "]";
          EComprehension (first, clauses))
        else (
          (* a row's remaining elements, real Julia's own way: comma-separated
             (like a Vector literal) AND/OR plain whitespace-separated
             (`[1.0 2.0 3.0]`) both work, freely mixable. Whitespace-separated
             elements go through parse_matrix_elem, not parse_expr, so a
             tight-bound sign (`[1.0 -2.0]`) starts a new element instead of
             continuing the previous one as a binary op -- see that
             function's comment. *)
          (* tracks whether row1 (below) was ever continued via a comma --
             distinguishes a real Vector literal (`[1.0, 2.0, 3.0]`, or
             comma-free but single-element `[1.0]`) from a genuine
             whitespace-only row (`[1.0 2.0 3.0]`), which real Julia builds
             as a 1xN Matrix, not a Vector (see the no-semicolon branch
             below). *)
          let used_comma = ref false in
          let parse_row_rest first_elem =
            let rec loop acc =
              if at_op st "," then (
                used_comma := true;
                advance st;
                loop (parse_matrix_elem st :: acc))
              else if at_op st ";" || at_op st "]" || at_eof st then List.rev acc
              else loop (parse_matrix_elem st :: acc)
            in
            loop [ first_elem ]
          in
          (* `first` above was parsed with the FULL expression grammar, which
             is exactly what over-consumes a row's tight-bound leading sign
             (`[1.0 -2.0]` greedily becomes the single expr `1.0 - 2.0` before
             we ever get a chance to look at spacing). So: re-parse the whole
             row from scratch using the space-sensitive grammar throughout
             (including the first element), and only fall back to `first`
             as a single standalone element if that re-parse can't even get
             going -- e.g. `[1:5]` or `[a ? b : c]`, a lone element using
             syntax (ranges, ternaries) parse_matrix_elem doesn't handle at
             all. Real Julia doesn't have this tension (its lexer is
             whitespace-sensitive throughout `[...]` from the start); this
             two-attempt dance is how a parser that ISN'T gets the common
             case right without losing the lone-element cases. *)
          let row1 =
            match
              try_parse st (fun () ->
                  used_comma := false;
                  restore st start_pos;
                  let row = parse_row_rest (parse_matrix_elem st) in
                  if at_op st ";" || at_op st "]" || at_eof st then row
                  else raise (Parse_error "matrix row: not a clean whitespace-sensitive parse"))
            with
            | Some row -> row
            | None ->
              used_comma := false; (* position is back where `first`'s own parse left it, a lone element *)
              [ first ]
          in
          if at_op st ";" then (
            (* a Matrix literal -- rows are semicolon-separated *)
            let rows = ref [ row1 ] in
            while at_op st ";" do
              advance st;
              (* same two-attempt dance `row1` above uses, and for the same
                 reason: `first_e` below is parsed with the FULL expression
                 grammar, which over-consumes a tight-bound leading sign
                 (`; -16.0 -43.0 98.0`'s first TWO elements greedily become
                 one subtraction, `(-16.0) - 43.0`, before spacing is ever
                 looked at) -- without this, a row after the first one could
                 silently end up with fewer elements than it should, tripping
                 the "all rows must have the same length" check below for the
                 wrong reason (verified: this was a real bug, not a
                 hypothetical one, caught by testing `[12.0 37.0 -43.0;
                 -16.0 -43.0 98.0]`). *)
              let row_start_pos = save st in
              let first_e = parse_expr st in
              let row =
                match
                  try_parse st (fun () ->
                      restore st row_start_pos;
                      let row = parse_row_rest (parse_matrix_elem st) in
                      if at_op st ";" || at_op st "]" || at_eof st then row
                      else raise (Parse_error "matrix row: not a clean whitespace-sensitive parse"))
                with
                | Some row -> row
                | None -> [ first_e ] (* position is back where `first_e`'s own parse left it *)
              in
              rows := row :: !rows
            done;
            expect_op st "]";
            let rows = List.rev !rows in
            let width = List.length (List.hd rows) in
            if not (List.for_all (fun r -> List.length r = width) rows) then
              raise (Parse_error "matrix literal: all rows must have the same length");
            EMatrixLit rows)
          else (
            expect_op st "]";
            (* a single row with no `;` and no comma at all, of more than one
               element, is real Julia's own 1xN Matrix (`[1.0 2.0 3.0]`) --
               a comma-joined row (or a lone element) stays a Vector *)
            if (not !used_comma) && List.length row1 > 1 then EMatrixLit [ row1 ]
            else EArrayLit row1)))
    | TIDENT name ->
      advance st;
      if name = "new" && at_op st "{" then (
        (* new{T}(...) inside a struct's own inner constructor -- the {T}
           names Tsubaki's automatic type-param inference already computes on
           its own (see Runtime.construct), so it's parsed and thrown away
           here, same as a constructor's own {T} suffix; new{T}(...) and
           new(...) end up identical from here on *)
        advance st;
        let rec loop () =
          ignore (ident st);
          if at_op st "," then (
            advance st;
            loop ())
        in
        loop ();
        expect_op st "}";
        expect_op st "(";
        let args, kwargs = parse_arglist st in
        expect_op st ")";
        ECall ("new", args, kwargs, Runtime.Dispatch.new_cache ()))
      else if at_op st "{" then (
        (* Name{T}(...) / Name{T} -- parsed once, THEN decided by whether a
           call's own "(" actually follows the closing "}": Array{T}()/
           Vector{T}(undef,n)/Matrix{T}(undef,m,n) (real Julia's declared-
           element-type constructors) and Name{T}(...) (an explicit
           type-parameter constructor call for a user struct, e.g.
           `DequeBlock{T}(...)`, needed by a short-form inner constructor
           calling itself/another parametric constructor -- `construct`
           already infers the concrete type parameter(s) from the actual
           argument shapes, not from this suffix, so it's thrown away same
           as always) all still need a real call; with NO "(" following,
           `Name{T}` is instead a bare first-class type VALUE (`Deque{Int}`,
           `factor(Vector{Int}, n)`) -- found necessary for `::Type{X}`
           dispatch parameters, which need a real type argument to dispatch
           against. *)
        advance st;
        let rec loop acc =
          let t = ident st in
          let acc = t :: acc in
          if at_op st "," then (
            advance st;
            loop acc)
          else List.rev acc
        in
        let params = loop [] in
        expect_op st "}";
        if not (at_op st "(") then ETypeExpr (Printf.sprintf "%s{%s}" name (String.concat "," params))
        else (
          advance st;
          let args, kwargs = parse_arglist st in
          expect_op st ")";
          match name, params, args with
          | "Matrix", [ elem_ty ], [ EVar ("undef", _); m; n ] -> ETypedMatrixUndef (elem_ty, m, n)
          | "Matrix", [ elem_ty ], _ ->
            raise (Parse_error (Printf.sprintf "Matrix{%s}(...): only (undef, m, n) is supported" elem_ty))
          | ("Array" | "Vector"), [ elem_ty ], [] -> ETypedArrayNew (elem_ty, [])
          | ("Array" | "Vector"), [ elem_ty ], [ EVar ("undef", _); n ] -> ETypedArrayUndef (elem_ty, n)
          | ("Array" | "Vector"), [ elem_ty ], _ ->
            raise (Parse_error (Printf.sprintf "%s{%s}(...): only () or (undef, n) is supported" name elem_ty))
          | _ -> ECall (name, args, kwargs, Runtime.Dispatch.new_cache ())))
      else if at_op st "->" then (
        advance st;
        let body = parse_expr st in
        ELambda ([ name ], [ SExpr body ]))
      else if at_op st "(" then (
        advance st;
        let args, kwargs = parse_arglist st in
        expect_op st ")";
        match parse_do_block st with
        (* the closure goes FIRST, as in real Julia: `f(a) do x ... end` means
           `f(function(x) ... end, a)`. That's what lets a method dispatch on it
           being a function (`on(f, obs)`, Observables.jl's own signature) and
           what a reader coming from Julia expects. Every do-block call site
           today passes no other positional argument (`play() do dt`), so which
           end it lands on is not a change to any of them. *)
        | Some closure -> ECall (name, closure :: args, kwargs, Runtime.Dispatch.new_cache ())
        | None -> ECall (name, args, kwargs, Runtime.Dispatch.new_cache ()))
      else EVar (name, Runtime.new_var_cache ())
    | _ -> raise (Parse_error (Printf.sprintf "expected expression at %s" (ctx st)))

  and parse_arglist st : expr list * (string * expr) list =
    let positional =
      if at_op st ")" || at_op st ";" then []
      else (
        let rec loop acc =
          let e = parse_expr st in
          let acc = e :: acc in
          if at_op st "," then (
            advance st;
            loop acc)
          else List.rev acc
        in
        loop [])
    in
    let kwargs =
      if at_op st ";" then (
        advance st;
        if at_op st ")" then []
        else (
          let rec loop acc =
            let n = ident st in
            expect_op st "=";
            let e = parse_expr st in
            let acc = (n, e) :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc
          in
          loop []))
      else []
    in
    positional, kwargs

  (* do-block sugar: a call immediately followed by `do <params>` on the same
     line, then a statement body, then `end`, desugars to appending an
     ELambda as the LAST positional arg of that call -- exactly like Julia's
     `f(a) do x ; body end` == `f(a, x -> body)`. `do` is a bare TIDENT (not
     reserved), so we peek for it by text. Tsubaki has no newline tokens, so the
     params are whatever bare names sit on the SAME source line as `do`; the
     body starts on the next line. Shares the same `end` closer + parse_stmt_list
     as function/for/while/if. *)
  and parse_do_block st : expr option =
    match peek st with
    | TIDENT "do" ->
      let do_line = fst (line_col st st.pos) in
      advance st;
      let params =
        let rec loop acc =
          if fst (line_col st st.pos) = do_line
             && (match peek st with TIDENT _ -> true | _ -> false)
          then (
            let n = ident st in
            let acc = n :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc)
          else List.rev acc
        in
        loop []
      in
      if at_op st ";" then advance st;
      let body = parse_stmt_list st in
      expect_kw st "end";
      Some (ELambda (params, body))
    | _ -> None

  (* string interpolation: "hi $name" -> EStr "hi " + string(name), and
     "hi $(expr)" -> the parenthesized part is re-tokenized and re-parsed as
     a full expression (mutually recursive with parse_expr, which is exactly
     why this lives in this `and` group instead of standing alone). *)
  and interpolate_string (s : string) : expr =
    let n = String.length s in
    let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' in
    let is_ident c = is_ident_start c || (c >= '0' && c <= '9') in
    let pieces = ref [] in
    let buf = Buffer.create 16 in
    let flush_lit () =
      if Buffer.length buf > 0 then (
        pieces := EStr (Buffer.contents buf) :: !pieces;
        Buffer.clear buf)
    in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '$' && !i + 1 < n && s.[!i + 1] = '(' then (
        flush_lit ();
        let depth = ref 1 in
        let j = ref (!i + 2) in
        while !j < n && !depth > 0 do
          (* a nested string is stepped over whole -- the lexer already kept
             `"$(x > 0 ? "yes" : "no")"` in one piece for us (see its own
             comment), so a `(`, `)` or `$` INSIDE those inner quotes is
             someone else's text, not our nesting *)
          if s.[!j] = '"' then (
            incr j;
            while !j < n && s.[!j] <> '"' do
              if s.[!j] = '\\' && !j + 1 < n then j := !j + 2 else incr j
            done;
            if !j < n then incr j)
          else (
            (if s.[!j] = '(' then incr depth else if s.[!j] = ')' then decr depth);
            if !depth > 0 then incr j)
        done;
        if !depth <> 0 then failwith "unterminated $(...) in string interpolation";
        let inner = String.sub s (!i + 2) (!j - !i - 2) in
        let e = parse_expr (mk (tokenize inner)) in
        pieces := ECall ("string", [ e ], [], Runtime.Dispatch.new_cache ()) :: !pieces;
        i := !j + 1)
      else if s.[!i] = '$' && !i + 1 < n && is_ident_start s.[!i + 1] then (
        flush_lit ();
        let j = ref (!i + 1) in
        while !j < n && is_ident s.[!j] do
          incr j
        done;
        let name = intern (String.sub s (!i + 1) (!j - !i - 1)) in
        pieces :=
          ECall
            ("string", [ EVar (name, Runtime.new_var_cache ()) ], [], Runtime.Dispatch.new_cache ())
          :: !pieces;
        i := !j)
      else if s.[!i] = '\001' then (
        Buffer.add_char buf '$';
        incr i)
      else (
        Buffer.add_char buf s.[!i];
        incr i)
    done;
    flush_lit ();
    match List.rev !pieces with
    | [] -> EStr ""
    | [ (EStr _ as only) ] -> only
    | first :: rest ->
      List.fold_left (fun acc e -> EBinOp ("+", acc, e, Runtime.Dispatch.new_cache ())) first rest

  (* one or more comma-separated expressions -- `a` alone stays a plain expr,
     `a, b, ...` becomes a Tuple. Used by `return a, b` and by the right side
     of a destructuring assignment `x, y = ...`. *)
  (* Union{A,B,C} or a plain type name *)
  and parse_type_expr st : string list =
    let name = ident st in
    if name = "Union" && at_op st "{" then (
      advance st;
      let rec loop acc =
        let t = ident st in
        let acc = t :: acc in
        if at_op st "," then (
          advance st;
          loop acc)
        else List.rev acc
      in
      let alts = loop [] in
      expect_op st "}";
      alts)
    else if at_op st "{" then (
      (* Box{Int} or Dict{Int,String} -- a concrete instantiation of a
         parametric type, matched as one single type name (however many
         parameters), not a union of alternatives *)
      advance st;
      let rec loop acc =
        let t = ident st in
        let acc = t :: acc in
        if at_op st "," then (
          advance st;
          loop acc)
        else List.rev acc
      in
      let inner = loop [] in
      expect_op st "}";
      [ Printf.sprintf "%s{%s}" name (String.concat "," inner) ])
    else [ name ]

  and parse_typed_ident st : string * string list =
    let name = ident st in
    if at_op st "::" then (
      advance st;
      let ty = parse_type_expr st in
      name, ty)
    else name, [ "Any" ]

  (* a for-loop OR comprehension clause's own loop-variable binding: a plain
     name, or real Julia's tuple-unpacking `(s, d)` shorthand. Shared by
     both `TKW "for"` (parse_stmt) and EComprehension's clause list (in
     parse_atom's `TOP "["` case) since they're the exact same grammar. *)
  and parse_for_target st : for_target =
    if at_op st "(" then (
      advance st;
      let rec loop acc =
        let acc = ident st :: acc in
        if at_op st "," then (
          advance st;
          loop acc)
        else List.rev acc
      in
      let names = loop [] in
      expect_op st ")";
      FVTuple names)
    else FVSingle (ident st)

  (* `::Type{...}` as an UNNAMED parameter -- real Julia's trait-dispatch-
     on-the-type-itself idiom (`Base.eltype(::Type{Deque{T}}) where T = T`,
     `factor(::Type{A}, n) where {A<:AbstractArray} = ...`). Produces a
     RAW `TPMatch` for a bare single identifier -- ambiguous until the
     enclosing `where` clause is known (is it a real type name, or a
     where-bound variable that should instead bind the whole matched
     value?) -- see finalize_type_patterns, run once where_vars is
     available, same two-pass shape strip_where_param_types already uses. *)
  and parse_type_pattern st : type_pattern =
    let kw = ident st in
    if kw <> "Type" then raise (Parse_error (Printf.sprintf "expected 'Type{...}' at %s" (ctx st)));
    expect_op st "{";
    let pat =
      if at_op st "<:" then (
        advance st;
        TPMatch (ident st))
      else (
        let outer = ident st in
        if at_op st "{" then (
          advance st;
          let var = ident st in
          expect_op st "}";
          TPNested (outer, var))
        else TPMatch outer)
    in
    expect_op st "}";
    pat

  (* positional params, then optionally `; k1=default1, k2=default2` -- part
     of the same recursive group as parse_expr because kwparam defaults are
     full expressions, and parse_atom (for anonymous `function (args) ... end`)
     needs to call this too. *)
  and parse_params st : param list * (string * string list * expr) list =
    expect_op st "(";
    let params =
      if at_op st ")" || at_op st ";" then []
      else (
        let rec loop acc =
          if at_op st "::" then (
            advance st;
            let pat = parse_type_pattern st in
            let pdefault = if at_op st "=" then (advance st; Some (parse_expr st)) else None in
            let acc =
              { pname = ""; ptype = [ "Any" ]; pdefault; pdestructure = None; ptypepattern = Some pat } :: acc
            in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc)
          else (
            let pname, ptype, pdestructure =
              if at_op st "(" then (
                (* tuple-destructuring parameter, e.g. `(cb, i)` -- found in
                   DataStructures.jl's `deque.jl` (Base.iterate's own state
                   param); always untyped (real Julia doesn't let you write
                   `(cb, i)::T` either) *)
                advance st;
                let rec names_loop acc =
                  let n = ident st in
                  let acc = n :: acc in
                  if at_op st "," then (
                    advance st;
                    names_loop acc)
                  else List.rev acc
                in
                let names = names_loop [] in
                expect_op st ")";
                Printf.sprintf "(%s)" (String.concat ", " names), [ "Any" ], Some names)
              else (
                let n, t = parse_typed_ident st in
                n, t, None)
            in
            let pdefault = if at_op st "=" then (advance st; Some (parse_expr st)) else None in
            let acc = { pname; ptype; pdefault; pdestructure; ptypepattern = None } :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc)
        in
        loop [])
    in
    let kwparams =
      if at_op st ";" then (
        advance st;
        if at_op st ")" then []
        else (
          let rec loop acc =
            (* a keyword param can carry its own `::T` too, `check::Bool =
               true` (found in Primes.jl) -- enforced at bind time the same
               on-this-assignment-only way a positional param's own `::T`
               already is *)
            let n, ty = parse_typed_ident st in
            expect_op st "=";
            let d = parse_expr st in
            let acc = (n, ty, d) :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc
          in
          loop []))
      else []
    in
    expect_op st ")";
    params, kwparams

  and parse_comma_exprs st : expr =
    let first = parse_expr st in
    if at_op st "," then (
      let rec loop acc =
        advance st;
        let e = parse_expr st in
        let acc = e :: acc in
        if at_op st "," then loop acc else List.rev acc
      in
      ETuple (loop [ first ]))
    else first

  and parse_stmt_list st =
    let acc = ref [] in
    while not (is_block_end st) do
      if at_op st ";" then advance st
      else (
        (* where this statement STARTS, captured before parsing it -- see
           Ast's SLine for why the position rides along as its own marker
           rather than as a field on every statement variant *)
        let start_line = fst (line_col st st.pos) in
        match (try `Ok (parse_stmt st) with Parse_error msg -> `Err msg) with
        | `Ok s -> acc := s :: SLine start_line :: !acc
        | `Err msg ->
          let line, col = line_col st st.pos in
          parse_errors := (line, col, msg) :: !parse_errors;
          (* skip past the trouble: at least one token (so this always makes
             progress) then the rest of this line -- statements
             conventionally start a new line here, even though it isn't
             syntactically required, so "the next line" is a reasonable
             recovery point without deeper structural analysis of what was
             actually being parsed when it broke *)
          advance st;
          while (not (is_block_end st)) && fst (line_col st st.pos) = line do
            advance st
          done)
    done;
    List.rev !acc

  and parse_stmt st =
    match peek st with
    | TKW "abstract" ->
      advance st;
      expect_kw st "type";
      let name = ident st in
      let parent = if at_op st "<:" then (advance st; Some (ident st)) else None in
      expect_kw st "end";
      SAbstractDecl (name, parent)
    | TKW "struct" ->
      advance st;
      parse_struct_body st ~mutable_:false
    | TKW "mutable" ->
      advance st;
      expect_kw st "struct";
      parse_struct_body st ~mutable_:true
    | TKW "function" ->
      advance st;
      let name = parse_funcdecl_name st in
      let params, kwparams = parse_params st in
      let where_vars = skip_where_clause st in
      let params = strip_where_param_types where_vars params |> finalize_type_patterns where_vars in
      let body = parse_stmt_list st in
      expect_kw st "end";
      SFuncDecl (name, params, kwparams, body, Runtime.new_funcdecl_cache ())
    | TKW "if" ->
      advance st;
      parse_if st
    | TKW "for" ->
      advance st;
      let target = parse_for_target st in
      (* real Julia treats "in" and "=" as fully interchangeable in a for
         loop header, same as in a comprehension clause (see EComprehension
         parsing) -- `for i = 1:n` is real, common surface syntax, not a
         Tsubaki-specific extension *)
      (if at_op st "=" then advance st else expect_kw st "in");
      let iter = parse_expr st in
      let body = parse_stmt_list st in
      expect_kw st "end";
      SFor (target, iter, body)
    | TKW "while" ->
      advance st;
      let cond = parse_expr st in
      let body = parse_stmt_list st in
      expect_kw st "end";
      SWhile (cond, body)
    | TKW "return" ->
      advance st;
      if is_block_end st || at_op st ";" then SReturn None
      else SReturn (Some (parse_comma_exprs st))
    | TKW "try" ->
      advance st;
      let body = parse_stmt_list st in
      expect_kw st "catch";
      let catchvar =
        match peek st with
        | TIDENT n ->
          advance st;
          Some n
        | _ -> None
      in
      let catch_body = parse_stmt_list st in
      expect_kw st "end";
      STry (body, catchvar, catch_body)
    | TKW "module" ->
      advance st;
      let name = ident st in
      let body = parse_stmt_list st in
      expect_kw st "end";
      SModuleDecl (name, body)
    | TKW "using" ->
      advance st;
      (* a dotted path (`using Outer.Inner`) reaches a nested module -- joined
         right back into the same "Outer.Inner." prefix string a nested
         `module Outer; module Inner; ... end; end` already registers things
         under, so this needs no changes on the use_module side at all *)
      let rec loop acc =
        let acc = ident st :: acc in
        if at_op st "." then (
          advance st;
          loop acc)
        else List.rev acc
      in
      SUsing (String.concat "." (loop []))
    | TKW "import" ->
      advance st;
      (* `import Name: a, b` -- selective import, the counterpart to `using`
         above; a dotted module path the same way, but this time followed by
         `:` and a comma-separated name list that's kept (not thrown away
         like export's) since Eval.import_module needs it to know which
         members to actually bind bare. Bare `import Name` (no `:` at all,
         real Julia's "import everything, but require Name.thing everywhere"
         form) isn't distinguished from `using Name` here -- this interpreter
         has no enforced qualification requirement to model that distinction
         against, so it's accepted as a plain SUsing instead of a new no-op. *)
      let rec loop acc =
        let acc = ident st :: acc in
        if at_op st "." then (
          advance st;
          loop acc)
        else List.rev acc
      in
      let modname = String.concat "." (loop []) in
      if at_op st ":" then (
        advance st;
        (* a name here can be an operator too -- `import Base: +` before
           adding a method to it (see is_overloadable_op/ident_or_op) *)
        let rec names_loop acc =
          let acc = ident_or_op st :: acc in
          if at_op st "," then (
            advance st;
            names_loop acc)
          else List.rev acc
        in
        SImport (modname, names_loop [])
      )
      else SUsing modname
    | TKW "macro" ->
      advance st;
      let name = ident st in
      expect_op st "(";
      let params =
        if at_op st ")" then []
        else (
          let rec loop acc =
            let acc = ident st :: acc in
            if at_op st "," then (
              advance st;
              loop acc)
            else List.rev acc
          in
          loop [])
      in
      expect_op st ")";
      let body = parse_stmt_list st in
      expect_kw st "end";
      SMacroDecl (name, params, body)
    | TKW "export" ->
      advance st;
      let rec loop acc =
        (* real Julia can export a macro name (`export @foo`) or an
           operator (`export +`), not just plain identifiers -- accepted
           and thrown away just the same, so none of it trips up the parser *)
        let name = if at_op st "@" then (advance st; "@" ^ ident st) else ident st in
        let acc = name :: acc in
        if at_op st "," then (
          advance st;
          loop acc)
        else List.rev acc
      in
      SExport (loop [])
    | TKW "const" ->
      (* real Julia's `const NAME = expr` -- purely a perf/immutability hint
         at global scope, meaningless here (Tsubaki never specializes on a
         binding never changing); parsed and thrown away, same convention
         as `export` above -- just re-parse whatever follows as an
         ordinary statement (typically a plain assignment). Found necessary
         re-testing JuliaMath/Primes.jl verbatim. *)
      advance st;
      parse_stmt st
    | TOP "@" -> (
      (* could be @name(args)/@name expr (same as EMacroCall, just used as
         a standalone statement) or @name wrapping a WHOLE statement
         (@inline function f(x) ... end, @inbounds for i in ... end) --
         only the lookahead past the name tells them apart, so try the
         statement-wrapping shape first and fall back to re-parsing the
         ordinary expression form (via parse_atom's own "@" handling) if
         it isn't one *)
      let start_pos = save st in
      advance st;
      let name = ident st in
      if at_stmt_start st then SMacroCall (name, parse_stmt st)
      else (
        restore st start_pos;
        SExpr (parse_comma_exprs st)))
    | _ -> (
      (* destructuring assignment: x, y, ... = rhs -- tried first since it
         starts the same way a plain expression statement would (an
         identifier), but needs at least one comma before the "=" to commit.
         Targets are full lvalues (parse_postfix), so a[i], a[j] = a[j], a[i]
         works, not just bare names. *)
      match
        try_parse st (fun () ->
            (* a bare-name target may carry its own `::T` annotation --
               `n, p::T = state`/`U::T, V::T, Qk::T = 1, 1, Q`, both found in
               Primes.jl -- checked only on `EVar`, matching how `x::T = e`
               (the single-target form, below) is also name-only. *)
            let parse_target () =
              let t = parse_postfix st in
              match t with
              | EVar _ when at_op st "::" ->
                advance st;
                t, Some (parse_type_expr st)
              | _ -> t, None
            in
            let t = parse_target () in
            if not (at_op st ",") then raise (Parse_error "not a destructure");
            let targets = ref [ t ] in
            while at_op st "," do
              advance st;
              targets := parse_target () :: !targets
            done;
            expect_op st "=";
            List.rev !targets)
      with
      | Some targets -> SDestructure (targets, parse_comma_exprs st)
      | None -> (
        (* short-form function definition: name(params) [where T] = expr *)
        match
          try_parse st (fun () ->
              let name = parse_funcdecl_name st in
              let params, kwparams = parse_params st in
              let where_vars = skip_where_clause st in
              let params = strip_where_param_types where_vars params |> finalize_type_patterns where_vars in
              expect_op st "=";
              let e = parse_expr st in
              name, params, kwparams, e)
        with
        | Some (name, params, kwparams, e) ->
          SFuncDecl (name, params, kwparams, [ SExpr e ], Runtime.new_funcdecl_cache ())
        | None -> (
          (* mid-function typed local assignment: x::T = expr *)
          match
            try_parse st (fun () ->
                let name = ident st in
                if not (at_op st "::") then raise (Parse_error "not a typed local assignment");
                advance st;
                let ty = parse_type_expr st in
                expect_op st "=";
                let e = parse_expr st in
                name, ty, e)
          with
          | Some (name, ty, e) -> SLocalTypedAssign (name, ty, e)
          | None -> SExpr (parse_comma_exprs st))))

  and parse_struct_body st ~mutable_ =
    let name = ident st in
    let type_params =
      if at_op st "{" then (
        advance st;
        let rec loop acc =
          let t = ident st in
          (* an inline subtype bound, `struct FactorIterator{T<:Integer}`
             (found in Primes.jl) -- discarded the same way `where T <:
             Signed` already is (see skip_where_clause): Tsubaki never
             type-checks a struct's own type parameter against it either *)
          if at_op st "<:" then (
            advance st;
            ignore (ident st));
          let acc = t :: acc in
          if at_op st "," then (
            advance st;
            loop acc)
          else List.rev acc
        in
        let ts = loop [] in
        expect_op st "}";
        ts)
      else []
    in
    let parent = if at_op st "<:" then (advance st; Some (ident st)) else None in
    let fields = ref [] in
    let constructors = ref [] in
    let kwdefaults = ref [] in
    while not (at_kw st "end") do
      if at_kw st "function" then (
        (* an inner constructor: `function StructName(...) ... end` or
           `function StructName{T}(...) where T ... end` -- the name
           itself isn't checked against the enclosing struct's (nothing
           else can legally appear in a struct body shaped like this, and
           `new`/`new{T}` inside always means "build THIS struct"
           regardless of what the constructor happened to be named) *)
        advance st;
        ignore (ident st);
        if at_op st "{" then (
          advance st;
          let rec loop () =
            ignore (ident st);
            if at_op st "," then (
              advance st;
              loop ())
          in
          loop ();
          expect_op st "}");
        let params, kwparams = parse_params st in
        ignore (skip_where_clause st);
        let body = parse_stmt_list st in
        expect_kw st "end";
        constructors := (params, kwparams, body) :: !constructors)
      else (
        let member_name = ident st in
        if at_op st "{" || at_op st "(" then (
          (* a short-form (one-liner) inner constructor:
             `StructName{T}(params...) where T = expr` or `StructName(params...) = expr`
             -- same idea as the top-level one-liner `f(x) = expr`, just
             inside a struct body. Distinguished from a field declaration
             (which is always a bare name or `name::Type`, never followed by
             `{`/`(`) purely by the token right after the leading identifier. *)
          if at_op st "{" then (
            advance st;
            let rec loop () =
              ignore (ident st);
              if at_op st "," then (
                advance st;
                loop ())
            in
            loop ();
            expect_op st "}");
          let params, kwparams = parse_params st in
          ignore (skip_where_clause st);
          expect_op st "=";
          let body_e = parse_expr st in
          constructors := (params, kwparams, [ SExpr body_e ]) :: !constructors)
        else (
          let ty = if at_op st "::" then (advance st; parse_type_expr st) else [ "Any" ] in
          (* an optional `= expr` default, real Julia's @kwdef field syntax
             (`field::T = default`) -- collected here for any struct; it only
             becomes a keyword constructor when the decl is under @kwdef, see
             Eval.SStructDecl *)
          (if at_op st "=" then (
             advance st;
             kwdefaults := (member_name, parse_expr st) :: !kwdefaults));
          fields := { fname = member_name; ftype = ty } :: !fields))
    done;
    expect_kw st "end";
    SStructDecl
      { mutable_
      ; name
      ; parent
      ; type_params
      ; fields = List.rev !fields
      ; constructors = List.rev !constructors
      ; kwdefaults = List.rev !kwdefaults
      }

  and parse_if st =
    let cond = parse_expr st in
    let body = parse_stmt_list st in
    let branches = ref [ cond, body ] in
    let else_body = ref None in
    let rec loop () =
      if at_kw st "elseif" then (
        advance st;
        let c = parse_expr st in
        let b = parse_stmt_list st in
        branches := (c, b) :: !branches;
        loop ())
      else if at_kw st "else" then (
        advance st;
        else_body := Some (parse_stmt_list st))
    in
    loop ();
    expect_kw st "end";
    SIf (List.rev !branches, !else_body)

  let parse_program (src : string) : stmt list =
    parse_errors := [];
    let st = mk (Lexer.tokenize src) in
    let prog = parse_stmt_list st in
    match List.sort compare !parse_errors with
    | [] -> prog
    | errors ->
      raise
        (Parse_error
           (Printf.sprintf "%d parse error(s):\n%s" (List.length errors)
              (String.concat "\n"
                 (List.map (fun (l, c, msg) -> Printf.sprintf "  line %d, col %d: %s" l c msg) errors))))
