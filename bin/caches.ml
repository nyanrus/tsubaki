(* ============================= Caches ============================= *)
(* AST のノードは、実行時のキャッシュのセルを自分の中に持たない。番号だけ持つ。
   セルの表は Runtime 側にある(mruby の irep も、inline cache は irep にでは
   なく VM の側に持つ)。

   ここは、その番号を配るところ。使うのは AST を作る側だけ -- Parser、
   マクロ展開(Eval.value_to_expr)、Compile の inline 置換。番号は一本の
   通し番号で、プログラムを読むたびに増えていく(REPL や tsubakiEval で
   何度読んでも、前に配った番号のセルはそのまま残る)。

   これで ast.ml は Runtime を知らなくてよくなる。AST がただのデータに
   なる、というのが目的で、速さのためではない -- 速さは Runtime 側の表が
   引き受ける。 *)

let n_var = ref 0
let n_call = ref 0
let n_funcdecl = ref 0

let fresh_var () = let i = !n_var in incr n_var; i
let fresh_call () = let i = !n_call in incr n_call; i
let fresh_funcdecl () = let i = !n_funcdecl in incr n_funcdecl; i
