#!/bin/bash
# Differential test: feed the same expression snippet to the real OCaml
# interpreter and to this crate's Rust port, diff their `println(...)`
# output line for line. See README.md for what's in/out of scope and why
# this exists at all.
set -eu
cd "$(dirname "$0")"

cargo build --quiet --release

REPO_ROOT=".."
if [ ! -f "$REPO_ROOT/_build/default/bin/main.bc.wasm.js" ]; then
  echo "error: $REPO_ROOT/_build not found -- run 'make build' from the repo root first" >&2
  exit 1
fi

# One snippet per line. Kept in one place (not scattered across ad hoc
# shell commands) so this list grows into the real regression suite for
# this crate's parser, not a one-off.
SNIPPETS_FILE="$(mktemp)"
trap 'rm -f "$SNIPPETS_FILE"' EXIT
cat > "$SNIPPETS_FILE" << 'EOF'
[12.0 37.0 -43.0; -16.0 -43.0 98.0]
[4.0 12.0 -16.0; 12.0 37.0 -43.0; -16.0 -43.0 98.0]
[1.0 2.0 3.0; 4.0 5.0 6.0; 7.0 8.0 10.0]
[1.0 -2.0 3.0]
[1.0 - 2.0]
[1.0-2.0]
[0.0 1.0; 1.0 0.0]
[100.0 200.0; 300.0 -400.0]
[1.0 0.0 0.0; 0.0 1.0 0.0]
[1.0, 2.0, 3.0]
1 + 2 * 3
2^10
3 < 5
1.0 / 3.0
10 % 3
-5
2 - -3
3 < 5 ? 1 : 2
3 > 5 ? 1 : 2
1:5
1:2:7
1.0:0.5:2.0
"hello"
[10.0, 20.0, 30.0][2]
[10.0, 20.0, 30.0][1:2]
[1.0 2.0; 3.0 4.0][2, 1]
sqrt(4.0)
sqrt(4)
abs(-5)
abs(-5.0)
length([1.0, 2.0, 3.0])
[1.0 2.0; 3.0 4.0]'
[1.0, 2.0, 3.0]'
EOF

pass=0
fail=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ocaml_out=$(node -r "$REPO_ROOT/preload.js" "$REPO_ROOT/_build/default/bin/main.bc.wasm.js" <(echo "println($line)") 2>&1 || true)
  rust_out=$(./target/release/tsubaki-rust-parser "$line" 2>&1 || true)
  if [ "$ocaml_out" = "$rust_out" ]; then
    pass=$((pass + 1))
    echo "PASS  $line"
  else
    fail=$((fail + 1))
    echo "FAIL  $line"
    echo "  OCaml: $ocaml_out"
    echo "  Rust:  $rust_out"
  fi
done < "$SNIPPETS_FILE"

echo ""
echo "$pass passed, $fail failed"

# --- statement-level programs (if/for/while/return, see program_snippets/)
# --- each is a whole script, run as-is (no println(...) wrapping): OCaml's
# --- own `Eval.run` prints nothing implicitly, so only explicit
# --- println/print calls inside the script produce comparable output.
for f in program_snippets/*.jl; do
  name="$(basename "$f")"
  ocaml_out=$(node -r "$REPO_ROOT/preload.js" "$REPO_ROOT/_build/default/bin/main.bc.wasm.js" "$f" 2>&1 || true)
  rust_out=$(./target/release/tsubaki-rust-parser --program < "$f" 2>&1 || true)
  if [ "$ocaml_out" = "$rust_out" ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name"
    echo "  OCaml: $ocaml_out"
    echo "  Rust:  $rust_out"
  fi
done

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
