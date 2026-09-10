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

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
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

    fn nats(&mut self) -> R<Vec<u32>> {
        let n = self.nat()? as usize;
        let mut v = Vec::with_capacity(n);
        for _ in 0..n {
            v.push(self.nat()?);
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
            let name = r.nat()?;
            let types = r.nats()?;
            let default = r.nat()?;
            Ok(Param { name, types, default })
        })
    }

    fn kwparams(&mut self) -> R<Vec<Kwparam>> {
        self.many(|r| {
            let name = r.nat()?;
            let types = r.nats()?;
            let default = r.nat()?;
            Ok(Kwparam { name, types, default })
        })
    }

    fn instr(&mut self) -> R<Instr> {
        use Instr::*;
        Ok(match self.tag()? {
            0 => Const(self.nat()?),
            1 => Nothing,
            2 => Load(self.nat()?, self.nat()?),
            3 => Store(self.nat()?, self.nat()?),
            4 => Pop,
            5 => Binop(self.nat()?, self.nat()?),
            6 => Call(self.nat()?, self.nat()?, self.nat()?),
            7 => Jump(self.nat()?),
            8 => JumpIfFalse(self.nat()?),
            9 => Println(self.nat()?),
            10 => Print(self.nat()?),
            11 => Enter,
            12 => Leave,
            13 => Defun(self.nat()?),
            14 => Ret,
            15 => Defstruct(self.nat()?),
            16 => Defabstract(self.nat()?, self.nat()?),
            17 => Getfield(self.nat()?),
            18 => Setfield(self.nat()?),
            19 => Bind(self.nat()?),
            20 => Range,
            21 => Range3,
            22 => IterNew,
            23 => IterNext(self.nat()?),
            24 => Pair,
            25 => Identical(self.nat()?),
            26 => Subtype(self.nat()?, self.nat()?),
            27 => In,
            28 => Makearr(self.nat()?),
            29 => Maketuple(self.nat()?),
            30 => SetEnd,
            31 => Index,
            32 => IndexSet,
            33 => Endmark,
            34 => Typeof,
            35 => Makedict(self.nat()?),
            36 => Isa(self.nat()?),
            37 => Using(self.nat()?),
            38 => Import(self.nat()?, self.nats()?),
            39 => ModuleEnter(self.nat()?),
            40 => ModuleLeave,
            41 => Makeclosure(self.nat()?),
            42 => Makematrix(self.nat()?, self.nat()?),
            43 => Qcall(self.nat()?, self.nat()?, self.nat()?, self.nat()?),
            44 => Apply(self.nat()?),
            45 => ApplyMethod(self.nat()?, self.nat()?),
            46 => Try(self.nat()?),
            47 => TryEnd,
            48 => Line(self.nat()?),
            49 => CallKw(self.nat()?, self.nat()?, self.nats()?, self.nat()?),
            50 => Typedarr(self.nat()?, self.nat()?),
            51 => TypedarrUndef(self.nat()?),
            52 => TypedmatUndef(self.nat()?),
            53 => LoadIndex(self.nat()?, self.nat()?),
            54 => IndexOrTyped(self.nat()?),
            55 => BindTuple(self.nats()?),
            56 => Comprehension(self.nat()?),
            57 => StorePlain(self.nat()?),
            58 => UnpackCheck(self.nat()?),
            59 => Elem(self.nat()?),
            60 => UnpackEnd,
            61 => Typecheck(self.nat()?, self.nats()?),
            62 => Symbol(self.nat()?),
            63 => File(self.nat()?),
            t => return Err(BadTsb(format!("unknown opcode {t}"))),
        })
    }
}

pub fn read(bytes: &[u8]) -> R<Program> {
    let mut r = Reader { b: bytes, pos: 0 };
    r.need(4)?;
    if &bytes[0..4] != b"TSB1" {
        return Err(BadTsb("wrong magic".into()));
    }
    r.pos = 4;
    let pool = r.many(|r| {
        Ok(match r.tag()? {
            0 => Lit::Int(r.bits()? as i64),
            1 => Lit::Float(f64::from_bits(r.bits()?)),
            2 => Lit::Str(r.str()?),
            3 => Lit::Bool(r.nat()? != 0),
            t => return Err(BadTsb(format!("unknown literal tag {t}"))),
        })
    })?;
    let syms = r.many(|r| r.str())?;
    let funcs = r.many(|r| {
        let name = r.nat()?;
        let params = r.params()?;
        let kwparams = r.kwparams()?;
        let body = r.nat()?;
        let cache = r.nat()?;
        Ok(Func { name, params, kwparams, body, cache })
    })?;
    let structs = r.many(|r| {
        let mutable = r.nat()? != 0;
        let name = r.nat()?;
        let parent = r.nat()?;
        let typarams = r.nats()?;
        let fields = r.many(|r| {
            let name = r.nat()?;
            let types = r.nats()?;
            Ok(Field { name, types })
        })?;
        let ctors = r.many(|r| {
            let params = r.params()?;
            let kwparams = r.kwparams()?;
            let body = r.nat()?;
            Ok(Ctor { params, kwparams, body })
        })?;
        let kwdefaults = r.many(|r| {
            let f = r.nat()?;
            let irep = r.nat()?;
            Ok((f, irep))
        })?;
        Ok(Strct { mutable, name, parent, typarams, fields, ctors, kwdefaults })
    })?;
    let lambdas = r.many(|r| {
        let params = r.nats()?;
        let body = r.nat()?;
        Ok(Lambda { params, body })
    })?;
    let comps = r.many(|r| {
        let targets = r.many(|r| {
            let names = r.nats()?;
            let tuple = r.nat()? != 0;
            Ok(Target { names, tuple })
        })?;
        let body = r.nat()?;
        Ok(Comp { targets, body })
    })?;
    let ireps = r.many(|r| r.many(|r| r.instr()))?;
    let main = r.nat()?;
    Ok(Program { pool, syms, funcs, structs, lambdas, comps, ireps, main })
}
