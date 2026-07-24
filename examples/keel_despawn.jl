# The Keel library now arrives by include -- one shared source of truth
# (examples/keel.jl), resolved relative to THIS file, so it works from any cwd.
include("keel.jl")

# ======================================================================
# keel_despawn -- proof that despawn! removes a ball cleanly AND that its slot
# is reused, so spawn/despawn churn doesn't grow the physics world.
#
#   frames 0..:  three balls fall under gravity (handles 0,1,2)
#   frame 10:    despawn the MIDDLE ball (blue, handle 1)
#   frame 12:    spawn a new yellow ball -- it must REUSE handle 1, and the
#                world's slot count must stay 3 (not grow to 4)
#   frame 20:    red (0) and green (2) are undisturbed; yellow (reused 1) falls
#
# slot count is read as length(physics_get_bodies(world)) / 4 -- one 4-float
# row per slot, live or tombstoned. The Keel library comes from examples/keel.jl
# via the include above. Spawns use the keyword form.
# Run: node -r ./preload.js _build/default/bin/main.bc.wasm.js --frames 25 examples/keel_despawn.jl
# ======================================================================

mutable struct Frame
    n::Int
end

function slot_count(s::Stage)
    length(physics_get_bodies(s.world)) / 4
end

scene = stage(480.0, 320.0)

red   = spawn!(scene; pos = Vec2(100.0, 20.0), radius = 15.0, color = RED)
blue  = spawn!(scene; pos = Vec2(240.0, 20.0), radius = 20.0, color = BLUE)
green = spawn!(scene; pos = Vec2(380.0, 20.0), radius = 10.0, color = GREEN)

clock = Frame(0)

play() do dt
    clear_screen(0.05, 0.05, 0.08)
    clock.n = clock.n + 1

    if clock.n == 10
        despawn!(scene, blue)
        println("frame 10: despawned blue (handle ", blue.handle, "); balls=", length(scene.balls), " slots=", slot_count(scene))
    end

    if clock.n == 12
        yellow = spawn!(scene; pos = Vec2(240.0, 20.0), radius = 12.0, color = GREEN)
        println("frame 12: spawned yellow -> handle=", yellow.handle, " (want 1, reused); balls=", length(scene.balls), " slots=", slot_count(scene), " (want 3, not grown)")
    end

    step!(scene, dt)

    for b in scene.balls
        draw(b)
    end

    if clock.n == 20
        println("frame 20: balls=", length(scene.balls), " slots=", slot_count(scene))
        println("  red   y=", red.tf.pos.y, "  green y=", green.tf.pos.y, "  (both still falling, undisturbed)")
    end
end
