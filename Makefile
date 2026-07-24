.PHONY: build run clean build-gpu clean-gpu

build:
	dune build ./bin/main.bc.wasm.js --profile release
	cd kernel && cargo build --target wasm32-unknown-unknown --release
	cd physics && cargo build --target wasm32-unknown-unknown --release

run: build
	node -r ./preload.js _build/default/bin/main.bc.wasm.js $(FILE)

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
