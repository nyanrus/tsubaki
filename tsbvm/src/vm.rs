//! Running a `.tsb`. The reference is bin/vm.ml -- what this answers has to
//! match what that answers, or it is wrong.
//!
//! Narrow on purpose: numbers, strings, bools, variables, calls with
//! positional arguments, `if`/`while`, `return`. Everything else says so,
//! rather than guessing.

use crate::tsb::*;
use std::cell::OnceCell;
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
    /// 内側の `function` から来た closure だけが持つ: 自分の名前と署名。
    /// 渡された引数が自分に合わなければ、名前での dispatch に戻る --
    /// 同じ名前の内側 method が何本かあるとき、型で選べるように
    pub inner: Option<(Rc<str>, Vec<Vec<u32>>)>,
}

/// One array. Julia's arrays all carry an element type -- `[1, 2]` is a
/// `Vector{Int64}`, `[]` is a `Vector{Any}` -- and they keep it even when
/// they are empty, which is the whole reason it is stored rather than read
/// back off the contents. `ty` is the full name (`Vector{Int64}`), kept so
/// `tag` can hand one out without building a string every time it is asked.
pub struct ArrVal {
    pub elem: Rc<str>,
    pub ty: Rc<str>,
    pub cells: RefCell<Vec<Value>>,
}

impl ArrVal {
    /// The cells, borrowed. Spelled like a RefCell's own so that reading a
    /// `xs.borrow()` here says the same thing it says everywhere else.
    pub fn borrow(&self) -> std::cell::Ref<'_, Vec<Value>> {
        self.cells.borrow()
    }

    pub fn borrow_mut(&self) -> std::cell::RefMut<'_, Vec<Value>> {
        self.cells.borrow_mut()
    }
}

/// One tuple. Julia's tuples carry their element types -- `(1, 2)` is a
/// `Tuple{Int64, Int64}` -- and that name is what dispatch reads, so
/// `t::Tuple{Int64, Int64}` can match something.
///
/// The name is built the FIRST time somebody asks for it, not when the tuple
/// is made: `for (k, v) in d` makes one tuple per turn and only takes it
/// apart again, and that loop should not pay for a name nobody reads.
///
/// No `RefCell` around the cells, unlike `ArrVal` -- a tuple does not change
/// after it is made. That is what lets it `Deref` straight to its contents,
/// so everything that reads one keeps reading it the way it always did.
pub struct TupleVal {
    ty: OnceCell<Rc<str>>,
    pub cells: Vec<Value>,
}

impl std::ops::Deref for TupleVal {
    type Target = Vec<Value>;
    fn deref(&self) -> &Vec<Value> {
        &self.cells
    }
}

impl TupleVal {
    /// `Tuple{Int64, Int64}`, built once. An empty tuple is `Tuple{}`, which
    /// is what Julia calls `typeof(())`.
    fn ty(&self) -> &str {
        self.ty.get_or_init(|| {
            let inner: Vec<&str> = self.cells.iter().map(tag).collect();
            Rc::from(format!("Tuple{{{}}}", inner.join(", ")).as_str())
        })
    }
}

pub fn tuple_of(cells: Vec<Value>) -> Value {
    Value::Tuple(Rc::new(TupleVal { ty: OnceCell::new(), cells }))
}

/// An array with a DECLARED element type: `Float64[1, 2]`, `Vector{T}(undef, n)`,
/// and whatever a literal's own elements promoted to.
pub fn arr_of(elem: &str, cells: Vec<Value>) -> Value {
    let elem: Rc<str> = Rc::from(canonical(elem));
    let ty: Rc<str> = Rc::from(format!("Vector{{{elem}}}").as_str());
    Value::Arr(Rc::new(ArrVal { elem, ty, cells: RefCell::new(cells) }))
}

#[derive(Clone)]
pub enum Value {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(Rc<str>),
    Sym(Rc<str>),
    Nothing,
    Arr(Rc<ArrVal>),
    Tuple(Rc<TupleVal>),
    /// Insertion-ordered, like the OCaml side's -- so printing one is
    /// reproducible. Small enough everywhere it is used that a linear scan
    /// beats hashing values that would have to be hashed structurally.
    Dict(Rc<RefCell<Vec<(Value, Value)>>>),
    Pair(Rc<(Value, Value)>),
    Struct(Rc<StructVal>),
    Range(i64, i64, i64),
    /// 端か刻みのどれかが float の range。`1.0:0.5:3.0`。Julia は i 番目を
    /// `start + i*step` で出すので(足しつづけない)、ここも同じにする
    FRange(f64, f64, f64),
    Closure(Rc<Closure>),
    /// `module M ... end` そのもの。`M.x` は、これの member を読む形になる
    /// (Julia でも module は値で、`typeof(M)` は `Module`)。
    Module(Rc<str>),
    /// A bare function NAME used as a value -- `filter(long, xs)`,
    /// `each(speak, pets)`. It stands for the whole generic function (every
    /// method of it), so which one runs is decided by the arguments it
    /// actually gets, not by what existed when the name was read.
    Generic(Rc<str>),
}

/// `[...]` -- 何の並びか。Julia は書かれた要素から一つの型を決める:
///
///     [1, 2]        Vector{Int64}      [1, "a"]   Vector{Any}
///     [1, 2.0]      Vector{Float64}    []         Vector{Any}
///     [true, 1]     Vector{Int64}      [Q(1)]     Vector{Q}
///     [[1, 2]]      Vector{Vector{Int64}}
///
/// 数どうしは promote(float が一つでもあれば float、Bool は Int に上がる)、
/// それ以外は共通の親まで登る(typejoin)。登りかたは宣言を知っている Vm しか
/// 言えないので、そこは呼ぶ側から渡してもらう。
///
/// (OCaml の runtime は数だけの並びを全部 float の箱で持つので、そちらでは
/// `[1, 2]` が `[1.0, 2.0]` と出る。持ちかたの話で、Julia の意味ではない。)
fn elem_type_of(vs: &mut Vec<Value>, join: impl Fn(&str, &str) -> Rc<str>) -> Rc<str> {
    if vs.is_empty() {
        return Rc::from("Any");
    }
    let numeric = vs
        .iter()
        .all(|v| matches!(v, Value::Int(_) | Value::Float(_) | Value::Bool(_)));
    if numeric {
        let any_float = vs.iter().any(|v| matches!(v, Value::Float(_)));
        let any_int = vs.iter().any(|v| matches!(v, Value::Int(_)));
        if any_float {
            for v in vs.iter_mut() {
                *v = Value::Float(match v {
                    Value::Int(n) => *n as f64,
                    Value::Bool(b) => *b as i64 as f64,
                    Value::Float(f) => *f,
                    _ => unreachable!(),
                });
            }
            return Rc::from("Float64");
        }
        if any_int {
            for v in vs.iter_mut() {
                if let Value::Bool(b) = v {
                    *v = Value::Int(*b as i64);
                }
            }
            return Rc::from("Int64");
        }
        return Rc::from("Bool");
    }
    let mut t: Rc<str> = Rc::from(tag(&vs[0]));
    for v in vs.iter().skip(1) {
        if &*t != tag(v) {
            t = join(&t, tag(v));
        }
    }
    t
}

/// 親の表を知らないところ用(JSON から戻ってくる値など)。型がばらけていたら
/// `Any` にする -- そこで登れる先を知らないので。
pub fn make_array_lit(mut vs: Vec<Value>) -> Value {
    let elem = elem_type_of(&mut vs, |_, _| Rc::from("Any"));
    arr_of(&elem, vs)
}

/// The runtime type name, as Tsubaki's own dispatch spells it.
pub fn tag(v: &Value) -> &str {
    match v {
        // Julia's own names: `Int` and `Float` are what you WRITE, `Int64`
        // and `Float64` are what a value IS (see canonical below)
        Value::Int(_) => "Int64",
        Value::Float(_) => "Float64",
        Value::Bool(_) => "Bool",
        Value::Str(_) => "String",
        Value::Sym(_) => "Symbol",
        Value::Nothing => "Nothing",
        // Julia's own name for a one-dimensional array, with what it holds
        Value::Arr(a) => &a.ty,
        Value::Tuple(t) => t.ty(),
        Value::Dict(_) => "Dict",
        Value::Pair(_) => "Pair",
        Value::Struct(s) => &s.kind,
        Value::Range(..) | Value::FRange(..) => "Range",
        Value::Closure(_) | Value::Generic(_) => "Function",
        Value::Module(_) => "Module",
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
        (Closure(x), Closure(y)) => Rc::ptr_eq(x, y),
        (Generic(x), Generic(y)) => x == y,
        (Module(x), Module(y)) => x == y,
        (Tuple(x), Tuple(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(a, b)| value_eq(a, b))
        }
        (Pair(x), Pair(y)) => value_eq(&x.0, &y.0) && value_eq(&x.1, &y.1),
        (Range(a1, s1, b1), Range(a2, s2, b2)) => a1 == a2 && s1 == s2 && b1 == b2,
        (FRange(a1, s1, b1), FRange(a2, s2, b2)) => a1 == a2 && s1 == s2 && b1 == b2,
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
        (Dict(x), Dict(y)) => Rc::ptr_eq(x, y),
        _ => value_eq(a, b),
    }
}

/// Julia's own float printing. Measured against julia 1.12, not guessed:
///
///     0.0001     0.0001       0.00012    0.00012
///     0.00001    1.0e-5       0.000012   1.2e-5
///     999999.0   999999.0     1000000.0  1.0e6
///     0.1+0.2    0.30000000000000004      -0.0  -0.0
///
/// So: plain decimal while the magnitude is in [1e-4, 1e6), exponent form
/// outside it, and a whole number always keeps its `.0`. Rust's own `{}`
/// gives the shortest form that reads back the same (which is what Julia
/// wants too), so the work here is only about which shape to put it in.
pub fn float_repr(f: f64) -> String {
    if f.is_nan() {
        return "NaN".into();
    }
    if f.is_infinite() {
        return if f > 0.0 { "Inf".into() } else { "-Inf".into() };
    }
    if f == 0.0 {
        return if f.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    let a = f.abs();
    if (1e-4..1e6).contains(&a) {
        let s = format!("{f}");
        if s.contains('.') {
            s
        } else {
            format!("{s}.0")
        }
    } else {
        // `{:e}` writes `1e6`; Julia writes `1.0e6`, so the mantissa always
        // carries a point
        let s = format!("{f:e}");
        match s.split_once('e') {
            Some((m, e)) if !m.contains('.') => format!("{m}.0e{e}"),
            _ => s,
        }
    }
}

pub fn show(v: &Value) -> String {
    match v {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => float_repr(*f),
        Value::Bool(b) => b.to_string(),
        // a string prints bare at the top, and quoted when nested -- see
        // show_elem, which is the OCaml side's rule too
        Value::Str(s) => s.to_string(),
        // `println(:name)` prints `name`; inside something else it shows
        // as `:name` (see show_elem) -- that is Julia's print/show split
        Value::Sym(s) => s.to_string(),
        Value::Nothing => "nothing".into(),
        Value::Arr(a) => {
            let xs = a.borrow();
            // 空のときは、中身が何も言ってくれないので、いつも型を書く
            // (`Float64[]`、`Any[]`)
            let prefix = if xs.is_empty() { &*a.elem } else { array_prefix(&a.elem) };
            // Julia は Bool の並びだけ中身を 1/0 で出す(`Bool[1, 0]`)。
            // 一つの `true` は `true` のままなので、並びの側の作法
            let body = if prefix == "Bool" {
                xs.iter()
                    .map(|v| match v {
                        Value::Bool(true) => "1".to_string(),
                        _ => "0".to_string(),
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            } else {
                xs.iter().map(show_elem).collect::<Vec<_>>().join(", ")
            };
            format!("{prefix}[{body}]")
        }
        Value::Tuple(xs) => {
            format!("({})", xs.iter().map(show_elem).collect::<Vec<_>>().join(", "))
        }
        Value::Closure(_) => "#<function>".into(),
        // Julia prints a named function as its name
        Value::Generic(n) => n.to_string(),
        Value::Module(n) => n.to_string(),
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
        // Julia は float の range では刻みをいつも書く(`1.0:3.0` も
        // `1.0:1.0:3.0` と出る)
        Value::FRange(a, s, b) => format!(
            "{}:{}:{}",
            float_repr(*a),
            float_repr(*s),
            float_repr(*b)
        ),
        Value::Struct(sv) => {
            let fs = sv.fields.borrow();
            // `error(msg)` shows as the bare message, the way real Julia's
            // ErrorException does (and the way the OCaml side already does)
            if &*sv.kind == "ErrorException" {
                if let Some((_, m)) = fs.iter().find(|(n, _)| &**n == "msg") {
                    return show(m);
                }
            }
            // Julia shows a struct as its name and its fields in order --
            // no field names (`P(1, 2)`, not `P(x=1, y=2)`)
            let body = fs
                .iter()
                .map(|(_, v)| show_elem(v))
                .collect::<Vec<_>>()
                .join(", ");
            format!("{}({})", sv.kind, body)
        }
    }
}

/// The type Julia writes in front of an array when the element type would
/// not be obvious from the elements themselves. Measured against julia 1.12:
///
///     [1, 2, 3]   [1, 2, 3]        [1, "a"]   Any[1, "a"]
///     [1.5]       [1.5]            []         Any[]
///     ["a"]       ["a"]            [true]     Bool[1]
///     [:a]        [:a]             [Q(1)]     Q[Q(1)]
///     [nothing]   [nothing]        [[1, 2]]   [[1, 2]]
///
/// 中身から出しているのではなく、その並びが持っている要素の型を見る --
/// だから `Float64[]` は空でも `Float64[]` と出るし、`Any[1, 2]` は
/// `Any[1, 2]` のまま。
fn array_prefix(elem: &str) -> &str {
    let base = elem.split_once('{').map(|(b, _)| b).unwrap_or(elem);
    match base {
        "Int64" | "Float64" | "String" | "Symbol" | "Nothing" | "Vector" | "Dict" | "Pair"
        | "Tuple" => "",
        _ => elem,
    }
}

/// How a value prints *inside* something else: a string gets its quotes back,
/// everything else is the same. (Runtime.show_elem, on the OCaml side.)
pub fn show_elem(v: &Value) -> String {
    match v {
        Value::Sym(s) => format!(":{s}"),
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

/// What a `try` leaves behind: where its catch is, and how much of the
/// machine to wind back before going there.
struct Handler {
    pc: usize,
    stack_len: usize,
    iters_len: usize,
    unpacked_len: usize,
    /// 受け止めたら、位置と呼び出しの重なりも、ここまで戻す -- 転んだところ
    /// のものを持ち歩かないように(木を歩く道の STry と同じ)
    frames_len: usize,
    line: u32,
    file: Rc<str>,
    env: Rc<RefCell<Scope>>,
}

struct Method {
    /// One entry per parameter: the type names it accepts (`["Any"]` when
    /// unannotated), as indices into `syms`.
    sig: Vec<Vec<u32>>,
    params: Vec<u32>,
    /// `f(a, xs...)` なら true。最後の引数が、余ったものをぜんぶ集める
    slurp: bool,
    /// どのファイルで declare されたか。呼ばれるのはずっとあとなので、
    /// 呼んだ側のファイルで転んだことにしないために覚えておく
    def_file: Rc<str>,
    /// 一つずつの既定値(`1 + irep`、無ければ 0)。渡されなかったところは
    /// これを、その呼び出しのスコープで作って束ねる -- Julia は既定つきの
    /// 引数を「arity のちがう method が何本かある」ものとして扱うので、
    /// 選ぶときも渡された数だけ見る
    defaults: Vec<u32>,
    kwparams: Vec<Kwparam>,
    body: u32,
    def_env: Rc<RefCell<Scope>>,
    /// Set when this is a struct's own inner constructor: `new(...)` inside
    /// the body builds THIS struct, and never re-enters a constructor.
    constructing: Option<Rc<str>>,
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
    /// `module M ... end` の中で置かれた**値**。関数と型はもう名前空間を
    /// 持っている(methods と structs が "M.name" で覚えている)けれど、値の
    /// 束縛だけが行き場を持っていなかった -- Julia では `M.x` で読める。
    module_values: HashMap<Rc<str>, Value>,
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
    /// the struct whose own constructor is running, for `new(...)`
    constructing: Vec<Rc<str>>,
    /// The scope the program's own top level ran in -- what a later
    /// `call` from the host has to see (its structs, its functions, its
    /// globals).
    global: Option<Rc<RefCell<Scope>>>,
    out: String,
    line: u32,
    /// いまどのファイルを走っているか(`File` の印が置いていく)。一枚の .tsb に
    /// 何枚か入っているので、転んだ場所を言うのに要る
    file: Rc<str>,
    /// 呼び出しの重なり: 関数の名前と、**呼んだ側**が居た行。転んだときに
    /// 「どこから来たか」を言えるように -- 木を歩く道が push_frame でして
    /// いるのと同じこと。無事に返るときだけ降ろす(転んだときは、そのままに
    /// しておく。それが読みたいものなので)
    frames: Vec<(Rc<str>, u32)>,
    /// いま関数の体の中にいるか(何段目か)。`function` の中で declare された
    /// `function` は、その呼び出しごとの closure としても束ねる -- そこを
    /// 見分けるためだけの数
    depth: u32,
}

/// `Int` is Julia's own name for `Int64` (`const Int = Int64`), so a program
/// may write either -- and `Float` is Tsubaki's shorthand for `Float64`, the
/// same way. Both are the same type; this is which spelling wins.
fn canonical(name: &str) -> &str {
    match name {
        "Int" => "Int64",
        "Float" => "Float64",
        other => other,
    }
}

/// `Tuple{Int64, Vector{Int64}}` -> `["Int64", "Vector{Int64}"]`。
/// 深さを数えて割る -- 中に入れ子があれば、そのコンマはこの階のものではない。
/// `{...}` の無い名前には何も無いので `None`。
fn type_params(name: &str) -> Option<Vec<&str>> {
    let open = name.find('{')?;
    let inner = name.get(open + 1..name.len().checked_sub(1)?)?;
    let mut out = Vec::new();
    let (mut depth, mut start) = (0i32, 0usize);
    for (i, c) in inner.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth -= 1,
            ',' if depth == 0 => {
                out.push(inner[start..i].trim());
                start = i + 1;
            }
            _ => {}
        }
    }
    let last = inner[start..].trim();
    // `Tuple{}` は「中身ゼロ個」であって、「空の名前が一つ」ではない
    if !(out.is_empty() && last.is_empty()) {
        out.push(last);
    }
    Some(out)
}

/// Julia's own tower, as much of it as dispatch here needs. Written out
/// rather than derived: it is a fact about the language, not about a program.
const BUILTIN_PARENTS: &[(&str, &str)] = &[
    ("Int64", "Signed"),
    ("Signed", "Integer"),
    ("Bool", "Integer"),
    ("Integer", "Real"),
    ("Float64", "AbstractFloat"),
    ("AbstractFloat", "Real"),
    ("Real", "Number"),
    ("Number", "Any"),
    ("String", "AbstractString"),
    ("AbstractString", "Any"),
    ("Symbol", "Any"),
    ("Vector", "Array"),
    ("Array", "AbstractArray"),
    ("AbstractArray", "Any"),
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
            module_values: HashMap::new(),
            structs: HashMap::new(),
            kwdefaults: HashMap::new(),
            parents,
            prefix: String::new(),
            outer_prefixes: Vec::new(),
            current_end: 0,
            constructing: Vec::new(),
            global: None,
            out: String::new(),
            line: 0,
            file: Rc::from(""),
            frames: Vec::new(),
            depth: 0,
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
        self.global = Some(env.clone());
        let main = self.p.main;
        self.exec(main, &env)
    }

    /// Call one of the program's functions from outside, after it has run.
    /// This is the `call` a drop's host makes (`ops.call("setup")`).
    pub fn call_toplevel(&mut self, name: &str, args: Vec<Value>) -> E<Value> {
        let env = self
            .global
            .clone()
            .ok_or("the program has not been run yet")?;
        self.call(&Rc::from(name), args, &env)
    }

    /// How far `sub` is below `sup`: 0 for the same type, 1 for its parent,
    /// and so on. `None` when it is not below it at all.
    ///
    /// This is what decides which method a call goes to. `Cat <: Pet <:
    /// Animal` means a Cat argument is 0 away from `speak(::Cat)` and 2 away
    /// from `speak(::Animal)` -- so the Cat one wins. Counting, not just
    /// "does it fit", is the whole of most-specific-wins.
    fn distance(&self, sub: &str, sup: &str) -> Option<u32> {
        let (sub, sup) = (canonical(sub), canonical(sup));
        if sub == sup {
            return Some(0);
        }
        // `Vector{Int64}` -- 中身まで書いてある名前。Julia の型引数は不変なので、
        // 相手も中身まで書いてあるなら、そっくり同じでなければ合わない
        // (`Vector{Int64}` は `Vector{Real}` ではない)。中身を言わない相手
        // (`Vector`、`Array`、`Any`)には、中身を落としてから登る。
        //
        // 中身のある名前だけがここを通る -- この関数は呼び出しのたびに
        // dispatch から来るので、`Int64` と `Any` の道に字の走査を置かない
        let sub = match sub.find('{') {
            None => sub,
            Some(i) => {
                let base = &sub[..i];
                if sup.contains('{') {
                    // Julia で共変なのは Tuple だけ -- `Tuple{Int64, Int64}` は
                    // `Tuple{Number, Number}` でもある。Vector はそうではない
                    // (`Vector{Int64}` は `Vector{Real}` ではない)ので、上の
                    // 不変のままにしておく
                    if base == "Tuple" && sup.starts_with("Tuple{") {
                        return self.tuple_distance(sub, sup);
                    }
                    return None;
                }
                if base == sup {
                    // 素の `Tuple` は、Julia では `Tuple{Vararg{Any}}` --
                    // 中身をぜんぶ `Any` と書いた形の、さらに一つ外。
                    // だから中身を言っている相手(`Tuple{Number, Number}`)の
                    // ほうが、いつでも近くなければならない。ここを 0 にすると、
                    // 素の `Tuple` が何にでも勝ってしまう
                    if base == "Tuple" {
                        return self.tuple_base_distance(sub);
                    }
                    return Some(0);
                }
                base
            }
        };
        let mut cur: Rc<str> = Rc::from(sub);
        // a cycle would be a bug in a declaration, not in a program: stop
        // rather than spin
        for d in 1..32u32 {
            match self.parents.get(&cur) {
                Some(p) => {
                    if &**p == sup {
                        return Some(d);
                    }
                    cur = p.clone();
                }
                // the chain ran out. Everything is under Any, whether or not
                // the table says so
                None => return if sup == "Any" { Some(32) } else { None },
            }
        }
        None
    }

    /// 二つの `Tuple{...}` のあいだの近さ。要素ごとに測って、いちばん遠い
    /// ものに一つ足す -- 木を歩くほうの `Types.distance_to` と同じ式にして
    /// ある。二つの runtime で、同じ method が選ばれるように。
    ///
    /// 数が合わなければ合わない(Julia の `Tuple{Int64}` は
    /// `Tuple{Int64, Int64}` ではない)。`xs...` の可変長は、まだ持っていない。
    /// `Tuple{A, B}` から、中身を言わない `Tuple` までの近さ。
    /// 中身をぜんぶ `Any` にするぶん(いちばん遠い要素)に、`Tuple{...}` から
    /// 素の `Tuple` へ落ちるぶんの一つを足す。
    fn tuple_base_distance(&self, sub: &str) -> Option<u32> {
        let mut worst = 0;
        for p in type_params(sub)? {
            worst = worst.max(self.distance(p, "Any")?);
        }
        Some(worst + 2)
    }

    fn tuple_distance(&self, sub: &str, sup: &str) -> Option<u32> {
        let (subs, sups) = (type_params(sub)?, type_params(sup)?);
        if subs.len() != sups.len() {
            return None;
        }
        let mut worst = 0;
        for (a, b) in subs.iter().zip(sups.iter()) {
            worst = worst.max(self.distance(a, b)?);
        }
        Some(1 + worst)
    }

    fn is_subtype(&self, sub: &str, sup: &str) -> bool {
        self.distance(sub, sup).is_some()
    }

    /// 二つの型の、いちばん近い共通の親。`[Cat(), Dog()]` が
    /// `Vector{Animal}` になるのは、これ(Julia の typejoin)。
    fn typejoin(&self, a: &str, b: &str) -> Rc<str> {
        let (a, b) = (canonical(a), canonical(b));
        if a == b {
            return Rc::from(a);
        }
        // Tuple は共変なので、二つの上にも Tuple が居られる --
        // Julia は `Tuple{Int64,Int64}` と `Tuple{String,Symbol}` を
        // `Tuple{Any, Any}` にする(`Any` ではなく)。長さが違えば、そこは
        // もう共通の形ではないので、下の登りかたに落ちる
        if a.starts_with("Tuple{") && b.starts_with("Tuple{") {
            if let (Some(pa), Some(pb)) = (type_params(a), type_params(b)) {
                if pa.len() == pb.len() {
                    let joined: Vec<String> = pa
                        .iter()
                        .zip(pb.iter())
                        .map(|(x, y)| self.typejoin(x, y).to_string())
                        .collect();
                    return Rc::from(format!("Tuple{{{}}}", joined.join(", ")).as_str());
                }
            }
        }
        let mut cur: Rc<str> = Rc::from(a);
        for _ in 0..32 {
            if self.is_subtype(b, &cur) {
                return cur;
            }
            match self.parents.get(&cur) {
                Some(p) => cur = p.clone(),
                None => break,
            }
        }
        Rc::from("Any")
    }

    /// `o.f` -- struct の field、Pair の `.first`/`.second`。
    fn getfield(&self, o: &Value, f: u32) -> E<Value> {
        let name = self.sym(f);
        match o {
            Value::Struct(sv) => {
                let fs = sv.fields.borrow();
                match fs.iter().find(|(n, _)| &**n == name) {
                    Some((_, v)) => Ok(v.clone()),
                    None => Err(format!("type {} has no field {name}", sv.kind)),
                }
            }
            // a Pair reads as `.first` / `.second`, the way real Julia's does
            Value::Pair(p) => match name {
                "first" => Ok(p.0.clone()),
                "second" => Ok(p.1.clone()),
                _ => Err(format!("Pair has no field {name} (only .first/.second)")),
            },
            // `M.x` -- module の中で置かれた値。入れ子の module も、そのまま
            // 次の `.` が読める(`Outer.Inner.b`)
            Value::Module(m) => {
                let full = format!("{m}.{name}");
                match self.module_values.get(full.as_str()) {
                    Some(v) => Ok(v.clone()),
                    None if self.is_module_name(&full) => Ok(Value::Module(Rc::from(full.as_str()))),
                    None => Err(format!("UndefVarError: {full} not defined")),
                }
            }
            other => Err(format!("{} is not a struct, has no fields", tag(other))),
        }
    }

    /// その名前は module か。member を一つでも持っていれば、そう見なす --
    /// `M.nope` が「M なんて名前は無い」ではなく「M.nope が無い」と言えるように。
    fn is_module_name(&self, n: &str) -> bool {
        let qp = format!("{n}.");
        self.methods.keys().any(|k| k.starts_with(&qp))
            || self.structs.keys().any(|k| k.starts_with(&qp))
            || self.module_values.keys().any(|k| k.starts_with(&qp))
    }

    /// その名前は、型の名前か。`Float64[1, 2]` を `xs[i]` と見分けるのに要る。
    fn is_type_name(&self, n: &str) -> bool {
        let n = canonical(n);
        n == "Any" || self.structs.contains_key(n) || self.parents.contains_key(n)
    }

    /// その並びに入れられる形にする。入れられないなら、そう言う。
    /// Julia は `push!([1, 2], 1.0)` を通して(1 に直して)、
    /// `push!([1, 2], "x")` は断る。
    fn coerce_elem(&self, elem: &str, v: Value) -> E<Value> {
        if &*elem == "Any" || self.is_subtype(tag(&v), elem) {
            return Ok(v);
        }
        match (elem, &v) {
            ("Float64", Value::Int(n)) => Ok(Value::Float(*n as f64)),
            ("Float64", Value::Bool(b)) => Ok(Value::Float(*b as i64 as f64)),
            ("Int64", Value::Float(f)) if f.fract() == 0.0 => Ok(Value::Int(*f as i64)),
            ("Int64", Value::Bool(b)) => Ok(Value::Int(*b as i64)),
            _ => Err(format!(
                "MethodError: Cannot `convert` an object of type {} to an object of type {elem}",
                tag(&v)
            )),
        }
    }

    /// `[...]` を建てる。要素の型は、書かれたものから決まる(elem_type_of)。
    fn arr_lit(&self, mut vs: Vec<Value>) -> Value {
        let elem = elem_type_of(&mut vs, |a, b| self.typejoin(a, b));
        arr_of(&elem, vs)
    }

    /// How well one argument fits one parameter: the distance to the nearest
    /// of its alternatives, or `None` if it fits none of them.
    fn fit(&self, alts: &[u32], v: &Value) -> Option<u32> {
        alts.iter()
            .filter_map(|a| self.distance(tag(v), self.sym(*a)))
            .min()
    }

    /// Build a struct the way its declaration says: one argument per field,
    /// in declared order, each checked against the field's own type.
    fn construct(&self, kind: &str, args: Vec<Value>) -> E<Value> {
        self.construct_maybe_partial(kind, args, false)
    }

    fn construct_maybe_partial(
        &self,
        kind: &str,
        mut args: Vec<Value>,
        allow_partial: bool,
    ) -> E<Value> {
        let def = self
            .structs
            .get(kind)
            .ok_or_else(|| format!("UndefVarError: {kind} not defined"))?;
        // `new(a)` inside a constructor may leave later fields for later --
        // they start as nothing, the same loose stand-in the OCaml side uses
        if allow_partial && args.len() < def.field_names.len() {
            args.resize(def.field_names.len(), Value::Nothing);
        }
        if def.field_names.len() != args.len() {
            return Err(format!(
                "{kind}: expected {} field(s), got {}",
                def.field_names.len(),
                args.len()
            ));
        }
        for ((v, ty), name) in args.iter().zip(&def.field_types).zip(&def.field_names) {
            if matches!(v, Value::Nothing) && allow_partial {
                continue;
            }
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

    /// The method to run for this call: the one whose parameters are nearest
    /// to what was actually passed. Julia's most-specific-wins, added up
    /// across the arguments.
    ///
    /// A tie goes to the one declared later, which is not Julia's answer
    /// (there it is an ambiguity error) -- worth saying out loud rather than
    /// pretending the ordering here is complete.
    fn pick(&self, name: &str, args: &[Value]) -> Option<usize> {
        self.resolve(name, args).ok().flatten()
    }

    /// どの method を呼ぶか。`Ok(None)` は「その名前の method が無い」、
    /// `Err` は「二本が並んで、どちらが狭いとも言えない」-- Julia は、そこを
    /// 黙って決めない。黙って別の method が選ばれるのは、いちばん見つけにくい
    /// 食い違いなので。
    fn resolve(&self, name: &str, args: &[Value]) -> Result<Option<usize>, String> {
        let Some(ms) = self.methods.get(name) else {
            return Ok(None);
        };
        // (埋めた数, 型の遠さ)の順に近いもの。数がぴったりのほうが先で、
        // そのあとで型を見る -- Julia は既定つきの引数を「arity のちがう
        // method が何本かある」ものとして扱うので、そう見えるように
        let mut best: Option<(usize, (usize, u32))> = None;
        for (i, m) in ms.iter().enumerate() {
            if let Some(score) = self.score(m, args) {
                if best.map_or(true, |(_, b)| score < b) {
                    best = Some((i, score));
                }
            }
        }
        let Some((i, (filled, _))) = best else {
            return Ok(None);
        };
        // 二本め以降が居るときだけ、並んでいないかを見る。名前に method が
        // 一本しか無いのがいちばん多い道なので、そこには何も足さない
        if ms.len() > 1 {
            for (j, m) in ms.iter().enumerate() {
                if j == i {
                    continue;
                }
                // 引数の数の扱いが違うものは、そこで先に決まっている
                if self.score(m, args).map(|(f, _)| f) != Some(filled) {
                    continue;
                }
                // どちらかが狭ければ、狭いほうが勝つ(Julia と同じ)。
                // どちらとも言えないなら、決めない
                let a = &ms[i].sig;
                let b = &m.sig;
                if !self.sig_within(a, b) && !self.sig_within(b, a) {
                    return Err(format!(
                        "MethodError: {name}({}) is ambiguous -- ({}) and ({}) are equally close",
                        args.iter().map(tag).collect::<Vec<_>>().join(", "),
                        self.show_sig(b),
                        self.show_sig(a)
                    ));
                }
            }
        }
        Ok(Some(i))
    }

    /// その method に当たるか、当たるならどれくらい近いか。
    /// `(既定で埋めた数, 型の遠さ)` -- 数がぴったりのほうが先。
    fn score(&self, m: &Method, args: &[Value]) -> Option<(usize, u32)> {
        // `f(a, xs...)` は、最後の一つが「残り全部」。数が多くても合う
        // かわりに、数がぴったりの method には負ける(+1)
        let filled = if m.slurp {
            if args.len() + 1 < m.sig.len() {
                return None;
            }
            1
        } else {
            // 渡された数がぴったりなら、既定の表は見ない -- 呼び出しのたびに
            // 通るので、いちばん多い形をいちばん短くしておく
            match m.sig.len().checked_sub(args.len()) {
                None => return None,
                Some(0) => 0,
                Some(k) => {
                    if m.defaults[args.len()..].iter().any(|d| *d == 0) {
                        return None;
                    }
                    k
                }
            }
        };
        let mut total = 0u32;
        // 最後の alt は、集めるほうなら残り全部に当たる
        let last = m.sig.len().saturating_sub(1);
        for (i, v) in args.iter().enumerate() {
            let alts = &m.sig[if m.slurp && i > last { last } else { i }];
            total += self.fit(alts, v)?;
        }
        Some((filled, total))
    }

    /// a の署名は b の署名に収まるか(どの場所でも、a の型が b の型の中)。
    /// これが Julia の「どちらが狭いか」で、遠さの合計とは別のものさし --
    /// `f(x::Int, y)` と `f(x, y::Float64)` は、`f(1, 1.0)` にどちらも当たる
    /// けれど、どちらが狭いとも言えない。
    fn sig_within(&self, a: &[Vec<u32>], b: &[Vec<u32>]) -> bool {
        a.len() == b.len()
            && a.iter().zip(b).all(|(x, y)| {
                x.iter()
                    .all(|xa| y.iter().any(|ya| self.is_subtype(self.sym(*xa), self.sym(*ya))))
            })
    }

    fn show_sig(&self, sig: &[Vec<u32>]) -> String {
        sig.iter()
            .map(|alts| alts.iter().map(|t| self.sym(*t)).collect::<Vec<_>>().join("|"))
            .collect::<Vec<_>>()
            .join(", ")
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
                        defaults: m.defaults.clone(),
                        slurp: m.slurp,
                        def_file: m.def_file.clone(),
                        kwparams: m.kwparams.clone(),
                        body: m.body,
                        def_env: m.def_env.clone(),
                        constructing: m.constructing.clone(),
                    })
                    .collect(),
                None => continue,
            };
            self.methods.entry(bare).or_default().extend(ms);
        }
        // module の中で置かれた値も、裸の名前で引けるように(関数や型と同じ扱い)
        let values: Vec<(Rc<str>, Value)> = self
            .module_values
            .iter()
            .filter_map(|(k, v)| k.strip_prefix(prefix).map(|b| (Rc::from(b), v.clone())))
            .collect();
        for (bare, v) in values {
            self.module_values.insert(bare, v);
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

    /// 引数を、その method の引数の名前に束ねる。`f(a, xs...)` の最後の一つは、
    /// 余ったものをぜんぶ集めたタプル(Julia もタプル。ゼロ個でも束ねる)。
    fn bind_args(&self, params: &[u32], slurp: bool, args: Vec<Value>, scope: &Rc<RefCell<Scope>>) -> usize {
        if !slurp || params.is_empty() {
            let given = args.len();
            for (k, v) in params.iter().zip(args) {
                bind(scope, *k, v);
            }
            return given;
        }
        let fixed = params.len() - 1;
        let mut args = args;
        let rest: Vec<Value> = if args.len() > fixed { args.split_off(fixed) } else { Vec::new() };
        for (k, v) in params.iter().zip(args) {
            bind(scope, *k, v);
        }
        bind(scope, params[fixed], tuple_of(rest));
        params.len()
    }

    /// 渡されなかった引数を、自分の既定で埋める。既定は、この呼び出しの
    /// スコープで、左から順に作る -- あとの既定が前の引数を読める(Julia も
    /// そう)。
    fn bind_defaults(
        &mut self,
        params: &[u32],
        defaults: &[u32],
        given: usize,
        scope: &Rc<RefCell<Scope>>,
    ) -> E<()> {
        for i in given..params.len() {
            let d = defaults[i];
            if d == 0 {
                return Err(format!(
                    "MethodError: {} has no default",
                    self.sym(params[i])
                ));
            }
            let v = self.exec(d - 1, scope)?;
            bind(scope, params[i], v);
        }
        Ok(())
    }

    /// keyword を取る builtin。いまは `sort` だけ -- `rev` と `by`。
    fn builtin_kw(
        &mut self,
        name: &str,
        args: &[Value],
        kwargs: &[(Rc<str>, Value)],
    ) -> Option<E<Value>> {
        let (name_is_sort, in_place) = match name {
            "sort" => (true, false),
            "sort!" => (true, true),
            _ => (false, false),
        };
        if !name_is_sort {
            return None;
        }
        let a = match args {
            [Value::Arr(a)] => a.clone(),
            _ => return Some(Err(nomethod(name, args))),
        };
        let mut rev = false;
        let mut by: Option<Value> = None;
        for (k, v) in kwargs {
            match (&**k, v) {
                ("rev", Value::Bool(b)) => rev = *b,
                ("by", f) => by = Some(f.clone()),
                (other, _) => {
                    return Some(Err(format!("MethodError: sort has no keyword argument {other}")))
                }
            }
        }
        let xs = a.borrow().clone();
        // `by` があるときは、その答えのほうを並べかえの物差しにする
        let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(xs.len());
        for x in xs {
            let k = match &by {
                None => x.clone(),
                Some(f) => match self.apply(&f.clone(), vec![x.clone()]) {
                    Ok(k) => k,
                    Err(e) => return Some(Err(e)),
                },
            };
            keyed.push((k, x));
        }
        let mut keys: Vec<Value> = keyed.iter().map(|(k, _)| k.clone()).collect();
        if let Err(e) = sort_values(&mut keys) {
            return Some(Err(e));
        }
        // 同じ物差しのものは、元の順のまま(Julia の sort も stable)
        let mut idx: Vec<usize> = (0..keyed.len()).collect();
        idx.sort_by(|i, j| value_order(&keyed[*i].0, &keyed[*j].0));
        if rev {
            idx.reverse();
        }
        let out: Vec<Value> = idx.into_iter().map(|i| keyed[i].1.clone()).collect();
        Some(Ok(if in_place {
            *a.borrow_mut() = out;
            Value::Arr(a)
        } else {
            arr_of(&a.elem, out)
        }))
    }

    /// `f(a, b; k=v)` -- keyword 引数つきの、ふつうの関数呼び出し。
    fn call_kwfunc(
        &mut self,
        name: &str,
        args: Vec<Value>,
        kwargs: Vec<(Rc<str>, Value)>,
        env: &Rc<RefCell<Scope>>,
    ) -> E<Value> {
        let idx = self.resolve(name, &args)?.ok_or_else(|| nomethod(name, &args))?;
        let (params, defaults, slurp, kwparams, body, def_env, constructing, def_file) = {
            let m = &self.methods[name][idx];
            (
                m.params.clone(),
                m.defaults.clone(),
                m.slurp,
                m.kwparams.clone(),
                m.body,
                m.def_env.clone(),
                m.constructing.clone(),
                m.def_file.clone(),
            )
        };
        let scope = Scope::child(&def_env);
        let given = self.bind_args(&params, slurp, args, &scope);
        if given < params.len() {
            self.bind_defaults(&params, &defaults, given, &scope)?;
        }
        for (k, v) in &kwargs {
            match kwparams.iter().find(|kp| self.sym(kp.name) == &**k) {
                Some(kp) => bind(&scope, kp.name, v.clone()),
                None => {
                    return Err(format!(
                        "MethodError: {name} has no keyword argument {k}"
                    ))
                }
            }
        }
        for kp in &kwparams {
            if lookup(&scope, kp.name).is_none() {
                let v = self.exec(kp.default, &scope)?;
                bind(&scope, kp.name, v);
            }
        }
        self.run_body(Rc::from(name), body, &scope, constructing, def_file)
    }

    /// 体を走らせる。呼び出しの重なりに一段積んで、**無事に返るときだけ**
    /// 降ろす -- 転んだときは、そのままにしておく。それが読みたいものなので
    /// (木を歩く道の tree_walk_impl と同じ考え)。
    fn run_body(
        &mut self,
        name: Rc<str>,
        body: u32,
        scope: &Rc<RefCell<Scope>>,
        constructing: Option<Rc<str>>,
        def_file: Rc<str>,
    ) -> E<Value> {
        let caller_line = self.line;
        let caller_file = std::mem::replace(&mut self.file, def_file);
        self.frames.push((name, caller_line));
        self.depth += 1;
        let r = match constructing {
            None => self.exec(body, scope),
            Some(kind) => {
                self.constructing.push(kind);
                let r = self.exec(body, scope);
                self.constructing.pop();
                r
            }
        };
        self.depth -= 1;
        if r.is_ok() {
            self.frames.pop();
            self.line = caller_line;
            self.file = caller_file;
        }
        r
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
        // ふつうの関数の keyword 引数。位置の引数で method を選んでから、
        // 名ざしで来たものを束ねる -- 名ざされなかった keyword は、自分の
        // 既定を、この呼び出しのスコープで作る(`call` と同じ)
        if self.methods.contains_key(name) {
            return self.call_kwfunc(name, args, kwargs, env);
        }
        if !self.structs.contains_key(name) {
            if let Some(r) = self.builtin_kw(name, &args, &kwargs) {
                return r;
            }
        }
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
            ("length", [Tuple(t)]) => Ok(Int(t.len() as i64)),
            ("length", [Dict(d)]) => Ok(Int(d.borrow().len() as i64)),
            ("length", [Str(s)]) => Ok(Int(s.chars().count() as i64)),
            ("length", [Range(a, st, b)]) => Ok(Int(if *st == 0 {
                0
            } else {
                (((b - a) / st) + 1).max(0)
            })),
            ("length", [FRange(a, st, b)]) => Ok(Int(frange_parts(*a, *st, *b).len)),
            ("isempty", [v]) => match v {
                Arr(a) => Ok(Bool(a.borrow().is_empty())),
                Dict(d) => Ok(Bool(d.borrow().is_empty())),
                Str(s) => Ok(Bool(s.is_empty())),
                other => Err(format!("isempty: not a collection, a {}", tag(other))),
            },
            ("push!", [Arr(a), v]) => match self.coerce_elem(&a.elem, v.clone()) {
                Ok(v) => {
                    a.borrow_mut().push(v);
                    Ok(Arr(a.clone()))
                }
                Err(e) => Err(e),
            },
            ("haskey", [Dict(d), k]) => {
                Ok(Bool(d.borrow().iter().any(|(k2, _)| value_eq(k2, k))))
            }
            ("get", [Dict(d), k, dflt]) => Ok(d
                .borrow()
                .iter()
                .find(|(k2, _)| value_eq(k2, k))
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| dflt.clone())),
            ("keys", [Dict(d)]) => Ok(self.arr_lit(
                d.borrow().iter().map(|(k, _)| k.clone()).collect(),
            )),
            ("values", [Dict(d)]) => Ok(self.arr_lit(
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
                        Arr(_) | Tuple(_) => match iter_values(v) {
                            Ok(xs) => out.extend(xs),
                            Err(e) => return Some(Err(e)),
                        },
                        other => out.push(other.clone()),
                    }
                }
                Ok(self.arr_lit(out))
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
                    _ => self.arr_lit(out),
                })
            }
            ("count", [f, coll]) => {
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let mut n = 0i64;
                for x in xs {
                    match self.apply(&f.clone(), vec![x]) {
                        Ok(Bool(true)) => n += 1,
                        Ok(Bool(false)) => {}
                        Ok(other) => {
                            return Some(Err(format!(
                                "count: the test must answer Bool, got a {}",
                                tag(&other)
                            )))
                        }
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(Int(n))
            }
            ("all", [f, coll]) | ("any", [f, coll]) => {
                let want_all = name == "all";
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let mut answer = want_all;
                for x in xs {
                    match self.apply(&f.clone(), vec![x]) {
                        Ok(Bool(b)) => {
                            if b != want_all {
                                answer = b;
                                break;
                            }
                        }
                        Ok(other) => {
                            return Some(Err(format!(
                                "{name}: the test must answer Bool, got a {}",
                                tag(&other)
                            )))
                        }
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(Bool(answer))
            }
            ("sum", [coll]) => {
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let all_int = xs.iter().all(|v| matches!(v, Int(_)));
                let mut fi = 0i64;
                let mut ff = 0.0f64;
                for x in &xs {
                    match x {
                        Int(n) => {
                            fi += n;
                            ff += *n as f64;
                        }
                        Float(f) => ff += f,
                        other => {
                            return Some(Err(format!("sum: not a number, a {}", tag(other))))
                        }
                    }
                }
                Ok(if all_int { Int(fi) } else { Float(ff) })
            }
            ("maximum", [coll]) | ("minimum", [coll]) => {
                let want_max = name == "maximum";
                let xs = match iter_values(coll) {
                    Ok(xs) => xs,
                    Err(e) => return Some(Err(e)),
                };
                let mut best: Option<Value> = None;
                for x in xs {
                    let take = match &best {
                        None => true,
                        Some(b) => match num_cmp(&x, b) {
                            Some(o) => (o > 0) == want_max && o != 0,
                            None => return Some(Err("maximum/minimum: not numbers".into())),
                        },
                    };
                    if take {
                        best = Some(x);
                    }
                }
                best.ok_or_else(|| format!("{name}: the collection is empty"))
            }
            ("first", [coll]) => match iter_values(coll) {
                Ok(xs) => xs.first().cloned().ok_or_else(|| "first: empty".to_string()),
                Err(e) => Err(e),
            },
            ("last", [coll]) => match iter_values(coll) {
                Ok(xs) => xs.last().cloned().ok_or_else(|| "last: empty".to_string()),
                Err(e) => Err(e),
            },
            ("firstindex", [_]) => Ok(Int(1)),
            ("lastindex", [coll]) => match coll {
                Arr(a) => Ok(Int(a.borrow().len() as i64)),
                Tuple(t) => Ok(Int(t.len() as i64)),
                Str(s) => Ok(Int(s.chars().count() as i64)),
                other => Err(format!("lastindex: not indexable, a {}", tag(other))),
            },
            ("abs", [Int(n)]) => Ok(Int(n.abs())),
            ("abs", [Float(f)]) => Ok(Float(f.abs())),
            ("sqrt", [Int(n)]) => Ok(Float((*n as f64).sqrt())),
            ("sqrt", [Float(f)]) => Ok(Float(f.sqrt())),
            ("min", [a, b]) | ("max", [a, b]) => {
                let want_max = name == "max";
                match num_cmp(a, b) {
                    Some(o) => Ok(if (o > 0) == want_max { a.clone() } else { b.clone() }),
                    None => Err(format!("{name}: not numbers")),
                }
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
                Ok(self.arr_lit(out))
            }
            _ => return self.builtin_more(name, args),
        })
    }

    /// 二枚目の builtin。上の一枚が大きくなりすぎたので、あとから足したものは
    /// こちら -- 分かれ目に意味は無くて、ただの置き場所。
    fn builtin_more(&mut self, name: &str, args: &[Value]) -> Option<E<Value>> {
        use Value::*;
        // 数を一つ取る道具。Int も Float も受ける
        let f1 = |v: &Value| -> Option<f64> {
            match v {
                Int(n) => Some(*n as f64),
                Float(f) => Some(*f),
                _ => None,
            }
        };
        Some(match (name, args) {
            // --- ビット演算。Julia では `&&`/`||` より低くない、ふつうの演算子 ---
            ("&", [Int(a), Int(b)]) => Ok(Int(a & b)),
            ("|", [Int(a), Int(b)]) => Ok(Int(a | b)),
            ("\u{22bb}", [Int(a), Int(b)]) => Ok(Int(a ^ b)),
            ("&", [Bool(a), Bool(b)]) => Ok(Bool(*a & *b)),
            ("|", [Bool(a), Bool(b)]) => Ok(Bool(*a | *b)),
            ("\u{22bb}", [Bool(a), Bool(b)]) => Ok(Bool(a != b)),
            ("<<", [Int(a), Int(b)]) => Ok(Int(a.wrapping_shl(*b as u32))),
            (">>", [Int(a), Int(b)]) => Ok(Int(a.wrapping_shr(*b as u32))),
            (">>>", [Int(a), Int(b)]) => Ok(Int(((*a as u64) >> (*b as u32)) as i64)),
            ("~", [Int(a)]) => Ok(Int(!a)),
            ("!", [Bool(a)]) => Ok(Bool(!a)),

            // --- 数 ---
            // floor/ceil/round は Julia では Float を返す(`floor(Int, x)` が Int)
            ("floor", [v]) => f1(v).map(|x| Float(x.floor())).ok_or_else(|| nomethod("floor", args)),
            ("ceil", [v]) => f1(v).map(|x| Float(x.ceil())).ok_or_else(|| nomethod("ceil", args)),
            // Julia の round は「半分は偶数へ」(RoundNearestTiesAway ではない)
            ("round", [v]) => f1(v)
                .map(|x| Float(round_half_even(x)))
                .ok_or_else(|| nomethod("round", args)),
            ("floor", [Sym(t), v]) | ("floor", [Generic(t), v]) if &**t == "Int" || &**t == "Int64" => {
                f1(v).map(|x| Int(x.floor() as i64)).ok_or_else(|| nomethod("floor", args))
            }
            ("trunc", [v]) => f1(v).map(|x| Float(x.trunc())).ok_or_else(|| nomethod("trunc", args)),
            ("div", [Int(a), Int(b)]) => {
                if *b == 0 { Err("DivideError: integer division error".into()) } else { Ok(Int(a / b)) }
            }
            ("rem", [Int(a), Int(b)]) => {
                if *b == 0 { Err("DivideError: integer division error".into()) } else { Ok(Int(a % b)) }
            }
            // Julia の `mod` は割る数の符号につく(`%`/rem とちがう)、
            // `fld` は下へ丸める割り算、`cld` は上へ
            ("mod", [Int(a), Int(b)]) => {
                if *b == 0 {
                    Err("DivideError: integer division error".into())
                } else {
                    let r = a % b;
                    Ok(Int(if r != 0 && (r < 0) != (*b < 0) { r + b } else { r }))
                }
            }
            ("fld", [Int(a), Int(b)]) => {
                if *b == 0 {
                    Err("DivideError: integer division error".into())
                } else {
                    let (q, r) = (a / b, a % b);
                    Ok(Int(if r != 0 && (r < 0) != (*b < 0) { q - 1 } else { q }))
                }
            }
            ("cld", [Int(a), Int(b)]) => {
                if *b == 0 {
                    Err("DivideError: integer division error".into())
                } else {
                    let (q, r) = (a / b, a % b);
                    Ok(Int(if r != 0 && (r < 0) == (*b < 0) { q + 1 } else { q }))
                }
            }
            ("sign", [v]) => f1(v)
                .map(|x| match v { Int(_) => Int(if x > 0.0 { 1 } else if x < 0.0 { -1 } else { 0 }), _ => Float(if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { x }) })
                .ok_or_else(|| nomethod("sign", args)),
            ("exp", [v]) => f1(v).map(|x| Float(x.exp())).ok_or_else(|| nomethod("exp", args)),
            ("log", [v]) => f1(v).map(|x| Float(x.ln())).ok_or_else(|| nomethod("log", args)),
            ("log2", [v]) => f1(v).map(|x| Float(x.log2())).ok_or_else(|| nomethod("log2", args)),
            ("log10", [v]) => f1(v).map(|x| Float(x.log10())).ok_or_else(|| nomethod("log10", args)),
            ("sin", [v]) => f1(v).map(|x| Float(x.sin())).ok_or_else(|| nomethod("sin", args)),
            ("cos", [v]) => f1(v).map(|x| Float(x.cos())).ok_or_else(|| nomethod("cos", args)),
            ("tan", [v]) => f1(v).map(|x| Float(x.tan())).ok_or_else(|| nomethod("tan", args)),
            ("atan", [v]) => f1(v).map(|x| Float(x.atan())).ok_or_else(|| nomethod("atan", args)),
            ("atan", [a, b]) => match (f1(a), f1(b)) {
                (Some(x), Some(y)) => Ok(Float(x.atan2(y))),
                _ => Err(nomethod("atan", args)),
            },
            ("hypot", [a, b]) => match (f1(a), f1(b)) {
                (Some(x), Some(y)) => Ok(Float(x.hypot(y))),
                _ => Err(nomethod("hypot", args)),
            },
            ("isqrt", [Int(n)]) => Ok(Int((*n as f64).sqrt().floor() as i64)),
            ("clamp", [v, lo, hi]) => match (f1(v), f1(lo), f1(hi)) {
                (Some(x), Some(l), Some(h)) => Ok(match v {
                    Int(_) => Int(x.max(l).min(h) as i64),
                    _ => Float(x.max(l).min(h)),
                }),
                _ => Err(nomethod("clamp", args)),
            },
            ("prod", [coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                let mut all_int = true;
                let mut acc = 1.0f64;
                let mut iacc = 1i64;
                for x in &xs {
                    match x {
                        Int(n) => { iacc = iacc.wrapping_mul(*n); acc *= *n as f64 }
                        Float(f) => { all_int = false; acc *= f }
                        other => return Some(Err(format!("prod: not a number, a {}", tag(other)))),
                    }
                }
                Ok(if all_int { Int(iacc) } else { Float(acc) })
            }

            // --- 型の名前を、変えるはたらきとして呼ぶ ---
            ("Int", [v]) | ("Int64", [v]) => match v {
                Int(n) => Ok(Int(*n)),
                Float(f) if f.fract() == 0.0 => Ok(Int(*f as i64)),
                Float(_) => Err("InexactError: Int64 wants a whole number".into()),
                Bool(b) => Ok(Int(*b as i64)),
                other => Err(format!("MethodError: no method matching Int64({})", tag(other))),
            },
            ("Float", [v]) | ("Float64", [v]) => f1(v)
                .map(Float)
                .ok_or_else(|| format!("MethodError: no method matching Float64({})", tag(v))),
            ("Bool", [v]) => match v {
                Bool(b) => Ok(Bool(*b)),
                Int(n) => Ok(Bool(*n != 0)),
                other => Err(format!("MethodError: no method matching Bool({})", tag(other))),
            },
            ("parse", [Sym(t) | Generic(t), Str(s)]) => match &**t {
                "Int" | "Int64" => s.trim().parse::<i64>().map(Int).map_err(|_| {
                    format!("ArgumentError: cannot parse {:?} as an Int64", &**s)
                }),
                "Float" | "Float64" => s.trim().parse::<f64>().map(Float).map_err(|_| {
                    format!("ArgumentError: cannot parse {:?} as a Float64", &**s)
                }),
                other => Err(format!("parse: {other} is not a type this knows")),
            },

            // --- 文字列 ---
            ("uppercase", [Str(s)]) => Ok(Str(Rc::from(s.to_uppercase().as_str()))),
            ("lowercase", [Str(s)]) => Ok(Str(Rc::from(s.to_lowercase().as_str()))),
            ("strip", [Str(s)]) => Ok(Str(Rc::from(s.trim()))),
            ("lstrip", [Str(s)]) => Ok(Str(Rc::from(s.trim_start()))),
            ("rstrip", [Str(s)]) => Ok(Str(Rc::from(s.trim_end()))),
            ("startswith", [Str(s), Str(p)]) => Ok(Bool(s.starts_with(&**p))),
            ("endswith", [Str(s), Str(p)]) => Ok(Bool(s.ends_with(&**p))),
            ("occursin", [Str(needle), Str(hay)]) => Ok(Bool(hay.contains(&**needle))),
            ("repeat", [Str(s), Int(n)]) => Ok(Str(Rc::from(s.repeat((*n).max(0) as usize).as_str()))),
            ("repeat", [Arr(a), Int(n)]) => {
                let xs = a.borrow();
                let mut out = Vec::with_capacity(xs.len() * (*n).max(0) as usize);
                for _ in 0..(*n).max(0) { out.extend(xs.iter().cloned()) }
                Ok(arr_of(&a.elem, out))
            }
            ("replace", [Str(s), Pair(p)]) => match (&p.0, &p.1) {
                (Str(from), Str(to)) => Ok(Str(Rc::from(s.replace(&**from, to).as_str()))),
                _ => Err("replace: wants a String => String".into()),
            },
            ("split", [Str(s)]) => Ok(self.arr_lit(
                s.split_whitespace().map(|w| Str(Rc::from(w))).collect(),
            )),
            ("split", [Str(s), Str(sep)]) => Ok(self.arr_lit(
                s.split(&**sep).map(|w| Str(Rc::from(w))).collect(),
            )),
            ("join", [coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                Ok(Str(Rc::from(xs.iter().map(show).collect::<Vec<_>>().join("").as_str())))
            }
            ("join", [coll, Str(sep)]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                Ok(Str(Rc::from(xs.iter().map(show).collect::<Vec<_>>().join(sep).as_str())))
            }

            // --- 集まり ---
            ("identity", [v]) => Ok(v.clone()),
            ("collect", [coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                Ok(self.arr_lit(xs))
            }
            ("zeros", [Int(n)]) => Ok(arr_of("Float64", vec![Float(0.0); (*n).max(0) as usize])),
            ("ones", [Int(n)]) => Ok(arr_of("Float64", vec![Float(1.0); (*n).max(0) as usize])),
            ("reverse", [Str(s)]) => Ok(Str(Rc::from(s.chars().rev().collect::<String>().as_str()))),
            ("reverse", [Arr(a)]) => {
                let mut xs = a.borrow().clone();
                xs.reverse();
                Ok(arr_of(&a.elem, xs))
            }
            ("reverse!", [Arr(a)]) => {
                a.borrow_mut().reverse();
                Ok(Arr(a.clone()))
            }
            ("sort", [Arr(a)]) => {
                let mut xs = a.borrow().clone();
                if let Err(e) = sort_values(&mut xs) { return Some(Err(e)) }
                Ok(arr_of(&a.elem, xs))
            }
            ("sort!", [Arr(a)]) => {
                let mut xs = a.borrow().clone();
                if let Err(e) = sort_values(&mut xs) { return Some(Err(e)) }
                *a.borrow_mut() = xs;
                Ok(Arr(a.clone()))
            }
            ("pop!", [Arr(a)]) => a
                .borrow_mut()
                .pop()
                .ok_or_else(|| "ArgumentError: array must be non-empty".to_string()),
            ("popfirst!", [Arr(a)]) => {
                let mut xs = a.borrow_mut();
                if xs.is_empty() {
                    Err("ArgumentError: array must be non-empty".into())
                } else {
                    Ok(xs.remove(0))
                }
            }
            ("pushfirst!", [Arr(a), v]) => match self.coerce_elem(&a.elem, v.clone()) {
                Ok(v) => {
                    a.borrow_mut().insert(0, v);
                    Ok(Arr(a.clone()))
                }
                Err(e) => Err(e),
            },
            ("insert!", [Arr(a), Int(i), v]) => {
                let mut xs = a.borrow_mut();
                if *i < 1 || *i as usize > xs.len() + 1 {
                    Err(format!("BoundsError: index {i}"))
                } else {
                    drop(xs);
                    match self.coerce_elem(&a.elem, v.clone()) {
                        Ok(v) => {
                            a.borrow_mut().insert(*i as usize - 1, v);
                            Ok(Arr(a.clone()))
                        }
                        Err(e) => Err(e),
                    }
                }
            }
            ("deleteat!", [Arr(a), Int(i)]) => {
                let mut xs = a.borrow_mut();
                if *i < 1 || *i as usize > xs.len() {
                    Err(format!("BoundsError: index {i}"))
                } else {
                    xs.remove(*i as usize - 1);
                    drop(xs);
                    Ok(Arr(a.clone()))
                }
            }
            ("append!", [Arr(a), coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                for x in xs {
                    match self.coerce_elem(&a.elem, x) {
                        Ok(x) => a.borrow_mut().push(x),
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(Arr(a.clone()))
            }
            ("unique", [coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                let mut out: Vec<Value> = Vec::new();
                for x in xs {
                    if !out.iter().any(|y| value_eq(y, &x)) { out.push(x) }
                }
                Ok(self.arr_lit(out))
            }
            ("in", [x, coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                Ok(Bool(xs.iter().any(|y| value_eq(y, x))))
            }
            ("findfirst", [f, coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                for (i, x) in xs.into_iter().enumerate() {
                    match self.apply(&f.clone(), vec![x]) {
                        Ok(Bool(true)) => return Some(Ok(Int(i as i64 + 1))),
                        Ok(Bool(false)) => {}
                        Ok(other) => {
                            return Some(Err(format!(
                                "findfirst: the test must answer Bool, got a {}",
                                tag(&other)
                            )))
                        }
                        Err(e) => return Some(Err(e)),
                    }
                }
                Ok(Nothing)
            }
            // enumerate も zip も、Julia では怠けものだけれど、ここでは並べて
            // 渡す -- for が回すためだけに使われるので、見分けはつかない
            ("enumerate", [coll]) => {
                let xs = match iter_values(coll) { Ok(xs) => xs, Err(e) => return Some(Err(e)) };
                Ok(self.arr_lit(
                    xs.into_iter()
                        .enumerate()
                        .map(|(i, x)| tuple_of(vec![Int(i as i64 + 1), x]))
                        .collect(),
                ))
            }
            ("zip", [a, b]) => {
                let (xs, ys) = match (iter_values(a), iter_values(b)) {
                    (Ok(x), Ok(y)) => (x, y),
                    (Err(e), _) | (_, Err(e)) => return Some(Err(e)),
                };
                Ok(self.arr_lit(
                    xs.into_iter()
                        .zip(ys)
                        .map(|(x, y)| tuple_of(vec![x, y]))
                        .collect(),
                ))
            }
            _ => return None,
        })
    }

    /// Calling a value rather than a name: a closure, and nothing else here.
    fn apply(&mut self, f: &Value, args: Vec<Value>) -> E<Value> {
        match f {
            // re-enters dispatch on each call, so it really is the whole
            // generic function -- not the one method that happened to exist
            // when the name was read
            Value::Generic(n) => {
                let n = n.clone();
                let env = self.global.clone().ok_or("nothing has been run yet")?;
                self.call(&n, args, &env)
            }
            Value::Closure(c) => {
                // 内側の `function` から来たもので、引数が自分に合わないなら、
                // 名前での dispatch にもどす(同じ名前のきょうだいが居る)
                if let Some((name, sig)) = &c.inner {
                    let fits = sig.len() == args.len()
                        && sig.iter().zip(&args).all(|(alts, v)| self.fit(alts, v).is_some());
                    if !fits {
                        let name = name.clone();
                        let env = self.global.clone().ok_or("nothing has been run yet")?;
                        return self.call(&name, args, &env);
                    }
                }
                let scope = Scope::child(&c.env);
                for (k, v) in c.params.iter().zip(args) {
                    bind(&scope, *k, v);
                }
                self.depth += 1;
                let r = self.exec(c.body, &scope);
                self.depth -= 1;
                r
            }
            other => Err(format!(
                "MethodError: objects of type {} are not callable",
                tag(other)
            )),
        }
    }

    /// Call by a name spelled out in full (a qualified call, `M.f(...)`).
    /// `c[i]`。組み込みの形はそのまま index_get へ、それ以外は
    /// `getindex(c, i)` の method に訊く -- 自分の中身を並びとして持っている
    /// 型が、組み込みのものと同じ綴りで書けるように。組み込みが先に勝つので、
    /// Array / Tuple / Dict の意味も速さも、今までのまま。
    fn index_or_dispatch(&mut self, c: Value, i: Value, env: &Rc<RefCell<Scope>>) -> E<Value> {
        match &c {
            Value::Arr(_) | Value::Tuple(_) | Value::Dict(_) => index_get(&c, &i),
            _ => self.call(&Rc::from("getindex"), vec![c, i], env),
        }
    }

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
        // `new(...)`: only inside a struct's own constructor, and it builds
        // the raw struct rather than re-entering a constructor (which is what
        // would make it recurse forever)
        if &*name == "new" {
            return match self.constructing.last() {
                Some(k) => {
                    let k = k.clone();
                    self.construct_maybe_partial(&k, args, true)
                }
                None => Err(
                    "UndefVarError: new can only be used inside a struct's own inner constructor"
                        .into(),
                ),
            };
        }
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
        if self.resolve(&name, &args)?.is_none() {
            if let Some(r) = self.builtin(&name, &args) {
                return r;
            }
        }
        let idx = self.resolve(&name, &args)?.ok_or_else(|| nomethod(&name, &args))?;
        let (params, defaults, slurp, kwparams, body, def_env, constructing, def_file) = {
            let m = &self.methods[&name][idx];
            // 既定で埋めるものが無いなら、既定の表は写さない -- 呼び出しごとに
            // 一つ増える確保で、fib の内側では、それがそのまま値段になる
            let defaults = if args.len() < m.params.len() {
                m.defaults.clone()
            } else {
                Vec::new()
            };
            (
                m.params.clone(),
                defaults,
                m.slurp,
                m.kwparams.clone(),
                m.body,
                m.def_env.clone(),
                m.constructing.clone(),
                m.def_file.clone(),
            )
        };
        let scope = Scope::child(&def_env);
        let given = self.bind_args(&params, slurp, args, &scope);
        if given < params.len() {
            self.bind_defaults(&params, &defaults, given, &scope)?;
        }
        // a keyword parameter the caller did not name takes its own default,
        // made now, in this call's own scope
        for kp in &kwparams {
            if lookup(&scope, kp.name).is_none() {
                let v = self.exec(kp.default, &scope)?;
                bind(&scope, kp.name, v);
            }
        }
        self.run_body(name, body, &scope, constructing, def_file)
    }

    /// 転んだところを、読める形に。木を歩く道と同じ並びで、いちばん内側から。
    pub fn report(&self, msg: &str) -> String {
        let mut s = String::from(msg);
        if !self.file.is_empty() {
            s.push_str(&format!("\n  at {}:{}", self.file, self.line));
        } else if self.line > 0 {
            s.push_str(&format!("\n  at line {}", self.line));
        }
        if !self.frames.is_empty() {
            s.push_str("\n  in:");
            for (name, line) in self.frames.iter().rev() {
                s.push_str(&format!("\n    {name}, called from line {line}"));
            }
        }
        s
    }

    /// Run one irep. `try` is why this is two functions: an error travels out
    /// of the inner one the way Rust errors do, and this one catches it,
    /// winds the machine back to where the `try` was, and carries on from the
    /// catch. The state a handler has to restore lives here, outside the loop.
    fn exec(&mut self, irep: u32, env0: &Rc<RefCell<Scope>>) -> E<Value> {
        let prog = Rc::clone(&self.p);
        let code = &prog.ireps[irep as usize];
        let mut stack: Vec<Value> = Vec::with_capacity(32);
        // for のネストの分だけ積む -- 値のスタックには置けない
        let mut iters: Vec<Iter> = Vec::new();
        // 分解代入のあいだだけ、右辺をばらしたものを覚えておく(Elem が取り出す)。
        // ネストするので積む -- 一つの irep の中だけの話なので、ここに置く
        let mut unpacked: Vec<Vec<Value>> = Vec::new();
        let mut handlers: Vec<Handler> = Vec::new();
        let mut env = env0.clone();
        let mut from = 0usize;
        loop {
            match self.exec_from(
                code,
                &mut stack,
                &mut iters,
                &mut unpacked,
                &mut handlers,
                &mut env,
                from,
            ) {
                Ok(v) => return Ok(v),
                Err(e) => match handlers.pop() {
                    None => return Err(e),
                    Some(h) => {
                        // 投げられたところで積まれていたものは、みんな捨てる
                        stack.truncate(h.stack_len);
                        iters.truncate(h.iters_len);
                        unpacked.truncate(h.unpacked_len);
                        self.frames.truncate(h.frames_len);
                        self.line = h.line;
                        self.file = h.file.clone();
                        env = h.env;
                        stack.push(self.thrown(&e));
                        from = h.pc;
                    }
                },
            }
        }
    }

    /// What `catch e` binds. A message is all this VM carries, so it comes
    /// back as the `ErrorException` it went out as -- `e.msg` reads, and
    /// printing one shows the bare message (Julia's own ErrorException does
    /// both).
    fn thrown(&self, msg: &str) -> Value {
        Value::Struct(Rc::new(StructVal {
            kind: Rc::from("ErrorException"),
            fields: RefCell::new(vec![(Rc::from("msg"), Value::Str(Rc::from(msg)))]),
        }))
    }

    #[allow(clippy::too_many_arguments)]
    fn exec_from(
        &mut self,
        code: &[Instr],
        stack: &mut Vec<Value>,
        iters: &mut Vec<Iter>,
        unpacked: &mut Vec<Vec<Value>>,
        handlers: &mut Vec<Handler>,
        env: &mut Rc<RefCell<Scope>>,
        from: usize,
    ) -> E<Value> {
        let mut pc = from;
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
                    let v = match lookup(env, *s) {
                        Some(v) => v,
                        // not a bound variable -- a bare FUNCTION name used as
                        // a plain expression is that function, as a value
                        None => {
                            let name = self.sym_rc[*s as usize].clone();
                            // builtin と型の名前も、値として渡せる
                            // (`map(length, xs)`、`floor(Int, x)`)
                            if let Some(v) = self.module_values.get(&name) {
                                v.clone()
                            } else if self.methods.contains_key(&name) || is_builtin_name(&name) {
                                Value::Generic(name)
                            } else if self.is_module_name(&name) {
                                // `module M ... end` そのもの。次の `.` が
                                // member を読む(getfield の Module の枝)
                                Value::Module(name)
                            } else {
                                return Err(format!(
                                    "UndefVarError: {} not defined",
                                    self.sym(*s)
                                ));
                            }
                        }
                    };
                    stack.push(v);
                    pc += 1;
                }
                Instr::Store(s, _) => {
                    let v = stack.last().ok_or("vm: Store with an empty stack")?.clone();
                    assign(env, *s, v);
                    pc += 1;
                }
                Instr::StorePlain(s) => {
                    let v = stack.last().ok_or("vm: Store with an empty stack")?.clone();
                    assign(env, *s, v);
                    pc += 1;
                }
                Instr::Bind(s) => {
                    let v = stack.pop().ok_or("vm: Bind with an empty stack")?;
                    bind(env, *s, v);
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
                    // a local holding a function wins over the name -- `f(x)`
                    // inside `each(f, xs)` means the one that was passed in
                    let v = match lookup(env, *s) {
                        Some(f @ (Value::Closure(_) | Value::Generic(_))) => {
                            self.apply(&f, args)?
                        }
                        _ => {
                            let name = self.sym_rc[*s as usize].clone();
                            self.call(&name, args, env)?
                        }
                    };
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
                    *env = Scope::child(env);
                    pc += 1;
                }
                Instr::Leave => {
                    let parent = env.borrow().parent.clone();
                    *env = parent.ok_or("vm: Leave at the top scope")?;
                    pc += 1;
                }
                Instr::Line(n) => {
                    self.line = *n;
                    pc += 1;
                }
                Instr::File(n) => {
                    self.file = self.sym_rc[*n as usize].clone();
                    pc += 1;
                }
                Instr::Defun(i) => {
                    let f = self.p.funcs[*i as usize].clone();
                    let m = Method {
                        sig: f.params.iter().map(|p| p.types.clone()).collect(),
                        params: f.params.iter().map(|p| p.name).collect(),
                        defaults: f.params.iter().map(|p| p.default).collect(),
                        slurp: f.params.last().is_some_and(|p| p.slurp),
                        def_file: self.file.clone(),
                        kwparams: f.kwparams.clone(),
                        body: f.body,
                        def_env: env.clone(),
                        constructing: None,
                    };
                    let full: Rc<str> = if self.prefix.is_empty() {
                        self.sym_rc[f.name as usize].clone()
                    } else {
                        Rc::from(format!("{}{}", self.prefix, self.sym(f.name)).as_str())
                    };
                    // 同じ署名で書き直したら、置きかえる(Julia もそう)。
                    // 積むだけにすると、同点が二本ならんで ambiguous になる
                    let ms = self.methods.entry(full).or_default();
                    ms.retain(|old| !(old.sig == m.sig && old.slurp == m.slurp));
                    ms.push(m);
                    // 関数の中で declare された `function` は、その呼び出し
                    // ごとの closure でもある -- 名前だけの method にすると、
                    // 工場を二度呼んでも二つにならない(あとの declare が前を
                    // 置きかえて、配った値がぜんぶ同じものを指す)。Julia は
                    // 内側の名前つき関数を closure として扱うので、そちらに
                    // 合わせる。kwargs つきは closure の道が positional しか
                    // 渡さないので、いままでどおり method だけ
                    if self.depth > 0 && f.kwparams.is_empty() {
                        let c = Value::Closure(Rc::new(Closure {
                            params: f.params.iter().map(|p| p.name).collect(),
                            body: f.body,
                            env: env.clone(),
                            inner: Some((
                                self.sym_rc[f.name as usize].clone(),
                                f.params.iter().map(|p| p.types.clone()).collect(),
                            )),
                        }));
                        bind(env, f.name, c);
                    }
                    pc += 1;
                }
                Instr::Ret => {
                    return Ok(stack.pop().unwrap_or(Value::Nothing));
                }
                // --- 値を作る ---
                Instr::Makearr(n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    let v = self.arr_lit(vs);
                    stack.push(v);
                    pc += 1;
                }
                Instr::Maketuple(n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    stack.push(tuple_of(vs));
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
                Instr::Typeof => {
                    let v = stack.pop().ok_or("vm: typeof wants a value")?;
                    // Tsubaki has no first-class type value, so this is the
                    // NAME -- which is what it prints as either way
                    stack.push(Value::Str(Rc::from(tag(&v))));
                    pc += 1;
                }
                Instr::Isa(t) => {
                    let v = stack.pop().ok_or("vm: isa wants a value")?;
                    let name = self.sym(*t).to_string();
                    stack.push(Value::Bool(self.is_subtype(tag(&v), &name)));
                    pc += 1;
                }
                Instr::Subtype(a, b) => {
                    let (x, y) = (self.sym(*a).to_string(), self.sym(*b).to_string());
                    stack.push(Value::Bool(self.is_subtype(&x, &y)));
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
                    self.structs.insert(name.clone(), def);
                    // a struct with at least one constructor of its own is
                    // built through those instead of directly
                    for c in &st.ctors {
                        let m = Method {
                            sig: c.params.iter().map(|p| p.types.clone()).collect(),
                            params: c.params.iter().map(|p| p.name).collect(),
                            defaults: c.params.iter().map(|p| p.default).collect(),
                            slurp: c.params.last().is_some_and(|p| p.slurp),
                            def_file: self.file.clone(),
                            kwparams: c.kwparams.clone(),
                            body: c.body,
                            def_env: env.clone(),
                            constructing: Some(name.clone()),
                        };
                        let ms = self.methods.entry(name.clone()).or_default();
                        ms.retain(|old| !(old.sig == m.sig && old.slurp == m.slurp));
                        ms.push(m);
                    }
                    pc += 1;
                }
                Instr::Defabstract(n, parent) => {
                    let name: Rc<str> =
                        Rc::from(format!("{}{}", self.prefix, self.sym(*n)).as_str());
                    self.parents.insert(name, Rc::from(self.sym(*parent)));
                    pc += 1;
                }
                // --- module ---
                // 体は自分のスコープで走る。そこに置かれた値は、この module の
                // member になる(`M.x` で読める)-- 関数と型はもう名前空間を
                // 持っていたので、行き場が無かったのは値の束縛だけだった
                Instr::ModuleEnter(s) => {
                    self.outer_prefixes.push(self.prefix.clone());
                    self.prefix = format!("{}{}.", self.prefix, self.sym(*s));
                    *env = Scope::child(env);
                    pc += 1;
                }
                Instr::ModuleLeave => {
                    let prefix = self.prefix.clone();
                    for (k, v) in env.borrow().vars.iter() {
                        let full: Rc<str> = Rc::from(format!("{}{}", prefix, self.sym(*k)).as_str());
                        self.module_values.insert(full, v.clone());
                    }
                    let parent = env.borrow().parent.clone();
                    *env = parent.ok_or("vm: ModuleLeave at the top scope")?;
                    self.prefix = self
                        .outer_prefixes
                        .pop()
                        .ok_or("vm: ModuleLeave outside a module")?;
                    pc += 1;
                }
                // --- field ---
                Instr::Getfield(f) => {
                    let o = stack.pop().ok_or("vm: Getfield with an empty stack")?;
                    let v = self.getfield(&o, *f)?;
                    stack.push(v);
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
                    let v = self.index_or_dispatch(c, i, env)?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::IndexSet => {
                    let v = stack.pop().ok_or("vm: IndexSet wants a value")?;
                    let i = stack.pop().ok_or("vm: IndexSet wants a subscript")?;
                    let c = stack.pop().ok_or("vm: IndexSet wants a container")?;
                    match &c {
                        Value::Arr(a) => {
                            let stored = self.coerce_elem(&a.elem, v.clone())?;
                            index_set(&c, &i, stored)?;
                        }
                        Value::Dict(_) => index_set(&c, &i, v.clone())?,
                        // 組み込みでないものは `setindex!(a, v, i)` の method に
                        // 訊く -- Julia と同じ並び。Tuple もここに来て、Julia と
                        // 同じ MethodError になる
                        _ => {
                            self.call(&Rc::from("setindex!"), vec![c, v.clone(), i], env)?;
                        }
                    }
                    stack.push(v);
                    pc += 1;
                }
                // `name[...]` は、name が変数か型の名前かで意味が変わる
                // (`xs[i]` と `Float64[1, 2]` は、書かれた形が同じ)。変数なら
                // 入れものを積んで、型なら何も積まない -- どちらだったかは
                // Index_or_typed がもう一度おなじ名前を引いて決める
                Instr::LoadIndex(s, _) => {
                    match lookup(env, *s) {
                        Some(v) => {
                            self.current_end = match &v {
                                Value::Arr(a) => a.borrow().len() as i64,
                                Value::Tuple(t) => t.len() as i64,
                                _ => self.current_end,
                            };
                            stack.push(v);
                        }
                        None if self.is_type_name(self.sym(*s)) => {}
                        None => {
                            return Err(format!(
                                "UndefVarError: {} not defined",
                                self.sym(*s)
                            ))
                        }
                    }
                    pc += 1;
                }
                Instr::IndexOrTyped(s) => {
                    let i = stack.pop().ok_or("vm: Index wants a subscript")?;
                    match lookup(env, *s) {
                        Some(_) => {
                            let c = stack.pop().ok_or("vm: Index wants a container")?;
                            let v = self.index_or_dispatch(c, i, env)?;
                            stack.push(v);
                        }
                        // `Float64[1, 2]` / `Named[]` -- 書かれた要素の型を
                        // 持つ並び。中身が空になっても、型は覚えている
                        None => {
                            let elem = canonical(self.sym(*s)).to_string();
                            let vs = match i {
                                Value::Tuple(t) => t.cells.clone(),
                                one => vec![one],
                            };
                            let mut out = Vec::with_capacity(vs.len());
                            for v in vs {
                                let was = tag(&v).to_string();
                                match self.coerce_elem(&elem, v) {
                                    Ok(v) => out.push(v),
                                    Err(_) => {
                                        return Err(format!(
                                            "TypeError: Array{{{elem}}} cannot hold a {was}"
                                        ))
                                    }
                                }
                            }
                            stack.push(arr_of(&elem, out));
                        }
                    }
                    pc += 1;
                }
                // --- 繰り返し ---
                Instr::Range => {
                    let hi = stack.pop().ok_or("vm: a range wants two ends")?;
                    let lo = stack.pop().ok_or("vm: a range wants two ends")?;
                    stack.push(make_range(&lo, &Value::Int(1), &hi)?);
                    pc += 1;
                }
                Instr::Range3 => {
                    let hi = stack.pop().ok_or("vm: a range wants three")?;
                    let st = stack.pop().ok_or("vm: a range wants three")?;
                    let lo = stack.pop().ok_or("vm: a range wants three")?;
                    stack.push(make_range(&lo, &st, &hi)?);
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
                Instr::IterDrop => {
                    // break -- 最後まで行かずに降りる
                    iters.pop();
                    pc += 1;
                }
                Instr::BindTuple(names) => {
                    let v = stack.pop().ok_or("vm: BindTuple with an empty stack")?;
                    match &v {
                        Value::Tuple(t) if t.len() == names.len() => {
                            for (n, x) in names.iter().zip(t.iter()) {
                                bind(env, *n, x.clone());
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
                                let scope = Scope::child(env);
                                bind_target(&scope, &c.targets[0], v)?;
                                // `if` があれば、値を作る前に決める
                                if c.cond > 0 {
                                    match self.exec(c.cond - 1, &scope)? {
                                        Value::Bool(true) => {}
                                        Value::Bool(false) => continue,
                                        other => {
                                            return Err(format!(
                                                "a comprehension's `if` must be Bool, got a {}",
                                                tag(&other)
                                            ))
                                        }
                                    }
                                }
                                out.push(self.exec(body, &scope)?);
                            }
                            let v = self.arr_lit(out);
                            stack.push(v);
                        }
                        2 => {
                            let s2 = stack.pop().ok_or("vm: a comprehension wants two sources")?;
                            let s1 = stack.pop().ok_or("vm: a comprehension wants two sources")?;
                            let vs2 = iter_values(&s2)?;
                            let mut rows = Vec::new();
                            for v1 in iter_values(&s1)? {
                                let mut row = Vec::new();
                                for v2 in &vs2 {
                                    let scope = Scope::child(env);
                                    bind_target(&scope, &c.targets[0], v1.clone())?;
                                    bind_target(&scope, &c.targets[1], v2.clone())?;
                                    row.push(self.exec(body, &scope)?);
                                }
                                rows.push(self.arr_lit(row));
                            }
                            let v = self.arr_lit(rows);
                            stack.push(v);
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
                        inner: None,
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
                    let v = self.call_named(&qualified, args, env)?;
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
                    let v = self.call_kw(&name, args, kwargs, env)?;
                    stack.push(v);
                    pc += 1;
                }
                // --- 分解代入 `a, b = ...` ---
                // 右辺は積まれたまま(分解代入そのものの値なので)、ばらした
                // ものを脇に覚えておく。Julia は並べられるものなら何でも
                // ばらすので、Tuple にかぎらない
                Instr::UnpackCheck(n) => {
                    let v = stack.last().ok_or("vm: UnpackCheck with an empty stack")?;
                    let vs = iter_values(v).map_err(|_| {
                        format!("cannot destructure a {} into {} targets", tag(v), n)
                    })?;
                    if vs.len() < *n as usize {
                        return Err(format!(
                            "BoundsError: attempt to access {}-element {} at index [{}]",
                            vs.len(),
                            tag(v),
                            n
                        ));
                    }
                    unpacked.push(vs);
                    pc += 1;
                }
                Instr::Elem(i) => {
                    let vs = unpacked.last().ok_or("vm: Elem outside a destructure")?;
                    stack.push(vs[*i as usize].clone());
                    pc += 1;
                }
                Instr::UnpackEnd => {
                    unpacked.pop();
                    pc += 1;
                }
                // `x::Int = ...` と、分解代入の一つずつの `::T`。値は残す
                Instr::Typecheck(name, types) => {
                    let v = stack.last().ok_or("vm: Typecheck with an empty stack")?;
                    if !types.iter().any(|t| self.is_subtype(tag(v), self.sym(*t))) {
                        return Err(format!(
                            "TypeError: {}::{} cannot hold a {}",
                            self.sym(*name),
                            types
                                .iter()
                                .map(|t| self.sym(*t))
                                .collect::<Vec<_>>()
                                .join("|"),
                            tag(v)
                        ));
                    }
                    pc += 1;
                }
                // --- 要素の型が書いてある並び ---
                // `Float64[1, 2]` / `Named[]` / `Array{Named}()`。ふつうの
                // `[...]` は中身から型を決めるが、こちらは書かれたほうが本当で、
                // 空になっても覚えている
                Instr::Typedarr(t, n) => {
                    let at = stack.len() - *n as usize;
                    let vs: Vec<Value> = stack.split_off(at);
                    let elem = canonical(self.sym(*t)).to_string();
                    let mut out = Vec::with_capacity(vs.len());
                    for v in vs {
                        let was = tag(&v).to_string();
                        match self.coerce_elem(&elem, v) {
                            Ok(v) => out.push(v),
                            Err(_) => {
                                return Err(format!(
                                    "TypeError: Array{{{elem}}} cannot hold a {was}"
                                ))
                            }
                        }
                    }
                    stack.push(arr_of(&elem, out));
                    pc += 1;
                }
                // `Vector{T}(undef, n)`。Julia の中身は決まっていない(読む前に
                // 書くためのもの)ので、ここは数なら 0、そうでなければ nothing で
                // 埋めておく -- 決まっていないものを、決まった形で置く
                Instr::TypedarrUndef(t) => {
                    let n = match stack.pop() {
                        Some(Value::Int(n)) if n >= 0 => n as usize,
                        Some(other) => {
                            return Err(format!(
                                "Vector{{{}}}(undef, n): n must be a non-negative Int, got a {}",
                                self.sym(*t),
                                tag(&other)
                            ))
                        }
                        None => return Err("vm: TypedarrUndef wants a length".into()),
                    };
                    let elem = canonical(self.sym(*t)).to_string();
                    let fill = match &*elem {
                        "Int64" => Value::Int(0),
                        "Float64" => Value::Float(0.0),
                        "Bool" => Value::Bool(false),
                        "String" => Value::Str(Rc::from("")),
                        _ => Value::Nothing,
                    };
                    stack.push(arr_of(&elem, vec![fill; n]));
                    pc += 1;
                }
                // `f(a, xs..., b)` -- ビットの立っている場所だけ、並べられる
                // ものとしてほどく。ほどいたあとは、ふつうの呼び出しと同じ
                Instr::CallSplat(sym, nparts, mask, _) => {
                    let at = stack.len() - *nparts as usize;
                    let parts: Vec<Value> = stack.split_off(at);
                    let args = spread(parts, *mask)?;
                    let name = self.sym_rc[*sym as usize].clone();
                    let v = match lookup(env, *sym) {
                        Some(f @ (Value::Closure(_) | Value::Generic(_))) => self.apply(&f, args)?,
                        _ => self.call(&name, args, env)?,
                    };
                    stack.push(v);
                    pc += 1;
                }
                Instr::ApplySplat(nparts, mask) => {
                    let at = stack.len() - *nparts as usize;
                    let parts: Vec<Value> = stack.split_off(at);
                    let args = spread(parts, *mask)?;
                    let f = stack.pop().ok_or("vm: Apply with no callee")?;
                    let v = self.apply(&f, args)?;
                    stack.push(v);
                    pc += 1;
                }
                Instr::Try(catch_pc) => {
                    handlers.push(Handler {
                        pc: *catch_pc as usize,
                        stack_len: stack.len(),
                        iters_len: iters.len(),
                        unpacked_len: unpacked.len(),
                        frames_len: self.frames.len(),
                        line: self.line,
                        file: self.file.clone(),
                        env: env.clone(),
                    });
                    pc += 1;
                }
                Instr::TryEnd => {
                    handlers.pop();
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

    fn binop(&mut self, op: u32, a: Value, b: Value) -> E<Value> {
        // 名前は借りたまま。答えが返ればそれで終わりで、Rc を持ち直さない
        if let Some(r) = binop_builtin(self.sym(op), &a, &b) {
            return r;
        }
        let name = self.sym_rc[op as usize].clone();
        self.binop_slow(&name, a, b)
    }

    /// 演算子も、名前のついた関数。組み込みの数と文字の道で答えられなかった
    /// ときだけ、その名前の method を探す -- `function +(a::P, b::P)` と
    /// 書いた人が居るかもしれないので。**答えられたときは探さない**:
    /// `Int + Int` は fib のいちばん内側なので、そこに表引きを足さない。
    fn binop_dispatch(&mut self, name: &str, a: Value, b: Value) -> E<Value> {
        let n: Rc<str> = Rc::from(name);
        if self.pick(&n, &[a.clone(), b.clone()]).is_some() {
            let env = self.global.clone().ok_or("nothing has been run yet")?;
            return self.call(&n, vec![a, b], &env);
        }
        Err(nomethod(name, &[a, b]))
    }

    /// `xs .+ 1` -- 一つずつに配る。点の無いほうの演算子を、要素ごとに呼ぶ。
    /// 片側が並びでないときは、その一つが全部の相手になる(Julia もそう)。
    fn broadcast(&mut self, base: &str, a: Value, b: Value) -> E<Value> {
        let as_list = |v: &Value| match v {
            Value::Arr(_) | Value::Range(..) | Value::FRange(..) => iter_values(v).ok(),
            _ => None,
        };
        // Julia の broadcast は、range に数を足したり掛けたりしたときだけ
        // range のまま返す(`(1:3) .+ 1` は `2:4`)。整数どうしのときの形だけ、
        // ここで同じにしておく -- ほかは、ふつうに並びになる
        if let Some(r) = broadcast_range(base, &a, &b) {
            return Ok(r);
        }
        match (as_list(&a), as_list(&b)) {
            (None, None) => self.binop_named(base, a, b),
            (Some(xs), None) => {
                let mut out = Vec::with_capacity(xs.len());
                for x in xs {
                    out.push(self.binop_named(base, x, b.clone())?);
                }
                Ok(self.arr_lit(out))
            }
            (None, Some(ys)) => {
                let mut out = Vec::with_capacity(ys.len());
                for y in ys {
                    out.push(self.binop_named(base, a.clone(), y)?);
                }
                Ok(self.arr_lit(out))
            }
            (Some(xs), Some(ys)) => {
                if xs.len() != ys.len() {
                    return Err(format!(
                        "DimensionMismatch: arrays could not be broadcast to a common size; got a dimension with lengths {} and {}",
                        xs.len(),
                        ys.len()
                    ));
                }
                let mut out = Vec::with_capacity(xs.len());
                for (x, y) in xs.into_iter().zip(ys) {
                    out.push(self.binop_named(base, x, y)?);
                }
                Ok(self.arr_lit(out))
            }
        }
    }

    /// 演算子の、速いほう。数と文字と bool で答えられるものだけ -- 答えられ
    /// なければ `None` を返して、遅いほう(broadcast か、その名前の method)に
    /// 渡す。**ここが `&self` すら取らないのは、fib のいちばん内側だから**:
    /// 名前を Rc で持ち直すだけでも、四百万回ぶんの値段になる。
    fn binop_named(&mut self, name: &str, a: Value, b: Value) -> E<Value> {
        match binop_builtin(name, &a, &b) {
            Some(r) => r,
            None => self.binop_slow(name, a, b),
        }
    }

    /// 答えられなかったとき。`.+` なら配る、そうでなければ、その名前の method。
    fn binop_slow(&mut self, name: &str, a: Value, b: Value) -> E<Value> {
        if let Some(base) = name.strip_prefix('.') {
            if !base.is_empty() {
                return self.broadcast(base, a, b);
            }
        }
        self.binop_dispatch(name, a, b)
    }
}

/// 数・文字・bool で答えられる演算。`None` は「この二つには、この名前で答え
/// られない」で、エラーではない -- 呼んだ側が method を探しに行く。
fn binop_builtin(name: &str, a: &Value, b: &Value) -> Option<E<Value>> {
    use Value::*;
    if let (Str(x), Str(y)) = (a, b) {
        return Some(Ok(match name {
            // Julia joins strings with `*`; `+` works here too, and both
            // are what the OCaml side registers
            "*" | "+" => Str(Rc::from(format!("{x}{y}").as_str())),
            "==" => Bool(x == y),
            "!=" => Bool(x != y),
            "<" => Bool(**x < **y),
            "<=" => Bool(**x <= **y),
            ">" => Bool(**x > **y),
            ">=" => Bool(**x >= **y),
            _ => return None,
        }));
    }
    // `==` は Julia では中身どうし -- 数でなくても答えられる
    match name {
        "==" => return Some(Ok(Bool(value_eq(a, b)))),
        "!=" => return Some(Ok(Bool(!value_eq(a, b)))),
        _ => {}
    }
    // ビット演算。Julia では `&&`/`||` とはちがう、ふつうの演算子で、
    // Bool にも効く
    if let (Bool(x), Bool(y)) = (a, b) {
        match name {
            "&" => return Some(Ok(Bool(*x && *y))),
            "|" => return Some(Ok(Bool(*x || *y))),
            "\u{22bb}" => return Some(Ok(Bool(x != y))),
            _ => {}
        }
    }
    let both_int = matches!((a, b), (Int(_), Int(_)));
    if both_int {
        let (x, y) = (as_int(a), as_int(b));
        match name {
            "&" => return Some(Ok(Int(x & y))),
            "|" => return Some(Ok(Int(x | y))),
            "\u{22bb}" => return Some(Ok(Int(x ^ y))),
            "<<" => return Some(Ok(Int(x.wrapping_shl(y as u32)))),
            ">>" => return Some(Ok(Int(x.wrapping_shr(y as u32)))),
            ">>>" => return Some(Ok(Int(((x as u64) >> (y as u32)) as i64))),
            _ => {}
        }
    }
    if !matches!((a, b), (Int(_) | Float(_), Int(_) | Float(_))) {
        return None;
    }
    let f = |v: &Value| match v {
        Int(n) => *n as f64,
        Float(x) => *x,
        _ => f64::NAN,
    };
    let (fa, fb) = (f(a), f(b));
    Some(Ok(match name {
        "+" => if both_int { Int(as_int(a) + as_int(b)) } else { Float(fa + fb) },
        "-" => if both_int { Int(as_int(a) - as_int(b)) } else { Float(fa - fb) },
        "*" => if both_int { Int(as_int(a) * as_int(b)) } else { Float(fa * fb) },
        // Julia's `/` is always a float, even on two Ints
        "/" => Float(fa / fb),
        "%" => if both_int { Int(as_int(a) % as_int(b)) } else { Float(fa % fb) },
        "^" => if both_int && as_int(b) >= 0 {
            Int(as_int(a).pow(as_int(b) as u32))
        } else {
            Float(fa.powf(fb))
        },
        "<" => Bool(fa < fb),
        "<=" => Bool(fa <= fb),
        ">" => Bool(fa > fb),
        ">=" => Bool(fa >= fb),
        _ => return None,
    }))
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

/// この VM が自分で答えられる名前(builtin / builtin_more の両方)。
/// `--builtins` が、ある .tsb がそのうちどれを口にしているかを数えるのに使う
/// -- runtime を二枚に分けるかどうかの、判断の材料。
const BUILTIN_NAMES: &[&str] = &[
    "!", "&", "<<", ">>", ">>>", "Bool", "Dict", "Float", "Float64", "Int", "Int64", "abs",
    "all", "any", "append!", "atan", "ceil", "clamp", "cld", "collect", "cos", "count",
    "delete!", "deleteat!", "div", "endswith", "enumerate", "error", "exp", "filter",
    "findfirst", "first", "firstindex", "fld", "floor", "get", "haskey", "hypot",
    "identity", "in", "insert!", "isempty", "isqrt", "join", "keys", "last", "lastindex",
    "length", "log", "log10", "log2", "lowercase", "lstrip", "map", "max", "maximum",
    "min", "minimum", "mod", "occursin", "ones", "parse", "pop!", "popfirst!", "prod",
    "push!", "pushfirst!", "rem", "repeat", "replace", "reverse", "reverse!", "round",
    "rstrip", "sign", "sin", "sort", "sort!", "split", "sqrt", "startswith", "string",
    "strip", "sum", "tan", "throw", "trunc", "unique", "uppercase", "values", "vcat",
    "zeros", "zip", "|", "~"
];

/// この program が名前を口にしている builtin。**どれを呼ぶか**ではなく
/// 「その名前が書かれているか」なので、多めに出る -- runtime を二枚に分ける
/// かどうかを考えるときの、上限のほうの数。
pub fn builtins_named(p: &Program) -> Vec<&str> {
    let mut out: Vec<&str> = p
        .syms
        .iter()
        .map(|s| s.as_str())
        .filter(|s| BUILTIN_NAMES.contains(s))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
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
        CallSplat(..) => "CallSplat", ApplySplat(..) => "ApplySplat",
        ApplyMethod(..) => "ApplyMethod", Jump(..) => "Jump", JumpIfFalse(..) => "JumpIfFalse",
        Println(..) => "Println", Print(..) => "Print", Enter => "Enter", Leave => "Leave",
        Line(..) => "Line", File(..) => "File", Defun(..) => "Defun", Defstruct(..) => "Defstruct",
        Defabstract(..) => "Defabstract", Makeclosure(..) => "Makeclosure", Using(..) => "Using",
        Import(..) => "Import", ModuleEnter(..) => "ModuleEnter", ModuleLeave => "ModuleLeave",
        Bind(..) => "Bind", BindTuple(..) => "BindTuple", Range => "Range", Range3 => "Range3",
        IterNew => "IterNew", IterNext(..) => "IterNext", IterDrop => "IterDrop", Comprehension(..) => "Comprehension",
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
        | Range3 | IterNew | IterNext(..) | IterDrop | Comprehension(..) | Using(..) | Import(..)
        | Qcall(..) | Apply(..) | In | BindTuple(..) | CallKw(..) | Typeof | Isa(..)
        | Subtype(..) | Try(..) | TryEnd | UnpackCheck(..) | Elem(..) | UnpackEnd
        | Typecheck(..) | CallSplat(..) | ApplySplat(..) | Typedarr(..)
        | TypedarrUndef(..) => return None,
        Makematrix(..) => "a matrix",
        ApplyMethod(..) => "calling a method on a JS value",
        TypedmatUndef(..) => "a typed matrix constructor",
    })
}

/// Iterating, pulled one at a time -- a `for` body lives in the same
/// instruction stream, so the loop has to be able to ask for the next value
/// at its own pace (bin/eval.ml's iter_start/iter_next, same reason).
enum Iter {
    Range(i64, i64, i64),
    /// start_n, step_n, den, いくつあるか, いま何番目。i 番目は
    /// `(start_n + i*step_n) / den` -- Julia の floatrange と同じ出しかた
    FRange(f64, f64, f64, i64, i64),
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
            Iter::FRange(a, s, den, n, k) => {
                if *k < *n {
                    let v = Value::Float((*a + (*k as f64) * *s) / *den);
                    *k += 1;
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
        Value::FRange(a, s, b) => {
            if *s == 0.0 {
                return Err("range step cannot be 0".into());
            }
            {
                let p = frange_parts(*a, *s, *b);
                Iter::FRange(p.start_n, p.step_n, p.den, p.len, 0)
            }
        }
        Value::Arr(a) => Iter::Vals(a.borrow().clone(), 0),
        Value::Tuple(t) => Iter::Vals(t.cells.clone(), 0),
        // a Dict iterates as its (key, value) pairs
        Value::Dict(d) => Iter::Vals(
            d.borrow()
                .iter()
                .map(|(k, v)| tuple_of(vec![k.clone(), v.clone()]))
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

/// `a:b` と `a:s:b`。端も刻みも全部 Int なら整数の range、一つでも float が
/// 混じれば float の range(Julia も `1:0.5:3` を `1.0:0.5:3.0` にする)。
fn make_range(lo: &Value, step: &Value, hi: &Value) -> E<Value> {
    let num = |v: &Value| match v {
        Value::Int(n) => Ok(*n as f64),
        Value::Float(f) => Ok(*f),
        other => Err(format!("a range wants numbers, got a {}", tag(other))),
    };
    if let (Value::Int(a), Value::Int(s), Value::Int(b)) = (lo, step, hi) {
        return Ok(Value::Range(*a, *s, *b));
    }
    Ok(Value::FRange(num(lo)?, num(step)?, num(hi)?))
}

/// float の range を、Julia が数えるとおりに数える。
///
/// Julia は `0.0:0.1:1.0` の三つめを `0.30000000000000004` ではなく `0.3` と
/// 出す。足しつづけていないからで、刻みを分数 `n/den` に直してから
/// `(start_n + i*step_n) / den` を出している(Base.floatrange)。ここも同じに
/// する -- 分数に直せない刻みのときだけ、素直に `start + i*step`。
struct FrangeParts {
    start_n: f64,
    step_n: f64,
    /// 分母。分数に直せなかったときは 1.0 で、start_n/step_n が元の float
    den: f64,
    len: i64,
}

/// Julia の `Base.rat`: x に近い分数 a/b を連分数で。b が 0 なら見つからなかった。
fn rat(x: f64) -> (i64, i64) {
    let m = 16_777_216.0f64; // maxintfloat(Float32, Int) -- Julia と同じ幅
    let (mut a, mut b, mut c, mut d) = (1i64, 0i64, 0i64, 1i64);
    let mut y = x;
    while y.abs() <= m {
        let f = y.trunc();
        if !f.is_finite() || f.abs() > m {
            return (c, d);
        }
        let f = f as i64;
        y -= f as f64;
        let (na, nc) = (f.saturating_mul(a).saturating_add(c), a);
        let (nb, nd) = (f.saturating_mul(b).saturating_add(d), b);
        a = na;
        c = nc;
        b = nb;
        d = nd;
        if (a.abs().max(b.abs()) as f64) > m {
            return (c, d);
        }
        if b != 0 && (a as f64) / (b as f64) == x {
            break;
        }
        y = 1.0 / y;
    }
    (a, b)
}

fn gcd_i64(a: i64, b: i64) -> i64 {
    let (mut a, mut b) = (a.abs(), b.abs());
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    a
}

fn frange_parts(a: f64, s: f64, b: f64) -> FrangeParts {
    // 素直な道(分数に直せなかったときの受け皿)
    let plain = || {
        let n = ((b - a) / s).floor();
        FrangeParts {
            start_n: a,
            step_n: s,
            den: 1.0,
            len: if n.is_finite() && n >= 0.0 { n as i64 + 1 } else { 0 },
        }
    };
    if !(a.is_finite() && s.is_finite() && b.is_finite()) || s == 0.0 {
        return plain();
    }
    let (an, ad) = rat(a);
    let (sn, sd) = rat(s);
    if ad == 0 || sd == 0 || (an as f64) / (ad as f64) != a || (sn as f64) / (sd as f64) != s {
        return plain();
    }
    let g = gcd_i64(ad, sd);
    if g == 0 {
        return plain();
    }
    let den = match (ad / g).checked_mul(sd) {
        Some(d) if d != 0 => d.abs(),
        _ => return plain(),
    };
    let m = 9_007_199_254_740_992.0f64; // maxintfloat(Float64, Int)
    let denf = den as f64;
    if (a * denf).abs() > m || (s * denf).abs() > m || den % ad != 0 || den % sd != 0 {
        return plain();
    }
    let start_n = (a * denf).round();
    let step_n = (s * denf).round();
    let len = ((denf * b - start_n + step_n) / step_n).trunc();
    FrangeParts {
        start_n,
        step_n,
        den: denf,
        len: if len.is_finite() && len >= 0.0 { len as i64 } else { 0 },
    }
}

/// float の range が立ち会う数を、ぜんぶ並べて。
pub fn frange_values(a: f64, s: f64, b: f64) -> Vec<f64> {
    let p = frange_parts(a, s, b);
    (0..p.len)
        .map(|k| (p.start_n + (k as f64) * p.step_n) / p.den)
        .collect()
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
            let cells = a.borrow();
            let mut out = Vec::new();
            let mut i = *lo;
            while if *st > 0 { i <= *hi } else { i >= *hi } {
                if i < 1 || i as usize > cells.len() {
                    return Err("BoundsError: slice index out of range".into());
                }
                out.push(cells[i as usize - 1].clone());
                i += *st;
            }
            // 切り出したものは、元と同じ何かの並び
            Ok(arr_of(&a.elem, out))
        }
        (Value::Arr(_) | Value::Tuple(_), other) => {
            Err(format!("index must be an Int, got a {}", tag(other)))
        }
        // ここまで来ないはず -- 呼ぶ側(index_or_dispatch)が、組み込みの形だけを
        // ここへ渡して、それ以外は `getindex` の method に訊いている
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
        // a missing key is CREATED here -- that is what a Dict is for
        (Value::Dict(d), k) => {
            dict_set(&mut d.borrow_mut(), k.clone(), v);
            Ok(())
        }
        // 読むほうと同じ -- 呼ぶ側が組み込みの形だけをここへ渡している
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

/// 名前だけで書かれたときに「それは builtin です」と言える名前。method 表に
/// 載っていないので、ここに並べておくしかない -- 値として渡せる形
/// (`map(length, xs)`、`floor(Int, x)`)のためだけの表。
fn is_builtin_name(n: &str) -> bool {
    matches!(
        n,
        "length" | "abs" | "sqrt" | "string" | "sum" | "prod" | "first" | "last"
            | "isempty" | "keys" | "values" | "maximum" | "minimum" | "reverse"
            | "sort" | "collect" | "uppercase" | "lowercase" | "strip" | "join"
            | "split" | "unique" | "identity"
            | "Int" | "Int64" | "Float" | "Float64" | "Bool" | "String" | "Symbol"
    )
}

/// 呼べる method が無かったときの言いかた。builtin の側でも同じ形にそろえる。
fn nomethod(name: &str, args: &[Value]) -> String {
    format!(
        "MethodError: no method matching {name}({})",
        args.iter().map(tag).collect::<Vec<_>>().join(", ")
    )
}

/// Julia の `round` は「ちょうど半分は偶数のほうへ」。Rust の `round` は
/// 遠いほうへ行くので、そこだけ自分で。
fn round_half_even(x: f64) -> f64 {
    let r = x.round();
    if (x - x.trunc()).abs() == 0.5 && r % 2.0 != 0.0 {
        r - x.signum()
    } else {
        r
    }
}

/// `(1:3) .+ 1` を `2:4` のまま返す形。整数の range と整数一つ、`+` `-` `*`
/// のときだけ -- ほかの組み合わせは None(呼んだ側が、ふつうに並べる)。
fn broadcast_range(base: &str, a: &Value, b: &Value) -> Option<Value> {
    let (lo, st, hi, k, range_first) = match (a, b) {
        (Value::Range(lo, st, hi), Value::Int(k)) => (*lo, *st, *hi, *k, true),
        (Value::Int(k), Value::Range(lo, st, hi)) => (*lo, *st, *hi, *k, false),
        _ => return None,
    };
    match base {
        "+" => Some(Value::Range(lo + k, st, hi + k)),
        "-" if range_first => Some(Value::Range(lo - k, st, hi - k)),
        "-" => Some(Value::Range(k - lo, -st, k - hi)),
        // 0 を掛けると刻みが 0 になって、回せない range になってしまう
        "*" if k != 0 => Some(Value::Range(lo * k, st * k, hi * k)),
        _ => None,
    }
}

/// `...` の付いていた場所だけ、ほどく。ビットの位が、その場所。
fn spread(parts: Vec<Value>, mask: u32) -> E<Vec<Value>> {
    let mut out = Vec::with_capacity(parts.len());
    for (i, p) in parts.into_iter().enumerate() {
        if mask & (1 << i) != 0 {
            out.extend(iter_values(&p)?);
        } else {
            out.push(p);
        }
    }
    Ok(out)
}

/// どちらが先か。数どうし、文字列どうしのときだけ答えられる。
fn value_order(a: &Value, b: &Value) -> std::cmp::Ordering {
    match (a, b) {
        (Value::Str(x), Value::Str(y)) => x.cmp(y),
        _ => num_cmp(a, b).unwrap_or(0).cmp(&0),
    }
}

/// 並べかえ。数どうし、文字列どうしのときだけ -- 混ざっていたら、何を先に
/// 置けばいいか、こちらからは言えない。
fn sort_values(xs: &mut [Value]) -> E<()> {
    let all_num = xs.iter().all(|v| matches!(v, Value::Int(_) | Value::Float(_)));
    let all_str = xs.iter().all(|v| matches!(v, Value::Str(_)));
    if !all_num && !all_str {
        return Err("sort: this VM can order numbers or strings, not a mix".into());
    }
    xs.sort_by(value_order);
    Ok(())
}

/// Comparing two numbers: -1, 0, 1 -- and None when either is not a number.
fn num_cmp(a: &Value, b: &Value) -> Option<i32> {
    let f = |v: &Value| match v {
        Value::Int(n) => Some(*n as f64),
        Value::Float(f) => Some(*f),
        _ => None,
    };
    let (x, y) = (f(a)?, f(b)?);
    Some(if x < y {
        -1
    } else if x > y {
        1
    } else {
        0
    })
}

fn as_int(v: &Value) -> i64 {
    match v {
        Value::Int(n) => *n,
        Value::Float(f) => *f as i64,
        _ => 0,
    }
}
