# The same vertex+fragment kernels as examples/glsl_triangle.jl -- but where
# that file only COMPILES to GLSL text (to_glsl) and prints it, this one hands
# that GLSL to a real WebGL2 context and actually DRAWS, all driven from Tsubaki
# source: to_glsl -> webgl_program -> webgl_uniform -> webgl_draw.
#
# The whole WebGL path is plain JS (the host page's host_webgl_* functions,
# see bin/webglBridge.ml + web/webgl-demo.html) -- no wgpu/Rust anywhere.
# WebGL2 is synchronous, so these read like ordinary calls.
#
# Run in a browser: serve the repo root (`python3 -m http.server`) and open
#   /web/webgl-demo.html?src=../examples/webgl_triangle.jl
# (this file needs a real WebGL2 context -- it can't run under `make run`,
# which is Node, the same way the WebGPU examples can't.)

struct Vec2
    x::Float
    y::Float
end

struct Vec3
    x::Float
    y::Float
    z::Float
end

struct Vec4
    x::Float
    y::Float
    z::Float
    w::Float
end

vertex_kernel = quote
    if vertex_index == 0
        p = Vec2(0.0, 0.6)
    elseif vertex_index == 1
        p = Vec2(-0.6, -0.6)
    else
        p = Vec2(0.6, -0.6)
    end
    clip = transform * Vec4(p.x, p.y, 0.0, 1.0)
    pos_x = clip.x
    pos_y = clip.y
end

fragment_kernel = quote
    c = color
    frag_r = c.x
    frag_g = c.y
    frag_b = c.z
    frag_a = 1.0
end

uniforms = Dict()
uniforms["transform"] = "mat4"
uniforms["color"] = "Vec3"

# Tsubaki source -> GLSL ES 3.00 (vertex + fragment)
shaders = to_glsl(vertex_kernel, fragment_kernel, uniforms)

# ...and now actually run it on WebGL2.
prog = webgl_program(shaders[1], shaders[2])

# a translation matrix, written row-major the way real Julia writes matrices --
# shift the triangle right by 0.3 in clip space (host uploads with transpose,
# so this row-major form lands correctly in GLSL's column-major mat4)
transform = [1.0 0.0 0.0 0.3
             0.0 1.0 0.0 0.0
             0.0 0.0 1.0 0.0
             0.0 0.0 0.0 1.0]
webgl_uniform(prog, "transform", transform)

# a green Vec3 color, as a plain 3-element vector
webgl_uniform(prog, "color", [0.25, 0.85, 0.45])

webgl_clear(0.06, 0.07, 0.12, 1.0)
webgl_draw(prog, "triangles", 3)

println("drew a triangle via WebGL2 -- shaders from Tsubaki's own to_glsl, GL from JS")
