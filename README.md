# Tsubaki

A toy Julia-like language, hosted in OCaml, compiled to WebAssembly via
[`wasm_of_ocaml`](https://ocsigen.org/js_of_ocaml/latest/manual/wasm_overview) (real WasmGC,
not a linear-memory emulation of one). Its numeric kernel calls out across a
wasm module boundary into [`faer`](https://github.com/sarah-quinones/faer), a
pure-Rust linear algebra library (no BLAS/LAPACK, no C, no Fortran), compiled
separately to `wasm32-unknown-unknown` (plain linear memory, no GC needed).

It exists to answer one question honestly: how much of Julia's actual
semantics — multiple dispatch, a real abstract-type hierarchy, structs,
closures, keyword arguments — can a small, hand-written interpreter cover, and
how does building that in OCaml compare to building the same thing in
JavaScript. (Short version: the type system's exhaustiveness checking catches
every place a new value variant needs handling, at compile time, by name.
JavaScript's `switch` has no idea the space of tags is closed, so the same
mistake surfaces later, at runtime, in an unrelated-looking stack trace.)

This is not a serious Julia implementation. Treat it as a demo of what's
*reachable* in an afternoon-scale project, not as a foundation to build on
without expecting to rewrite large parts of it. Everything documented here was
verified by actually running it — the embedded demo, a real benchmark, or a
real headless-browser harness — not by reading the code.

## Benchmarked against real Julia's own microbenchmark suite

`examples/` holds four benchmarks with their algorithm bodies taken verbatim
from [JuliaLang/Microbenchmarks](https://github.com/JuliaLang/Microbenchmarks/blob/master/julia/perf.jl)
(only the `@test`/`@timeit` macro harness is swapped for plain Tsubaki code) —
real code Julia's own team uses, not code written to flatter this interpreter.
All four produce the same answer as real Julia; none are fast.

| Benchmark | no cache | fully optimized | real Julia (1.12.6) | slowdown |
|---|---|---|---|---|
| `fib(20)` (recursive) | 0.128 s | 0.006 s | 0.00023 s | ~25× |
| `qsort!` 5,000 floats | 0.489 s | 0.027 s | 0.00049 s | ~56× |
| `pisum` (5,000,000 float divisions) | 29.8 s | 0.80 s | 0.0032 s | ~250× |
| `mandelperf` (complex-plane sweep, `maxiter=80`) | — | 0.013 s | 0.00026 s | ~50× |

The honesty practice behind those numbers, in short:

- **A regression suite where two thirds of it runs under real Julia too.**
  `make test` runs every `tests/*.jl` against its recorded output; `make
  test-julia` additionally feeds each test marked `# julia: yes` to real
  Julia 1.12.5 and requires *the same golden file* to match both. So "this
  behaves like Julia" is not a claim about 13 of the 20 tests — it is a
  second execution. Writing them turned up real divergences on the first
  pass: `3x^2` parsing as `(3x)^2` where Julia says `3*(x^2)`, `round(2.5)`
  rounding away from zero where Julia rounds to even, `==` answering for
  numbers and nothing else (`true == true` was a `MethodError`), and a
  factory function handing back the *same* closure twice over rather than
  two independent ones. Where Tsubaki still differs on purpose, the difference
  itself is a test: [`tests/known_gaps.jl`](tests/known_gaps.jl) pins the
  current behavior of each, with real Julia's answer written beside it, so
  closing one fails the suite instead of passing unnoticed.
- **Values are printed, not approximated.** A float shows the shortest
  decimal that reads back as the same float, and switches to scientific
  notation on real Julia's own thresholds. That sounds cosmetic and wasn't:
  the previous fixed `%.3f` printed `1.5e-8` as `0.000`, `-0.0` as `0.000`,
  and this file's own `pisum` benchmark as `1.645` — while the text beside
  it claimed agreement with Julia's `1.6449340668`, true and unverifiable
  from the output. It now prints `1.6448340718480652`, and
  `tests/benchmarks.jl` checks that digit for digit against real Julia.
- **Bugs found by running real code, not synthetic demos.** Every feature had
  its own passing hand-written demo; the benchmarks (and later, unmodified
  real package source) broke in ways those demos never did — a missing `>>>`
  operator, destructuring that only accepted bare names, and a real scoping
  bug where every "local" was secretly one shared global (found because
  quicksort is recursive and actually exercises it).
- **Eleven optimizations, applied in order, each measured** — inline caches
  for `EBinOp`/`ECall`, assoc-list scopes, allocation-free cache hits,
  variable-depth caches, identifier interning, physical-equality tag
  comparison — plus a real static-analysis phase (`Resolve`) that computes
  variable depths once before execution. Several were found by `node --prof`,
  not by guessing: the dominant cost turned out to be variable-name lookup,
  not dispatch, and allocation was never the bottleneck the earlier reasoning
  assumed. None change any dynamic behavior (bit-for-bit identical output
  before and after each).
- **Tested against real, unmodified package source.** `JuliaLang/Example.jl`
  (the official minimal template) runs correctly, verbatim. `DataStructures.jl`'s
  `deque.jl` and the 1057-line `JuliaMath/Primes.jl` drove many rounds of
  fixes, each found by nothing more than re-running the exact file (triple-
  quoted docstrings, `export`, inner constructors, `where` clauses, bitwise
  ops, first-class type values for `::Type{X}` dispatch, …). Where the line
  falls is an honest snapshot, found by testing, not guessed at.
- **A second execution path.** A zero-parameter function whose entire body is
  restricted-numeric gets JIT-compiled (the first time it's evaluated, cached
  per declaration site) into a small bytecode ISA run by a second interpreter
  in the Rust kernel, with superinstruction fusion. ~6.6× faster than the
  tree-walker on the unmodified `pisum()`; anything outside the subset falls
  back to tree-walking, unchanged. Full story:
  [`AST_IN_RUST_EXPERIMENT.md`](AST_IN_RUST_EXPERIMENT.md).

## Build & run

Requires: OCaml + dune + `wasm_of_ocaml-compiler` (opam), Rust + the
`wasm32-unknown-unknown` target (rustup), Node.js 22+ (needs WasmGC, default
from Node 22 on).

```sh
make repl                      # an interactive prompt
make run                       # runs bin/main.ml's embedded demo program
make run FILE=path/to/prog.jl  # runs that file instead
make test                      # every tests/*.jl against its recorded output
make test-julia                # ...and the julia-compatible ones under real Julia too
```

The REPL (`--repl`) keeps its state from one line to the next, reads a
declaration that spans several lines until the last `end` closes it, prints
what an expression came to (a trailing `;` keeps it quiet, same as real
Julia), and survives every error — a `MethodError` at one prompt leaves
everything defined so far still defined:

```
tsubaki> function square(n)
      ..     return n * n
      .. end
tsubaki> square(7)
49
tsubaki> square("nope", 2)
ERROR: MethodError: no method matching square(String, Int)
tsubaki> square(7)
49
```

A real `.jl`-style file works too:
`node -r ./preload.js _build/default/bin/main.bc.wasm.js path/to/prog.jl`
(paths resolve relative to wherever `node` was launched from). With no path,
it falls back to the fixed demo at the bottom of `bin/main.ml`.

`include("other.jl")` reads a sibling file and runs it right there, resolving
its argument against the *including file's* directory the way real Julia
does — so a program can be several files, and `examples/keel_bounce.jl` finds
`examples/keel.jl` no matter where the process was started from.

### Where an error happened

A runtime error carries its place: the file and line of the statement that
raised it, then the calls that led there, innermost first. Parse errors have
had line/column all along, and `parse_stmt_list` recovers across statements —
one pass reports every independent mistake, each with its own line/col (it
still won't *run* with any errors, only diagnoses better).

```
$ make run FILE=tests/errors_position.jl
about to fail
tsubaki: Int is not a struct, has no fields
  at tests/errors_position.jl:10
  in:
    boom, called from line 14
    middle, called from line 18
    outer, called from line 29
```

The position rides along as a marker statement the parser puts in front of
every statement ([`bin/ast.ml`](bin/ast.ml)'s `SLine`) rather than as a field
on every AST node — see that comment for why, and `Compile.strip_lines` for
how the bytecode compiler goes on seeing exactly the statement lists it saw
before. A *caught* error is untouched by any of this — `catch e` still binds
the same bare value it did before, with no position glued onto its message.

**What it costs, measured.** Between 1.5% and 7%, depending on how much of a
program is calls: `pisum` +1.5%, `qsort!` +2.7%, `mandelperf` +4.3%, and
`fib(25)` — which is nothing *but* calls — +6.8% (0.1036 s → 0.1107 s, mean of
eight runs each). Two earlier versions cost considerably more and were thrown
away rather than shipped:

- a traceback frame as a `(name, line)` cons cell allocated two blocks on
  every call: **+14% on `fib(25)`**. Now two parallel growable arrays, an
  index, and a real list built only where an error actually reads one.
- unwinding the position carefully on the way out, which meant an exception
  handler installed on every call. Now nothing unwinds at all: a raised error
  deliberately leaves the position and the frames exactly where it happened —
  which is precisely what the report wants to read — and whoever *catches* it
  puts them back (`STry`, or the top level). One save per `try` instead of one
  handler per call.

The first number was only found because the original measurement compared
against a build whose own float display was `%.3f`, which had nowhere near
the resolution to show it.

Functions declared in an `include`d file report their own file, not the
caller's, because a function captures the file it was written in the same way
it already captured its module.

`--frames N` runs a program's `on_frame` callback N times headlessly (fixed
1/60s dt, no browser) — enough to exercise a frame's *logic* with no pixels.
The draw/input/audio host functions are stubbed by `preload.js`; a frame that
*raises* stops the run with a non-zero exit code. Flags may come before or
after the path, and an unrecognized argument is an error (it used to match no
shape at all and quietly run the built-in demo instead).

`make build` alone produces `_build/default/bin/main.bc.wasm.js` (OCaml side,
real WasmGC) and `kernel/target/.../tsubaki_kernel.wasm` (Rust side, plain
linear memory). `preload.js` wires them together — see the comment at its top
for why it's a separate `--require` preload (short version: `wasm_of_ocaml`'s
loader resolves its `.assets/` dir from `require.main.filename`).

## Browser GPU compute (wgpu)

`gpu/` is a second, independent Rust crate (`tsubaki-gpu`) exposing WebGPU to the
browser, aimed at GPU-accelerated visualizations (N-body, wave equations,
Julia/Mandelbrot sets — anything embarrassingly parallel over a buffer) from a
page that also hosts Tsubaki.

It is deliberately not part of `kernel/`. That module is raw linear memory,
loaded synchronously with zero imports. wgpu's web backend can't be that:
adapter/device requests and buffer readback are all async Promise calls, which
only work through `wasm-bindgen` (JS glue, `Promise`-returning exports, an
`externref` table) — a different-shaped wasm module. So `gpu/` is its own crate
with its own build step.

The API is a small resource-handle model (buffers/pipelines are opaque `u32`
handles the caller creates and destroys explicitly), so a toy gets real control
over shape and lifetime. See `gpu/src/lib.rs` for full per-function docs;
summary:

- `await gpu_init(powerPreference?, canvas?)` — requests a GPU adapter+device
  once (`"low-power"` / `"high-performance"` / omitted). Returns what the
  browser actually granted (`{name, backend, deviceType, driver}`). Prefers
  real WebGPU but transparently falls back to WebGL2 where WebGPU isn't
  available (Safari without the flag, older browsers, some headless/CI), via
  wgpu's `new_instance_with_webgpu_detection` (which actually probes
  `requestAdapter()`, not just `navigator.gpu`'s presence). `canvas` is
  optional and only needed for that fallback — a browser WebGL context is
  intrinsically tied to a canvas, so a canvas-less `gpu_init` can only ever
  land on WebGPU. **Disclosed**: WebGL2 has no compute stage at all (so
  compute fails cleanly at device-request time on a GL adapter), and the two
  backends can pick different default surface formats, so the same draw can
  render at a visibly different brightness across WebGPU vs. WebGL2 — shape/
  interpolation correct, just not pixel-identical.
- `create_buffer(sizeBytes, kind)` → handle — `kind` is `"storage-read"` /
  `"storage-read-write"` / `"uniform"`. `write_buffer(handle, f32Array)`
  (sync) and `await read_buffer(handle)` (async — WebGPU readback always is)
  round-trip data. `destroy_buffer(handle)` releases it.
- `await create_pipeline(wgsl, entryPoint, bindingKinds)` → handle — compiles
  a `@compute fn <entryPoint>` shader, one binding per `bindingKinds[i]`
  (`"storage-read"` / `"storage-read-write"` / `"uniform"` / `"texture"` /
  `"sampler"`, in `@binding` order). Content-hash cached — calling it every
  frame with the same shader returns the cached handle. `destroy_pipeline`.
- `dispatch(pipelineHandle, resourceHandles, wgX, wgY, wgZ)` — sync, binds
  `resourceHandles[i]` at `@binding(i)` (each resolved to buffer/texture/
  sampler automatically) and submits one compute pass. Cheap per frame.
- `await gpu_on_device_lost()` — resolves once on device loss; `gpu_init`
  again to recover. `gpu_shutdown()` — drops everything deterministically.

**Rendering to a canvas** is the same handle model, one resource deeper:

- `configure_canvas(canvasElement, width, height, alphaMode)` — creates and
  configures a `wgpu::Surface` using whatever format/present-mode the adapter
  reports (via `get_capabilities`, never assumed). `alphaMode` is `"opaque"`
  or `"premultiplied"` (genuinely composites with the page behind), checked
  against what the browser actually supports — asking for one it doesn't is a
  real error. For `"premultiplied"`, pair with `"premultiplied-alpha"` blend
  and premultiply your own colors.
- `await create_render_pipeline(wgsl, vertexEntry, fragmentEntry,
  bindingKinds, topology, blend)` → handle — same shape as `create_pipeline`,
  for a `@vertex`+`@fragment` pair. No vertex-buffer layout at all (geometry
  off `@builtin(vertex_index)`). `topology` is `"triangle-list"` /
  `"triangle-strip"` / `"line-list"` / `"line-strip"` / `"point-list"`;
  `blend` is `"replace"` / `"alpha"` / `"premultiplied-alpha"`.
  `destroy_render_pipeline`.
- `begin_frame(r,g,b,a)` / `draw_frame(pipeline, resources, vertexCount,
  instanceCount)` / `end_frame()` compose one frame from several draws: each
  `draw_frame` LOADS (never re-clears) the same texture, so a curve, points,
  and labels layer onto one frame instead of each wiping the last.
- `create_texture(width, height, rgbaBytes)` → handle (uploads raw RGBA8, e.g.
  straight from a 2-D canvas' `getImageData().data`) + `destroy_texture`;
  `create_sampler("nearest"|"linear")` → handle (clamp-to-edge) +
  `destroy_sampler`. Bind either with kind `"texture"` / `"sampler"`.

Build with `make build-gpu` (needs `wasm-bindgen-cli`, version-matched to the
`wasm-bindgen` crate — a mismatch fails loudly). Produces `gpu/pkg/tsubaki_gpu.js`
+ `.wasm`, loadable from any page. Three test pages
(`gpu/{test,render-test,text-test}.html`) each verify real output (read-back
pixels + screenshots), run against real Chrome headless via `puppeteer-core` —
none is "it compiled." The caller always supplies the shader text; the crate
ships no WGSL of its own.

**Disclosed limits.** Only f32 (WGSL/WebGPU has no `f64`; a Tsubaki-side caller
narrows/widens at the boundary). WebGPU's own error-reporting mechanisms
(error scopes, `on_uncaptured_error`) both route through a wgpu-30 conversion
that *panics* on any error class beyond Validation/OOM (headless Chrome
reports `GPUInternalError`), so neither is used — `create_pipeline` catches
shader-source errors via `ShaderModule::get_compilation_info()` instead;
later-stage errors (a bind-group layout not matching the shader) still have no
safe catchable path.

### Reachable from real Tsubaki source now, no `await` keyword needed

The API above is genuinely async, and `Eval.eval` is a plain synchronous
recursive function — calling one of these from a Tsubaki builtin needs the whole
interpreter call stack to suspend and resume. `bin/async.ml` performs an OCaml
5 effect (`AwaitJs`) at the `await` point inside a builtin (see
`bin/gpuBridge.ml`), with an `Effect.Deep` handler around both entry points
(`Eval.run`, `GpuBridge.run_frame`). From a Tsubaki script's own point of view,
`gpu_init()` reads and behaves like any other synchronous call:

```julia
info = gpu_init("high-performance")
buf_in = create_buffer(32, "storage-read")
buf_out = create_buffer(16, "storage-read-write")
write_buffer(buf_in, [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
pipeline = create_pipeline(wgsl_source, "main", ["storage-read", "storage-read-write"])
dispatch(pipeline, [buf_in, buf_out], 1, 1, 1)
result = read_buffer(buf_out)  # suspends & resumes transparently
```

`bin/dune` builds with `--effects=cps` (whole-program CPS), not the default
`--effects=jspi` (which needs the runtime's JS Promise Integration, absent
under plain `node`). Cost: a mostly-fixed per-run overhead (~2.8–3× on the
three short benchmarks, ~1.08× on `pisum`, which amortizes it over 5,000,000
iterations). A rejected Promise resumes with `discontinue k (Failure msg)` —
the exact exception a script's `try/catch` already catches. Verified end to
end in headless Chrome via `examples/gpu_reduce.jl` +
`web/gpu-compute-demo.html`.

**ECS SoA storage feeds this directly.** A component struct with all-`::Float`
fields and no `mutable` gets stored columnar (`Runtime.soa_eligible`);
`soa_flatten(kind, fields)` reads its whole live column set into a flat Vector
in one OCaml pass (~53× faster than a per-entity interpreter loop), ready for
`write_buffer`. `draw_frame`'s `instance_count` draws N entities from one call
(a WGSL vertex shader indexing a storage buffer by `@builtin(instance_index)`);
a camera transform is just a small uniform the vertex shader reads. Examples:
`ecs_gpu_soa_reduce.jl` / `ecs_gpu_instanced.jl` / `ecs_gpu_camera.jl`, each
verified in headless Chrome. `offset_xy(vec, dx, dy)` rebases large-magnitude
world coordinates onto a local origin before the f32 narrowing loses bits.

### `to_wgsl` — compute kernels written IN Tsubaki, not hand-written WGSL

`to_wgsl(kernel, buffers)` (`bin/compile.ml`'s `Compile.Wgsl`) compiles a
restricted subset of Tsubaki syntax into real WGSL — the same Julia-to-shader
idea `WGPUCompute.jl` established for real Julia, mirrored here. `kernel` is a
`quote ... end` block; `buffers` is a `Dict` mapping each buffer name to its
`BindingKind` string, in insertion order (which becomes the binding index), so
the result feeds straight into `create_pipeline`:

```julia
kernel = quote
    output[gid] = input[gid] * 2.0
end
buffers = Dict()
buffers["input"] = "storage-read"
buffers["output"] = "storage-read-write"
wgsl = to_wgsl(kernel, buffers)  # real WGSL, ready for create_pipeline
```

`gid` is a magic free name — the invocation's element index
(`@builtin(global_invocation_id)`). The accepted subset is arithmetic/
comparison, `if`/`for`/`while`, buffer read/write, and `vec2`/`vec3`/`vec4`/
`mat4` (below); a comparison's result may only be used directly in an
`if`/`while` condition (WGSL's `bool` is a distinct type this compiler never
casts to). Workgroup size is a fixed 64, entry point always `"main"` — both a
disclosed v1 cut. Verified as a full round trip (`examples/wgsl_double.jl`:
Tsubaki → WGSL → real GPU compute → `[2,4,…,16]`), not just "the string looks
right."

### `to_glsl` — render kernels (vertex+fragment) written in Tsubaki

`to_wgsl`'s compute shape has nowhere to run as GLSL — real WebGL2 has no
compute stage (that needs OpenGL ES 3.1, one major version past WebGL2's ES
3.0 base). `to_glsl(vertex_kernel, fragment_kernel, uniforms)`
(`bin/compile.ml`'s `Compile.Glsl`) targets what WebGL2 actually runs: a
vertex+fragment pair. Structural near-twin of `Compile.Wgsl` (same restricted
subset, same first-assignment-wins `Int`/`Float` inference), different magic
names:

```julia
vertex_kernel = quote
    if vertex_index == 0
        pos_x = 0.0; pos_y = 0.6
    elseif vertex_index == 1
        pos_x = -0.6; pos_y = -0.6
    else
        pos_x = 0.6; pos_y = -0.6
    end
end
fragment_kernel = quote
    c = color
    frag_r = c.x; frag_g = c.y; frag_b = c.z; frag_a = 1.0
end
uniforms = Dict()
uniforms["color"] = "Vec3"
shaders = to_glsl(vertex_kernel, fragment_kernel, uniforms)  # [vertexGlsl, fragmentGlsl]
```

`vertex_index` (vertex only — GLSL's `gl_VertexID`) is the magic input;
`pos_x`/`pos_y` and `frag_r`/`frag_g`/`frag_b`/`frag_a` are the magic outputs,
assembled into `gl_Position`/`fragColor`. `uniforms` maps each name to its
type (`"Float"`, a vecN struct name, or `"mat4"`) — WebGL2 sets uniforms by
name, so there's no positional binding index like `to_wgsl`'s buffers. No
varyings yet (the vertex stage can't hand the fragment stage anything beyond
`gl_Position`) — a disclosed v1 cut. Verified against a real WebGL2 context
(`gl.compileShader`/`linkProgram`/`drawArrays`, read-back pixels, screenshot).

### Running `to_glsl` output on WebGL2, straight from Tsubaki

`to_glsl` emits GLSL; a small synchronous runtime actually runs it, driven
from Tsubaki source, through the plain browser WebGL2 API — **no wgpu/Rust in the
path** (`bin/webglBridge.ml`, the JS side in `web/webgl-demo.html`'s
`host_webgl_*` functions). WebGL2 is entirely synchronous (context, compile,
link, uniforms, draw), so unlike the WebGPU path this needs none of
`async.ml`'s effect machinery — every call is an ordinary `host_call`, same
shape as `gpuBridge.ml`'s `draw_rect`.

- `webgl_program(vertexGlsl, fragmentGlsl)` → Int handle (compiles+links;
  throws the real info log on failure).
- `webgl_clear(r, g, b, a)`.
- `webgl_uniform(prog, name, values)` — the value's LENGTH picks the call,
  covering exactly `to_glsl`'s uniform types: 1 → float, 2/3/4 → vecN, 16 →
  mat4. A numeric `Vector` carries scalars/vecN; a `Matrix` literal (row-major,
  real Julia's `[.. ; ..]`) is the natural way to write a mat4 — uploaded with
  `transpose=true` (WebGL2 honors it) so a row-major Tsubaki matrix lands
  correctly in GLSL's column-major `mat4`.
- `webgl_draw(prog, mode, vertexCount)` — `useProgram` + `drawArrays`; `mode`
  is `"triangles"` / `"triangle_strip"` / `"lines"` / `"line_strip"` /
  `"points"`. No vertex buffers (geometry off `gl_VertexID`).

```julia
shaders = to_glsl(vertex_kernel, fragment_kernel, uniforms)
prog = webgl_program(shaders[1], shaders[2])
transform = [1.0 0.0 0.0 0.3
             0.0 1.0 0.0 0.0
             0.0 0.0 1.0 0.0
             0.0 0.0 0.0 1.0]
webgl_uniform(prog, "transform", transform)
webgl_uniform(prog, "color", [0.25, 0.85, 0.45])
webgl_clear(0.06, 0.07, 0.12, 1.0)
webgl_draw(prog, "triangles", 3)
```

Verified as a real rendered image (`examples/webgl_triangle.jl` +
`web/webgl-demo.html`, headless Chrome + screenshot): a green triangle,
visibly shifted right by the `mat4` translation — which is what proves the
row-major→transpose→column-major path is correct, not just plausible. Serve
the repo root (`python3 -m http.server`) and open
`/web/webgl-demo.html?src=../examples/webgl_triangle.jl`.

### `vec2`/`vec3`/`vec4`/`mat4` — for both `to_wgsl` and `to_glsl`

A Tsubaki struct is "vecN-eligible" when it's flat, immutable, non-parametric,
has 2–4 fields, every field is exactly `::Float`, and the field names are
exactly `x`/`y`[/`z`[/`w`]] in order (WGSL's/GLSL's own swizzle names):

```julia
struct Vec2
    x::Float
    y::Float
end
```

Construction, swizzle reads (`.x`/`.y`/`.z`/`.w`), and arithmetic (`vecN ±
vecN`, `vecN * scalar` either order, `vecN / scalar`) all compile to the real
operators (`*` on two vecNs is componentwise, as in WGSL/GLSL). `to_wgsl`
buffers can hold `vec2`/`vec4` elements
(`buffers["p"] = "storage-read-write:Vec2"`) but **not vec3** (WGSL pads
`array<vec3>` to 16 bytes, which a tightly-packed `write_buffer` can't match —
a vec3 *uniform* is fine). A `mat4` comes from a Tsubaki matrix literal (4×4 of
`Float`s), as a uniform only, and is transposed on the way out (Tsubaki's rows
are row-major, WGSL/GLSL's constructors fill column-major). Verified against
real GPU/WebGL2 execution (`examples/wgsl_vec2.jl`, `examples/glsl_triangle.jl`
— the latter's triangle visibly shifts under a `mat4` translation).

### Trig/general math builtins

`cos`/`sin`/`tan`/`asin`/`acos`/`atan`/`atan2`/`hypot`/`exp`/`log`/`floor`/
`ceil`/`round` (`bin/runtime.ml`) — thin wrappers over OCaml's `Stdlib`,
accepting `Int` or `Float` uniformly (`pi` is a plain global). Without them,
anything needing an angle (circular motion, rotation, bearing) had no way to
be written in Tsubaki at all. `round` breaks a tie toward the even neighbour,
real Julia's `RoundNearest` (`round(2.5)` is `2.0`, `round(3.5)` is `4.0`) —
OCaml's own `Float.round` rounds a tie away from zero, which disagreed on
exactly the halves.

Integer division in all three of real Julia's roundings — `div` (truncated,
also spelled `÷`), `fld` (floored), `cld` (ceiling) — plus `sign`. `%` was
here already; there had been no way to write the other half of a divmod.

`==`/`!=` answer for **any** two values, not only numbers: strings, `Bool`,
`nothing`, `Symbol`, first-class types, Tuples, Arrays, Dicts, and structs
field by field, with a `mutable struct` compared by identity instead — real
Julia's own split, and verified against it. A user's own `==` method on their
own type is more specific and still wins, including for a value nested inside
a container. Strings also order (`<`/`<=`/`>`/`>=`, lexicographic), which is
what `sort` on a Vector of names goes through.

Strings: `length`, `lowercase`/`uppercase`, and `*` for concatenation —
real Julia's spelling, and its absence used to stop real Julia source dead.
The pre-existing `+` still concatenates too.

## What it can actually do

- **Multiple dispatch**, close to Julia's real algorithm: a single-inheritance
  abstract-type hierarchy up to `Any`, most-specific-applicable resolution,
  and a genuine ambiguity error when two candidates tie.
- **`abstract type`, `struct` / `mutable struct`** (`<: Parent`) — each
  registers a real runtime type, not a hardcoded enum case. Field access; for
  mutable structs, field assignment.
- **Parametric structs, any number of parameters**: `struct Box{T}` /
  `Pair{K,V}` infers each concrete type from whichever field is declared
  exactly `::T`, and registers `Box{Int} <: Box` on the fly.
- **Inner constructors and `new`/`new{T}`** — a `struct` body can define
  `function StructName(...) ... end`, replacing the default constructor.
  `new(...)` builds the raw struct directly (and can take FEWER args than
  fields, leaving the rest assigned afterward — what makes a self-referential/
  circular struct constructible at all). Short-form one-liner constructors and
  the general `Name{T}(args)` call shape work too.
- **Modules** (`module Name ... end` / `using Name`): namespaces `function`,
  `struct`/`abstract type`, and `macro` declarations; nested modules work
  (`using Outer.Inner`). `Name.member(...)` is a strict qualified call, no
  `using` needed, any chain length. `import Name: a, b` binds only the named
  members bare. Constructing a type qualified vs. bare produces the identical
  runtime tag.
- **Macros, with real hygiene, `gensym`, `esc`** — `:( expr )` / `quote ...
  end` quote code as `Symbol`/`Expr` values; `$(expr)` / `$name` splice;
  `macro name(args...) ... end` (args arrive unevaluated, matched by count) +
  `@name(args)`. Hygiene renames a macro's own template variables to fresh
  names so they can't collide with the call site (verified with the classic
  `@swap!`); `esc(x)` strips that off to reach the caller's scope; `eval(quoted)`
  runs it. `@name` can also wrap a whole STATEMENT (`@inline function f(x) ...
  end`); a fixed set of compiler-hint macros (`@inline`/`@inbounds`/…) are
  pure identity. Quoting covers most of the grammar (see "does not do" for the
  scoped-out edges).
- **`Union{A,B,C}`** annotations in signatures.
- **Complex numbers**: `complex(re, im)`, `real`, `imag`, and `+`/`-`/`*`/`^`
  on `Complex` (a `Number` subtype) — added to run `examples/mandel.jl`.
- **Closures**: `x -> expr`, `(a, b) -> expr`, with real lexical capture.
  A named `function` declared inside another function is a real local of the
  call that is running: it closes over that call's own variables (read and
  mutate), can recurse by its own name, and calling the enclosing function
  again makes a genuinely new one. That last part used to be false, silently
  — an inner function existed only as a method on the global generic function
  of its name, and defining one with the same signature *replaces* it, so a
  factory called twice handed back the same closure both times, with the same
  counter inside. Two limits remain, each falling back to exactly that older
  behavior rather than anything worse: an inner function with keyword
  parameters isn't bound locally (the local-closure call path passes only
  positional arguments), and a call whose arguments don't match re-enters
  ordinary dispatch, which is what keeps several same-named inner methods
  choosing by type.
- **Keyword arguments**: `f(a; k = default)` — a side channel, never part of
  the dispatch signature, matching real Julia.
- **Control flow**: `if`/`elseif`/`else`, `for x in`/`= <range or vector>`,
  `while`, explicit `return` plus "last expression is the value."
- **`try`/`catch`/`error(msg)`**: user errors and the interpreter's own
  (`MethodError`, `UndefVarError`, …) are both ordinary catchable values.
- **`&&`/`||`** with real short-circuit evaluation.
- **Vectors**: literals, comprehensions, `push!` (real heap growth), 1-indexed
  `v[i]` read/write, `v[end]`/`v[end-1]`, `length`, slicing (`v[2:4]`,
  `v[2:end]`).
- **A `Base` collection vocabulary**: `max`/`min`/`clamp`, and `map`/`filter`/
  `sort` (`by=`, `rev=`)/`any`/`all`/`count`/`sum`/`maximum`/`minimum`/`pop!`
  over `Range`/`Vector`/`Array`/`Tuple`/`Dict`. `filter`/`map` give back the
  shape they were handed; ordering goes through Tsubaki's own `<` dispatch.
- **A named function is a value.** `f = double`, `filter(fell, balls)` — the
  value is the whole generic function, dispatched on the arguments it receives.
- **`Dict`**: `Dict()` then `d[k] = v` / `d[k]` (missing key raises
  `KeyError`; `get(d, k, default)` doesn't), plus `haskey`/`delete!`/`keys`/
  `values`/`length` and `for (k, v) in d`. Keys are Int/Float/Bool/String/
  Symbol/nothing (`d[1]` and `d[1.0]` are the same entry); insertion-ordered.
  No `=>` literal (see "does not do").
- **`Array`: a Vector that can hold anything.** A literal is a numeric
  `Vector` only if non-empty and every element is a number; otherwise (or if
  empty, Julia's `Vector{Any}`) it's an `Array`. Same `push!`/`length`/`v[i]`/
  slicing/`for`, holding real values. **`Array{T}` dispatch, inferred or
  declared**: a homogeneous `Array`'s tag reflects its contents
  (`Array{Named}`); `Array{Player}()` is a real constructor enforcing `Player`
  on every later `push!`.
- **2D comprehensions**: a second `for` clause builds a genuine 2D result
  (all-numeric → the FFI-friendly `Matrix`; otherwise a row-major
  Array-of-Array). Three+ clauses raise a clear error.
- **A generic boxed `Matrix{T}` container**: `Matrix{Named}(undef, m, n)`,
  `A[i,j]`-indexed over any element type, elementwise `+`/`-` and scalar `*`
  dispatching each cell through Tsubaki's own `T` methods.
- **`Rational`**: `n // d` builds a GCD-reduced fraction (Int-backed, not
  BigInt — a disclosed cut). Stays exact between Rationals or Rational/Int;
  mixing a Float promotes to Float. `numerator`/`denominator`/`abs`.
- **Ranges with a step**: `a:step:b` (Int or Float, computed as `start +
  i*step` so error can't accumulate).
- **Multiple return values and destructuring**: `return a, b` builds a
  `Tuple`; `x, y = f()` destructures it; targets can be full lvalues
  (`a[i], a[j] = a[j], a[i]`).
- **Ternary, compound assignment** (`+=`/`-=`/`*=`/`/=`/`>>=`), `%`, `>>>`,
  bitwise `&`/`|`/`⊻` and `<<`/`>>` (with real Julia's arithmetic-like
  precedence, not `&&`/`||`'s), unary `!`, `===`/`!==` (reference identity).
- **Numeric literal coefficients** (`2x`, `2I`, `2(x+1)`, `2^3x` → `2^(3*x)`).
- **Strings**: `\"`/`\\`/`\n`/`\t`/`\$` escapes, `"hi $name"` and `"$(a + b)"`
  interpolation, triple-quoted `"""..."""` docstrings.
- **`export a, b, c`** and **`const NAME = expr`** parse and are discarded —
  real Julia hints meaningless here (found necessary running real packages).
- **Matrix literals**, real Julia's own syntax: `[1.0 2.0; 3.0 4.0]`
  (whitespace within a row, `;` between rows; comma rows work too; a
  whitespace-only single row builds a genuine 1×N `Matrix`). `A * v` goes
  straight through the Rust/faer FFI.
- **Struct field type annotations are enforced**, at construction and on later
  assignment (`p.y = "nope"` raises a catchable `TypeError`).
- **Fixed-width integers** `Int8`/`Int16`/`Int32`/`UInt8`/`UInt16`/`UInt32`
  (an `Integer`/`Signed`/`Unsigned` layer under `Number`); `T(x)` is a checked
  conversion (`InexactError` on out-of-range), same-type arithmetic wraps on
  overflow. `f.(container)` broadcast (single-arg). `Int[]`/`Int[1,2,3]` typed
  literals. `Vector{T}(undef, n)` / `Matrix{T}(undef, m, n)`.
- **`Float64` and `Int64` are accepted everywhere a type name is written** —
  real Julia's own spellings, normalized to Tsubaki's `Float`/`Int` tags on
  the way in: annotations, struct fields, `Union{...}` alternatives, typed
  literals (`Float64[1.0, 2.0]`), `Vector{Float64}(undef, n)`, `isa`,
  `Box{Float64}` and `::Type{Float64}` dispatch, and the conversions
  `Float64(x)`/`Int64(x)` (`Float(x)` had no spelling at all before). The
  tags themselves are unchanged — renaming them means rewriting the ~120
  method signatures that spell them out as literal strings — so `typeof(1.0)`
  still answers `Float`. `tests/type_aliases.jl` runs under real Julia too.
- **First-class type values and `::Type{X}` dispatch** — a bare type name
  evaluates to a `VType`; `f(::Type{Deque{T}}) where T` and `factor(::Type{A},
  n) where {A<:AbstractArray}` dispatch on the type itself, via the existing
  covariant-parametric matching.
- **A typed exception hierarchy** — `catch e; isa(e, DimensionMismatch)` and
  `e.msg` both work. One parser (`exn_of_failure_message`) turns the existing
  `"Kind: message"` convention into real `isa`-checkable `VStruct`s at the one
  place a `Failure` is caught; `show` prints them exactly as before.
- **A real cross-module FFI boundary**: `*` on `(Matrix, Vector)` and
  `rotate(vec2, angle)` call the separate Rust/faer wasm module, copying bytes
  across the GC↔linear-memory boundary by hand.
- **`LinearAlgebra` compatibility** (faer does the numerical heavy lifting;
  see [`ROADMAP.md`](ROADMAP.md) for the staged plan and where full parity
  isn't reachable in principle):
  - Core ops: `A[i,j]` get/set, `A * B` (rectangular, checked
    `DimensionMismatch`), `transpose(A)` / `A'`, `dot(a,b)` / `a ⋅ b`,
    `norm(v[, p])`, `zeros`/`ones`, `size`, and `LinearAlgebra.I` as a real
    lazy `UniformScaling` (`A + I`, `2I`, `I * v`, …). Scalar `*` and
    `Vector - Vector` alongside.
  - Solves/decompositions: `A \ b`, `det`, `inv`, `tr`, `rank`, plus real
    factorization objects `lu`/`qr`/`cholesky`/`svd` (field names matching
    real Julia — `.L`/`.U`/`.p`, `.Q`/`.R`, `.U`/`.S`/`.V`). Eigen
    (`eigvals`/`eigvecs`/`eigen`) branches on symmetry: a symmetric input
    stays real; a non-symmetric one returns genuine `ComplexVector`/
    `ComplexMatrix` results (a separate FFI export wrapping faer's general
    eigendecomposition). **Disclosed gap**: an exactly singular `A` isn't
    reliably detected by `\`/`inv` (partial-pivot LU can return `NaN`/`Inf`
    instead of raising).
  - Wrapper types `Symmetric`/`Diagonal`/`UpperTriangular`/`LowerTriangular`/
    `Tridiagonal` (`*`/`\`/`det`/`inv`/`tr`, with real O(n)/O(n²) algorithms
    for `Diagonal` and `Tridiagonal`'s Thomas solve, densify-and-redispatch
    for the rest), `± I` absorbing into each, and the long tail
    (`issymmetric`/`ishermitian`, `isposdef`, `logdet` (overflow-safe),
    `cond`, `pinv`, `nullspace` (any shape, via full-V SVD), `kron`).
  - **Sparse** (`SparseMatrixCSC`): `sparse`/`spzeros`/`nnz`/`*`/`\` (square,
    via faer's `sp_lu`); COO/triplet input like real Julia's `sparse(I,J,V)`.
- Compiles to an actual WasmGC module — verified by disassembling and finding
  real `(type (struct …))` / `(type (array …))`, not a linear-memory emulation.

## What it deliberately does not do

- **`Dict` has no `=>` literal.** `Dict()` then `d[k] = v` is the only way;
  `Dict("a" => 1)` doesn't parse (it needs a `Pair` type that collides with
  the demo's own `struct Pair{K,V}`, plus varargs dispatch doesn't have —
  three decisions, not one). Keys are limited to immutable scalar types.
- **A traceback skips a function that was bytecode-compiled.** A runtime
  error now names its file, its line, and the chain of calls that reached it
  (see "Where an error happened" below) — but a zero-parameter function that
  took the bytecode/Host path doesn't run through the tree-walker and so
  contributes no frame. The functions it *calls* still do.
- **`module`/`using`/`import` are a real but narrow subset.** No export lists;
  two modules declaring an unrelated same-named type both `using`'d end up
  treated as related (the same "same name → merged" simplification same-named
  functions already accept); no bare `Name.member` for a non-call member (no
  first-class module value, plain variables aren't namespaced).
- **Macros/quoting cover a scoped subset of the grammar.** Not quotable
  (raises a clear error): `Vector{T}(undef, n)` and a bare evaluated block.
  Macros are namespaced by module and are NOT merged by `using` (unlike
  functions/types). Hygiene renames variable-binding/reference positions only,
  never a call's function/operator name or a `.field` (renaming `+` itself was
  a real bug caught while building this); a macro-local closure recursively
  calling itself by its own name is a disclosed residual gap. No `@generated`,
  no built-in macro library.
- **Matrix literal whitespace-sensitivity** is faithful across a whole row now
  (`[1.0 -2.0]` splits into two elements), reached via a two-attempt re-parse
  since this parser isn't whitespace-sensitive everywhere real Julia's lexer
  is.
- **`Rational` is Int-backed, not BigInt-backed**, so it silently overflows
  like any other `VInt` here. Always GCD-reduced with a positive denominator;
  `1 // 0` raises.
- **No `BigFloat`, permanently.** Spiked, not deferred: `zarith` +
  `zarith_stubs_js` runs under `byte`/`native`/`js` but fails at runtime under
  `wasm` (the target this actually ships), and `zarith_stubs_js` only shims
  classic `js_of_ocaml`. A self-contained pure-OCaml bignum was judged bigger
  than any other single piece of this project's history, and not taken on. See
  `ROADMAP.md`'s "Numeric type genericity."
- **No package system.** `include("other.jl")` is the whole of it: no
  registry, no environments, no `Project.toml`, no versions.
- **Eleven targeted optimizations plus one static-analysis pass, no more.**
  Variable lookup's depth is resolved statically, but the lookup at that depth
  is still a linear assoc-list scan (interning just makes its comparisons
  cheap). No JIT in the real sense — "pseudo-JIT" means caching a hot
  *interpretive* decision, not compiling one away (except the restricted
  bytecode path, which is a genuinely separate compiler — see
  `AST_IN_RUST_EXPERIMENT.md`). Fine for a demo, nowhere near fine for
  anything real.

## Layout

- `bin/` — the whole interpreter, one file per module (dune wires multi-file
  executables automatically):
  - `runtime.ml` — value representation, type hierarchy, multiple dispatch,
    every built-in (`+`, `LinearAlgebra`, the exception hierarchy, …) — the
    biggest file by far.
  - `ast.ml`, `lexer.ml`, `parser.ml` — AST, tokenizer, recursive-descent
    parser (`rust_parser/` ports this last one's expression grammar to Rust).
  - `resolve.ml` — the static scope-resolution pass (runs once before
    execution).
  - `compile.ml` — the restricted bytecode compiler/VM bridge plus the
    `Wgsl`/`Glsl` shader emitters (`to_wgsl`/`to_glsl`).
  - `eval.ml` — the tree-walking evaluator.
  - `async.ml` — the OCaml-5-effect `await` bridge for the async GPU builtins.
  - `hints.ml` — one shared function (`is_inert_hint_macro`).
  - `gpuBridge.ml` / `webglBridge.ml` — the browser bridges: WebGPU (wgpu, via
    `gpu/`) and raw WebGL2 (plain JS, running `to_glsl` output). Their
    top-level registrations are forced to link by an explicit `init ()` call
    in `main.ml` (an unreferenced module's side effects are otherwise dropped
    by the wasm/js build — see `CurveBridge.init`'s own comment).
  - `curveBridge.ml`, `physicsBridge.ml`, `audioBridge.ml`, `parallelBridge.ml`,
    `ecs.ml` — the other host bridges (museum curve, physics, audio, worker
    pool, ECS).
  - `repl.ml` — the interactive prompt: reads until every opened block is
    closed, shows what an expression came to, and never lets an error end the
    session.
  - `main.ml` — the CLI entry point (run a file, the REPL, or the built-in
    demo) and, at the bottom, that demo program.
- `tests/` — the regression suite: a `NAME.jl` and the `NAME.out` it must
  print. A test starting `# julia: yes` must produce that same output under
  real Julia; one named `repl_*` is fed to the REPL on stdin instead of run
  as a file; [`known_gaps.jl`](tests/known_gaps.jl) pins the places Tsubaki
  deliberately still differs.
- `tools/test.py` — runs them (`make test`, `make test-julia`). `--update`
  re-records the goldens; read its diff before trusting it.
- `examples/` — real JuliaLang/Microbenchmarks programs plus the GPU/WebGL
  demos (`wgsl_double.jl`, `glsl_triangle.jl`, `webgl_triangle.jl`, the `ecs_gpu_*`
  set). Run browser ones via `web/*.html` (serve the repo root).
- `web/` — browser host pages: `demo.html` (fixed-function 2D), `gpu-compute-demo.html`
  (wgpu compute from Tsubaki), `webgl-demo.html` (raw WebGL2 from Tsubaki).
- `kernel/` — the Rust/faer numeric kernel (`wasm32-unknown-unknown`, plain
  linear memory).
- `gpu/` — the browser WebGPU (wgpu) crate, independent of `kernel/`.
- `preload.js` — wires the two wasm modules together.
- [`ROADMAP.md`](ROADMAP.md) — the staged `LinearAlgebra` plan, including where
  full parity isn't reachable even in principle.
- [`AST_IN_RUST_EXPERIMENT.md`](AST_IN_RUST_EXPERIMENT.md) — the bytecode
  compiler + VM for "pisum-shaped" numeric functions (~6.6× faster,
  automatically), with a superinstruction fusion pass; also where emitting
  real wasm would go.
- [`rust_parser/`](rust_parser/README.md) — a deliberately frozen Rust
  src→AST port of Tsubaki's expression grammar, valued for differential testing
  and as one more data point on OCaml's exhaustiveness vs. JavaScript's
  `switch` vs. Rust's `match`.
