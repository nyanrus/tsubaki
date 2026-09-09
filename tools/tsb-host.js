// 渡す道の、いちばん端。parser を持たない build(dropvm)に .tsb を食べさせる。
//
//     node -r ./preload.js _build/default/bin/tsb-host.js path/to/file.tsb
//
// bin/ に置いてから走らせる必要がある -- glue は自分の .assets を
// require.main の隣から探すので(preload.js の頭に、その説明があります)。
// Makefile の test-tsb がそれをしている。
const fs = require("fs");
globalThis.tsubakiOnReady = () => {
  globalThis.tsubakiRunTsb(new Uint8Array(fs.readFileSync(process.argv[2])));
};
require("./dropvm.bc.wasm.js");
