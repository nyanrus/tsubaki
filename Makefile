.PHONY: build run repl test test-julia clean build-gpu clean-gpu

build:
	dune build ./bin/main.bc.wasm.js --profile release
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
