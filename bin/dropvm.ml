(* .tsb だけを走らせる drop。parser も、AST をソースから組む道も入っていない
   -- ホストが渡すのは命令列だけ(tsubakiRunTsb)。

   drop.ml との違いは、Frontend を呼ばないことと、bin/dune がこちらに
   tsubaki_frontend をリンクしないこと。それだけで、前半分がまるごと落ちる。
   `tsubakiEval` の戸は残っているけれど、差し込まれていないので「ソースは
   読めない」と言う。 *)

let () = JsBridge.init ()
let () = ActorBridge.init ()
