// Loaded via `node -r ./preload.js ...` so it runs, synchronously, before the
// actual entry script (main.bc.wasm.js) does -- that entry script resolves
// its own .assets directory from `require.main.filename`'s directory, which
// only works if it's the thing Node was actually launched with, not
// something require()'d from another script. Hence: preload + real entry
// point, instead of one wrapper script requiring the other.
"use strict";
const fs = require("fs");
const path = require("path");

const rustPath = path.join(
  __dirname,
  "kernel",
  "target",
  "wasm32-unknown-unknown",
  "release",
  "tsubaki_kernel.wasm"
);
const rustBytes = fs.readFileSync(rustPath);
// WebAssembly.Module/Instance (unlike WebAssembly.instantiate) are synchronous,
// which is what lets this run to completion inside a --require preload.
const rustModule = new WebAssembly.Module(rustBytes);
const rust = new WebAssembly.Instance(rustModule, {});
const {
  wasm_alloc,
  matvec,
  matmul,
  det,
  inverse,
  solve,
  matrix_rank,
  eigvals_symmetric,
  eigen_symmetric,
  eigen_general,
  lu,
  qr,
  cholesky,
  is_posdef,
  svd,
  svd_full_v,
  sparse_matvec,
  sparse_solve,
  pisum_native,
  run_bytecode,
  memory,
} = rust.exports;

globalThis.host_matvec = (aFlat, b, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const bPtr = wasm_alloc(n * 8);
  const outPtr = wasm_alloc(n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  new Float64Array(memory.buffer, bPtr, n).set(b);
  matvec(aPtr, bPtr, outPtr, n);
  const result = new Float64Array(n);
  result.set(new Float64Array(memory.buffer, outPtr, n));
  return result;
};

// General A(m x k) * B(k x n) -> C(m x n), row-major flat in/out -- the
// LinearAlgebra-compat entry point, unlike host_matvec above (square-only).
globalThis.host_matmul = (aFlat, bFlat, m, k, n) => {
  const aPtr = wasm_alloc(m * k * 8);
  const bPtr = wasm_alloc(k * n * 8);
  const outPtr = wasm_alloc(m * n * 8);
  new Float64Array(memory.buffer, aPtr, m * k).set(aFlat);
  new Float64Array(memory.buffer, bPtr, k * n).set(bFlat);
  matmul(aPtr, bPtr, outPtr, m, k, n);
  const result = new Float64Array(m * n);
  result.set(new Float64Array(memory.buffer, outPtr, m * n));
  return result;
};

// det(A) for a row-major n x n matrix -- a plain number back, no output buffer needed.
globalThis.host_det = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  return det(aPtr, n);
};

// inv(A) for a row-major n x n matrix -- returns the flat n*n inverse.
globalThis.host_inverse = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  inverse(aPtr, outPtr, n);
  const result = new Float64Array(n * n);
  result.set(new Float64Array(memory.buffer, outPtr, n * n));
  return result;
};

// A \ b : solves A*x = b for a row-major n x n A and length-n b.
globalThis.host_solve = (aFlat, b, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const bPtr = wasm_alloc(n * 8);
  const outPtr = wasm_alloc(n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  new Float64Array(memory.buffer, bPtr, n).set(b);
  solve(aPtr, bPtr, outPtr, n);
  const result = new Float64Array(n);
  result.set(new Float64Array(memory.buffer, outPtr, n));
  return result;
};

// rank(A) for a row-major m x n matrix -- a plain Int32 back.
globalThis.host_rank = (aFlat, m, n) => {
  const aPtr = wasm_alloc(m * n * 8);
  new Float64Array(memory.buffer, aPtr, m * n).set(aFlat);
  return matrix_rank(aPtr, m, n);
};

// eigvals(A) for a SYMMETRIC row-major n x n matrix -- the OCaml side
// already verified symmetry before calling this. Returns n eigenvalues,
// sorted nondecreasing.
globalThis.host_eigvals_symmetric = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outPtr = wasm_alloc(n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  eigvals_symmetric(aPtr, outPtr, n);
  const result = new Float64Array(n);
  result.set(new Float64Array(memory.buffer, outPtr, n));
  return result;
};

// eigen(A)/eigvecs(A) for a SYMMETRIC row-major n x n matrix -- returns
// [eigenvalues (n), eigenvectors (row-major n*n, columns are eigenvectors)].
globalThis.host_eigen_symmetric = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outValsPtr = wasm_alloc(n * 8);
  const outVecsPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  eigen_symmetric(aPtr, outValsPtr, outVecsPtr, n);
  const vals = new Float64Array(n);
  vals.set(new Float64Array(memory.buffer, outValsPtr, n));
  const vecs = new Float64Array(n * n);
  vecs.set(new Float64Array(memory.buffer, outVecsPtr, n * n));
  return [vals, vecs];
};

// lu(A) for a row-major n x n matrix -- returns [L (flat n*n), U (flat n*n),
// p (length n, 0-based; the OCaml side adds 1)].
globalThis.host_lu = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outLPtr = wasm_alloc(n * n * 8);
  const outUPtr = wasm_alloc(n * n * 8);
  const outPPtr = wasm_alloc(n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  lu(aPtr, outLPtr, outUPtr, outPPtr, n);
  const l = new Float64Array(n * n);
  l.set(new Float64Array(memory.buffer, outLPtr, n * n));
  const u = new Float64Array(n * n);
  u.set(new Float64Array(memory.buffer, outUPtr, n * n));
  const p = new Float64Array(n);
  p.set(new Float64Array(memory.buffer, outPPtr, n));
  return [l, u, p];
};

// qr(A) for a row-major m x n matrix -- thin/economy QR, k = min(m, n).
// Returns [Q (flat m*k), R (flat k*n)].
globalThis.host_qr = (aFlat, m, n) => {
  const k = Math.min(m, n);
  const aPtr = wasm_alloc(m * n * 8);
  const outQPtr = wasm_alloc(m * k * 8);
  const outRPtr = wasm_alloc(k * n * 8);
  new Float64Array(memory.buffer, aPtr, m * n).set(aFlat);
  qr(aPtr, outQPtr, outRPtr, m, n);
  const q = new Float64Array(m * k);
  q.set(new Float64Array(memory.buffer, outQPtr, m * k));
  const r = new Float64Array(k * n);
  r.set(new Float64Array(memory.buffer, outRPtr, k * n));
  return [q, r];
};

// cholesky(A) for a SYMMETRIC POSITIVE-DEFINITE row-major n x n matrix --
// returns the flat n*n lower-triangular L (A == L*L').
globalThis.host_cholesky = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outLPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  cholesky(aPtr, outLPtr, n);
  const l = new Float64Array(n * n);
  l.set(new Float64Array(memory.buffer, outLPtr, n * n));
  return l;
};

// isposdef(A) for a SYMMETRIC row-major n x n matrix -- 1/0, not a real
// Bool (there's no bool typed array to write into across the FFI boundary,
// same reasoning as every other flat-number convention here).
globalThis.host_is_posdef = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  return is_posdef(aPtr, n);
};

// Internal helper for `nullspace` only -- the FULL svd's V (flat n*n) plus
// S (length min(m, n)).
globalThis.host_svd_full_v = (aFlat, m, n) => {
  const k = Math.min(m, n);
  const aPtr = wasm_alloc(m * n * 8);
  const outVPtr = wasm_alloc(n * n * 8);
  const outSPtr = wasm_alloc(k * 8);
  new Float64Array(memory.buffer, aPtr, m * n).set(aFlat);
  svd_full_v(aPtr, outVPtr, outSPtr, m, n);
  const v = new Float64Array(n * n);
  v.set(new Float64Array(memory.buffer, outVPtr, n * n));
  const s = new Float64Array(k);
  s.set(new Float64Array(memory.buffer, outSPtr, k));
  return [v, s];
};

// svd(A) for a row-major m x n matrix -- thin SVD, k = min(m, n). Returns
// [U (flat m*k), S (length k), V (flat n*k, NOT V transpose)].
globalThis.host_svd = (aFlat, m, n) => {
  const k = Math.min(m, n);
  const aPtr = wasm_alloc(m * n * 8);
  const outUPtr = wasm_alloc(m * k * 8);
  const outSPtr = wasm_alloc(k * 8);
  const outVPtr = wasm_alloc(n * k * 8);
  new Float64Array(memory.buffer, aPtr, m * n).set(aFlat);
  svd(aPtr, outUPtr, outSPtr, outVPtr, m, n);
  const u = new Float64Array(m * k);
  u.set(new Float64Array(memory.buffer, outUPtr, m * k));
  const s = new Float64Array(k);
  s.set(new Float64Array(memory.buffer, outSPtr, k));
  const v = new Float64Array(n * k);
  v.set(new Float64Array(memory.buffer, outVPtr, n * k));
  return [u, s, v];
};

// eigen(A)/eigvals(A)/eigvecs(A) for a GENERAL (possibly non-symmetric)
// row-major n x n matrix -- returns [valsRe, valsIm (each length n),
// vecsRe, vecsIm (each flat row-major n*n)].
globalThis.host_eigen_general = (aFlat, n) => {
  const aPtr = wasm_alloc(n * n * 8);
  const outValsRePtr = wasm_alloc(n * 8);
  const outValsImPtr = wasm_alloc(n * 8);
  const outVecsRePtr = wasm_alloc(n * n * 8);
  const outVecsImPtr = wasm_alloc(n * n * 8);
  new Float64Array(memory.buffer, aPtr, n * n).set(aFlat);
  eigen_general(aPtr, outValsRePtr, outValsImPtr, outVecsRePtr, outVecsImPtr, n);
  const valsRe = new Float64Array(n);
  valsRe.set(new Float64Array(memory.buffer, outValsRePtr, n));
  const valsIm = new Float64Array(n);
  valsIm.set(new Float64Array(memory.buffer, outValsImPtr, n));
  const vecsRe = new Float64Array(n * n);
  vecsRe.set(new Float64Array(memory.buffer, outVecsRePtr, n * n));
  const vecsIm = new Float64Array(n * n);
  vecsIm.set(new Float64Array(memory.buffer, outVecsImPtr, n * n));
  return [valsRe, valsIm, vecsRe, vecsIm];
};

// Sparse A(m x n, COO/triplet) * x(n) -> y(m).
globalThis.host_sparse_matvec = (rowIdx, colIdx, vals, nnz, m, n, x) => {
  const rowPtr = wasm_alloc(nnz * 4);
  const colPtr = wasm_alloc(nnz * 4);
  const valPtr = wasm_alloc(nnz * 8);
  const xPtr = wasm_alloc(n * 8);
  const outPtr = wasm_alloc(m * 8);
  new Int32Array(memory.buffer, rowPtr, nnz).set(rowIdx);
  new Int32Array(memory.buffer, colPtr, nnz).set(colIdx);
  new Float64Array(memory.buffer, valPtr, nnz).set(vals);
  new Float64Array(memory.buffer, xPtr, n).set(x);
  sparse_matvec(rowPtr, colPtr, valPtr, nnz, m, n, xPtr, outPtr);
  const y = new Float64Array(m);
  y.set(new Float64Array(memory.buffer, outPtr, m));
  return y;
};

// Sparse A(n x n, COO/triplet) \ b(n) -> x(n).
globalThis.host_sparse_solve = (rowIdx, colIdx, vals, nnz, n, b) => {
  const rowPtr = wasm_alloc(nnz * 4);
  const colPtr = wasm_alloc(nnz * 4);
  const valPtr = wasm_alloc(nnz * 8);
  const bPtr = wasm_alloc(n * 8);
  const outPtr = wasm_alloc(n * 8);
  new Int32Array(memory.buffer, rowPtr, nnz).set(rowIdx);
  new Int32Array(memory.buffer, colPtr, nnz).set(colIdx);
  new Float64Array(memory.buffer, valPtr, nnz).set(vals);
  new Float64Array(memory.buffer, bPtr, n).set(b);
  sparse_solve(rowPtr, colPtr, valPtr, nnz, n, bPtr, outPtr);
  const x = new Float64Array(n);
  x.set(new Float64Array(memory.buffer, outPtr, n));
  return x;
};

// Experiment only -- see ROADMAP.md and the AST-in-Rust report next to it.
globalThis.host_pisum_native = () => pisum_native();

// The real mechanism the pisum_native experiment led to -- see Compile in
// bin/main.ml. `code` is the flat f64-encoded bytecode array; returns
// [tag, value] (0=Int/1=Float/2=Bool), left for the OCaml side to turn
// back into a real Runtime.value.
globalThis.host_run_bytecode = (code, nslots) => {
  const codePtr = wasm_alloc(code.length * 8);
  const outTagPtr = wasm_alloc(8);
  const outValPtr = wasm_alloc(8);
  new Float64Array(memory.buffer, codePtr, code.length).set(code);
  run_bytecode(codePtr, code.length, nslots, outTagPtr, outValPtr);
  const tag = new Float64Array(memory.buffer, outTagPtr, 1)[0];
  const value = new Float64Array(memory.buffer, outValPtr, 1)[0];
  return [tag, value];
};

// ============================================================================
// physics/ -- a SEPARATE wasm module from the kernel one above (its own
// memory, its own wasm_alloc), loaded the exact same synchronous way. Unlike
// kernel/, this same .wasm ALSO gets fetched (not read from disk) by
// web/demo.html, since physics/ has no web-sys/DOM dependency and needed no
// wasm-bindgen step -- see bin/physicsBridge.ml for the Tsubaki-facing side.
const physicsPath = path.join(
  __dirname,
  "physics",
  "target",
  "wasm32-unknown-unknown",
  "release",
  "tsubaki_physics.wasm"
);
const physicsBytes = fs.readFileSync(physicsPath);
const physicsModule = new WebAssembly.Module(physicsBytes);
const physics = new WebAssembly.Instance(physicsModule, {});
const {
  wasm_alloc: physics_alloc,
  physics_world_new,
  physics_add_circle,
  physics_add_box,
  physics_set_velocity,
  physics_remove,
  physics_body_count,
  physics_step,
  physics_get_bodies,
  memory: physicsMemory,
} = physics.exports;

globalThis.host_physics_world_new = (gx, gy) => physics_world_new(gx, gy);

globalThis.host_physics_add_circle = (world, x, y, vx, vy, radius, mass, restitution) =>
  physics_add_circle(world, x, y, vx, vy, radius, mass, restitution);

globalThis.host_physics_add_box = (world, x, y, vx, vy, hw, hh, mass, restitution) =>
  physics_add_box(world, x, y, vx, vy, hw, hh, mass, restitution);

globalThis.host_physics_set_velocity = (world, body, vx, vy) => physics_set_velocity(world, body, vx, vy);

globalThis.host_physics_remove = (world, body) => physics_remove(world, body);

globalThis.host_physics_body_count = (world) => physics_body_count(world);

// Tsubaki's `include("other.jl")` -- read a source file synchronously. Node has a
// real filesystem, so this is just fs; web/demo.html backs the same host name
// with a synchronous XHR instead. Eval resolves the path before calling.
globalThis.host_read_file = (path) => fs.readFileSync(path, "utf8");

// One line from stdin, synchronously, for the REPL (bin/repl.ml). Returns
// null at end of input (Ctrl-D), which is how the REPL knows to stop.
//
// Synchronous on purpose: the interpreter is an ordinary recursive OCaml
// function with no way to await a callback, and readline's async API would
// mean restructuring the whole read-eval-print loop around it. So: read one
// byte at a time off fd 0 until a newline. Slow per byte and entirely
// irrelevant at human typing speed. EAGAIN can come back from a terminal
// that has nothing typed yet -- that is not end of input, so it retries.
// Bytes are collected raw and decoded only at the newline: decoding each byte
// on its own would mangle every multi-byte character, and Tsubaki source has
// real ones in it (`÷`, `⊻`, `⋅`, and anything inside a string literal).
const stdinByte = Buffer.alloc(1);
globalThis.host_read_line = () => {
  const bytes = [];
  for (;;) {
    let n;
    try {
      n = fs.readSync(0, stdinByte, 0, 1, null);
    } catch (e) {
      if (e.code === "EAGAIN") continue;
      if (e.code === "EOF") return bytes.length ? Buffer.from(bytes).toString("utf8") : null;
      throw e;
    }
    if (n === 0) return bytes.length ? Buffer.from(bytes).toString("utf8") : null; // Ctrl-D
    if (stdinByte[0] === 0x0a) return Buffer.from(bytes).toString("utf8");
    if (stdinByte[0] !== 0x0d) bytes.push(stdinByte[0]);
  }
};

globalThis.host_physics_step = (world, dt) => physics_step(world, dt);

// n = body count (bin/physicsBridge.ml gets it from host_physics_body_count,
// since the free list means it can't just count adds) -- [x,y,vx,vy] per body.
globalThis.host_physics_get_bodies = (world, n) => {
  const outPtr = physics_alloc(n * 4 * 8);
  physics_get_bodies(world, outPtr);
  const result = new Float64Array(n * 4);
  result.set(new Float64Array(physicsMemory.buffer, outPtr, n * 4));
  return result;
};

// ============================================================================
// gpuBridge.ml's fixed-function 2D API (clear_screen/draw_rect(s)/key_down/
// mouse_x/mouse_y) has no Node-side host at all otherwise -- these exist only
// so a script's on_frame() body can run under plain `node -r ./preload.js`
// (see bin/main.ml's `--frames N` headless mode) without crashing on an
// undefined host_gpu_*/host_key_down/host_mouse_* global. Draws become
// no-ops, input reads a fixed idle state (nothing held, mouse at origin) --
// enough to exercise a frame's LOGIC, not to see any pixels.
globalThis.host_gpu_clear = () => {};
globalThis.host_gpu_draw_rect = () => {};
globalThis.host_gpu_draw_rects = () => {};
globalThis.host_key_down = () => false;
globalThis.host_mouse_x = () => 0;
globalThis.host_mouse_y = () => 0;
globalThis.host_mouse_down = () => false;

// play_tone(freq, dur; volume, wave)'s host side (bin/audioBridge.ml) -- the
// Web Audio API has no Node equivalent, so a beep is a silent no-op here, the
// same posture as the draw_* stubs above. It has to EXIST, though, and this is
// not a cosmetic point: a `beep()` on a hit used to kill the whole frame, so
// everything AFTER the beep in that frame -- the despawn!, the score bump --
// silently didn't happen, and only that frame's error line said so.
globalThis.host_audio_tone = () => {};

// get_data(name)/put_data(name, data)'s host side (bin/gpuBridge.ml) -- a
// real embedding page defines these itself to hand back live data by name,
// and to actually keep whatever a script saves; under this headless CLI
// there's no such page, so every get_data reads as empty and every put_data
// is silently discarded rather than crashing.
globalThis.host_get_data = () => [];
globalThis.host_put_data = () => {};

// text_texture(text,font,size)/draw_texture(...)'s host side (real-font
// rendering via Canvas2D + a texture upload, see web/text-demo.html) --
// no OffscreenCanvas/WebGPU under this headless CLI, so text_texture hands
// back a dummy 1x1 handle/size and draw_texture is a no-op, same posture as
// the other draw_* stubs above.
globalThis.host_text_texture = () => [0, 1, 1];
globalThis.host_gpu_draw_texture = () => {};

// ===================== the worker pool ======================================
// What bin/parallelBridge.ml calls to get more than one core. The cores have to
// come from here: wasm_of_ocaml has no threads (Domain.spawn runs sequentially,
// measured), so each "thread" is a Node worker_thread running its own instance
// of this very same main.bc.wasm.js, over the very same script.
//
// No component data is ever sent between them. A column is a Bigarray, which
// under wasm_of_ocaml IS a JS typed array -- allocated here, on a
// SharedArrayBuffer, so main and every worker address the same bytes. All that
// crosses a port is the job (a function name and a range) and, when storage has
// been reallocated, the typed-array views themselves (a structured clone of a
// SAB-backed view shares the buffer; it does not copy it).
const { Worker, isMainThread, workerData, receiveMessageOnPort, MessageChannel } = require("worker_threads");
const os = require("os");

// The .jl this process was asked to run -- read the way bin/main.ml's own CLI
// reads it (flags in any order, the one non-flag argument is the script), NOT
// as a fixed process.argv[2]. A worker is another instance of this same entry
// point over the same script, so getting this wrong doesn't fail loudly: it
// starts a worker on the wrong file, and main then waits forever for a worker
// that already died. (`node ... --frames 600 game.jl` is exactly the shape
// that used to hand a worker the string "--frames".)
const scriptArg = () => {
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--frames") { i++; continue; }   // skip the flag AND its value
    if (!args[i].startsWith("-")) return args[i];
  }
  return undefined;
};

globalThis.host_shared_f64 = (n) => new Float64Array(new SharedArrayBuffer(n * 8));
globalThis.host_shared_u8 = (n) => new Uint8Array(new SharedArrayBuffer(n));
globalThis.host_is_worker = () => !isMainThread;

// ctrl[0]: job sequence number -- workers park on this and wake when it moves.
// ctrl[1]: how many workers are still running the current job (counts down to 0).
const CTRL_SEQ = 0, CTRL_LEFT = 1;

if (isMainThread) {
  let workers = [], ports = [], ctrl = null, seq = 0;
  let bindPayload = null, bindGen = 0, sentGen = [];

  globalThis.host_pool_start = () => {
    if (workers.length) return workers.length;
    const n = Math.max(1, parseInt(process.env.TSUBAKI_WORKERS || "", 10) || Math.min(4, (os.availableParallelism?.() ?? os.cpus().length) - 1));
    ctrl = new Int32Array(new SharedArrayBuffer(8));
    const script = scriptArg();       // the .jl the main instance is running -- a worker runs the same one
    const entry = process.argv[1];    // main.bc.wasm.js itself -- a worker is another instance of it
    for (let i = 0; i < n; i++) {
      const { port1, port2 } = new MessageChannel();
      const w = new Worker(entry, {
        execArgv: ["-r", __filename],
        argv: [script],
        workerData: { ctrl, port: port2 },
        transferList: [port2],
        stdout: false, stderr: false,
      });
      w.unref();                       // a parked worker must not keep the process alive
      workers.push(w); ports.push(port1); sentGen.push(-1);
    }
    return n;
  };

  globalThis.host_pool_bind = (tables, alive) => { bindPayload = { tables, alive }; bindGen++; };

  globalThis.host_pool_run = (fn, n, kinds) => {
    const W = workers.length;
    Atomics.store(ctrl, CTRL_LEFT, W);
    for (let w = 0; w < W; w++) {
      const lo = Math.floor((n * w) / W), hi = Math.floor((n * (w + 1)) / W);
      const bind = sentGen[w] !== bindGen ? bindPayload : null;
      sentGen[w] = bindGen;
      ports[w].postMessage({ gen: bindGen, fn, lo, hi, kinds, bind });
    }
    Atomics.store(ctrl, CTRL_SEQ, ++seq);
    Atomics.notify(ctrl, CTRL_SEQ);
    let left;
    while ((left = Atomics.load(ctrl, CTRL_LEFT)) > 0) Atomics.wait(ctrl, CTRL_LEFT, left);
    // whatever a worker's system threw comes back here, synchronously, so
    // parallel_each can raise it on the main thread like any other Tsubaki error
    const errs = [];
    for (let w = 0; w < W; w++) {
      let m;
      while ((m = receiveMessageOnPort(ports[w]))) if (m.message && m.message.err) errs.push(m.message.err);
    }
    return errs;
  };
} else {
  const ctrl = workerData.ctrl, port = workerData.port;
  let lastSeq = 0, stash = null;

  globalThis.host_worker_wait = () => {
    Atomics.wait(ctrl, CTRL_SEQ, lastSeq);          // parks this thread until main hands out a job
    lastSeq = Atomics.load(ctrl, CTRL_SEQ);
    // the job was posted before the sequence number moved, but a port's queue is
    // filled by the event loop we are NOT running, so it can arrive a hair late
    let msg;
    while (!(msg = receiveMessageOnPort(port))) {}
    const job = msg.message;
    if (job.bind) stash = job.bind;
    return { stop: false, gen: job.gen, fn: job.fn, lo: job.lo, hi: job.hi, kinds: job.kinds };
  };

  globalThis.host_worker_columns = () => stash;

  globalThis.host_worker_done = (err) => {
    if (err) port.postMessage({ err: String(err) });   // posted BEFORE the countdown, so main sees it after the barrier
    Atomics.sub(ctrl, CTRL_LEFT, 1);
    Atomics.notify(ctrl, CTRL_LEFT);
  };
}
