(* .tsubaki を .tsb に畳むだけの道具。ビルドのときにだけ動きます。

   走らせる側の言葉(Eval も Vm も、橋も)は要らない -- ここは畳むだけなので。
   registry の build が、drop の ops をこれで一枚にします。

       tsubakic out.tsb std.tsubaki Style.tsubaki webpanel.tsubaki *)

let () =
  match Array.to_list Sys.argv with
  | _ :: out :: (_ :: _ as files) -> (
    match Tsb.of_files files with
    | tsb ->
      Tsb.write_file out tsb;
      prerr_endline (Printf.sprintf "%s: %d bytes" out (String.length tsb))
    | exception Ast.Parse_error msg ->
      prerr_endline ("tsubakic: " ^ msg);
      exit 1
    | exception Tocode.Not_yet what ->
      prerr_endline ("tsubakic: cannot fold " ^ what ^ " yet (see bin/tocode.ml)");
      exit 1
    | exception Sys_error msg ->
      prerr_endline ("tsubakic: " ^ msg);
      exit 1)
  | _ ->
    prerr_endline "usage: tsubakic out.tsb file.jl...";
    exit 1
