(* ============================= Frontend ============================= *)
(* Eval が開けておいた口に、ソースを読む道具を差し込むところ。

   ここを呼ばない build は、ソースを渡されても読めない -- AST を受け取って
   走らせることしかできない。それが、この分けかたで言いたかったことの全部
   です。Eval の本体はもともと AST しか見ていなかったので、Parser と Compile
   を外に出すのに要ったのは、この六行だけだった。

   Compile のほうは差し込まれていなくても困らない(「その形は無理」と答えた
   ときと同じ道を通って、tree-walking で走る)。読むほうと GPU のほうは、
   無いなら無いと言う。 *)

let install () =
  Eval.parse_source :=
    (fun src ->
      let prog = Parser.parse_program src in
      Resolve.resolve_program prog;
      prog);
  Eval.compile_bytecode :=
    (fun body ->
      match Compile.try_compile body with
      | Some (code, nslots) -> Some (Compile.encode code, nslots)
      | None -> None);
  Eval.compile_host :=
    (fun body ->
      match Compile.try_compile_host body with
      | Some (prog, nslots) -> Some (fun () -> Host.run prog nslots)
      | None -> None);
  Eval.register_inlinable := Compile.register_inlinable;
  Eval.compile_wgsl := Compile.Wgsl.try_compile;
  Eval.compile_glsl := Compile.Glsl.compile_stage

(* CurveBridge は top-level で Tsubaki のソースを走らせる(`f` と `add` を
   Tsubaki 自身のことばで定義している)ので、差し込みは library の初期化の
   うちに済んでいないと間に合わない -- executable の top-level は、その
   あとに来るので。だから、ここで一度呼んでおく。

   main.ml / drop.ml がもう一度呼ぶのは、この module を確かにリンクさせる
   ため。CurveBridge.init がそこに居るのと同じ理由です(参照されない module
   の top-level 効果は、コンパイルの途中で静かに落ちる)。二度呼んでも
   同じところに同じものを差し込むだけ。 *)
let () = install ()
