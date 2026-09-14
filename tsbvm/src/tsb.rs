//! Reading a `.tsb`: the flat instruction stream Tsubaki's frontend folds a
//! program into (see bin/bytecode.ml for the writing side, and bin/tocode.ml
//! for what folds into what).
//!
//! Nothing here interprets anything -- this file only knows the shape on the
//! wire. Every number in it is a non-negative 4-byte big-endian integer,
//! except an integer literal (8 bytes, i64) and a float literal (8 bytes,
//! IEEE754 bits); strings are a length and then the bytes. That restriction
//! is not for this side's sake: the writer runs under js_of_ocaml, where an
//! OCaml `int` is 32 bits, so it never writes a number that crosses the sign.

use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub enum Lit {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
}

/// One parameter. `types` are indices into `syms` -- an unannotated parameter
/// carries the single name "Any", the same convention the OCaml side uses.
/// `default` is `1 + <irep index>`, or 0 for "no default".
#[derive(Debug, Clone)]
pub struct Param {
    pub name: u32,
    pub types: Vec<u32>,
    pub default: u32,
    /// `f(a, xs...)` の `xs` なら true。最後の一つにしか立たない -- 呼ばれた
    /// ときに余ったものをぜんぶ集めて、タプルとして束ねる
    pub slurp: bool,
}

#[derive(Debug, Clone)]
pub struct Kwparam {
    pub name: u32,
    pub types: Vec<u32>,
    pub default: u32,
}

#[derive(Debug, Clone)]
pub struct Func {
    pub name: u32,
    pub params: Vec<Param>,
    pub kwparams: Vec<Kwparam>,
    pub body: u32,
    pub cache: u32,
}

#[derive(Debug, Clone)]
pub struct Field {
    pub name: u32,
    pub types: Vec<u32>,
}

#[derive(Debug, Clone)]
pub struct Ctor {
    pub params: Vec<Param>,
    pub kwparams: Vec<Kwparam>,
    pub body: u32,
}

#[derive(Debug, Clone)]
pub struct Strct {
    pub mutable: bool,
    pub name: u32,
    pub parent: u32,
    pub typarams: Vec<u32>,
    pub fields: Vec<Field>,
    pub ctors: Vec<Ctor>,
    /// (field sym, irep of its default) -- only present under `@kwdef`.
    pub kwdefaults: Vec<(u32, u32)>,
}

#[derive(Debug, Clone)]
pub struct Lambda {
    pub params: Vec<u32>,
    pub body: u32,
}

/// A loop variable: one name, or a tuple unpacked into several.
#[derive(Debug, Clone)]
pub struct Target {
    pub names: Vec<u32>,
    pub tuple: bool,
}

#[derive(Debug, Clone)]
pub struct Comp {
    pub targets: Vec<Target>,
    /// `1 + <irep>` for `[x for x in xs if cond]`, or 0 for no filter.
    pub cond: u32,
    pub body: u32,
}

/// The instruction set. Tags are the ones bin/bytecode.ml writes -- they are
/// not contiguous, because instructions were added over time and the numbers
/// stayed put (a `.tsb` written by an older frontend still reads).
#[derive(Debug, Clone)]
pub enum Instr {
    Const(u32),
    Nothing,
    Load(u32, u32),
    Store(u32, u32),
    Pop,
    Binop(u32, u32),
    Call(u32, u32, u32),
    CallKw(u32, u32, Vec<u32>, u32),
    Jump(u32),
    JumpIfFalse(u32),
    Println(u32),
    Print(u32),
    Enter,
    Leave,
    Line(u32),
    File(u32),
    Defun(u32),
    Defstruct(u32),
    Defabstract(u32, u32),
    Makeclosure(u32),
    Using(u32),
    Import(u32, Vec<u32>),
    ModuleEnter(u32),
    ModuleLeave,
    Bind(u32),
    BindTuple(Vec<u32>),
    StorePlain(u32),
    Range,
    Range3,
    IterNew,
    IterNext(u32),
    IterDrop,
    Comprehension(u32),
    Getfield(u32),
    Setfield(u32),
    Makearr(u32),
    Maketuple(u32),
    Makematrix(u32, u32),
    Makedict(u32),
    Pair,
    Identical(u32),
    Subtype(u32, u32),
    In,
    Typeof,
    Isa(u32),
    Symbol(u32),
    SetEnd,
    Index,
    IndexSet,
    Endmark,
    Typedarr(u32, u32),
    TypedarrUndef(u32),
    TypedmatUndef(u32),
    LoadIndex(u32, u32),
    IndexOrTyped(u32),
    UnpackCheck(u32),
    Elem(u32),
    UnpackEnd,
    Typecheck(u32, Vec<u32>),
    /// syms[名前], 積まれている部分の数, どれをばらすかのビット, call cache
    CallSplat(u32, u32, u32, u32),
    /// 呼ぶもの, 部分… の順に積んで、部分の数, ビット
    ApplySplat(u32, u32),
    Qcall(u32, u32, u32, u32),
    Apply(u32),
    ApplyMethod(u32, u32),
    Try(u32),
    TryEnd,
    Ret,
}

#[derive(Debug, Clone)]
pub struct Program {
    pub pool: Vec<Lit>,
    pub syms: Vec<String>,
    pub funcs: Vec<Func>,
    pub structs: Vec<Strct>,
    pub lambdas: Vec<Lambda>,
    pub comps: Vec<Comp>,
    pub ireps: Vec<Vec<Instr>>,
    pub main: u32,
}

#[derive(Debug)]
pub struct BadTsb(pub String);

impl std::fmt::Display for BadTsb {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "not a .tsb: {}", self.0)
    }
}

/// もう読んである一枚の上に二枚目を足すとき、二枚目の番号をどこへ動かすか。
///
/// 五つの表はうしろに並べるだけなので、長さを足せばいい。syms だけは違って、
/// **文字で照らして引き直す** -- scope は名前を番号で引く(vm.rs の `Scope`)ので、
/// 同じ名前が二つの番号を持つと、一枚目が置いたものを二枚目が引けない。
struct Bases {
    pool: u32,
    funcs: u32,
    structs: u32,
    lambdas: u32,
    comps: u32,
    ireps: u32,
    /// 二枚目の中の番号 -> 継ぎ足したあとの番号
    syms: Vec<u32>,
}

/// 足される側の、読みはじめる前に分かっているぶん。
struct Prev<'p> {
    pool: u32,
    funcs: u32,
    structs: u32,
    lambdas: u32,
    comps: u32,
    ireps: u32,
    syms: &'p [String],
}

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
    /// 一枚目なら None -- 番号はそのまま通る。
    base: Option<Bases>,
}

type R<T> = Result<T, BadTsb>;

impl<'a> Reader<'a> {
    fn need(&self, n: usize) -> R<()> {
        if self.pos + n > self.b.len() {
            Err(BadTsb("ran off the end".into()))
        } else {
            Ok(())
        }
    }

    /// ただの数。表の番号ではないもの -- 数えたもの、同じ irep の中の行き先
    /// (`Jump` / `JumpIfFalse` / `IterNext` / `Try`)、行番号、call cache の
    /// セル(VM は見ていない)、旗。
    fn nat(&mut self) -> R<u32> {
        self.need(4)?;
        let n = u32::from_be_bytes([
            self.b[self.pos],
            self.b[self.pos + 1],
            self.b[self.pos + 2],
            self.b[self.pos + 3],
        ]);
        self.pos += 4;
        Ok(n)
    }

    /// 表の番号。`pick` が、どの表かを言う。
    fn at(&mut self, pick: fn(&Bases) -> u32) -> R<u32> {
        let n = self.nat()?;
        Ok(match &self.base {
            Some(b) => n + pick(b),
            None => n,
        })
    }

    fn pool(&mut self) -> R<u32> {
        self.at(|b| b.pool)
    }
    fn func(&mut self) -> R<u32> {
        self.at(|b| b.funcs)
    }
    fn strct(&mut self) -> R<u32> {
        self.at(|b| b.structs)
    }
    fn lambda(&mut self) -> R<u32> {
        self.at(|b| b.lambdas)
    }
    fn comp(&mut self) -> R<u32> {
        self.at(|b| b.comps)
    }
    fn irep(&mut self) -> R<u32> {
        self.at(|b| b.ireps)
    }

    /// `1 + <irep>`、0 なら「無し」。`Param.default` と `Comp.cond` がこの形
    /// (`Kwparam.default` と `Strct.kwdefaults` のほうは生の irep -- 「無し」が
    /// 無いので、sentinel を取っていない)。
    fn irep1(&mut self) -> R<u32> {
        let n = self.nat()?;
        if n == 0 {
            return Ok(0);
        }
        Ok(match &self.base {
            Some(b) => n + b.ireps,
            None => n,
        })
    }

    /// 名前の番号。足すのではなく、引き直す。
    fn sym(&mut self) -> R<u32> {
        let n = self.nat()?;
        match &self.base {
            None => Ok(n),
            Some(b) => b
                .syms
                .get(n as usize)
                .copied()
                .ok_or_else(|| BadTsb(format!("a name number past the end ({n})"))),
        }
    }

    fn bits(&mut self) -> R<u64> {
        self.need(8)?;
        let mut v: u64 = 0;
        for k in 0..8 {
            v = (v << 8) | self.b[self.pos + k] as u64;
        }
        self.pos += 8;
        Ok(v)
    }

    fn tag(&mut self) -> R<u8> {
        self.need(1)?;
        let c = self.b[self.pos];
        self.pos += 1;
        Ok(c)
    }

    fn str(&mut self) -> R<String> {
        let n = self.nat()? as usize;
        self.need(n)?;
        let s = String::from_utf8_lossy(&self.b[self.pos..self.pos + n]).into_owned();
        self.pos += n;
        Ok(s)
    }

    /// 名前の番号の並び。`.tsb` の中で並んで書かれる番号は、どれも名前のほう
    /// (型の名前、keyword の名前、ばらす先の名前、module の member、型引数)。
    fn syms(&mut self) -> R<Vec<u32>> {
        let n = self.nat()? as usize;
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            v.push(self.sym()?);
        }
        Ok(v)
    }

    fn many<T>(&mut self, mut one: impl FnMut(&mut Self) -> R<T>) -> R<Vec<T>> {
        let n = self.nat()? as usize;
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            v.push(one(self)?);
        }
        Ok(v)
    }

    fn params(&mut self) -> R<Vec<Param>> {
        self.many(|r| {
            let name = r.sym()?;
            let types = r.syms()?;
            let default = r.irep1()?;
            let slurp = r.nat()? != 0;
            Ok(Param { name, types, default, slurp })
        })
    }

    fn kwparams(&mut self) -> R<Vec<Kwparam>> {
        self.many(|r| {
            let name = r.sym()?;
            let types = r.syms()?;
            let default = r.irep()?;
            Ok(Kwparam { name, types, default })
        })
    }

    fn instr(&mut self) -> R<Instr> {
        use Instr::*;
        Ok(match self.tag()? {
            0 => Const(self.pool()?),
            1 => Nothing,
            2 => Load(self.sym()?, self.nat()?),
            3 => Store(self.sym()?, self.nat()?),
            4 => Pop,
            5 => Binop(self.sym()?, self.nat()?),
            6 => Call(self.sym()?, self.nat()?, self.nat()?),
            7 => Jump(self.nat()?),
            8 => JumpIfFalse(self.nat()?),
            9 => Println(self.nat()?),
            10 => Print(self.nat()?),
            11 => Enter,
            12 => Leave,
            13 => Defun(self.func()?),
            14 => Ret,
            15 => Defstruct(self.strct()?),
            16 => Defabstract(self.sym()?, self.sym()?),
            17 => Getfield(self.sym()?),
            18 => Setfield(self.sym()?),
            19 => Bind(self.sym()?),
            20 => Range,
            21 => Range3,
            22 => IterNew,
            23 => IterNext(self.nat()?),
            64 => IterDrop,
            24 => Pair,
            25 => Identical(self.nat()?),
            26 => Subtype(self.sym()?, self.sym()?),
            27 => In,
            28 => Makearr(self.nat()?),
            29 => Maketuple(self.nat()?),
            30 => SetEnd,
            31 => Index,
            32 => IndexSet,
            33 => Endmark,
            34 => Typeof,
            35 => Makedict(self.nat()?),
            36 => Isa(self.sym()?),
            37 => Using(self.sym()?),
            38 => Import(self.sym()?, self.syms()?),
            39 => ModuleEnter(self.sym()?),
            40 => ModuleLeave,
            41 => Makeclosure(self.lambda()?),
            42 => Makematrix(self.nat()?, self.nat()?),
            43 => Qcall(self.sym()?, self.sym()?, self.nat()?, self.nat()?),
            44 => Apply(self.nat()?),
            45 => ApplyMethod(self.sym()?, self.nat()?),
            46 => Try(self.nat()?),
            47 => TryEnd,
            48 => Line(self.nat()?),
            49 => CallKw(self.sym()?, self.nat()?, self.syms()?, self.nat()?),
            50 => Typedarr(self.sym()?, self.nat()?),
            51 => TypedarrUndef(self.sym()?),
            52 => TypedmatUndef(self.sym()?),
            53 => LoadIndex(self.sym()?, self.nat()?),
            54 => IndexOrTyped(self.sym()?),
            55 => BindTuple(self.syms()?),
            56 => Comprehension(self.comp()?),
            57 => StorePlain(self.sym()?),
            58 => UnpackCheck(self.nat()?),
            59 => Elem(self.nat()?),
            60 => UnpackEnd,
            61 => Typecheck(self.sym()?, self.syms()?),
            62 => Symbol(self.sym()?),
            63 => File(self.sym()?),
            65 => CallSplat(self.sym()?, self.nat()?, self.nat()?, self.nat()?),
            66 => ApplySplat(self.nat()?, self.nat()?),
            t => return Err(BadTsb(format!("unknown opcode {t}"))),
        })
    }
}

pub fn read(bytes: &[u8]) -> R<Program> {
    read_with(bytes, None)
}

/// 二枚目を、もう読んである一枚の上に足す。返すのは二枚目の main の irep 番号。
///
/// 一枚目の番号はどれも動かないので、もう作られた closure も method も生きたまま。
/// 名前だけは引き直すので、std が置いた global を drop 側が引けるし、drop が
/// std と同じ署名で書き直した method は(Julia と同じに)置きかわる。
pub fn append(p: &mut Program, bytes: &[u8]) -> R<u32> {
    let part = read_with(
        bytes,
        Some(Prev {
            pool: p.pool.len() as u32,
            funcs: p.funcs.len() as u32,
            structs: p.structs.len() as u32,
            lambdas: p.lambdas.len() as u32,
            comps: p.comps.len() as u32,
            ireps: p.ireps.len() as u32,
            syms: &p.syms,
        }),
    )?;
    p.pool.extend(part.pool);
    p.syms.extend(part.syms);
    p.funcs.extend(part.funcs);
    p.structs.extend(part.structs);
    p.lambdas.extend(part.lambdas);
    p.comps.extend(part.comps);
    p.ireps.extend(part.ireps);
    Ok(part.main)
}

/// `prev` が無ければ、出るのは一枚まるごと。あれば、継ぎ足すぶんだけが入っていて、
/// 番号はもう直してある(`main` も)。
fn read_with(bytes: &[u8], prev: Option<Prev>) -> R<Program> {
    let mut r = Reader { b: bytes, pos: 0, base: None };
    r.need(4)?;
    // 形が変わったら版が上がる(bin/bytecode.ml の magic)。古いものを黙って
    // 読み違えるより、古いと言う
    match &bytes[0..4] {
        b"TSB3" => {}
        b"TSB1" | b"TSB2" => {
            return Err(BadTsb(
                "an older .tsb. Fold it again with the current tsubakic".into(),
            ))
        }
        _ => return Err(BadTsb("wrong magic".into())),
    }
    r.pos = 4;
    // pool は名前を見ないので、番号の直しかたが決まる前に読んでよい
    let pool = r.many(|r| {
        Ok(match r.tag()? {
            0 => Lit::Int(r.bits()? as i64),
            1 => Lit::Float(f64::from_bits(r.bits()?)),
            2 => Lit::Str(r.str()?),
            3 => Lit::Bool(r.nat()? != 0),
            t => return Err(BadTsb(format!("unknown literal tag {t}"))),
        })
    })?;
    let read_syms = r.many(|r| r.str())?;
    // ここで、二枚目の番号の直しかたが決まる。これより後ろの節は名前を指すので、
    // 一周で足りる
    let syms = match &prev {
        None => read_syms,
        Some(p) => {
            let mut index: HashMap<String, u32> = HashMap::with_capacity(p.syms.len());
            for (i, s) in p.syms.iter().enumerate() {
                index.insert(s.clone(), i as u32);
            }
            let mut map = Vec::with_capacity(read_syms.len());
            let mut fresh: Vec<String> = Vec::new();
            for s in read_syms {
                let at = match index.get(&s) {
                    Some(i) => *i,
                    None => {
                        let at = p.syms.len() as u32 + fresh.len() as u32;
                        index.insert(s.clone(), at);
                        fresh.push(s);
                        at
                    }
                };
                map.push(at);
            }
            r.base = Some(Bases {
                pool: p.pool,
                funcs: p.funcs,
                structs: p.structs,
                lambdas: p.lambdas,
                comps: p.comps,
                ireps: p.ireps,
                syms: map,
            });
            fresh
        }
    };
    let funcs = r.many(|r| {
        let name = r.sym()?;
        let params = r.params()?;
        let kwparams = r.kwparams()?;
        let body = r.irep()?;
        let cache = r.nat()?;
        Ok(Func { name, params, kwparams, body, cache })
    })?;
    let structs = r.many(|r| {
        let mutable = r.nat()? != 0;
        let name = r.sym()?;
        let parent = r.sym()?;
        let typarams = r.syms()?;
        let fields = r.many(|r| {
            let name = r.sym()?;
            let types = r.syms()?;
            Ok(Field { name, types })
        })?;
        let ctors = r.many(|r| {
            let params = r.params()?;
            let kwparams = r.kwparams()?;
            let body = r.irep()?;
            Ok(Ctor { params, kwparams, body })
        })?;
        let kwdefaults = r.many(|r| {
            let f = r.sym()?;
            let irep = r.irep()?;
            Ok((f, irep))
        })?;
        Ok(Strct { mutable, name, parent, typarams, fields, ctors, kwdefaults })
    })?;
    let lambdas = r.many(|r| {
        let params = r.syms()?;
        let body = r.irep()?;
        Ok(Lambda { params, body })
    })?;
    let comps = r.many(|r| {
        let targets = r.many(|r| {
            let names = r.syms()?;
            let tuple = r.nat()? != 0;
            Ok(Target { names, tuple })
        })?;
        let cond = r.irep1()?;
        let body = r.irep()?;
        Ok(Comp { targets, cond, body })
    })?;
    let ireps = r.many(|r| r.many(|r| r.instr()))?;
    let main = r.irep()?;
    Ok(Program { pool, syms, funcs, structs, lambdas, comps, ireps, main })
}
