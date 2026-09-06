package main

import "core:math"
import rl "vendor:raylib"

Match_Mode :: enum {
    Online,
    Vs_CPU,
    Local_2P,
}

CPU_Difficulty :: enum {
    Easy,
    Normal,
    Hard,
}

CPU_AI :: struct {
    think_timer: f32,
    target_y:    f32,
    aim_cycle:   int,
}

cpu_difficulty_name :: proc(difficulty: CPU_Difficulty) -> string {
    switch difficulty {
    case .Easy:   return "EASY"
    case .Normal: return "NORMAL"
    case .Hard:   return "HARD"
    }
    return "NORMAL"
}

cpu_difficulty_previous :: proc(difficulty: CPU_Difficulty) -> CPU_Difficulty {
    switch difficulty {
    case .Easy:   return .Hard
    case .Normal: return .Easy
    case .Hard:   return .Normal
    }
    return .Normal
}

cpu_difficulty_next :: proc(difficulty: CPU_Difficulty) -> CPU_Difficulty {
    switch difficulty {
    case .Easy:   return .Normal
    case .Normal: return .Hard
    case .Hard:   return .Easy
    }
    return .Normal
}

reset_cpu_ai :: proc(ai: ^CPU_AI) {
    ai^ = CPU_AI{}
    ai.target_y = FIELD_H * 0.5
}

// Predict where the ball will cross the CPU paddle's x position, including
// top/bottom wall reflections. The difficulty layer below deliberately adds
// reaction delay and aim error; the paddle itself never exceeds Game_Rules.
cpu_predicted_intercept_y :: proc(g: ^Game_State) -> f32 {
    if g.ball_vx <= 1 {
        return FIELD_H * 0.5
    }

    travel_x := (P2_X - BALL_RADIUS) - g.ball_x
    if travel_x <= 0 {
        return g.ball_y
    }

    t := travel_x / g.ball_vx
    y := g.ball_y + g.ball_vy * t
    low := BALL_RADIUS
    high := FIELD_H - BALL_RADIUS

    // A Pong flight cannot realistically require many reflections, but the
    // fixed cap makes malformed/extreme custom speeds harmless too.
    for _ in 0..<24 {
        if y < low {
            y = low + (low - y)
            continue
        }
        if y > high {
            y = high - (y - high)
            continue
        }
        break
    }
    return math.clamp(y, low, high)
}

cpu_paddle_direction :: proc(ai: ^CPU_AI, g: ^Game_State, difficulty: CPU_Difficulty, dt: f32) -> f32 {
    reaction: f32 = 0.13
    dead_zone: f32 = 22
    error_amount: f32 = 24

    switch difficulty {
    case .Easy:
        reaction = 0.27
        dead_zone = 35
        error_amount = 58
    case .Normal:
        reaction = 0.13
        dead_zone = 22
        error_amount = 24
    case .Hard:
        reaction = 0.065
        dead_zone = 12
        error_amount = 8
    }

    ai.think_timer -= dt
    if ai.think_timer <= 0 {
        ai.think_timer = reaction
        ai.aim_cycle = (ai.aim_cycle + 1) % 6

        target := FIELD_H * 0.5
        if g.ball_vx > 0 && g.countdown_timer <= 0 && g.serve_timer <= 0 {
            target = cpu_predicted_intercept_y(g)
        }

        // Deterministic aim error: difficulty is repeatable and does not need
        // a separate RNG stream that could interfere with networking IDs.
        error_factor: f32 = 0
        if ai.aim_cycle == 0 {
            error_factor = -1.0
        } else if ai.aim_cycle == 1 {
            error_factor = 0.45
        } else if ai.aim_cycle == 2 {
            error_factor = -0.30
        } else if ai.aim_cycle == 3 {
            error_factor = 0.85
        } else if ai.aim_cycle == 4 {
            error_factor = -0.60
        } else {
            error_factor = 0.20
        }
        target += error_factor * error_amount
        ai.target_y = math.clamp(target, BALL_RADIUS, FIELD_H - BALL_RADIUS)
    }

    paddle_center := g.p2_y + PADDLE_H * 0.5
    delta := ai.target_y - paddle_center
    if math.abs(delta) <= dead_zone {
        return 0
    }
    if delta < 0 {
        return -1
    }
    return 1
}

input_gamepad_direction_for :: proc(gamepad: i32) -> f32 {
    if !rl.IsGamepadAvailable(gamepad) { return 0 }

    up := rl.IsGamepadButtonDown(gamepad, .LEFT_FACE_UP)
    down := rl.IsGamepadButtonDown(gamepad, .LEFT_FACE_DOWN)
    axis := rl.GetGamepadAxisMovement(gamepad, .LEFT_Y)
    if axis < -GAMEPAD_DEADZONE { up = true }
    if axis > GAMEPAD_DEADZONE { down = true }
    if up == down { return 0 }
    if up { return -1 }
    return 1
}

input_local_p1_direction :: proc() -> f32 {
    when PONG_ANDROID {
        return 0
    } else {
        up := rl.IsKeyDown(.W)
        down := rl.IsKeyDown(.S)
        if up != down {
            if up { return -1 }
            return 1
        }
        return input_gamepad_direction_for(0)
    }
    return 0
}

input_local_p2_direction :: proc() -> f32 {
    when PONG_ANDROID {
        return 0
    } else {
        up := rl.IsKeyDown(.UP)
        down := rl.IsKeyDown(.DOWN)
        if up != down {
            if up { return -1 }
            return 1
        }
        return input_gamepad_direction_for(1)
    }
    return 0
}

// Android local 2P: each side owns its half of the screen. Two simultaneous
// touches therefore control both paddles without either player stealing the
// other's finger. This mode intentionally uses simple hold zones rather than
// swipe state, because touch IDs may be reordered by the platform.
input_android_local_2p :: proc() -> (p1, p2: f32) {
    when !PONG_ANDROID { return 0, 0 }

    count := rl.GetTouchPointCount()
    midpoint_y := FIELD_H * 0.5
    for i in 0..<count {
        point := logical_screen_position(rl.GetTouchPosition(i32(i)))
        x := point[0]
        y := point[1]

        // Reserve the top-right MENU button area.
        if x >= f32(WINDOW_W - 150) && y <= 70 {
            continue
        }

        direction: f32 = 0
        if y < midpoint_y - MOBILE_MID_DEADZONE {
            direction = -1
        } else if y > midpoint_y + MOBILE_MID_DEADZONE {
            direction = 1
        }

        if x < FIELD_W * 0.5 {
            p1 = direction
        } else {
            p2 = direction
        }
    }
    return
}
