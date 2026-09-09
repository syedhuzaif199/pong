package main

import "core:math"
import rl "vendor:raylib"

Match_Mode :: enum {
    Online,
    Vs_CPU,
    Local_2P,
    Local_Doubles,
}

CPU_Difficulty :: enum {
    Easy,
    Normal,
    Hard,
}

CPU_AI :: struct {
    target_y: f32,
    velocity: f32,
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

// Predict the landing position from the current velocity without angle error.
cpu_path_landing :: proc(x, y, vx, vy: f32) -> f32 {
    if vx <= 0 { return FIELD_H / 2 }
    travel_time := max(f32(0), (P2_X - BALL_RADIUS - x) / vx)
    unfolded := y - BALL_RADIUS + vy * travel_time
    span := FIELD_H - BALL_RADIUS * 2
    wrapped := unfolded - math.floor(unfolded / (span * 2)) * (span * 2)
    if wrapped > span { wrapped = span * 2 - wrapped }
    return BALL_RADIUS + wrapped
}

cpu_paddle_direction :: proc(ai: ^CPU_AI, g: ^Game_State, difficulty: CPU_Difficulty, dt: f32, slot: int = 2, paddle_speed: f32 = 430) -> f32 {
    if g.game_over || g.countdown_timer > 0 || g.serve_timer > 0 || g.between_games_timer > 0 {
        reset_cpu_ai(ai)
        return 0
    }
    if dt <= 0 { return 0 }
    low := PADDLE_H / 2
    high := FIELD_H - PADDLE_H / 2
    if g.doubles {
        if slot == 3 { low += FIELD_H / 2 } else { high -= FIELD_H / 2 }
    }
    if g.ball_vx > 0 {
        ai.target_y = math.clamp(cpu_path_landing(g.ball_x, g.ball_y, g.ball_vx, g.ball_vy), low, high)
    } else {
        ai.target_y = (low + high) / 2
    }
    delta := ai.target_y - (paddle_position(g, slot)^ + PADDLE_H / 2)
    profile := cpu_movement_profile(difficulty)
    cap := paddle_speed * profile.speed_fraction
    acceleration := cap / profile.acceleration_time
    braking := cap / profile.braking_time
    // A stopping-distance controller brakes toward the target instead of
    // intentionally overshooting it. A new shot can still demand an impossible reversal.
    safe_speed := math.sqrt(2 * braking * max(f32(0), math.abs(delta) - 2))
    desired := min(cap, safe_speed)
    if delta < 0 { desired = -desired }
    rate := acceleration
    if ai.velocity * desired < 0 || math.abs(desired) < math.abs(ai.velocity) { rate = braking }
    ai.velocity += math.clamp(desired - ai.velocity, -rate * dt, rate * dt)
    y := paddle_position(g, slot)^
    if (y <= low - PADDLE_H/2 && ai.velocity < 0) || (y >= high - PADDLE_H/2 && ai.velocity > 0) { ai.velocity = 0 }
    if paddle_speed <= 0 { return 0 }
    return math.clamp(ai.velocity / paddle_speed, -profile.speed_fraction, profile.speed_fraction)
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

cpu_doubles_direction :: proc(ai: ^CPU_AI, g: ^Game_State, difficulty: CPU_Difficulty, dt: f32, slot: int, paddle_speed: f32 = 430) -> f32 {
    return cpu_paddle_direction(ai, g, difficulty, dt, slot, paddle_speed)
}

CPU_Movement_Profile :: struct {
    speed_fraction, acceleration_time, braking_time: f32,
}

cpu_movement_profile :: proc(difficulty: CPU_Difficulty) -> CPU_Movement_Profile {
    switch difficulty {
    case .Easy: return {0.62, 0.35, 0.22}
    case .Normal: return {0.78, 0.24, 0.16}
    case .Hard: return {0.90, 0.16, 0.11}
    }
    return {0.78, 0.24, 0.16}
}
