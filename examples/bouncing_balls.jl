# Physics MVP in the browser: a handful of circles bouncing inside a box made
# of four static walls, one nudgeable by arrow keys. Run via web/demo.html
# (see that file's own header comment for how to serve it) --
# web/demo.html?src=../examples/bouncing_balls.jl
#
# Canvas is 480x320, y-down (see web/demo.html's toNdc) -- physics itself
# doesn't care about that, it just needs SOME consistent coordinate space, so
# this reuses the canvas's own pixel space directly and treats "down" as
# +y, gravity as a positive gy.

world = physics_world_new(0.0, 400.0)

wall_thickness = 20.0
physics_add_box(world, 240.0, 320.0 + wall_thickness / 2, 0.0, 0.0, 240.0, wall_thickness / 2, 0.0, 0.6) # floor
physics_add_box(world, 240.0, -wall_thickness / 2, 0.0, 0.0, 240.0, wall_thickness / 2, 0.0, 0.6) # ceiling
physics_add_box(world, -wall_thickness / 2, 160.0, 0.0, 0.0, wall_thickness / 2, 160.0, 0.0, 0.6) # left
physics_add_box(world, 480.0 + wall_thickness / 2, 160.0, 0.0, 0.0, wall_thickness / 2, 160.0, 0.0, 0.6) # right

ball1 = physics_add_circle(world, 100.0, 50.0, 80.0, 0.0, 15.0, 1.0, 0.7)
ball2 = physics_add_circle(world, 300.0, 100.0, -60.0, 40.0, 20.0, 1.0, 0.7)
ball3 = physics_add_circle(world, 200.0, 200.0, 30.0, -50.0, 10.0, 0.6, 0.7)

speed = 200.0

on_frame(function()
    clear_screen(0.05, 0.05, 0.08)

    vx = 0.0
    vy = 0.0
    if key_down("ArrowRight")
        vx = speed
    end
    if key_down("ArrowLeft")
        vx = -speed
    end
    if key_down("ArrowUp")
        vy = -speed
    end
    if key_down("ArrowDown")
        vy = speed
    end
    if vx != 0.0 || vy != 0.0
        physics_set_velocity(world, ball1, vx, vy)
    end

    if physics_step(world, 1.0 / 60.0) > 0
        play_tone(220.0, 0.05)
    end

    # 4 static walls were added first (bodies 1-4, 16 numbers), so ball1/2/3
    # are the 5th/6th/7th bodies -- state[17]/[21]/[25] are their x's.
    state = physics_get_bodies(world)
    draw_rect(state[17] - 15.0, state[18] - 15.0, 30.0, 30.0, 0.9, 0.3, 0.2, 1.0)
    draw_rect(state[21] - 20.0, state[22] - 20.0, 40.0, 40.0, 0.2, 0.6, 0.9, 1.0)
    draw_rect(state[25] - 10.0, state[26] - 10.0, 20.0, 20.0, 0.3, 0.9, 0.4, 1.0)
end)
