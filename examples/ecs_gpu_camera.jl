# GPU-side camera: entity positions never get re-touched when the camera
# pans -- only a tiny camera uniform buffer (5 floats) is rewritten. Needs
# ZERO changes to gpu/src/lib.rs -- create_render_pipeline/draw_frame are
# already generic (caller supplies the WGSL, caller supplies the buffers),
# so "camera on the GPU" is just a WGSL vertex shader that reads a camera
# uniform, made practical by instancing (draw_frame's instance_count).
#
# Also demonstrates offset_xy (bin/runtime.ml): entities are created at
# large-magnitude "world" coordinates (simulating UTM-derived meters,
# hundreds of thousands -- exactly where f32 breaks down if sent to the GPU
# raw, see README's own "Only f32" note), then rebased onto a small LOCAL
# origin BEFORE anything crosses into the (f32) position buffer. The camera
# itself then only ever deals in small local-meter offsets too.
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/ecs_gpu_camera.jl

struct Position
    x::Float
    y::Float
end

n = 10

world_origin_x = 302345.0
world_origin_y = 4567890.0

i = 0
while i < n
    angle = (i * 1.0 / n) * 2.0 * pi
    e = create_entity()
    add_component!(e, Position(world_origin_x + 50.0 * cos(angle), world_origin_y + 50.0 * sin(angle)))
    i = i + 1
end

raw = soa_flatten("Position", ["x", "y"])
local_positions = offset_xy(raw, -world_origin_x, -world_origin_y) # now small, f32-safe

shader = """
    struct Camera { panX: f32, panY: f32, pxPerMeter: f32, halfW: f32, halfH: f32 };
    struct Params { size: f32, r: f32, g: f32, b: f32 };

    @group(0) @binding(0) var<storage, read> positions: array<f32>;
    @group(0) @binding(1) var<uniform> camera: Camera;
    @group(0) @binding(2) var<uniform> params: Params;

    struct VertexOutput {
      @builtin(position) position: vec4<f32>,
    };

    @vertex
    fn vs_main(@builtin(vertex_index) vidx: u32, @builtin(instance_index) iidx: u32) -> VertexOutput {
      let wx = positions[iidx * 2u] - camera.panX;
      let wy = positions[iidx * 2u + 1u] - camera.panY;
      let ndcX = (wx * camera.pxPerMeter) / camera.halfW;
      let ndcY = (wy * camera.pxPerMeter) / camera.halfH;
      var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
      );
      let local = corners[vidx] * params.size;
      var out: VertexOutput;
      out.position = vec4<f32>(ndcX + local.x, ndcY + local.y, 0.0, 1.0);
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

pos_buf = create_buffer(length(local_positions) * 4, "storage-read")
write_buffer(pos_buf, local_positions)

camera_buf = create_buffer(5 * 4, "uniform")
params_buf = create_buffer(4 * 4, "uniform")
write_buffer(params_buf, [0.05, 0.4, 0.8, 0.95])

pipeline = create_render_pipeline(shader, "vs_main", "fs_main", ["storage-read", "uniform", "uniform"], "triangle-list", "replace")

# frame 1: camera centered exactly on the local origin (pan = 0, 0)
write_buffer(camera_buf, [0.0, 0.0, 3.0, 240.0, 240.0])
begin_frame(0.05, 0.05, 0.08, 1.0)
draw_frame(pipeline, [pos_buf, camera_buf, params_buf], 6, n)
end_frame()
println("frame 1: camera centered on the local origin")

# frame 2: pan the camera 30m on X -- ONLY the camera uniform is rewritten;
# pos_buf (entity positions) is never touched again.
write_buffer(camera_buf, [30.0, 0.0, 3.0, 240.0, 240.0])
begin_frame(0.05, 0.05, 0.08, 1.0)
draw_frame(pipeline, [pos_buf, camera_buf, params_buf], 6, n)
end_frame()
println("frame 2: camera panned 30m on X, entity buffer untouched")

println("DONE")
