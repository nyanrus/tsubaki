# Real GPU instancing, closing the gap Stage 2's README note called
# "genuinely separate, larger" -- N entities, Position flattened straight
# from ECS SoA storage (soa_flatten, no manual per-frame loop) into ONE
# storage buffer, drawn with a SINGLE draw_frame call (instance_count = N):
# the WGSL vertex shader reads its own entity's position via
# @builtin(instance_index), not a thousand separate draw_frame calls.
#
# Also exercises cos/sin (new builtins) for something this project's own
# examples couldn't write before: entities arranged on a circle.
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/ecs_gpu_instanced.jl

struct Position
    x::Float
    y::Float
end

n = 12
radius = 0.6

i = 0
while i < n
    angle = (i * 1.0 / n) * 2.0 * pi
    e = create_entity()
    add_component!(e, Position(radius * cos(angle), radius * sin(angle)))
    i = i + 1
end

positions = soa_flatten("Position", ["x", "y"]) # length 2n, straight from SoA columns

shader = """
    struct Params { size: f32, r: f32, g: f32, b: f32 };

    @group(0) @binding(0) var<storage, read> positions: array<f32>;
    @group(0) @binding(1) var<uniform> params: Params;

    struct VertexOutput {
      @builtin(position) position: vec4<f32>,
    };

    @vertex
    fn vs_main(@builtin(vertex_index) vidx: u32, @builtin(instance_index) iidx: u32) -> VertexOutput {
      let px = positions[iidx * 2u];
      let py = positions[iidx * 2u + 1u];
      var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
      );
      let local = corners[vidx] * params.size;
      var out: VertexOutput;
      out.position = vec4<f32>(px + local.x, py + local.y, 0.0, 1.0);
      return out;
    }

    @fragment
    fn fs_main() -> @location(0) vec4<f32> {
      return vec4<f32>(params.r, params.g, params.b, 1.0);
    }
"""

info = gpu_init()
println("adapter ready")

configure_canvas("canvas", 480, 480, "opaque")

pos_buf = create_buffer(length(positions) * 4, "storage-read")
write_buffer(pos_buf, positions)

params_buf = create_buffer(4 * 4, "uniform")
write_buffer(params_buf, [0.06, 0.95, 0.55, 0.15])

pipeline = create_render_pipeline(shader, "vs_main", "fs_main", ["storage-read", "uniform"], "triangle-list", "replace")

begin_frame(0.05, 0.05, 0.08, 1.0)
draw_frame(pipeline, [pos_buf, params_buf], 6, n) # ONE call, n instances
end_frame()

println("drew ", n, " entities in a single draw_frame call (instance_count=", n, ")")
println("DONE")
