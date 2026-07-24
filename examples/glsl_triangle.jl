# Compiles a VERTEX+FRAGMENT kernel pair WRITTEN IN TSUBAKI into real GLSL ES
# 3.00 (WebGL2's actual shading language) via to_glsl(vertex, fragment,
# uniforms) -- bin/compile.ml's Compile.Glsl, the render-side counterpart to
# to_wgsl's compute-side path (WebGL2 has no compute stage at all, so this
# targets vertex+fragment instead -- see Compile.Glsl's own doc comment).
#
# Exercises the vec2/vec3/vec4/mat4 support added on top of the original
# scalar-only version: the vertex position is built as a real Vec2, lifted
# to a Vec4 homogeneous coordinate, and multiplied by a real mat4 uniform
# (a translation matrix) -- a genuine transform application, not just
# scalar plumbing. The fragment color comes from a Vec3 uniform.
#
# `vertex_index` is the one magic INPUT (GLSL's gl_VertexID); `pos_x`/
# `pos_y` are the vertex kernel's magic OUTPUTS (become gl_Position), and
# `frag_r`/`frag_g`/`frag_b`/`frag_a` are the fragment kernel's (become
# fragColor).
#
# Run: `make run FILE=examples/glsl_triangle.jl` (prints both shaders --
# this file only COMPILES text, no GPU/WebGL call happens here).

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

shaders = to_glsl(vertex_kernel, fragment_kernel, uniforms)

println("--- vertex ---")
println(shaders[1])
println("--- fragment ---")
println(shaders[2])
