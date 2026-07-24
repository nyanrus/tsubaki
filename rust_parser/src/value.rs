//! A tree-walking evaluator + `show`, mirroring `bin/eval.ml`/`bin/runtime.ml`
//! closely enough to diff this crate's output directly against real Tsubaki's
//! `println(expr)` (or a whole `--program`) for the same source. Covers the
//! full expression/statement grammar this crate parses (see
//! rust_parser/README.md for this project's own history: started as a
//! deliberately narrow "frozen snapshot", grew to cover the whole grammar).
//!
//! Known, DOCUMENTED simplifications versus the real OCaml interpreter
//! (kept deliberately -- this crate is a differential-testing tool, not a
//! second production implementation, see README.md):
//! - Functions/struct constructors dispatch by NAME (and, for constructors,
//!   ARITY) only -- no real multiple dispatch by argument TYPE across
//!   several same-named overloads (the OCaml side's `Dispatch.methods` does
//!   real type-signature resolution; this crate's `functions`/`constructors`
//!   tables are simple maps, last-declared-wins on a name/arity collision).
//! - Parameter/field type annotations (`::T`) are PARSED and stored but not
//!   enforced -- no TypeError on a mismatched argument/field value.
//! - A parametric struct (`struct Box{T} ... end`) never infers a concrete
//!   tag like `"Box{Int}"` -- every instance just tags as the bare
//!   `"Box"`. `typeof`/`isa` still work, just without that extra precision.
//! - `isa`/type hierarchies are a flat name->parent map (mirrors
//!   `Types.declare`'s SHAPE, not its full feature set) -- enough for
//!   `struct S <: Exception`/catch-by-type to work, not a stand-in for
//!   Julia's real abstract-type lattice.

use crate::ast::{intern, BinOpKind, DepthCache, Expr, Param, Stmt};
use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

// ============================= Values =============================

#[derive(Debug, Clone)]
pub enum Value {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
    Nothing,
    /// `Rc<RefCell<...>>`, NOT a plain `Vec` -- mirrors `VVec of float array
    /// ref` (`bin/runtime.ml`) exactly: real Julia arrays are mutable,
    /// REFERENCE-semantics objects, not copied on assignment or when passed
    /// to a function.
    Vector(Rc<RefCell<Vec<f64>>>),
    /// same reasoning as `Vector` above -- mirrors `VMat`.
    Matrix(Rc<RefCell<Vec<Vec<f64>>>>),
    /// a general, possibly-heterogeneous Array -- mirrors `VArr` (`declared`
    /// is `Some elem_ty` only for the real `Array{T}()` constructor, kept
    /// even while empty; `None` for an ordinary literal/comprehension
    /// Array, matching the OCaml side's own two constructors).
    Array(Rc<RefCell<Vec<Value>>>, Option<String>),
    /// VRange (start, step, stop) -- an Int step range, e.g. `1:2:7`.
    Range(i64, i64, i64),
    /// VFRange (start, step, stop) -- a Float step range, e.g. `-1.0:0.1:1.0`.
    FRange(f64, f64, f64),
    /// VTuple -- produced by `return a, b`, a destructuring assignment's
    /// right side, or a quoted `(a, b)` tuple-expr.
    Tuple(Vec<Value>),
    /// VComplex (re, im) -- produced by `complex(re, im)`.
    Complex(f64, f64),
    /// a lambda/closure -- mirrors `VClosure`: captures the `Scope` it was
    /// CREATED in (real lexical closure, not just "always global"), so a
    /// lambda declared inside a loop/function body can read/mutate that
    /// call's own locals.
    Closure(Rc<ClosureDef>),
    /// a struct instance -- mirrors `VStruct`: `Rc` around the whole thing
    /// (not just each field) so assignment/passing aliases the SAME
    /// instance, matching real Julia object identity; each field is its own
    /// `RefCell` so `set_field` mutates in place through every alias.
    Struct(Rc<StructInstance>),
    /// VSymbol (name, hygiene_tag) -- quoted syntax data, `:name`. Boxed
    /// (DOP_MIGRATION.md): this and `ExprV` are the two variants whose
    /// un-boxed size (40 and 48 bytes) used to set `Value`'s own size,
    /// forcing every value -- including the hot-path `Int`/`Float` cases --
    /// to pay for a footprint that only quoted syntax data ever needs.
    Symbol(Box<(String, Option<u64>)>),
    /// VExpr { head; args } -- quoted syntax data, `:(...)`/`quote ... end`.
    /// Boxed for the same reason as `Symbol` above.
    ExprV(Box<(String, Vec<Value>)>),
}

#[derive(Debug)]
pub struct ClosureDef {
    pub params: Vec<String>,
    pub body: Vec<Stmt>,
    pub captured: Scope,
    /// the module prefix active where this lambda was CREATED -- mirrors
    /// `ELambda`'s own `def_prefix` capture (bare calls inside the body
    /// resolve within that module, regardless of the caller's own module).
    pub def_prefix: String,
}

#[derive(Debug)]
pub struct StructInstance {
    pub kind: String,
    pub fields: Vec<(String, RefCell<Value>)>,
}

#[derive(Debug)]
pub struct EvalError(pub String);

// ============================= Scope =============================

/// mirrors `bin/eval.ml`'s `env`/`new_scope`/`bind`/`assign`/`lookup`: a
/// real parent-linked scope chain (not a flat stack), so a `Value::Closure`
/// can capture an `Rc` to whatever scope it was created in -- including a
/// non-global one (a lambda declared inside a loop body, or inside a
/// function call) -- and keep it alive/mutable independent of whatever
/// scope is "current" by the time the closure is actually called.
pub type Scope = Rc<ScopeNode>;

/// `a == b` against a plain, not-necessarily-interned name -- a direct
/// content comparison (no reason to pay an intern-table lookup just to
/// compare). See `sym_eq_sym` below for the real pointer-equality fast path,
/// used once callers hold an already-interned `Rc<str>` (the variable depth
/// cache, see README.md's "identifier interning").
fn sym_eq(a: &Rc<str>, b: &str) -> bool {
    a.as_ref() == b
}

/// `a == b` for two ALREADY-interned names -- pointer equality first (the
/// overwhelmingly common case: both came from the same `intern` table),
/// content comparison as a fallback for the vanishingly rare case of a hash
/// collision in a different table generation (never happens in practice
/// since `intern` is the only place that mints these, but cheap insurance).
fn sym_eq_sym(a: &Rc<str>, b: &Rc<str>) -> bool {
    Rc::ptr_eq(a, b) || a.as_ref() == b.as_ref()
}

/// a scope's own bindings: mirrors README.md's "lightweight assoc-list
/// scopes" -- a plain `Vec`, empty until something is actually bound,
/// rather than a hash table eagerly sized for a scope that (a function
/// call frame, one loop iteration) typically holds only a handful of
/// variables. Keys are interned `Rc<str>` (see `intern` above) so a hit
/// against a name obtained from the SAME call site's cached symbol (see
/// the variable depth cache) compares via one pointer check.
#[derive(Debug)]
pub struct ScopeNode {
    vars: RefCell<Vec<(Rc<str>, Value)>>,
    parent: Option<Scope>,
}

fn new_root_scope() -> Scope {
    Rc::new(ScopeNode { vars: RefCell::new(Vec::new()), parent: None })
}

fn new_child_scope(parent: &Scope) -> Scope {
    Rc::new(ScopeNode { vars: RefCell::new(Vec::new()), parent: Some(parent.clone()) })
}

impl ScopeNode {
    fn lookup(&self, name: &str) -> Option<Value> {
        if let Some((_, v)) = self.vars.borrow().iter().find(|(k, _)| sym_eq(k, name)) {
            return Some(v.clone());
        }
        self.parent.as_ref().and_then(|p| p.lookup(name))
    }

    fn bind(&self, name: &str, v: Value) {
        let mut vars = self.vars.borrow_mut();
        match vars.iter_mut().find(|(k, _)| sym_eq(k, name)) {
            Some((_, slot)) => *slot = v,
            None => vars.push((intern(name), v)),
        }
    }

    /// empties this scope's own bindings in place -- see
    /// `body_may_capture_scope`/the pooled path in `Stmt::For`/`Stmt::While`
    /// (DOP_MIGRATION.md): reusing ONE `ScopeNode` across loop iterations
    /// instead of allocating a fresh one requires clearing whatever the
    /// PREVIOUS iteration bound, or a later iteration that doesn't rebind
    /// some name would incorrectly still see the old value.
    fn clear_vars(&self) {
        self.vars.borrow_mut().clear();
    }

    /// like `lookup`, but THIS scope only -- no walking to `parent`; the
    /// building block `lookup_cached` uses to check a single hinted depth
    /// without paying for the whole-chain walk the uncached path would.
    /// `name` is an ALREADY-interned symbol (an `Expr::Var`'s own name, see
    /// `ast.rs`'s `intern`), so comparing against a scope entry's own
    /// interned key hits `Rc::ptr_eq` first -- the actual point of
    /// interning (README.md's "identifier interning, the one that actually
    /// moved the needle most"): avoiding a byte-by-byte comparison entirely
    /// for the overwhelmingly common case.
    fn local_get_sym(&self, name: &Rc<str>) -> Option<Value> {
        self.vars.borrow().iter().find(|(k, _)| sym_eq_sym(k, name)).map(|(_, v)| v.clone())
    }

    /// like `bind`, but only MUTATES an existing entry in THIS scope --
    /// never creates one, and via the same pointer-equality-first
    /// comparison as `local_get_sym`. Returns whether an entry was found.
    fn try_set_local_sym(&self, name: &Rc<str>, v: &Value) -> bool {
        let mut vars = self.vars.borrow_mut();
        match vars.iter_mut().find(|(k, _)| sym_eq_sym(k, name)) {
            Some((_, slot)) => {
                *slot = v.clone();
                true
            }
            None => false,
        }
    }
}

/// the `ScopeNode` exactly `depth` `parent` hops up from `scope` (`depth ==
/// 0` is `scope` itself). `None` if the chain is shorter than `depth` --
/// only possible when a cached hint has gone stale (see `lookup_cached`).
fn scope_at_depth(scope: &Scope, depth: i32) -> Option<&ScopeNode> {
    let mut node: &ScopeNode = scope.as_ref();
    for _ in 0..depth {
        node = node.parent.as_ref()?.as_ref();
    }
    Some(node)
}

/// depth-cache-aware variable READ -- mirrors `bin/eval.ml`'s own read
/// depth cache (README.md's "Seven optimizations", step 4: "read/write
/// variable-depth caches"). `cache` remembers how many `parent` hops up
/// `scope` THIS EXACT `Expr::Var` node resolved to last time; recursion
/// never changes this depth (a call/loop-iteration frame's parent is
/// always its own STATIC definition/enclosing scope, never whatever
/// dynamic context is currently executing), so a learned depth stays valid
/// across every future evaluation of this same node. A wrong guess (only
/// possible if this exact node somehow saw a differently-shaped scope
/// chain) just falls back to the full walk below and re-learns -- provably
/// no worse than having no cache at all.
fn lookup_cached(scope: &Scope, name: &Rc<str>, cache: &DepthCache) -> Option<Value> {
    let hint = cache.0.get();
    if hint >= 0 {
        if let Some(node) = scope_at_depth(scope, hint) {
            if let Some(v) = node.local_get_sym(name) {
                return Some(v);
            }
        }
    }
    let mut node: &ScopeNode = scope.as_ref();
    let mut depth: i32 = 0;
    loop {
        if let Some(v) = node.local_get_sym(name) {
            cache.0.set(depth);
            return Some(v);
        }
        match &node.parent {
            Some(p) => {
                node = p.as_ref();
                depth += 1;
            }
            None => return None,
        }
    }
}

/// depth-cache-aware variable WRITE -- the write half of the same
/// optimization, mirroring `bin/eval.ml`'s `assign`'s own cache. Mutates an
/// EXISTING binding wherever up the chain it's found (matching
/// `try_assign`'s semantics exactly); if truly not found anywhere, creates
/// a fresh local in the CURRENT (innermost) scope -- and caches depth `0`
/// for that outcome too, since a function/loop-iteration scope is fresh
/// every single time it's entered (`with_child_scope`/`call_scoped`), so
/// "not found anywhere, create here" is exactly as static a fact about this
/// AST node as any real outer-variable depth is.
fn assign_cached(scope: &Scope, name: &Rc<str>, cache: &DepthCache, v: Value) {
    let hint = cache.0.get();
    if hint >= 0 {
        if let Some(node) = scope_at_depth(scope, hint) {
            if node.try_set_local_sym(name, &v) {
                return;
            }
        }
    }
    let mut node: &ScopeNode = scope.as_ref();
    let mut depth: i32 = 0;
    loop {
        if node.try_set_local_sym(name, &v) {
            cache.0.set(depth);
            return;
        }
        match &node.parent {
            Some(p) => {
                node = p.as_ref();
                depth += 1;
            }
            None => break,
        }
    }
    scope.bind(name, v);
    cache.0.set(0);
}

// ============================= Declarations =============================

pub struct FuncDef {
    pub params: Vec<Param>,
    pub kwparams: Vec<(String, Expr)>,
    pub body: Vec<Stmt>,
    pub def_env: Scope,
    pub def_prefix: String,
}

pub struct StructDef {
    pub canonical_name: String,
    pub field_names: Vec<String>,
    /// e.g. `["T"]` for `Box{T}`, `["K","V"]` for `Dict{K,V}`, `[]` if not
    /// parametric.
    pub type_params: Vec<String>,
    /// parallel to `field_names` -- used only to INFER a parametric
    /// instantiation's concrete tag (`"Box{Int}"`) at construction time,
    /// see `Env::construct`; not enforced against a field's actual value
    /// (see this module's own doc comment on known simplifications).
    pub field_types: Vec<Vec<String>>,
}

pub struct CtorDef {
    pub params: Vec<Param>,
    pub kwparams: Vec<(String, Expr)>,
    pub body: Vec<Stmt>,
    pub def_env: Scope,
}

pub struct MacroDef {
    pub params: Vec<String>,
    pub body: Vec<Stmt>,
}

/// real Julia performance/codegen hints (`@inline`, `@inbounds`, ...) never
/// change behavior in a tree-walking interpreter -- mirrors `bin/hints.ml`'s
/// `is_inert_hint_macro` exactly.
fn is_inert_hint_macro(name: &str) -> bool {
    matches!(
        name,
        "inline"
            | "noinline"
            | "inbounds"
            | "propagate_inbounds"
            | "simd"
            | "fastmath"
            | "boundscheck"
            | "nospecialize"
            | "specialize"
    )
}

const EXCEPTION_KINDS: &[&str] =
    &["DimensionMismatch", "BoundsError", "UndefVarError", "TypeError", "MethodError", "DomainError"];

// ============================= Env =============================

/// mirrors `bin/eval.ml`/`bin/runtime.ml`'s several side-channel `ref`s
/// (`current_kwargs`, `current_end`, `current_module_prefix`,
/// `current_constructing_struct`, the hygiene counter/current id) plus
/// `struct_defs`/`macros`/`Types.parent`, all bundled onto one `Env` (a
/// single execution context, single-threaded -- this crate never runs two
/// programs concurrently, so plain mutable fields suffice where OCaml uses
/// global `ref`s).
pub struct Env {
    scope: Scope,
    global: Scope,
    /// real multiple dispatch: several same-named overloads, resolved by
    /// argument TYPE at call time (see `resolve_overload`) -- mirrors
    /// `Dispatch.methods`'s per-name method LIST exactly, not just a
    /// name-keyed single slot.
    functions: HashMap<String, Vec<Rc<FuncDef>>>,
    structs: HashMap<String, Rc<StructDef>>,
    constructors: HashMap<String, Vec<Rc<CtorDef>>>,
    macros: HashMap<String, Rc<MacroDef>>,
    types_parent: HashMap<String, String>,
    module_prefix: String,
    current_end: i64,
    constructing_struct: Option<String>,
    hygiene_counter: u64,
    current_hygiene_id: Option<u64>,
    /// inline cache for `resolve_function` -- mirrors `bin/eval.ml`'s own
    /// `ECall` inline cache (see README.md's "Seven optimizations"): keyed
    /// by call NAME rather than by call site (this crate has no per-node
    /// mutable cache slot in `Expr`, see `ast.rs`'s doc comment on why it
    /// stays a plain, `Clone`/`PartialEq`-able tree) -- still sound, since
    /// the same (name, arg types) always resolves to the same method
    /// regardless of which call site asked. Bumping `function_generation`
    /// on every `declare_function` invalidates every entry in one
    /// comparison, same as the OCaml side's generation counter.
    call_cache: HashMap<String, CallCacheEntry>,
    function_generation: u64,
}

struct CallCacheEntry {
    tags: Vec<String>,
    def: Rc<FuncDef>,
    generation: u64,
}

impl Env {
    pub fn new() -> Self {
        let root = new_root_scope();
        root.bind("pi", Value::Float(std::f64::consts::PI));
        let mut env = Env {
            scope: root.clone(),
            global: root,
            functions: HashMap::new(),
            structs: HashMap::new(),
            constructors: HashMap::new(),
            macros: HashMap::new(),
            types_parent: HashMap::new(),
            module_prefix: String::new(),
            current_end: 0,
            constructing_struct: None,
            hygiene_counter: 0,
            current_hygiene_id: None,
            call_cache: HashMap::new(),
            function_generation: 0,
        };
        // built-in type hierarchy -- mirrors `Types`'s own top-level
        // `let () = ...` registering these exactly (needed for real
        // multiple dispatch: e.g. `f(x::Number)` must accept an Int OR a
        // Float argument).
        for (child, parent) in [
            ("Number", "Any"),
            ("Int", "Number"),
            ("Float", "Number"),
            ("Complex", "Number"),
            ("Bool", "Any"),
            ("String", "Any"),
            ("Nothing", "Any"),
            ("Range", "Any"),
            ("Vector", "Any"),
            ("Array", "Any"),
            ("Matrix", "Any"),
            ("Function", "Any"),
            ("Tuple", "Any"),
            ("Symbol", "Any"),
            ("Expr", "Any"),
        ] {
            env.types_parent.insert(child.to_string(), parent.to_string());
        }
        // typed exception hierarchy -- mirrors `bin/runtime.ml`'s own
        // top-level `let () = ...` registering these exactly.
        env.types_parent.insert("Exception".to_string(), "Any".to_string());
        for k in EXCEPTION_KINDS.iter().chain(std::iter::once(&"ErrorException")) {
            env.types_parent.insert(k.to_string(), "Exception".to_string());
            env.structs.insert(
                k.to_string(),
                Rc::new(StructDef {
                    canonical_name: k.to_string(),
                    field_names: vec!["msg".to_string()],
                    type_params: vec![],
                    field_types: vec![vec!["String".to_string()]],
                }),
            );
        }
        env
    }

    fn lookup_opt(&self, name: &str) -> Option<Value> {
        self.scope.lookup(name)
    }

    fn bind(&mut self, name: &str, v: Value) {
        self.scope.bind(name, v);
    }

    /// runs `f` with a fresh child scope of `def_env` as current, restoring
    /// afterward regardless of how `f` returns -- mirrors a function/
    /// closure call building its own fresh scope off its OWN captured
    /// `def_env`, not whatever scope happened to be current at the call
    /// site.
    fn call_scoped<T>(&mut self, def_env: &Scope, f: impl FnOnce(&mut Env) -> T) -> T {
        let saved = std::mem::replace(&mut self.scope, new_child_scope(def_env));
        let r = f(self);
        self.scope = saved;
        r
    }

    /// runs `f` with a fresh child of the CURRENT scope -- mirrors
    /// `new_scope env` for an `if`/`for`/`while`/`try` body.
    fn with_child_scope<T>(&mut self, f: impl FnOnce(&mut Env) -> T) -> T {
        let parent = self.scope.clone();
        self.call_scoped(&parent, f)
    }

    /// like `call_scoped`, but installs a GIVEN `Scope` object instead of
    /// always allocating a fresh one -- the building block for scope
    /// pooling (DOP_MIGRATION.md): a capture-free loop reuses the SAME
    /// pooled `Scope` (cleared between iterations via `clear_vars`) across
    /// every iteration, so `f` here just needs to swap it in as current and
    /// restore afterward, exactly like `call_scoped` does for a fresh one.
    fn with_existing_scope<T>(&mut self, scope: Scope, f: impl FnOnce(&mut Env) -> T) -> T {
        let saved = std::mem::replace(&mut self.scope, scope);
        let r = f(self);
        self.scope = saved;
        r
    }

    fn resolve_type_name(&self, n: &str) -> String {
        if self.module_prefix.is_empty() {
            return n.to_string();
        }
        let qualified = format!("{}{}", self.module_prefix, n);
        if self.types_parent.contains_key(&qualified) {
            qualified
        } else {
            n.to_string()
        }
    }

    fn declare_struct(
        &mut self,
        full_name: String,
        parent: String,
        type_params: Vec<String>,
        field_names: Vec<String>,
        field_types: Vec<Vec<String>>,
    ) {
        self.types_parent.insert(full_name.clone(), parent);
        self.structs.insert(
            full_name.clone(),
            Rc::new(StructDef { canonical_name: full_name, field_names, type_params, field_types }),
        );
    }

    fn declare_abstract(&mut self, full_name: String, parent: String) {
        self.types_parent.insert(full_name, parent);
    }

    /// a concrete parametric instantiation's tag (`"Box{Int}"`,
    /// `"Array{Named}"`, `"Pair{Int,String}"`) isn't pre-registered in
    /// `types_parent` (mirrors `Runtime.tag`/`construct`'s own on-the-fly
    /// `Types.declare` for these) -- computed structurally here instead
    /// (parent = the base name before `{`), which needs no mutation at all.
    /// This gets "some Box{Int} is-a Box" for free but NOT the OCaml side's
    /// covariant `Array{Player} <: Array{Entity}` matching (see this
    /// module's own doc comment) -- a real, narrower simplification.
    fn parent_of(&self, tag: &str) -> Option<String> {
        if let Some(p) = self.types_parent.get(tag) {
            return Some(p.clone());
        }
        if tag.ends_with('}') {
            if let Some(brace) = tag.find('{') {
                return Some(tag[..brace].to_string());
            }
        }
        None
    }

    /// splits a concrete instantiation's name into its base and parameters,
    /// e.g. `"Array{Int}"` -> `Some(("Array", ["Int"]))`, `"Pair{Int,String}"`
    /// -> `Some(("Pair", ["Int","String"]))`, `"Any"` -> `None`. Mirrors
    /// `Types.parse_concrete` exactly.
    fn parse_concrete(name: &str) -> Option<(String, Vec<String>)> {
        let brace = name.find('{')?;
        if !name.ends_with('}') {
            return None;
        }
        let base = name[..brace].to_string();
        let inner = &name[brace + 1..name.len() - 1];
        Some((base, inner.split(',').map(|s| s.to_string()).collect()))
    }

    /// mirrors `Types.distance_to` exactly: a plain ancestor-chain walk
    /// first, THEN a covariant fallback between two concrete instantiations
    /// of the SAME parametric family (`Array{Player} <: Array{Entity}`
    /// holds because `Array` matches `Array` and, position by position,
    /// `Player <: Entity` -- neither side needs to be pre-registered for
    /// this, unlike the plain walk). `None` if unrelated; `Some(0)` for an
    /// exact match; higher for each ancestor hop (or, for the covariant
    /// case, `1 + ` the worst per-parameter distance).
    fn isa_distance(&self, tag: &str, tname: &str) -> Option<u32> {
        let mut cur = tag.to_string();
        let mut d = 0u32;
        loop {
            if cur == tname {
                return Some(d);
            }
            match self.parent_of(&cur) {
                Some(p) if p != cur => {
                    cur = p;
                    d += 1;
                }
                _ => break,
            }
        }
        if let (Some((sub_base, sub_params)), Some((sup_base, sup_params))) =
            (Self::parse_concrete(tag), Self::parse_concrete(tname))
        {
            if sub_base == sup_base && sub_params.len() == sup_params.len() {
                let mut max_d = 0u32;
                for (sp, pp) in sub_params.iter().zip(sup_params.iter()) {
                    match self.isa_distance(sp, pp) {
                        Some(dd) => max_d = max_d.max(dd),
                        None => return if tname == "Any" { Some(u32::MAX / 2) } else { None },
                    }
                }
                return Some(1 + max_d);
            }
        }
        if tname == "Any" {
            Some(u32::MAX / 2)
        } else {
            None
        }
    }

    fn isa(&self, tag: &str, tname: &str) -> bool {
        tname == "Any" || self.isa_distance(tag, tname).is_some()
    }

    /// mirrors `Dispatch.matches_alt`/`best_distance`: a param's declared
    /// type is a LIST of alternatives (`["Any"]` if untyped, several for a
    /// `Union{A,B,C}`) -- matches if ANY alternative accepts the arg's tag,
    /// scored by the CLOSEST one.
    fn match_distance(&self, tag: &str, ptype: &[String]) -> Option<u32> {
        ptype.iter().filter_map(|t| if t == "Any" { Some(u32::MAX / 2) } else { self.isa_distance(tag, t) }).min()
    }

    /// mirrors `Dispatch.resolve` exactly: filter to applicable overloads
    /// (same arity, every param's type list accepts the corresponding arg),
    /// then pick the single most-specific one (lowest total distance);
    /// none applicable is a `MethodError`, a tie between the top two is an
    /// ambiguous-method `MethodError`, same as real Julia.
    fn resolve_overload<'a, T>(
        kind: &str,
        name: &str,
        arg_tags: &[String],
        candidates: &'a [Rc<T>],
        params_of: impl Fn(&T) -> &[Param],
        distance: impl Fn(&str, &[String]) -> Option<u32>,
    ) -> Result<Rc<T>, EvalError> {
        let mut scored: Vec<(u32, &Rc<T>)> = Vec::new();
        for def in candidates {
            let params = params_of(def);
            if params.len() != arg_tags.len() {
                continue;
            }
            let mut total = 0u32;
            let mut ok = true;
            for (p, tag) in params.iter().zip(arg_tags) {
                match distance(tag, &p.ptype) {
                    Some(d) => total += d,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                scored.push((total, def));
            }
        }
        scored.sort_by_key(|(s, _)| *s);
        match scored.as_slice() {
            [] => Err(EvalError(format!(
                "MethodError: no method matching {}({})",
                name,
                arg_tags.join(", ")
            ))),
            [(best, _), (second, _), ..] if second == best => Err(EvalError(format!(
                "MethodError: ambiguous method for {} {}({}) -- tied candidates",
                kind,
                name,
                arg_tags.join(", ")
            ))),
            [(_, m), ..] => Ok((*m).clone()),
        }
    }

    fn resolve_function(&mut self, name: &str, args: &[Value]) -> Result<Rc<FuncDef>, EvalError> {
        // cache hit: compare THIS call's arg types against the cached
        // signature with no allocation at all (`tag_eq`, not `value_tag`) --
        // mirrors the OCaml side's "allocation-free cache hits" step
        // exactly; only a genuine miss below builds `arg_tags`.
        if let Some(entry) = self.call_cache.get(name) {
            if entry.generation == self.function_generation
                && entry.tags.len() == args.len()
                && entry.tags.iter().zip(args).all(|(t, v)| tag_eq(v, t))
            {
                return Ok(entry.def.clone());
            }
        }
        let candidates = self.functions.get(name).map(|v| v.as_slice()).unwrap_or(&[]);
        let arg_tags: Vec<String> = args.iter().map(|v| value_tag(v).into_owned()).collect();
        let def = Env::resolve_overload("function", name, &arg_tags, candidates, |d: &FuncDef| d.params.as_slice(), |t, p| {
            self.match_distance(t, p)
        })?;
        self.call_cache.insert(
            name.to_string(),
            CallCacheEntry { tags: arg_tags, def: def.clone(), generation: self.function_generation },
        );
        Ok(def)
    }

    fn resolve_ctor(&self, name: &str, args: &[Value]) -> Result<Rc<CtorDef>, EvalError> {
        let candidates = self.constructors.get(name).map(|v| v.as_slice()).unwrap_or(&[]);
        let arg_tags: Vec<String> = args.iter().map(|v| value_tag(v).into_owned()).collect();
        Env::resolve_overload("constructor", name, &arg_tags, candidates, |d: &CtorDef| d.params.as_slice(), |t, p| {
            self.match_distance(t, p)
        })
    }

    /// mirrors `Dispatch.defmethod`: redefining a method with the exact same
    /// PARAMETER TYPE SIGNATURE replaces it (matching real Julia) rather
    /// than accumulating an ever-growing pile of identical, eventually-
    /// ambiguous candidates.
    fn declare_function(&mut self, name: String, def: FuncDef) {
        let sig: Vec<Vec<String>> = def.params.iter().map(|p| p.ptype.clone()).collect();
        let entry = self.functions.entry(name).or_default();
        entry.retain(|d| {
            let existing_sig: Vec<Vec<String>> = d.params.iter().map(|p| p.ptype.clone()).collect();
            existing_sig != sig
        });
        entry.push(Rc::new(def));
        // invalidates every `call_cache` entry in one comparison -- mirrors
        // the OCaml side's generation counter exactly (see `call_cache`'s
        // own doc comment on `Env`).
        self.function_generation += 1;
    }

    /// mirrors `Runtime.construct`: builds a struct instance from positional
    /// field values, in declaration order. `allow_partial` (only ever true
    /// for `new(...)`/`new{T}(...)`) lets fewer args than fields through,
    /// padding missing TRAILING fields with `Nothing` -- the standard way
    /// to build a self-referential struct (a field that has to point back
    /// at the very value being constructed can't be supplied yet).
    fn construct(&self, name: &str, args: Vec<Value>, allow_partial: bool) -> Result<Value, EvalError> {
        let def = self
            .structs
            .get(name)
            .ok_or_else(|| EvalError(format!("no such struct type: {}", name)))?;
        let nargs = args.len();
        let nfields = def.field_names.len();
        if allow_partial {
            if nargs > nfields {
                return Err(EvalError(format!("{} has {} field(s), new(...) given {}", name, nfields, nargs)));
            }
        } else if nargs != nfields {
            return Err(EvalError(format!("{} expects {} args, got {}", name, nfields, nargs)));
        }
        let mut padded = args;
        while padded.len() < nfields {
            padded.push(Value::Nothing);
        }
        // enforce field type annotations now -- except a field typed with
        // one of the struct's own type parameters (`::T`), whose concrete
        // type is INFERRED FROM this argument rather than a constraint it
        // must already satisfy; a field beyond the args actually given
        // (partial construction via `new`) has nothing to check yet.
        // Mirrors `Runtime.construct`'s own enforcement loop exactly.
        for (i, ftype) in def.field_types.iter().enumerate() {
            if i < nargs && ftype.as_slice() != ["Any"] && !is_type_param_field(ftype, def) {
                let arg_tag = value_tag(&padded[i]);
                if !ftype.iter().any(|t| self.isa(&arg_tag, t)) {
                    return Err(EvalError(format!(
                        "TypeError: field {}::{} cannot hold a {}",
                        def.field_names[i],
                        ftype.join("|"),
                        arg_tag
                    )));
                }
            }
        }
        // mirrors `Runtime.construct`'s own parametric-tag inference: for
        // each of the struct's own type params (`Box{T}`'s `T`), find the
        // first field (among the args actually GIVEN) declared exactly
        // `::T`, and use THAT argument's tag as the concrete parameter.
        // Only if every param resolves this way does the instance tag as
        // the concrete instantiation (`"Box{Int}"`); otherwise it stays
        // generic (`"Box"`).
        let kind = if def.type_params.is_empty() {
            def.canonical_name.clone()
        } else {
            let mut resolved = Vec::with_capacity(def.type_params.len());
            for tparam in &def.type_params {
                let found = def
                    .field_types
                    .iter()
                    .enumerate()
                    .find(|(i, ftype)| *i < nargs && ftype.len() == 1 && ftype[0] == *tparam)
                    .map(|(i, _)| value_tag(&padded[i]));
                match found {
                    Some(t) => resolved.push(t),
                    None => break,
                }
            }
            if resolved.len() == def.type_params.len() {
                format!("{}{{{}}}", def.canonical_name, resolved.join(","))
            } else {
                def.canonical_name.clone()
            }
        };
        let fields =
            def.field_names.iter().cloned().zip(padded).map(|(n, v)| (n, RefCell::new(v))).collect();
        Ok(Value::Struct(Rc::new(StructInstance { kind, fields })))
    }

    /// mirrors `Runtime.exn_of_failure_message`: reconstructs a real typed
    /// exception value from an internal `EvalError`'s own "Kind: message"
    /// string convention (every `EvalError` in this file already follows
    /// it, by the same convention `bin/runtime.ml`'s `failwith` sites do) --
    /// this is the one place such a message is ever parsed back apart, at
    /// the point a `try`/`catch` actually catches one.
    fn exn_of_failure_message(&self, msg: &str) -> Value {
        if let Some(i) = msg.find(':') {
            let kind = &msg[..i];
            if EXCEPTION_KINDS.contains(&kind) {
                let rest = if msg.len() > i + 2 { &msg[i + 2..] } else { "" };
                return self.construct(kind, vec![Value::Str(rest.to_string())], false).unwrap();
            }
        }
        self.construct("ErrorException", vec![Value::Str(msg.to_string())], false).unwrap()
    }

    /// mirrors `Runtime.use_module`: merges everything registered under
    /// `"ModName."` into the bare/global namespace -- mirrors
    /// `Runtime.use_module`: a module's overloads become EXTRA candidates
    /// of the bare name's own generic function (coexisting with whatever
    /// was already registered bare), same as top-level same-named
    /// `function` declarations already behaved before modules existed.
    fn use_module(&mut self, modname: &str) {
        let prefix = format!("{}.", modname);
        let func_keys: Vec<String> =
            self.functions.keys().filter(|k| k.starts_with(&prefix)).cloned().collect();
        for k in &func_keys {
            let bare = k[prefix.len()..].to_string();
            if let Some(defs) = self.functions.get(k).cloned() {
                self.functions.entry(bare).or_default().extend(defs);
            }
        }
        let struct_keys: Vec<String> =
            self.structs.keys().filter(|k| k.starts_with(&prefix)).cloned().collect();
        for k in &struct_keys {
            let bare = k[prefix.len()..].to_string();
            if let Some(def) = self.structs.get(k).cloned() {
                self.structs.entry(bare.clone()).or_insert(def);
            }
            if let Some(ctors) = self.constructors.get(k).cloned() {
                self.constructors.entry(bare).or_insert(ctors);
            }
        }
        // ancestor-chain splice for every qualified TYPE (struct or
        // abstract): qualified -> bare -> qualified's old parent, so `isa`
        // against the bare name recognizes an already-qualified-tagged
        // instance as related.
        let type_keys: Vec<String> =
            self.types_parent.keys().filter(|k| k.starts_with(&prefix)).cloned().collect();
        for k in &type_keys {
            let bare = k[prefix.len()..].to_string();
            if let Some(old_parent) = self.types_parent.get(k).cloned() {
                self.types_parent.entry(bare.clone()).or_insert(old_parent);
                self.types_parent.insert(k.clone(), bare);
            }
        }
    }
}

fn as_float(v: &Value) -> Result<f64, EvalError> {
    match v {
        Value::Int(n) => Ok(*n as f64),
        Value::Float(f) => Ok(*f),
        v => Err(EvalError(format!("expected a number, got {}", value_tag(v)))),
    }
}

fn as_int(v: &Value) -> Result<i64, EvalError> {
    match v {
        Value::Int(n) => Ok(*n),
        v => Err(EvalError(format!("expected an Int, got {}", value_tag(v)))),
    }
}

/// mirrors `bin/main.ml`'s `num2` promotion rule exactly: Int op Int stays
/// Int, anything else promotes both sides to Float first.
fn num_binop(
    a: &Value,
    b: &Value,
    iop: impl Fn(i64, i64) -> i64,
    fop: impl Fn(f64, f64) -> f64,
) -> Result<Value, EvalError> {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => Ok(Value::Int(iop(*x, *y))),
        _ => Ok(Value::Float(fop(as_float(a)?, as_float(b)?))),
    }
}

fn cmp_binop(
    a: &Value,
    b: &Value,
    icmp: impl Fn(i64, i64) -> bool,
    fcmp: impl Fn(f64, f64) -> bool,
) -> Result<Value, EvalError> {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => Ok(Value::Bool(icmp(*x, *y))),
        _ => Ok(Value::Bool(fcmp(as_float(a)?, as_float(b)?))),
    }
}

/// mirrors `bin/runtime.ml`'s `Dispatch.defmethod "^" [["Complex"];["Int"]]`
/// exactly: repeated multiplication, `n` times (`n <= 0` short-circuits to
/// `1 + 0i` without erroring).
fn complex_ipow(re: f64, im: f64, n: i64) -> (f64, f64) {
    let (mut ar, mut ai) = (1.0, 0.0);
    for _ in 0..n {
        let (nar, nai) = (ar * re - ai * im, ar * im + ai * re);
        ar = nar;
        ai = nai;
    }
    (ar, ai)
}

/// no `EBinOp` inline cache here, unlike `bin/eval.ml`'s own (README.md's
/// "Seven optimizations", step 1): on the OCaml side, `+`/`-`/`<`/... are
/// registered through the SAME `Dispatch.defmethod`/`resolve` machinery as
/// ordinary named functions, so operators pay the same candidate-filter +
/// specificity-score search a call does -- worth caching. Here, operators
/// are resolved to a `BinOpKind` ONCE at parse time (`ast.rs`) and this
/// function matches on that enum -- no per-call resolution step to cache in
/// the first place (this used to match on `&str` instead, which is NOT the
/// jump table an enum match is; that was an incorrect assumption in an
/// earlier version of this comment, corrected after actually investigating
/// why this crate was still slower than OCaml's fully-optimized
/// interpreter despite being compiled -- see `ast.rs`'s `BinOpKind` doc
/// comment for the fix). Likewise no analog of step 5's "monomorphic
/// string-key lookup, found by profiling": that fix replaced OCaml's
/// polymorphic `compare_val`-based `List.assoc_opt` with a hand-written
/// `String`-only comparator; every string comparison in THIS crate (`==` on
/// `&str`/`Rc<str>`) is already monomorphic Rust, with no
/// polymorphic-dispatch tax to remove.
fn eval_binop(op: &BinOpKind, a: Value, b: Value) -> Result<Value, EvalError> {
    if let (Value::Complex(ar, ai), Value::Complex(br, bi)) = (&a, &b) {
        return match op {
            BinOpKind::Add => Ok(Value::Complex(ar + br, ai + bi)),
            BinOpKind::Sub => Ok(Value::Complex(ar - br, ai - bi)),
            BinOpKind::Mul => Ok(Value::Complex((ar * br) - (ai * bi), (ar * bi) + (ai * br))),
            _ => Err(EvalError(format!("unsupported operator for Complex: {}", op.as_str()))),
        };
    }
    if let (Value::Complex(re, im), Value::Int(n)) = (&a, &b) {
        if *op == BinOpKind::Pow {
            let (rr, ri) = complex_ipow(*re, *im, *n);
            return Ok(Value::Complex(rr, ri));
        }
    }
    // matches `Dispatch.defmethod "+" [["String"];["String"]]` in
    // `bin/runtime.ml` exactly -- string concatenation, the operator
    // `interpolate_string` (parser.rs) chains interpolated pieces with.
    if let (Value::Str(x), Value::Str(y)) = (&a, &b) {
        if *op == BinOpKind::Add {
            return Ok(Value::Str(format!("{}{}", x, y)));
        }
    }
    match op {
        BinOpKind::Add => num_binop(&a, &b, |x, y| x + y, |x, y| x + y),
        BinOpKind::Sub => num_binop(&a, &b, |x, y| x - y, |x, y| x - y),
        BinOpKind::Mul => num_binop(&a, &b, |x, y| x * y, |x, y| x * y),
        BinOpKind::Div => Ok(Value::Float(as_float(&a)? / as_float(&b)?)),
        BinOpKind::Mod => num_binop(&a, &b, |x, y| x % y, |x, y| x % y),
        BinOpKind::Lt => cmp_binop(&a, &b, |x, y| x < y, |x, y| x < y),
        BinOpKind::Le => cmp_binop(&a, &b, |x, y| x <= y, |x, y| x <= y),
        BinOpKind::Gt => cmp_binop(&a, &b, |x, y| x > y, |x, y| x > y),
        BinOpKind::Ge => cmp_binop(&a, &b, |x, y| x >= y, |x, y| x >= y),
        BinOpKind::Eq => cmp_binop(&a, &b, |x, y| x == y, |x, y| x == y),
        BinOpKind::Ne => cmp_binop(&a, &b, |x, y| x != y, |x, y| x != y),
        BinOpKind::Pow => match (&a, &b) {
            (Value::Int(_), Value::Int(e)) if *e < 0 => Err(EvalError(format!(
                "DomainError: Cannot raise an integer x to a negative power {}",
                e
            ))),
            (Value::Int(base), Value::Int(e)) => {
                fn ipow(b: i64, e: i64) -> i64 {
                    if e == 0 {
                        1
                    } else {
                        let half = ipow(b, e / 2);
                        let half2 = half * half;
                        if e % 2 == 0 {
                            half2
                        } else {
                            half2 * b
                        }
                    }
                }
                Ok(Value::Int(ipow(*base, *e)))
            }
            _ => Ok(Value::Float(as_float(&a)?.powf(as_float(&b)?))),
        },
        BinOpKind::Shr => match (&a, &b) {
            (Value::Int(x), Value::Int(y)) => Ok(Value::Int(((*x as u64) >> (*y as u32)) as i64)),
            _ => Err(EvalError(format!("expected (Int, Int) for >>>, got ({:?}, {:?})", a, b))),
        },
        BinOpKind::Colon | BinOpKind::And | BinOpKind::Or | BinOpKind::Other(_) => {
            Err(EvalError(format!("unsupported operator: {}", op.as_str())))
        }
    }
}

/// mirrors `bin/eval.ml`'s `range_ints` exactly: the actual integers a step
/// range denotes, e.g. `range_ints(1, 2, 7) = [1, 3, 5, 7]`.
fn range_ints(a: i64, step: i64, b: i64) -> Result<Vec<i64>, EvalError> {
    if step == 0 {
        return Err(EvalError("range step cannot be 0".to_string()));
    }
    let mut acc = Vec::new();
    let mut i = a;
    while if step > 0 { i <= b } else { i >= b } {
        acc.push(i);
        i += step;
    }
    Ok(acc)
}

// ============================= Signal / control flow =============================

/// mirrors `bin/eval.ml`'s `Return_exc`/`JuliaError` -- `?` on an `SResult`
/// propagates any of the three variants automatically.
#[derive(Debug)]
pub enum Signal {
    /// an internal interpreter failure (`Failure msg` on the OCaml side) --
    /// caught by `try`/`catch` via `exn_of_failure_message`.
    Error(EvalError),
    /// `throw(v)`/`error(msg)` -- a real, catchable value (`JuliaError v`).
    Thrown(Value),
    /// `return` unwinds a statement list via early exit -- caught by
    /// whatever function/closure call is running, never by `try`/`catch`.
    Return(Value),
}

impl From<EvalError> for Signal {
    fn from(e: EvalError) -> Self {
        Signal::Error(e)
    }
}

impl Signal {
    pub fn message(&self) -> String {
        match self {
            Signal::Error(e) => e.0.clone(),
            Signal::Thrown(v) => format!("uncaught exception: {}", show(v)),
            Signal::Return(_) => {
                "uncaught top-level return (escapes the program on the OCaml side too, as an uncaught Return_exc)".to_string()
            }
        }
    }
}

pub type SResult<T> = Result<T, Signal>;

// ============================= Expression evaluation =============================

fn eval_args(args: &[Expr], env: &mut Env) -> SResult<Vec<Value>> {
    args.iter().map(|a| eval(a, env)).collect()
}

fn eval_kwargs(kwargs: &[(String, Expr)], env: &mut Env) -> SResult<Vec<(String, Value)>> {
    kwargs.iter().map(|(k, e)| Ok((k.clone(), eval(e, env)?))).collect()
}

pub fn eval(e: &Expr, env: &mut Env) -> SResult<Value> {
    match e {
        Expr::Int(n) => Ok(Value::Int(*n)),
        Expr::Float(f) => Ok(Value::Float(*f)),
        Expr::Str(s) => Ok(Value::Str(s.clone())),
        Expr::Bool(b) => Ok(Value::Bool(*b)),
        Expr::Nothing => Ok(Value::Nothing),
        Expr::End => Ok(Value::Int(env.current_end)),
        Expr::Var(name, cache) => lookup_cached(&env.scope, name, cache)
            .ok_or_else(|| EvalError(format!("UndefVarError: {} not defined", name)).into()),
        Expr::Assign(name, rhs, cache) => {
            let v = eval(rhs, env)?;
            assign_cached(&env.scope, name, cache, v.clone());
            Ok(v)
        }
        Expr::FieldAssign(obj, f, rhs) => {
            let v = eval(rhs, env)?;
            let container = eval(obj, env)?;
            set_field(env, &container, f, v.clone())?;
            Ok(v)
        }
        Expr::BinOp(BinOpKind::Colon, a, b) => match (eval(a, env)?, eval(b, env)?) {
            (Value::Int(a), Value::Int(b)) => Ok(Value::Range(a, 1, b)),
            (a, b) => Ok(Value::FRange(as_float(&a)?, 1.0, as_float(&b)?)),
        },
        Expr::BinOp(BinOpKind::And, a, b) => match eval(a, env)? {
            Value::Bool(false) => Ok(Value::Bool(false)),
            Value::Bool(true) => match eval(b, env)? {
                Value::Bool(r) => Ok(Value::Bool(r)),
                v => Err(EvalError(format!("&& operand must be Bool, got {}", value_tag(&v))).into()),
            },
            v => Err(EvalError(format!("&& operand must be Bool, got {}", value_tag(&v))).into()),
        },
        Expr::BinOp(BinOpKind::Or, a, b) => match eval(a, env)? {
            Value::Bool(true) => Ok(Value::Bool(true)),
            Value::Bool(false) => match eval(b, env)? {
                Value::Bool(r) => Ok(Value::Bool(r)),
                v => Err(EvalError(format!("|| operand must be Bool, got {}", value_tag(&v))).into()),
            },
            v => Err(EvalError(format!("|| operand must be Bool, got {}", value_tag(&v))).into()),
        },
        Expr::BinOp(op, a, b) => Ok(eval_binop(op, eval(a, env)?, eval(b, env)?)?),
        Expr::RangeStep(lo, step, hi) => match (eval(lo, env)?, eval(step, env)?, eval(hi, env)?) {
            (Value::Int(a), Value::Int(s), Value::Int(b)) => Ok(Value::Range(a, s, b)),
            (a, s, b) => Ok(Value::FRange(as_float(&a)?, as_float(&s)?, as_float(&b)?)),
        },
        Expr::Ternary(c, t, f) => match eval(c, env)? {
            Value::Bool(true) => eval(t, env),
            Value::Bool(false) => eval(f, env),
            v => Err(EvalError(format!("ternary condition must be Bool, got {}", value_tag(&v))).into()),
        },
        Expr::ArrayLit(elems) => {
            let vals = eval_args(elems, env)?;
            if vals.iter().all(|v| matches!(v, Value::Int(_) | Value::Float(_))) {
                let floats: Result<Vec<f64>, EvalError> = vals.iter().map(as_float).collect();
                Ok(Value::Vector(Rc::new(RefCell::new(floats?))))
            } else {
                Ok(Value::Array(Rc::new(RefCell::new(vals)), None))
            }
        }
        Expr::MatrixLit(rows) => {
            let mut vals = Vec::with_capacity(rows.len());
            for row in rows {
                let r: Result<Vec<f64>, EvalError> = eval_args(row, env)?.iter().map(as_float).collect();
                vals.push(r?);
            }
            Ok(Value::Matrix(Rc::new(RefCell::new(vals))))
        }
        Expr::TypedArrayNew(elem_ty) => Ok(Value::Array(Rc::new(RefCell::new(Vec::new())), Some(elem_ty.clone()))),
        Expr::Comprehension(body, clauses) => match clauses.as_slice() {
            [(var, iter_e)] => {
                let items = iter_values(&eval(iter_e, env)?)?;
                let mut vals = Vec::with_capacity(items.len());
                for item in items {
                    let r = env.with_child_scope(|env| {
                        env.bind(var, item);
                        eval(body, env)
                    })?;
                    vals.push(r);
                }
                if vals.iter().all(|v| matches!(v, Value::Int(_) | Value::Float(_))) {
                    let floats: Result<Vec<f64>, EvalError> = vals.iter().map(as_float).collect();
                    Ok(Value::Vector(Rc::new(RefCell::new(floats?))))
                } else {
                    Ok(Value::Array(Rc::new(RefCell::new(vals)), None))
                }
            }
            [(var1, iter1_e), (var2, iter2_e)] => {
                let vs1 = iter_values(&eval(iter1_e, env)?)?;
                let vs2 = iter_values(&eval(iter2_e, env)?)?;
                let mut rows = Vec::with_capacity(vs1.len());
                for v1 in &vs1 {
                    let mut row = Vec::with_capacity(vs2.len());
                    for v2 in &vs2 {
                        let r = env.with_child_scope(|env| {
                            env.bind(var1, v1.clone());
                            env.bind(var2, v2.clone());
                            eval(body, env)
                        })?;
                        row.push(as_float(&r)?);
                    }
                    rows.push(row);
                }
                Ok(Value::Matrix(Rc::new(RefCell::new(rows))))
            }
            _ => Err(EvalError(
                "comprehensions support at most 2 for-clauses (no N-dimensional array type)".to_string(),
            )
            .into()),
        },
        Expr::Field(obj, f) => Ok(get_field(&eval(obj, env)?, f)?),
        Expr::Tuple(es) => Ok(Value::Tuple(eval_args(es, env)?)),
        Expr::Index(obj, idx_e) => eval_index(obj, idx_e, env),
        Expr::IndexAssign(obj, idx_e, rhs) => eval_index_assign(obj, idx_e, rhs, env),
        Expr::Lambda(params, body) => Ok(Value::Closure(Rc::new(ClosureDef {
            params: params.clone(),
            body: body.clone(),
            captured: env.scope.clone(),
            def_prefix: env.module_prefix.clone(),
        }))),
        Expr::Quote(inner) => expr_to_value(env, inner),
        Expr::QuoteSymbol(name) => Ok(Value::Symbol(Box::new((name.clone(), env.current_hygiene_id)))),
        Expr::QuoteBlock(stmts) => stmt_list_to_value(env, stmts),
        Expr::Interp(inner) => eval(inner, env),
        Expr::InterpAssign(_, _) => {
            Err(EvalError("$(...) = ... is only meaningful inside a quote".to_string()).into())
        }
        Expr::Block(stmts) => exec_stmt_list(env, stmts),
        Expr::MacroCall(name, arg_exprs) => eval_macro_call(name, arg_exprs, env),
        // `error(msg)`/`throw(v)` -- a real, catchable value, not a plain
        // interpreter failure. Special-cased before the generic call
        // dispatch below, same as `println`/`print`/`typeof`/`isa` are on
        // the OCaml side.
        Expr::Call(name, args, _) if name == "error" => {
            let argv = eval_args(args, env)?;
            match argv.as_slice() {
                [Value::Str(s)] => {
                    let ex = env.construct("ErrorException", vec![Value::Str(s.clone())], false)?;
                    Err(Signal::Thrown(ex))
                }
                _ => Err(EvalError("error() expects one String argument".to_string()).into()),
            }
        }
        Expr::Call(name, args, _) if name == "throw" => {
            let argv = eval_args(args, env)?;
            match argv.as_slice() {
                [v] => Err(Signal::Thrown(v.clone())),
                _ => Err(EvalError("throw() expects exactly one argument".to_string()).into()),
            }
        }
        Expr::Call(name, args, _) if name == "println" || name == "print" => {
            let shown: Result<Vec<String>, EvalError> =
                eval_args(args, env)?.iter().map(|v| Ok(show(v))).collect();
            let line = shown?.join(" ");
            if name == "println" {
                println!("{}", line);
            } else {
                print!("{}", line);
            }
            Ok(Value::Nothing)
        }
        Expr::Call(name, args, _) if name == "typeof" => {
            let v = match args.as_slice() {
                [x] => eval(x, env)?,
                _ => return Err(EvalError("typeof expects exactly one argument".to_string()).into()),
            };
            Ok(Value::Str(value_tag(&v).into_owned()))
        }
        Expr::Call(name, args, _) if name == "isa" => match args.as_slice() {
            [x_e, Expr::Var(tname, _)] => {
                let v = eval(x_e, env)?;
                Ok(Value::Bool(env.isa(&value_tag(&v), tname)))
            }
            _ => Err(EvalError("isa(x, TypeName) expects a bare type name".to_string()).into()),
        },
        // `eval(quoted)` -- runs a Symbol/Expr (or plain literal) as real
        // code in the CURRENT scope, real Julia's actual `eval`.
        // `expansion_id: u64::MAX` is a sentinel no real macro expansion
        // ever uses (those start at 1, see `env.hygiene_counter`), so this
        // never renames anything -- exactly right for a plain `eval` call
        // with no active hygiene context of its own. Mirrors
        // `Dispatch.defmethod "eval"` (`bin/eval.ml`) exactly.
        Expr::Call(name, args, _) if name == "eval" => {
            let v = match eval_args(args, env)?.as_slice() {
                [v] => v.clone(),
                _ => return Err(EvalError("eval expects exactly one argument".to_string()).into()),
            };
            let mut rename_table = HashMap::new();
            let expanded = value_to_expr(env, &mut rename_table, u64::MAX, &v)?;
            eval(&expanded, env)
        }
        Expr::Call(name, args, kwargs) => {
            // a local variable shadowing the name as a closure wins, same
            // as Julia.
            if let Some(Value::Closure(cdef)) = env.lookup_opt(name) {
                let argv = eval_args(args, env)?;
                return call_closure(&cdef, argv, env);
            }
            if name == "new" {
                // only valid while one of a struct's own inner
                // constructors is directly running.
                let argv = eval_args(args, env)?;
                return match env.constructing_struct.clone() {
                    Some(sname) => Ok(env.construct(&sname, argv, true)?),
                    None => Err(EvalError(
                        "UndefVarError: new can only be used inside a struct's own inner constructor"
                            .to_string(),
                    )
                    .into()),
                };
            }
            let argv = eval_args(args, env)?;
            let kwv = eval_kwargs(kwargs, env)?;
            // inside a module, a bare call resolves within it first (so
            // code in `module M` calling `helper(...)` finds `M.helper`).
            let qualified = format!("{}{}", env.module_prefix, name);
            let resolved = if !env.module_prefix.is_empty()
                && (env.functions.contains_key(&qualified)
                    || env.structs.contains_key(&qualified)
                    || env.constructors.contains_key(&qualified))
            {
                qualified
            } else {
                name.clone()
            };
            call_named(env, &resolved, argv, kwv)
        }
        Expr::QualifiedCall(modname, member, args, kwargs) => {
            let qualified = format!("{}.{}", modname, member);
            if !(env.functions.contains_key(&qualified)
                || env.structs.contains_key(&qualified)
                || env.constructors.contains_key(&qualified))
            {
                return Err(EvalError(format!("UndefVarError: {} not defined", qualified)).into());
            }
            let argv = eval_args(args, env)?;
            let kwv = eval_kwargs(kwargs, env)?;
            call_named(env, &qualified, argv, kwv)
        }
    }
}

fn eval_index(obj: &Expr, idx_e: &Expr, env: &mut Env) -> SResult<Value> {
    // container evaluated before the index expression, on purpose: `end`
    // inside idx_e needs to already know this container's length.
    let container = eval(obj, env)?;
    match &container {
        Value::Vector(r) => env.current_end = r.borrow().len() as i64,
        Value::Array(cells, _) => env.current_end = cells.borrow().len() as i64,
        _ => {}
    }
    let idx = eval(idx_e, env)?;
    Ok(match (&container, &idx) {
        (Value::Vector(r), Value::Int(i)) => {
            let r = r.borrow();
            let i = *i;
            if i < 1 || i as usize > r.len() {
                return Err(EvalError(format!("BoundsError: index {}", i)).into());
            }
            Value::Float(r[(i - 1) as usize])
        }
        (Value::Vector(r), Value::Range(a, s, b)) => {
            let r = r.borrow();
            let idxs = range_ints(*a, *s, *b)?;
            if idxs.iter().any(|&i| i < 1 || i as usize > r.len()) {
                return Err(EvalError("BoundsError: slice index out of range".to_string()).into());
            }
            Value::Vector(Rc::new(RefCell::new(idxs.iter().map(|&i| r[(i - 1) as usize]).collect())))
        }
        (Value::Vector(_), _) => {
            return Err(EvalError("Vector index must be an Int or a Range".to_string()).into())
        }
        (Value::Array(cells, _), Value::Int(i)) => {
            let cells = cells.borrow();
            let i = *i;
            if i < 1 || i as usize > cells.len() {
                return Err(EvalError(format!("BoundsError: index {}", i)).into());
            }
            cells[(i - 1) as usize].clone()
        }
        (Value::Array(cells, declared), Value::Range(a, s, b)) => {
            let cells = cells.borrow();
            let idxs = range_ints(*a, *s, *b)?;
            if idxs.iter().any(|&i| i < 1 || i as usize > cells.len()) {
                return Err(EvalError("BoundsError: slice index out of range".to_string()).into());
            }
            Value::Array(
                Rc::new(RefCell::new(idxs.iter().map(|&i| cells[(i - 1) as usize].clone()).collect())),
                declared.clone(),
            )
        }
        (Value::Array(_, _), _) => {
            return Err(EvalError("Array index must be an Int or a Range".to_string()).into())
        }
        (Value::Matrix(rows), Value::Tuple(t)) if t.len() == 2 => {
            let (i, j) = (as_int(&t[0])?, as_int(&t[1])?);
            let rows = rows.borrow();
            if i < 1 || i as usize > rows.len() {
                return Err(EvalError(format!("BoundsError: row {}", i)).into());
            }
            if j < 1 || j as usize > rows[0].len() {
                return Err(EvalError(format!("BoundsError: column {}", j)).into());
            }
            Value::Float(rows[(i - 1) as usize][(j - 1) as usize])
        }
        (Value::Matrix(_), _) => {
            return Err(EvalError("Matrix index must be a pair of Ints, A[i,j]".to_string()).into())
        }
        _ => return Err(EvalError("indexing is only supported on Vector, Array, or Matrix".to_string()).into()),
    })
}

fn eval_index_assign(obj: &Expr, idx_e: &Expr, rhs: &Expr, env: &mut Env) -> SResult<Value> {
    let container = eval(obj, env)?;
    match &container {
        Value::Vector(r) => env.current_end = r.borrow().len() as i64,
        Value::Array(cells, _) => env.current_end = cells.borrow().len() as i64,
        _ => {}
    }
    let idx = eval(idx_e, env)?;
    Ok(match (&container, &idx) {
        (Value::Vector(r), Value::Int(i)) => {
            let i = *i;
            let mut r = r.borrow_mut();
            if i < 1 || i as usize > r.len() {
                return Err(EvalError(format!("BoundsError: index {}", i)).into());
            }
            let v = as_float(&eval(rhs, env)?)?;
            r[(i - 1) as usize] = v;
            Value::Float(v)
        }
        (Value::Vector(_), _) => return Err(EvalError("Vector index must be an Int".to_string()).into()),
        (Value::Array(cells, _), Value::Int(i)) => {
            let i = *i;
            let len = cells.borrow().len();
            if i < 1 || i as usize > len {
                return Err(EvalError(format!("BoundsError: index {}", i)).into());
            }
            let v = eval(rhs, env)?;
            cells.borrow_mut()[(i - 1) as usize] = v.clone();
            v
        }
        (Value::Array(_, _), _) => return Err(EvalError("Array index must be an Int".to_string()).into()),
        (Value::Matrix(rows), Value::Tuple(t)) if t.len() == 2 => {
            let (i, j) = (as_int(&t[0])?, as_int(&t[1])?);
            let mut rows = rows.borrow_mut();
            if i < 1 || i as usize > rows.len() {
                return Err(EvalError(format!("BoundsError: row {}", i)).into());
            }
            if j < 1 || j as usize > rows[0].len() {
                return Err(EvalError(format!("BoundsError: column {}", j)).into());
            }
            let v = as_float(&eval(rhs, env)?)?;
            rows[(i - 1) as usize][(j - 1) as usize] = v;
            Value::Float(v)
        }
        (Value::Matrix(_), _) => {
            return Err(EvalError("Matrix index must be a pair of Ints, A[i,j]".to_string()).into())
        }
        _ => return Err(EvalError("indexing is only supported on Vector, Array, or Matrix".to_string()).into()),
    })
}

fn get_field(v: &Value, name: &str) -> Result<Value, EvalError> {
    match v {
        Value::Struct(inst) => inst
            .fields
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, r)| r.borrow().clone())
            .ok_or_else(|| EvalError(format!("type {} has no field {}", inst.kind, name))),
        _ => Err(EvalError(format!("{} is not a struct, has no fields", value_tag(v)))),
    }
}

/// true if `ftype` is either bare `::T` (one of the struct's own type
/// parameters) or a self-referential parametric reference to the struct
/// ITSELF (`next::Node{T}` inside Node's own declaration). Both have their
/// concrete type filled in dynamically rather than being a fixed constraint
/// to check a value against, so field type-checking (`construct`,
/// `set_field`) skips enforcement entirely for these. Mirrors
/// `Runtime.is_type_param_field` exactly.
/// `esc(x)` -- strips every Symbol's hygiene tag inside a quoted value,
/// recursively. Mirrors `Runtime.esc_value` exactly.
fn esc_value(v: &Value) -> Value {
    match v {
        Value::Symbol(b) => Value::Symbol(Box::new((b.0.clone(), None))),
        Value::ExprV(b) => Value::ExprV(Box::new((b.0.clone(), b.1.iter().map(esc_value).collect()))),
        v => v.clone(),
    }
}

fn is_type_param_field(ftype: &[String], def: &StructDef) -> bool {
    if ftype.len() != 1 {
        return false;
    }
    let t = &ftype[0];
    if def.type_params.contains(t) {
        return true;
    }
    if let Some(brace) = t.find('{') {
        if t.ends_with('}') {
            let base = &t[..brace];
            let inner = &t[brace + 1..t.len() - 1];
            if base == def.canonical_name && def.type_params.iter().any(|p| p == inner) {
                return true;
            }
        }
    }
    false
}

/// struct_defs is keyed by the base name ("Box"), but a parametric struct's
/// values carry a concrete instantiated kind ("Box{Int}") -- strip that
/// back off to find the declaration when checking a field's declared type.
/// Mirrors `Runtime.struct_def_for` exactly.
fn struct_def_for<'a>(env: &'a Env, kind: &str) -> Option<&'a Rc<StructDef>> {
    if let Some(sd) = env.structs.get(kind) {
        return Some(sd);
    }
    let base = kind.split('{').next()?;
    env.structs.get(base)
}

fn set_field(env: &Env, v: &Value, name: &str, newv: Value) -> Result<(), EvalError> {
    match v {
        Value::Struct(inst) => match inst.fields.iter().find(|(n, _)| n == name) {
            Some((_, r)) => {
                // matches `Runtime.set_field`'s own enforcement exactly --
                // the SAME check `construct` does, now also applied on
                // assignment, not just at birth.
                if let Some(sd) = struct_def_for(env, &inst.kind) {
                    if let Some(ftype) = sd
                        .field_names
                        .iter()
                        .position(|n| n == name)
                        .and_then(|i| sd.field_types.get(i))
                    {
                        if ftype.as_slice() != ["Any"] && !is_type_param_field(ftype, sd) {
                            let new_tag = value_tag(&newv);
                            if !ftype.iter().any(|t| env.isa(&new_tag, t)) {
                                return Err(EvalError(format!(
                                    "TypeError: field {}::{} cannot hold a {}",
                                    name,
                                    ftype.join("|"),
                                    new_tag
                                )));
                            }
                        }
                    }
                }
                *r.borrow_mut() = newv;
                Ok(())
            }
            None => Err(EvalError(format!("type {} has no field {}", inst.kind, name))),
        },
        _ => Err(EvalError(format!("{} is not a struct, has no fields", value_tag(v)))),
    }
}

/// mirrors `bin/eval.ml`'s `tree_walk_impl`/`call_user_function`: binds
/// positional args, then keyword args (caller-supplied value or the
/// default expression evaluated fresh in this call's own scope), runs the
/// body against a fresh scope of the function's OWN captured `def_env`
/// (real lexical closure, not just "always global"), and -- critically --
/// catches `Signal::Return` here, converting it into this call's own
/// return value; only `Signal::Error`/`Signal::Thrown` escape past a
/// function call.
fn call_user_function(
    env: &mut Env,
    def: &Rc<FuncDef>,
    args: Vec<Value>,
    kwargs: Vec<(String, Value)>,
) -> SResult<Value> {
    if args.len() != def.params.len() {
        return Err(EvalError(format!(
            "function expects {} argument(s), got {}",
            def.params.len(),
            args.len()
        ))
        .into());
    }
    let saved_prefix = std::mem::replace(&mut env.module_prefix, def.def_prefix.clone());
    let saved_scope = std::mem::replace(&mut env.scope, new_child_scope(&def.def_env));
    for (p, v) in def.params.iter().zip(args) {
        env.bind(&p.pname, v);
    }
    let kw_result = bind_kwparams(env, &def.kwparams, &kwargs);
    let result = kw_result.and_then(|()| exec_stmt_list(env, &def.body));
    env.scope = saved_scope;
    env.module_prefix = saved_prefix;
    match result {
        Ok(v) => Ok(v),
        Err(Signal::Return(v)) => Ok(v),
        Err(e) => Err(e),
    }
}

fn bind_kwparams(env: &mut Env, kwparams: &[(String, Expr)], kwargs: &[(String, Value)]) -> SResult<()> {
    for (kname, default_e) in kwparams {
        let v = match kwargs.iter().find(|(k, _)| k == kname) {
            Some((_, v)) => v.clone(),
            None => eval(default_e, env)?,
        };
        env.bind(kname, v);
    }
    Ok(())
}

/// mirrors `bin/eval.ml`'s `ELambda`'s own `VClosure` call: same
/// catch-`Return`-here rule as `call_user_function`, plus the same
/// module-prefix save/restore `ELambda`'s closure does.
fn call_closure(cdef: &Rc<ClosureDef>, args: Vec<Value>, env: &mut Env) -> SResult<Value> {
    if args.len() != cdef.params.len() {
        return Err(EvalError(format!(
            "function expects {} argument(s), got {}",
            cdef.params.len(),
            args.len()
        ))
        .into());
    }
    let saved_prefix = std::mem::replace(&mut env.module_prefix, cdef.def_prefix.clone());
    let saved_scope = std::mem::replace(&mut env.scope, new_child_scope(&cdef.captured));
    for (p, v) in cdef.params.iter().zip(args) {
        env.bind(p, v);
    }
    let result = exec_stmt_list(env, &cdef.body);
    env.scope = saved_scope;
    env.module_prefix = saved_prefix;
    match result {
        Ok(v) => Ok(v),
        Err(Signal::Return(v)) => Ok(v),
        Err(e) => Err(e),
    }
}

/// mirrors `bin/eval.ml`'s `SStructDecl`'s own inner-constructor impl:
/// picks the first registered constructor whose ARITY matches (a
/// simplification of real multiple dispatch, see this module's own doc
/// comment), binds params/kwparams, and runs the body with
/// `current_constructing_struct` set so `new(...)` inside it knows which
/// struct to build.
fn call_ctor(env: &mut Env, full_name: &str, args: Vec<Value>, kwargs: Vec<(String, Value)>) -> SResult<Value> {
    let ctor = env.resolve_ctor(full_name, &args)?;
    let saved_scope = std::mem::replace(&mut env.scope, new_child_scope(&ctor.def_env));
    for (p, v) in ctor.params.iter().zip(args) {
        env.bind(&p.pname, v);
    }
    let kw_result = bind_kwparams(env, &ctor.kwparams, &kwargs);
    let saved_constructing = env.constructing_struct.replace(full_name.to_string());
    let result = kw_result.and_then(|()| exec_stmt_list(env, &ctor.body));
    env.constructing_struct = saved_constructing;
    env.scope = saved_scope;
    match result {
        Ok(v) => Ok(v),
        Err(Signal::Return(v)) => Ok(v),
        Err(e) => Err(e),
    }
}

/// shared by a bare `ECall`/`EQualifiedCall`'s common tail: a struct with no
/// custom constructor builds directly; one with at least one registered
/// inner constructor dispatches through those instead; otherwise a
/// user-declared function; otherwise a builtin.
fn call_named(env: &mut Env, name: &str, args: Vec<Value>, kwargs: Vec<(String, Value)>) -> SResult<Value> {
    if env.structs.contains_key(name) && !env.constructors.contains_key(name) {
        return Ok(env.construct(name, args, false)?);
    }
    if env.constructors.contains_key(name) {
        return call_ctor(env, name, args, kwargs);
    }
    if env.functions.contains_key(name) {
        let def = env.resolve_function(name, &args)?;
        return call_user_function(env, &def, args, kwargs);
    }
    Ok(eval_call(env, name, args)?)
}

/// mirrors `bin/eval.ml`'s `iter_values_do`/`iter_values`: the values a
/// `for` header's (or comprehension clause's) iterable actually walks.
fn iter_values(v: &Value) -> Result<Vec<Value>, EvalError> {
    match v {
        Value::Range(a, s, b) => Ok(range_ints(*a, *s, *b)?.into_iter().map(Value::Int).collect()),
        Value::FRange(a, s, b) => {
            if *s == 0.0 {
                return Err(EvalError("range step cannot be 0".to_string()));
            }
            let count = ((b - a) / s).round() as i64;
            Ok((0..=count).map(|i| Value::Float(a + (i as f64) * s)).collect())
        }
        Value::Vector(v) => Ok(v.borrow().iter().map(|x| Value::Float(*x)).collect()),
        Value::Array(cells, _) => Ok(cells.borrow().clone()),
        v => Err(EvalError(format!("expected a Range, Vector, or Array to iterate, got {}", value_tag(v)))),
    }
}

/// mirrors `bin/eval.ml`'s `iter_values_do` exactly (see README.md's "three
/// more optimizations": `for`'s hot path used to build a full `int list`
/// via `range_ints` and then map it into a `value list` -- one allocation
/// `for` never needs to pay). `Stmt::For` uses this instead of materializing
/// `iter_values` up front: a `Range`/`FRange` is walked by direct stepping,
/// no intermediate `Vec` at all. `Vector`/`Array` still snapshot into a
/// `Vec` first (matching `iter_values`'s own behavior) since the loop body
/// may itself mutate the very container being iterated, and this crate's
/// `for` (like `bin/eval.ml`'s) iterates over the values as of loop entry.
fn for_each_value(v: &Value, mut f: impl FnMut(Value) -> SResult<()>) -> SResult<()> {
    match v {
        Value::Range(a, s, b) => {
            let (a, s, b) = (*a, *s, *b);
            if s == 0 {
                return Err(EvalError("range step cannot be 0".to_string()).into());
            }
            let mut i = a;
            while if s > 0 { i <= b } else { i >= b } {
                f(Value::Int(i))?;
                i += s;
            }
            Ok(())
        }
        Value::FRange(a, s, b) => {
            let (a, s) = (*a, *s);
            if s == 0.0 {
                return Err(EvalError("range step cannot be 0".to_string()).into());
            }
            let count = ((b - a) / s).round() as i64;
            for i in 0..=count {
                f(Value::Float(a + (i as f64) * s))?;
            }
            Ok(())
        }
        Value::Vector(v) => {
            for x in v.borrow().clone() {
                f(Value::Float(x))?;
            }
            Ok(())
        }
        Value::Array(cells, _) => {
            for item in cells.borrow().clone() {
                f(item)?;
            }
            Ok(())
        }
        v => Err(EvalError(format!("expected a Range, Vector, or Array to iterate, got {}", value_tag(v))).into()),
    }
}

fn process_start() -> std::time::Instant {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    *START.get_or_init(std::time::Instant::now)
}

/// xorshift64 -- no external `rand` crate is a dependency of this crate, and
/// real randomness isn't the point here (only `rand`'s output SHAPE matters
/// for benchmarking, e.g. quicksort's `sortperf` needing an array to sort).
fn next_rand_f64() -> f64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static STATE: AtomicU64 = AtomicU64::new(0);
    let mut x = STATE.load(Ordering::Relaxed);
    if x == 0 {
        x = process_start().elapsed().as_nanos() as u64 | 1;
    }
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    STATE.store(x, Ordering::Relaxed);
    (x >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
}

/// the small set of builtin calls whose arguments stay inside this crate's
/// value space -- mirrors the narrow slice of `Dispatch.defmethod`
/// registrations (`bin/runtime.ml`) this crate's example/test programs
/// actually exercise (see this module's own doc comment: no full standard
/// library, that's out of scope for a syntax-focused differential tester).
fn eval_call(env: &mut Env, name: &str, args: Vec<Value>) -> Result<Value, EvalError> {
    match (name, args.as_slice()) {
        ("string", [v]) => Ok(Value::Str(show(v))),
        // `esc(x)` -- strips every Symbol's hygiene tag inside a quoted
        // value, recursively, so that part of a macro's expansion resolves
        // at the CALL SITE instead of being renamed. Mirrors
        // `Runtime.esc_value` exactly.
        ("esc", [v]) => Ok(esc_value(v)),
        // a fresh, guaranteed-unique Symbol on demand -- macro-writing
        // builtins, mirrors `Dispatch.defmethod "gensym"` exactly (untagged:
        // its whole point is that the raw name is already unique, so it
        // passes through hygiene renaming unchanged).
        ("gensym", []) => {
            env.hygiene_counter += 1;
            Ok(Value::Symbol(Box::new((format!("##gensym#{}", env.hygiene_counter), None))))
        }
        ("gensym", [Value::Str(base)]) => {
            env.hygiene_counter += 1;
            Ok(Value::Symbol(Box::new((format!("##{}#{}", base, env.hygiene_counter), None))))
        }
        // for benchmarking only (examples/*.jl's own `t0 = time(); ...; t1 =
        // time()` pattern) -- mirrors `Dispatch.defmethod "time"`'s intent
        // (wall/CPU seconds elapsed), measured here as wall time since
        // process start rather than `Sys.time()`'s CPU-time semantics, which
        // std has no direct equivalent for.
        ("time", []) => Ok(Value::Float(process_start().elapsed().as_secs_f64())),
        // mirrors `Dispatch.defmethod "rand"`'s two overloads exactly (plain
        // -> one Float in [0,1), rand(n::Int) -> an n-element Vector) via a
        // small xorshift64 PRNG -- good enough for benchmarking (quicksort's
        // own `sortperf` needs an array to sort, not real entropy).
        ("rand", []) => Ok(Value::Float(next_rand_f64())),
        ("rand", [Value::Int(n)]) => {
            let v: Vec<f64> = (0..*n).map(|_| next_rand_f64()).collect();
            Ok(Value::Vector(Rc::new(RefCell::new(v))))
        }
        ("sqrt", [Value::Float(f)]) => Ok(Value::Float(f.sqrt())),
        ("sqrt", [Value::Int(n)]) => Ok(Value::Float((*n as f64).sqrt())),
        ("abs", [Value::Int(n)]) => Ok(Value::Int(n.abs())),
        ("abs", [Value::Float(f)]) => Ok(Value::Float(f.abs())),
        ("abs", [Value::Complex(re, im)]) => Ok(Value::Float(re.hypot(*im))),
        ("complex", [Value::Float(re), Value::Float(im)]) => Ok(Value::Complex(*re, *im)),
        ("complex", [Value::Int(re), Value::Int(im)]) => Ok(Value::Complex(*re as f64, *im as f64)),
        ("real", [Value::Complex(re, _)]) => Ok(Value::Float(*re)),
        ("imag", [Value::Complex(_, im)]) => Ok(Value::Float(*im)),
        ("length", [Value::Vector(v)]) => Ok(Value::Int(v.borrow().len() as i64)),
        ("length", [Value::Array(v, _)]) => Ok(Value::Int(v.borrow().len() as i64)),
        ("sum", [Value::Matrix(rows)]) => {
            let rows = rows.borrow();
            Ok(Value::Float(rows.iter().flatten().sum()))
        }
        ("transpose", [Value::Matrix(rows)]) => {
            let rows = rows.borrow();
            if rows.is_empty() {
                return Ok(Value::Matrix(Rc::new(RefCell::new(Vec::new()))));
            }
            let (nr, nc) = (rows.len(), rows[0].len());
            let mut out = vec![vec![0.0; nr]; nc];
            for (i, row) in rows.iter().enumerate() {
                for (j, x) in row.iter().enumerate() {
                    out[j][i] = *x;
                }
            }
            Ok(Value::Matrix(Rc::new(RefCell::new(out))))
        }
        // matches `Dispatch.defmethod "transpose" [["Vector"]]` exactly: a
        // Vector transposes into a genuine 1xN Matrix, not another Vector
        // (verified: `[1.0,2.0,3.0]'` shows as `[1. 2. 3.]`, the Matrix
        // single-row format, not `[1., 2., 3.]`, the Vector one).
        ("transpose", [Value::Vector(v)]) => Ok(Value::Matrix(Rc::new(RefCell::new(vec![v.borrow().clone()])))),
        // matches `Dispatch.defmethod "push!" [["Vector"];["Float"|"Int"]]`
        // exactly -- mutates the underlying storage in place (aliasing,
        // same as every other Vector op here) and returns the Vector
        // itself.
        ("push!", [Value::Vector(r), Value::Float(x)]) => {
            r.borrow_mut().push(*x);
            Ok(args[0].clone())
        }
        ("push!", [Value::Vector(r), Value::Int(x)]) => {
            r.borrow_mut().push(*x as f64);
            Ok(args[0].clone())
        }
        // matches `Dispatch.defmethod "push!" [["Array"];["Any"]]` --
        // `declared` (a real `Array{T}()`) IS enforced (see `EIndexAssign`'s
        // own comment for why this is the one Array-related check this
        // crate does bother with), returns the (aliased) Array itself,
        // same as the OCaml side.
        ("push!", [Value::Array(cells, declared), _]) => {
            let x = args[1].clone();
            if let Some(t) = declared {
                let x_tag = value_tag(&x);
                if !env.isa(&x_tag, t) {
                    return Err(EvalError(format!("TypeError: Array{{{}}} cannot hold a {}", t, x_tag)));
                }
            }
            cells.borrow_mut().push(x);
            Ok(args[0].clone())
        }
        // matches `Dispatch.call`'s own fallback exactly (`MethodError: no
        // method matching name(tags)`) -- kept in this exact format, not a
        // crate-specific message, since `try`/`catch` relies on this "Kind:
        // message" convention to reconstruct a real, catchable
        // `MethodError` struct (see `Env::exn_of_failure_message`).
        _ => Err(EvalError(format!(
            "MethodError: no method matching {}({})",
            name,
            args.iter().map(value_tag).collect::<Vec<_>>().join(", ")
        ))),
    }
}

// ============================= Quoting =============================

/// mirrors `bin/eval.ml`'s `expr_to_value`: reifies parsed syntax as data
/// (real Julia's `Symbol`/`Expr`). `env` is only used for `Interp`
/// ($-splices), which evaluate NORMALLY and splice the resulting value in
/// directly. Every other case walks the AST shape into an equivalent
/// `Symbol`/`ExprV` tree, tagging each name with the CURRENT hygiene id.
fn expr_to_value(env: &mut Env, e: &Expr) -> SResult<Value> {
    Ok(match e {
        Expr::Int(n) => Value::Int(*n),
        Expr::Float(f) => Value::Float(*f),
        Expr::Str(s) => Value::Str(s.clone()),
        Expr::Bool(b) => Value::Bool(*b),
        Expr::Nothing => Value::Nothing,
        Expr::Var(name, _) => Value::Symbol(Box::new((name.to_string(), env.current_hygiene_id))),
        Expr::Interp(inner) => eval(inner, env)?,
        Expr::InterpAssign(target_e, rhs) => match eval(target_e, env)? {
            Value::Symbol(b) => Value::ExprV(Box::new((
                "=".to_string(),
                vec![Value::Symbol(b), expr_to_value(env, rhs)?],
            ))),
            v => {
                return Err(EvalError(format!(
                    "quoting: $(...) = ... needs the interpolated target to be a Symbol, got a {}",
                    value_tag(&v)
                ))
                .into())
            }
        },
        Expr::BinOp(op, a, b) => Value::ExprV(Box::new((
            "call".to_string(),
            vec![
                Value::Symbol(Box::new((op.as_str().to_string(), env.current_hygiene_id))),
                expr_to_value(env, a)?,
                expr_to_value(env, b)?,
            ],
        ))),
        Expr::Call(_, _, kwargs) if !kwargs.is_empty() => {
            return Err(EvalError("quoting a call with keyword arguments isn't supported".to_string()).into())
        }
        Expr::Call(name, args, _) => {
            let mut vs = vec![Value::Symbol(Box::new((name.clone(), env.current_hygiene_id)))];
            for a in args {
                vs.push(expr_to_value(env, a)?);
            }
            Value::ExprV(Box::new(("call".to_string(), vs)))
        }
        Expr::Field(obj, f) => Value::ExprV(Box::new((
            ".".to_string(),
            vec![expr_to_value(env, obj)?, Value::Symbol(Box::new((f.clone(), env.current_hygiene_id)))],
        ))),
        Expr::Assign(name, rhs, _) => Value::ExprV(Box::new((
            "=".to_string(),
            vec![Value::Symbol(Box::new((name.to_string(), env.current_hygiene_id))), expr_to_value(env, rhs)?],
        ))),
        Expr::FieldAssign(obj, f, rhs) => Value::ExprV(Box::new((
            "field=".to_string(),
            vec![
                expr_to_value(env, obj)?,
                Value::Symbol(Box::new((f.clone(), env.current_hygiene_id))),
                expr_to_value(env, rhs)?,
            ],
        ))),
        Expr::Index(obj, idx) => {
            Value::ExprV(Box::new(("ref".to_string(), vec![expr_to_value(env, obj)?, expr_to_value(env, idx)?])))
        }
        Expr::IndexAssign(obj, idx, rhs) => Value::ExprV(Box::new((
            "index=".to_string(),
            vec![expr_to_value(env, obj)?, expr_to_value(env, idx)?, expr_to_value(env, rhs)?],
        ))),
        Expr::Tuple(es) => {
            let mut vs = Vec::with_capacity(es.len());
            for e in es {
                vs.push(expr_to_value(env, e)?);
            }
            Value::ExprV(Box::new(("tuple".to_string(), vs)))
        }
        Expr::Ternary(c, t, f) => Value::ExprV(Box::new((
            "if".to_string(),
            vec![expr_to_value(env, c)?, expr_to_value(env, t)?, expr_to_value(env, f)?],
        ))),
        Expr::RangeStep(a, s, b) => Value::ExprV(Box::new((
            "range3".to_string(),
            vec![expr_to_value(env, a)?, expr_to_value(env, s)?, expr_to_value(env, b)?],
        ))),
        Expr::QualifiedCall(_, _, _, kwargs) if !kwargs.is_empty() => {
            return Err(
                EvalError("quoting a qualified call with keyword arguments isn't supported".to_string()).into(),
            )
        }
        Expr::QualifiedCall(m, mem, args, _) => {
            let mut vs = vec![
                Value::Symbol(Box::new((m.clone(), env.current_hygiene_id))),
                Value::Symbol(Box::new((mem.clone(), env.current_hygiene_id))),
            ];
            for a in args {
                vs.push(expr_to_value(env, a)?);
            }
            Value::ExprV(Box::new(("modcall".to_string(), vs)))
        }
        Expr::Quote(inner) => Value::ExprV(Box::new(("quoted".to_string(), vec![expr_to_value(env, inner)?]))),
        Expr::QuoteSymbol(name) => Value::Symbol(Box::new((name.clone(), env.current_hygiene_id))),
        Expr::QuoteBlock(stmts) => stmt_list_to_value(env, stmts)?,
        Expr::End
        | Expr::ArrayLit(_)
        | Expr::Lambda(_, _)
        | Expr::Comprehension(_, _)
        | Expr::MatrixLit(_)
        | Expr::TypedArrayNew(_)
        | Expr::MacroCall(_, _)
        | Expr::Block(_) => {
            return Err(EvalError(
                "quoting this kind of expression isn't supported (array/matrix literals, lambdas, \
                 comprehensions, Array{T}(), and nested macro calls can't appear inside a quote)"
                    .to_string(),
            )
            .into())
        }
    })
}

fn stmt_to_value(env: &mut Env, s: &Stmt) -> SResult<Value> {
    Ok(match s {
        Stmt::Expr(e) => expr_to_value(env, e)?,
        Stmt::If(branches, else_body) if branches.len() == 1 => {
            let (cond, then_body) = &branches[0];
            let else_v = match else_body {
                Some(eb) => stmt_list_to_value(env, eb)?,
                None => Value::Nothing,
            };
            Value::ExprV(Box::new((
                "if_stmt".to_string(),
                vec![expr_to_value(env, cond)?, stmt_list_to_value(env, then_body)?, else_v],
            )))
        }
        Stmt::If(_, _) => {
            return Err(
                EvalError("quoting an if/elseif chain isn't supported -- only a single if/else".to_string()).into(),
            )
        }
        Stmt::For(var, iter, body) => Value::ExprV(Box::new((
            "for".to_string(),
            vec![
                Value::Symbol(Box::new((var.clone(), env.current_hygiene_id))),
                expr_to_value(env, iter)?,
                stmt_list_to_value(env, body)?,
            ],
        ))),
        Stmt::While(cond, body) => Value::ExprV(Box::new((
            "while".to_string(),
            vec![expr_to_value(env, cond)?, stmt_list_to_value(env, body)?],
        ))),
        Stmt::Return(None) => Value::ExprV(Box::new(("return".to_string(), vec![]))),
        Stmt::Return(Some(e)) => Value::ExprV(Box::new(("return".to_string(), vec![expr_to_value(env, e)?]))),
        Stmt::Destructure(targets, rhs) => {
            let mut ts = Vec::with_capacity(targets.len());
            for t in targets {
                ts.push(expr_to_value(env, t)?);
            }
            Value::ExprV(Box::new((
                "destructure".to_string(),
                vec![Value::ExprV(Box::new(("tuple".to_string(), ts))), expr_to_value(env, rhs)?],
            )))
        }
        Stmt::FuncDecl(..)
        | Stmt::StructDecl { .. }
        | Stmt::AbstractDecl(..)
        | Stmt::Try(..)
        | Stmt::ModuleDecl(..)
        | Stmt::Using(_)
        | Stmt::MacroDecl(..)
        | Stmt::Export(_)
        | Stmt::MacroCall(..) => {
            return Err(EvalError(
                "quoting this kind of statement isn't supported (function/struct/abstract-type/module/macro \
                 declarations, export, nested macro calls, and try/catch can't appear inside a quote)"
                    .to_string(),
            )
            .into())
        }
    })
}

fn stmt_list_to_value(env: &mut Env, stmts: &[Stmt]) -> SResult<Value> {
    let mut vs = Vec::with_capacity(stmts.len());
    for s in stmts {
        vs.push(stmt_to_value(env, s)?);
    }
    Ok(Value::ExprV(Box::new(("block".to_string(), vs))))
}

/// hygiene: a `Symbol` tagged with THIS expansion's id gets renamed (once
/// per distinct original name, memoized in `rename_table` so every
/// occurrence agrees) to a fresh gensym'd name; anything else passes
/// through as the bare name, resolving at the splice site's own scope.
fn resolve_symbol(
    env: &mut Env,
    rename_table: &mut HashMap<String, String>,
    expansion_id: u64,
    name: &str,
    tag: Option<u64>,
) -> String {
    if tag == Some(expansion_id) {
        if let Some(fresh) = rename_table.get(name) {
            return fresh.clone();
        }
        env.hygiene_counter += 1;
        let fresh = format!("##{}#{}", name, env.hygiene_counter);
        rename_table.insert(name.to_string(), fresh.clone());
        fresh
    } else {
        name.to_string()
    }
}

/// mirrors `bin/eval.ml`'s `value_to_expr` -- the inverse of
/// `expr_to_value`/`stmt_to_value`, splicing a macro's returned
/// `Symbol`/`Expr` (or plain literal) back into real code. Statement-shaped
/// values (`block`/`if_stmt`/`for`/`while`/`return`/`destructure`) get
/// wrapped in `Expr::Block` so the result is always a single `Expr`
/// regardless of what shape the macro actually returned.
fn value_to_expr(
    env: &mut Env,
    rename_table: &mut HashMap<String, String>,
    expansion_id: u64,
    v: &Value,
) -> Result<Expr, EvalError> {
    match v {
        Value::Int(n) => Ok(Expr::Int(*n)),
        Value::Float(f) => Ok(Expr::Float(*f)),
        Value::Str(s) => Ok(Expr::Str(s.clone())),
        Value::Bool(b) => Ok(Expr::Bool(*b)),
        Value::Nothing => Ok(Expr::Nothing),
        Value::Symbol(b) => Ok(Expr::Var(
            intern(&resolve_symbol(env, rename_table, expansion_id, &b.0, b.1)),
            DepthCache::new(),
        )),
        Value::ExprV(b) if b.0 == "call" && b.1.len() >= 1 => {
            let (_, args) = b.as_ref();
            match &args[0] {
                Value::Symbol(fb) => {
                    let fname = &fb.0;
                    let rest: Result<Vec<Expr>, EvalError> =
                        args[1..].iter().map(|a| value_to_expr(env, rename_table, expansion_id, a)).collect();
                    let rest = rest?;
                    if rest.len() == 2
                        && matches!(
                            fname.as_str(),
                            "+" | "-" | "*" | "/" | "%" | "^" | ">>>" | "<" | "<=" | ">" | ">=" | "==" | "!=" | "&&"
                                | "||" | ":"
                        )
                    {
                        let mut it = rest.into_iter();
                        let a = it.next().unwrap();
                        let b = it.next().unwrap();
                        Ok(Expr::BinOp(BinOpKind::parse(fname), Box::new(a), Box::new(b)))
                    } else {
                        Ok(Expr::Call(fname.clone(), rest, vec![]))
                    }
                }
                _ => Err(EvalError("macro expansion: a quoted call's head must be a Symbol".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "." && b.1.len() == 2 => {
            let args = &b.1;
            match &args[1] {
                Value::Symbol(fb) => {
                    Ok(Expr::Field(Box::new(value_to_expr(env, rename_table, expansion_id, &args[0])?), fb.0.clone()))
                }
                _ => Err(EvalError("macro expansion: a quoted field access's field must be a Symbol".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "=" && b.1.len() == 2 => {
            let args = &b.1;
            match &args[0] {
                Value::Symbol(nb) => Ok(Expr::Assign(
                    intern(&resolve_symbol(env, rename_table, expansion_id, &nb.0, nb.1)),
                    Box::new(value_to_expr(env, rename_table, expansion_id, &args[1])?),
                    DepthCache::new(),
                )),
                _ => Err(EvalError("macro expansion: an assignment target must be a Symbol".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "field=" && b.1.len() == 3 => {
            let args = &b.1;
            match &args[1] {
                Value::Symbol(fb) => Ok(Expr::FieldAssign(
                    Box::new(value_to_expr(env, rename_table, expansion_id, &args[0])?),
                    fb.0.clone(),
                    Box::new(value_to_expr(env, rename_table, expansion_id, &args[2])?),
                )),
                _ => Err(EvalError("macro expansion: a field-assignment field must be a Symbol".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "ref" && b.1.len() == 2 => Ok(Expr::Index(
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[0])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[1])?),
        )),
        Value::ExprV(b) if b.0 == "index=" && b.1.len() == 3 => Ok(Expr::IndexAssign(
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[0])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[1])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[2])?),
        )),
        Value::ExprV(b) if b.0 == "tuple" => {
            let es: Result<Vec<Expr>, EvalError> =
                b.1.iter().map(|a| value_to_expr(env, rename_table, expansion_id, a)).collect();
            Ok(Expr::Tuple(es?))
        }
        Value::ExprV(b) if b.0 == "if" && b.1.len() == 3 => Ok(Expr::Ternary(
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[0])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[1])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[2])?),
        )),
        Value::ExprV(b) if b.0 == "range3" && b.1.len() == 3 => Ok(Expr::RangeStep(
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[0])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[1])?),
            Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[2])?),
        )),
        Value::ExprV(b) if b.0 == "modcall" && b.1.len() >= 2 => {
            let args = &b.1;
            match (&args[0], &args[1]) {
                (Value::Symbol(mb), Value::Symbol(memb)) => {
                    let rest: Result<Vec<Expr>, EvalError> =
                        args[2..].iter().map(|a| value_to_expr(env, rename_table, expansion_id, a)).collect();
                    Ok(Expr::QualifiedCall(mb.0.clone(), memb.0.clone(), rest?, vec![]))
                }
                _ => {
                    Err(EvalError("macro expansion: a quoted qualified call's head must be two Symbols".to_string()))
                }
            }
        }
        Value::ExprV(b) if b.0 == "quoted" && b.1.len() == 1 => {
            Ok(Expr::Quote(Box::new(value_to_expr(env, rename_table, expansion_id, &b.1[0])?)))
        }
        Value::ExprV(b)
            if matches!(b.0.as_str(), "block" | "if_stmt" | "for" | "while" | "return" | "destructure") =>
        {
            Ok(Expr::Block(value_to_stmt_list_inner(env, rename_table, expansion_id, v)?))
        }
        Value::ExprV(b) => Err(EvalError(format!(
            "macro expansion: don't know how to un-quote Expr(:{}, ...) with {} arg(s)",
            b.0,
            b.1.len()
        ))),
        v => Err(EvalError(format!(
            "macro expansion: a macro must return quoted syntax (a Symbol/Expr) or a plain literal, got a {}",
            value_tag(v)
        ))),
    }
}

fn value_to_stmt(
    env: &mut Env,
    rename_table: &mut HashMap<String, String>,
    expansion_id: u64,
    v: &Value,
) -> Result<Stmt, EvalError> {
    match v {
        Value::ExprV(b) if b.0 == "if_stmt" && b.1.len() == 3 => {
            let args = &b.1;
            let then_body = value_to_stmt_list_inner(env, rename_table, expansion_id, &args[1])?;
            let else_body = match &args[2] {
                Value::Nothing => None,
                ev => Some(value_to_stmt_list_inner(env, rename_table, expansion_id, ev)?),
            };
            Ok(Stmt::If(vec![(value_to_expr(env, rename_table, expansion_id, &args[0])?, then_body)], else_body))
        }
        Value::ExprV(b) if b.0 == "for" && b.1.len() == 3 => {
            let args = &b.1;
            match &args[0] {
                Value::Symbol(vb) => Ok(Stmt::For(
                    resolve_symbol(env, rename_table, expansion_id, &vb.0, vb.1),
                    value_to_expr(env, rename_table, expansion_id, &args[1])?,
                    value_to_stmt_list_inner(env, rename_table, expansion_id, &args[2])?,
                )),
                _ => Err(EvalError("macro expansion: a quoted for-loop's variable must be a Symbol".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "while" && b.1.len() == 2 => Ok(Stmt::While(
            value_to_expr(env, rename_table, expansion_id, &b.1[0])?,
            value_to_stmt_list_inner(env, rename_table, expansion_id, &b.1[1])?,
        )),
        Value::ExprV(b) if b.0 == "return" => {
            let args = &b.1;
            if args.is_empty() {
                Ok(Stmt::Return(None))
            } else {
                Ok(Stmt::Return(Some(value_to_expr(env, rename_table, expansion_id, &args[0])?)))
            }
        }
        Value::ExprV(b) if b.0 == "destructure" && b.1.len() == 2 => {
            let args = &b.1;
            match &args[0] {
                Value::ExprV(b2) if b2.0 == "tuple" => {
                    let ts: Result<Vec<Expr>, EvalError> =
                        b2.1.iter().map(|t| value_to_expr(env, rename_table, expansion_id, t)).collect();
                    Ok(Stmt::Destructure(ts?, value_to_expr(env, rename_table, expansion_id, &args[1])?))
                }
                _ => Err(EvalError("macro expansion: a quoted destructure's targets must be a tuple".to_string())),
            }
        }
        Value::ExprV(b) if b.0 == "block" && b.1.len() == 1 => {
            value_to_stmt(env, rename_table, expansion_id, &b.1[0])
        }
        v => Ok(Stmt::Expr(value_to_expr(env, rename_table, expansion_id, v)?)),
    }
}

fn value_to_stmt_list_inner(
    env: &mut Env,
    rename_table: &mut HashMap<String, String>,
    expansion_id: u64,
    v: &Value,
) -> Result<Vec<Stmt>, EvalError> {
    match v {
        Value::ExprV(b) if b.0 == "block" => {
            b.1.iter().map(|a| value_to_stmt(env, rename_table, expansion_id, a)).collect()
        }
        _ => Ok(vec![value_to_stmt(env, rename_table, expansion_id, v)?]),
    }
}

/// `SMacroCall` needs the macro's result as a real stmt LIST to splice
/// directly into the surrounding statement sequence (not wrapped in
/// `Expr::Block`, which is only for splicing into an expression
/// position) -- a stmt-shaped result already comes back as `Expr::Block`
/// from `value_to_expr` (see its own "block"/"if_stmt"/... case), so
/// unwrap that; anything else is a plain expression, treated as one
/// expression-statement.
fn value_to_stmt_list(
    env: &mut Env,
    rename_table: &mut HashMap<String, String>,
    expansion_id: u64,
    v: &Value,
) -> Result<Vec<Stmt>, EvalError> {
    match value_to_expr(env, rename_table, expansion_id, v)? {
        Expr::Block(stmts) => Ok(stmts),
        e => Ok(vec![Stmt::Expr(e)]),
    }
}

fn eval_macro_call(name: &str, arg_exprs: &[Expr], env: &mut Env) -> SResult<Value> {
    let mdef = env
        .macros
        .get(name)
        .cloned()
        .ok_or_else(|| EvalError(format!("UndefVarError: @{} not defined", name)))?;
    if mdef.params.len() != arg_exprs.len() {
        return Err(EvalError(format!(
            "macro @{} expects {} argument(s), got {}",
            name,
            mdef.params.len(),
            arg_exprs.len()
        ))
        .into());
    }
    // macro arguments are passed UNEVALUATED -- reified as quoted syntax,
    // exactly what a real `:(...)` quote of that same expr would produce.
    let mut argv = Vec::with_capacity(arg_exprs.len());
    for a in arg_exprs {
        argv.push(expr_to_value(env, a)?);
    }
    let expansion_id = {
        env.hygiene_counter += 1;
        env.hygiene_counter
    };
    let saved_hygiene = env.current_hygiene_id;
    env.current_hygiene_id = Some(expansion_id);
    let saved_scope = std::mem::replace(&mut env.scope, new_child_scope(&env.global.clone()));
    for (p, v) in mdef.params.iter().zip(argv) {
        env.bind(p, v);
    }
    let result = exec_stmt_list(env, &mdef.body);
    env.scope = saved_scope;
    env.current_hygiene_id = saved_hygiene;
    let result_v = match result {
        Ok(v) => v,
        Err(Signal::Return(v)) => v,
        Err(e) => return Err(e),
    };
    let mut rename_table = HashMap::new();
    let expanded = value_to_expr(env, &mut rename_table, expansion_id, &result_v)?;
    eval(&expanded, env)
}

fn eval_macro_stmt_call(name: &str, inner: &Stmt, env: &mut Env) -> SResult<Value> {
    if is_inert_hint_macro(name) {
        return exec_stmt(env, inner);
    }
    let mdef = env
        .macros
        .get(name)
        .cloned()
        .ok_or_else(|| EvalError(format!("UndefVarError: @{} not defined", name)))?;
    if mdef.params.len() != 1 {
        return Err(EvalError(format!("macro @{} expects {} argument(s), got 1", name, mdef.params.len())).into());
    }
    let argv = vec![stmt_to_value(env, inner)?];
    let expansion_id = {
        env.hygiene_counter += 1;
        env.hygiene_counter
    };
    let saved_hygiene = env.current_hygiene_id;
    env.current_hygiene_id = Some(expansion_id);
    let saved_scope = std::mem::replace(&mut env.scope, new_child_scope(&env.global.clone()));
    for (p, v) in mdef.params.iter().zip(argv) {
        env.bind(p, v);
    }
    let result = exec_stmt_list(env, &mdef.body);
    env.scope = saved_scope;
    env.current_hygiene_id = saved_hygiene;
    let result_v = match result {
        Ok(v) => v,
        Err(Signal::Return(v)) => v,
        Err(e) => return Err(e),
    };
    let mut rename_table = HashMap::new();
    let expanded_stmts = value_to_stmt_list(env, &mut rename_table, expansion_id, &result_v)?;
    exec_stmt_list(env, &expanded_stmts)
}

// ============================= Statement execution =============================

/// used by `Stmt::Destructure`: a target can be any lvalue-shaped expr, not
/// just a bare name -- `a[i], a[j] = a[j], a[i]` is a real in-place swap.
fn assign_lvalue(target: &Expr, value: Value, env: &mut Env) -> SResult<()> {
    match target {
        Expr::Var(n, cache) => {
            assign_cached(&env.scope, n, cache, value);
            Ok(())
        }
        Expr::Field(obj, f) => {
            let container = eval(obj, env)?;
            Ok(set_field(env, &container, f, value)?)
        }
        Expr::Index(obj, idx_e) => {
            let container = eval(obj, env)?;
            let idx = eval(idx_e, env)?;
            match (&container, &idx) {
                (Value::Vector(r), Value::Int(i)) => {
                    let i = *i;
                    let mut r = r.borrow_mut();
                    if i < 1 || i as usize > r.len() {
                        return Err(EvalError(format!("BoundsError: index {}", i)).into());
                    }
                    r[(i - 1) as usize] = as_float(&value)?;
                    Ok(())
                }
                (Value::Array(cells, _), Value::Int(i)) => {
                    let i = *i;
                    let mut cells = cells.borrow_mut();
                    if i < 1 || i as usize > cells.len() {
                        return Err(EvalError(format!("BoundsError: index {}", i)).into());
                    }
                    cells[(i - 1) as usize] = value;
                    Ok(())
                }
                _ => Err(EvalError("invalid destructuring index target".to_string()).into()),
            }
        }
        _ => Err(EvalError("invalid destructuring target".to_string()).into()),
    }
}

/// `println`/`print` (and every other call) share `eval`'s own `Expr::Call`
/// dispatch -- a bare statement-level call (no `return`/assignment wrapping
/// it) must check user-declared functions/closures first, exactly like
/// every other call site.
fn exec_call_stmt(name: &str, args: &[Expr], kwargs: &[(String, Expr)], env: &mut Env) -> SResult<Value> {
    eval(&Expr::Call(name.to_string(), args.to_vec(), kwargs.to_vec()), env)
}

/// mirrors `bin/eval.ml`'s `exec_stmt_list`: a block's value is its last
/// statement's value (`Nothing` for an empty block).
pub fn exec_stmt_list(env: &mut Env, stmts: &[Stmt]) -> SResult<Value> {
    let mut result = Value::Nothing;
    for s in stmts {
        result = exec_stmt(env, s)?;
    }
    Ok(result)
}

/// conservative static check backing the scope-pooling optimization in
/// `Stmt::For`/`Stmt::While` below -- see DOP_MIGRATION.md for the full
/// reasoning. Returns `true` ("unsafe to pool, may capture") the moment it
/// finds anything that could make an iteration's scope outlive that
/// iteration. When in doubt, this returns `true`: a missed optimization
/// costs speed, a wrong `false` here would cost CORRECTNESS (closures
/// silently sharing one mutable binding across iterations), so every
/// ambiguous case below is resolved toward `true`.
fn body_may_capture_scope(body: &[Stmt]) -> bool {
    body.iter().any(stmt_may_capture_scope)
}

fn stmt_may_capture_scope(s: &Stmt) -> bool {
    match s {
        Stmt::Expr(e) => expr_may_capture_scope(e),
        Stmt::If(branches, else_body) => {
            branches.iter().any(|(cond, b)| expr_may_capture_scope(cond) || body_may_capture_scope(b))
                || else_body.as_deref().is_some_and(body_may_capture_scope)
        }
        Stmt::For(_, iter_e, b) => expr_may_capture_scope(iter_e) || body_may_capture_scope(b),
        Stmt::While(cond, b) => expr_may_capture_scope(cond) || body_may_capture_scope(b),
        // constructs a `FuncDef` whose `def_env` captures the CURRENT scope
        // (see `value.rs`'s `FuncDef`) -- always unsafe, regardless of what
        // the function body itself contains.
        Stmt::FuncDecl(..) => true,
        // a struct with at least one inner constructor builds a `CtorDef`
        // that ALSO captures `def_env`; a struct with none never captures
        // anything (`Env::construct` doesn't need a `Scope` at all).
        Stmt::StructDecl { constructors, .. } => !constructors.is_empty(),
        Stmt::AbstractDecl(..) => false,
        Stmt::Return(e) => e.as_ref().is_some_and(expr_may_capture_scope),
        Stmt::Try(body, _, catch_body) => body_may_capture_scope(body) || body_may_capture_scope(catch_body),
        Stmt::Destructure(targets, rhs) => {
            targets.iter().any(expr_may_capture_scope) || expr_may_capture_scope(rhs)
        }
        // not fully audited for whether its body opens its own fresh scope
        // layer -- conservatively unsafe rather than reasoned out for a
        // "declare a module inside a hot loop" pattern that doesn't occur
        // in practice.
        Stmt::ModuleDecl(..) => true,
        Stmt::Using(_) => false,
        // `MacroDef` (see `value.rs`) has no captured-`Scope` field at all,
        // and every macro CALL builds a fresh scope rooted at `env.global`
        // (never the declaration site's scope) -- the body itself is never
        // a capture risk, so it's not even worth recursing into.
        Stmt::MacroDecl(..) => false,
        Stmt::Export(_) => false,
        // a macro CALL's expansion is arbitrary code produced at RUNTIME by
        // running the macro's own body -- there's no way to know statically
        // whether it splices in a closure. Unsafe unconditionally.
        Stmt::MacroCall(..) => true,
    }
}

fn expr_may_capture_scope(e: &Expr) -> bool {
    match e {
        Expr::Int(_)
        | Expr::Float(_)
        | Expr::Str(_)
        | Expr::Bool(_)
        | Expr::Nothing
        | Expr::Var(..)
        | Expr::End
        | Expr::TypedArrayNew(_)
        | Expr::QuoteSymbol(_) => false,
        Expr::Assign(_, rhs, _) => expr_may_capture_scope(rhs),
        Expr::IndexAssign(a, b, c) | Expr::Ternary(a, b, c) | Expr::RangeStep(a, b, c) => {
            expr_may_capture_scope(a) || expr_may_capture_scope(b) || expr_may_capture_scope(c)
        }
        Expr::BinOp(_, a, b) | Expr::Index(a, b) => expr_may_capture_scope(a) || expr_may_capture_scope(b),
        Expr::Call(_, args, kwargs) | Expr::QualifiedCall(_, _, args, kwargs) => {
            args.iter().any(expr_may_capture_scope) || kwargs.iter().any(|(_, e)| expr_may_capture_scope(e))
        }
        Expr::Field(obj, _) => expr_may_capture_scope(obj),
        Expr::FieldAssign(obj, _, rhs) => expr_may_capture_scope(obj) || expr_may_capture_scope(rhs),
        Expr::ArrayLit(elems) | Expr::Tuple(elems) => elems.iter().any(expr_may_capture_scope),
        Expr::MatrixLit(rows) => rows.iter().flatten().any(expr_may_capture_scope),
        Expr::Comprehension(body, clauses) => {
            expr_may_capture_scope(body) || clauses.iter().any(|(_, iter_e)| expr_may_capture_scope(iter_e))
        }
        // constructs a `ClosureDef` capturing the CURRENT scope
        // (`ClosureDef.captured`, see `value.rs`) -- always unsafe.
        Expr::Lambda(..) => true,
        // quoted syntax is DATA until something evaluates it, and when it
        // IS evaluated it runs in whatever scope is current AT THAT LATER
        // POINT, not a scope captured at quote-time -- deliberately not
        // recursed into. Mirrors the same lesson `ast.rs`'s note on the
        // (unbuilt) static Resolve pass describes from the other direction:
        // quoted control-flow doesn't open a real scope.
        Expr::Quote(_) | Expr::QuoteBlock(_) => false,
        // documented as "a harmless passthrough anywhere else" outside a
        // quote context (see `ast.rs`) -- recursed into defensively.
        Expr::Interp(inner) => expr_may_capture_scope(inner),
        Expr::InterpAssign(a, b) => expr_may_capture_scope(a) || expr_may_capture_scope(b),
        // args are passed UNEVALUATED, but the macro's EXPANSION (arbitrary
        // runtime-produced code) gets executed in the CURRENT scope at the
        // call site -- see `Stmt::MacroCall`'s own comment above.
        Expr::MacroCall(..) => true,
        Expr::Block(stmts) => body_may_capture_scope(stmts),
    }
}

/// mirrors `bin/eval.ml`'s `exec_stmt` for the full statement grammar.
pub fn exec_stmt(env: &mut Env, s: &Stmt) -> SResult<Value> {
    match s {
        Stmt::Expr(Expr::Call(name, args, kwargs)) => exec_call_stmt(name, args, kwargs, env),
        Stmt::Expr(e) => eval(e, env),
        Stmt::Return(None) => Err(Signal::Return(Value::Nothing)),
        Stmt::Return(Some(e)) => Err(Signal::Return(eval(e, env)?)),
        Stmt::If(branches, else_body) => {
            for (cond, body) in branches {
                match eval(cond, env)? {
                    Value::Bool(true) => return env.with_child_scope(|env| exec_stmt_list(env, body)),
                    Value::Bool(false) => continue,
                    v => {
                        return Err(EvalError(format!("if condition must be Bool, got {}", value_tag(&v))).into())
                    }
                }
            }
            match else_body {
                Some(b) => env.with_child_scope(|env| exec_stmt_list(env, b)),
                None => Ok(Value::Nothing),
            }
        }
        Stmt::For(var, iter_e, body) => {
            let iter_val = eval(iter_e, env)?;
            // scope pooling (DOP_MIGRATION.md): only when the body provably
            // can't let a closure capture an iteration's scope. One `Scope`
            // is allocated for this loop's ENTIRE run instead of one per
            // iteration; `with_existing_scope` clears and reuses it each
            // time. The unsafe path below is untouched -- byte-for-byte the
            // same fresh-scope-per-iteration behavior as always.
            if body_may_capture_scope(body) {
                for_each_value(&iter_val, |item| {
                    env.with_child_scope(|env| {
                        env.bind(var, item);
                        exec_stmt_list(env, body)
                    })?;
                    Ok(())
                })?;
            } else {
                let pooled = new_child_scope(&env.scope);
                for_each_value(&iter_val, |item| {
                    pooled.clear_vars();
                    env.with_existing_scope(pooled.clone(), |env| {
                        env.bind(var, item);
                        exec_stmt_list(env, body)
                    })?;
                    Ok(())
                })?;
            }
            Ok(Value::Nothing)
        }
        Stmt::While(cond, body) => {
            let pooled = if body_may_capture_scope(body) { None } else { Some(new_child_scope(&env.scope)) };
            loop {
                match eval(cond, env)? {
                    Value::Bool(true) => match &pooled {
                        Some(scope) => {
                            scope.clear_vars();
                            env.with_existing_scope(scope.clone(), |env| exec_stmt_list(env, body))?;
                        }
                        None => {
                            env.with_child_scope(|env| exec_stmt_list(env, body))?;
                        }
                    },
                    Value::Bool(false) => break,
                    v => {
                        return Err(EvalError(format!("while condition must be Bool, got {}", value_tag(&v))).into())
                    }
                }
            }
            Ok(Value::Nothing)
        }
        Stmt::FuncDecl(name, params, kwparams, body) => {
            let full_name = format!("{}{}", env.module_prefix, name);
            let resolved_params: Vec<Param> = params
                .iter()
                .map(|p| Param {
                    pname: p.pname.clone(),
                    ptype: p.ptype.iter().map(|t| env.resolve_type_name(t)).collect(),
                })
                .collect();
            env.declare_function(
                full_name,
                FuncDef {
                    params: resolved_params,
                    kwparams: kwparams.clone(),
                    body: body.clone(),
                    def_env: env.scope.clone(),
                    def_prefix: env.module_prefix.clone(),
                },
            );
            Ok(Value::Nothing)
        }
        Stmt::StructDecl { mutable: _, name, parent, type_params, fields, constructors } => {
            let full_name = format!("{}{}", env.module_prefix, name);
            let parent_name = env.resolve_type_name(parent.as_deref().unwrap_or("Any"));
            let field_names = fields.iter().map(|f| f.fname.clone()).collect();
            let field_types: Vec<Vec<String>> = fields
                .iter()
                .map(|f| f.ftype.iter().map(|t| env.resolve_type_name(t)).collect())
                .collect();
            env.declare_struct(full_name.clone(), parent_name, type_params.clone(), field_names, field_types);
            if !constructors.is_empty() {
                let def_env = env.scope.clone();
                let ctor_defs: Vec<Rc<CtorDef>> = constructors
                    .iter()
                    .map(|(params, kwparams, body)| {
                        Rc::new(CtorDef {
                            params: params.clone(),
                            kwparams: kwparams.clone(),
                            body: body.clone(),
                            def_env: def_env.clone(),
                        })
                    })
                    .collect();
                env.constructors.insert(full_name, ctor_defs);
            }
            Ok(Value::Nothing)
        }
        Stmt::AbstractDecl(name, parent) => {
            let full_name = format!("{}{}", env.module_prefix, name);
            let parent_name = env.resolve_type_name(parent.as_deref().unwrap_or("Any"));
            env.declare_abstract(full_name, parent_name);
            Ok(Value::Nothing)
        }
        Stmt::Try(body, catchvar, catch_body) => {
            let saved = env.scope.clone();
            let result = env.with_child_scope(|env| exec_stmt_list(env, body));
            match result {
                Ok(v) => Ok(v),
                Err(Signal::Return(v)) => Err(Signal::Return(v)),
                Err(Signal::Thrown(v)) => {
                    env.scope = new_child_scope(&saved);
                    if let Some(n) = catchvar {
                        env.bind(n, v);
                    }
                    let r = exec_stmt_list(env, catch_body);
                    env.scope = saved;
                    r
                }
                Err(Signal::Error(e)) => {
                    let exn = env.exn_of_failure_message(&e.0);
                    env.scope = new_child_scope(&saved);
                    if let Some(n) = catchvar {
                        env.bind(n, exn);
                    }
                    let r = exec_stmt_list(env, catch_body);
                    env.scope = saved;
                    r
                }
            }
        }
        Stmt::Destructure(targets, rhs) => {
            let v = eval(rhs, env)?;
            match &v {
                Value::Tuple(vals) if vals.len() == targets.len() => {
                    for (t, val) in targets.iter().zip(vals.iter()) {
                        assign_lvalue(t, val.clone(), env)?;
                    }
                    Ok(v)
                }
                Value::Tuple(vals) => Err(EvalError(format!(
                    "cannot destructure a {}-tuple into {} targets",
                    vals.len(),
                    targets.len()
                ))
                .into()),
                v => Err(EvalError(format!(
                    "cannot destructure a {} into {} targets",
                    value_tag(v),
                    targets.len()
                ))
                .into()),
            }
        }
        Stmt::ModuleDecl(name, body) => {
            let saved = env.module_prefix.clone();
            env.module_prefix = format!("{}{}.", saved, name);
            exec_stmt_list(env, body)?;
            env.module_prefix = saved;
            Ok(Value::Nothing)
        }
        Stmt::Using(name) => {
            env.use_module(name);
            Ok(Value::Nothing)
        }
        Stmt::MacroDecl(name, params, body) => {
            // always bare/global -- macros aren't module-namespaced (a
            // scope cut, mirrors `bin/eval.ml`'s own `SMacroDecl`).
            env.macros.insert(
                name.clone(),
                Rc::new(MacroDef { params: params.clone(), body: body.clone() }),
            );
            Ok(Value::Nothing)
        }
        Stmt::Export(_) => Ok(Value::Nothing),
        Stmt::MacroCall(name, inner) => eval_macro_stmt_call(name, inner, env),
    }
}

/// mirrors `bin/eval.ml`'s `run`: executes a whole program at the top
/// level, discarding its last statement's value (only explicit
/// `println`/`print` calls inside it produce visible output). A top-level
/// `return` is deliberately NOT treated as a quiet success (see
/// `Signal::message`'s own comment) -- everything printed before the
/// `return` still reaches stdout either way, so this only changes what
/// happens AFTER.
pub fn exec_program(stmts: &[Stmt]) -> Result<(), Signal> {
    let mut env = Env::new();
    exec_stmt_list(&mut env, stmts).map(|_| ())
}

// ============================= Display =============================

/// mirrors `Runtime.array_elem_tag` exactly: `"Any"` if empty or genuinely
/// mixed-type, else the one tag every element shares.
fn array_elem_tag(cells: &[Value]) -> Cow<'static, str> {
    match cells.first() {
        None => Cow::Borrowed("Any"),
        Some(first) => {
            let t0 = value_tag(first);
            if cells.iter().all(|v| value_tag(v) == t0) {
                t0
            } else {
                Cow::Borrowed("Any")
            }
        }
    }
}

/// mirrors `Runtime.tag` exactly for every variant this evaluator can
/// produce. Returns a shared `'static` constant for every fixed-name
/// variant -- no allocation at all on the overwhelmingly common path (see
/// README.md's "physical-equality fast paths for ... string comparisons":
/// the OCaml side's version of this fix was sharing one string constant per
/// tag so comparisons hit physical equality; here the equivalent win is
/// not allocating a `String` in the first place). Only the two variants
/// whose tag is itself computed dynamically (`Array{T}`'s type parameter,
/// an untyped `Array`'s current element tag) still allocate.
pub fn value_tag(v: &Value) -> Cow<'static, str> {
    match v {
        Value::Int(_) => Cow::Borrowed("Int"),
        Value::Float(_) => Cow::Borrowed("Float"),
        Value::Bool(_) => Cow::Borrowed("Bool"),
        Value::Str(_) => Cow::Borrowed("String"),
        Value::Nothing => Cow::Borrowed("Nothing"),
        Value::Vector(_) => Cow::Borrowed("Vector"),
        Value::Matrix(_) => Cow::Borrowed("Matrix"),
        // declared via the real `Array{T}()` constructor -- fixed, enforced,
        // kept even while empty.
        Value::Array(_, Some(t)) => Cow::Owned(format!("Array{{{}}}", t)),
        // an ordinary literal/comprehension/push!'d Array: tagged by
        // whatever its CURRENT contents share, recomputed every time (not
        // stamped once), same as `Runtime.tag`'s own `array_elem_tag` --
        // "Array" if empty or genuinely mixed-type, "Array{ElemTag}" if
        // every element currently shares one tag.
        Value::Array(cells, None) => match array_elem_tag(&cells.borrow()) {
            t if t == "Any" => Cow::Borrowed("Array"),
            t => Cow::Owned(format!("Array{{{}}}", t)),
        },
        Value::Range(..) | Value::FRange(..) => Cow::Borrowed("Range"),
        Value::Tuple(_) => Cow::Borrowed("Tuple"),
        Value::Complex(..) => Cow::Borrowed("Complex"),
        Value::Closure(_) => Cow::Borrowed("Function"),
        Value::Struct(s) => Cow::Owned(s.kind.clone()),
        Value::Symbol(..) => Cow::Borrowed("Symbol"),
        Value::ExprV(..) => Cow::Borrowed("Expr"),
    }
}

/// `value_tag(v) == tag` with no allocation on the fixed-name variants --
/// used only by `resolve_function`'s cache-hit check (see `call_cache`'s
/// own doc comment). Falls back to the real, allocating `value_tag` for the
/// two variants whose tag is itself computed dynamically (an untyped
/// `Array`'s element tag), since there's nothing cheaper to compare there.
fn tag_eq(v: &Value, tag: &str) -> bool {
    match v {
        Value::Int(_) => tag == "Int",
        Value::Float(_) => tag == "Float",
        Value::Bool(_) => tag == "Bool",
        Value::Str(_) => tag == "String",
        Value::Nothing => tag == "Nothing",
        Value::Vector(_) => tag == "Vector",
        Value::Matrix(_) => tag == "Matrix",
        Value::Range(..) | Value::FRange(..) => tag == "Range",
        Value::Tuple(_) => tag == "Tuple",
        Value::Complex(..) => tag == "Complex",
        Value::Closure(_) => tag == "Function",
        Value::Struct(s) => s.kind == tag,
        Value::Symbol(..) => tag == "Symbol",
        Value::ExprV(..) => tag == "Expr",
        Value::Array(_, Some(t)) => tag.strip_prefix("Array{").and_then(|s| s.strip_suffix('}')) == Some(t.as_str()),
        Value::Array(_, None) => value_tag(v) == tag,
    }
}

/// Vector/Matrix elements print via OCaml's own `string_of_float`, NOT the
/// `%.3f` a bare scalar `Float` uses -- see this function's own callers in
/// `show` for the exact distinction (verified directly against `ocaml`'s
/// own REPL: `1. 0. 0.` for a Matrix's unit diagonal, not `1.000 0.000
/// 0.000`). Reimplemented here via Rust's own `{:e}` (exact, robust
/// exponent extraction) to decide fixed vs. scientific notation the same
/// way `%g` does, then trims trailing zeros -- an approximation, not a
/// byte-perfect port, but exact for everything actually checked (whole
/// numbers, many-decimal values, large/small magnitudes crossing the
/// fixed/scientific boundary, negative-exponent zero-padding like
/// `1.5e-05`).
fn ocaml_string_of_float(x: f64) -> String {
    if x.is_nan() {
        return "nan".to_string();
    }
    if x.is_infinite() {
        return if x < 0.0 { "-inf".to_string() } else { "inf".to_string() };
    }
    if x == 0.0 {
        return if x.is_sign_negative() { "-0.".to_string() } else { "0.".to_string() };
    }
    let sig: i32 = 12;
    let sci = format!("{:e}", x);
    let epos = sci.find('e').unwrap();
    let exp: i32 = sci[epos + 1..].parse().unwrap();

    if exp < -4 || exp >= sig {
        let prec = (sig - 1).max(0) as usize;
        let formatted = format!("{:.*e}", prec, x);
        let epos2 = formatted.find('e').unwrap();
        let (mantissa, exp_str) = formatted.split_at(epos2);
        let exp_val: i32 = exp_str[1..].parse().unwrap();
        let mantissa_trimmed = if mantissa.contains('.') {
            mantissa.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            mantissa.to_string()
        };
        format!("{}e{}{:02}", mantissa_trimmed, if exp_val < 0 { "-" } else { "+" }, exp_val.abs())
    } else {
        let prec = ((sig - 1) - exp).max(0) as usize;
        let formatted = format!("{:.*}", prec, x);
        if formatted.contains('.') {
            formatted.trim_end_matches('0').to_string()
        } else {
            format!("{}.", formatted)
        }
    }
}

/// matches `Runtime.show` (`bin/main.ml`) exactly for every variant this
/// evaluator can produce.
pub fn show(v: &Value) -> String {
    match v {
        Value::Int(n) => n.to_string(),
        Value::Float(f) => format!("{:.3}", f),
        Value::Str(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Nothing => "nothing".to_string(),
        Value::Range(a, 1, b) => format!("{}:{}", a, b),
        Value::Range(a, s, b) => format!("{}:{}:{}", a, s, b),
        Value::FRange(a, s, b) if *s == 1.0 => format!("{:.3}:{:.3}", a, b),
        Value::FRange(a, s, b) => format!("{:.3}:{:.3}:{:.3}", a, s, b),
        Value::Vector(v) => {
            let parts: Vec<String> = v.borrow().iter().map(|x| ocaml_string_of_float(*x)).collect();
            format!("[{}]", parts.join(", "))
        }
        Value::Matrix(rows) => {
            let parts: Vec<String> = rows
                .borrow()
                .iter()
                .map(|row| {
                    let cells: Vec<String> = row.iter().map(|x| ocaml_string_of_float(*x)).collect();
                    cells.join(" ")
                })
                .collect();
            format!("[{}]", parts.join("; "))
        }
        Value::Array(cells, _) => {
            let parts: Vec<String> = cells.borrow().iter().map(show).collect();
            format!("[{}]", parts.join(", "))
        }
        Value::Tuple(vals) => {
            let parts: Vec<String> = vals.iter().map(show).collect();
            format!("({})", parts.join(", "))
        }
        Value::Complex(re, im) => show_complex_pair(*re, *im),
        Value::Symbol(b) => format!(":{}", b.0),
        Value::ExprV(b) => {
            let parts: Vec<String> = b.1.iter().map(show).collect();
            format!(":({} {})", b.0, parts.join(" "))
        }
        Value::Struct(s) if s.kind == "ErrorException" => match s.fields.iter().find(|(n, _)| n == "msg") {
            Some((_, r)) => match &*r.borrow() {
                Value::Str(m) => m.clone(),
                v => show(v),
            },
            None => "ErrorException".to_string(),
        },
        Value::Struct(s) if EXCEPTION_KINDS.contains(&s.kind.as_str()) => {
            match s.fields.iter().find(|(n, _)| n == "msg") {
                Some((_, r)) => match &*r.borrow() {
                    Value::Str(m) => format!("{}: {}", s.kind, m),
                    v => format!("{}: {}", s.kind, show(v)),
                },
                None => s.kind.clone(),
            }
        }
        Value::Struct(s) => {
            let parts: Vec<String> = s.fields.iter().map(|(n, r)| format!("{}={}", n, show(&r.borrow()))).collect();
            format!("{}({})", s.kind, parts.join(", "))
        }
        Value::Closure(_) => "#<function>".to_string(),
    }
}

fn show_complex_pair(re: f64, im: f64) -> String {
    format!("{:.3} {} {:.3}im", re, if im < 0.0 { "-" } else { "+" }, im.abs())
}
