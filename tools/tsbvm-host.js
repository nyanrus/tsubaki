// tsbvm(Rust の VM)を wasm として起こして、.tsb を食べさせる。
//
//     node tools/tsbvm-host.js a.tsb [b.tsb ...] [-- 関数名 [引数の JSON]]
//
// 二枚目からは、一枚目の global scope の上に足される(静的 import)。std を
// lib から一枚だけ配るときの、走らせる側と同じ順。
//
// 関数名を足すと、走らせたあとにそれを呼んで、答えを JSON で出す
// (drop の worker が `call` でしているのと同じこと)。`--` を書かないときは、
// .tsb でない最初の引数から後ろが 関数名 と 引数。
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
const { tsb_alloc, tsb_run, tsb_load, tsb_call, tsb_out_ptr, tsb_out_len, memory } =
  inst.exports;

/** バイトを module のメモリに置いて、その場所と長さを返す */
function put(bytes) {
  const ptr = tsb_alloc(bytes.length);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function output() {
  return Buffer.from(new Uint8Array(memory.buffer, tsb_out_ptr(), tsb_out_len())).toString("utf8");
}

const argv = process.argv.slice(2);
const cut = argv.indexOf("--");
const sheets = cut >= 0 ? argv.slice(0, cut) : argv.filter((a) => a.endsWith(".tsb"));
const rest = cut >= 0 ? argv.slice(cut + 1) : argv.slice(sheets.length);
if (sheets.length === 0) {
  process.stderr.write("usage: node tools/tsbvm-host.js a.tsb [b.tsb ...] [-- name [args]]\n");
  process.exit(2);
}

let code = 0;
for (const [i, sheet] of sheets.entries()) {
  const bytes = fs.readFileSync(sheet);
  code = i === 0 ? tsb_run(...put(bytes)) : tsb_load(...put(bytes));
  process.stdout.write(output());
  if (code !== 0) process.exit(code);
}

const name = rest[0];
if (name) {
  const args = Buffer.from(rest[1] ?? "[]", "utf8");
  code = tsb_call(...put(Buffer.from(name, "utf8")), ...put(args));
  process.stdout.write(output() + "\n");
}
process.exit(code);
