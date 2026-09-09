(* drop に積むほう。CLI も REPL も、gpu も ecs も physics も無い。
   ホストが tsubakiEval / tsubakiCall で呼ぶ、その戸だけ開けておく。
   何がここに来るかは bin/dune が言っている。 *)

let () = Frontend.install ()
let () = JsBridge.init ()
let () = ActorBridge.init ()
