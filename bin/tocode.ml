(* ============================= Tocode ============================= *)
(* AST を Bytecode.program に畳む。ビルド時にだけ動く -- frontend の側に居る。

   畳めない形に出会ったら `Not_yet` で止まる。黙って別の道を通ったりしない:
   走らせる側に parser は無いのだから、あとで落ちるより、ここで言ったほうが
   いい。Compile.try_compile が「無理なら tree-walking に戻す」のと逆向きで、
   これは意図してそうしている(戻る先が無い)。

   いま畳めるのは fib が端から端まで通るだけの範囲 -- 数と文字列、変数、
   二項演算、呼び出し、代入、三項、if/while、return、注釈のない引数だけの
   関数。残りは順に足していく。 *)

open Ast
open Bytecode

exception Not_yet of string

(* --- 命令を積む箱。前に進むだけ、あとから飛び先だけ埋める --- *)
type codebuf = { mutable a : instr array; mutable n : int }

let newbuf () = { a = Array.make 32 Nothing; n = 0 }

let emit cb i =
  if cb.n = Array.length cb.a then begin
    let bigger = Array.make (2 * cb.n) Nothing in
    Array.blit cb.a 0 bigger 0 cb.n;
    cb.a <- bigger
  end;
  cb.a.(cb.n) <- i;
  cb.n <- cb.n + 1

(* 飛び先がまだ分からないときは、そこに印を置いて番地を覚えておき、
   分かったところで埋める *)
let hole cb =
  emit cb Nothing;
  cb.n - 1

let patch cb at i = cb.a.(at) <- i
let here cb = cb.n
let finish cb = Array.sub cb.a 0 cb.n

(* --- 棚。同じリテラルや同じ名前は一つにまとめる --- *)
type builder =
  { pool_tbl : (lit, int) Hashtbl.t
  ; mutable pool_rev : lit list
  ; mutable npool : int
  ; sym_tbl : (string, int) Hashtbl.t
  ; mutable syms_rev : string list
  ; mutable nsyms : int
  ; mutable funcs_rev : func list
  ; mutable nfuncs : int
  ; mutable structs_rev : strct list
  ; mutable nstructs : int
  ; mutable lambdas_rev : lambda list
  ; mutable nlambdas : int
  ; mutable comps_rev : comp list
  ; mutable ncomps : int
  ; mutable ireps_rev : instr array list
  ; mutable nireps : int
  }

let new_builder () =
  { pool_tbl = Hashtbl.create 64
  ; pool_rev = []
  ; npool = 0
  ; sym_tbl = Hashtbl.create 64
  ; syms_rev = []
  ; nsyms = 0
  ; funcs_rev = []
  ; nfuncs = 0
  ; structs_rev = []
  ; nstructs = 0
  ; lambdas_rev = []
  ; nlambdas = 0
  ; comps_rev = []
  ; ncomps = 0
  ; ireps_rev = []
  ; nireps = 0
  }

let lit_index b l =
  match Hashtbl.find_opt b.pool_tbl l with
  | Some i -> i
  | None ->
    let i = b.npool in
    Hashtbl.replace b.pool_tbl l i;
    b.pool_rev <- l :: b.pool_rev;
    b.npool <- i + 1;
    i

let sym_index b s =
  match Hashtbl.find_opt b.sym_tbl s with
  | Some i -> i
  | None ->
    let i = b.nsyms in
    Hashtbl.replace b.sym_tbl s i;
    b.syms_rev <- s :: b.syms_rev;
    b.nsyms <- i + 1;
    i

let add_irep b code =
  let i = b.nireps in
  b.ireps_rev <- code :: b.ireps_rev;
  b.nireps <- i + 1;
  i

let add_func b f =
  let i = b.nfuncs in
  b.funcs_rev <- f :: b.funcs_rev;
  b.nfuncs <- i + 1;
  i

let add_lambda b l =
  let i = b.nlambdas in
  b.lambdas_rev <- l :: b.lambdas_rev;
  b.nlambdas <- i + 1;
  i

let add_comp b c =
  let i = b.ncomps in
  b.comps_rev <- c :: b.comps_rev;
  b.ncomps <- i + 1;
  i

(* ループの変数。`for x in ...` と `for (k, v) in ...` *)
let fold_target b = function
  | FVSingle name -> { t_names = [| sym_index b name |]; t_tuple = false }
  | FVTuple names -> { t_names = Array.of_list (List.map (sym_index b) names); t_tuple = true }

let add_struct b st =
  let i = b.nstructs in
  b.structs_rev <- st :: b.structs_rev;
  b.nstructs <- i + 1;
  i

(* 型注釈の並び。注釈を書かなかったところは parser が ["Any"] にしているけれど、
   そうでない道から来たものもここで "Any" にそろえる。名前は生のまま棚に置く --
   module の中でどう読むかを決めるのは、走らせる側 *)
let types_index b (ts : string list) =
  let ts = match ts with [] -> [ "Any" ] | ts -> ts in
  Array.of_list (List.map (sym_index b) ts)

(* --- 式。どれも「値を一つ積んで終わる」 --- *)
let rec compile_expr b cb (e : expr) : unit =
  match e with
  | EInt n -> emit cb (Const (lit_index b (LInt n)))
  | EFloat f -> emit cb (Const (lit_index b (LFloat f)))
  | EStr s -> emit cb (Const (lit_index b (LStr s)))
  | EBool x -> emit cb (Const (lit_index b (LBool x)))
  | ENothing -> emit cb Nothing
  | EVar (name, vc) -> emit cb (Load (sym_index b name, vc))
  | EAssign (name, rhs, vc) ->
    compile_expr b cb rhs;
    emit cb (Store (sym_index b name, vc))
  (* `&&` と `||` は、右を見ないことがある -- eval もそうしている。呼び出しに
     畳むと両方を見てしまうので、飛び先でつなぐ。どちらの辺も Bool でなければ
     ならない、というところまで Jump_if_false が見てくれる *)
  | EBinOp ("&&", l, r, _) ->
    compile_expr b cb l;
    let f1 = hole cb in
    compile_expr b cb r;
    let f2 = hole cb in
    emit cb (Const (lit_index b (LBool true)));
    let to_end = hole cb in
    let lfalse = here cb in
    emit cb (Const (lit_index b (LBool false)));
    patch cb f1 (Jump_if_false lfalse);
    patch cb f2 (Jump_if_false lfalse);
    patch cb to_end (Jump (here cb))
  | EBinOp ("||", l, r, _) ->
    compile_expr b cb l;
    (* 左が偽のときだけ右を見る。真ならそのまま true へ *)
    let to_right = hole cb in
    let to_true = hole cb in
    patch cb to_right (Jump_if_false (here cb));
    compile_expr b cb r;
    let f2 = hole cb in
    patch cb to_true (Jump (here cb));
    emit cb (Const (lit_index b (LBool true)));
    let to_end = hole cb in
    patch cb f2 (Jump_if_false (here cb));
    emit cb (Const (lit_index b (LBool false)));
    patch cb to_end (Jump (here cb))
  | EBinOp (":", lo, hi, _) ->
    compile_expr b cb lo;
    compile_expr b cb hi;
    emit cb Range
  (* eval が特別に見ている演算子たち。呼び出しに畳むと意味が変わってしまう *)
  | EBinOp ("=>", l, r, _) ->
    compile_expr b cb l;
    compile_expr b cb r;
    emit cb Pair
  | EBinOp ((("===" | "!==") as op), l, r, _) ->
    compile_expr b cb l;
    compile_expr b cb r;
    emit cb (Identical (if op = "===" then 1 else 0))
  (* `T <: Number` -- どちらの辺も、変数としてではなく名前のまま見る
     (eval の同じ but-not-evaluated の扱い)。それ以外の形は下のふつうの道 *)
  | EBinOp ("<:", EVar (sub, _), EVar (sup, _), _) ->
    emit cb (Subtype (sym_index b sub, sym_index b sup))
  | EBinOp ("in", item, coll, _) ->
    compile_expr b cb item;
    compile_expr b cb coll;
    emit cb In
  | EBinOp (op, l, r, cc) ->
    compile_expr b cb l;
    compile_expr b cb r;
    emit cb (Binop (sym_index b op, cc))
  (* println/print は eval でも可変長の特別扱い(実の Julia は引数のあいだに
     何も挟まない)。ここでも同じ形で畳む *)
  | ECall ("println", args, [], _) ->
    List.iter (compile_expr b cb) args;
    emit cb (Println (List.length args))
  | ECall ("print", args, [], _) ->
    List.iter (compile_expr b cb) args;
    emit cb (Print (List.length args))
  (* eval が特別に見ている呼び出し。可変長だったり、引数を値としてでなく
     名前として読んだりするので、dispatch には預けられないものたち *)
  | ECall ("typeof", [ x ], _, _) ->
    compile_expr b cb x;
    emit cb Typeof
  | ECall ("Dict", (_ :: _ as args), [], _) ->
    List.iter (compile_expr b cb) args;
    emit cb (Makedict (List.length args))
  | ECall ("isa", [ x; EVar (tname, _) ], _, _) ->
    compile_expr b cb x;
    emit cb (Isa (sym_index b tname))
  | ECall (name, args, ((_ :: _) as kwargs), cc) ->
    (* 位置引数のあとに、キーワードの値をその並び順で積む *)
    List.iter (compile_expr b cb) args;
    List.iter (fun (_, e) -> compile_expr b cb e) kwargs;
    emit cb
      (Call_kw
         ( sym_index b name
         , List.length args
         , Array.of_list (List.map (fun (k, _) -> sym_index b k) kwargs)
         , cc ))
  | ECall (name, args, [], cc) ->
    List.iter (compile_expr b cb) args;
    emit cb (Call (sym_index b name, List.length args, cc))
  | ETernary (c, t, f) ->
    compile_expr b cb c;
    let to_else = hole cb in
    compile_expr b cb t;
    let to_end = hole cb in
    patch cb to_else (Jump_if_false (here cb));
    compile_expr b cb f;
    patch cb to_end (Jump (here cb))
  (* まだ畳めない形。何が足りないのかを数えたいので、ひとつずつ名前で言う *)
  (* `obj.meth(...)` は field 読み + 呼び出しに分けない -- JS のメソッドが
     受け手を失わないように(eval も分けていない) *)
  | EApply (EField (o, meth), args) ->
    compile_expr b cb o;
    List.iter (compile_expr b cb) args;
    emit cb (Apply_method (sym_index b meth, List.length args))
  | EApply (callee, args) ->
    compile_expr b cb callee;
    List.iter (compile_expr b cb) args;
    emit cb (Apply (List.length args))
  | EField (o, f) ->
    compile_expr b cb o;
    emit cb (Getfield (sym_index b f))
  | EFieldAssign (o, f, rhs) ->
    (* eval は右辺を先に見る。そろえる *)
    compile_expr b cb rhs;
    compile_expr b cb o;
    emit cb (Setfield (sym_index b f))
  | EArrayLit es ->
    List.iter (compile_expr b cb) es;
    emit cb (Makearr (List.length es))
  | ELambda (params, body) ->
    (* 体は子 irep。名前で呼ばれるものではないので、funcs とは別の棚に置く *)
    let l = { l_params = Array.of_list (List.map (sym_index b) params); l_body = compile_body b body } in
    emit cb (Makeclosure (add_lambda b l))
  | EComprehension (_, clauses) when List.length clauses > 2 ->
    raise (Not_yet "a comprehension with more than two for-clauses")
  | EComprehension (body_e, clauses) ->
    List.iter (fun (_, iter_e) -> compile_expr b cb iter_e) clauses;
    let c =
      { cp_targets = Array.of_list (List.map (fun (t, _) -> fold_target b t) clauses)
      ; cp_body = compile_body b [ SExpr body_e ]
      }
    in
    emit cb (Comprehension (add_comp b c))
  (* 入れものを先に見てから添字を読む -- 添字の中の `end` が、その入れものの
     長さを知っている必要があるので(eval もそうしている) *)
  (* `name[...]` だけは、name が変数か型の名前かで意味が変わる。どちらかは
     走らせてみるまでわからないので、その分かれ道ごと命令にする *)
  | EIndex (EVar (name, vc), idx) ->
    let s = sym_index b name in
    emit cb (Load_index (s, vc));
    compile_expr b cb idx;
    emit cb (Index_or_typed s)
  | EIndex (o, idx) ->
    compile_expr b cb o;
    emit cb Set_end;
    compile_expr b cb idx;
    emit cb Index
  | EIndexAssign (o, idx, rhs) ->
    compile_expr b cb o;
    emit cb Set_end;
    compile_expr b cb idx;
    compile_expr b cb rhs;
    emit cb Index_set
  | ETuple es ->
    List.iter (compile_expr b cb) es;
    emit cb (Maketuple (List.length es))
  | ETypeExpr _ -> raise (Not_yet "a type used as a value")
  | EBegin -> emit cb (Const (lit_index b (LInt 1)))
  | EEnd -> emit cb Endmark
  | ERangeStep (lo, step, hi) ->
    compile_expr b cb lo;
    compile_expr b cb step;
    compile_expr b cb hi;
    emit cb Range3
  | EMatrixLit rows ->
    (* 行の長さが揃っていない書き方は、ここで止める。eval はそのまま作って
       しまうけれど、それは壊れた行列なので *)
    let widths = List.map List.length rows in
    (match widths with
     | [] -> raise (Not_yet "an empty matrix literal")
     | w :: rest ->
       if List.exists (fun x -> x <> w) rest then raise (Not_yet "a matrix literal with ragged rows");
       List.iter (fun row -> List.iter (compile_expr b cb) row) rows;
       emit cb (Makematrix (List.length rows, w)))
  | ETypedArrayNew (elem_ty, elements) ->
    List.iter (compile_expr b cb) elements;
    emit cb (Typedarr (sym_index b elem_ty, List.length elements))
  | ETypedArrayUndef (elem_ty, n) ->
    compile_expr b cb n;
    emit cb (Typedarr_undef (sym_index b elem_ty))
  | ETypedMatrixUndef (elem_ty, m, n) ->
    compile_expr b cb m;
    compile_expr b cb n;
    emit cb (Typedmat_undef (sym_index b elem_ty))
  | EQualifiedCall (_, _, _, _ :: _, _) -> raise (Not_yet "keyword arguments in a qualified call")
  | EQualifiedCall (modname, member, args, [], cc) ->
    List.iter (compile_expr b cb) args;
    emit cb (Qcall (sym_index b modname, sym_index b member, List.length args, cc))
  (* `:name` は、名前を Symbol として持つだけ -- AST をデータにする本当の
     quote(`:(...)` と `quote ... end`)とは、別のもの *)
  | EQuoteSymbol name -> emit cb (Symbol (sym_index b name))
  | EQuote _ | EQuoteBlock _ -> raise (Not_yet "a quote")
  | EInterp _ | EInterpAssign _ -> raise (Not_yet "an interpolation")
  | EMacroCall _ -> raise (Not_yet "a macro call")
  (* `begin ... end`、そして macro の展開が文の形だったときに包まれるもの。
     新しいスコープは作らない -- eval も exec_stmt_list をそのまま呼んでいる *)
  | EBlock stmts -> compile_stmts b cb stmts

(* --- 文。どれも「値を一つ積んで終わる」ことにしてある。
       eval の exec_stmt_list が最後の文の値を返すのと、そろえるため --- *)
and compile_stmt b cb (s : stmt) : unit =
  match s with
  | SExpr e -> compile_expr b cb e
  | SReturn (Some e) ->
    compile_expr b cb e;
    emit cb Ret
  | SReturn None ->
    emit cb Nothing;
    emit cb Ret
  | SIf (branches, else_body) ->
    (* if/elseif/else を、条件ごとの飛び先でつなぐ *)
    let ends = ref [] in
    let rec go = function
      | [] -> (
        match else_body with
        | Some body ->
          emit cb Enter;
          compile_stmts b cb body;
          emit cb Leave
        | None -> emit cb Nothing)
      | (cond, body) :: rest ->
        compile_expr b cb cond;
        let to_next = hole cb in
        emit cb Enter;
        compile_stmts b cb body;
        emit cb Leave;
        ends := hole cb :: !ends;
        patch cb to_next (Jump_if_false (here cb));
        go rest
    in
    go branches;
    let fin = here cb in
    List.iter (fun at -> patch cb at (Jump fin)) !ends
  | SWhile (cond, body) ->
    let top = here cb in
    compile_expr b cb cond;
    let out = hole cb in
    emit cb Enter;
    compile_stmts b cb body;
    emit cb Leave;
    emit cb Pop;
    emit cb (Jump top);
    patch cb out (Jump_if_false (here cb));
    emit cb Nothing
  | SFuncDecl (name, params, kwparams, body, fc) ->
    let ps = List.map (fold_param b) params in
    let kws = List.map (fold_kwparam b) kwparams in
    let body_irep = compile_body b body in
    let f =
      { f_name = sym_index b name
      ; f_params = Array.of_list ps
      ; f_kwparams = Array.of_list kws
      ; f_body = body_irep
      ; f_cache = fc
      }
    in
    emit cb (Defun (add_func b f));
    emit cb Nothing
  | SStructDecl { mutable_; name; parent; type_params; fields; constructors; kwdefaults } ->
    fold_struct b cb ~mutable_ ~name ~parent ~type_params ~fields ~constructors ~kwdefaults
      ~kwdef:false
  | SAbstractDecl (name, parent) ->
    emit cb (Defabstract (sym_index b name, sym_index b (Option.value parent ~default:"Any")));
    emit cb Nothing
  | SLine n -> emit cb (Line n)
  | SFor (target, iter_e, body) ->
    (* 反復を作って、次があるあいだ体を回す。体は同じ命令列の中に居る --
       そこから `return` で関数ごと抜けられるように(子 irep にすると、
       抜ける先が変わってしまう)。ループの変数は、eval と同じく毎回の
       スコープに新しく置く(親の同名を書きかえない)ので Bind *)
    compile_expr b cb iter_e;
    emit cb Iter_new;
    let top = here cb in
    let out = hole cb in
    emit cb Enter;
    (match fold_target b target with
     | { t_names = [| n |]; t_tuple = false } -> emit cb (Bind n)
     | t -> emit cb (Bind_tuple t.t_names));
    compile_stmts b cb body;
    emit cb Pop;
    emit cb Leave;
    emit cb (Jump top);
    patch cb out (Iter_next (here cb));
    emit cb Nothing
  | STry (body, catchvar, catch_body) ->
    (* 受け止める場所を先に言っておいて、体を走らせる。無事に済んだら
       受け止めをやめて、catch を飛び越す *)
    let to_catch = hole cb in
    emit cb Enter;
    compile_stmts b cb body;
    emit cb Leave;
    emit cb Try_end;
    let to_end = hole cb in
    patch cb to_catch (Try (here cb));
    (* ここに来たときは、投げられた値が積まれている *)
    emit cb Enter;
    (match catchvar with Some n -> emit cb (Bind (sym_index b n)) | None -> emit cb Pop);
    compile_stmts b cb catch_body;
    emit cb Leave;
    patch cb to_end (Jump (here cb))
  | SDestructure (targets, rhs) ->
    (* 右辺のタプルは、代入のあいだ覚えておいて Elem で取り出す。式としての
       値もそれ自身なので、スタックには置いたままにする *)
    compile_expr b cb rhs;
    emit cb (Unpack_check (List.length targets));
    List.iteri
      (fun i (t, ty) ->
        let typecheck n =
          match ty with
          | Some ty -> emit cb (Typecheck (sym_index b n, types_index b ty))
          | None -> ()
        in
        match t with
        | EVar (n, vc) ->
          emit cb (Elem i);
          typecheck n;
          emit cb (Store (sym_index b n, vc));
          emit cb Pop
        | EField (o, f) ->
          emit cb (Elem i);
          compile_expr b cb o;
          emit cb (Setfield (sym_index b f));
          emit cb Pop
        | EIndex (o, idx) ->
          compile_expr b cb o;
          emit cb Set_end;
          compile_expr b cb idx;
          emit cb (Elem i);
          emit cb Index_set;
          emit cb Pop
        | _ -> raise (Not_yet "this shape as a destructuring target"))
      targets;
    emit cb Unpack_end
  | SLocalTypedAssign (name, ty, rhs) ->
    compile_expr b cb rhs;
    emit cb (Typecheck (sym_index b name, types_index b ty));
    emit cb (Store_plain (sym_index b name))
  | SModuleDecl (name, body) ->
    (* 体は同じ命令列の中。module の中の代入は名前空間に入らない、というのは
       eval と同じ(体を別のスコープでは走らせない) *)
    emit cb (Module_enter (sym_index b name));
    compile_stmts b cb body;
    emit cb Pop;
    emit cb Module_leave;
    emit cb Nothing
  | SUsing name ->
    emit cb (Using (sym_index b name));
    emit cb Nothing
  | SImport (name, members) ->
    emit cb (Import (sym_index b name, Array.of_list (List.map (sym_index b) members)));
    emit cb Nothing
  | SMacroDecl _ -> raise (Not_yet "a macro declaration")
  | SExport _ -> raise (Not_yet "export")
  | SMacroCall ("kwdef", SStructDecl { mutable_; name; parent; type_params; fields; constructors; kwdefaults })
    ->
    fold_struct b cb ~mutable_ ~name ~parent ~type_params ~fields ~constructors ~kwdefaults
      ~kwdef:true
  | SMacroCall (name, inner) when Hints.is_inert_hint_macro name ->
    (* @inline や @inbounds -- 本物の Julia では codegen の指示で、ここでは
       何も変えない(eval も、包まれている文をそのまま走らせている) *)
    compile_stmt b cb inner
  | SMacroCall _ -> raise (Not_yet "a macro call on a statement")


(* 引数ひとつ。分解と `::Type{...}` はまだ畳まない。既定値は、キーワード
   引数と同じく、式ひとつだけの子 irep *)
and fold_param b (p : Ast.param) : Bytecode.param =
  if p.pdestructure <> None then raise (Not_yet "a destructuring parameter");
  if p.ptypepattern <> None then raise (Not_yet "a ::Type{...} parameter");
  { p_name = sym_index b p.pname
  ; p_types = types_index b p.ptype
  ; p_default = (match p.pdefault with None -> 0 | Some e -> 1 + compile_body b [ SExpr e ])
  }

(* キーワード引数ひとつ。既定値は、式ひとつだけの子 irep にする -- 呼ばれる
   たびに、その呼び出しのスコープで走る *)
and fold_kwparam b (name, ty, default_e) =
  { k_name = sym_index b name
  ; k_types = types_index b ty
  ; k_default = compile_body b [ SExpr default_e ]
  }

(* struct ひとつ。@kwdef が付いていたかどうかで、既定値を持つかが変わる *)
and fold_struct b cb ~mutable_ ~name ~parent ~type_params ~fields ~constructors ~kwdefaults
    ~kwdef =
    let st =
      { st_mutable = mutable_
      ; st_name = sym_index b name
      ; st_parent = sym_index b (Option.value parent ~default:"Any")
      ; st_typarams = Array.of_list (List.map (sym_index b) type_params)
      ; st_ctors =
          Array.of_list
            (List.map
               (fun (cparams, ckwparams, cbody) ->
                 { c_params = Array.of_list (List.map (fold_param b) cparams)
                 ; c_kwparams = Array.of_list (List.map (fold_kwparam b) ckwparams)
                 ; c_body = compile_body b cbody
                 })
               constructors)
      ; st_kwdefaults =
          (* 素の struct に書かれた `field = 既定値` は、eval と同じく
             ここには来ない -- @kwdef が付いていたときだけ *)
          (if kwdef then
             Array.of_list
               (List.map (fun (f, e) -> sym_index b f, compile_body b [ SExpr e ]) kwdefaults)
           else [||])
      ; st_fields =
          Array.of_list
            (List.map
               (fun (f : tfield) ->
                 { fd_name = sym_index b f.fname; fd_types = types_index b f.ftype })
               fields)
      }
    in
    emit cb (Defstruct (add_struct b st));
    emit cb Nothing

(* 文の並び。最後の値だけ残して、途中のは捨てる。

   位置の目印(SLine)は値を積まないので、「最後の文」を数えるときにも
   数に入れない -- 目印は必ず文の前に来るので、並びの最後が目印になることは
   ないけれど、途中に挟まる分は Pop してはいけない *)
and compile_stmts b cb (stmts : stmt list) : unit =
  let is_line = function SLine _ -> true | _ -> false in
  let remaining = ref (List.length (List.filter (fun s -> not (is_line s)) stmts)) in
  if !remaining = 0 then (
    List.iter (compile_stmt b cb) stmts;
    emit cb Nothing)
  else
    List.iter
      (fun s ->
        compile_stmt b cb s;
        if not (is_line s) then begin
          decr remaining;
          if !remaining > 0 then emit cb Pop
        end)
      stmts

and compile_body b stmts =
  let cb = newbuf () in
  compile_stmts b cb stmts;
  emit cb Ret;
  add_irep b (finish cb)

(* 何枚かのファイルを、一つの program に畳む。drop の ops はこの形 --
   std.tsubaki から順に、読まれるはずの順で渡す。番号(cache のセルを指す)は
   ファイルをまたいで一つずつ配られるので、まとめて畳むほうが正しい。

   ファイルの変わり目に印(File)を置く。転んだときに、どのファイルの何行目か
   を言えるように *)
let compile_files (files : (string * stmt list) list) : program =
  let b = new_builder () in
  let cb = newbuf () in
  let n = ref (List.length files) in
  List.iter
    (fun (name, stmts) ->
      emit cb (File (sym_index b name));
      compile_stmts b cb stmts;
      decr n;
      if !n > 0 then emit cb Pop)
    files;
  if files = [] then emit cb Nothing;
  emit cb Ret;
  let main = add_irep b (finish cb) in
  { pool = Array.of_list (List.rev b.pool_rev)
  ; syms = Array.of_list (List.rev b.syms_rev)
  ; funcs = Array.of_list (List.rev b.funcs_rev)
  ; structs = Array.of_list (List.rev b.structs_rev)
  ; lambdas = Array.of_list (List.rev b.lambdas_rev)
  ; comps = Array.of_list (List.rev b.comps_rev)
  ; ireps = Array.of_list (List.rev b.ireps_rev)
  ; main
  }

let compile_program (stmts : stmt list) : program =
  let b = new_builder () in
  let main = compile_body b stmts in
  { pool = Array.of_list (List.rev b.pool_rev)
  ; syms = Array.of_list (List.rev b.syms_rev)
  ; funcs = Array.of_list (List.rev b.funcs_rev)
  ; structs = Array.of_list (List.rev b.structs_rev)
  ; lambdas = Array.of_list (List.rev b.lambdas_rev)
  ; comps = Array.of_list (List.rev b.comps_rev)
  ; ireps = Array.of_list (List.rev b.ireps_rev)
  ; main
  }
