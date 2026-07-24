//! Mirrors `Ast.expr`/`Ast.stmt` in `bin/main.ml` -- see rust_parser/README.md
//! for the project's own history (this crate started as a deliberately
//! narrow "frozen snapshot", then grew to cover the full grammar). Field
//! names/shapes match the OCaml constructors this mirrors, one-to-one.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// interns identifier text so equal names share one allocation -- mirrors
/// `bin/lexer.ml`'s `Lexer.intern` (see README.md's "identifier interning,
/// the one that actually moved the needle most"). `Var`/`Assign` names are
/// interned once here, at PARSE time, so every occurrence of the same
/// identifier text (e.g. every `k` in a hot loop) shares one `Rc<str>`
/// allocation -- letting `value.rs`'s scope lookup compare names via
/// `Rc::ptr_eq` instead of a byte-by-byte comparison.
pub fn intern(s: &str) -> Rc<str> {
    thread_local! {
        static TABLE: RefCell<HashMap<String, Rc<str>>> = RefCell::new(HashMap::new());
    }
    TABLE.with(|t| match t.borrow_mut().entry(s.to_string()) {
        std::collections::hash_map::Entry::Occupied(e) => e.get().clone(),
        std::collections::hash_map::Entry::Vacant(e) => {
            let rc: Rc<str> = Rc::from(s);
            e.insert(rc.clone());
            rc
        }
    })
}

/// a `Var`/`Assign` node's own scope-depth cache -- mirrors `bin/eval.ml`'s
/// "read/write variable-depth caches" (README.md's "Seven optimizations"):
/// how many `parent` hops up the scope chain this exact AST node's name
/// resolved to LAST time. Recursion never changes this depth (a call
/// frame's parent is always its static definition scope, never the dynamic
/// caller), so a learned depth stays valid across every future evaluation
/// of this same node; a wrong guess (rare -- see `value.rs`'s
/// `lookup_cached`/`assign_cached`) just falls back to the full walk and
/// re-learns. `-1` means "not learned yet". Deliberately NOT part of an
/// `Expr`'s structural identity: two ASTs that parse to the same shape are
/// equal regardless of what either has learned at runtime, so `PartialEq`
/// always returns `true` here (the surrounding `Expr`/`Stmt` derive still
/// compares every OTHER field).
#[derive(Debug)]
pub struct DepthCache(pub std::cell::Cell<i32>);

impl DepthCache {
    pub fn new() -> Self {
        DepthCache(std::cell::Cell::new(-1))
    }
}

impl Default for DepthCache {
    fn default() -> Self {
        Self::new()
    }
}

impl Clone for DepthCache {
    fn clone(&self) -> Self {
        DepthCache(std::cell::Cell::new(self.0.get()))
    }
}

impl PartialEq for DepthCache {
    fn eq(&self, _other: &Self) -> bool {
        true
    }
}

// A NOTE on what this crate deliberately did NOT port: `bin/eval.ml`'s
// `Resolve` pass (README.md's "a genuine static-analysis phase, separate
// from execution") walks the whole program ONCE before execution, mirroring
// every scope-introducing construct with a static scope-shape stack, and
// writes each `Var`/`Assign` node's depth in ahead of time instead of
// learning it lazily. Considered and NOT built here, for a reason that's
// specific to what this crate is FOR: the OCaml side's own docs say this
// pass's measured speed contribution was small -- the dynamic cache above
// already converges within a handful of iterations, and `pisum`'s 5,000,000
// makes that convergence cost round to zero either way. Its real value there
// was architectural ("is analysis really separated from execution"), not
// raw speed. Meanwhile the RISK is real and asymmetric: a second walker that
// has to mirror every scope-introducing construct in lockstep with the
// evaluator (function/lambda/for/while/if/try bodies) is exactly the kind of
// thing that silently drifts out of sync -- the OCaml version's own history
// includes a real bug here (quoted code wrongly treated as opening a static
// scope, caught only by the regression suite). A WRONG pre-computed depth is
// a materially worse failure mode than this crate's dynamic cache ever has:
// the dynamic cache can only ever cache an outcome a REAL evaluation already
// produced, so a stale hint just falls back and re-learns (see
// `value.rs`'s `lookup_cached`); a wrong STATIC guess could instead make a
// lookup silently return a DIFFERENT, unrelated binding that happens to live
// at the guessed depth, with nothing to catch it. For a crate whose entire
// purpose is being a byte-for-byte-correct differential-testing oracle
// against the OCaml interpreter (see this crate's own README), that risk
// isn't worth a speedup its own source of inspiration already called small.

/// `Expr::BinOp`'s operator, resolved ONCE at parse time via `parse_binop`
/// instead of staying a `String` compared byte-by-byte on every evaluation
/// (found while investigating why this crate's tree-walker was still
/// slower than the OCaml interpreter's fully-optimized version despite
/// being compiled: unlike OCaml, where `+`/`-`/`<`/... are registered
/// through the SAME `Dispatch.defmethod`/`resolve` multiple-dispatch
/// machinery a named function call is -- worth an inline cache, see
/// `value.rs`'s note on `eval_binop` -- this crate's operators were ALREADY
/// just a `match` on `&str`, which the compiler cannot turn into a jump
/// table the way a `match` on this enum can). `Other` covers the two
/// operators `parser.rs`'s `prec` recognizes for PRECEDENCE only but
/// `eval_binop` has never actually implemented (`\` left-division, `⋅`
/// dot-product) -- carrying the original text keeps their existing
/// "unsupported operator: X" error message byte-for-byte unchanged rather
/// than silently changing behavior for an unrelated cleanup.
#[derive(Debug, Clone, PartialEq)]
pub enum BinOpKind {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Pow,
    Shr,
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,
    Colon,
    And,
    Or,
    Other(String),
}

impl BinOpKind {
    pub fn parse(s: &str) -> Self {
        match s {
            "+" => Self::Add,
            "-" => Self::Sub,
            "*" => Self::Mul,
            "/" => Self::Div,
            "%" => Self::Mod,
            "^" => Self::Pow,
            ">>>" => Self::Shr,
            "<" => Self::Lt,
            "<=" => Self::Le,
            ">" => Self::Gt,
            ">=" => Self::Ge,
            "==" => Self::Eq,
            "!=" => Self::Ne,
            ":" => Self::Colon,
            "&&" => Self::And,
            "||" => Self::Or,
            other => Self::Other(other.to_string()),
        }
    }

    /// the operator's own source text -- used to reconstruct a quoted
    /// `Expr` (`expr_to_value`) and to report an unimplemented operator's
    /// original name (`eval_binop`'s `Other` arm).
    pub fn as_str(&self) -> &str {
        match self {
            Self::Add => "+",
            Self::Sub => "-",
            Self::Mul => "*",
            Self::Div => "/",
            Self::Mod => "%",
            Self::Pow => "^",
            Self::Shr => ">>>",
            Self::Lt => "<",
            Self::Le => "<=",
            Self::Gt => ">",
            Self::Ge => ">=",
            Self::Eq => "==",
            Self::Ne => "!=",
            Self::Colon => ":",
            Self::And => "&&",
            Self::Or => "||",
            Self::Other(s) => s,
        }
    }
}

/// `ptype`: `["Any"]` if untyped, a singleton for a plain `x::T`
/// annotation, or several for `x::Union{A,B,C}` -- mirrors `Ast.param`.
#[derive(Debug, Clone, PartialEq)]
pub struct Param {
    pub pname: String,
    pub ptype: Vec<String>,
}

/// mirrors `Ast.tfield` -- a struct field's name and declared type(s).
#[derive(Debug, Clone, PartialEq)]
pub struct TField {
    pub fname: String,
    pub ftype: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Nothing,
    /// name is interned (see `intern` above) so `value.rs`'s scope lookup
    /// can compare it against a scope entry's own interned key via
    /// `Rc::ptr_eq`.
    Var(Rc<str>, DepthCache),
    Assign(Rc<str>, Box<Expr>, DepthCache),
    IndexAssign(Box<Expr>, Box<Expr>, Box<Expr>),
    BinOp(BinOpKind, Box<Expr>, Box<Expr>),
    /// positional args, keyword args (name, expr) -- mirrors `ECall`.
    Call(String, Vec<Expr>, Vec<(String, Expr)>),
    Field(Box<Expr>, String),
    FieldAssign(Box<Expr>, String, Box<Expr>),
    ArrayLit(Vec<Expr>),
    Index(Box<Expr>, Box<Expr>),
    Tuple(Vec<Expr>),
    Ternary(Box<Expr>, Box<Expr>, Box<Expr>),
    RangeStep(Box<Expr>, Box<Expr>, Box<Expr>),
    MatrixLit(Vec<Vec<Expr>>),
    /// `end` -- only meaningful inside a `[...]` index expression (`v[end]`,
    /// `v[end-1]`); mirrors `EEnd`.
    End,
    /// `[body for v1 in iter1, v2 in iter2, ...]` -- mirrors
    /// `bin/ast.ml`'s `EComprehension` (one clause per `for`; this crate,
    /// like the OCaml side, only supports 1 or 2 clauses -- there's no
    /// N-dimensional array type to hold a 3rd).
    Comprehension(Box<Expr>, Vec<(String, Expr)>),
    /// `Array{T}()` -- an empty Array with a declared, enforced element
    /// type, mirrors `ETypedArrayNew`.
    TypedArrayNew(String),
    /// `Name.member(args)` -- a struct constructor or dispatch call
    /// qualified by module name, single-level only. Mirrors
    /// `EQualifiedCall`.
    QualifiedCall(String, String, Vec<Expr>, Vec<(String, Expr)>),
    /// `x -> expr` or `function (args) ... end` -- mirrors `ELambda`.
    Lambda(Vec<String>, Vec<Stmt>),
    /// `:( expr )` -- quotes a single expression as data.
    Quote(Box<Expr>),
    /// `:name` -- quotes a bare identifier (or single-token operator) as a
    /// Symbol.
    QuoteSymbol(String),
    /// `quote ... end` -- quotes a statement list as data.
    QuoteBlock(Vec<Stmt>),
    /// `$(expr)` or `$name` -- only meaningful while converting a
    /// surrounding quote to a value; a harmless passthrough anywhere else.
    Interp(Box<Expr>),
    /// `$(target) = rhs` -- an assignment whose target isn't known until
    /// quote-conversion time (e.g. `$(esc(x)) = 0` inside a macro's quote).
    InterpAssign(Box<Expr>, Box<Expr>),
    /// `@name(args)` or `@name arg` -- args passed to the macro UNEVALUATED.
    MacroCall(String, Vec<Expr>),
    /// wraps a stmt list as a single expr -- used to splice a macro
    /// expansion shaped like a block/control-flow statement into
    /// expression position.
    Block(Vec<Stmt>),
}

/// mirrors `Ast.stmt`, field-for-field.
#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    Expr(Expr),
    If(Vec<(Expr, Vec<Stmt>)>, Option<Vec<Stmt>>),
    For(String, Expr, Vec<Stmt>),
    While(Expr, Vec<Stmt>),
    /// name, positional params, keyword params with default-value exprs, body.
    FuncDecl(String, Vec<Param>, Vec<(String, Expr)>, Vec<Stmt>),
    StructDecl {
        mutable: bool,
        name: String,
        parent: Option<String>,
        /// e.g. `["T"]` for `Box{T}`, `["K","V"]` for `Dict{K,V}`.
        type_params: Vec<String>,
        fields: Vec<TField>,
        /// real Julia's "inner constructors" -- `function StructName(...)
        /// ... end` defined inside the struct body.
        constructors: Vec<(Vec<Param>, Vec<(String, Expr)>, Vec<Stmt>)>,
    },
    AbstractDecl(String, Option<String>),
    Return(Option<Expr>),
    Try(Vec<Stmt>, Option<String>, Vec<Stmt>),
    /// `x, y = a, b` -- targets are full lvalue exprs (`Var`/`Field`/
    /// `Index`), not just bare names, so `a[i], a[j] = a[j], a[i]` (an
    /// in-place swap) works.
    Destructure(Vec<Expr>, Expr),
    /// `module Name ... end` -- functions/structs/abstract types declared
    /// in the body register under `"Name.thing"`; plain variable
    /// assignments in the body are NOT namespaced, on purpose.
    ModuleDecl(String, Vec<Stmt>),
    /// `using Name` -- merges everything Name declared into the bare/global
    /// namespace.
    Using(String),
    /// `macro name(args...) ... end` -- a separate namespace from
    /// functions; args are always plain names (macros dispatch purely by
    /// argument count, never type).
    MacroDecl(String, Vec<String>, Vec<Stmt>),
    /// `export a, b, c` -- a real Julia visibility hint, meaningless here
    /// (parsed and thrown away).
    Export(Vec<String>),
    /// `@name <stmt>` -- a macro call wrapping an entire statement.
    MacroCall(String, Box<Stmt>),
}
