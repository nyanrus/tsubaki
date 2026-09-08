(* ============================= Lexer ============================= *)
  type token =
    | TINT of int
    | TFLOAT of float
    | TSTR of string
    | TIDENT of string
    | TKW of string
    | TOP of string
    | TEOF

  let keywords =
    [ "function"; "begin"; "end"; "struct"; "mutable"; "abstract"; "type"; "if"; "elseif"; "else"
    ; "for"; "while"; "true"; "false"; "nothing"; "in"; "return"; "try"; "catch"
    ; "module"; "using"; "import"; "macro"; "quote"; "export"; "where"; "const"
    ]

  (* every identifier occurrence with the SAME text becomes the SAME
     physical string, program-wide (persists for the process's whole
     lifetime -- a single script run never needs to forget one). This is
     what lets Eval.str_assoc_opt's `==` fast path actually fire for
     variable lookups: without it, "k" tokenized at the loop header and "k"
     tokenized again at each reference inside the body would be two
     content-equal but physically-different allocations (String.sub makes
     a fresh one every time), so a hot loop's variable reads/writes would
     always fall through to a full byte comparison. Used here AND by
     Parser.interpolate_string's `$name` extraction, which builds an
     identifier string a different way (slicing a string literal, not
     re-tokenizing) but needs to land on the same canonical instance. *)
  let intern_table : (string, string) Hashtbl.t = Hashtbl.create 256

  let intern s =
    match Hashtbl.find_opt intern_table s with
    | Some s' -> s'
    | None ->
      Hashtbl.replace intern_table s s;
      s

  (* tokenize pairs every token with whether it was directly preceded by
     whitespace/a comment -- used by matrix-literal row parsing (see
     parse_matrix_elem), which needs to tell `[1 -2]` (two elements: a
     tight-bound sign starts a new one) apart from `[1 - 2]` / `[1-2]` (one
     element, ordinary binary subtraction), exactly the disambiguation real
     Julia itself makes -- and its 1-based (line, col), used for error
     messages and for the statement-recovery heuristic in parse_stmt_list
     (see there): both captured once per outer loop iteration, at the very
     start of whatever token (or run of whitespace/comment) is about to be
     scanned, so they always describe where a token actually BEGAN, not
     wherever `i` has wandered to by the time it's fully lexed. *)
  let tokenize (src : string) : (token * bool * int * int) list =
    let n = String.length src in
    let i = ref 0 in
    let line = ref 1 in
    let line_start = ref 0 (* index of this line's first char *) in
    let toks = ref [] in
    let space_before = ref true (* no real predecessor yet; value is irrelevant *) in
    let cur_line = ref 1 in
    let cur_col = ref 1 in
    let emit tok =
      toks := (tok, !space_before, !cur_line, !cur_col) :: !toks;
      space_before := false
    in
    let peekc () = if !i < n then Some src.[!i] else None in
    let is_digit c = c >= '0' && c <= '9' in
    (* `!` is a valid identifier CONTINUATION character (`push!`, `empty!`,
       real Julia's own mutating-function convention) but must NOT be a
       valid identifier START -- otherwise a leading `!` (unary not, or the
       first half of `!=`) gets swallowed as its own one-character
       identifier token before the `!=`/`!` operator matching below ever
       gets a chance to see it. Bug, not a design choice: found while
       testing `n != 2`, which used to tokenize as `IDENT n, IDENT !, OP =,
       INT 2` instead of `IDENT n, OP !=, INT 2`. *)
    let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' || c = '!' in
    let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' in
    let is_alnum c = is_alpha c || is_digit c in
    while !i < n do
      cur_line := !line;
      cur_col := !i - !line_start + 1;
      let c = src.[!i] in
      if c = ' ' || c = '\t' || c = '\r' then (
        space_before := true;
        incr i)
      else if c = '\n' then (
        space_before := true;
        incr i;
        incr line;
        line_start := !i)
      else if c = '#' then (
        (* comment to end of line *)
        space_before := true;
        while !i < n && src.[!i] <> '\n' do
          incr i
        done)
      else if is_digit c then (
        let start = !i in
        while !i < n && is_digit src.[!i] do
          incr i
        done;
        let is_float = ref false in
        if !i < n && src.[!i] = '.' && !i + 1 < n && is_digit src.[!i + 1] then (
          is_float := true;
          incr i;
          while !i < n && is_digit src.[!i] do
            incr i
          done);
        (* scientific notation (`1e10`, `1.5e-3`, `2E+5`) -- only consumed
           when `e`/`E` is actually followed by an optional sign then a
           digit; otherwise leave it alone so e.g. `3e` still lexes as
           TINT 3 followed by the identifier `e`, same as before. *)
        (if !i < n && (src.[!i] = 'e' || src.[!i] = 'E') then
           let save = !i in
           let j = ref (!i + 1) in
           if !j < n && (src.[!j] = '+' || src.[!j] = '-') then incr j;
           if !j < n && is_digit src.[!j] then (
             is_float := true;
             i := !j;
             while !i < n && is_digit src.[!i] do
               incr i
             done)
           else i := save);
        let text = String.sub src start (!i - start) in
        if !is_float then emit (TFLOAT (float_of_string text)) else emit (TINT (int_of_string text)))
      else if is_ident_start c then (
        let start = !i in
        while !i < n && is_alnum src.[!i] do
          incr i
        done;
        let word = intern (String.sub src start (!i - start)) in
        if List.mem word keywords then emit (TKW word) else emit (TIDENT word))
      else if c = '"' then (
        (* real Julia's `"""..."""` (docstrings, and any string that wants
           embedded unescaped quotes) -- three quotes open, three quotes
           close, everything else (escapes, `$` interpolation) works
           identically to a plain single-quoted string. Detected here
           rather than given its own top-level branch since both start
           with the same '"' and share the whole escape-handling loop. *)
        let triple = !i + 2 < n && src.[!i + 1] = '"' && src.[!i + 2] = '"' in
        i := !i + (if triple then 3 else 1);
        let is_close () =
          if triple then !i + 2 < n && src.[!i] = '"' && src.[!i + 1] = '"' && src.[!i + 2] = '"'
          else src.[!i] = '"'
        in
        let buf = Buffer.create 16 in
        while !i < n && not (is_close ()) do
          if src.[!i] = '$' && !i + 1 < n && src.[!i + 1] = '(' then (
            (* An interpolated expression is real code, and real code contains
               strings -- a ternary picking between two string literals, say.
               Without this, the plain scan below ends the OUTER string at the
               first inner quote, and what's left is a torn fragment that dies
               as an unterminated interpolation. So: copy the whole balanced
               interpolation region verbatim (Parser.interpolate_string
               re-lexes it later, which is where those inner quotes become
               strings again), stepping OVER any nested string rather than
               reading its contents as if they were ours. *)
            Buffer.add_string buf "$(";
            i := !i + 2;
            let depth = ref 1 in
            while !i < n && !depth > 0 do
              let c = src.[!i] in
              if c = '"' then (
                (* a nested string literal: copied whole, so neither a `(`
                   nor a `)` nor a `$` inside it can move our depth *)
                Buffer.add_char buf '"';
                incr i;
                while !i < n && src.[!i] <> '"' do
                  if src.[!i] = '\\' && !i + 1 < n then (
                    Buffer.add_char buf src.[!i];
                    Buffer.add_char buf src.[!i + 1];
                    i := !i + 2)
                  else (
                    if src.[!i] = '\n' then (
                      incr line;
                      line_start := !i + 1);
                    Buffer.add_char buf src.[!i];
                    incr i)
                done;
                if !i < n then (
                  Buffer.add_char buf '"';
                  incr i))
              else (
                if c = '(' then incr depth else if c = ')' then decr depth;
                if c = '\n' then (
                  incr line;
                  line_start := !i + 1);
                (* the closing paren of the region is part of it, and the
                   depth already hit 0 -- add it and step past *)
                Buffer.add_char buf c;
                incr i)
            done;
            if !depth > 0 then failwith "unterminated $(...) in string interpolation")
          else if src.[!i] = '\\' && !i + 1 < n then (
            (match src.[!i + 1] with
            | '"' -> Buffer.add_char buf '"'
            | '\\' -> Buffer.add_char buf '\\'
            | 'n' -> Buffer.add_char buf '\n'
            | 't' -> Buffer.add_char buf '\t'
            (* NOT a literal '$' here on purpose: interpolate_string runs
               after lexing and can't tell "user typed \$" apart from "user
               typed a live $" once both are the same byte. '\001' is a
               sentinel only interpolate_string understands, translated back
               to a literal '$' there without ever being treated as a trigger. *)
            | '$' -> Buffer.add_char buf '\001'
            | c -> Buffer.add_char buf c);
            i := !i + 2)
          else (
            (* a string can embed real newlines (this always could, even
               before triple-quoting existed) -- keep line/col tracking
               accurate for whatever comes after it *)
            if src.[!i] = '\n' then (
              incr line;
              line_start := !i + 1);
            Buffer.add_char buf src.[!i];
            incr i)
        done;
        let s = Buffer.contents buf in
        i := !i + if triple then 3 else 1;
        emit (TSTR s))
      else (
        let three = if !i + 2 < n then Some (String.sub src !i 3) else None in
        let two = if !i + 1 < n then Some (String.sub src !i 2) else None in
        match three with
        | Some ((">>>" | "===" | "!==" | ">>=") as op) ->
          emit (TOP op);
          i := !i + 3
        | Some "\xe2\x89\xa4" ->
          (* unicode <= : U+2264, real Julia's own preferred spelling --
             just an alias at the lexer level, so nothing downstream needs
             to know it exists. Found necessary running JuliaMath/Primes.jl
             verbatim (see the real-library section in the README). *)
          emit (TOP "<=");
          i := !i + 3
        | Some "\xe2\x89\xa5" ->
          (* unicode >= : U+2265, same as above *)
          emit (TOP ">=");
          i := !i + 3
        | Some "\xe2\x8b\x85" ->
          (* unicode dot operator U+22C5, real LinearAlgebra's `dot` product
             infix (`a ⋅ b`) -- kept as its own operator, not aliased to an
             existing one like ≤/≥ above, since it has genuinely different
             (Vector,Vector)-only semantics from plain `*` *)
          emit (TOP "\xe2\x8b\x85");
          i := !i + 3
        | Some "\xe2\x8a\xbb" ->
          (* unicode xor U+22BB, real Julia's bitwise/logical `⊻` -- kept as
             its own operator, same as ⋅ above (not an alias like ≤/≥) *)
          emit (TOP "\xe2\x8a\xbb");
          i := !i + 3
        | _ -> (
          match two with
          | Some "\xc3\xb7" ->
            (* unicode division U+00F7, real Julia's own spelling of `div`
               (integer division, truncated) -- two bytes, not three like
               the operators above, so it belongs in this branch *)
            emit (TOP "\xc3\xb7");
            i := !i + 2
          (* `=>`, real Julia's Pair -- how a Dict literal is written
             (`Dict("a" => 1)`). Two bytes, and never ambiguous with `=`
             followed by `>`: Julia has no such sequence. *)
          | Some ("=>" as op)
          | Some ("<:" as op) | Some ("::" as op) | Some ("==" as op) | Some ("!=" as op)
          | Some ("<=" as op) | Some (">=" as op) | Some ("->" as op) | Some ("&&" as op)
          | Some ("||" as op) | Some ("+=" as op) | Some ("-=" as op) | Some ("*=" as op)
          | Some ("/=" as op)
          (* plain (non-logical) bitshift, distinct from `>>>` above -- found
             necessary running JuliaMath/Primes.jl verbatim, same as ≤/≥ *)
          | Some ("<<" as op) | Some (">>" as op)
          (* `//`, real Julia's exact-Rational constructor (`1 // 2`) --
             never ambiguous with a line comment, since Julia's own comment
             syntax is `#`, not `//` *)
          | Some ("//" as op) ->
            emit (TOP op);
            i := !i + 2
          | _ ->
            emit (TOP (String.make 1 c));
            incr i))
    done;
    ignore peekc;
    List.rev ((TEOF, !space_before, !line, !i - !line_start + 1) :: !toks)
