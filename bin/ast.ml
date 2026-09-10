(* ============================= AST ============================= *)
  (* パースが失敗したという報せ。raise するのは Parser だけれど、受け止める
     のは Parser を持たない build もある(actorBridge の tsubakiEval)。それで
     ここに置いてある -- 「AST を組めなかった」は AST の側の話なので。 *)
  exception Parse_error of string

  type expr =
    | EInt of int
    | EFloat of float
    | EStr of string
    | EBool of bool
    | ENothing
    | EVar of string * int (* var_cache の番号 -- 表は Runtime 側 *)
    | EBinOp of string * expr * expr * int
      (* 末尾は call_cache の番号。セルそのものは Runtime.Dispatch の表に
         あって、この番号がその一つを指す -- 番号は parse 時に一度配られ、
         この呼び出し場所が評価されるたび同じセルに行き着く。ノードが
         セルを抱えていた頃と同じ意味で、抱えていないだけ(そのおかげで
         AST は Runtime を知らないただのデータでいられる)。 *)
    | ECall of string * expr list * (string * expr) list * int
      (* positional args, keyword args, and (like EBinOp) the number of the
         cache cell owned by this one call site *)
    | ESplat of expr
      (* `xs...` -- 呼び出しの引数のところだけに立つ。ここにあるものを
         ばらして、その数だけの引数にする。値ではないので、ほかの場所には
         現れない(パーサも、そこでしか作らない) *)
    | EApply of expr * expr list
      (* calling the RESULT of an expression rather than a name: `f()()`,
         `v[1](x)`, `(x -> x + 1)(3)`. `ECall` above NAMES its callee, which
         is what the overwhelmingly common `f(x)` is and what dispatch needs
         to resolve on; this is the other shape, where the thing being called
         has to be evaluated first and can only be a closure value.

         Only ever produced by parse_postfix, and only for a "(" that is
         tight against what precedes it and that the qualified-call path
         didn't already take (`Name.member(args)` is still EQualifiedCall) --
         so nothing that parsed before parses any differently now. *)
    | EField of expr * string
    | EAssign of string * expr * int
    | EFieldAssign of expr * string * expr
    | EArrayLit of expr list
    | ELambda of string list * stmt list
      (* `x -> expr` wraps expr as [SExpr expr]; `function (args) ... end`
         supplies a real multi-statement body directly *)
    | EComprehension of expr * (for_target * expr) list * expr option
      (* the last part is `[x for x in xs if cond]` -- Julia's own filter.
         Only ever on a single-clause comprehension here: with two `for`
         clauses the result is a 2-D shape, and a filter would flatten it,
         which is a different thing and not one anything asks for yet. *)
      (* one clause per `for` -- [x*x for x in r] has one, mandel's
         [f(r,i) for i = ..., r = ...] has two (see Eval for what each count
         does). Each clause's own loop variable can tuple-destructure too,
         `[v for (k, v) in d]` (found in Primes.jl), the same for_target a
         plain `for` statement's own header already uses. *)
    | EIndex of expr * expr
    | EIndexAssign of expr * expr * expr
    | ETuple of expr list
    | ETypeExpr of string
      (* a bare type name/parametric instantiation used as a plain VALUE,
         not a call -- `Vector`, `Deque{Int}` -- evaluates to a first-class
         `VType`. Only ever produced when a `Name{Params}` parse (see
         parser.ml's `TIDENT name` case) isn't immediately followed by `(`;
         `Name` alone (no braces) stays a plain `EVar`, resolved to a
         `VType` at eval time only if it isn't a bound variable (see
         Eval.eval_expr's EVar case) -- so an ordinary variable named the
         same as a type still shadows it, same as everywhere else in this
         interpreter. *)
    | ELet of (string * expr) list * stmt list
      (* `let x = 1, y = 2 ... end` -- 新しいスコープを開く一つだけの形
         (`begin` は開かない)。束ねる値は**外**で作ってから中に置くので、
         `let x = x` が外の x を捕まえられる。値は最後の文のもの *)
    | EBegin (* only meaningful inside a `[...]` index expression: firstindex *)
    | EEnd (* only meaningful inside a `[...]` index expression *)
    | ETernary of expr * expr * expr
    | ERangeStep of expr * expr * expr (* start:step:stop *)
    | EMatrixLit of expr list list (* rows *)
    | ETypedArrayNew of string * expr list
      (* Array{T}() (elements always []) or real Julia's `T[]`/`T[1,2,3]`
         shorthand (elements from the bracket contents) -- a DECLARED,
         enforced element type T, kept even while empty (unlike an ordinary
         literal/comprehension Array, whose element type is only ever
         inferred from current contents -- see Runtime.tag's VArr case).
         `T[1,2,3]` itself is never actually built by the parser as this
         node directly -- it parses as ordinary `EIndex(EVar T, ...)`
         (indistinguishable from indexing at parse time) and is reinterpreted
         into this shape at eval time, only once looking `T` up as a
         variable has already failed (see Eval's EIndex case). *)
    | ETypedArrayUndef of string * expr
      (* Vector{T}(undef, n) / Array{T}(undef, n) -- real Julia's
         uninitialized-allocation constructor. `n` is evaluated once to get
         the size; every cell starts as VNothing, the same loose stand-in
         for a genuinely uninitialized slot that `new(...)`'s
         partial-construction path already uses (see Runtime.construct) --
         reading a cell before it's ever written just sees VNothing instead
         of erroring. *)
    | ETypedMatrixUndef of string * expr * expr
      (* Matrix{T}(undef, m, n) -- the 2-D counterpart of ETypedArrayUndef
         above, building the generic boxed `Matrix{T}` container (see
         Runtime.VGenMat) rather than the numeric `VMat`. Every cell starts
         as VNothing, same convention as ETypedArrayUndef. *)
    | EQualifiedCall of string * string * expr list * (string * expr) list * int
      (* Name.member(args) -- a struct constructor or dispatch call qualified
         by module name. Single-level only (not Outer.Inner.member): a
         narrower, purpose-built node rather than generalizing ECall's
         callee to an arbitrary expression, since a bare bracket like this
         is otherwise indistinguishable at parse time from ordinary chained
         struct field access (`a.b.c`) until the trailing "(" is seen. *)
    | EQuote of expr (* :( expr ) -- quotes a single expression as data *)
    | EQuoteSymbol of string (* :name -- quotes a bare identifier as a Symbol *)
    | EQuoteBlock of stmt list (* quote ... end -- quotes a statement list as data *)
    | EInterp of expr
      (* $(expr) or $name -- ONLY meaningful while converting a surrounding
         quote to a value (Eval.expr_to_value): splices this expr's ALREADY-
         EVALUATED value in, instead of quoting it as syntax. Evaluated as a
         harmless passthrough (`eval_expr env inner`) anywhere else. *)
    | EInterpAssign of expr * expr
      (* $(target) = rhs -- an assignment whose TARGET name isn't known
         until quote-conversion time (e.g. `$(esc(x)) = 0` inside a macro's
         quote, where `esc(x)` evaluates to a Symbol naming the caller's own
         variable). Only meaningful there too; `target` is the interpolated
         expr (unwrapped, not itself wrapped in EInterp). *)
    | EMacroCall of string * expr list
      (* @name(args) or @name arg -- args are passed to the macro UNEVALUATED,
         reified as quoted syntax (exactly what a real :(...) quote would
         produce); the macro's return value is converted back to real AST
         and spliced in at the call site, hygienically renamed -- see
         Eval.expr_to_value/value_to_expr and the macro/hygiene comments
         there for the whole mechanism. *)
    | EBlock of stmt list
      (* wraps a stmt list as a single expr -- used only to splice a macro
         expansion that's shaped like a block/control-flow statement (not a
         bare expression) into expression position; evaluates by just
         running the statements and returning the last one's value, same as
         any other stmt list. *)

  (* a for-loop's own header binding: a plain variable (`for x in ...`) or
     real Julia's tuple-unpacking form (`for (s, d) in ...`) -- plain names
     only (not full lvalues the way SDestructure's targets can be), matching
     how this shorthand is actually used in practice *)
  and for_target =
    | FVSingle of string
    | FVTuple of string list

  (* ptype: list of alternative type names -- ["Any"] if untyped, a singleton for
     a plain `x::T` annotation, or several for `x::Union{A,B,C}`.
     pdefault: a positional parameter's own default value (`f(a, b=1)`) --
     only ever set on a suffix of a param list, same rule real Julia enforces
     (not checked here; a caller just won't supply enough args for an
     earlier one, and binding below fails as a plain arity mismatch).
     pdestructure: `Some [...]` for a tuple-pattern parameter
     (`(cb, i) = default`, found in DataStructures.jl's `deque.jl`) -- the
     names actually bound come from here, not `pname` (kept only as an
     unused display label, e.g. "(cb, i)", in that case). *)
  and param =
    { pname : string
    ; ptype : string list
    ; pdefault : expr option
    ; pdestructure : string list option
    ; pslurp : bool
      (* `f(a, xs...)` -- 最後の一つだけが持てる。呼ばれたときに余ったものを
         ぜんぶ集めて、タプルとして束ねる(Julia もタプル)。集めるので、
         `pdefault` とは一緒に立たない *)
    ; ptypepattern : type_pattern option
      (* `Some _` for an UNNAMED `::Type{...}` dispatch parameter (real
         Julia's trait-dispatch-on-the-type-itself idiom, e.g.
         `Base.eltype(::Type{Deque{T}}) where T = T`,
         `factor(::Type{A}, n) where {A<:AbstractArray} = ...`) -- `pname`
         is unused (empty) in this case; see type_pattern below for what
         each shape means and Eval.bind_one_param for how it binds. *)
    }

  and type_pattern =
    | TPMatch of string
      (* `Type{Name}` or `Type{<:Name}` -- Name is either a real registered
         type or a where-bound variable with its OWN `where Name<:Bound`
         (substituted for Bound at registration time, see
         finalize_type_patterns) -- a plain subtype-of-Name check, no
         binding; the actual VType argument is matched and dropped. *)
    | TPWhole of string * string
      (* `Type{A}`, A an otherwise-unconstrained where-bound variable
         (`factor(::Type{A}, ...) where A = ...`) -- matches any VType at
         all (2nd field is the substituted bound, "Any" if A itself has no
         `where A<:Bound`); binds the WHOLE actual wrapped name to A (1st
         field) inside the method body. *)
    | TPNested of string * string
      (* `Type{Outer{Var}}`, Var a where-bound variable
         (`Base.eltype(::Type{Deque{T}}) where T = T`) -- Outer (1st field)
         must match (subtype-wise); Var (2nd field) binds to the INNER part
         of the actual VType's wrapped name. Var is always treated as
         unconstrained here -- a concrete inner type written directly
         (`Type{Deque{Int}}`) isn't disclosed as needed and would just bind
         an unused local named after it, not silently wrong, just unused. *)

  and tfield = { fname : string; ftype : string list }

  (* expr and stmt are mutually recursive now: ELambda above carries a real
     stmt list body. *)
  and stmt =
    | SLine of int
      (* Not a statement anyone writes -- a source-position marker the parser
         puts in front of every statement it produces (see
         Parser.parse_stmt_list), so the evaluator knows which LINE it is
         currently on and a runtime error can say where it happened. Before
         this, `MethodError`/`UndefVarError` named the function that failed
         and nothing else: the AST carried no position at all.

         A marker rather than a position field on every variant, on purpose:
         a field would have meant touching all ~180 places statements are
         built and matched across parser/eval/resolve/compile, and quietly
         changing the shape `compile.ml` matches against (which decides
         bytecode eligibility by exact statement shape -- a mismatch there
         doesn't fail, it silently stops compiling). Markers are stripped
         back out at Compile's own entry points instead (Compile.strip_lines),
         so that file sees the exact same statement lists it always did.

         Evaluating one sets the current line and yields nothing, so a block's
         "last expression is the value" rule is unaffected -- a marker always
         comes BEFORE its statement, never last. *)
    | SExpr of expr
    | SIf of (expr * stmt list) list * stmt list option
    | SFor of for_target * expr * stmt list
    | SWhile of expr * stmt list
    | SFuncDecl of string * param list * (string * string list * expr) list * stmt list * int
      (* name, positional params, keyword params (name, declared type --
         `["Any"]` if untyped, same convention as a param's own `ptype` --
         and a default-value expr), body, and a JIT-style bytecode-compile
         cache の番号。宣言の場所ひとつにセルひとつ、というのは前と同じ
         (表は Runtime.funcdecl_cache_table) *)
    | SStructDecl of
        { mutable_ : bool
        ; name : string
        ; parent : string option
        ; type_params : string list (* e.g. ["T"] for Box{T}, ["K";"V"] for Dict{K,V} *)
        ; fields : tfield list
        ; constructors : (param list * (string * string list * expr) list * stmt list) list
          (* real Julia's "inner constructors" -- `function StructName(...)
             ... end` defined INSIDE the struct body (any `{T}` after the
             name and `where T` clause are parsed and thrown away; Tsubaki
             infers the parametric type the same automatic way it already
             does for the default constructor, see Runtime.construct). Each
             one replaces/supplements the auto-generated default
             constructor -- see Eval.SStructDecl and the `new`/`new{T}`
             special form used inside their bodies. *)
        ; kwdefaults : (string * expr) list
          (* field -> default-value expr, for the fields a `field = expr`
             clause gave a default (empty for a struct with none). Under
             `@kwdef` these power the keyword constructor `T(; field=val, ...)`,
             filling any omitted field from its default -- see Eval.SStructDecl
             and the ECall keyword-construct path. *)
        }
    | SAbstractDecl of string * string option
    | SReturn of expr option
    | SBreak
      (* leave the innermost `for`/`while` -- only meaningful inside one, and
         the folding side (Tocode) is where that is checked: it is the one
         that knows which loop is innermost, because it is the one building
         the jump. *)
    | SContinue (* go on to that loop's next turn *)
    | STry of stmt list * string option * stmt list
    | SDestructure of (expr * string list option) list * expr
      (* x, y = rhs -- targets are full lvalue exprs (EVar/EField/EIndex), not
         just bare names, so a[i], a[j] = a[j], a[i] (an in-place swap) works.
         The `string list option` is an optional `::T` annotation on a target
         (only ever `Some` for a plain `EVar` target -- `x::T, y = state`,
         real Julia's per-target typed destructure, found in Primes.jl's
         `n, p::T = state`); enforced the same on-this-assignment-only way
         `SLocalTypedAssign` already enforces a single typed local. Quoting a
         typed destructure silently drops the annotation (unsupported edge
         case, not disclosed as needed) -- see Eval.stmt_to_value/vs. *)
    | SLocalTypedAssign of string * string list * expr
      (* x::T = expr -- a mid-function type-annotated local assignment.
         Enforces T on THIS assignment only (a TypeError on mismatch,
         matching a struct field's declared-type enforcement) -- does NOT
         track the annotation for any LATER plain reassignment of the same
         variable (a disclosed v1 scope cut; real Julia enforces it on
         every subsequent assignment too, which would need the type
         threaded through Resolve/Eval's scope state, not attempted here). *)
    | SModuleDecl of string * stmt list
      (* module Name ... end -- functions/structs/abstract types declared in
         the body register under "Name.thing" (see Eval); plain variable
         assignments in the body are NOT namespaced, on purpose (see README) *)
    | SUsing of string
      (* using Name -- merges everything Name declared into the bare/global
         namespace so unqualified names work from here on *)
    | SImport of string * string list
      (* import Name: a, b -- unlike `using` (merges EVERYTHING), only the
         named members become reachable bare; anything else Name declared
         stays reachable solely as Name.thing (see Runtime.import_module) *)
    | SMacroDecl of string * string list * stmt list
      (* macro name(args...) ... end -- a SEPARATE namespace from functions;
         args are always plain names (no type annotations -- real macros
         dispatch purely by argument COUNT, never by type, since they never
         see evaluated values, only quoted syntax) *)
    | SExport of string list
      (* export a, b, c -- a real Julia visibility hint, meaningless here
         since `using` already imports everything a module declared (see
         SUsing); parsed and thrown away rather than choking on it, so real
         package source (which starts with this almost universally) at
         least gets past the first line *)
    | SMacroCall of string * stmt
      (* @name <stmt> -- a macro call wrapping an entire STATEMENT (a real
         function/struct declaration, a for/while loop, an if), not just a
         trailing expression like EMacroCall handles. Real Julia code
         constantly annotates declarations this way (`@inline function
         f(x) ... end`, `@inbounds for i in ... end`) with compiler-hint
         macros that never change behavior, only codegen -- see Eval for
         the fixed set treated as pure identity, and how a real, non-hint
         macro handles this (only for statement shapes already quotable;
         see stmt_to_value). *)
