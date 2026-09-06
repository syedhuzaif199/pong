package main

import "core:fmt"
import rl "vendor:raylib"

BG :: rl.Color{16, 18, 24, 255}
PANEL :: rl.Color{27, 31, 41, 255}
PANEL_HOVER :: rl.Color{39, 46, 60, 255}
FG :: rl.Color{235, 239, 246, 255}
MUTED :: rl.Color{143, 153, 170, 255}
ACCENT :: rl.Color{106, 191, 255, 255}
DANGER :: rl.Color{255, 111, 116, 255}
GOOD :: rl.Color{114, 220, 151, 255}

ui_click_requested: bool

request_ui_click :: proc() {
    ui_click_requested = true
}

take_ui_click_request :: proc() -> bool {
    requested := ui_click_requested
    ui_click_requested = false
    return requested
}

Text_Field :: struct {
    bytes:  [160]u8,
    length: int,
    active: bool,
}

text_field_set :: proc(field: ^Text_Field, value: string) {
    n := len(value)
    if n > len(field.bytes) {
        n = len(field.bytes)
    }
    copy(field.bytes[:n], transmute([]u8)value[:n])
    field.length = n
}

text_field_string :: proc(field: ^Text_Field) -> string {
    return string(field.bytes[:field.length])
}

text_field_update :: proc(field: ^Text_Field, allow: proc(rune) -> bool) {
    if !field.active {
        return
    }

    modifier_down := rl.IsKeyDown(.LEFT_CONTROL) ||
                     rl.IsKeyDown(.RIGHT_CONTROL) ||
                     rl.IsKeyDown(.LEFT_SUPER) ||
                     rl.IsKeyDown(.RIGHT_SUPER)

    if modifier_down && rl.IsKeyPressed(.V) {
        clipboard_c := rl.GetClipboardText()
        if clipboard_c != nil {
            clipboard := string(clipboard_c)
            field.length = 0

            for ch in clipboard {
                if field.length >= len(field.bytes) {
                    break
                }
                if ch >= 32 && ch <= 126 && allow(ch) {
                    field.bytes[field.length] = u8(ch)
                    field.length += 1
                }
            }
        }
        return
    }

    if rl.IsKeyPressed(.BACKSPACE) && field.length > 0 {
        field.length -= 1
    }

    for {
        ch := rl.GetCharPressed()
        if ch == 0 {
            break
        }
        if field.length >= len(field.bytes) {
            break
        }
        if ch >= 32 && ch <= 126 && allow(ch) {
            field.bytes[field.length] = u8(ch)
            field.length += 1
        }
    }
}

allow_ip_address_char :: proc(ch: rune) -> bool {
    return (ch >= '0' && ch <= '9') ||
           (ch >= 'a' && ch <= 'f') ||
           (ch >= 'A' && ch <= 'F') ||
           ch == ':' || ch == '.'
}

allow_port_char :: proc(ch: rune) -> bool {
    return ch >= '0' && ch <= '9'
}

allow_player_name_char :: proc(ch: rune) -> bool {
    return (ch >= 'a' && ch <= 'z') ||
           (ch >= 'A' && ch <= 'Z') ||
           (ch >= '0' && ch <= '9') ||
           ch == ' ' || ch == '_' || ch == '-'
}

allow_server_url_char :: proc(ch: rune) -> bool {
    return (ch >= 'a' && ch <= 'z') ||
           (ch >= 'A' && ch <= 'Z') ||
           (ch >= '0' && ch <= '9') ||
           ch == '.' || ch == '-' || ch == '_' ||
           ch == ':' || ch == '/' || ch == '?' ||
           ch == '=' || ch == '&' || ch == '%' || ch == '~'
}

allow_room_code_char :: proc(ch: rune) -> bool {
    return (ch >= 'a' && ch <= 'z') ||
           (ch >= 'A' && ch <= 'Z') ||
           (ch >= '0' && ch <= '9') ||
           ch == '-' || ch == ' '
}

// Convert physical-window mouse coordinates back into our fixed 960x540
// logical canvas. This lets the same UI work in a resized or fullscreen window.
logical_mouse_position :: proc() -> [2]f32 {
    mouse := rl.GetMousePosition()
    screen_w := f32(rl.GetScreenWidth())
    screen_h := f32(rl.GetScreenHeight())

    scale := min(screen_w / FIELD_W, screen_h / FIELD_H)
    if scale <= 0 {
        return mouse
    }

    draw_w := FIELD_W * scale
    draw_h := FIELD_H * scale
    offset_x := (screen_w - draw_w) * 0.5
    offset_y := (screen_h - draw_h) * 0.5

    return [2]f32{
        (mouse[0] - offset_x) / scale,
        (mouse[1] - offset_y) / scale,
    }
}

present_logical_canvas :: proc(target: rl.RenderTexture2D) {
    screen_w := f32(rl.GetScreenWidth())
    screen_h := f32(rl.GetScreenHeight())
    scale := min(screen_w / FIELD_W, screen_h / FIELD_H)

    draw_w := FIELD_W * scale
    draw_h := FIELD_H * scale
    offset_x := (screen_w - draw_w) * 0.5
    offset_y := (screen_h - draw_h) * 0.5

    source := rl.Rectangle{0, 0, FIELD_W, -FIELD_H}
    dest := rl.Rectangle{offset_x, offset_y, draw_w, draw_h}
    rl.DrawTexturePro(
        target.texture,
        source,
        dest,
        [2]f32{0, 0},
        0,
        rl.Color{255, 255, 255, 255},
    )
}

draw_text :: proc(text: string, x, y, size: int, colour: rl.Color) {
    buf: [1024]u8
    n := len(text)
    if n > len(buf) - 1 {
        n = len(buf) - 1
    }
    if n > 0 {
        copy(buf[:n], transmute([]u8)text[:n])
    }
    buf[n] = 0
    rl.DrawText(cstring(raw_data(buf[:])), i32(x), i32(y), i32(size), colour)
}

draw_text_centered :: proc(text: string, y, size: int, colour: rl.Color) {
    buf: [1024]u8
    n := len(text)
    if n > len(buf) - 1 {
        n = len(buf) - 1
    }
    if n > 0 {
        copy(buf[:n], transmute([]u8)text[:n])
    }
    buf[n] = 0
    ctext := cstring(raw_data(buf[:]))
    width := rl.MeasureText(ctext, i32(size))
    rl.DrawText(ctext, i32((WINDOW_W - int(width)) / 2), i32(y), i32(size), colour)
}

button :: proc(label: string, rect: rl.Rectangle, enabled := true) -> bool {
    mouse := logical_mouse_position()
    hot := enabled && rl.CheckCollisionPointRec(mouse, rect)
    colour := PANEL
    border := ACCENT
    text_colour := FG

    if hot {
        colour = PANEL_HOVER
    }
    if !enabled {
        border = MUTED
        text_colour = MUTED
    }

    rl.DrawRectangleRec(rect, colour)
    rl.DrawRectangleLinesEx(rect, 1, border)

    buf: [512]u8
    n := len(label)
    if n > len(buf) - 1 {
        n = len(buf) - 1
    }
    if n > 0 {
        copy(buf[:n], transmute([]u8)label[:n])
    }
    buf[n] = 0
    ctext := cstring(raw_data(buf[:]))
    tw := rl.MeasureText(ctext, 22)
    tx := i32(rect.x + (rect.width - f32(tw)) * 0.5)
    ty := i32(rect.y + (rect.height - 22) * 0.5)
    rl.DrawText(ctext, tx, ty, 22, text_colour)

    clicked := hot && rl.IsMouseButtonPressed(.LEFT)
    if clicked { request_ui_click() }
    return clicked
}

text_field :: proc(label: string, field: ^Text_Field, rect: rl.Rectangle, enabled := true) -> bool {
    mouse := logical_mouse_position()
    hot := enabled && rl.CheckCollisionPointRec(mouse, rect)
    clicked := hot && rl.IsMouseButtonPressed(.LEFT)
    if clicked {
        request_ui_click()
        field.active = true
    } else if rl.IsMouseButtonPressed(.LEFT) && !hot {
        field.active = false
    }
    if !enabled {
        field.active = false
    }

    draw_text(label, int(rect.x), int(rect.y) - 25, 18, MUTED)
    fill := PANEL
    if enabled && (field.active || hot) {
        fill = PANEL_HOVER
    }
    rl.DrawRectangleRec(rect, fill)
    border := MUTED
    if field.active && enabled {
        border = ACCENT
    }
    rl.DrawRectangleLinesEx(rect, 1, border)

    value := text_field_string(field)
    value_colour := FG
    if !enabled { value_colour = MUTED }
    draw_text(value, int(rect.x) + 12, int(rect.y) + 13, 22, value_colour)

    if field.active && enabled && (int(rl.GetTime() * 2) & 1) == 0 {
        // Cursor position is approximate because this field is ASCII-only.
        buf: [256]u8
        n := len(value)
        if n > len(buf) - 1 {
            n = len(buf) - 1
        }
        if n > 0 {
            copy(buf[:n], transmute([]u8)value[:n])
        }
        buf[n] = 0
        width := rl.MeasureText(cstring(raw_data(buf[:])), 22)
        cx := rect.x + 12 + f32(width) + 2
        rl.DrawRectangle(i32(cx), i32(rect.y + 12), 2, 25, ACCENT)
    }

    return clicked
}

setting_row_int :: proc(label: string, value: ^int, y: f32, min_value, max_value, step: int, enabled := true) -> bool {
    changed := false
    draw_text(label, 285, int(y) + 12, 21, FG)
    if button("-", rl.Rectangle{560, y, 52, 48}, enabled) {
        value^ -= step
        if value^ < min_value { value^ = min_value }
        changed = true
    }

    value_buf: [64]u8
    value_text := fmt.bprintf(value_buf[:], "%d", value^)
    value_colour := FG
    if !enabled { value_colour = MUTED }
    draw_text_centered_in(value_text, rl.Rectangle{618, y, 92, 48}, 21, value_colour)

    if button("+", rl.Rectangle{716, y, 52, 48}, enabled) {
        value^ += step
        if value^ > max_value { value^ = max_value }
        changed = true
    }
    return changed
}

setting_row_f32 :: proc(label: string, value: ^f32, y: f32, min_value, max_value, step: f32, enabled := true) -> bool {
    changed := false
    draw_text(label, 285, int(y) + 12, 21, FG)
    if button("-", rl.Rectangle{560, y, 52, 48}, enabled) {
        value^ -= step
        if value^ < min_value { value^ = min_value }
        changed = true
    }

    value_buf: [64]u8
    value_text := fmt.bprintf(value_buf[:], "%.0f", value^)
    value_colour := FG
    if !enabled { value_colour = MUTED }
    draw_text_centered_in(value_text, rl.Rectangle{618, y, 92, 48}, 21, value_colour)

    if button("+", rl.Rectangle{716, y, 52, 48}, enabled) {
        value^ += step
        if value^ > max_value { value^ = max_value }
        changed = true
    }
    return changed
}

draw_text_centered_in :: proc(text: string, rect: rl.Rectangle, size: int, colour: rl.Color) {
    buf: [512]u8
    n := len(text)
    if n > len(buf) - 1 { n = len(buf) - 1 }
    if n > 0 { copy(buf[:n], transmute([]u8)text[:n]) }
    buf[n] = 0
    ctext := cstring(raw_data(buf[:]))
    width := rl.MeasureText(ctext, i32(size))
    rl.DrawText(
        ctext,
        i32(rect.x + (rect.width - f32(width)) * 0.5),
        i32(rect.y + (rect.height - f32(size)) * 0.5),
        i32(size),
        colour,
    )
}

clipboard_set_text :: proc(text: string) {
    buf: [512]u8
    n := min(len(text), len(buf) - 1)
    if n > 0 { copy(buf[:n], transmute([]u8)text[:n]) }
    buf[n] = 0
    rl.SetClipboardText(cstring(raw_data(buf[:])))
}
