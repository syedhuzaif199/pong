package main

import "core:math"
import rl "vendor:raylib"

// All artwork is drawn at the logical canvas resolution; no external assets.
CORAL :: rl.Color{255, 119, 139, 255}
EDGE :: rl.Color{42, 63, 79, 255}

ink :: proc(c: rl.Color, alpha: u8) -> rl.Color {
    return rl.Color{c.r, c.g, c.b, alpha}
}

surface :: proc(rect: rl.Rectangle, fill: rl.Color, border := EDGE) {
    rl.DrawRectangleRounded(rl.Rectangle{rect.x, rect.y + 4, rect.width, rect.height}, 0.16, 8, rl.Color{0, 0, 0, 65})
    rl.DrawRectangleRounded(rect, 0.16, 8, fill)
    rl.DrawRectangleRoundedLinesEx(rect, 0.16, 8, 1, border)
}

draw_atmosphere :: proc() {
    rl.DrawRectangleGradientV(0, 0, WINDOW_W, WINDOW_H, rl.Color{12, 24, 36, 255}, BG)
    rl.DrawCircleGradient({80, 220}, 380, ink(ACCENT, 15), ink(ACCENT, 0))
    rl.DrawCircleGradient({880, 360}, 360, ink(CORAL, 13), ink(CORAL, 0))
    for x := 24; x < WINDOW_W; x += 32 {
        for y := 20; y < WINDOW_H; y += 32 {
            rl.DrawCircle(i32(x), i32(y), 1, rl.Color{74, 106, 126, 30})
        }
    }
    rl.DrawLine(24, 0, 24, WINDOW_H, ink(EDGE, 100))
    rl.DrawLine(WINDOW_W - 24, 0, WINDOW_W - 24, WINDOW_H, ink(EDGE, 100))
}

draw_energy_paddle :: proc(rect: rl.Rectangle, colour: rl.Color, flash: f32) {
    for i in 1..=3 {
        spread := f32(i) * 3
        rl.DrawRectangleRounded({rect.x - spread, rect.y - spread, rect.width + spread * 2, rect.height + spread * 2}, 0.5, 8, ink(colour, u8(18 - i * 4)))
    }
    rl.DrawRectangleRounded(rect, 0.6, 8, colour)
    rl.DrawRectangleRounded({rect.x + 3, rect.y + 4, 3, rect.height - 8}, 0.8, 8, ink(FG, 160))
    for i in 0..<3 {
        rl.DrawRectangle(i32(rect.x + 5), i32(rect.y + rect.height / 2 - 7 + f32(i * 6)), i32(rect.width - 10), 2, ink(BG, 110))
    }
    if flash > 0 {
        rl.DrawRectangleRounded(rect, 0.6, 8, ink(FG, u8(min(f32(1), flash / 0.12) * 220)))
        rl.DrawCircleLinesV({rect.x + rect.width / 2, rect.y + rect.height / 2}, 60 * (1 - flash / 0.12), ink(colour, 100))
    }
}

draw_energy_ball :: proc(position: [2]f32, radius: f32, colour: rl.Color) {
    rl.DrawCircleGradient(position, radius * 4, ink(colour, 85), ink(colour, 0))
    rl.DrawCircleV(position, radius + 1, colour)
    rl.DrawCircleV(position, radius * 0.67, FG)
}

draw_arena :: proc() {
    rl.DrawRectangleGradientV(0, 0, WINDOW_W, WINDOW_H, rl.Color{10, 22, 32, 255}, BG)
    for x := 0; x < WINDOW_W; x += 40 {
        rl.DrawLine(i32(x), 0, i32(x), WINDOW_H, rl.Color{29, 49, 62, 45})
    }
    for y := 0; y < WINDOW_H; y += 40 {
        rl.DrawLine(0, i32(y), WINDOW_W, i32(y), rl.Color{29, 49, 62, 45})
    }
    rl.DrawCircleGradient({0, FIELD_H / 2}, 270, ink(ACCENT, 20), ink(ACCENT, 0))
    rl.DrawCircleGradient({FIELD_W, FIELD_H / 2}, 270, ink(CORAL, 20), ink(CORAL, 0))
    rl.DrawCircleLinesV({FIELD_W / 2, FIELD_H / 2}, 78, EDGE)
    rl.DrawCircleLinesV({FIELD_W / 2, FIELD_H / 2}, 82, ink(EDGE, 85))
    for y := 138; y < WINDOW_H - 12; y += 22 {
        rl.DrawRectangle(WINDOW_W / 2 - 1, i32(y), 2, 8, ink(EDGE, 180))
    }
    for i in 0..<4 {
        rl.DrawRectangle(0, i32(i), WINDOW_W, 1, ink(ACCENT, u8(100 - i * 25)))
        rl.DrawRectangle(0, WINDOW_H - 1 - i32(i), WINDOW_W, 1, ink(CORAL, u8(100 - i * 25)))
    }
    rl.DrawRectangle(0, 0, 3, WINDOW_H, ink(ACCENT, 110))
    rl.DrawRectangle(WINDOW_W - 3, 0, 3, WINDOW_H, ink(CORAL, 110))
}

// A live, decorative rally on the home screen, independent of match state.
draw_showcase :: proc() {
    rect := rl.Rectangle{484, 126, 424, 294}
    surface(rect, rl.Color{9, 21, 31, 255})
    rl.BeginScissorMode(485, 127, 422, 292)
    t := f32(rl.GetTime())
    when #config(PONG_VISUAL_REVIEW, false) { t = 0.75 }
    rl.DrawCircleGradient({550, 260}, 180, ink(ACCENT, 20), ink(ACCENT, 0))
    rl.DrawCircleGradient({870, 290}, 170, ink(CORAL, 20), ink(CORAL, 0))
    for y := 148; y < 408; y += 24 { rl.DrawRectangle(695, i32(y), 2, 9, EDGE) }
    rl.DrawCircleLinesV({696, 273}, 53, EDGE)
    phase := t * 0.42 - math.floor(t * 0.42)
    bx := 534 + (1 - math.abs(phase * 2 - 1)) * 324
    by := 273 + math.sin(t * 2.64) * 74
    direction: f32 = 1
    if phase > 0.5 { direction = -1 }
    for i := 12; i > 0; i -= 1 {
        rl.DrawCircleV({bx - direction * f32(i) * 6, by - math.cos(t * 2.64) * f32(i) * 2}, f32(7) - f32(i) * 0.35, ink(ACCENT, u8(100 - i * 7)))
    }
    draw_energy_paddle({520, 238 + math.sin(t * 2.64 - 0.4) * 68, 12, 70}, ACCENT, 0)
    draw_energy_paddle({860, 238 + math.sin(t * 2.64 + 0.4) * 68, 12, 70}, CORAL, 0)
    draw_energy_ball({bx, by}, 7, ACCENT)
    rl.EndScissorMode()
    draw_text("THE ARENA", 502, 143, 12, MUTED)
    draw_text("01", 654, 157, 30, ink(ACCENT, 160))
    draw_text("02", 715, 157, 30, ink(CORAL, 160))
    draw_text("PURE REFLEX. EVERY POINT.", 548, 441, 16, MUTED)
}

menu_card :: proc(title, subtitle, number: string, rect: rl.Rectangle, colour: rl.Color) -> bool {
    hot := rl.CheckCollisionPointRec(logical_mouse_position(), rect)
    fill := PANEL
    border := EDGE
    if hot { fill = PANEL_HOVER; border = colour }
    surface(rect, fill, border)
    rl.DrawRectangleRounded({rect.x + 14, rect.y + 14, 36, 36}, 0.3, 8, ink(colour, 24))
    draw_text_centered_in(number, {rect.x + 14, rect.y + 14, 36, 36}, 17, colour)
    draw_text(title, int(rect.x + 64), int(rect.y + 14), 23, FG)
    draw_text(subtitle, int(rect.x + 64), int(rect.y + 44), 13, MUTED)
    draw_text(">", int(rect.x + rect.width - 30), int(rect.y + 25), 23, colour)
    clicked := hot && ui_primary_pressed()
    if clicked { request_ui_click() }
    return clicked
}
