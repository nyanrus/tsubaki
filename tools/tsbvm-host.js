// tsbvm(Rust の VM)を wasm として起こして、.tsb を一枚食べさせる。
//
//     node tools/tsbvm-host.js path/to/file.tsb
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
const { tsb_alloc, tsb_run, tsb_out_ptr, tsb_out_len, memory } = inst.exports;

const tsb = fs.readFileSync(process.argv[2]);
const ptr = tsb_alloc(tsb.length);
new Uint8Array(memory.buffer, ptr, tsb.length).set(tsb);
const code = tsb_run(ptr, tsb.length);
const out = new Uint8Array(memory.buffer, tsb_out_ptr(), tsb_out_len());
process.stdout.write(Buffer.from(out).toString("utf8"));
process.exit(code);
