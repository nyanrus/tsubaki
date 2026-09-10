.PHONY: build run repl test test-julia test-vm test-tsb test-tsbvm clean build-gpu clean-gpu

# 四本建つ。main は CLI/REPL と橋を全部つれてくる開発用、drop は drop に積む
# ほう(actor の戸だけ)、dropvm は .tsb だけを走らせるほう(parser が入らない)、
# tsubakic は畳むだけの道具(走らせる側の言葉が入らない)。
# 何がどちらに行くかは bin/dune。
build:
	dune build ./bin/main.bc.wasm.js ./bin/drop.bc.wasm.js ./bin/dropvm.bc.wasm.js \
	  ./bin/tsubakic.bc.wasm.js --profile release
	cd kernel && cargo build --target wasm32-unknown-unknown --release
	cd physics && cargo build --target wasm32-unknown-unknown --release

run: build
	node -r ./preload.js _build/default/bin/main.bc.wasm.js $(FILE)

# an interactive prompt: state carries from one line to the next, an error
# doesn't end the session. Ctrl-D to leave.
repl: build
	node -r ./preload.js _build/default/bin/main.bc.wasm.js --repl

# every tests/*.jl against its recorded output. `make test FILTER=dispatch`
# narrows it to matching names.
test: build
	python3 tools/test.py $(FILTER)

# the same suite, plus: every test marked `# julia: yes` is ALSO run through
# real Julia and must produce the identical output. Needs julia on PATH.
test-julia: build
	python3 tools/test.py --julia $(FILTER)

# 段階3 の道: いったん命令列(.tsb)に畳んでから走らせる。畳める形がまだ
# 限られているので、両方の道で同じ答えが出ることを確かめられるのは fib だけ。
# 増えたらここに足していく。
BIN = _build/default/bin/main.bc.wasm.js
test-vm: build
	@a=$$(node -r ./preload.js $(BIN) examples/fib.jl 2>/dev/null | head -1); \
	 b=$$(node -r ./preload.js $(BIN) --vm examples/fib.jl 2>/dev/null | head -1); \
	 if [ "$$a" = "$$b" ]; then echo "vm: fib matches the tree-walking answer"; \
	 else echo "vm: MISMATCH"; echo "  tree: $$a"; echo "  vm:   $$b"; exit 1; fi

# 渡す道を、端から端まで一度通す: ソース -> tsubakic -> .tsb -> dropvm。
# registry の build が通る道と、同じ二本です。ここが通るなら、drop にソースを
# 配らなくてよくなっている。
test-tsb: build
	@cp tools/tsb-host.js _build/default/bin/tsb-host.js
	@node _build/default/bin/tsubakic.bc.wasm.js _build/default/bin/fib.tsb examples/fib.jl 2>/dev/null
	@a=$$(node -r ./preload.js $(BIN) examples/fib.jl 2>/dev/null | head -1); \
	 b=$$(node -r ./preload.js _build/default/bin/tsb-host.js _build/default/bin/fib.tsb 2>/dev/null | head -1); \
	 if [ "$$a" = "$$b" ]; then echo "tsb: the parser-less build gives the same answer"; \
	 else echo "tsb: MISMATCH"; echo "  source: $$a"; echo "  .tsb:   $$b"; exit 1; fi

# Rust の VM(tsbvm/)を、tests の golden と突き合わせる。参照は OCaml のほう --
# 食い違ったら Rust が間違っている。まだ知らない形(builtin もふくめて)は
# 「まだ」として数えられるだけで、転ばない。
test-tsbvm: build
	cd tsbvm && cargo build --lib --target wasm32-unknown-unknown --release
	python3 tools/test.py --tsbvm $(FILTER)

clean:
	dune clean
	cd kernel && cargo clean
	cd physics && cargo clean

# Separate from `build` on purpose -- this targets a browser (WebGPU), not
# the Node/WasmGC path the rest of the Makefile drives. See gpu/src/lib.rs
# for why it's not just another export on the existing kernel module.
build-gpu:
	cd gpu && cargo build --target wasm32-unknown-unknown --release
	cd gpu && wasm-bindgen --target web --out-dir pkg target/wasm32-unknown-unknown/release/tsubaki_gpu.wasm

clean-gpu:
	cd gpu && cargo clean
	rm -rf gpu/pkg
