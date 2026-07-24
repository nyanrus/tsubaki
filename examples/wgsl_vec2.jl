# Exercises to_wgsl's new vec2 support: a buffer of Vec2 points, read as a
# real vec2<f32> (not two separate floats), shifted by a constructed Vec2,
# written back -- verified against a real GPU, not just "the string looks
# right" (see README's to_wgsl section).
#
# Run via web/gpu-compute-demo.html --
# web/gpu-compute-demo.html?src=../examples/wgsl_vec2.jl

struct Vec2
    x::Float
    y::Float
end

kernel = quote
    p = points[gid]
    d = Vec2(10.0, 100.0)
    points[gid] = p + d
end

buffers = Dict()
buffers["points"] = "storage-read-write:Vec2"

wgsl = to_wgsl(kernel, buffers)
println(wgsl)

info = gpu_init("high-performance")
println("adapter: ", info.name, " / ", info.backend)

# 4 Vec2 points, flattened x,y,x,y,...
points = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]

points_buf = create_buffer(32, "storage-read-write") # 8 floats * 4 bytes
write_buffer(points_buf, points)

# tsubaki-gpu's own bindingKinds only care about the buffer's USAGE
# (read/read-write), not its WGSL-side element type -- the ":Vec2" suffix
# is purely a to_wgsl/Compile.Wgsl convention, already baked into the WGSL
# text above (`array<vec2<f32>>`), invisible to wgpu's own binding setup.
pipeline = create_pipeline(wgsl, "main", ["storage-read-write"])

dispatch(pipeline, [points_buf], 1, 1, 1)
result = read_buffer(points_buf)

println("input:  ", points)
println("output (each Vec2 + (10,100)): ", result)

expected = [11.0, 102.0, 13.0, 104.0, 15.0, 106.0, 17.0, 108.0]
ok = true
i = 1
while i <= 8
    if abs(result[i] - expected[i]) > 0.001
        ok = false
    end
    i = i + 1
end

destroy_buffer(points_buf)
destroy_pipeline(pipeline)
gpu_shutdown()

println(ok ? "PASS" : "FAIL")
