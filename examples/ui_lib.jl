# Draft immediate-mode UI library: no retained widget tree, no persistent
# widget objects -- every widget function is called fresh each frame with
# its rect/label and returns its current interaction result. Fits Tsubaki's
# on_frame model directly (see move_rect.jl), the way Dear ImGui fits a
# frame loop.
#
# Click-vs-held needs comparing THIS frame's mouse_down against LAST
# frame's. That needs somewhere to keep one frame of history. A plain
# top-level variable reassigned (no `global` keyword) inside an on_frame
# closure DOES persist correctly across frames here -- confirmed directly,
# `x = x + 1.0` inside a closure keeps accumulating call after call. Only
# the explicit `global x` keyword form is broken (UndefVarError). Still,
# threading state explicitly through a UiState struct (rather than one
# bare captured variable per widget) is the right shape for a UI library
# regardless of that bug's exact edges -- it's what every widget needs to
# read the SAME frame's mouse state, computed once, not the widget
# reaching for global mutable state on its own.
mutable struct UiState
    mouse_was_down::Bool
    mouse_down_now::Bool
end

# Call once at the top of on_frame's body, before any widget calls this
# frame -- snapshots "is the mouse held right now" ONCE so every widget
# this frame agrees on it (each widget calling mouse_down() itself would
# also work most of the time, but ties widget behavior to exactly when in
# the frame it happens to be evaluated instead of one frame-start snapshot).
function ui_begin_frame(ui::UiState)
    ui.mouse_down_now = mouse_down("left")
end

# Call once at the end of on_frame's body, after every widget this frame
# -- rolls this frame's snapshot into "last frame" for the NEXT frame's
# edge detection. Do this exactly once per frame, not per-widget: a
# per-widget update would only let the FIRST widget processed each frame
# ever see a real click edge.
function ui_end_frame(ui::UiState)
    ui.mouse_was_down = ui.mouse_down_now
end

function point_in_rect(px, py, x, y, w, h)
    return px >= x && px <= x + w && py >= y && py <= y + h
end

# button: draws itself (lighter fill when hovered) + a left-aligned label,
# returns true on exactly the frame the mouse transitions from up to down
# while over it -- a real click edge, not "currently held".
function button(ui::UiState, x, y, w, h, label_text::String)
    hovered = point_in_rect(mouse_x(), mouse_y(), x, y, w, h)
    clicked = hovered && ui.mouse_down_now && !ui.mouse_was_down

    if hovered
        draw_rect(x, y, w, h, 0.35, 0.35, 0.42, 1.0)
    else
        draw_rect(x, y, w, h, 0.22, 0.22, 0.27, 1.0)
    end
    draw_text(x + 4.0, y + h / 2.0 - 3.0, label_text, 1.0, 1.0, 1.0, 1.0, 1.0)

    return clicked
end

# label: thin wrapper over draw_text, mostly for API symmetry with the
# other widgets here (so a toolbar's code reads as a list of widget calls,
# not "draw_text mixed in with real widgets").
function label(x, y, text_str::String, scale, r, g, b, a)
    draw_text(x, y, text_str, scale, r, g, b, a)
end

# checkbox: draws a small box (filled when checked) + label to its right,
# returns the NEW checked state -- same click-edge detection as button.
# Caller is expected to reassign their own `checked` variable from the
# return value, same as button's caller reacts to its Bool return.
function checkbox(ui::UiState, x, y, size, checked::Bool, label_text::String)
    hovered = point_in_rect(mouse_x(), mouse_y(), x, y, size, size)
    clicked = hovered && ui.mouse_down_now && !ui.mouse_was_down
    new_checked = checked
    if clicked
        new_checked = !checked
    end

    if new_checked
        draw_rect(x, y, size, size, 0.3, 0.75, 0.35, 1.0)
    else
        draw_rect(x, y, size, size, 0.2, 0.2, 0.24, 1.0)
    end
    draw_text(x + size + 6.0, y, label_text, 1.0, 1.0, 1.0, 1.0, 1.0)

    return new_checked
end

# panel: just a background rect, for grouping/visual separation (a
# toolbar strip, a sidebar) -- deliberately nothing fancier than draw_rect
# under a different name.
function panel(x, y, w, h, r, g, b, a)
    draw_rect(x, y, w, h, r, g, b, a)
end

# vstack_y: the minimal layout helper -- y position of item `index`
# (0-based) in a vertical stack starting at start_y, each item
# item_height tall with spacing between. Not a general layout system on
# purpose; callers still place x by hand and call this once per item for y.
function vstack_y(start_y, item_height, spacing, index)
    return start_y + index * (item_height + spacing)
end

# ------------------------------ demo ------------------------------
# A small toolbar: two buttons and a checkbox, driven by on_frame. Run
# with `node -r ./preload.js _build/default/bin/main.bc.wasm.js --frames N
# examples/ui_lib.jl` (headless -- mouse always reads as up/at-origin
# under preload.js's stub, so no click will actually fire, but this
# confirms the whole thing runs frame after frame without crashing) or
# from a real host page (web/demo.html-style) for actual interaction.

ui = UiState(false, false)
click_count = 0
show_extra = false

on_frame(function ()
    ui_begin_frame(ui)
    clear_screen(0.05, 0.05, 0.08)

    panel(10.0, 10.0, 160.0, 150.0, 0.12, 0.12, 0.16, 1.0)
    label(20.0, 16.0, "TOOLBAR", 1.0, 0.8, 0.8, 0.8, 1.0)

    y0 = vstack_y(34.0, 24.0, 8.0, 0)
    if button(ui, 20.0, y0, 130.0, 24.0, "BUTTON A")
        click_count = click_count + 1
    end

    y1 = vstack_y(34.0, 24.0, 8.0, 1)
    if button(ui, 20.0, y1, 130.0, 24.0, "BUTTON B")
        show_extra = !show_extra
    end

    y2 = vstack_y(34.0, 24.0, 8.0, 2)
    show_extra = checkbox(ui, 20.0, y2, 16.0, show_extra, "EXTRA")

    label(20.0, 128.0, "CLICKS", 1.0, 0.55, 0.55, 0.55, 1.0)

    if show_extra
        panel(180.0, 10.0, 100.0, 40.0, 0.15, 0.2, 0.15, 1.0)
        label(190.0, 20.0, "EXTRA PANEL", 1.0, 0.7, 1.0, 0.7, 1.0)
    end

    ui_end_frame(ui)
end)
