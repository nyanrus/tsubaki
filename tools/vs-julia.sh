#!/bin/sh
# 一つの .jl を、Tsubaki の VM(Rust)と本物の Julia の両方で走らせて、出たものを
# 並べて比べる。
#
#     tools/vs-julia.sh path/to/file.jl
#
# 互換性の基準は Julia です。食い違ったら、直るのはこちら -- この道具は
# 「どこが違うか」を見つけるためのもので、直したあとにもう一度通す。
# make build と、tsbvm の wasm が建っていること、julia が PATH に居ることが要る。
set -e
jl=$1
# wasm を建て直しておく -- tsbvm-host.js が読むのは wasm のほうで、
# cargo build だけしても手元の直しは届かない(何度か踏んだ)
(cd tsbvm && cargo build --lib --target wasm32-unknown-unknown --release >/dev/null 2>&1)
[ -n "$jl" ] || { echo "usage: tools/vs-julia.sh path/to/file.jl" >&2; exit 1; }
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
node _build/default/bin/tsubakic.bc.wasm.js "$dir/a.tsb" "$jl" >/dev/null 2>&1 || {
  echo "畳めなかった:" >&2
  node _build/default/bin/tsubakic.bc.wasm.js "$dir/a.tsb" "$jl" 2>&1 >/dev/null | head -3 >&2
  exit 1
}
node tools/tsbvm-host.js "$dir/a.tsb" > "$dir/tsubaki.txt" 2>&1 || true
julia --startup-file=no "$jl" > "$dir/julia.txt" 2>&1 || true
if diff -q "$dir/julia.txt" "$dir/tsubaki.txt" >/dev/null; then
  echo "同じ ($(wc -l < "$dir/julia.txt" | tr -d ' ') 行)"
else
  diff -u --label julia "$dir/julia.txt" --label tsubaki "$dir/tsubaki.txt"
  exit 1
fi
