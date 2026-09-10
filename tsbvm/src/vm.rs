//! Running a `.tsb`. The reference is bin/vm.ml -- what this answers has to
//! match what that answers, or it is wrong.
//!
//! Narrow on purpose: numbers, strings, bools, variables, calls with
//! positional arguments, `if`/`while`, `return`. Everything else says so,
//! rather than guessing.

use crate::tsb::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// One struct instance. Fields keep their declared order, and a mutable
/// struct writes through the same cells -- two names for one instance see
/// each other's writes, the way the OCaml side's `value ref` array does.
pub struct StructVal {
    pub kind: Rc<str>,
    pub fields: RefCell<Vec<(Rc<str>, Value)>>,
}

/// `x -> ...` and `function (x) ... end`, and a `function` declared inside
/// another one (which is also bound locally, so two calls to a factory make
/// two closures -- see bin/vm.ml's Defun for why that matters).
pub struct Closure {
    pub params: Vec<u32>,
    pub body: u32,
    pub env: Rc<RefCell<Scope>>,
}

#[derive(Clone)]
pub enum Value {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(Rc<str>),
    Sym(Rc<str>),
    Nothing,
    Arr(Rc<RefCell<Vec<Value>>>),
    /// An array whose elements are all numbers stays in this shape -- the
    /// OCaml side keeps it as an unboxed float array, and it PRINTS
    /// differently for it (`[1.0, 2.0]`, not `[1, 2]`). Matching that is why
    /// this is a separate case and not a flag.
    Vector(Rc<RefCell<Vec<f64>>>),
    Tuple(Rc<Vec<Value>>),
    /// Insertion-ordered, like the OCaml side's -- so printing one is
    /// reproducible. Small enough everywhere it is used that a linear scan
    /// beats hashing values that would have to be hashed structurally.
    Dict(Rc<RefCell<Vec<(Value, Value)>>>),
    Pair(Rc<(Value, Value)>),
    Struct(Rc<StructVal>),
    Range(i64, i64, i64),
    Closure(Rc<Closure>),
}

/// `[...]`: all numbers stays a numeric Vector, anything else (an empty one
/// included) is an Array. The OCaml side's Eval.make_array_lit, same rule.
pub fn make_array_lit(vs: Vec<Value>) -> Value {
    let numeric = !vs.is_empty()
        && vs.iter().all(|v| matches!(v, Value::Int(_) | Value::Float(_)));
    if numeric {
        let fs = vs
            .iter()
            .map(|v| match v {
                Value::Int(n) => *n as f64,
                Value::Float(f) => *f,
                _ => unreachable!(),
            })
            .collect();
        Value::Vector(Rc::new(RefCell::new(fs)))
    } else {
        Value::Arr(Rc::new(RefCell::new(vs)))
    }
}

/// The runtime type name, as Tsubaki's own dispatch spells it.
pub fn tag(v: &Value) -> &str {
    match v {
        Value::Int(_) => "Int",
        Value::Float(_) => "Float",
        Value::Bool(_) => "Bool",
        Value::Str(_) => "String",
        Value::Sym(_) => "Symbol",
        Value::Nothing => "Nothing",
        Value::Arr(_) => "Array",
        Value::Vector(_) => "Vector",
        Value::Tuple(_) => "Tuple",
        Value::Dict(_) => "Dict",
        Value::Pair(_) => "Pair",
        Value::Struct(s) => &s.kind,
        Value::Range(..) => "Range",
        Value::Closure(_) => "Function",
    }
}

/// Equality between values, which is what a Dict's keys and `==` both need.
/// Structural, except that two distinct mutable structs are never equal --
/// same rule the OCaml side spells out in its own `generic_eq`.
pub fn value_eq(a: &Value, b: &Value) -> bool {
    use Value::*;
    match (a, b) {
        (Int(x), Int(y)) => x == y,
        (Float(x), Float(y)) => x == y,
        (Int(x), Float(y)) | (Float(y), Int(x)) => *x as f64 == *y,
        (Bool(x), Bool(y)) => x == y,
        (Str(x), Str(y)) => x == y,
        (Sym(x), Sym(y)) => x == y,
        (Nothing, Nothing) => true,
        (Arr(x), Arr(y)) => {
            let (x, y) = (x.borrow(), y.borrow());
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(a, b)| value_eq(a, b))
        }
        (Vector(x), Vector(y)) => *x.borrow() == *y.borrow(),
        (Closure(x), Closure(y)) => Rc::ptr_eq(x, y),
        (Tuple(x), Tuple(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(a, b)| value_eq(a, b))
        }
        (Pair(x), Pair(y)) => value_eq(&x.0, &y.0) && value_eq(&x.1, &y.1),
        (Range(a1, s1, b1), Range(a2, s2, b2)) => a1 == a2 && s1 == s2 && b1 == b2,
        (Dict(x), Dict(y)) => {
            let (x, y) = (x.borrow(), y.borrow());
            x.len() == y.len()
                && x.iter().all(|(k, v)| {
                    y.iter().any(|(k2, v2)| value_eq(k, k2) && value_eq(v, v2))
                })
        }
        (Struct(x), Struct(y)) => {
            if Rc::ptr_eq(x, y) {
                return true;
            }
            let (fx, fy) = (x.fields.borrow(), y.fields.borrow());
            x.kind == y.kind
                && fx.len() == fy.len()
                && fx.iter().zip(fy.iter()).all(|((_, a), (_, b))| value_eq(a, b))
        }
        _ => false,
    }
}

/// Physical identity (`===`): the same cell, not merely the same shape.
pub fn identical(a: &Value, b: &Value) -> bool {
    use Value::*;
    match (a, b) {
        (Struct(x), Struct(y)) => Rc::ptr_eq(x, y),
        (Arr(x), Arr(y)) => Rc::ptr_eq(x, y),
        (Vector(x), Vector(y)) => Rc::ptr_eq(x, y),
        (Dict(x), Dict(y)) => Rc::ptr_eq(x, y),
        _ => value_eq(a, b),
    }
}

/// Julia's own float printing, which is what the OCaml side does too
/// (Runtime.float_repr): a whole number keeps its `.0`, everything else is
/// the shortest form that reads back the same.
pub fn float_repr(f: f64) -> String {
    if f.is_nan() {
        return "NaN".into();
    }
    if f.is_infinite() {
        return if f > 0.0 { "Inf".into() } else { "-Inf".into() };
    }
    if f == f.trunc() && f.abs() < 1e16 {
        return format!("{:.1}", f);
    }
    // Rust's `{}` for f64 is already the shortest round-tripping form
    format!("{}", f)
}

pub fn show(v: &Value) -> String {
    match v {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => float_repr(*f),
        Value::Bool(b) => b.to_string(),
        // a string prints bare at the top, and quoted when nested -- see
        // show_elem, which is the OCaml side's rule too
        Value::Str(s) => s.to_string(),
        Value::Sym(s) => format!(":{s}"),
        Value::Nothing => "nothing".into(),
        Value::Arr(xs) => {
            let xs = xs.borrow();
            format!("[{}]", xs.iter().map(show_elem).collect::<Vec<_>>().join(", "))
        }
        Value::Vector(xs) => {
            let xs = xs.borrow();
            format!("[{}]", xs.iter().map(|f| float_repr(*f)).collect::<Vec<_>>().join(", "))
        }
        Value::Tuple(xs) => {
            format!("({})", xs.iter().map(show_elem).collect::<Vec<_>>().join(", "))
        }
        Value::Closure(_) => "#<function>".into(),
        Value::Dict(d) => {
            let d = d.borrow();
            let body = d
                .iter()
                .map(|(k, v)| format!("{} => {}", show_elem(k), show_elem(v)))
                .collect::<Vec<_>>()
                .join(", ");
            format!("Dict({body})")
        }
        Value::Pair(p) => format!("{} => {}", show_elem(&p.0), show_elem(&p.1)),
        Value::Range(a, 1, b) => format!("{a}:{b}"),
        Value::Range(a, s, b) => format!("{a}:{s}:{b}"),
        Value::Struct(sv) => {
            let fs = sv.fields.borrow();
            // `error(msg)` shows as the bare message, the way real Julia's
            // ErrorException does (and the way the OCaml side already does)
            if &*sv.kind == "ErrorException" {
                if let Some((_, m)) = fs.iter().find(|(n, _)| &**n == "msg") {
                    return show(m);
                }
            }
            let body = fs
                .iter()
                .map(|(n, v)| format!("{n}={}", show_elem(v)))
                .collect::<Vec<_>>()
                .join(", ");
            format!("{}({})", sv.kind, body)
        }
    }
}

/// How a value prints *inside* something else: a string gets its quotes back,
/// everything else is the same. (Runtime.show_elem, on the OCaml side.)
pub fn show_elem(v: &Value) -> String {
    match v {
        Value::Str(s) => {
            let mut b = String::with_capacity(s.len() + 2);
            b.push('"');
            for c in s.chars() {
                match c {
                    '"' => b.push_str("\\\""),
                    '\\' => b.push_str("\\\\"),
                    '\n' => b.push_str("\\n"),
                    '\t' => b.push_str("\\t"),
                    c => b.push(c),
                }
            }
            b.push('"');
            b
        }
        other => show(other),
    }
}

/// A scope, keyed by the symbol's index rather than its text: within one
/// program a name is one index, so nothing here ever compares strings.
pub struct Scope {
    vars: Vec<(u32, Value)>,
    parent: Option<Rc<RefCell<Scope>>>,
}

impl Scope {
    fn root() -> Rc<RefCell<Scope>> {
        Rc::new(RefCell::new(Scope { vars: Vec::new(), parent: None }))
    }

    fn child(parent: &Rc<RefCell<Scope>>) -> Rc<RefCell<Scope>> {
        Rc::new(RefCell::new(Scope { vars: Vec::new(), parent: Some(parent.clone()) }))
    }
}

fn lookup(env: &Rc<RefCell<Scope>>, sym: u32) -> Option<Value> {
    let s = env.borrow();
    for (k, v) in s.vars.iter().rev() {
        if *k == sym {
            return Some(v.clone());
        }
    }
    match &s.parent {
        Some(p) => lookup(p, sym),
        None => None,
    }
}

/// Assignment: overwrite wherever the name already lives, else make it here.
/// The same rule as the OCaml side's `assign`.
fn assign(env: &Rc<RefCell<Scope>>, sym: u32, v: Value) {
    {
        let mut s = env.borrow_mut();
        for (k, slot) in s.vars.iter_mut().rev() {
            if *k == sym {
                *slot = v;
                return;
            }
        }
        let parent = s.parent.clone();
        match parent {
            None => {
                s.vars.push((sym, v));
                return;
            }
            Some(p) => {
                drop(s);
                if lookup(&p, sym).is_some() {
                    assign(&p, sym, v);
                } else {
                    env.borrow_mut().vars.push((sym, v));
                }
                return;
            }
        }
    }
}

/// Binding: always here, never the parent's (a loop variable, a parameter).
fn bind(env: &Rc<RefCell<Scope>>, sym: u32, v: Value) {
    env.borrow_mut().vars.push((sym, v));
}

/// What a `struct T ... end` declared. Enough to build one and to type-check
/// what goes in a field; the type parameters of a parametric struct are not
/// here yet, and Defstruct says so rather than pretending.
struct StructDef {
    field_names: Vec<Rc<str>>,
    field_types: Vec<Vec<Rc<str>>>,
    mutable: bool,
}

struct Method {
    /// One entry per parameter: the type names it accepts (`["Any"]` when
    /// unannotated), as indices into `syms`.
    sig: Vec<Vec<u32>>,
    params: Vec<u32>,
    body: u32,
    def_env: Rc<RefCell<Scope>>,
}

pub struct Vm {
    /// Behind an `Rc` so a running irep can be borrowed while the VM itself
    /// is borrowed mutably. Without it `exec` had to CLONE the instruction
    /// list every time it was entered -- once per call, which fib(30) does
    /// 2.7 million times.
    p: Rc<Program>,
    /// name -> its methods, most recently defined last. Keyed by the text and
    /// not by the symbol's number, because a name declared inside `module M`
    /// is "M.name" -- a name the program's own symbol table never spells.
    methods: HashMap<Rc<str>, Vec<Method>>,
    /// One `Rc<str>` per symbol, made once. A call names its callee by the
    /// symbol's number, and the methods table is keyed by text -- without
    /// this, every single call would copy the name into a fresh String.
    sym_rc: Vec<Rc<str>>,
    /// "Any", looked up once
    any: Option<u32>,
    structs: HashMap<Rc<str>, StructDef>,
    /// `@kwdef` struct -> (field, the irep that makes its default). Run in
    /// the CALLER's scope, the way the OCaml side does it.
    kwdefaults: HashMap<Rc<str>, Vec<(Rc<str>, u32)>>,
    /// every type's immediate supertype -- the built-in tower plus whatever
    /// `struct T <: U` and `abstract type T <: U` declared
    parents: HashMap<Rc<str>, Rc<str>>,
    /// inside `module M`, names are declared as "M.name" (see ModuleEnter)
    prefix: String,
    outer_prefixes: Vec<String>,
    /// what `end` means right now, inside a `[...]`
    current_end: i64,
    out: String,
    line: u32,
}

/// Julia's own tower, as much of it as dispatch here needs. Written out
/// rather than derived: it is a fact about the language, not about a program.
const BUILTIN_PARENTS: &[(&str, &str)] = &[
    ("Int", "Signed"),
    ("Signed", "Integer"),
    ("Bool", "Integer"),
    ("Integer", "Real"),
    ("Float", "AbstractFloat"),
    ("AbstractFloat", "Real"),
    ("Real", "Number"),
    ("Number", "Any"),
    ("String", "AbstractString"),
    ("AbstractString", "Any"),
    ("Symbol", "Any"),
    ("Array", "Any"),
    ("Dict", "Any"),
    ("Tuple", "Any"),
    ("Pair", "Any"),
    ("Range", "Any"),
    ("Nothing", "Any"),
];

type E<T> = Result<T, String>;

impl Vm {
    pub fn new(p: Program) -> Vm {
        let any = p.syms.iter().position(|s| s == "Any").map(|i| i as u32);
        let mut parents = HashMap::new();
        for (a, b) in BUILTIN_PARENTS {
            parents.insert(Rc::from(*a), Rc::from(*b));
        }
        let sym_rc = p.syms.iter().map(|s| Rc::from(s.as_str())).collect();
        Vm {
            p: Rc::new(p),
            sym_rc,
            methods: HashMap::new(),
            any,
            structs: HashMap::new(),
            kwdefaults: HashMap::new(),
            parents,
            prefix: String::new(),
            outer_prefixes: Vec::new(),
            current_end: 0,
            out: String::new(),
            line: 0,
        }
    }

    fn sym(&self, i: u32) -> &str {
        &self.p.syms[i as usize]
    }

    /// Whatever the program printed. Kept rather than written out, so a host
    /// without a stdout (a wasm module, say) still gets it.
    pub fn output(&self) -> &str {
        &self.out
    }

    pub fn run(&mut self) -> E<Value> {
        let env = Scope::root();
        let main = self.p.main;
        self.exec(main, &env)
    }

    /// Is `sub` this type, or one below it? Walks the one chain of parents --
    /// the built-in tower and whatever the program declared, in one table.
    fn is_subtype(&self, sub: &str, sup: &str) -> bool {
        if sup == "Any" || sub == sup {
            return true;
        }
        let mut cur: Rc<str> = Rc::from(sub);
        // a cycle would be a bug in a declaration, not in a program: stop
        // rather than spin
        for _ in 0..32 {
            match self.parents.get(&cur) {
                Some(p) => {
                    if &**p == sup {
                        return true;
                    }
                    cur = p.clone();
                }
                None => return false,
            }
        }
        false
    }

    /// Does this argument satisfy one parameter's alternatives?
    fn accepts(&self, alts: &[u32], v: &Value) -> bool {
        alts.iter().any(|a| {
            if Some(*a) == self.any {
                true
            } else {
                self.is_subtype(tag(v), self.sym(*a))
            }
        })
    }

    /// Build a struct the way its declaration says: one argument per field,
    /// in declared order, each checked against the field's own type.
    fn construct(&self, kind: &str, args: Vec<Value>) -> E<Value> {
        let def = self
            .structs
            .get(kind)
            .ok_or_else(|| format!("UndefVarError: {kind} not defined"))?;
        if def.field_names.len() != args.len() {
            return Err(format!(
                "{kind}: expected {} field(s), got {}",
                def.field_names.len(),
                args.len()
            ));
        }
        for ((v, ty), name) in args.iter().zip(&def.field_types).zip(&def.field_names) {
            if !ty.iter().any(|t| self.is_subtype(tag(v), t)) {
                return Err(format!(
                    "TypeError: {kind}.{name}::{} cannot hold a {}",
                    ty.iter().map(|t| &**t).collect::<Vec<_>>().join("|"),
                    tag(v)
                ));
            }
        }
        let fields = def.field_names.iter().cloned().zip(args).collect();
        Ok(Value::Struct(Rc::new(StructVal {
            kind: Rc::from(kind),
            fields: RefCell::new(fields),
        })))
    }

    /// The method to run for this call. More specific wins, the way Tsubaki's
    /// own dispatch does -- here that only means "fewer `Any`s", which is as
    /// much of the ordering as this narrow VM can be asked about.
    fn pick(&self, name: &str, args: &[Value]) -> Option<usize> {
        let ms = self.methods.get(name)?;
        let mut best: Option<(usize, usize)> = None;
        for (i, m) in ms.iter().enumerate() {
            if m.sig.len() != args.len() {
                continue;
            }
            if !m.sig.iter().zip(args).all(|(alts, v)| self.accepts(alts, v)) {
                continue;
            }
            let anys = m
                .sig
                .iter()
                .filter(|alts| alts.iter().any(|a| Some(*a) == self.any))
                .count();
            if best.map_or(true, |(_, b)| anys < b) {
                best = Some((i, anys));
            }
        }
        best.map(|(i, _)| i)
    }

    /// `using M` -- whatever M declared becomes reachable bare as well.
    fn use_module(&mut self, prefix: &str) {
        let names: Vec<Rc<str>> = self
            .methods
            .keys()
            .filter(|k| k.starts_with(prefix))
            .cloned()
            .collect();
        for full in names {
            let bare: Rc<str> = Rc::from(&full[prefix.len()..]);
            // the qualified name keeps working too: the methods are copied
            // under the bare name, not moved
            let ms: Vec<Method> = match self.methods.get(&full) {
                Some(ms) => ms
                    .iter()
                    .map(|m| Method {
                        sig: m.sig.clone(),
                        params: m.params.clone(),
                        body: m.body,
                        def_env: m.def_env.clone(),
                    })
                    .collect(),
                None => continue,
            };
            self.methods.entry(bare).or_default().extend(ms);
        }
        let structs: Vec<(Rc<str>, Rc<str>)> = self
            .structs
            .keys()
            .filter_map(|k| k.strip_prefix(prefix).map(|b| (k.clone(), Rc::from(b))))
            .collect();
        for (full, bare) in structs {
            if let Some(d) = self.structs.get(&full) {
                let copy = StructDef {
                    field_names: d.field_names.clone(),
                    field_types: d.field_types.clone(),
                    mutable: d.mutable,
                };
                self.structs.insert(bare.clone(), copy);
                if let Some(p) = self.parents.get(&full).cloned() {
                    self.parents.insert(bare, p);
                }
            }
        }
    }

    /// A call with keyword arguments. Two shapes reach here in practice, both
    /// of them about building a struct: `T(; field=val, ...)` on an `@kwdef`
    /// struct (every field takes its named value, else its own default), and
    /// `T(existing; field=val)` (copy that one, then apply the overrides).
    /// Keyword parameters on an ordinary function are not folded yet.
    fn call_kw(
        &mut self,
        name: &str,
        args: Vec<Value>,
        kwargs: Vec<(Rc<str>, Value)>,
        env: &Rc<RefCell<Scope>>,
    ) -> E<Value> {
        let known: Vec<Rc<str>> = match self.structs.get(name) {
            Some(d) => d.field_names.clone(),
            None => {
                return Err(format!(
                    "vm: keyword arguments to a function are not supported yet ({name})"
                ))
            }
        };
        for (k, _) in &kwargs {
            if !known.iter().any(|f| f == k) {
                return Err(format!("type {name} has no field {k}"));
            }
        }
        let base: Option<Rc<StructVal>> = match args.first() {
            Some(Value::Struct(sv)) if &*sv.kind == name => Some(sv.clone()),
            None => None,
            Some(other) => {
                return Err(format!(
                    "{name}(...; kwargs): keyword form only supported as {name}(existing; field=val, ...), got a {}",
                    tag(other)
                ))
            }
        };
        let defaults = self.kwdefaults.get(name).cloned();
        let mut fields = Vec::with_capacity(known.len());
        for f in &known {
            if let Some((_, v)) = kwargs.iter().find(|(k, _)| k == f) {
                fields.push(v.clone());
                continue;
            }
            if let Some(sv) = &base {
                let got = sv.fields.borrow().iter().find(|(n, _)| n == f).map(|(_, v)| v.clone());
                if let Some(v) = got {
                    fields.push(v);
                    continue;
                }
            }
            match defaults.as_ref().and_then(|ds| ds.iter().find(|(n, _)| n == f)) {
                // the default is made now, in the caller's scope, so one that
                // reads a global sees it
                Some((_, irep)) => {
                    let v = self.exec(*irep, env)?;
                    fields.push(v);
                }
                None => {
                    return Err(format!(
                        "{name}: field {f} has no default, so it must be given as a keyword"
                    ))
                }
            }
        }
        self.construct(name, fields)
    }

    /// The words a program is given before its own. Only what the drops here
    /// actually reach for -- the OCaml side has 106 of these, and most of
    /// them (every one to do with matrices) a drop never says.
    ///
    /// `None` means "not a builtin at all", which is a different answer from
    /// `Some(Err(..))` ("that name, but not those arguments").
    fn builtin(&mut self, name: &str, args: &[Value]) -> Option<E<Value>> {
        use Value::*;
        Some(match (name, args) {
            ("Dict", []) => Ok(Dict(Rc::new(RefCell::new(Vec::new())))),
            ("length", [Arr(a)]) => Ok(Int(a.borrow().len() as i64)),
            ("length", [Vector(a)]) => Ok(Int(a.borrow().len() as i64)),
            ("length", [Tuple(t)]) => Ok(Int(t.len() as i64)),
            ("length", [Dict(d)]) => Ok(Int(d.borrow().len() as i64)),
            ("length", [Str(s)]) => Ok(Int(s.chars().count() as i64)),
            ("isempty", [v]) => match v {
                Arr(a) => Ok(Bool(a.borrow().is_empty())),
                Vector(a) => Ok(Bool(a.borrow().is_empty())),
                Dict(d) => Ok(Bool(d.borrow().is_empty())),
                Str(s) => Ok(Bool(s.is_empty())),
                other => Err(format!("isempty: not a collection, a {}", tag(other))),
            },
            ("push!", [Arr(a), v]) => {
                a.borrow_mut().push(v.clone());
                Ok(Arr(a.clone()))
            }
            ("haskey", [Dict(d), k]) => {
                Ok(Bool(d.borrow().iter().any(|(k2, _)| value_eq(k2, k))))
            }
            ("get", [Dict(d), k, dflt]) => Ok(d
                .borrow()
                .iter()
                .find(|(k2, _)| value_eq(k2, k))
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| dflt.clone())),
            ("keys", [Dict(d)]) => Ok(make_array_lit(
                d.borrow().iter().map(|(k, _)| k.clone()).collect(),
            )),
            ("values", [Dict(d)]) => Ok(make_array_lit(
                d.borrow().iter().map(|(_, v)| v.clone()).collect(),
            )),
            ("delete!", [Dict(d), k]) => {
                d.borrow_mut().retain(|(k2, _)| !value_eq(k2, k));
                Ok(Dict(d.clone()))
            }
            ("string", vs) => Ok(Str(Rc::from(
                vs.iter().map(show).collect::<Vec<_>>().join("").as_str(),
            ))),
            ("error", [v]) => Err(show(v)),
            ("throw", [v]) => Err(show(v)),
            ("vcat", vs) => {
                let mut out = Vec::new();
                for v in vs {
                    match v {
                        Arr(_) | Vector(_) | Tuple(_) => match iter_values(v) {
                            Ok(xs) => out.extend(xs),
                            Err(e) => return Some(Err(e)),
                        },
                        other => out.push(other.clone()),
                    }
                }
                Ok(make_array_lit(out))
            }
            ("filter", [f, coll]) => {
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let mut out = Vec::new();
                for x in xs {
                    match self.apply(&f.clone(), vec![x.clone()]) {
                        Ok(Bool(true)) => out.push(x),
                        Ok(Bool(false)) => {}
                        Ok(other) => {
                            return Some(Err(format!(
                                "filter: the test must answer Bool, got a {}",
                                tag(&other)
                            )))
                        }
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(match coll {
                    Dict(_) => {
                        let mut d = Vec::new();
                        for x in out {
                            if let Tuple(t) = x {
                                dict_set(&mut d, t[0].clone(), t[1].clone());
                            }
                        }
                        Dict(Rc::new(RefCell::new(d)))
                    }
                    _ => make_array_lit(out),
                })
            }
            ("map", [f, coll]) => {
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let mut out = Vec::with_capacity(xs.len());
                for x in xs {
                    match self.apply(&f.clone(), vec![x]) {
                        Ok(v) => out.push(v),
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(make_array_lit(out))
            }
            _ => return None,
        })
    }

    /// Calling a value rather than a name: a closure, and nothing else here.
    fn apply(&mut self, f: &Value, args: Vec<Value>) -> E<Value> {
        match f {
            Value::Closure(c) => {
                let scope = Scope::child(&c.env);
                for (k, v) in c.params.iter().zip(args) {
                    bind(&scope, *k, v);
                }
                self.exec(c.body, &scope)
            }
            other => Err(format!(
                "MethodError: objects of type {} are not callable",
                tag(other)
            )),
        }
    }

    /// Call by a name spelled out in full (a qualified call, `M.f(...)`).
    fn call_named(&mut self, name: &str, args: Vec<Value>, env: &Rc<RefCell<Scope>>) -> E<Value> {
        // a qualified call is strict: the writer asked for this exact name
        if !self.methods.contains_key(name) && !self.structs.contains_key(name) {
            return Err(format!("UndefVarError: {name} not defined"));
        }
        self.call(&Rc::from(name), args, env)
    }

    fn call(&mut self, bare: &Rc<str>, args: Vec<Value>, env: &Rc<RefCell<Scope>>) -> E<Value> {
        // inside `module M`, a bare call looks within it first -- falling back
        // to the bare name for builtins and anything already `using`'d.
        // Outside one (the overwhelmingly common case) this costs nothing:
        // the name is the same Rc the symbol table already holds.
        let name: Rc<str> = if self.prefix.is_empty() {
            bare.clone()
        } else {
            let q: Rc<str> = Rc::from(format!("{}{}", self.prefix, bare).as_str());
            if self.methods.contains_key(&q) { q } else { bare.clone() }
        };
        // a struct with no constructor of its own is built directly -- the
        // same judgement the OCaml side's call_named makes
        if !self.methods.contains_key(&name) {
            // `T()` on an @kwdef struct: every field from its own default
            if args.is_empty() && self.kwdefaults.contains_key(&name) {
                return self.call_kw(&name, vec![], vec![], env);
            }
            if self.structs.contains_key(&name) {
                return self.construct(&name, args);
            }
        }
        if self.pick(&name, &args).is_none() {
            if let Some(r) = self.builtin(&name, &args) {
                return r;
            }
        }
        let idx = self.pick(&name, &args).ok_or_else(|| {
            format!(
                "MethodError: no method matching {name}({})",
                args.iter().map(tag).collect::<Vec<_>>().join(", ")
            )
        })?;
        let (params, body, def_env) = {
            let m = &self.methods[&name][idx];
            (m.params.clone(), m.body, m.def_env.clone())
        };
        let scope = Scope::child(&def_env);
        for (k, v) in params.iter().zip(args) {
            bind(&scope, *k, v);
        }
        self.exec(body, &scope)
    }

    fn exec(&mut self, irep: u32, env0: &Rc<RefCell<Scope>>) -> E<Value> {
        let prog = Rc::clone(&self.p);
        let code = &prog.ireps[irep as usize];
        let mut stack: Vec<Value> = Vec::with_capacity(32);
        // for のネストの分だけ積む -- 値のスタックには置けない
        let mut iters: Vec<Iter> = Vec::new();
        let mut env = env0.clone();
        let mut pc = 0usize;
        loop {
            if pc >= code.len() {
                return Err("vm: ran off the end".into());
            }
            match &code[pc] {
                Instr::Const(i) => {
                    let v = match &self.p.pool[*i as usize] {
                        Lit::Int(n) => Value::Int(*n),
                        Lit::Float(f) => Value::Float(*f),
                        Lit::Str(s) => Value::Str(Rc::from(s.as_str())),
                        Lit::Bool(b) => Value::Bool(*b),
                    };
                    stack.push(v);
                    pc += 1;
                }
                Instr::Nothing => {
                    stack.push(Value::Nothing);
                    pc += 1;
                }
                Instr::Pop => {
                    stack.pop();
                    pc += 1;
                }
                Instr::Load(s, _) => {
                    let v = lookup(&env, *s)
                        .ok_or_else(|| format!("UndefVarError: {} not defined", self.sym(*s)))?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::Store(s, _) => {
                    let v = stack.last().ok_or("vm: Store with an empty stack")?.clone();
                    assign(&env, *s, v);
                    pc += 1;
                }
                Instr::StorePlain(s) => {
                    let v = stack.last().ok_or("vm: Store with an empty stack")?.clone();
                    assign(&env, *s, v);
                    pc += 1;
                }
                Instr::Bind(s) => {
                    let v = stack.pop().ok_or("vm: Bind with an empty stack")?;
                    bind(&env, *s, v);
                    pc += 1;
                }
                Instr::Binop(op, _) => {
                    let b = stack.pop().ok_or("vm: Binop wants two values")?;
                    let a = stack.pop().ok_or("vm: Binop wants two values")?;
                    let v = self.binop(*op, a, b)?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::Call(s, nargs, _) => {
                    let at = stack.len() - *nargs as usize;
                    let args: Vec<Value> = stack.split_off(at);
                    let name = self.sym_rc[*s as usize].clone();
                    let v = self.call(&name, args, &env)?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::Jump(t) => pc = *t as usize,
                Instr::JumpIfFalse(t) => {
                    match stack.pop().ok_or("vm: a condition with an empty stack")? {
                        Value::Bool(true) => pc += 1,
                        Value::Bool(false) => pc = *t as usize,
                        v => return Err(format!("a condition must be Bool, got a {}", tag(&v))),
                    }
                }
                Instr::Println(n) | Instr::Print(n) => {
                    let at = stack.len() - *n as usize;
                    let args: Vec<Value> = stack.split_off(at);
                    for a in &args {
                        self.out.push_str(&show(a));
                    }
                    if matches!(code[pc], Instr::Println(_)) {
                        self.out.push('\n');
                    }
                    stack.push(Value::Nothing);
                    pc += 1;
                }
                Instr::Enter => {
                    env = Scope::child(&env);
                    pc += 1;
                }
                Instr::Leave => {
                    let parent = env.borrow().parent.clone();
                    env = parent.ok_or("vm: Leave at the top scope")?;
                    pc += 1;
                }
                Instr::Line(n) => {
                    self.line = *n;
                    pc += 1;
                }
                Instr::File(_) => pc += 1,
                Instr::Defun(i) => {
                    let f = self.p.funcs[*i as usize].clone();
                    if !f.kwparams.is_empty() {
                        return Err("vm: keyword parameters are not supported yet".into());
                    }
                    if f.params.iter().any(|p| p.default != 0) {
                        return Err("vm: a default parameter value is not supported yet".into());
                    }
                    let m = Method {
                        sig: f.params.iter().map(|p| p.types.clone()).collect(),
                        params: f.params.iter().map(|p| p.name).collect(),
                        body: f.body,
                        def_env: env.clone(),
                    };
                    let full: Rc<str> = if self.prefix.is_empty() {
                        self.sym_rc[f.name as usize].clone()
                    } else {
                        Rc::from(format!("{}{}", self.prefix, self.sym(f.name)).as_str())
                    };
                    self.methods.entry(full).or_default().push(m);
                    pc += 1;
                }
                Instr::Ret => {
                    return Ok(stack.pop().unwrap_or(Value::Nothing));
                }
                // --- 値を作る ---
                Instr::Makearr(n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    stack.push(make_array_lit(vs));
                    pc += 1;
                }
                Instr::Maketuple(n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    stack.push(Value::Tuple(Rc::new(vs)));
                    pc += 1;
                }
                Instr::Makedict(n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    let mut d: Vec<(Value, Value)> = Vec::with_capacity(vs.len());
                    for v in vs {
                        match v {
                            Value::Pair(p) => dict_set(&mut d, p.0.clone(), p.1.clone()),
                            Value::Tuple(t) if t.len() == 2 => {
                                dict_set(&mut d, t[0].clone(), t[1].clone())
                            }
                            other => {
                                return Err(format!(
                                    "Dict: expected `key => value` pairs, got a {}",
                                    tag(&other)
                                ))
                            }
                        }
                    }
                    stack.push(Value::Dict(Rc::new(RefCell::new(d))));
                    pc += 1;
                }
                Instr::Pair => {
                    let b = stack.pop().ok_or("vm: Pair wants two values")?;
                    let a = stack.pop().ok_or("vm: Pair wants two values")?;
                    stack.push(Value::Pair(Rc::new((a, b))));
                    pc += 1;
                }
                Instr::Symbol(s) => {
                    stack.push(Value::Sym(Rc::from(self.sym(*s))));
                    pc += 1;
                }
                Instr::Identical(want) => {
                    let b = stack.pop().ok_or("vm: === wants two values")?;
                    let a = stack.pop().ok_or("vm: === wants two values")?;
                    stack.push(Value::Bool(identical(&a, &b) == (*want == 1)));
                    pc += 1;
                }
                // --- 型を宣言する ---
                Instr::Defstruct(i) => {
                    let st = self.p.structs[*i as usize].clone();
                    if !st.typarams.is_empty() {
                        return Err("vm: a parametric struct is not supported yet".into());
                    }
                    if !st.ctors.is_empty() {
                        return Err("vm: an inner constructor is not supported yet".into());
                    }
                    let name: Rc<str> =
                        Rc::from(format!("{}{}", self.prefix, self.sym(st.name)).as_str());
                    let parent: Rc<str> = Rc::from(self.sym(st.parent));
                    self.parents.insert(name.clone(), parent);
                    let def = StructDef {
                        field_names: st.fields.iter().map(|f| Rc::from(self.sym(f.name))).collect(),
                        field_types: st
                            .fields
                            .iter()
                            .map(|f| f.types.iter().map(|t| Rc::from(self.sym(*t))).collect())
                            .collect(),
                        mutable: st.mutable,
                    };
                    if !st.kwdefaults.is_empty() {
                        let ds = st
                            .kwdefaults
                            .iter()
                            .map(|(f, irep)| (Rc::from(self.sym(*f)), *irep))
                            .collect();
                        self.kwdefaults.insert(name.clone(), ds);
                    }
                    self.structs.insert(name, def);
                    pc += 1;
                }
                Instr::Defabstract(n, parent) => {
                    let name: Rc<str> =
                        Rc::from(format!("{}{}", self.prefix, self.sym(*n)).as_str());
                    self.parents.insert(name, Rc::from(self.sym(*parent)));
                    pc += 1;
                }
                // --- module ---
                Instr::ModuleEnter(s) => {
                    self.outer_prefixes.push(self.prefix.clone());
                    self.prefix = format!("{}{}.", self.prefix, self.sym(*s));
                    pc += 1;
                }
                Instr::ModuleLeave => {
                    self.prefix = self
                        .outer_prefixes
                        .pop()
                        .ok_or("vm: ModuleLeave outside a module")?;
                    pc += 1;
                }
                // --- field ---
                Instr::Getfield(f) => {
                    let o = stack.pop().ok_or("vm: Getfield with an empty stack")?;
                    let name = self.sym(*f);
                    match &o {
                        Value::Struct(sv) => {
                            let fs = sv.fields.borrow();
                            match fs.iter().find(|(n, _)| &**n == name) {
                                Some((_, v)) => stack.push(v.clone()),
                                None => {
                                    return Err(format!("type {} has no field {name}", sv.kind))
                                }
                            }
                        }
                        // a Pair reads as `.first` / `.second`, the way real
                        // Julia's does
                        Value::Pair(p) => match name {
                            "first" => stack.push(p.0.clone()),
                            "second" => stack.push(p.1.clone()),
                            _ => {
                                return Err(format!(
                                    "Pair has no field {name} (only .first/.second)"
                                ))
                            }
                        },
                        other => {
                            return Err(format!("{} is not a struct, has no fields", tag(other)))
                        }
                    }
                    pc += 1;
                }
                Instr::Setfield(f) => {
                    let o = stack.pop().ok_or("vm: Setfield with an empty stack")?;
                    let v = stack.last().ok_or("vm: Setfield with no value")?.clone();
                    let name = self.sym(*f);
                    match &o {
                        Value::Struct(sv) => {
                            if !self.structs.get(&sv.kind).map_or(false, |d| d.mutable) {
                                return Err(format!(
                                    "type {} is immutable, cannot set field {name}",
                                    sv.kind
                                ));
                            }
                            let mut fs = sv.fields.borrow_mut();
                            match fs.iter_mut().find(|(n, _)| &**n == name) {
                                Some((_, slot)) => *slot = v,
                                None => {
                                    return Err(format!("type {} has no field {name}", sv.kind))
                                }
                            }
                        }
                        other => {
                            return Err(format!("{} is not a struct, has no fields", tag(other)))
                        }
                    }
                    pc += 1;
                }
                // --- 添字 ---
                Instr::SetEnd => {
                    let v = stack.last().ok_or("vm: SetEnd with an empty stack")?;
                    self.current_end = match v {
                        Value::Arr(a) => a.borrow().len() as i64,
                        Value::Tuple(t) => t.len() as i64,
                        _ => self.current_end,
                    };
                    pc += 1;
                }
                Instr::Endmark => {
                    stack.push(Value::Int(self.current_end));
                    pc += 1;
                }
                Instr::Index => {
                    let i = stack.pop().ok_or("vm: Index wants a subscript")?;
                    let c = stack.pop().ok_or("vm: Index wants a container")?;
                    stack.push(index_get(&c, &i)?);
                    pc += 1;
                }
                Instr::IndexSet => {
                    let v = stack.pop().ok_or("vm: IndexSet wants a value")?;
                    let i = stack.pop().ok_or("vm: IndexSet wants a subscript")?;
                    let c = stack.pop().ok_or("vm: IndexSet wants a container")?;
                    index_set(&c, &i, v.clone())?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::LoadIndex(s, _) => {
                    // `name[...]`。変数として引ければ入れもの、そうでなければ
                    // 型の名前 -- 型のほうはまだ(Typedarr が要る)
                    let v = lookup(&env, *s).ok_or_else(|| {
                        format!("UndefVarError: {} not defined", self.sym(*s))
                    })?;
                    self.current_end = match &v {
                        Value::Arr(a) => a.borrow().len() as i64,
                        Value::Tuple(t) => t.len() as i64,
                        _ => self.current_end,
                    };
                    stack.push(v);
                    pc += 1;
                }
                Instr::IndexOrTyped(_) => {
                    let i = stack.pop().ok_or("vm: Index wants a subscript")?;
                    let c = stack.pop().ok_or("vm: Index wants a container")?;
                    stack.push(index_get(&c, &i)?);
                    pc += 1;
                }
                // --- 繰り返し ---
                Instr::Range => {
                    let hi = stack.pop().ok_or("vm: a range wants two ends")?;
                    let lo = stack.pop().ok_or("vm: a range wants two ends")?;
                    stack.push(make_range(&lo, 1, &hi)?);
                    pc += 1;
                }
                Instr::Range3 => {
                    let hi = stack.pop().ok_or("vm: a range wants three")?;
                    let st = stack.pop().ok_or("vm: a range wants three")?;
                    let lo = stack.pop().ok_or("vm: a range wants three")?;
                    let step = match st {
                        Value::Int(n) => n,
                        _ => return Err("vm: a float range is not supported yet".into()),
                    };
                    stack.push(make_range(&lo, step, &hi)?);
                    pc += 1;
                }
                Instr::IterNew => {
                    let src = stack.pop().ok_or("vm: IterNew with an empty stack")?;
                    iters.push(iter_start(&src)?);
                    pc += 1;
                }
                Instr::IterNext(out) => match iters.last_mut() {
                    None => return Err("vm: IterNext with no iterator".into()),
                    Some(it) => match it.next() {
                        Some(v) => {
                            stack.push(v);
                            pc += 1;
                        }
                        None => {
                            iters.pop();
                            pc = *out as usize;
                        }
                    },
                },
                Instr::BindTuple(names) => {
                    let v = stack.pop().ok_or("vm: BindTuple with an empty stack")?;
                    match &v {
                        Value::Tuple(t) if t.len() == names.len() => {
                            for (n, x) in names.iter().zip(t.iter()) {
                                bind(&env, *n, x.clone());
                            }
                        }
                        Value::Tuple(t) => {
                            return Err(format!(
                                "BoundsError: for-loop destructure expected {} values, got {}",
                                names.len(),
                                t.len()
                            ))
                        }
                        other => {
                            return Err(format!(
                                "for-loop destructure target requires a Tuple-valued iterator element, got a {}",
                                tag(other)
                            ))
                        }
                    }
                    pc += 1;
                }
                Instr::In => {
                    let coll = stack.pop().ok_or("vm: `in` wants two values")?;
                    let item = stack.pop().ok_or("vm: `in` wants two values")?;
                    // a plain number is its own one-element collection, the
                    // way real Julia's `Base.in(x, y::Number)` is
                    let found = match &coll {
                        Value::Int(_) | Value::Float(_) => value_eq(&item, &coll),
                        other => iter_values(other)?.iter().any(|v| value_eq(v, &item)),
                    };
                    stack.push(Value::Bool(found));
                    pc += 1;
                }
                Instr::Comprehension(i) => {
                    let c = self.p.comps[*i as usize].clone();
                    let body = c.body;
                    match c.targets.len() {
                        1 => {
                            let src = stack.pop().ok_or("vm: a comprehension wants a source")?;
                            let mut out = Vec::new();
                            for v in iter_values(&src)? {
                                let scope = Scope::child(&env);
                                bind_target(&scope, &c.targets[0], v)?;
                                out.push(self.exec(body, &scope)?);
                            }
                            stack.push(make_array_lit(out));
                        }
                        2 => {
                            let s2 = stack.pop().ok_or("vm: a comprehension wants two sources")?;
                            let s1 = stack.pop().ok_or("vm: a comprehension wants two sources")?;
                            let vs2 = iter_values(&s2)?;
                            let mut rows = Vec::new();
                            for v1 in iter_values(&s1)? {
                                let mut row = Vec::new();
                                for v2 in &vs2 {
                                    let scope = Scope::child(&env);
                                    bind_target(&scope, &c.targets[0], v1.clone())?;
                                    bind_target(&scope, &c.targets[1], v2.clone())?;
                                    row.push(self.exec(body, &scope)?);
                                }
                                rows.push(make_array_lit(row));
                            }
                            stack.push(Value::Arr(Rc::new(RefCell::new(rows))));
                        }
                        _ => return Err("a comprehension wants one or two for-clauses".into()),
                    }
                    pc += 1;
                }
                // --- 名前を持たないものを呼ぶ ---
                Instr::Makeclosure(i) => {
                    let l = self.p.lambdas[*i as usize].clone();
                    stack.push(Value::Closure(Rc::new(Closure {
                        params: l.params.clone(),
                        body: l.body,
                        env: env.clone(),
                    })));
                    pc += 1;
                }
                Instr::Apply(nargs) => {
                    let at = stack.len() - *nargs as usize;
                    let args: Vec<Value> = stack.split_off(at);
                    let f = stack.pop().ok_or("vm: Apply with no callee")?;
                    let v = self.apply(&f, args)?;
                    stack.push(v);
                    pc += 1;
                }
                // --- module の中の名前 ---
                Instr::Using(s) | Instr::Import(s, _) => {
                    // 同じ .tsb にぜんぶ入っているので、読みに行くものは無い。
                    // することは「M.x を x でも引けるようにする」だけ
                    let m = format!("{}.", self.sym(*s));
                    self.use_module(&m);
                    pc += 1;
                }
                Instr::Qcall(m, member, nargs, _) => {
                    let at = stack.len() - *nargs as usize;
                    let args: Vec<Value> = stack.split_off(at);
                    let qualified = format!("{}.{}", self.sym(*m), self.sym(*member));
                    let v = self.call_named(&qualified, args, &env)?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::CallKw(s, nargs, kwnames, _) => {
                    let at = stack.len() - kwnames.len();
                    let kwvals: Vec<Value> = stack.split_off(at);
                    let kwargs: Vec<(Rc<str>, Value)> = kwnames
                        .iter()
                        .map(|k| Rc::from(self.sym(*k)))
                        .zip(kwvals)
                        .collect();
                    let at = stack.len() - *nargs as usize;
                    let args: Vec<Value> = stack.split_off(at);
                    let name = self.sym(*s).to_string();
                    let v = self.call_kw(&name, args, kwargs, &env)?;
                    stack.push(v);
                    pc += 1;
                }
                other => {
                    return Err(format!(
                        "vm: {:?} is not supported yet (line {})",
                        other, self.line
                    ))
                }
            }
        }
    }

    fn binop(&self, op: u32, a: Value, b: Value) -> E<Value> {
        use Value::*;
        let name = self.sym(op);
        let both_int = matches!((&a, &b), (Int(_), Int(_)));
        let fa = match &a {
            Int(n) => *n as f64,
            Float(f) => *f,
            _ => f64::NAN,
        };
        let fb = match &b {
            Int(n) => *n as f64,
            Float(f) => *f,
            _ => f64::NAN,
        };
        let numeric = matches!((&a, &b), (Int(_) | Float(_), Int(_) | Float(_)));
        if let (Str(x), Str(y)) = (&a, &b) {
            return Ok(match name {
                // Julia joins strings with `*`; `+` works here too, and both
                // are what the OCaml side registers
                "*" | "+" => Str(Rc::from(format!("{x}{y}").as_str())),
                "==" => Bool(x == y),
                "!=" => Bool(x != y),
                "<" => Bool(**x < **y),
                "<=" => Bool(**x <= **y),
                ">" => Bool(**x > **y),
                ">=" => Bool(**x >= **y),
                _ => return Err(format!("MethodError: no method matching {name}(String, String)")),
            });
        }
        if !numeric {
            return Err(format!(
                "MethodError: no method matching {name}({}, {})",
                tag(&a),
                tag(&b)
            ));
        }
        Ok(match name {
            "+" => if both_int { Int(as_int(&a) + as_int(&b)) } else { Float(fa + fb) },
            "-" => if both_int { Int(as_int(&a) - as_int(&b)) } else { Float(fa - fb) },
            "*" => if both_int { Int(as_int(&a) * as_int(&b)) } else { Float(fa * fb) },
            // Julia's `/` is always a float, even on two Ints
            "/" => Float(fa / fb),
            "%" => if both_int { Int(as_int(&a) % as_int(&b)) } else { Float(fa % fb) },
            "^" => if both_int && as_int(&b) >= 0 {
                Int(as_int(&a).pow(as_int(&b) as u32))
            } else {
                Float(fa.powf(fb))
            },
            "==" => Bool(fa == fb),
            "!=" => Bool(fa != fb),
            "<" => Bool(fa < fb),
            "<=" => Bool(fa <= fb),
            ">" => Bool(fa > fb),
            ">=" => Bool(fa >= fb),
            _ => return Err(format!("MethodError: no method matching {name}({}, {})", tag(&a), tag(&b))),
        })
    }
}

/// What this VM does not know yet, counted across the whole program. Meant to
/// be read before running: the folding side (Tocode) says `Not_yet` about one
/// shape at a time, which tells you the next thing but not how far there is
/// to go. This says how far.
pub fn unsupported(p: &Program) -> Vec<(&'static str, usize)> {
    let mut counts: HashMap<&'static str, usize> = HashMap::new();
    for irep in &p.ireps {
        for i in irep {
            if let Some(k) = unsupported_kind(i) {
                *counts.entry(k).or_insert(0) += 1;
            }
        }
    }
    let mut v: Vec<_> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    v
}

/// Every instruction kind in a program, with how many times it occurs. Reading
/// this is how you find out that a `.tsb` uses far fewer kinds than the set
/// has -- which is the number that decides how much VM there is to write.
pub fn instruction_census(p: &Program) -> Vec<(&'static str, usize)> {
    let mut counts: HashMap<&'static str, usize> = HashMap::new();
    for irep in &p.ireps {
        for i in irep {
            *counts.entry(kind_of(i)).or_insert(0) += 1;
        }
    }
    let mut v: Vec<_> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    v
}

/// Which two instructions follow each other, and how often. Two things show
/// up here: pairs that are pure ceremony (a value pushed only to be dropped),
/// and pairs worth fusing into one instruction. The second was measured once
/// before, in the Rust numeric VM -- fewer instructions did NOT automatically
/// mean faster (see AST_IN_RUST_EXPERIMENT.md), so this only says where to
/// look, never what to do.
pub fn adjacent_pairs(p: &Program) -> Vec<(String, usize)> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for irep in &p.ireps {
        for w in irep.windows(2) {
            *counts
                .entry(format!("{} {}", kind_of(&w[0]), kind_of(&w[1])))
                .or_insert(0) += 1;
        }
    }
    let mut v: Vec<_> = counts.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    v
}

fn kind_of(i: &Instr) -> &'static str {
    use Instr::*;
    match i {
        Const(..) => "Const", Nothing => "Nothing", Load(..) => "Load", Store(..) => "Store",
        StorePlain(..) => "StorePlain", Pop => "Pop", Binop(..) => "Binop", Call(..) => "Call",
        CallKw(..) => "CallKw", Qcall(..) => "Qcall", Apply(..) => "Apply",
        ApplyMethod(..) => "ApplyMethod", Jump(..) => "Jump", JumpIfFalse(..) => "JumpIfFalse",
        Println(..) => "Println", Print(..) => "Print", Enter => "Enter", Leave => "Leave",
        Line(..) => "Line", File(..) => "File", Defun(..) => "Defun", Defstruct(..) => "Defstruct",
        Defabstract(..) => "Defabstract", Makeclosure(..) => "Makeclosure", Using(..) => "Using",
        Import(..) => "Import", ModuleEnter(..) => "ModuleEnter", ModuleLeave => "ModuleLeave",
        Bind(..) => "Bind", BindTuple(..) => "BindTuple", Range => "Range", Range3 => "Range3",
        IterNew => "IterNew", IterNext(..) => "IterNext", Comprehension(..) => "Comprehension",
        Getfield(..) => "Getfield", Setfield(..) => "Setfield", Makearr(..) => "Makearr",
        Maketuple(..) => "Maketuple", Makematrix(..) => "Makematrix", Makedict(..) => "Makedict",
        Pair => "Pair", Identical(..) => "Identical", Subtype(..) => "Subtype", In => "In",
        Typeof => "Typeof", Isa(..) => "Isa", Symbol(..) => "Symbol", SetEnd => "SetEnd",
        Index => "Index", IndexSet => "IndexSet", Endmark => "Endmark", Typedarr(..) => "Typedarr",
        TypedarrUndef(..) => "TypedarrUndef", TypedmatUndef(..) => "TypedmatUndef",
        LoadIndex(..) => "LoadIndex", IndexOrTyped(..) => "IndexOrTyped",
        UnpackCheck(..) => "UnpackCheck", Elem(..) => "Elem", UnpackEnd => "UnpackEnd",
        Typecheck(..) => "Typecheck", Try(..) => "Try", TryEnd => "TryEnd", Ret => "Ret",
    }
}

fn unsupported_kind(i: &Instr) -> Option<&'static str> {
    use Instr::*;
    Some(match i {
        Const(..) | Nothing | Load(..) | Store(..) | StorePlain(..) | Bind(..) | Pop
        | Binop(..) | Call(..) | Jump(..) | JumpIfFalse(..) | Println(..) | Print(..) | Enter
        | Leave | Line(..) | File(..) | Defun(..) | Ret | Makearr(..) | Maketuple(..)
        | Makedict(..) | Pair | Symbol(..) | Identical(..) | Defstruct(..) | Defabstract(..)
        | ModuleEnter(..) | ModuleLeave | Getfield(..) | Setfield(..) | SetEnd | Endmark
        | Index | IndexSet | LoadIndex(..) | IndexOrTyped(..) | Makeclosure(..) | Range
        | Range3 | IterNew | IterNext(..) | Comprehension(..) | Using(..) | Import(..)
        | Qcall(..) | Apply(..) | In | BindTuple(..) | CallKw(..) => return None,
        Makematrix(..) => "a matrix",
        ApplyMethod(..) => "calling a method on a JS value",
        Subtype(..) => "<:",
        Typeof => "typeof",
        Isa(..) => "isa",
        Typedarr(..) | TypedarrUndef(..) | TypedmatUndef(..) => "a typed array constructor",
        UnpackCheck(..) | Elem(..) | UnpackEnd => "a destructuring assignment",
        Typecheck(..) => "a type-annotated assignment",
        Try(..) | TryEnd => "try/catch",
    })
}

/// Iterating, pulled one at a time -- a `for` body lives in the same
/// instruction stream, so the loop has to be able to ask for the next value
/// at its own pace (bin/eval.ml's iter_start/iter_next, same reason).
enum Iter {
    Range(i64, i64, i64),
    Vals(Vec<Value>, usize),
}

impl Iter {
    fn next(&mut self) -> Option<Value> {
        match self {
            Iter::Range(cur, step, stop) => {
                let go = if *step > 0 { *cur <= *stop } else { *cur >= *stop };
                if go {
                    let v = Value::Int(*cur);
                    *cur += *step;
                    Some(v)
                } else {
                    None
                }
            }
            Iter::Vals(vs, k) => {
                if *k < vs.len() {
                    *k += 1;
                    Some(vs[*k - 1].clone())
                } else {
                    None
                }
            }
        }
    }
}

fn iter_start(v: &Value) -> E<Iter> {
    Ok(match v {
        Value::Range(a, s, b) => {
            if *s == 0 {
                return Err("range step cannot be 0".into());
            }
            Iter::Range(*a, *s, *b)
        }
        Value::Arr(a) => Iter::Vals(a.borrow().clone(), 0),
        Value::Vector(a) => {
            Iter::Vals(a.borrow().iter().map(|f| Value::Float(*f)).collect(), 0)
        }
        Value::Tuple(t) => Iter::Vals(t.as_ref().clone(), 0),
        // a Dict iterates as its (key, value) pairs
        Value::Dict(d) => Iter::Vals(
            d.borrow()
                .iter()
                .map(|(k, v)| Value::Tuple(Rc::new(vec![k.clone(), v.clone()])))
                .collect(),
            0,
        ),
        other => {
            return Err(format!(
                "expected a Range, Vector, Array, or Dict to iterate, got a {}",
                tag(other)
            ))
        }
    })
}

fn iter_values(v: &Value) -> E<Vec<Value>> {
    let mut it = iter_start(v)?;
    let mut out = Vec::new();
    while let Some(x) = it.next() {
        out.push(x);
    }
    Ok(out)
}

/// `a:b` and `a:s:b`. Only the integer form for now -- a float range says so.
fn make_range(lo: &Value, step: i64, hi: &Value) -> E<Value> {
    match (lo, hi) {
        (Value::Int(a), Value::Int(b)) => Ok(Value::Range(*a, step, *b)),
        _ => Err("vm: a float range is not supported yet".into()),
    }
}

/// Dict: insertion-ordered, an existing key overwritten in place.
fn dict_set(d: &mut Vec<(Value, Value)>, k: Value, v: Value) {
    for (k2, slot) in d.iter_mut() {
        if value_eq(k2, &k) {
            *slot = v;
            return;
        }
    }
    d.push((k, v));
}

/// `c[i]`. Everything indexable here starts at 1, the way Julia's does.
fn index_get(c: &Value, i: &Value) -> E<Value> {
    match (c, i) {
        (Value::Arr(a), Value::Int(n)) => {
            let a = a.borrow();
            if *n < 1 || *n as usize > a.len() {
                Err(format!("BoundsError: index {n}"))
            } else {
                Ok(a[*n as usize - 1].clone())
            }
        }
        (Value::Vector(a), Value::Int(n)) => {
            let a = a.borrow();
            if *n < 1 || *n as usize > a.len() {
                Err(format!("BoundsError: index {n}"))
            } else {
                Ok(Value::Float(a[*n as usize - 1]))
            }
        }
        (Value::Tuple(t), Value::Int(n)) => {
            if *n < 1 || *n as usize > t.len() {
                Err(format!("BoundsError: index {n}"))
            } else {
                Ok(t[*n as usize - 1].clone())
            }
        }
        (Value::Dict(d), k) => d
            .borrow()
            .iter()
            .find(|(k2, _)| value_eq(k2, k))
            .map(|(_, v)| v.clone())
            .ok_or_else(|| format!("KeyError: key {} not found", show(k))),
        // a slice: v[2:end] or v[2:4] -- a fresh one, not a view
        (Value::Arr(a), Value::Range(lo, st, hi)) => {
            let a = a.borrow();
            let mut out = Vec::new();
            let mut i = *lo;
            while if *st > 0 { i <= *hi } else { i >= *hi } {
                if i < 1 || i as usize > a.len() {
                    return Err("BoundsError: slice index out of range".into());
                }
                out.push(a[i as usize - 1].clone());
                i += *st;
            }
            Ok(Value::Arr(Rc::new(RefCell::new(out))))
        }
        (Value::Vector(a), Value::Range(lo, st, hi)) => {
            let a = a.borrow();
            let mut out = Vec::new();
            let mut i = *lo;
            while if *st > 0 { i <= *hi } else { i >= *hi } {
                if i < 1 || i as usize > a.len() {
                    return Err("BoundsError: slice index out of range".into());
                }
                out.push(a[i as usize - 1]);
                i += *st;
            }
            Ok(Value::Vector(Rc::new(RefCell::new(out))))
        }
        (Value::Arr(_) | Value::Vector(_) | Value::Tuple(_), other) => {
            Err(format!("index must be an Int, got a {}", tag(other)))
        }
        (other, _) => Err(format!(
            "indexing is only supported on Array, Tuple, or Dict, got a {}",
            tag(other)
        )),
    }
}

fn index_set(c: &Value, i: &Value, v: Value) -> E<()> {
    match (c, i) {
        (Value::Arr(a), Value::Int(n)) => {
            let mut a = a.borrow_mut();
            if *n < 1 || *n as usize > a.len() {
                Err(format!("BoundsError: index {n}"))
            } else {
                let at = *n as usize - 1;
                a[at] = v;
                Ok(())
            }
        }
        (Value::Vector(a), Value::Int(n)) => {
            let mut a = a.borrow_mut();
            if *n < 1 || *n as usize > a.len() {
                Err(format!("BoundsError: index {n}"))
            } else {
                let at = *n as usize - 1;
                a[at] = match v {
                    Value::Int(x) => x as f64,
                    Value::Float(f) => f,
                    other => return Err(format!("a Vector holds numbers, not a {}", tag(&other))),
                };
                Ok(())
            }
        }
        // a missing key is CREATED here -- that is what a Dict is for
        (Value::Dict(d), k) => {
            dict_set(&mut d.borrow_mut(), k.clone(), v);
            Ok(())
        }
        (other, _) => Err(format!(
            "cannot write to an index of a {}",
            tag(other)
        )),
    }
}

fn bind_target(scope: &Rc<RefCell<Scope>>, t: &Target, v: Value) -> E<()> {
    if !t.tuple {
        bind(scope, t.names[0], v);
        return Ok(());
    }
    match &v {
        Value::Tuple(xs) if xs.len() == t.names.len() => {
            for (n, x) in t.names.iter().zip(xs.iter()) {
                bind(scope, *n, x.clone());
            }
            Ok(())
        }
        other => Err(format!(
            "for-loop destructure target requires a matching Tuple, got a {}",
            tag(other)
        )),
    }
}

fn as_int(v: &Value) -> i64 {
    match v {
        Value::Int(n) => *n,
        Value::Float(f) => *f as i64,
        _ => 0,
    }
}
