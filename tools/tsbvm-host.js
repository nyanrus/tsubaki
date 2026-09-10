// tsbvm(Rust の VM)を wasm として起こして、.tsb を一枚食べさせる。
//
//     node tools/tsbvm-host.js path/to/file.tsb [関数名 [引数の JSON]]
//
// 関数名を足すと、走らせたあとにそれを呼んで、答えを JSON で出す
// (drop の worker が `call` でしているのと同じこと)。
//
// 渡し方は kernel と同じ: この module 自身の線形メモリを alloc してもらって、
// そこにバイトを書き、走らせて、出た文字を読み戻す。参照は越えない。
const fs = require("fs");
const path = require("path");
const wasmPath = path.join(
  __dirname,
  "..",
  "tsbvm",
  "target",
  "wasm32-unknown-unknown",
  "release",
  "tsbvm.wasm",
);
const inst = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), {});
const { tsb_alloc, tsb_run, tsb_call, tsb_out_ptr, tsb_out_len, memory } = inst.exports;

/** バイトを module のメモリに置いて、その場所と長さを返す */
function put(bytes) {
  const ptr = tsb_alloc(bytes.length);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function output() {
  return Buffer.from(new Uint8Array(memory.buffer, tsb_out_ptr(), tsb_out_len())).toString("utf8");
}

const tsb = fs.readFileSync(process.argv[2]);
let code = tsb_run(...put(tsb));
process.stdout.write(output());

const name = process.argv[3];
if (code === 0 && name) {
  const args = Buffer.from(process.argv[4] ?? "[]", "utf8");
  code = tsb_call(...put(Buffer.from(name, "utf8")), ...put(args));
  process.stdout.write(output() + "\n");
}
process.exit(code);
