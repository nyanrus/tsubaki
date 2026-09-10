.PHONY: build run repl test test-julia test-tsbvm check-doors clean build-gpu clean-gpu

# 三本建つ。main は CLI/REPL と橋を全部つれてくる開発用、drop は drop に積む
# ほう(actor の戸だけ)、tsubakic は .tsubaki を .tsb に畳むだけの道具。
# 走らせるのは Rust の VM(tsbvm/) -- OCaml の側は、もう畳むところまで。
# 何がどちらに行くかは bin/dune。
build:
	dune build ./bin/main.bc.wasm.js ./bin/drop.bc.wasm.js \
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

# Rust の VM(tsbvm/)を、本物の Julia と突き合わせる。基準は Julia -- 食い違ったら
# こちらが間違っている。まだ知らない形(builtin もふくめて)は「まだ」として
# 数えられるだけで、転ばない。julia が PATH に要る。
test-tsbvm: build
	cd tsbvm && cargo build --lib --target wasm32-unknown-unknown --release
	python3 tools/test.py --tsbvm $(FILTER)

# drop に積む build に、外へ出る戸(jsglobal / tojs / include)が残っていないか。
# 消したことを覚えているのがコメントだけ、では、また戻ってくる。
check-doors: build
	node tools/drop-doors.cjs

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
