# Tsubaki's game-engine MVP, end to end: a rectangle you move with arrow keys.
# Run in a browser via web/demo.html (python3 -m http.server from the repo
# root, then open /web/demo.html) -- clear_screen/draw_rect/key_down/
# on_frame are all builtins registered by bin/gpuBridge.ml, backed by
# gpu/'s WebGPU render pipeline.

x = 200.0
y = 140.0
speed = 4.0

on_frame(function()
    clear_screen(0.05, 0.05, 0.08)

    if key_down("ArrowRight")
        x = x + speed
    end
    if key_down("ArrowLeft")
        x = x - speed
    end
    if key_down("ArrowUp")
        y = y - speed
    end
    if key_down("ArrowDown")
        y = y + speed
    end

    draw_rect(x, y, 40.0, 40.0, 0.9, 0.3, 0.2, 1.0)
end)
