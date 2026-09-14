(* ============================= Tsb ============================= *)
(* ソースを .tsb にする。畳む側にだけ要るので、frontend の側に居ます。

   何枚かのファイルを一つの program に畳む -- drop の ops は std.tsubaki から
   順に読まれる何枚かで一つのまとまりで、cache のセルを指す番号はその流れの
   中で一つずつ配られるので、まとめて畳むほうが正しい。ファイルの変わり目には
   印(Bytecode.File)が入る。転んだときに、どのファイルの何行目かを言うため。 *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let of_files (files : string list) : string =
  let parsed =
    List.map
      (fun f ->
        let src = read_file f in
        Runtime.current_file := f;
        Runtime.current_file_dir := Filename.dirname f;
        f, Parser.parse_program src)
      files
  in
  Resolve.resolve_program (List.concat_map snd parsed);
  Bytecode.to_bytes (Tocode.compile_files parsed)

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc
