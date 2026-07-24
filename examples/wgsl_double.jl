# Compiles a KERNEL WRITTEN IN TSUBAKI (not hand-written WGSL) via the new
# to_wgsl(quoted_kernel, buffers) builtin (bin/compile.ml's Compile.Wgsl),
# then actually runs the result on a real GPU through gpu/'s raw async API
# -- same "no `await` keyword needed" transparency examples/gpu_reduce.jl
# already demonstrates for hand-written WGSL, now for Tsubaki-generated WGSL
# too. Closes the loop: Tsubaki source -> real WGSL text -> real GPU compute,
# entirely from one Tsubaki script.
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/wgsl_double.jl

kernel = quote
    output[gid] = input[gid] * 2.0
end

buffers = Dict()
buffers["input"] = "storage-read"
buffers["output"] = "storage-read-write"

wgsl = to_wgsl(kernel, buffers)
println(wgsl)

info = gpu_init("high-performance")
println("adapter: ", info.name, " / ", info.backend)

input = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]

input_buf = create_buffer(32, "storage-read")         # 8 floats * 4 bytes
output_buf = create_buffer(32, "storage-read-write")  # same size, elementwise

write_buffer(input_buf, input)

pipeline = create_pipeline(wgsl, "main", ["storage-read", "storage-read-write"])

# 8 elements, workgroup_size(64) -- one workgroup covers them all; the
# compiled bounds-guard (`if (gid >= arrayLength(&output))`) handles the
# 56 invocations past the real length safely.
dispatch(pipeline, [input_buf, output_buf], 1, 1, 1)
result = read_buffer(output_buf)

println("input:  ", input)
println("output (doubled, via Tsubaki-generated WGSL): ", result)

expected = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0]
ok = true
i = 1
while i <= 8
    if abs(result[i] - expected[i]) > 0.001
        ok = false
    end
    i = i + 1
end

destroy_buffer(input_buf)
destroy_buffer(output_buf)
destroy_pipeline(pipeline)
gpu_shutdown()

println(ok ? "PASS" : "FAIL")
