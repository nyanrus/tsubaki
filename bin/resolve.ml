(* ============================= Resolve ============================= *)
(* A genuine static-analysis phase, run once over the whole parsed program
   BEFORE any of it executes: walks the AST maintaining a scope-shape stack
   that mirrors exactly where Eval creates a new runtime scope (function/
   lambda bodies, for/while bodies, if-branches, try/catch bodies,
   comprehension clauses), and for every EVar/EAssign, works out how many
   scopes up its binding actually lives -- writing that depth directly into
   the AST node's own (already-existing) var_cache, so Eval's lookup/assign
   never need to learn it by walking and guessing on the program's first
   pass through.

   Deliberately conservative wherever a binding site can't be determined
   with full confidence -- crossing into a NESTED function/lambda/macro
   declaration's own body means resolving it against a SNAPSHOT of what's
   known in the enclosing scope at the point of declaration; a name not
   found in that snapshot is left completely untouched (depth stays at the
   cache's own default of 0), never guessed at. This is safe by
   construction, not by luck: Eval.lookup_cached/assign_cached already fall
   back to a full, correct walk whenever a cached depth doesn't actually
   find the name at that scope -- so anything this pass doesn't confidently
   resolve costs exactly what it already cost before this pass existed
   (learn-on-first-use), never a wrong answer. Macro-EXPANDED code (built by
   Eval.value_to_expr at eval time, from a macro's return value) is never
   seen by this pass at all -- it doesn't exist yet when this runs -- so it
   always relies on the dynamic fallback alone, same as before this pass
   existed. *)
  open Ast

  type scope = { mutable known : string list; parent : scope option }

  let child parent = { known = []; parent = Some parent }
  let know s name = if not (List.mem name s.known) then s.known <- name :: s.known

  (* Some d: name is already bound d scopes up (an assignment there mutates
     it in place). None: not found anywhere in the chain -- an assignment
     with this name would create a fresh binding right HERE (depth 0) --
     exactly Eval.assign's own rule, computed statically instead of by
     walking real scopes at runtime. *)
  let rec find_depth s name d =
    if List.mem name s.known then Some d
    else match s.parent with Some p -> find_depth p name (d + 1) | None -> None

  let resolve_var s name (cache : Runtime.var_cache) =
    match find_depth s name 0 with
    | Some d -> cache.Runtime.depth <- d
    | None -> () (* UndefVarError at runtime regardless -- nothing to cache *)

  let resolve_assign s name (cache : Runtime.var_cache) =
    match find_depth s name 0 with
    | Some d -> cache.Runtime.depth <- d
    | None ->
      cache.Runtime.depth <- 0;
      know s name

  let global_scope : scope = { known = [ "pi"; "I" ]; parent = None }

  let rec resolve_expr s (e : expr) : unit =
    match e with
    | EInt _ | EFloat _ | EStr _ | EBool _ | ENothing | EBegin | EEnd | EQuoteSymbol _ | ETypedArrayNew _ | ETypeExpr _ -> ()
    | ETypedArrayUndef (_, n_e) -> resolve_expr s n_e
    | ETypedMatrixUndef (_, m_e, n_e) ->
      resolve_expr s m_e;
      resolve_expr s n_e
    | EVar (name, cache) -> resolve_var s name cache
    | EBinOp (_, a, b, _) ->
      resolve_expr s a;
      resolve_expr s b
    | ECall (_, args, kwargs, _) ->
      List.iter (resolve_expr s) args;
      List.iter (fun (_, e) -> resolve_expr s e) kwargs
    | EQualifiedCall (_, _, args, kwargs, _) ->
      List.iter (resolve_expr s) args;
      List.iter (fun (_, e) -> resolve_expr s e) kwargs
    | EField (o, _) -> resolve_expr s o
    | EApply (f, args) ->
      resolve_expr s f;
      List.iter (resolve_expr s) args
    | EAssign (name, rhs, cache) ->
      resolve_expr s rhs;
      resolve_assign s name cache
    | EFieldAssign (o, _, rhs) ->
      resolve_expr s o;
      resolve_expr s rhs
    | EArrayLit es -> List.iter (resolve_expr s) es
    | ELambda (params, body) ->
      (* a nested closure: a snapshot of `s` as it stands right here, not
         live -- see the module comment *)
      let s' = child s in
      List.iter (know s') params;
      resolve_stmt_list s' body
    | EComprehension (body_e, clauses) ->
      let s' = child s in
      List.iter
        (fun (target, iter_e) ->
          resolve_expr s iter_e;
          match target with FVSingle v -> know s' v | FVTuple names -> List.iter (know s') names)
        clauses;
      resolve_expr s' body_e
    | EIndex (o, idx) ->
      resolve_expr s o;
      resolve_expr s idx
    | EIndexAssign (o, idx, rhs) ->
      resolve_expr s o;
      resolve_expr s idx;
      resolve_expr s rhs
    | ETuple es -> List.iter (resolve_expr s) es
    | ETernary (c, t, f) ->
      resolve_expr s c;
      resolve_expr s t;
      resolve_expr s f
    | ERangeStep (a, b, c) ->
      resolve_expr s a;
      resolve_expr s b;
      resolve_expr s c
    | EMatrixLit rows -> List.iter (List.iter (resolve_expr s)) rows
    | EQuote inner -> resolve_quoted_expr s inner
    | EQuoteBlock stmts -> List.iter (resolve_quoted_stmt s) stmts
    | EInterp inner -> resolve_expr s inner
    | EInterpAssign (target, rhs) ->
      resolve_expr s target;
      resolve_expr s rhs
    | EMacroCall (_, args) -> List.iter (resolve_expr s) args
    | EBlock stmts -> resolve_stmt_list s stmts

  and resolve_stmt s (st : stmt) : unit =
    match st with
    | SLine _ -> () (* a source-position marker binds and references nothing *)
    | SExpr e -> resolve_expr s e
    | SIf (branches, else_body) ->
      List.iter
        (fun (cond, body) ->
          resolve_expr s cond;
          resolve_stmt_list (child s) body)
        branches;
      Option.iter (fun b -> resolve_stmt_list (child s) b) else_body
    | SFor (target, iter_e, body) ->
      resolve_expr s iter_e;
      let s' = child s in
      (match target with FVSingle var -> know s' var | FVTuple names -> List.iter (know s') names);
      resolve_stmt_list s' body
    | SWhile (cond, body) ->
      resolve_expr s cond;
      resolve_stmt_list (child s) body
    | SFuncDecl (_, params, kwparams, body, _) ->
      (* like ELambda: a snapshot of `s` at the declaration site, not live *)
      let s' = child s in
      List.iter
        (fun p ->
          (match p.pdefault with Some d -> resolve_expr s d | None -> ());
          match p.ptypepattern with
          | Some (TPMatch _) -> ()
          | Some (TPWhole (var, _)) | Some (TPNested (_, var)) -> know s' var
          | None -> (
            match p.pdestructure with
            | Some names -> List.iter (know s') names
            | None -> know s' p.pname))
        params;
      List.iter
        (fun (k, _ty, default_e) ->
          resolve_expr s default_e;
          know s' k)
        kwparams;
      resolve_stmt_list s' body
    | SStructDecl _ | SAbstractDecl _ -> ()
    | SReturn None -> ()
    | SReturn (Some e) -> resolve_expr s e
    | STry (body, catchvar, catch_body) ->
      resolve_stmt_list (child s) body;
      let s' = child s in
      Option.iter (know s') catchvar;
      resolve_stmt_list s' catch_body
    | SDestructure (targets, rhs) ->
      resolve_expr s rhs;
      List.iter
        (fun (target, _ty) ->
          match target with
          | EVar (name, cache) -> resolve_assign s name cache
          | (EField _ | EIndex _) as target -> resolve_expr s target
          | _ -> ())
        targets
    | SLocalTypedAssign (name, _ty, rhs) ->
      resolve_expr s rhs;
      know s name
    | SModuleDecl (_, body) ->
      (* runs against the SAME scope, not a new one -- see Eval.SModuleDecl *)
      resolve_stmt_list s body
    | SUsing _ -> ()
    | SImport _ -> ()
    | SExport _ -> ()
    | SMacroCall (name, inner) ->
      (* a known hint runs the wrapped statement directly at eval time
         (ordinary scope rules apply); anything else gets reified via
         stmt_to_value if quotable (flat, no scopes -- see
         resolve_quoted_stmt) or is simply unsupported *)
      if Hints.is_inert_hint_macro name then resolve_stmt s inner else resolve_quoted_stmt s inner
    | SMacroDecl (_, params, body) ->
      (* a macro's body always runs in a fresh scope off GLOBAL, never the
         declaration site's scope -- see Eval.EMacroCall *)
      let s' = child global_scope in
      List.iter (know s') params;
      resolve_stmt_list s' body

  and resolve_stmt_list s stmts = List.iter (resolve_stmt s) stmts

  (* --- resolving the INSIDE of a quote (:( ... ) / quote ... end) is a
     genuinely different job from resolving ordinary code, not just a
     recursive call with the same rules. Eval.expr_to_value/stmt_to_value
     REIFY a quote's structure into a value -- they never actually EXECUTE
     it, so an `if`/`for`/`while` written inside a quote never creates a
     real runtime scope while being quoted (unlike the exact same syntax
     written as ordinary code, which does, once per execution). Every
     `$(...)` splice anywhere inside ONE quote -- no matter how deeply
     nested in the quoted syntax it visually appears -- is evaluated with
     the SAME flat environment: wherever the quote itself is being built.
     Treating quoted control-flow as if it opened new static scopes (this
     pass's first attempt) breaks the classic hygiene demo outright: a
     macro whose quote reads `$a` then, inside a quoted `if`, `$b` again,
     would resolve $a and $b to DIFFERENT (wrong) depths even though both
     interpolate at the exact same real depth (macro_env, depth 0) --
     found by testing the actual `@my_max`/`@swap!` demos, not a
     hypothetical. So: recurse through quoted structure WITHOUT ever
     pushing a child scope, and only touch the cache for what's actually
     inside a `$(...)` (via the ordinary, scope-creating resolve_expr) --
     every bare quoted name (a plain EVar/EAssign target with no `$`) is
     just syntax being reified into a Symbol; its cache is never consulted
     for that (see expr_to_value), so there's nothing to resolve there at
     all. *)
  and resolve_quoted_expr s (e : expr) : unit =
    match e with
    | EInterp inner -> resolve_expr s inner
    | EInterpAssign (target, rhs) ->
      resolve_expr s target;
      resolve_expr s rhs
    | EInt _ | EFloat _ | EStr _ | EBool _ | ENothing | EBegin | EEnd | EQuoteSymbol _
    | ETypedArrayUndef _ | ETypedMatrixUndef _ | EVar _ | ETypeExpr _ -> ()
    | ETypedArrayNew (_, elems) -> List.iter (resolve_quoted_expr s) elems
    (* quoting one is refused outright (see Eval.expr_to_value); this only
       walks past it, so an `$(...)` interpolation nested inside still gets
       resolved before that refusal is ever reached *)
    | EApply (f, args) ->
      resolve_quoted_expr s f;
      List.iter (resolve_quoted_expr s) args
    | EBinOp (_, a, b, _) ->
      resolve_quoted_expr s a;
      resolve_quoted_expr s b
    | ECall (_, args, kwargs, _) ->
      List.iter (resolve_quoted_expr s) args;
      List.iter (fun (_, e) -> resolve_quoted_expr s e) kwargs
    | EQualifiedCall (_, _, args, kwargs, _) ->
      List.iter (resolve_quoted_expr s) args;
      List.iter (fun (_, e) -> resolve_quoted_expr s e) kwargs
    | EField (o, _) -> resolve_quoted_expr s o
    | EAssign (_, rhs, _) -> resolve_quoted_expr s rhs
    | EFieldAssign (o, _, rhs) ->
      resolve_quoted_expr s o;
      resolve_quoted_expr s rhs
    | EIndex (o, idx) ->
      resolve_quoted_expr s o;
      resolve_quoted_expr s idx
    | EIndexAssign (o, idx, rhs) ->
      resolve_quoted_expr s o;
      resolve_quoted_expr s idx;
      resolve_quoted_expr s rhs
    | ETuple es -> List.iter (resolve_quoted_expr s) es
    | ETernary (c, t, f) ->
      resolve_quoted_expr s c;
      resolve_quoted_expr s t;
      resolve_quoted_expr s f
    | ERangeStep (a, b, c) ->
      resolve_quoted_expr s a;
      resolve_quoted_expr s b;
      resolve_quoted_expr s c
    | EMatrixLit rows -> List.iter (List.iter (resolve_quoted_expr s)) rows
    | EQuote inner -> resolve_quoted_expr s inner
    | EQuoteBlock stmts -> List.iter (resolve_quoted_stmt s) stmts
    | EArrayLit es -> List.iter (resolve_quoted_expr s) es
    (* a quoted lambda/comprehension never opens a real static scope here
       either (see the module comment above) -- its params/clause vars are
       just syntax being reified into Symbols, resolved for real only at
       splice time by value_to_expr's hygiene rename. Only $(...) splices
       inside the body/iter exprs are ever real, scope-consulting code. *)
    | ELambda (_, body) -> List.iter (resolve_quoted_stmt s) body
    | EComprehension (body_e, clauses) ->
      List.iter (fun (_, iter_e) -> resolve_quoted_expr s iter_e) clauses;
      resolve_quoted_expr s body_e
    | EMacroCall (_, args) -> List.iter (resolve_quoted_expr s) args
    | EBlock _ -> () (* not quotable at all (expr_to_value errors on this) -- nothing to resolve *)

  and resolve_quoted_stmt s (st : stmt) : unit =
    match st with
    | SLine _ -> ()
    | SExpr e -> resolve_quoted_expr s e
    | SIf (branches, else_body) ->
      List.iter
        (fun (cond, body) ->
          resolve_quoted_expr s cond;
          List.iter (resolve_quoted_stmt s) body)
        branches;
      Option.iter (List.iter (resolve_quoted_stmt s)) else_body
    | SFor (_, iter, body) ->
      resolve_quoted_expr s iter;
      List.iter (resolve_quoted_stmt s) body
    | SWhile (cond, body) ->
      resolve_quoted_expr s cond;
      List.iter (resolve_quoted_stmt s) body
    | SReturn None -> ()
    | SReturn (Some e) -> resolve_quoted_expr s e
    | SDestructure (targets, rhs) ->
      resolve_quoted_expr s rhs;
      List.iter (fun (t, _ty) -> resolve_quoted_expr s t) targets
    | SFuncDecl _ | SStructDecl _ | SAbstractDecl _ | STry _ | SModuleDecl _ | SUsing _ | SImport _
    | SMacroDecl _ | SExport _ | SMacroCall _ | SLocalTypedAssign _ -> ()
    (* not quotable at all -- nothing to resolve *)

  let resolve_program (prog : stmt list) : unit = resolve_stmt_list global_scope prog
