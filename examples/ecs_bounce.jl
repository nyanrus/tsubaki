# move_rect.jl's ECS version: N entities (Position, Velocity structs) driven
# entirely by create_entity/add_component!/query -- one draw_rect call per
# entity, each frame. Run via web/demo.html (see that file's own header
# comment for how to serve it) -- web/demo.html?src=../examples/ecs_bounce.jl
#
# Canvas is 480x320, y-down, top-left origin (see web/demo.html's toNdc) --
# same pixel space bouncing_balls.jl's physics reuses directly.
#
# See ecs_bounce_batched.jl for the same scene drawn with draw_rects (one
# FFI crossing for all rects in a frame) instead of one draw_rect per entity.

struct Position
    x
    y
end

struct Velocity
    dx
    dy
end

width = 480.0
height = 320.0
size = 16.0
n = 10

i = 0
while i < n
    e = create_entity()
    add_component!(e, Position(20.0 + i * 40.0, 20.0 + i * 12.0))
    add_component!(e, Velocity(1.5 + i * 0.4, 2.0 - i * 0.15))
    i = i + 1
end

on_frame(function()
    clear_screen(0.05, 0.05, 0.08)

    for e in query(["Position", "Velocity"])
        p = get_component(e, "Position")
        v = get_component(e, "Velocity")

        nx = p.x + v.dx
        ny = p.y + v.dy
        ndx = v.dx
        ndy = v.dy

        if nx < 0.0 || nx + size > width
            ndx = -v.dx
            nx = p.x
        end
        if ny < 0.0 || ny + size > height
            ndy = -v.dy
            ny = p.y
        end

        add_component!(e, Position(nx, ny))
        add_component!(e, Velocity(ndx, ndy))

        draw_rect(nx, ny, size, size, 0.9, 0.3, 0.2, 1.0)
    end
end)
