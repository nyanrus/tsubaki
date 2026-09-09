(* ============================= Bytecode ============================= *)
(* AST を畳んだ、平らな命令の列。

   mruby の irep に倣っている -- 命令の列と、リテラルの棚(pool)と、名前の棚
   (syms)と、関数の体それぞれの子 irep。木の代わりにこれを配れば、走らせる側は
   もう parser を持たなくていい。それが、この形にしたい理由の全部です。

   ここは何にも依存しない。書く側(Tocode、frontend に居る)と読む側(Vm、runtime
   の側に居る)が、この形だけを見て話す。

   キャッシュの番号 -- 段階2 で AST の外に出したもの -- は、そのままここに
   乗っている。表は Runtime 側にあるので、命令はただの数のままでいられる。
   mruby の irep が inline cache を VM 側に置いているのと、同じ形になった。

   まだ全部ではない。いま畳めるのは fib が通るだけの範囲で、畳めない形に
   出会ったら Tocode が「まだ畳めない」と言って止まる(黙って別の道を通ったり
   しない -- 走らせる側に parser が無い以上、あとで落ちるより、ここで言った
   ほうがいい)。 *)

type lit =
  | LInt of int
  | LFloat of float
  | LStr of string
  | LBool of bool

type instr =
  | Const of int (* pool[i] を積む *)
  | Nothing (* nothing を積む *)
  | Load of int * int (* syms[名前], var cache の番号 *)
  | Store of int * int (* 積まれている値を syms[名前] へ。値はそのまま残る *)
  | Pop
  | Binop of int * int (* syms[演算子], call cache の番号。二つ取って一つ積む *)
  | Call of int * int * int (* syms[名前], 引数の数, call cache の番号 *)
  | Call_kw of int * int * int array * int
    (* syms[名前], 位置引数の数, キーワードの名前たち, call cache。
       位置引数のあとに、キーワードの値がその並び順で積まれている *)
  | Jump of int (* その番地へ *)
  | Jump_if_false of int (* 積まれている値を取って、偽ならその番地へ *)
  | Println of int (* 引数の数。積まれている分をつないで、一行にして出す *)
  | Print of int (* 同じ、改行なし *)
  | Enter (* 新しいスコープに入る(if/while の体は、eval でもそうなっている) *)
  | Leave (* 親のスコープに戻る *)
  | Defun of int (* funcs[i] を宣言する *)
  | Bind of int (* 積まれている値を取って、いまのスコープに syms[名前] で置く *)
  | Bind_tuple of int array (* 同じ。ただしタプルをばらして、名前の数だけ *)
  | Store_plain of int (* syms[名前] へ代入。cache を持たない場所のため *)
  | Unpack_check of int
    (* 積まれているものが n 個のタプルであることを確かめて、覚えておく
       (取り出すのは Elem)。値はそのまま残る -- 分解代入そのものの値なので *)
  | Elem of int (* 覚えてあるタプルの i 番目 *)
  | Unpack_end (* 覚えるのをやめる *)
  | Typecheck of int * int array (* syms[名前] が syms[型…] を持てるか。値は残す *)
  | Comprehension of int (* comps[i]。for 節の数だけ、反復するものが積まれている *)
  | Pair (* a, b の順に積んで、a => b *)
  | Makearr of int (* 積まれている n 個で `[...]` *)
  | Using of int (* using syms[名前] *)
  | Import of int * int array (* import syms[名前]: syms[...] *)
  | Module_enter of int (* ここから先は module syms[名前] の中 *)
  | Module_leave (* 出る *)
  | Makeclosure of int (* lambdas[i] を、いまの環境を捕まえた値にする *)
  | File of int (* いまどのファイルか。値は積まない。一つの .tsb に何枚か
                   入っているときに、転んだ場所を言えるように *)
  | Line of int (* いま何行目か。値は積まない -- 位置の目印なので *)
  | Try of int (* ここから先で投げられたら、その番地へ(投げられた値を積んで) *)
  | Try_end (* 無事に済んだので、その受け止めをやめる *)
  | Makematrix of int * int (* 行, 列。積まれている 行*列 個を、行の順に *)
  | Qcall of int * int * int * int (* syms[module], syms[member], 引数の数, call cache *)
  | Apply of int (* 呼ぶもの, 引数… の順に積んで、引数の数 *)
  | Apply_method of int * int (* 受け手, 引数… の順に積んで、syms[名前], 引数の数 *)
  | Symbol of int (* `:name` -- 名前を Symbol として持つ *)
  | Typeof (* 積まれているものの型の名前 *)
  | Makedict of int (* 積まれている n 個の `key => value` で Dict *)
  | Isa of int (* 積まれているものが syms[名前] か *)
  | Typedarr of int * int (* syms[要素の型], 積まれている要素の数 *)
  | Typedarr_undef of int (* syms[要素の型]。長さを積んで *)
  | Typedmat_undef of int (* syms[要素の型]。行, 列 を積んで *)
  | Load_index of int * int
    (* `name[...]` の name。変数として引ければ入れもの(と `end`)、引けなくて
       型の名前なら「型として読む」印を置く -- どちらかは走らせてみるまで
       わからない(`Float64[1,2]` と `xs[i]` は、書かれた形が同じ) *)
  | Index_or_typed of int (* 上の印を見て、c[i] か Float64[...] か *)
  | Set_end (* 積まれている入れものの長さを、`end` が読めるところへ。値は残す *)
  | Index (* 入れもの, 添字 の順に積んで、c[i] *)
  | Index_set (* 入れもの, 添字, 値 の順に積んで、c[i] = v。値が残る *)
  | Endmark (* `[...]` の中の `end` *)
  | Maketuple of int (* 積まれている n 個で `(...)` *)
  | Identical of int (* 1 なら ===、0 なら !== *)
  | Subtype of int * int (* syms[下], syms[上] -- どちらも名前のまま *)
  | In (* item, 集まり の順に積んで、item in 集まり *)
  | Range (* lo, hi の順に積んで、a:b *)
  | Range3 (* lo, step, hi の順に積んで、a:s:b *)
  | Iter_new (* 積まれているものから、反復のいまを作る *)
  | Iter_next of int (* 次があれば積む。無ければ反復を降ろして、その番地へ *)
  | Getfield of int (* 積まれているものの syms[名前] のところ *)
  | Setfield of int (* 値・入れもの の順に積んで、入れものだけ取る。値は残る *)
  | Defstruct of int (* structs[i] を宣言する *)
  | Defabstract of int * int (* syms[名前], syms[親] *)
  | Ret (* 積まれている値を答えにして、この irep を出る *)

(* 引数ひとつ。型注釈は syms の番号の並び -- `x::Union{A,B}` なら二つ、
   注釈を書かなかった引数は "Any" ひとつ(parser がそうしている)。

   名前はここでは生のまま置いてある。module の中で宣言された型名をどう読むかは
   走らせる側が決める(Runtime.resolve_type_name)ので、畳む側では決めない。 *)
type param =
  { p_name : int
  ; p_types : int array
  ; p_default : int
    (* 既定値の irep に 1 を足したもの。0 なら既定値なし -- ここを通る数は
       どれも非負でいてほしいので、一つずらしてある *)
  }

(* キーワード引数ひとつ。既定値は子 irep -- 呼ばれるたびに、その呼び出しの
   スコープで作られる(木を歩く道が、そのたび式を評価しているのと同じ) *)
type kwparam = { k_name : int; k_types : int array; k_default : int (* ireps[i] *) }

type func =
  { f_name : int
  ; f_params : param array
  ; f_kwparams : kwparam array
  ; f_body : int (* ireps[i] *)
  ; f_cache : int (* funcdecl cache の番号 *)
  }

(* struct の中に書かれた constructor。関数と同じ形だけれど、名前は struct の
   ほうを使うので持たない *)
type ctor = { c_params : param array; c_kwparams : kwparam array; c_body : int }

(* ループの変数の受けかた。`for x in ...` は名前ひとつ、`for (k, v) in ...`
   はばらして二つ(内包表記の for 節も同じ形を使う) *)
type target = { t_names : int array; t_tuple : bool }

(* `[body for x in ...]`。for 節は一つか二つ。体は子 irep -- 式なので、
   中から `return` で関数を抜けることはない *)
type comp = { cp_targets : target array; cp_body : int }

(* `x -> ...` と `function (x) ... end`。名前を持たない -- 呼ばれるのは
   値として渡されたときなので、dispatch の表には載らない *)
type lambda = { l_params : int array; l_body : int }

(* struct のひとつ。親は書かれていなければ "Any" が入っている(Tocode が埋める)。
   inner constructor と @kwdef の既定値はまだ畳まないので、ここには無い。 *)
type field = { fd_name : int; fd_types : int array }

type strct =
  { st_mutable : bool
  ; st_name : int
  ; st_parent : int
  ; st_typarams : int array
  ; st_fields : field array
  ; st_ctors : ctor array
  ; st_kwdefaults : (int * int) array
    (* field の syms と、その既定値の irep。@kwdef が付いていたときだけ
       中身がある -- 素の struct に書かれた `field = 既定値` は、eval と
       同じく、ここには来ない *)
  }

type program =
  { pool : lit array
  ; syms : string array
  ; funcs : func array
  ; structs : strct array
  ; lambdas : lambda array
  ; comps : comp array
  ; ireps : instr array array
  ; main : int (* ireps のうち、top level はどれか *)
  }

(* --- .tsb: この形を、そのままバイトにする ---------------------------------
   渡す道がここにできる。書くのはビルド時(frontend)、読むのは走らせる側。
   読む側は、これだけ読めれば parser を持たなくていい。

   形式は素直に -- 4 バイトの整数と、長さつきの文字列と、命令ごとの一バイトの
   札。LEB128 のような詰め方はしていない(まず通すことを先に)。 *)

let magic = "TSB1"

(* 4 バイト。ここを通る数はどれも非負(棚の番号、引数の数、飛び先、cache の
   番号)。int の幅は走る場所で違う(js_of_ocaml では 32 bit)ので、符号を
   またぐ書き方はしない -- 負を持ちうるのは下の二つだけで、それぞれ自分の
   やり方で書く。 *)
let put_nat buf n =
  if n < 0 then invalid_arg "Bytecode.put_nat: negative";
  Buffer.add_char buf (Char.chr ((n lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (n land 0xff))

(* 整数リテラルは負になりうるので 8 バイト、Int64 のまま *)
let put_i64 buf (n : int) =
  let bits = Int64.of_int n in
  for k = 7 downto 0 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits (k * 8)) 0xFFL)))
  done

let put_float buf f =
  let bits = Int64.bits_of_float f in
  for k = 7 downto 0 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits (k * 8)) 0xFFL)))
  done

(* 番号の並び。長さを先に書く *)
let put_nats buf a =
  put_nat buf (Array.length a);
  Array.iter (put_nat buf) a

let put_str buf s =
  put_nat buf (String.length s);
  Buffer.add_string buf s

let put_params buf ps =
  put_nat buf (Array.length ps);
  Array.iter
    (fun (pr : param) ->
      put_nat buf pr.p_name;
      put_nats buf pr.p_types;
      put_nat buf pr.p_default)
    ps

let put_kwparams buf ks =
  put_nat buf (Array.length ks);
  Array.iter
    (fun (k : kwparam) ->
      put_nat buf k.k_name;
      put_nats buf k.k_types;
      put_nat buf k.k_default)
    ks

let op buf tag args =
  Buffer.add_char buf (Char.chr tag);
  List.iter (put_nat buf) args

let to_bytes (p : program) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf magic;
  put_nat buf (Array.length p.pool);
  Array.iter
    (fun l ->
      match l with
      | LInt n -> Buffer.add_char buf '\000'; put_i64 buf n
      | LFloat f -> Buffer.add_char buf '\001'; put_float buf f
      | LStr s -> Buffer.add_char buf '\002'; put_str buf s
      | LBool b -> Buffer.add_char buf '\003'; put_nat buf (if b then 1 else 0))
    p.pool;
  put_nat buf (Array.length p.syms);
  Array.iter (put_str buf) p.syms;
  put_nat buf (Array.length p.funcs);
  Array.iter
    (fun f ->
      put_nat buf f.f_name;
      put_params buf f.f_params;
      put_kwparams buf f.f_kwparams;
      put_nat buf f.f_body;
      put_nat buf f.f_cache)
    p.funcs;
  put_nat buf (Array.length p.structs);
  Array.iter
    (fun st ->
      put_nat buf (if st.st_mutable then 1 else 0);
      put_nat buf st.st_name;
      put_nat buf st.st_parent;
      put_nats buf st.st_typarams;
      put_nat buf (Array.length st.st_fields);
      Array.iter
        (fun fd ->
          put_nat buf fd.fd_name;
          put_nats buf fd.fd_types)
        st.st_fields;
      put_nat buf (Array.length st.st_ctors);
      Array.iter
        (fun c ->
          put_params buf c.c_params;
          put_kwparams buf c.c_kwparams;
          put_nat buf c.c_body)
        st.st_ctors;
      put_nat buf (Array.length st.st_kwdefaults);
      Array.iter
        (fun (f, irep) ->
          put_nat buf f;
          put_nat buf irep)
        st.st_kwdefaults)
    p.structs;
  put_nat buf (Array.length p.lambdas);
  Array.iter
    (fun l ->
      put_nats buf l.l_params;
      put_nat buf l.l_body)
    p.lambdas;
  put_nat buf (Array.length p.comps);
  Array.iter
    (fun c ->
      put_nat buf (Array.length c.cp_targets);
      Array.iter
        (fun t ->
          put_nats buf t.t_names;
          put_nat buf (if t.t_tuple then 1 else 0))
        c.cp_targets;
      put_nat buf c.cp_body)
    p.comps;
  put_nat buf (Array.length p.ireps);
  Array.iter
    (fun code ->
      put_nat buf (Array.length code);
      Array.iter
        (fun i ->
          match i with
          | Const a -> op buf 0 [ a ]
          | Nothing -> op buf 1 []
          | Load (a, b) -> op buf 2 [ a; b ]
          | Store (a, b) -> op buf 3 [ a; b ]
          | Pop -> op buf 4 []
          | Binop (a, b) -> op buf 5 [ a; b ]
          | Call (a, b, c) -> op buf 6 [ a; b; c ]
          | Call_kw (a, b, ks, c) ->
            Buffer.add_char buf (Char.chr 49);
            put_nat buf a;
            put_nat buf b;
            put_nats buf ks;
            put_nat buf c
          | Jump a -> op buf 7 [ a ]
          | Jump_if_false a -> op buf 8 [ a ]
          | Println a -> op buf 9 [ a ]
          | Print a -> op buf 10 [ a ]
          | Enter -> op buf 11 []
          | Leave -> op buf 12 []
          | Defun a -> op buf 13 [ a ]
          | Ret -> op buf 14 []
          | Bind a -> op buf 19 [ a ]
          | Store_plain a -> op buf 57 [ a ]
          | Unpack_check a -> op buf 58 [ a ]
          | Elem a -> op buf 59 [ a ]
          | Unpack_end -> op buf 60 []
          | Typecheck (a, ts) ->
            Buffer.add_char buf (Char.chr 61);
            put_nat buf a;
            put_nats buf ts
          | Bind_tuple ns ->
            Buffer.add_char buf (Char.chr 55);
            put_nats buf ns
          | Comprehension a -> op buf 56 [ a ]
          | Pair -> op buf 24 []
          | Makearr a -> op buf 28 [ a ]
          | Using a -> op buf 37 [ a ]
          | Import (a, ms) ->
            Buffer.add_char buf (Char.chr 38);
            put_nat buf a;
            put_nats buf ms
          | Module_enter a -> op buf 39 [ a ]
          | Module_leave -> op buf 40 []
          | Makeclosure a -> op buf 41 [ a ]
          | File a -> op buf 63 [ a ]
          | Line a -> op buf 48 [ a ]
          | Try a -> op buf 46 [ a ]
          | Try_end -> op buf 47 []
          | Makematrix (a, b) -> op buf 42 [ a; b ]
          | Qcall (a, b, c, d) -> op buf 43 [ a; b; c; d ]
          | Apply a -> op buf 44 [ a ]
          | Apply_method (a, b) -> op buf 45 [ a; b ]
          | Symbol a -> op buf 62 [ a ]
          | Typeof -> op buf 34 []
          | Makedict a -> op buf 35 [ a ]
          | Isa a -> op buf 36 [ a ]
          | Typedarr (a, b) -> op buf 50 [ a; b ]
          | Typedarr_undef a -> op buf 51 [ a ]
          | Typedmat_undef a -> op buf 52 [ a ]
          | Load_index (a, b) -> op buf 53 [ a; b ]
          | Index_or_typed a -> op buf 54 [ a ]
          | Set_end -> op buf 30 []
          | Index -> op buf 31 []
          | Index_set -> op buf 32 []
          | Endmark -> op buf 33 []
          | Maketuple a -> op buf 29 [ a ]
          | Identical a -> op buf 25 [ a ]
          | Subtype (a, b) -> op buf 26 [ a; b ]
          | In -> op buf 27 []
          | Range -> op buf 20 []
          | Range3 -> op buf 21 []
          | Iter_new -> op buf 22 []
          | Iter_next a -> op buf 23 [ a ]
          | Getfield a -> op buf 17 [ a ]
          | Setfield a -> op buf 18 [ a ]
          | Defstruct a -> op buf 15 [ a ]
          | Defabstract (a, b) -> op buf 16 [ a; b ])
        code)
    p.ireps;
  put_nat buf p.main;
  Buffer.contents buf

exception Bad_tsb of string

let of_bytes (s : string) : program =
  let pos = ref 0 in
  let need n = if !pos + n > String.length s then raise (Bad_tsb "ran off the end") in
  let byte k = Char.code s.[!pos + k] in
  let get_nat () =
    need 4;
    let n = (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3 in
    pos := !pos + 4;
    n
  in
  let get_bits () =
    need 8;
    let bits = ref 0L in
    for k = 0 to 7 do
      bits := Int64.logor (Int64.shift_left !bits 8) (Int64.of_int (byte k))
    done;
    pos := !pos + 8;
    !bits
  in
  let get_tag () =
    need 1;
    let c = byte 0 in
    incr pos;
    c
  in
  let get_nats () = Array.init (get_nat ()) (fun _ -> get_nat ()) in
  let get_params () =
    Array.init (get_nat ()) (fun _ ->
        let p_name = get_nat () in
        let p_types = get_nats () in
        let p_default = get_nat () in
        { p_name; p_types; p_default })
  in
  let get_kwparams () =
    Array.init (get_nat ()) (fun _ ->
        let k_name = get_nat () in
        let k_types = get_nats () in
        let k_default = get_nat () in
        { k_name; k_types; k_default })
  in
  let get_str () =
    let n = get_nat () in
    need n;
    let r = String.sub s !pos n in
    pos := !pos + n;
    r
  in
  need 4;
  if String.sub s 0 4 <> magic then raise (Bad_tsb "not a .tsb (wrong magic)");
  pos := 4;
  let pool =
    Array.init (get_nat ()) (fun _ ->
        match get_tag () with
        | 0 -> LInt (Int64.to_int (get_bits ()))
        | 1 -> LFloat (Int64.float_of_bits (get_bits ()))
        | 2 -> LStr (get_str ())
        | 3 -> LBool (get_nat () <> 0)
        | t -> raise (Bad_tsb (Printf.sprintf "unknown literal tag %d" t)))
  in
  let syms = Array.init (get_nat ()) (fun _ -> get_str ()) in
  let funcs =
    Array.init (get_nat ()) (fun _ ->
        let f_name = get_nat () in
        let f_params = get_params () in
        let f_kwparams = get_kwparams () in
        let f_body = get_nat () in
        let f_cache = get_nat () in
        { f_name; f_params; f_kwparams; f_body; f_cache })
  in
  let structs =
    Array.init (get_nat ()) (fun _ ->
        let st_mutable = get_nat () <> 0 in
        let st_name = get_nat () in
        let st_parent = get_nat () in
        let st_typarams = get_nats () in
        let st_fields =
          Array.init (get_nat ()) (fun _ ->
              let fd_name = get_nat () in
              let fd_types = get_nats () in
              { fd_name; fd_types })
        in
        let st_ctors =
          Array.init (get_nat ()) (fun _ ->
              let c_params = get_params () in
              let c_kwparams = get_kwparams () in
              let c_body = get_nat () in
              { c_params; c_kwparams; c_body })
        in
        let st_kwdefaults =
          Array.init (get_nat ()) (fun _ ->
              let f = get_nat () in
              let irep = get_nat () in
              f, irep)
        in
        { st_mutable; st_name; st_parent; st_typarams; st_fields; st_ctors; st_kwdefaults })
  in
  let lambdas =
    Array.init (get_nat ()) (fun _ ->
        let l_params = get_nats () in
        let l_body = get_nat () in
        { l_params; l_body })
  in
  let comps =
    Array.init (get_nat ()) (fun _ ->
        let cp_targets =
          Array.init (get_nat ()) (fun _ ->
              let t_names = get_nats () in
              let t_tuple = get_nat () <> 0 in
              { t_names; t_tuple })
        in
        let cp_body = get_nat () in
        { cp_targets; cp_body })
  in
  let ireps =
    Array.init (get_nat ()) (fun _ ->
        Array.init (get_nat ()) (fun _ ->
            match get_tag () with
            | 0 -> Const (get_nat ())
            | 1 -> Nothing
            | 2 -> let a = get_nat () in let b = get_nat () in Load (a, b)
            | 3 -> let a = get_nat () in let b = get_nat () in Store (a, b)
            | 4 -> Pop
            | 5 -> let a = get_nat () in let b = get_nat () in Binop (a, b)
            | 6 -> let a = get_nat () in let b = get_nat () in let c = get_nat () in Call (a, b, c)
            | 49 ->
              let a = get_nat () in
              let b = get_nat () in
              let ks = get_nats () in
              let c = get_nat () in
              Call_kw (a, b, ks, c)
            | 7 -> Jump (get_nat ())
            | 8 -> Jump_if_false (get_nat ())
            | 9 -> Println (get_nat ())
            | 10 -> Print (get_nat ())
            | 11 -> Enter
            | 12 -> Leave
            | 13 -> Defun (get_nat ())
            | 14 -> Ret
            | 15 -> Defstruct (get_nat ())
            | 17 -> Getfield (get_nat ())
            | 19 -> Bind (get_nat ())
            | 55 -> Bind_tuple (get_nats ())
            | 57 -> Store_plain (get_nat ())
            | 58 -> Unpack_check (get_nat ())
            | 59 -> Elem (get_nat ())
            | 60 -> Unpack_end
            | 61 -> let a = get_nat () in let ts = get_nats () in Typecheck (a, ts)
            | 56 -> Comprehension (get_nat ())
            | 24 -> Pair
            | 28 -> Makearr (get_nat ())
            | 30 -> Set_end
            | 50 -> let a = get_nat () in let b = get_nat () in Typedarr (a, b)
            | 51 -> Typedarr_undef (get_nat ())
            | 52 -> Typedmat_undef (get_nat ())
            | 53 -> let a = get_nat () in let b = get_nat () in Load_index (a, b)
            | 54 -> Index_or_typed (get_nat ())
            | 34 -> Typeof
            | 62 -> Symbol (get_nat ())
            | 42 -> let a = get_nat () in let b = get_nat () in Makematrix (a, b)
            | 46 -> Try (get_nat ())
            | 48 -> Line (get_nat ())
            | 63 -> File (get_nat ())
            | 47 -> Try_end
            | 43 ->
              let a = get_nat () in
              let b = get_nat () in
              let c = get_nat () in
              let d = get_nat () in
              Qcall (a, b, c, d)
            | 44 -> Apply (get_nat ())
            | 45 -> let a = get_nat () in let b = get_nat () in Apply_method (a, b)
            | 37 -> Using (get_nat ())
            | 38 -> let a = get_nat () in let ms = get_nats () in Import (a, ms)
            | 39 -> Module_enter (get_nat ())
            | 40 -> Module_leave
            | 41 -> Makeclosure (get_nat ())
            | 35 -> Makedict (get_nat ())
            | 36 -> Isa (get_nat ())
            | 31 -> Index
            | 32 -> Index_set
            | 33 -> Endmark
            | 29 -> Maketuple (get_nat ())
            | 25 -> Identical (get_nat ())
            | 26 -> let a = get_nat () in let b = get_nat () in Subtype (a, b)
            | 27 -> In
            | 20 -> Range
            | 21 -> Range3
            | 22 -> Iter_new
            | 23 -> Iter_next (get_nat ())
            | 18 -> Setfield (get_nat ())
            | 16 -> let a = get_nat () in let b = get_nat () in Defabstract (a, b)
            | t -> raise (Bad_tsb (Printf.sprintf "unknown opcode %d" t))))
  in
  let main = get_nat () in
  { pool; syms; funcs; structs; lambdas; comps; ireps; main }
