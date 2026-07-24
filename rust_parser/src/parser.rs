//! Mirrors `Parser` in `bin/main.ml` -- a full port of Tsubaki's grammar
//! (started as a deliberately narrow "frozen snapshot" for differential
//! testing; grew to cover the whole grammar -- see rust_parser/README.md for
//! that history). Ported function-for-function from the OCaml
//! recursive-descent parser, including the whitespace-sensitive matrix-row
//! dance (both the first row AND every subsequent one -- the OCaml source
//! had a real bug where only the first row got this treatment; this mirrors
//! the FIXED version, post-dating that bugfix, not the original).

use crate::ast::{intern, BinOpKind, DepthCache, Expr, Param, Stmt, TField};
use crate::lexer::{Lexed, Token};

#[derive(Debug)]
pub struct ParseError(pub String);

pub type PResult<T> = Result<T, ParseError>;

pub struct State {
    toks: Vec<Token>,
    space_before: Vec<bool>,
    line: Vec<usize>,
    col: Vec<usize>,
    pos: usize,
}

impl State {
    pub fn new(lexed: Vec<Lexed>) -> Self {
        let toks = lexed.iter().map(|l| l.tok.clone()).collect();
        let space_before = lexed.iter().map(|l| l.space_before).collect();
        let line = lexed.iter().map(|l| l.line).collect();
        let col = lexed.iter().map(|l| l.col).collect();
        State { toks, space_before, line, col, pos: 0 }
    }

    fn peek(&self) -> &Token {
        &self.toks[self.pos]
    }

    fn peek_at(&self, offset: usize) -> &Token {
        let i = self.pos + offset;
        if i < self.toks.len() {
            &self.toks[i]
        } else {
            &self.toks[self.toks.len() - 1]
        }
    }

    fn advance(&mut self) {
        if self.pos < self.toks.len() - 1 {
            self.pos += 1;
        }
    }

    fn save(&self) -> usize {
        self.pos
    }

    fn restore(&mut self, p: usize) {
        self.pos = p;
    }

    /// out-of-range defaults to true, same as "nothing tightly bound here"
    /// -- matches the OCaml `space_before` accessor exactly.
    fn space_before_at(&self, i: usize) -> bool {
        i >= self.space_before.len() || self.space_before[i]
    }

    fn ctx(&self) -> String {
        let (line, col) = (self.line[self.pos], self.col[self.pos]);
        format!("line {}, col {} (pos={})", line, col, self.pos)
    }

    fn at_op(&self, op: &str) -> bool {
        matches!(self.peek(), Token::Op(o) if o == op)
    }

    fn at_kw(&self, kw: &str) -> bool {
        matches!(self.peek(), Token::Kw(k) if k == kw)
    }

    fn at_eof(&self) -> bool {
        matches!(self.peek(), Token::Eof)
    }

    /// mirrors OCaml's `is_block_end`: the tokens that close a statement
    /// list.
    fn is_block_end(&self) -> bool {
        self.at_kw("end")
            || self.at_kw("else")
            || self.at_kw("elseif")
            || self.at_kw("catch")
            || self.at_eof()
    }

    /// is the CURRENT token the start of a real statement (a declaration or
    /// a control-flow block), as opposed to an expression? Used only to
    /// decide whether `@name ...` is wrapping a whole statement (`@inline
    /// function f(x) ... end`) rather than a trailing expression (`@assert
    /// x > 0`) -- mirrors `bin/parser.ml`'s `at_stmt_start` exactly.
    fn at_stmt_start(&self) -> bool {
        self.at_kw("struct")
            || self.at_kw("abstract")
            || self.at_kw("if")
            || self.at_kw("for")
            || self.at_kw("while")
            || self.at_kw("try")
            || self.at_kw("mutable")
            || self.at_kw("module")
            || self.at_kw("macro")
            || (self.at_kw("function") && matches!(self.peek_at(1), Token::Ident(_)))
    }

    fn expect_kw(&mut self, kw: &str) -> PResult<()> {
        if self.at_kw(kw) {
            self.advance();
            Ok(())
        } else {
            Err(ParseError(format!("expected '{}' at {}", kw, self.ctx())))
        }
    }

    fn expect_op(&mut self, op: &str) -> PResult<()> {
        if self.at_op(op) {
            self.advance();
            Ok(())
        } else {
            Err(ParseError(format!("expected '{}' at {}", op, self.ctx())))
        }
    }

    fn ident(&mut self) -> PResult<String> {
        match self.peek().clone() {
            Token::Ident(s) => {
                self.advance();
                Ok(s)
            }
            _ => Err(ParseError(format!("expected identifier at {}", self.ctx()))),
        }
    }

    /// try a parser; on ParseError, restore position and return None --
    /// mirrors OCaml's `try_parse`.
    fn try_parse<T>(&mut self, f: impl FnOnce(&mut Self) -> PResult<T>) -> Option<T> {
        let p = self.save();
        match f(self) {
            Ok(v) => Some(v),
            Err(_) => {
                self.restore(p);
                None
            }
        }
    }
}

/// ":" is deliberately absent -- ranges aren't a normal left-associative
/// binary operator, they're parsed specially by `parse_range` below, since
/// `a:b:c` has three operands, not two. Same table as OCaml's `prec`.
fn prec(op: &str) -> i32 {
    match op {
        "||" => 0,
        "&&" => 1,
        "==" | "!=" | "<" | "<=" | ">" | ">=" => 2,
        "+" | "-" => 3,
        "*" | "/" | "%" | ">>>" | "\u{22c5}" | "\\" => 4,
        "^" => 5,
        _ => -1,
    }
}

pub fn parse_expr(st: &mut State) -> PResult<Expr> {
    let lhs = parse_range(st)?;
    if st.at_op("?") {
        st.advance();
        let t = parse_binary(st, 0)?;
        st.expect_op(":")?;
        let f = parse_expr(st)?;
        Ok(Expr::Ternary(Box::new(lhs), Box::new(t), Box::new(f)))
    } else if st.at_op("=") {
        st.advance();
        let rhs = parse_expr(st)?;
        assignment_target(lhs, rhs, st)
    } else {
        match st.peek().clone() {
            Token::Op(op) if op == "+=" || op == "-=" || op == "*=" || op == "/=" => {
                st.advance();
                let rhs = parse_expr(st)?;
                let base_op = BinOpKind::parse(&op[..1]);
                let combined = Expr::BinOp(base_op, Box::new(lhs.clone()), Box::new(rhs));
                assignment_target(lhs, combined, st)
            }
            _ => Ok(lhs),
        }
    }
}

/// mirrors `bin/parser.ml`'s shared assignment-target match (used by both
/// bare `=` and the `+=`/`-=`/`*=`/`/=` compound forms): a bare variable
/// becomes `Assign`, a field target becomes `FieldAssign`, an index
/// expression becomes `IndexAssign`, an interpolation splice (`$(target) =
/// rhs`, only meaningful inside a quote) becomes `InterpAssign`; anything
/// else is a parse error.
fn assignment_target(lhs: Expr, rhs: Expr, st: &State) -> PResult<Expr> {
    match lhs {
        Expr::Var(n, _) => Ok(Expr::Assign(n, Box::new(rhs), DepthCache::new())),
        Expr::Field(o, f) => Ok(Expr::FieldAssign(o, f, Box::new(rhs))),
        Expr::Index(o, idx) => Ok(Expr::IndexAssign(o, idx, Box::new(rhs))),
        Expr::Interp(inner) => Ok(Expr::InterpAssign(inner, Box::new(rhs))),
        _ => Err(ParseError(format!("invalid assignment target at {}", st.ctx()))),
    }
}

/// a:b (step 1) or a:step:b -- each operand at the normal binary level,
/// same as OCaml's `parse_range`.
fn parse_range(st: &mut State) -> PResult<Expr> {
    let lo = parse_binary(st, 0)?;
    if st.at_op(":") {
        st.advance();
        let mid = parse_binary(st, 0)?;
        if st.at_op(":") {
            st.advance();
            let hi = parse_binary(st, 0)?;
            Ok(Expr::RangeStep(Box::new(lo), Box::new(mid), Box::new(hi)))
        } else {
            Ok(Expr::BinOp(BinOpKind::Colon, Box::new(lo), Box::new(mid)))
        }
    } else {
        Ok(lo)
    }
}

fn parse_binary(st: &mut State, min_prec: i32) -> PResult<Expr> {
    let mut lhs = parse_unary(st)?;
    loop {
        match st.peek().clone() {
            Token::Op(op) if prec(&op) >= 0 && prec(&op) >= min_prec => {
                st.advance();
                let rhs = parse_binary(st, prec(&op) + 1)?;
                lhs = Expr::BinOp(BinOpKind::parse(&op), Box::new(lhs), Box::new(rhs));
            }
            _ => break,
        }
    }
    Ok(lhs)
}

/// `parse_binary`'s twin for elements of a whitespace-separated matrix row:
/// identical, except a '+'/'-' with a space before it and none after (tight-
/// bound to the following operand) ends the current element instead of
/// continuing it as a binary op -- real Julia's own rule for telling
/// `[1 -2]` (two elements) apart from `[1 - 2]`/`[1-2]` (one element,
/// ordinary subtraction). Mirrors OCaml's `parse_matrix_elem` exactly.
fn parse_matrix_elem(st: &mut State) -> PResult<Expr> {
    fn go(st: &mut State, min_prec: i32) -> PResult<Expr> {
        let mut lhs = parse_unary(st)?;
        loop {
            match st.peek().clone() {
                Token::Op(op) if (op == "+" || op == "-") => {
                    if st.space_before_at(st.pos) && !st.space_before_at(st.pos + 1) {
                        break;
                    }
                    if prec(&op) >= 0 && prec(&op) >= min_prec {
                        st.advance();
                        let rhs = go(st, prec(&op) + 1)?;
                        lhs = Expr::BinOp(BinOpKind::parse(&op), Box::new(lhs), Box::new(rhs));
                    } else {
                        break;
                    }
                }
                Token::Op(op) if prec(&op) >= 0 && prec(&op) >= min_prec => {
                    st.advance();
                    let rhs = go(st, prec(&op) + 1)?;
                    lhs = Expr::BinOp(BinOpKind::parse(&op), Box::new(lhs), Box::new(rhs));
                }
                _ => break,
            }
        }
        Ok(lhs)
    }
    go(st, 0)
}

fn parse_unary(st: &mut State) -> PResult<Expr> {
    if st.at_op("-") {
        st.advance();
        let e = parse_unary(st)?;
        Ok(Expr::BinOp(BinOpKind::Sub, Box::new(Expr::Int(0)), Box::new(e)))
    } else {
        parse_postfix(st)
    }
}

fn parse_postfix(st: &mut State) -> PResult<Expr> {
    let mut e = parse_atom(st)?;
    loop {
        if st.at_op(".") {
            st.advance();
            let f = st.ident()?;
            match (&e, st.at_op("(")) {
                // `Name.member(args)` -- qualified call, single level only
                // (see `Expr::QualifiedCall`'s own comment in ast.rs).
                (Expr::Var(modname, _), true) => {
                    let modname = modname.to_string();
                    st.advance();
                    let (args, kwargs) = parse_arglist(st)?;
                    st.expect_op(")")?;
                    e = Expr::QualifiedCall(modname, f, args, kwargs);
                }
                _ => e = Expr::Field(Box::new(e), f),
            }
        } else if st.at_op("[") {
            st.advance();
            let first = parse_expr(st)?;
            let mut rest = Vec::new();
            while st.at_op(",") {
                st.advance();
                rest.push(parse_expr(st)?);
            }
            st.expect_op("]")?;
            let idx = if rest.is_empty() {
                first
            } else {
                let mut all = vec![first];
                all.extend(rest);
                Expr::Tuple(all)
            };
            e = Expr::Index(Box::new(e), Box::new(idx));
        } else if st.at_op("'") {
            // postfix transpose/adjoint, real Julia's `A'`
            st.advance();
            e = Expr::Call("transpose".to_string(), vec![e], vec![]);
        } else {
            break;
        }
    }
    Ok(e)
}

/// positional args, then optionally `; k1=v1, k2=v2` -- mirrors
/// `bin/parser.ml`'s `parse_arglist` exactly.
fn parse_arglist(st: &mut State) -> PResult<(Vec<Expr>, Vec<(String, Expr)>)> {
    let positional = if st.at_op(")") || st.at_op(";") {
        Vec::new()
    } else {
        let mut acc = Vec::new();
        loop {
            acc.push(parse_expr(st)?);
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        acc
    };
    let kwargs = if st.at_op(";") {
        st.advance();
        if st.at_op(")") {
            Vec::new()
        } else {
            let mut acc = Vec::new();
            loop {
                let n = st.ident()?;
                st.expect_op("=")?;
                let e = parse_expr(st)?;
                acc.push((n, e));
                if st.at_op(",") {
                    st.advance();
                } else {
                    break;
                }
            }
            acc
        }
    } else {
        Vec::new()
    };
    Ok((positional, kwargs))
}

/// a row's remaining elements: comma-separated AND/OR whitespace-separated,
/// freely mixable -- mirrors OCaml's `parse_row_rest`.
fn parse_row_rest(st: &mut State, first_elem: Expr) -> PResult<Vec<Expr>> {
    let mut acc = vec![first_elem];
    loop {
        if st.at_op(",") {
            st.advance();
            acc.push(parse_matrix_elem(st)?);
        } else if st.at_op(";") || st.at_op("]") || st.at_eof() {
            break;
        } else {
            acc.push(parse_matrix_elem(st)?);
        }
    }
    Ok(acc)
}

/// The two-attempt dance every row of a matrix/array literal needs: `first`
/// was already parsed with the FULL expression grammar (which over-consumes
/// a tight-bound leading sign, e.g. `-16.0 -43.0` greedily becoming one
/// subtraction before spacing is ever looked at). Re-parse the whole row
/// from scratch with the whitespace-sensitive grammar instead; fall back to
/// `[first]` alone if that re-parse can't even get going (e.g. `[1:5]`, a
/// lone element using syntax `parse_matrix_elem` doesn't handle).
///
/// Mirrors OCaml's `row1` dance -- and, post-bugfix, the identical dance
/// every later row now also gets (the OCaml source originally only gave
/// this treatment to the first row; every row after it just called
/// `parse_expr` directly for its own first element, silently swallowing a
/// tight-bound sign into an ordinary subtraction and shortening that row by
/// one element -- see README.md's own bugfix entry for the real case that
/// caught it, `[12.0 37.0 -43.0; -16.0 -43.0 98.0]`).
fn parse_row_with_dance(st: &mut State, row_start: usize, first: Expr) -> PResult<Vec<Expr>> {
    let dance = st.try_parse(|st| {
        st.restore(row_start);
        let elem0 = parse_matrix_elem(st)?;
        let row = parse_row_rest(st, elem0)?;
        if st.at_op(";") || st.at_op("]") || st.at_eof() {
            Ok(row)
        } else {
            Err(ParseError("matrix row: not a clean whitespace-sensitive parse".to_string()))
        }
    });
    match dance {
        Some(row) => Ok(row),
        None => Ok(vec![first]),
    }
}

fn parse_atom(st: &mut State) -> PResult<Expr> {
    match st.peek().clone() {
        Token::Int(n) => {
            st.advance();
            Ok(Expr::Int(n))
        }
        Token::Float(f) => {
            st.advance();
            Ok(Expr::Float(f))
        }
        Token::Str(s) => {
            st.advance();
            interpolate_string(&s)
        }
        Token::Kw(ref k) if k == "true" => {
            st.advance();
            Ok(Expr::Bool(true))
        }
        Token::Kw(ref k) if k == "false" => {
            st.advance();
            Ok(Expr::Bool(false))
        }
        Token::Kw(ref k) if k == "nothing" => {
            st.advance();
            Ok(Expr::Nothing)
        }
        Token::Kw(ref k) if k == "end" => {
            st.advance();
            Ok(Expr::End)
        }
        Token::Kw(ref k) if k == "quote" => {
            st.advance();
            let body = parse_stmt_list(st)?;
            st.expect_kw("end")?;
            Ok(Expr::QuoteBlock(body))
        }
        Token::Op(ref o) if o == ":" => {
            st.advance();
            match st.peek().clone() {
                Token::Op(ref p) if p == "(" => {
                    st.advance();
                    let e = parse_expr(st)?;
                    st.expect_op(")")?;
                    Ok(Expr::Quote(Box::new(e)))
                }
                Token::Ident(name) => {
                    st.advance();
                    Ok(Expr::QuoteSymbol(name))
                }
                Token::Op(op) => {
                    // `:+`, `:<`, etc -- quoting a single-token operator as
                    // a Symbol.
                    st.advance();
                    Ok(Expr::QuoteSymbol(op))
                }
                _ => Err(ParseError(format!("expected '(' or a name after ':' at {}", st.ctx()))),
            }
        }
        Token::Op(ref o) if o == "@" => {
            st.advance();
            let name = st.ident()?;
            if st.at_op("(") {
                st.advance();
                let (args, _kwargs) = parse_arglist(st)?;
                st.expect_op(")")?;
                Ok(Expr::MacroCall(name, args))
            } else {
                // bareword form: @name expr -- takes ONE trailing expression
                // as the sole argument, matching real Julia's common
                // `@time foo()` / `@assert x > 0` usage.
                let arg = parse_expr(st)?;
                Ok(Expr::MacroCall(name, vec![arg]))
            }
        }
        Token::Op(ref o) if o == "$" => {
            st.advance();
            if st.at_op("(") {
                st.advance();
                let e = parse_expr(st)?;
                st.expect_op(")")?;
                Ok(Expr::Interp(Box::new(e)))
            } else {
                let name = st.ident()?;
                Ok(Expr::Interp(Box::new(Expr::Var(intern(&name), DepthCache::new()))))
            }
        }
        Token::Kw(ref k) if k == "function" => {
            // anonymous, multi-statement form: `function (args) ... end` --
            // as opposed to the named `function name(args) ... end`
            // declaration, which only `parse_stmt` recognizes.
            st.advance();
            let (params, _kwparams) = parse_params(st)?;
            let body = parse_stmt_list(st)?;
            st.expect_kw("end")?;
            Ok(Expr::Lambda(params.into_iter().map(|p| p.pname).collect(), body))
        }
        Token::Op(ref o) if o == "(" => {
            // try `(a, b) -> expr` (a multi-arg lambda) before falling back
            // to a plain parenthesized expression.
            let names = st.try_parse(|st| {
                st.advance();
                let mut names = Vec::new();
                if !st.at_op(")") {
                    loop {
                        names.push(st.ident()?);
                        if st.at_op(",") {
                            st.advance();
                        } else {
                            break;
                        }
                    }
                }
                st.expect_op(")")?;
                st.expect_op("->")?;
                Ok(names)
            });
            match names {
                Some(names) => {
                    let body = parse_expr(st)?;
                    Ok(Expr::Lambda(names, vec![Stmt::Expr(body)]))
                }
                None => {
                    st.advance();
                    let e = parse_expr(st)?;
                    st.expect_op(")")?;
                    Ok(e)
                }
            }
        }
        Token::Op(ref o) if o == "[" => {
            st.advance();
            if st.at_op("]") {
                st.advance();
                return Ok(Expr::ArrayLit(vec![]));
            }
            let start_pos = st.save();
            let first = parse_expr(st)?;
            if st.at_kw("for") {
                st.advance();
                // one or more comma-separated `var in iter` / `var = iter`
                // clauses -- real Julia treats "in" and "=" as fully
                // interchangeable here, so mandel's verbatim
                // `for i = ..., r = ...` parses unmodified. Mirrors
                // `bin/parser.ml`'s own comprehension clause parsing
                // exactly.
                let mut clauses = Vec::new();
                loop {
                    let var = st.ident()?;
                    if st.at_op("=") {
                        st.advance();
                    } else {
                        st.expect_kw("in")?;
                    }
                    let iter = parse_expr(st)?;
                    clauses.push((var, iter));
                    if st.at_op(",") {
                        st.advance();
                    } else {
                        break;
                    }
                }
                st.expect_op("]")?;
                return Ok(Expr::Comprehension(Box::new(first), clauses));
            }
            let row1 = parse_row_with_dance(st, start_pos, first)?;
            if st.at_op(";") {
                let mut rows = vec![row1];
                while st.at_op(";") {
                    st.advance();
                    let row_start = st.save();
                    let first_e = parse_expr(st)?;
                    let row = parse_row_with_dance(st, row_start, first_e)?;
                    rows.push(row);
                }
                st.expect_op("]")?;
                let width = rows[0].len();
                if !rows.iter().all(|r| r.len() == width) {
                    return Err(ParseError("matrix literal: all rows must have the same length".to_string()));
                }
                Ok(Expr::MatrixLit(rows))
            } else {
                st.expect_op("]")?;
                Ok(Expr::ArrayLit(row1))
            }
        }
        Token::Ident(name) => {
            st.advance();
            if name == "Array" && st.at_op("{") {
                // `Array{T}()` -- the real, declared-element-type
                // constructor, a distinct grammar shape from a plain call
                // since "Array{T}" isn't a single identifier token.
                st.advance();
                let elem_ty = st.ident()?;
                st.expect_op("}")?;
                st.expect_op("(")?;
                st.expect_op(")")?;
                Ok(Expr::TypedArrayNew(elem_ty))
            } else if name == "new" && st.at_op("{") {
                // `new{T}(...)` inside a struct's own inner constructor --
                // the `{T}` names Tsubaki's automatic type-param inference
                // already computes on its own, so it's parsed and thrown
                // away here, same as a constructor's own `{T}` suffix.
                st.advance();
                loop {
                    st.ident()?;
                    if st.at_op(",") {
                        st.advance();
                    } else {
                        break;
                    }
                }
                st.expect_op("}")?;
                st.expect_op("(")?;
                let (args, kwargs) = parse_arglist(st)?;
                st.expect_op(")")?;
                Ok(Expr::Call("new".to_string(), args, kwargs))
            } else if st.at_op("->") {
                st.advance();
                let body = parse_expr(st)?;
                Ok(Expr::Lambda(vec![name], vec![Stmt::Expr(body)]))
            } else if st.at_op("(") {
                st.advance();
                let (args, kwargs) = parse_arglist(st)?;
                st.expect_op(")")?;
                Ok(Expr::Call(name, args, kwargs))
            } else {
                Ok(Expr::Var(intern(&name), DepthCache::new()))
            }
        }
        _ => Err(ParseError(format!("expected expression at {}", st.ctx()))),
    }
}

/// string interpolation: `"hi $name"` -> `EStr "hi " + string(name)`, and
/// `"hi $(expr)"` -> the parenthesized part is re-tokenized and re-parsed as
/// a full expression. Mirrors `bin/parser.ml`'s `interpolate_string`
/// exactly, including the `\u{1}` sentinel (see lexer.rs) translating back
/// to a literal `$` for an escaped `\$`.
fn interpolate_string(s: &str) -> PResult<Expr> {
    let b = s.as_bytes();
    let n = b.len();
    let is_ident_start = |c: u8| c.is_ascii_alphabetic() || c == b'_';
    let is_ident = |c: u8| is_ident_start(c) || c.is_ascii_digit();
    let mut pieces: Vec<Expr> = Vec::new();
    let mut buf = String::new();
    let mut i = 0usize;
    while i < n {
        if b[i] == b'$' && i + 1 < n && b[i + 1] == b'(' {
            if !buf.is_empty() {
                pieces.push(Expr::Str(std::mem::take(&mut buf)));
            }
            let mut depth = 1i32;
            let mut j = i + 2;
            while j < n && depth > 0 {
                if b[j] == b'(' {
                    depth += 1;
                } else if b[j] == b')' {
                    depth -= 1;
                }
                if depth > 0 {
                    j += 1;
                }
            }
            if depth != 0 {
                return Err(ParseError("unterminated $(...) in string interpolation".to_string()));
            }
            let inner = &s[i + 2..j];
            let lexed = crate::lexer::tokenize(inner);
            let mut inner_st = State::new(lexed);
            let e = parse_expr(&mut inner_st)?;
            pieces.push(Expr::Call("string".to_string(), vec![e], vec![]));
            i = j + 1;
        } else if b[i] == b'$' && i + 1 < n && is_ident_start(b[i + 1]) {
            if !buf.is_empty() {
                pieces.push(Expr::Str(std::mem::take(&mut buf)));
            }
            let mut j = i + 1;
            while j < n && is_ident(b[j]) {
                j += 1;
            }
            let name = s[i + 1..j].to_string();
            pieces.push(Expr::Call("string".to_string(), vec![Expr::Var(intern(&name), DepthCache::new())], vec![]));
            i = j;
        } else if b[i] == 0x01 {
            buf.push('$');
            i += 1;
        } else {
            let ch = s[i..].chars().next().unwrap();
            buf.push(ch);
            i += ch.len_utf8();
        }
    }
    if !buf.is_empty() {
        pieces.push(Expr::Str(buf));
    }
    let mut it = pieces.into_iter();
    match it.next() {
        None => Ok(Expr::Str(String::new())),
        Some(first) => {
            Ok(it.fold(first, |acc, e| Expr::BinOp(BinOpKind::Add, Box::new(acc), Box::new(e))))
        }
    }
}

pub fn parse(src: &str) -> PResult<Expr> {
    let lexed = crate::lexer::tokenize(src);
    let mut st = State::new(lexed);
    let e = parse_expr(&mut st)?;
    if !st.at_eof() {
        return Err(ParseError(format!("trailing tokens at {}", st.ctx())));
    }
    Ok(e)
}

/// mirrors `bin/parser.ml`'s `parse_stmt_list` exactly: statements until a
/// block-ending keyword or EOF, `;` skipped as a no-op separator (a newline
/// needs no special handling -- it's already whitespace to the lexer, same
/// as in the OCaml source).
fn parse_stmt_list(st: &mut State) -> PResult<Vec<Stmt>> {
    let mut acc = Vec::new();
    while !st.is_block_end() {
        if st.at_op(";") {
            st.advance();
        } else {
            acc.push(parse_stmt(st)?);
        }
    }
    Ok(acc)
}

/// a `Union{A,B,C}` type constraint or a plain/parametric type name --
/// mirrors `bin/parser.ml`'s `parse_type_expr` exactly.
fn parse_type_expr(st: &mut State) -> PResult<Vec<String>> {
    let name = st.ident()?;
    if name == "Union" && st.at_op("{") {
        st.advance();
        let mut alts = Vec::new();
        loop {
            alts.push(st.ident()?);
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        st.expect_op("}")?;
        Ok(alts)
    } else if st.at_op("{") {
        // `Box{Int}` or `Dict{Int,String}` -- a concrete instantiation of a
        // parametric type, matched as one single type name (however many
        // parameters), not a union of alternatives.
        st.advance();
        let mut inner = Vec::new();
        loop {
            inner.push(st.ident()?);
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        st.expect_op("}")?;
        Ok(vec![format!("{}{{{}}}", name, inner.join(","))])
    } else {
        Ok(vec![name])
    }
}

fn parse_typed_ident(st: &mut State) -> PResult<(String, Vec<String>)> {
    let name = st.ident()?;
    if st.at_op("::") {
        st.advance();
        let ty = parse_type_expr(st)?;
        Ok((name, ty))
    } else {
        Ok((name, vec!["Any".to_string()]))
    }
}

/// positional params, then optionally `; k1=default1, k2=default2` --
/// mirrors `bin/parser.ml`'s `parse_params` exactly.
fn parse_params(st: &mut State) -> PResult<(Vec<Param>, Vec<(String, Expr)>)> {
    st.expect_op("(")?;
    let params = if st.at_op(")") || st.at_op(";") {
        Vec::new()
    } else {
        let mut acc = Vec::new();
        loop {
            let (n, t) = parse_typed_ident(st)?;
            acc.push(Param { pname: n, ptype: t });
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        acc
    };
    let kwparams = if st.at_op(";") {
        st.advance();
        if st.at_op(")") {
            Vec::new()
        } else {
            let mut acc = Vec::new();
            loop {
                let n = st.ident()?;
                st.expect_op("=")?;
                let d = parse_expr(st)?;
                acc.push((n, d));
                if st.at_op(",") {
                    st.advance();
                } else {
                    break;
                }
            }
            acc
        }
    } else {
        Vec::new()
    };
    st.expect_op(")")?;
    Ok((params, kwparams))
}

/// mirrors `bin/parser.ml`'s `parse_stmt` -- the FULL statement grammar.
fn parse_stmt(st: &mut State) -> PResult<Stmt> {
    if st.at_kw("abstract") {
        st.advance();
        st.expect_kw("type")?;
        let name = st.ident()?;
        let parent = if st.at_op("<:") {
            st.advance();
            Some(st.ident()?)
        } else {
            None
        };
        st.expect_kw("end")?;
        Ok(Stmt::AbstractDecl(name, parent))
    } else if st.at_kw("struct") {
        st.advance();
        parse_struct_body(st, false)
    } else if st.at_kw("mutable") {
        st.advance();
        st.expect_kw("struct")?;
        parse_struct_body(st, true)
    } else if st.at_kw("function") {
        st.advance();
        let name = st.ident()?;
        let (params, kwparams) = parse_params(st)?;
        let body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::FuncDecl(name, params, kwparams, body))
    } else if st.at_kw("if") {
        st.advance();
        parse_if(st)
    } else if st.at_kw("for") {
        st.advance();
        let var = st.ident()?;
        // real Julia treats "in" and "=" as interchangeable in a for-loop
        // header -- mirrors `bin/parser.ml`'s own `SFor` parsing exactly.
        if st.at_op("=") {
            st.advance();
        } else {
            st.expect_kw("in")?;
        }
        let iter = parse_expr(st)?;
        let body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::For(var, iter, body))
    } else if st.at_kw("while") {
        st.advance();
        let cond = parse_expr(st)?;
        let body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::While(cond, body))
    } else if st.at_kw("return") {
        st.advance();
        if st.is_block_end() || st.at_op(";") {
            Ok(Stmt::Return(None))
        } else {
            Ok(Stmt::Return(Some(parse_comma_exprs(st)?)))
        }
    } else if st.at_kw("try") {
        st.advance();
        let body = parse_stmt_list(st)?;
        st.expect_kw("catch")?;
        let catchvar = if let Token::Ident(n) = st.peek().clone() {
            st.advance();
            Some(n)
        } else {
            None
        };
        let catch_body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::Try(body, catchvar, catch_body))
    } else if st.at_kw("module") {
        st.advance();
        let name = st.ident()?;
        let body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::ModuleDecl(name, body))
    } else if st.at_kw("using") {
        st.advance();
        // a dotted path (`using Outer.Inner`) reaches a nested module --
        // joined right back into the same "Outer.Inner." prefix string a
        // nested `module Outer; module Inner; ... end; end` already
        // registers things under.
        let mut parts = vec![st.ident()?];
        while st.at_op(".") {
            st.advance();
            parts.push(st.ident()?);
        }
        Ok(Stmt::Using(parts.join(".")))
    } else if st.at_kw("macro") {
        st.advance();
        let name = st.ident()?;
        st.expect_op("(")?;
        let mut params = Vec::new();
        if !st.at_op(")") {
            loop {
                params.push(st.ident()?);
                if st.at_op(",") {
                    st.advance();
                } else {
                    break;
                }
            }
        }
        st.expect_op(")")?;
        let body = parse_stmt_list(st)?;
        st.expect_kw("end")?;
        Ok(Stmt::MacroDecl(name, params, body))
    } else if st.at_kw("export") {
        st.advance();
        let mut names = Vec::new();
        loop {
            // real Julia can export a macro name (`export @foo`) or an
            // operator (`export +`), not just plain identifiers -- accepted
            // and thrown away just the same.
            let name = if st.at_op("@") {
                st.advance();
                format!("@{}", st.ident()?)
            } else {
                st.ident()?
            };
            names.push(name);
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        Ok(Stmt::Export(names))
    } else if st.at_op("@") {
        // could be `@name(args)`/`@name expr` (same as `MacroCall`, just
        // used as a standalone statement) or `@name` wrapping a WHOLE
        // statement (`@inline function f(x) ... end`, `@inbounds for i in
        // ... end`) -- only the lookahead past the name tells them apart.
        let start_pos = st.save();
        st.advance();
        let name = st.ident()?;
        if st.at_stmt_start() {
            Ok(Stmt::MacroCall(name, Box::new(parse_stmt(st)?)))
        } else {
            st.restore(start_pos);
            Ok(Stmt::Expr(parse_comma_exprs(st)?))
        }
    } else if let Some(targets) = st.try_parse(|st| {
        // destructuring assignment: x, y, ... = rhs -- tried first since it
        // starts the same way a plain expression statement would (an
        // identifier), but needs at least one comma before the "=" to
        // commit. Targets are full lvalues (`parse_postfix`), so
        // `a[i], a[j] = a[j], a[i]` works, not just bare names.
        let t = parse_postfix(st)?;
        if !st.at_op(",") {
            return Err(ParseError("not a destructure".to_string()));
        }
        let mut targets = vec![t];
        while st.at_op(",") {
            st.advance();
            targets.push(parse_postfix(st)?);
        }
        st.expect_op("=")?;
        Ok(targets)
    }) {
        Ok(Stmt::Destructure(targets, parse_comma_exprs(st)?))
    } else if let Some((name, params, kwparams, body_expr)) = st.try_parse(|st| {
        // short-form function definition: `name(params) = expr`.
        let name = st.ident()?;
        let (params, kwparams) = parse_params(st)?;
        st.expect_op("=")?;
        let e = parse_expr(st)?;
        Ok((name, params, kwparams, e))
    }) {
        Ok(Stmt::FuncDecl(name, params, kwparams, vec![Stmt::Expr(body_expr)]))
    } else {
        Ok(Stmt::Expr(parse_comma_exprs(st)?))
    }
}

/// mirrors `bin/parser.ml`'s `parse_struct_body` -- a struct's fields and
/// any inner constructors, up to its own `end`. A `{T, U}` type-parameter
/// list and a `<: Parent` supertype are both optional; an inner
/// constructor's own `{T}`/`where T` clause is parsed and thrown away
/// (Tsubaki infers a parametric constructor's concrete type automatically,
/// see `bin/runtime.ml`'s `Runtime.construct`).
fn parse_struct_body(st: &mut State, mutable: bool) -> PResult<Stmt> {
    let name = st.ident()?;
    let type_params = if st.at_op("{") {
        st.advance();
        let mut ts = Vec::new();
        loop {
            ts.push(st.ident()?);
            if st.at_op(",") {
                st.advance();
            } else {
                break;
            }
        }
        st.expect_op("}")?;
        ts
    } else {
        Vec::new()
    };
    let parent = if st.at_op("<:") {
        st.advance();
        Some(st.ident()?)
    } else {
        None
    };
    let skip_where_clause = |st: &mut State| -> PResult<()> {
        if st.at_kw("where") {
            st.advance();
            if st.at_op("{") {
                st.advance();
                loop {
                    st.ident()?;
                    if st.at_op(",") {
                        st.advance();
                    } else {
                        break;
                    }
                }
                st.expect_op("}")?;
            } else {
                st.ident()?;
            }
        }
        Ok(())
    };
    let mut fields = Vec::new();
    let mut constructors = Vec::new();
    while !st.at_kw("end") {
        if st.at_kw("function") {
            // an inner constructor: `function StructName(...) ... end` or
            // `function StructName{T}(...) where T ... end` -- the name
            // itself isn't checked against the enclosing struct's (nothing
            // else can legally appear in a struct body shaped like this).
            st.advance();
            st.ident()?;
            if st.at_op("{") {
                st.advance();
                loop {
                    st.ident()?;
                    if st.at_op(",") {
                        st.advance();
                    } else {
                        break;
                    }
                }
                st.expect_op("}")?;
            }
            let (params, kwparams) = parse_params(st)?;
            skip_where_clause(st)?;
            let body = parse_stmt_list(st)?;
            st.expect_kw("end")?;
            constructors.push((params, kwparams, body));
        } else {
            let (n, t) = parse_typed_ident(st)?;
            fields.push(TField { fname: n, ftype: t });
        }
    }
    st.expect_kw("end")?;
    Ok(Stmt::StructDecl { mutable, name, parent, type_params, fields, constructors })
}

/// mirrors `bin/parser.ml`'s `parse_comma_exprs`: `a, b, ...` becomes a
/// `Tuple` -- used by `return a, b` and by a destructuring assignment's
/// right side.
fn parse_comma_exprs(st: &mut State) -> PResult<Expr> {
    let first = parse_expr(st)?;
    if st.at_op(",") {
        let mut elems = vec![first];
        while st.at_op(",") {
            st.advance();
            elems.push(parse_expr(st)?);
        }
        Ok(Expr::Tuple(elems))
    } else {
        Ok(first)
    }
}

/// mirrors `bin/parser.ml`'s `parse_if` -- an `elseif` chain plus an
/// optional trailing `else`, one shared `end`.
fn parse_if(st: &mut State) -> PResult<Stmt> {
    let cond = parse_expr(st)?;
    let body = parse_stmt_list(st)?;
    let mut branches = vec![(cond, body)];
    let mut else_body = None;
    loop {
        if st.at_kw("elseif") {
            st.advance();
            let c = parse_expr(st)?;
            let b = parse_stmt_list(st)?;
            branches.push((c, b));
        } else if st.at_kw("else") {
            st.advance();
            else_body = Some(parse_stmt_list(st)?);
            break;
        } else {
            break;
        }
    }
    st.expect_kw("end")?;
    Ok(Stmt::If(branches, else_body))
}

/// entry point for a whole statement-level program (as opposed to `parse`'s
/// single bare expression) -- see rust_parser/README.md for why these are
/// two separate CLI modes rather than one.
pub fn parse_program(src: &str) -> PResult<Vec<Stmt>> {
    let lexed = crate::lexer::tokenize(src);
    let mut st = State::new(lexed);
    let prog = parse_stmt_list(&mut st)?;
    if !st.at_eof() {
        return Err(ParseError(format!("trailing tokens at {}", st.ctx())));
    }
    Ok(prog)
}
