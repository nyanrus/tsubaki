//! Mirrors `Lexer` in `bin/main.ml` (OCaml is the canonical grammar; this is
//! a frozen snapshot, not a co-evolving twin -- see rust_parser/README.md).
//! Ported field-for-field from the OCaml `tokenize` function: same keyword
//! list, same 1/2/3-char + unicode operator table, same triple-quoted
//! string handling, same scientific-notation number rule, same
//! `space_before`/`(line, col)` tracking per token (needed by the parser's
//! own whitespace-sensitive matrix-literal rule).

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    Int(i64),
    Float(f64),
    Str(String),
    Ident(String),
    Kw(String),
    Op(String),
    Eof,
}

pub const KEYWORDS: &[&str] = &[
    "function", "end", "struct", "mutable", "abstract", "type", "if", "elseif", "else", "for",
    "while", "true", "false", "nothing", "in", "return", "try", "catch", "module", "using",
    "macro", "quote", "export", "where",
];

#[derive(Debug, Clone)]
pub struct Lexed {
    pub tok: Token,
    pub space_before: bool,
    pub line: usize,
    pub col: usize,
}

fn is_digit(c: u8) -> bool {
    c.is_ascii_digit()
}

fn is_alpha(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_' || c == b'!'
}

fn is_alnum(c: u8) -> bool {
    is_alpha(c) || is_digit(c)
}

/// Same convention as the OCaml lexer: `space_before` is true for the very
/// first token (no real predecessor), then tracks whether whitespace/a
/// comment directly preceded THIS token.
pub fn tokenize(src: &str) -> Vec<Lexed> {
    let b = src.as_bytes();
    let n = b.len();
    let mut i = 0usize;
    let mut line = 1usize;
    let mut line_start = 0usize;
    let mut space_before = true;
    let mut out = Vec::new();

    macro_rules! emit {
        ($tok:expr, $cur_line:expr, $cur_col:expr) => {{
            out.push(Lexed { tok: $tok, space_before, line: $cur_line, col: $cur_col });
            space_before = false;
        }};
    }

    while i < n {
        let cur_line = line;
        let cur_col = i - line_start + 1;
        let c = b[i];
        if c == b' ' || c == b'\t' || c == b'\r' {
            space_before = true;
            i += 1;
        } else if c == b'\n' {
            space_before = true;
            i += 1;
            line += 1;
            line_start = i;
        } else if c == b'#' {
            space_before = true;
            while i < n && b[i] != b'\n' {
                i += 1;
            }
        } else if is_digit(c) {
            let start = i;
            while i < n && is_digit(b[i]) {
                i += 1;
            }
            let mut is_float = false;
            if i < n && b[i] == b'.' && i + 1 < n && is_digit(b[i + 1]) {
                is_float = true;
                i += 1;
                while i < n && is_digit(b[i]) {
                    i += 1;
                }
            }
            // scientific notation (1e10, 1.5e-3, 2E+5) -- only consumed when
            // e/E is followed by an optional sign then a digit, same rule
            // as the OCaml lexer (so `3e` still lexes as Int(3), Ident("e")).
            if i < n && (b[i] == b'e' || b[i] == b'E') {
                let save = i;
                let mut j = i + 1;
                if j < n && (b[j] == b'+' || b[j] == b'-') {
                    j += 1;
                }
                if j < n && is_digit(b[j]) {
                    is_float = true;
                    i = j;
                    while i < n && is_digit(b[i]) {
                        i += 1;
                    }
                } else {
                    i = save;
                }
            }
            let text = std::str::from_utf8(&b[start..i]).unwrap();
            if is_float {
                emit!(Token::Float(text.parse().unwrap()), cur_line, cur_col);
            } else {
                emit!(Token::Int(text.parse().unwrap()), cur_line, cur_col);
            }
        } else if is_alpha(c) {
            let start = i;
            while i < n && is_alnum(b[i]) {
                i += 1;
            }
            let word = std::str::from_utf8(&b[start..i]).unwrap().to_string();
            if KEYWORDS.contains(&word.as_str()) {
                emit!(Token::Kw(word), cur_line, cur_col);
            } else {
                emit!(Token::Ident(word), cur_line, cur_col);
            }
        } else if c == b'"' {
            let triple = i + 2 < n && b[i + 1] == b'"' && b[i + 2] == b'"';
            i += if triple { 3 } else { 1 };
            let is_close = |i: usize, b: &[u8]| -> bool {
                if triple {
                    i + 2 < n && b[i] == b'"' && b[i + 1] == b'"' && b[i + 2] == b'"'
                } else {
                    i < n && b[i] == b'"'
                }
            };
            let mut buf = String::new();
            while i < n && !is_close(i, b) {
                if b[i] == b'\\' && i + 1 < n {
                    match b[i + 1] {
                        b'"' => buf.push('"'),
                        b'\\' => buf.push('\\'),
                        b'n' => buf.push('\n'),
                        b't' => buf.push('\t'),
                        // NOT a literal '$' here on purpose, same reasoning
                        // as the OCaml lexer: '\u{1}' is a sentinel the
                        // interpolation pass (`interpolate_string`,
                        // parser.rs) needs to distinguish "user typed \$"
                        // from "user typed a live $", translated back to a
                        // literal '$' there.
                        b'$' => buf.push('\u{1}'),
                        other => buf.push(other as char),
                    }
                    i += 2;
                } else {
                    if b[i] == b'\n' {
                        line += 1;
                        line_start = i + 1;
                    }
                    buf.push(b[i] as char);
                    i += 1;
                }
            }
            i += if triple { 3 } else { 1 };
            emit!(Token::Str(buf), cur_line, cur_col);
        } else {
            let three = if i + 2 < n { Some(&src[i..i + 3]) } else { None };
            let two = if i + 1 < n { Some(&src[i..i + 2]) } else { None };
            if three == Some(">>>") {
                emit!(Token::Op(">>>".to_string()), cur_line, cur_col);
                i += 3;
            } else if three == Some("\u{2264}") {
                // unicode <=, U+2264 -- aliased at the lexer level, same as
                // the OCaml lexer
                emit!(Token::Op("<=".to_string()), cur_line, cur_col);
                i += 3;
            } else if three == Some("\u{2265}") {
                // unicode >=, U+2265
                emit!(Token::Op(">=".to_string()), cur_line, cur_col);
                i += 3;
            } else if three == Some("\u{22c5}") {
                // unicode dot operator U+22C5, real LinearAlgebra's `dot`
                emit!(Token::Op("\u{22c5}".to_string()), cur_line, cur_col);
                i += 3;
            } else if matches!(
                two,
                Some("<:") | Some("::") | Some("==") | Some("!=") | Some("<=") | Some(">=")
                    | Some("->") | Some("&&") | Some("||") | Some("+=") | Some("-=") | Some("*=")
                    | Some("/=")
            ) {
                emit!(Token::Op(two.unwrap().to_string()), cur_line, cur_col);
                i += 2;
            } else {
                emit!(Token::Op((c as char).to_string()), cur_line, cur_col);
                i += 1;
            }
        }
    }
    out.push(Lexed { tok: Token::Eof, space_before: true, line, col: i - line_start + 1 });
    out
}
