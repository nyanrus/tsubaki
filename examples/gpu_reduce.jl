# Ports gpu/test.html's own verified pairwise-sum reduction shader to a real
# Tsubaki script, proving gpu/'s raw async wgpu API (gpu_init/create_pipeline/
# read_buffer, all genuinely async on gpu/'s own Rust side) is reachable
# from ordinary Tsubaki source -- no `await` keyword anywhere below, see
# bin/async.ml for how that's made transparent.
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/gpu_reduce.jl

shader = """
    struct Params { k: f32 };

    @group(0) @binding(0) var<storage, read> input: array<f32>;
    @group(0) @binding(1) var<uniform> params: Params;
    @group(0) @binding(2) var<storage, read_write> output: array<f32>;

    @compute @workgroup_size(1, 1, 1)
    fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
      let i = gid.y * 2u + gid.x;
      if (i < arrayLength(&output)) {
        output[i] = (input[i * 2u] + input[i * 2u + 1u]) * params.k;
      }
    }
"""

info = gpu_init("high-performance")
println("adapter: ", info.name, " / ", info.backend)

input = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
k = 10.0

input_buf = create_buffer(32, "storage-read")        # 8 floats * 4 bytes
params_buf = create_buffer(4, "uniform")             # 1 float * 4 bytes
output_buf = create_buffer(16, "storage-read-write") # 4 floats * 4 bytes

write_buffer(input_buf, input)
write_buffer(params_buf, [k])

pipeline = create_pipeline(shader, "main", ["storage-read", "uniform", "storage-read-write"])

dispatch(pipeline, [input_buf, params_buf, output_buf], 2, 2, 1)
result = read_buffer(output_buf)

println("output (pairwise sum * k): ", result)

expected = [30.0, 70.0, 110.0, 150.0]
ok = true
i = 1
while i <= 4
    if abs(result[i] - expected[i]) > 0.001
        ok = false
    end
    i = i + 1
end

destroy_buffer(input_buf)
destroy_buffer(params_buf)
destroy_buffer(output_buf)
destroy_pipeline(pipeline)
gpu_shutdown()

println(ok ? "PASS" : "FAIL")
