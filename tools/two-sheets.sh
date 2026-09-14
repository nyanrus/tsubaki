#!/bin/sh
# 二枚に分けて読んだ答えが、一枚に畳んだ答えと同じかどうか。
#
#     tools/two-sheets.sh [--no-julia] [a.jl b.jl ...]
#
# 引数が無ければ tests/two-sheets/ の二組を続けて。std を lib から一枚だけ配って、
# drop は自分のぶんだけを持つ -- そのときに走らせる側がすることを、ここで先に
# 確かめる。
#
# 一枚に畳む道はもう Julia と突き合わせてあるので、それが基準。julia が PATH に
# 居れば、三つ目として本物とも比べる(`--no-julia` で降りる)。
# make build と、tsbvm の wasm が建っていることが要る。
set -e
cd "$(dirname "$0")/.."
if [ $# -eq 0 ]; then
  # 一組目は本物の Julia でも走る。二組目は module -- 上の但し書きのとおり
  tools/two-sheets.sh tests/two-sheets/a.jl tests/two-sheets/b.jl
  tools/two-sheets.sh --no-julia tests/two-sheets/mod-a.jl tests/two-sheets/mod-b.jl
  exit $?
fi
with_julia=1
if [ "$1" = "--no-julia" ]; then
  with_julia=0
  shift
fi
# wasm を建て直しておく -- tsbvm-host.js が読むのは wasm のほうで、
# cargo build だけしても手元の直しは届かない
(cd tsbvm && cargo build --lib --target wasm32-unknown-unknown --release >/dev/null 2>&1)

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
fold() {
  out=$1
  shift
  node _build/default/bin/tsubakic.bc.wasm.js "$out" "$@" >/dev/null 2>&1 || {
    echo "畳めなかった: $*" >&2
    node _build/default/bin/tsubakic.bc.wasm.js "$out" "$@" 2>&1 >/dev/null | head -3 >&2
    exit 1
  }
}

# 一枚に
fold "$dir/one.tsb" "$@"
node tools/tsbvm-host.js "$dir/one.tsb" > "$dir/one.txt" 2>&1 || true

# 一枚ずつ、別々に
n=0
sheets=""
for jl in "$@"; do
  n=$((n + 1))
  fold "$dir/$n.tsb" "$jl"
  sheets="$sheets $dir/$n.tsb"
done
# shellcheck disable=SC2086
node tools/tsbvm-host.js $sheets > "$dir/many.txt" 2>&1 || true

ok=0
if diff -q "$dir/one.txt" "$dir/many.txt" >/dev/null; then
  echo "一枚と $n 枚が同じ ($(wc -l < "$dir/one.txt" | tr -d ' ') 行)"
else
  diff -u --label "一枚" "$dir/one.txt" --label "$n 枚" "$dir/many.txt"
  ok=1
fi

if [ "$with_julia" = 1 ] && command -v julia >/dev/null 2>&1; then
  cat "$@" > "$dir/all.jl"
  julia --startup-file=no "$dir/all.jl" > "$dir/julia.txt" 2>&1 || true
  if diff -q "$dir/julia.txt" "$dir/many.txt" >/dev/null; then
    echo "本物の Julia とも同じ"
  else
    diff -u --label julia "$dir/julia.txt" --label "$n 枚" "$dir/many.txt"
    ok=1
  fi
fi
exit $ok
