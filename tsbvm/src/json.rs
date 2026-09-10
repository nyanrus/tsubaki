//! The boundary: Tsubaki values as JSON.
//!
//! The OCaml runtime crosses into JS values directly (Runtime.js_of_value and
//! value_of_js). This VM has only bytes, so the same meaning is carried as
//! JSON text instead. What has to match is the MEANING, not the mechanism --
//! a host that calls `setup()` must see the same thing either way:
//!
//!   Int / Float      number        a number comes back Int when its value is
//!   Bool             boolean       a whole one (that is what the OCaml side's
//!   String           string        value_of_js_shallow does, and JS has only
//!   nothing          null          the one number type to tell them apart by)
//!   Array/Vector     array
//!   Tuple, Pair      array         a Pair crosses as [first, second]
//!   Dict             object        keys are the key's text
//!   struct           object        with "__type": the struct's own name
//!
//! Coming back the other way, an object is a Dict -- including one that
//! carries `__type`. That asymmetry is the OCaml side's too: a struct goes
//! out as data and returns as data, never as a struct again.
//!
//! A closure does not cross. On the OCaml side it can (it becomes a real JS
//! function), but a drop's logic runs in a worker and what leaves a worker is
//! structured-cloned, which a function never survives. So: an error, not a
//! quiet stand-in.

use crate::vm::{float_repr, show, tag, StructVal, Value};
use std::cell::RefCell;
use std::rc::Rc;

pub fn to_json(v: &Value) -> Result<String, String> {
    let mut s = String::new();
    write(v, &mut s)?;
    Ok(s)
}

fn write_str(x: &str, out: &mut String) {
    out.push('"');
    for c in x.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write(v: &Value, out: &mut String) -> Result<(), String> {
    match v {
        Value::Int(n) => out.push_str(&n.to_string()),
        Value::Float(f) => {
            if f.is_finite() {
                out.push_str(&float_repr(*f))
            } else {
                // JSON has no NaN or Inf; null is what JSON.stringify does too
                out.push_str("null")
            }
        }
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Str(s) => write_str(s, out),
        // a Symbol is its name -- that is what it is on the JS side of a Dict
        // key already
        Value::Sym(s) => write_str(s, out),
        Value::Nothing => out.push_str("null"),
        Value::Arr(a) => {
            out.push('[');
            for (i, x) in a.borrow().iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write(x, out)?;
            }
            out.push(']');
        }
        Value::Tuple(t) => {
            out.push('[');
            for (i, x) in t.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write(x, out)?;
            }
            out.push(']');
        }
        Value::Pair(p) => {
            out.push('[');
            write(&p.0, out)?;
            out.push(',');
            write(&p.1, out)?;
            out.push(']');
        }
        Value::Dict(d) => {
            out.push('{');
            for (i, (k, val)) in d.borrow().iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                // the key's text: a String or Symbol is itself, anything else
                // is how it prints
                match k {
                    Value::Str(s) | Value::Sym(s) => write_str(s, out),
                    other => write_str(&show(other), out),
                }
                out.push(':');
                write(val, out)?;
            }
            out.push('}');
        }
        Value::Struct(sv) => {
            out.push_str("{\"__type\":");
            write_str(&sv.kind, out);
            for (n, val) in sv.fields.borrow().iter() {
                out.push(',');
                write_str(n, out);
                out.push(':');
                write(val, out)?;
            }
            out.push('}');
        }
        Value::Range(a, s, b) => {
            // a range crosses as the numbers it stands for -- a host has no
            // Range of its own to receive
            out.push('[');
            let mut i = *a;
            let mut first = true;
            while if *s > 0 { i <= *b } else { i >= *b } {
                if !first {
                    out.push(',');
                }
                first = false;
                out.push_str(&i.to_string());
                i += *s;
            }
            out.push(']');
        }
        Value::FRange(a, st, b) => {
            // 同じ -- 立ち会う数を並べて渡す
            out.push('[');
            for (k, x) in crate::vm::frange_values(*a, *st, *b).iter().enumerate() {
                if k > 0 {
                    out.push(',');
                }
                out.push_str(&float_repr(*x));
            }
            out.push(']');
        }
        Value::Closure(_) | Value::Generic(_) => {
            return Err("a function cannot cross this boundary (it would have to be cloned)".into())
        }
        Value::Module(n) => {
            return Err(format!("a module ({n}) cannot cross this boundary -- pass one of its members"))
        }
    }
    Ok(())
}

// --- reading back ----------------------------------------------------------

struct P<'a> {
    b: &'a [u8],
    i: usize,
}

pub fn from_json(s: &str) -> Result<Value, String> {
    let mut p = P { b: s.as_bytes(), i: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i != p.b.len() {
        return Err(format!("trailing text at byte {}", p.i));
    }
    Ok(v)
}

impl<'a> P<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> Result<(), String> {
        if self.i < self.b.len() && self.b[self.i] == c {
            self.i += 1;
            Ok(())
        } else {
            Err(format!("expected {} at byte {}", c as char, self.i))
        }
    }

    fn lit(&mut self, word: &str) -> bool {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            true
        } else {
            false
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        self.ws();
        if self.i >= self.b.len() {
            return Err("unexpected end".into());
        }
        let c = self.b[self.i];
        if c == b'n' && self.lit("null") {
            return Ok(Value::Nothing);
        }
        if c == b't' && self.lit("true") {
            return Ok(Value::Bool(true));
        }
        if c == b'f' && self.lit("false") {
            return Ok(Value::Bool(false));
        }
        match c {
            b'"' => Ok(Value::Str(Rc::from(self.string()?.as_str()))),
            b'[' => {
                self.i += 1;
                let mut xs = Vec::new();
                self.ws();
                if self.i < self.b.len() && self.b[self.i] == b']' {
                    self.i += 1;
                } else {
                    loop {
                        xs.push(self.value()?);
                        self.ws();
                        if self.i < self.b.len() && self.b[self.i] == b',' {
                            self.i += 1;
                            continue;
                        }
                        self.eat(b']')?;
                        break;
                    }
                }
                // all numbers stays a numeric Vector, the way an array
                // literal in the language does
                Ok(crate::vm::make_array_lit(xs))
            }
            b'{' => {
                self.i += 1;
                let mut d: Vec<(Value, Value)> = Vec::new();
                self.ws();
                if self.i < self.b.len() && self.b[self.i] == b'}' {
                    self.i += 1;
                } else {
                    loop {
                        self.ws();
                        let k = self.string()?;
                        self.ws();
                        self.eat(b':')?;
                        let v = self.value()?;
                        d.push((Value::Str(Rc::from(k.as_str())), v));
                        self.ws();
                        if self.i < self.b.len() && self.b[self.i] == b',' {
                            self.i += 1;
                            continue;
                        }
                        self.eat(b'}')?;
                        break;
                    }
                }
                // an object is a Dict, `__type` and all -- see this file's
                // own note on why that asymmetry is the right one
                Ok(Value::Dict(Rc::new(RefCell::new(d))))
            }
            _ => self.number(),
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.eat(b'"')?;
        let mut out = String::new();
        loop {
            if self.i >= self.b.len() {
                return Err("unterminated string".into());
            }
            match self.b[self.i] {
                b'"' => {
                    self.i += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.i += 1;
                    let c = *self.b.get(self.i).ok_or("unterminated escape")?;
                    self.i += 1;
                    match c {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'u' => {
                            let hex = std::str::from_utf8(&self.b[self.i..self.i + 4])
                                .map_err(|_| "bad \\u escape")?;
                            let n = u32::from_str_radix(hex, 16).map_err(|_| "bad \\u escape")?;
                            self.i += 4;
                            out.push(char::from_u32(n).unwrap_or('\u{fffd}'));
                        }
                        other => return Err(format!("unknown escape \\{}", other as char)),
                    }
                }
                _ => {
                    // copy one whole UTF-8 character
                    let start = self.i;
                    self.i += 1;
                    while self.i < self.b.len() && (self.b[self.i] & 0xC0) == 0x80 {
                        self.i += 1;
                    }
                    out.push_str(
                        std::str::from_utf8(&self.b[start..self.i]).map_err(|_| "bad UTF-8")?,
                    );
                }
            }
        }
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.i;
        if self.i < self.b.len() && (self.b[self.i] == b'-' || self.b[self.i] == b'+') {
            self.i += 1;
        }
        while self.i < self.b.len()
            && matches!(self.b[self.i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'-' | b'+')
        {
            self.i += 1;
        }
        let text = std::str::from_utf8(&self.b[start..self.i]).map_err(|_| "bad number")?;
        let f: f64 = text.parse().map_err(|_| format!("bad number {text}"))?;
        // whole number -> Int, the same test value_of_js_shallow makes
        Ok(if f.fract() == 0.0 && f.abs() < 9007199254740992.0 {
            Value::Int(f as i64)
        } else {
            Value::Float(f)
        })
    }
}

/// Unused today, but the reason `StructVal` is public: a host that wants to
/// hand a struct back would build one here.
#[allow(dead_code)]
fn _unused(_: &StructVal, _: &dyn Fn(&Value) -> &str) {}

#[allow(dead_code)]
fn _tag_is_used(v: &Value) -> &str {
    tag(v)
}
