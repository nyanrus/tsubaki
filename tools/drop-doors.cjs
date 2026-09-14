// drop の build に、外へ出る戸が残っていないか訊く。
//
//     node tools/drop-doors.cjs
//
// drop に積む build(bin/drop.ml)は、わざと `jsglobal` も `tojs`/`fromjs` も
// `include` も持たない -- 一行あれば worker の特権 global に手が届いてしまう
// ので、「この drop にできるのはこれだけ」と書いた札が、ただの札になる。
// 消したことを覚えているのはコメントだけ、では、また戻ってくる。ここが訊く。
//
// (wasm.js は自分の隣で .wasm を探す -- require.main の居るところ。だから
//  一時の場所に置いて、assets を symlink で並べてから走らせる。)
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const build = path.join(__dirname, "..", "_build", "default", "bin");
const CLOSED = ['jsglobal("globalThis")', 'jsglobal("document")', 'tojs(Dict("a" => 1))', 'include("x.jl")'];
const OPEN = ["1 + 1", "length([1, 2])", 'get(Dict("a" => 1), "a", 0)'];

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "drop-doors-"));
fs.copyFileSync(path.join(build, "drop.bc.wasm.js"), path.join(dir, "drop.bc.wasm.js"));
fs.symlinkSync(path.join(build, "drop.bc.wasm.assets"), path.join(dir, "drop.bc.wasm.assets"));
fs.writeFileSync(
  path.join(dir, "ask.cjs"),
  `const closed = ${JSON.stringify(CLOSED)}, open = ${JSON.stringify(OPEN)};
globalThis.tsubakiOnReady = () => {
  let bad = 0;
  for (const src of closed) {
    let left = null;
    try { globalThis.tsubakiEval(src); left = "it answered"; }
    catch (e) { if (!/no method matching|not defined/.test(String(e))) left = String(e).split("\\n")[0]; }
    if (left) { console.log("  OPEN  " + src + " -- " + left); bad++; }
    else console.log("  shut  " + src);
  }
  for (const src of open) {
    try { globalThis.tsubakiEval(src); console.log("  works " + src); }
    catch (e) { console.log("  BROKE " + src + " -- " + String(e).split("\\n")[0]); bad++; }
  }
  process.exitCode = bad ? 1 : 0;
};
require("./drop.bc.wasm.js");`,
);

console.log("drop の戸:");
const r = spawnSync(process.execPath, [path.join(dir, "ask.cjs")], { stdio: "inherit" });
fs.rmSync(dir, { recursive: true, force: true });
if (r.status !== 0) {
  console.log("");
  console.log("外へ出る戸が残っている -- bin/drop.ml のいちばん上に、なぜ閉じているかがある。");
}
process.exit(r.status ?? 1);
