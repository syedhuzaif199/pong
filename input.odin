package main

import rl "vendor:raylib"

Paddle_Input_Source :: enum {
    None,
    Keyboard,
    Touch,
    Gamepad,
}

Input_State :: struct {
    source: Paddle_Input_Source,

    mobile_touch_active: bool,
    mobile_anchor_y: f32,
    mobile_last_y: f32,
    mobile_drag_direction: f32,
}

GAMEPAD_DEADZONE :: f32(0.35)
MOBILE_SWIPE_DEADZONE :: f32(24)
MOBILE_MID_DEADZONE :: f32(18)

input_gamepad_direction :: proc() -> f32 {
    if !rl.IsGamepadAvailable(0) { return 0 }

    up := rl.IsGamepadButtonDown(0, .LEFT_FACE_UP)
    down := rl.IsGamepadButtonDown(0, .LEFT_FACE_DOWN)
    axis := rl.GetGamepadAxisMovement(0, .LEFT_Y)

    if axis < -GAMEPAD_DEADZONE { up = true }
    if axis > GAMEPAD_DEADZONE { down = true }

    if up == down { return 0 }
    if up { return -1 }
    return 1
}

input_gamepad_menu_pressed :: proc() -> bool {
    return rl.IsGamepadAvailable(0) && rl.IsGamepadButtonPressed(0, .MIDDLE_RIGHT)
}

input_gamepad_back_pressed :: proc() -> bool {
    return rl.IsGamepadAvailable(0) && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_RIGHT)
}

input_confirm_pressed :: proc() -> bool {
    alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
    if !alt_down && rl.IsKeyPressed(.ENTER) { return true }
    return rl.IsGamepadAvailable(0) && rl.IsGamepadButtonPressed(0, .RIGHT_FACE_DOWN)
}

input_back_pressed :: proc() -> bool {
    return platform_window_back_pressed() || input_gamepad_back_pressed()
}

input_pause_pressed :: proc() -> bool {
    return platform_window_back_pressed() || input_gamepad_menu_pressed() || input_gamepad_back_pressed()
}

input_mobile_direction :: proc(state: ^Input_State) -> f32 {
    when !PONG_ANDROID { return 0 }

    if rl.GetTouchPointCount() <= 0 {
        state.mobile_touch_active = false
        state.mobile_drag_direction = 0
        return 0
    }

    touch := logical_screen_position(rl.GetTouchPosition(0))
    logical_x := touch[0]
    logical_y := touch[1]

    // Do not turn taps on the Android menu button into paddle movement.
    if logical_x >= f32(WINDOW_W - 150) && logical_y <= 70 {
        state.mobile_touch_active = false
        state.mobile_drag_direction = 0
        return 0
    }

    if !state.mobile_touch_active {
        state.mobile_touch_active = true
        state.mobile_anchor_y = logical_y
        state.mobile_last_y = logical_y
        state.mobile_drag_direction = 0
    } else {
        delta := logical_y - state.mobile_anchor_y
        step_delta := logical_y - state.mobile_last_y

        // Crossing the swipe threshold enters drag mode. Once dragging, a
        // small deliberate movement in the opposite direction reverses the
        // requested direction without requiring the finger to cross its
        // original touch point again.
        if delta <= -MOBILE_SWIPE_DEADZONE {
            state.mobile_drag_direction = -1
            state.mobile_anchor_y = logical_y
        } else if delta >= MOBILE_SWIPE_DEADZONE {
            state.mobile_drag_direction = 1
            state.mobile_anchor_y = logical_y
        } else if state.mobile_drag_direction != 0 {
            if step_delta <= -6 {
                state.mobile_drag_direction = -1
                state.mobile_anchor_y = logical_y
            } else if step_delta >= 6 {
                state.mobile_drag_direction = 1
                state.mobile_anchor_y = logical_y
            }
        }
        state.mobile_last_y = logical_y
    }

    // A deliberate swipe/drag overrides the old half-screen hold controls.
    if state.mobile_drag_direction != 0 {
        return state.mobile_drag_direction
    }

    midpoint := f32(FIELD_H) * 0.5
    if logical_y < midpoint - MOBILE_MID_DEADZONE { return -1 }
    if logical_y > midpoint + MOBILE_MID_DEADZONE { return 1 }
    return 0
}

input_paddle_direction :: proc(state: ^Input_State) -> f32 {
    state.source = .None

    when PONG_ANDROID {
        touch := input_mobile_direction(state)
        if touch != 0 {
            state.source = .Touch
            return touch
        }
    }

    pad := input_gamepad_direction()
    if pad != 0 {
        state.source = .Gamepad
        return pad
    }

    when !PONG_ANDROID {
        up := rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)
        down := rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)
        if up != down {
            state.source = .Keyboard
            if up { return -1 }
            return 1
        }
    }

    return 0
}

input_source_name :: proc(source: Paddle_Input_Source) -> string {
    switch source {
    case .None:     return "idle"
    case .Keyboard: return "keyboard"
    case .Touch:    return "touch"
    case .Gamepad:  return "controller"
    }
    return "idle"
}
