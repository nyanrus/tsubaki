(* ============================= Vm ============================= *)
(* Bytecode.program を走らせる。走らせる側 -- つまりブラウザに積まれるほう --
   に居るので、ここは parser を知らない。知っているのは命令の形と、Runtime の
   値と dispatch だけ。

   スタックマシンです。環境は eval と同じ scope の鎖をそのまま使う(Resolve が
   数えた「何段上か」がそのまま効くように、if/while の体でスコープを作る場所も
   eval と揃えてある -- Enter/Leave がそれ)。

   まだ eval の隣に立っているだけで、置き換えてはいない。畳める形が増えたら、
   こちらが本体になる。 *)

open Runtime
open Bytecode

let value_of_lit = function
  | LInt n -> VInt n
  | LFloat f -> VFloat f
  | LStr s -> VStr s
  | LBool b -> VBool b

(* try が置いていく目印。捕まえたときは、ここに書いてあるところまで全部
   戻してから、catch の番地に飛ぶ -- 例外は OCaml の側を突き抜けて飛ぶので、
   命令の道のほうを自分で巻き戻してやる必要がある *)
type handler =
  { h_pc : int
  ; h_sp : int
  ; h_env : Eval.env
  ; h_iters : Eval.iter list
  ; h_prefixes : string list
  ; h_site : site
  }

let rec exec (p : program) (code : instr array) env0 : value =
  let stack = Array.make 256 VNothing in
  let sp = ref 0 in
  let push v =
    if !sp >= Array.length stack then failwith "vm: stack overflow";
    stack.(!sp) <- v;
    incr sp
  in
  let pop () =
    decr sp;
    stack.(!sp)
  in
  (* 棚から名前を引く。型名は、走らせているいまの module から見て読む
     (Tocode は生のまま置いていく -- どう読むかを決めるのは、ここ) *)
  let sym i = p.syms.(i) in
  let type_names a = List.map (fun t -> resolve_type_name p.syms.(t)) (Array.to_list a) in
  (* 既定値を持つ引数がある分だけ、受けつける引数の数に幅がある
     -- eval の param_arity_range と同じ数えかた *)
  let arity_range (ps : param array) =
    let n = Array.length ps in
    let rec first k = if k >= n then n else if ps.(k).p_default > 0 then k else first (k + 1) in
    first 0, n
  in
  (* 引数を束ねる。届かなかった分は、それぞれの既定値から -- 同じスコープで
     走らせるので、あとの既定値が前の引数を見られる(`f(a, b=a+1)`)。
     キーワード引数は、呼んだ側が渡していなければ自分の既定値から *)
  let bind_args scope (ps : param array) pnames (kws : kwparam array) argv =
    List.iteri (fun k v -> Eval.bind scope pnames.(k) v) argv;
    for k = List.length argv to Array.length ps - 1 do
      Eval.bind scope pnames.(k) (exec p p.ireps.(ps.(k).p_default - 1) scope)
    done;
    Array.iter
      (fun kp ->
        Eval.bind_kw scope (sym kp.k_name) (type_names kp.k_types) (fun () ->
            exec p p.ireps.(kp.k_default) scope))
      kws
  in
  (* 反復のいま。for がネストした分だけ積む -- 値のスタックには置けない
     (value ではないので)、別に持つ *)
  let iters = ref [] in
  (* Load_index が置く印。true なら「型として読む」 *)
  let index_kinds = ref [] in
  (* 分解代入のあいだ、右辺のタプルを覚えておくところ *)
  let unpacked = ref [] in
  (* module の中に入ったとき、出たら戻す先 *)
  let outer_prefixes = ref [] in
  let env = ref env0 in
  let handlers : handler list ref = ref [] in
  let pc = ref 0 in
  let result = ref VNothing in
  let running = ref true in
  let step_all () =
    while !running do
      (match Array.unsafe_get code !pc with
     | Const i ->
       push (value_of_lit p.pool.(i));
       incr pc
     | Nothing ->
       push VNothing;
       incr pc
     | Pop ->
       ignore (pop ());
       incr pc
     | Load (s, vc) ->
       (* 木を歩く道と同じ三段 -- 変数、型の名前、関数の名前そのもの *)
       push (Eval.load_var !env (sym s) (var_cache_at vc));
       incr pc
     | Store (s, vc) ->
       (* 代入の値は、式としての答えでもあるので積んだまま残す *)
       Eval.assign_cached !env p.syms.(s) stack.(!sp - 1) (var_cache_at vc);
       incr pc
     | Binop (s, cc) ->
       let r = pop () in
       let l = pop () in
       push (Dispatch.call_cached (Dispatch.cache_at cc) p.syms.(s) [ l; r ]);
       incr pc
     | Call (s, nargs, cc) ->
       let args = ref [] in
       for _ = 1 to nargs do
         args := pop () :: !args
       done;
       (* 木を歩く道と同じところを通る -- closure が名前を覆っていたら
          それが勝つ、struct はそのまま建つ、module の中では中から読む *)
       push (Eval.call_named !env (Dispatch.cache_at cc) (sym s) !args []);
       incr pc
     | Call_kw (s, nargs, kwnames, cc) ->
       (* キーワードの値が上に、位置引数がその下に積まれている *)
       let nkw = Array.length kwnames in
       let kwargv = ref [] in
       for k = nkw - 1 downto 0 do
         kwargv := (sym kwnames.(k), pop ()) :: !kwargv
       done;
       let args = ref [] in
       for _ = 1 to nargs do
         args := pop () :: !args
       done;
       push (Eval.call_named !env (Dispatch.cache_at cc) (sym s) !args !kwargv);
       incr pc
     | Jump t -> pc := t
     | Jump_if_false t -> (
       match pop () with
       | VBool true -> incr pc
       | VBool false -> pc := t
       | _ -> failwith "a condition must be Bool")
     | Println n ->
       let args = ref [] in
       for _ = 1 to n do
         args := pop () :: !args
       done;
       print_endline (String.concat "" (List.map show !args));
       push VNothing;
       incr pc
     | Print n ->
       let args = ref [] in
       for _ = 1 to n do
         args := pop () :: !args
       done;
       print_string (String.concat "" (List.map show !args));
       push VNothing;
       incr pc
     | Enter ->
       env := Eval.new_scope !env;
       incr pc
     | Leave ->
       (match (!env).parent with
        | Some parent -> env := parent
        | None -> failwith "vm: Leave at the top scope");
       incr pc
     | File n ->
       current_file := sym n;
       incr pc
     | Line n ->
       current_line := n;
       incr pc
     | Defun i ->
       let f = p.funcs.(i) in
       let bare = sym f.f_name in
       let name = !current_module_prefix ^ bare in
       let body = p.ireps.(f.f_body) in
       let pnames = Array.map (fun pr -> sym pr.p_name) f.f_params in
       (* eval の param_sig_alt と同じもの -- 注釈を書かなかった引数は "Any"
          ひとつ、`x::Union{A,B}` は二つ。既定値も `::Type{...}` もまだ
          Tocode が畳まないので、ここには注釈だけが来る *)
       let sig_ = Array.to_list (Array.map (fun pr -> type_names pr.p_types) f.f_params) in
       (* 宣言された場所の環境と、module と、ファイルを捕まえる -- eval の
          SFuncDecl と同じ *)
       let def_env = !env in
       let def_prefix = !current_module_prefix in
       let def_file = !current_file in
       let n_required, n_total = arity_range f.f_params in
       let impl argv =
         let scope = Eval.new_scope def_env in
         bind_args scope f.f_params pnames f.f_kwparams argv;
         (* 呼んだ側の位置を覚えて、帰りに戻す。エラーが「どこで起きて、
            どこから呼ばれたか」を言えるのは、これがあるから(eval の
            tree_walk_impl と同じことを、同じ順でしている) *)
         let run_body () =
           let caller_line = !current_line and caller_file = !current_file in
           push_frame bare caller_line;
           if def_file != caller_file then current_file := def_file;
           let v = exec p body scope in
           pop_frame ();
           current_line := caller_line;
           if def_file != caller_file then current_file := caller_file;
           v
         in
         if def_prefix = "" then run_body ()
         else (
           let saved = !current_module_prefix in
           current_module_prefix := def_prefix;
           match run_body () with
           | v ->
             current_module_prefix := saved;
             v
           | exception e ->
             current_module_prefix := saved;
             raise e)
       in
       for k = n_required to n_total do
         Dispatch.defmethod name (Eval.take k sig_) impl
       done;
       (* 関数の中で宣言された function は、その呼び出しごとの closure として
          ローカルにも束ねる -- そうしないと、工場を二度呼んでも渡されるのは
          あとから登録されたほう一つになってしまう(eval の SFuncDecl に、
          なぜそうなるかが書いてあります)。キーワード引数を持つものは、
          closure の道が位置引数しか渡さないので、ここでは束ねない *)
       if inside_function_body () && Array.length f.f_kwparams = 0 then begin
         let local_impl argv =
           let k = List.length argv in
           if k >= n_required && k <= n_total
              && Dispatch.applicable { Dispatch.sig_ = Eval.take k sig_; impl } (List.map tag argv)
           then impl argv
           else Dispatch.call name argv
         in
         Eval.bind !env bare (VClosure (n_total, local_impl))
       end;
       push VNothing;
       incr pc
     (* n 個ぶん取って、並びにする。積んだ順がそのまま並びの順 *)
     | Makearr n ->
       let vs = Array.init n (fun k -> stack.(!sp - n + k)) in
       sp := !sp - n;
       push (Eval.make_array_lit vs);
       incr pc
     | Maketuple n ->
       let vs = Array.init n (fun k -> stack.(!sp - n + k)) in
       sp := !sp - n;
       push (VTuple vs);
       incr pc
     | Using s ->
       let name = sym s in
       Eval.ensure_module name;
       use_module name;
       push VNothing;
       incr pc
     | Import (s, members) ->
       let name = sym s in
       Eval.ensure_module name;
       import_module name (List.map sym (Array.to_list members));
       push VNothing;
       incr pc
     | Module_enter s ->
       outer_prefixes := !current_module_prefix :: !outer_prefixes;
       current_module_prefix := !current_module_prefix ^ sym s ^ ".";
       incr pc
     | Module_leave ->
       (match !outer_prefixes with
        | outer :: rest ->
          current_module_prefix := outer;
          outer_prefixes := rest
        | [] -> failwith "vm: Module_leave outside a module");
       incr pc
     | Makeclosure i ->
       let l = p.lambdas.(i) in
       let names = Array.map sym l.l_params in
       let body = p.ireps.(l.l_body) in
       (* 宣言された場所の環境と module を捕まえる -- eval の ELambda と同じ *)
       let def_env = !env in
       let def_prefix = !current_module_prefix in
       push
         (VClosure
            ( Array.length names
            , fun argv ->
                let call_env = Eval.new_scope def_env in
                List.iteri (fun k v -> Eval.bind call_env names.(k) v) argv;
                if def_prefix = "" then exec p body call_env
                else (
                  let saved = !current_module_prefix in
                  current_module_prefix := def_prefix;
                  match exec p body call_env with
                  | v ->
                    current_module_prefix := saved;
                    v
                  | exception e ->
                    current_module_prefix := saved;
                    raise e) ));
       incr pc
     | Makematrix (nrows, ncols) ->
       let n = nrows * ncols in
       let base = !sp - n in
       let rows =
         Array.init nrows (fun r -> Array.init ncols (fun c -> as_float stack.(base + (r * ncols) + c)))
       in
       sp := base;
       push (VMat rows);
       incr pc
     | Qcall (m, member, nargs, cc) ->
       let args = ref [] in
       for _ = 1 to nargs do
         args := pop () :: !args
       done;
       push (Eval.call_qualified !env (Dispatch.cache_at cc) (sym m) (sym member) !args []);
       incr pc
     | Apply nargs ->
       let args = ref [] in
       for _ = 1 to nargs do
         args := pop () :: !args
       done;
       let f = pop () in
       push (Eval.apply_value f !args);
       incr pc
     | Apply_method (meth, nargs) ->
       let args = ref [] in
       for _ = 1 to nargs do
         args := pop () :: !args
       done;
       let obj = pop () in
       push (Eval.apply_method obj (sym meth) !args);
       incr pc
     | Symbol s ->
       push (VSymbol (sym s, !current_hygiene_id));
       incr pc
     | Typeof ->
       let v = pop () in
       push (VStr (tag v));
       incr pc
     | Makedict n ->
       let vs = ref [] in
       for _ = 1 to n do
         vs := pop () :: !vs
       done;
       push (Eval.make_dict !vs);
       incr pc
     | Isa t ->
       let v = pop () in
       push (Eval.isa_named !env v (sym t));
       incr pc
     | Typedarr (t, n) ->
       let name = sym t in
       (* `score[]` -- 束縛された変数のほうが、型の名前より強い(eval と同じ) *)
       if n = 0 && Eval.lookup_opt !env name <> None then
         push
           (Dispatch.call_cached (Dispatch.new_cache ()) "getindex"
              [ Option.get (Eval.lookup_opt !env name) ])
       else begin
         let vs = Array.init n (fun k -> stack.(!sp - n + k)) in
         sp := !sp - n;
         push (Eval.typed_array_new name vs)
       end;
       incr pc
     | Typedarr_undef t ->
       let n = pop () in
       push (Eval.typed_array_undef (sym t) n);
       incr pc
     | Typedmat_undef t ->
       let n = pop () in
       let m = pop () in
       push (Eval.typed_matrix_undef (sym t) m n);
       incr pc
     | Load_index (s, vc) ->
       let name = sym s in
       (match Eval.lookup_cached !env name (var_cache_at vc) with
        | c ->
          index_kinds := false :: !index_kinds;
          Eval.set_end_from c;
          push c
        | exception Failure msg ->
          if Eval.is_recognized_elem_type name then begin
            index_kinds := true :: !index_kinds;
            push VNothing
          end
          else failwith msg);
       incr pc
     | Index_or_typed t ->
       let idx = pop () in
       let c = pop () in
       (match !index_kinds with
        | as_type :: rest ->
          index_kinds := rest;
          if as_type then
            push
              (Eval.typed_array_new (sym t)
                 (match idx with VTuple vs -> vs | v -> [| v |]))
          else push (Eval.index_get c idx)
        | [] -> failwith "vm: Index_or_typed with no mark");
       incr pc
     | Set_end ->
       Eval.set_end_from stack.(!sp - 1);
       incr pc
     | Endmark ->
       push (VInt !current_end);
       incr pc
     | Index ->
       let i = pop () in
       let c = pop () in
       push (Eval.index_get c i);
       incr pc
     | Index_set ->
       let v = pop () in
       let i = pop () in
       let c = pop () in
       (* 右辺はもう積まれている。eval は書ける場所だと分かってから右辺を見る
          ので、そこだけ順が違う -- Eval.index_set のところに書いてあります *)
       push (Eval.index_set c i (fun () -> v));
       incr pc
     | Pair ->
       let b = pop () in
       let a = pop () in
       push (VPair (a, b));
       incr pc
     | Identical want ->
       let r = pop () in
       let l = pop () in
       push (VBool (is_identical l r = (want = 1)));
       incr pc
     | Subtype (sub, sup) ->
       push (VBool (Types.distance_to (sym sub) (sym sup) <> None));
       incr pc
     | In ->
       let coll = pop () in
       let item = pop () in
       push (VBool (Eval.value_in item coll));
       incr pc
     | Bind s ->
       Eval.bind !env (sym s) (pop ());
       incr pc
     | Store_plain s ->
       Eval.assign !env (sym s) stack.(!sp - 1);
       incr pc
     | Unpack_check n ->
       (match stack.(!sp - 1) with
        | VTuple vs when Array.length vs = n -> unpacked := vs :: !unpacked
        | VTuple vs ->
          failwith
            (Printf.sprintf "cannot destructure a %d-tuple into %d targets" (Array.length vs) n)
        | v -> failwith (Printf.sprintf "cannot destructure a %s into %d targets" (tag v) n));
       incr pc
     | Elem i ->
       (match !unpacked with
        | vs :: _ -> push vs.(i)
        | [] -> failwith "vm: Elem with nothing unpacked");
       incr pc
     | Unpack_end ->
       (match !unpacked with
        | _ :: rest -> unpacked := rest
        | [] -> failwith "vm: Unpack_end with nothing unpacked");
       incr pc
     | Typecheck (n, ts) ->
       let v = stack.(!sp - 1) in
       let ty = List.map sym (Array.to_list ts) in
       if not (Dispatch.matches_alt (tag v) ty) then
         failwith
           (Printf.sprintf "TypeError: %s::%s cannot hold a %s" (sym n) (String.concat "|" ty) (tag v));
       incr pc
     | Bind_tuple ns ->
       Eval.bind_names !env (List.map sym (Array.to_list ns)) ~tuple:true (pop ());
       incr pc
     | Comprehension i ->
       let c = p.comps.(i) in
       let body = p.ireps.(c.cp_body) in
       let outer = !env in
       let bind_target scope (t : target) v =
         Eval.bind_names scope (List.map sym (Array.to_list t.t_names)) ~tuple:t.t_tuple v
       in
       (match c.cp_targets with
        | [| t |] ->
          let src = pop () in
          let results =
            List.map
              (fun v ->
                let scope = Eval.new_scope outer in
                bind_target scope t v;
                exec p body scope)
              (Eval.iter_values src)
          in
          push (Eval.make_array_lit (Array.of_list results))
        | [| t1; t2 |] ->
          (* 二つの for 節 -- 外が行、内が列(eval と同じ向き) *)
          let src2 = pop () in
          let src1 = pop () in
          let vs2 = Eval.iter_values src2 in
          let raw_rows =
            List.map
              (fun v1 ->
                Array.of_list
                  (List.map
                     (fun v2 ->
                       let scope = Eval.new_scope outer in
                       bind_target scope t1 v1;
                       bind_target scope t2 v2;
                       exec p body scope)
                     vs2))
              (Eval.iter_values src1)
          in
          push (Eval.make_matrix_lit raw_rows)
        | _ -> failwith "vm: a comprehension wants one or two for-clauses");
       incr pc
     | Range ->
       let hi = pop () in
       let lo = pop () in
       push (Eval.make_range lo hi);
       incr pc
     | Range3 ->
       let hi = pop () in
       let step = pop () in
       let lo = pop () in
       push (Eval.make_range_step lo step hi);
       incr pc
     | Iter_new ->
       iters := Eval.iter_start (pop ()) :: !iters;
       incr pc
     | Iter_next out -> (
       match !iters with
       | [] -> failwith "vm: Iter_next with no iterator"
       | it :: rest -> (
         match Eval.iter_next it with
         | Some v ->
           push v;
           incr pc
         | None ->
           iters := rest;
           pc := out))
     | Getfield f ->
       let o = pop () in
       push (get_field o (sym f));
       incr pc
     | Setfield f ->
       (* 値・入れもの の順に積んである。入れものだけ取って、値は式の答えとして
          残す(eval の EFieldAssign と同じ) *)
       let o = pop () in
       set_field o (sym f) stack.(!sp - 1);
       incr pc
     | Defstruct i ->
       let st = p.structs.(i) in
       let fields = Array.to_list st.st_fields in
       let full_name = !current_module_prefix ^ sym st.st_name in
       declare_struct ~mutable_:st.st_mutable full_name
         ~parent:(resolve_type_name (sym st.st_parent))
         ~type_params:(List.map sym (Array.to_list st.st_typarams))
         (List.map (fun fd -> sym fd.fd_name) fields)
         (List.map (fun fd -> type_names fd.fd_types) fields);
       (* 中に書かれた constructor は、自動で作られるほうの代わりに立つ。
          一つでも登録されていれば、呼び出しはそちらへ回る(eval の ECall と
          同じ判断で、call_named がそれを見ている) *)
       let def_env = !env in
       Array.iter
         (fun c ->
           let pnames = Array.map (fun pr -> sym pr.p_name) c.c_params in
           let sig_ = Array.to_list (Array.map (fun pr -> type_names pr.p_types) c.c_params) in
           let body = p.ireps.(c.c_body) in
           let n_required, n_total = arity_range c.c_params in
           let impl argv =
             let call_env = Eval.new_scope def_env in
             bind_args call_env c.c_params pnames c.c_kwparams argv;
             (* 体の中の `new(...)` が、どの struct を建てるのかを言う *)
             let saved = !current_constructing_struct in
             current_constructing_struct := Some full_name;
             Fun.protect
               ~finally:(fun () -> current_constructing_struct := saved)
               (fun () -> exec p body call_env)
           in
           for k = n_required to n_total do
             Dispatch.defmethod full_name (Eval.take k sig_) impl
           done)
         st.st_ctors;
       if Array.length st.st_kwdefaults > 0 then
         Hashtbl.replace Eval.kwdef_defaults full_name
           (Array.to_list
              (Array.map
                 (fun (f, irep) -> sym f, fun env -> exec p p.ireps.(irep) env)
                 st.st_kwdefaults));
       push VNothing;
       incr pc
     | Defabstract (n, parent) ->
       declare_abstract
         (!current_module_prefix ^ sym n)
         ~parent:(resolve_type_name (sym parent));
       push VNothing;
       incr pc
     | Try catch_pc ->
       handlers :=
         { h_pc = catch_pc
         ; h_sp = !sp
         ; h_env = !env
         ; h_iters = !iters
         ; h_prefixes = !outer_prefixes
         ; h_site = here ()
         }
         :: !handlers;
       incr pc
     | Try_end ->
       (match !handlers with
        | _ :: rest -> handlers := rest
        | [] -> failwith "vm: Try_end with no try");
       incr pc
     | Ret ->
       result := pop ();
       running := false);
      if !running && !pc >= Array.length code then failwith "vm: ran off the end"
    done
  in
  (* 投げられたものを受け止める。受け止め手が居なければ、そのまま外へ通す --
     いちばん外(main / actorBridge)が読むのは、そのままの形なので *)
  let rec go () =
    match step_all () with
    | () -> ()
    | exception e -> (
      match e, !handlers with
      | (JuliaError _ | Failure _), h :: rest ->
        handlers := rest;
        (* 投げられたところで止まったままの位置とフレームを、ここで戻す
           (eval の STry と同じ場所で、同じことをしている) *)
        restore_site h.h_site;
        sp := h.h_sp;
        env := h.h_env;
        iters := h.h_iters;
        outer_prefixes := h.h_prefixes;
        push (match e with JuliaError v -> v | Failure msg -> exn_of_failure_message msg | _ -> assert false);
        pc := h.h_pc;
        go ()
      | _ -> raise e)
  in
  go ();
  !result

let run (p : program) env : value = exec p p.ireps.(p.main) env
