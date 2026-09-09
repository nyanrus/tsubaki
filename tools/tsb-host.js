// 渡す道の、いちばん端。parser を持たない build(dropvm)に .tsb を食べさせる。
//
//     node -r ./preload.js _build/default/bin/tsb-host.js path/to/file.tsb [関数名]
//
// 関数名を足すと、走らせたあとにそれを呼んで、答えを JSON で出す
// (drop の worker が `call` でしているのと同じこと)。
//
// bin/ に置いてから走らせる必要がある -- glue は自分の .assets を
// require.main の隣から探すので(preload.js の頭に、その説明があります)。
// Makefile の test-tsb がそれをしている。
const fs = require("fs");
globalThis.tsubakiOnReady = () => {
  globalThis.tsubakiRunTsb(new Uint8Array(fs.readFileSync(process.argv[2])));
  const name = process.argv[3];
  if (name) console.log(JSON.stringify(globalThis.tsubakiCall(name, [])));
};
require("./dropvm.bc.wasm.js");
