# ECS SoA storage feeding a GPU buffer directly, no manual per-frame
# flat-array marshal loop: `soa_flatten` (bin/ecs.ml) reads Position's own
# columns straight into a flat Vector, which `write_buffer` (Stage 1's raw
# gpu/ API) takes as-is -- compare against ecs_soa_flatten_bench.jl for how
# much that skips versus the old query/get_component/push! loop.
#
# The GPU side then computes the centroid of every entity's Position on the
# GPU (a real, if simple, single-invocation reduction) and reads it back --
# proving the round trip, not just the upload.
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/ecs_gpu_soa_reduce.jl

struct Position
    x::Float
    y::Float
end

n = 5000

i = 0
while i < n
    e = create_entity()
    add_component!(e, Position(i * 1.0, i * 2.0))
    i = i + 1
end

positions = soa_flatten("Position", ["x", "y"]) # length 2n, straight from the SoA columns

shader = """
    struct Params { n: f32 };

    @group(0) @binding(0) var<storage, read> positions: array<f32>;
    @group(0) @binding(1) var<uniform> params: Params;
    @group(0) @binding(2) var<storage, read_write> sums: array<f32>;

    @compute @workgroup_size(1, 1, 1)
    fn main() {
      var sx: f32 = 0.0;
      var sy: f32 = 0.0;
      let count = u32(params.n);
      for (var i: u32 = 0u; i < count; i = i + 1u) {
        sx = sx + positions[i * 2u];
        sy = sy + positions[i * 2u + 1u];
      }
      sums[0] = sx;
      sums[1] = sy;
    }
"""

info = gpu_init()
println("adapter ready")

pos_buf = create_buffer(length(positions) * 4, "storage-read")
params_buf = create_buffer(4, "uniform")
sums_buf = create_buffer(2 * 4, "storage-read-write")

write_buffer(pos_buf, positions)
write_buffer(params_buf, [n * 1.0])

pipeline = create_pipeline(shader, "main", ["storage-read", "uniform", "storage-read-write"])
dispatch(pipeline, [pos_buf, params_buf, sums_buf], 1, 1, 1)
result = read_buffer(sums_buf)

centroid_x = result[1] / n
centroid_y = result[2] / n
println("GPU centroid over ", n, " entities: (", centroid_x, ", ", centroid_y, ")")

expected_x = (n - 1) / 2.0
expected_y = n - 1
println("expected centroid: (", expected_x, ", ", expected_y, ")")

ok = abs(centroid_x - expected_x) < 0.5 && abs(centroid_y - expected_y) < 0.5
println(ok ? "PASS" : "FAIL")

destroy_buffer(pos_buf)
destroy_buffer(params_buf)
destroy_buffer(sums_buf)
destroy_pipeline(pipeline)
gpu_shutdown()
