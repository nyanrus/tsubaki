(* drop に積むほう。CLI も REPL も、gpu も ecs も physics も無い。
   ホストが tsubakiEval / tsubakiCall で呼ぶ、その戸だけ開けておく。
   何がここに来るかは bin/dune が言っている。

   **JsBridge は、ここでは呼ばない。** `jsglobal("globalThis")` が一行あれば、
   drop の ops から worker の特権 global に手が届いてしまう -- そこから先は
   何でもできるので、「この drop にできるのはこれだけ」と書いた札が、ただの
   札になる。JsBridge の method は module の top level で登録されるので、
   誰も参照しなければ link されず、名前ごと無くなる(呼ばないこと自体が、
   引き算になっている)。使っている drop はゼロ。

   `include` も同じ理由で開けない(`Eval.install_include ()` を呼ばない)。
   worker にファイルは無いし、隣のファイルは `import` で足りている -- そちらは
   build のときに畳まれる。読めない戸でも、開いていないほうがいい。

   これで、drop にできることの天井は wasm の import と actor の戸だけになる
   -- 数えられる形になった、というのがここの狙い。CLI(bin/main.ml)は
   いままでどおり JsBridge も include も持つ。

   閉まっているかどうかは `make check-doors` が訊く(tools/drop-doors.cjs)。
   ここに一行足すと開いてしまうので、覚えているのがこのコメントだけ、には
   しないでおく。 *)

let () = Frontend.install ()
let () = ActorBridge.init ()
