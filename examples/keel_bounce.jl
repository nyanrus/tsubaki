# The Keel library now arrives by include -- one shared source of truth
# (examples/keel.jl), resolved relative to THIS file, so it works from any cwd.
include("keel.jl")

# ======================================================================
# keel_bounce -- bouncing_balls.jl, rewritten on the Keel surface.
#
# Same scene as examples/bouncing_balls.jl (four walls, three balls, one
# nudged by the arrow keys, a beep on collision) -- but the frame body now
# reads like the GAME_DX_VISION.md L0 sketch: a Stage you spawn into, a
# step! that keeps every Transform in sync, arrows() for input, draw per
# ball. No hand-indexed state[17]/[21]/[25]; each ball knows its own body.
#
# The Keel library comes from examples/keel.jl via the include above -- one
# source of truth, no copy to keep in sync. Run:
#   make run FILE=examples/keel_bounce.jl          (loads + registers; exits)
#   node -r ./preload.js _build/default/bin/main.bc.wasm.js --frames N \
#        examples/keel_bounce.jl                    (actually ticks N frames)
# ======================================================================

scene = stage(480.0, 320.0)
walls(scene)

red   = spawn!(scene; pos = Vec2(100.0, 50.0),  vel = Vec2(80.0, 0.0),   radius = 15.0, color = RED)
blue  = spawn!(scene; pos = Vec2(300.0, 100.0), vel = Vec2(-60.0, 40.0), radius = 20.0, color = BLUE)
green = spawn!(scene; pos = Vec2(200.0, 200.0), vel = Vec2(30.0, -50.0), radius = 10.0, color = GREEN)

speed = 200.0

play() do dt
    clear_screen(0.05, 0.05, 0.08)

    dir = arrows()                       # held arrows -> a Vec2, ZERO if none
    if dir.x != 0.0 || dir.y != 0.0
        nudge!(scene, red, speed * dir)  # push the red ball in place
    end

    step!(scene, dt)                     # physics + wall bounce; all tf synced
    if collided(scene)
        beep()
    end

    draw(red)
    draw(blue)
    draw(green)
end
