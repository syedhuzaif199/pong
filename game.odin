package main

import "core:math"
import rl "vendor:raylib"

WINDOW_W :: 960
WINDOW_H :: 540

FIELD_W :: f32(WINDOW_W)
FIELD_H :: f32(WINDOW_H)

PADDLE_W :: f32(16)
PADDLE_H :: f32(104)
PADDLE_MARGIN :: f32(38)
BALL_RADIUS :: f32(10)

P1_X :: PADDLE_MARGIN
P2_X :: FIELD_W - PADDLE_MARGIN - PADDLE_W

// These rules belong to a match, not to the application's Settings menu.
// The host chooses them before each game and sends them to the client.
Game_Rules :: struct {
    winning_score: int,
    ball_speed:    f32,
    paddle_speed:  f32,
}

Game_State :: struct {
    p1_y: f32,
    p2_y: f32,

    ball_x:  f32,
    ball_y:  f32,
    ball_vx: f32,
    ball_vy: f32,

    score1: int,
    score2: int,

    game_over: bool,
    winner:    int,

    serve_timer:     f32,
    serve_dir:       f32,
    countdown_timer: f32,
    go_timer:        f32,
}

default_game_rules :: proc() -> Game_Rules {
    return Game_Rules{
        winning_score = 7,
        ball_speed = 460,
        paddle_speed = 430,
    }
}

reset_match :: proc(g: ^Game_State) {
    g^ = Game_State{}
    g.p1_y = (FIELD_H - PADDLE_H) * 0.5
    g.p2_y = (FIELD_H - PADDLE_H) * 0.5
    g.serve_dir = 1
    reset_round(g)
}

begin_match_countdown :: proc(g: ^Game_State) {
    reset_match(g)
    g.countdown_timer = 3.0
    g.go_timer = 0
    g.serve_timer = 0
    g.ball_vx = 0
    g.ball_vy = 0
}

reset_round :: proc(g: ^Game_State) {
    g.ball_x = FIELD_W * 0.5
    g.ball_y = FIELD_H * 0.5
    g.ball_vx = 0
    g.ball_vy = 0
    g.serve_timer = 0.75
}

launch_ball :: proc(g: ^Game_State, speed: f32) {
    // Alternate the vertical direction from the score so serves stay deterministic.
    y_sign: f32 = 1
    if ((g.score1 + g.score2) & 1) != 0 {
        y_sign = -1
    }

    x := speed * 0.91 * g.serve_dir
    y := speed * 0.42 * y_sign
    g.ball_vx = x
    g.ball_vy = y
}

move_paddle :: proc(y: ^f32, direction, speed, dt: f32) {
    y^ += direction * speed * dt
    y^ = math.clamp(y^, 0, FIELD_H - PADDLE_H)
}

step_host_game :: proc(g: ^Game_State, rules: Game_Rules, p1_input, p2_input, dt: f32) {
    if g.game_over {
        return
    }

    if g.countdown_timer > 0 {
        g.countdown_timer -= dt
        if g.countdown_timer <= 0 {
            g.countdown_timer = 0
            g.go_timer = 0.45
            launch_ball(g, rules.ball_speed)
        }
        return
    }

    if g.go_timer > 0 {
        g.go_timer -= dt
        if g.go_timer < 0 { g.go_timer = 0 }
    }

    move_paddle(&g.p1_y, p1_input, rules.paddle_speed, dt)
    move_paddle(&g.p2_y, p2_input, rules.paddle_speed, dt)

    if g.serve_timer > 0 {
        g.serve_timer -= dt
        if g.serve_timer <= 0 {
            launch_ball(g, rules.ball_speed)
        }
        return
    }

    g.ball_x += g.ball_vx * dt
    g.ball_y += g.ball_vy * dt

    if g.ball_y - BALL_RADIUS < 0 {
        g.ball_y = BALL_RADIUS
        if g.ball_vy < 0 {
            g.ball_vy = -g.ball_vy
        }
    } else if g.ball_y + BALL_RADIUS > FIELD_H {
        g.ball_y = FIELD_H - BALL_RADIUS
        if g.ball_vy > 0 {
            g.ball_vy = -g.ball_vy
        }
    }

    // Left paddle.
    if g.ball_vx < 0 &&
       g.ball_x - BALL_RADIUS <= P1_X + PADDLE_W &&
       g.ball_x + BALL_RADIUS >= P1_X &&
       g.ball_y + BALL_RADIUS >= g.p1_y &&
       g.ball_y - BALL_RADIUS <= g.p1_y + PADDLE_H {
        g.ball_x = P1_X + PADDLE_W + BALL_RADIUS
        bounce_from_paddle(g, g.p1_y, true, rules.ball_speed)
    }

    // Right paddle.
    if g.ball_vx > 0 &&
       g.ball_x + BALL_RADIUS >= P2_X &&
       g.ball_x - BALL_RADIUS <= P2_X + PADDLE_W &&
       g.ball_y + BALL_RADIUS >= g.p2_y &&
       g.ball_y - BALL_RADIUS <= g.p2_y + PADDLE_H {
        g.ball_x = P2_X - BALL_RADIUS
        bounce_from_paddle(g, g.p2_y, false, rules.ball_speed)
    }

    if g.ball_x + BALL_RADIUS < 0 {
        g.score2 += 1
        finish_point(g, 2, rules.winning_score)
    } else if g.ball_x - BALL_RADIUS > FIELD_W {
        g.score1 += 1
        finish_point(g, 1, rules.winning_score)
    }
}

bounce_from_paddle :: proc(g: ^Game_State, paddle_y: f32, go_right: bool, base_speed: f32) {
    centre := paddle_y + PADDLE_H * 0.5
    impact := (g.ball_y - centre) / (PADDLE_H * 0.5)
    impact = math.clamp(impact, -1, 1)

    horizontal_speed := g.ball_vx
    if horizontal_speed < 0 {
        horizontal_speed = -horizontal_speed
    }
    horizontal_speed *= 1.035
    horizontal_speed = min(horizontal_speed, base_speed * 1.75)

    if go_right {
        g.ball_vx = horizontal_speed
    } else {
        g.ball_vx = -horizontal_speed
    }

    g.ball_vy += impact * 185
    g.ball_vy = math.clamp(g.ball_vy, -base_speed * 1.25, base_speed * 1.25)
}

finish_point :: proc(g: ^Game_State, scorer, winning_score: int) {
    if g.score1 >= winning_score || g.score2 >= winning_score {
        g.game_over = true
        g.winner = scorer
        g.ball_vx = 0
        g.ball_vy = 0
        return
    }

    // Serve towards the player who conceded the point.
    if scorer == 1 {
        g.serve_dir = 1
    } else {
        g.serve_dir = -1
    }
    reset_round(g)
}

lerp_f32 :: proc(a, b, t: f32) -> f32 {
    return a + (b - a) * t
}

interpolate_render_state :: proc(render: ^Game_State, target: Game_State, dt, prediction_seconds: f32) {
    // Scores and terminal state should never visually lag behind a snapshot.
    render.score1 = target.score1
    render.score2 = target.score2
    render.game_over = target.game_over
    render.winner = target.winner
    render.serve_timer = target.serve_timer
    render.serve_dir = target.serve_dir
    render.countdown_timer = target.countdown_timer
    render.go_timer = target.go_timer
    render.ball_vx = target.ball_vx
    render.ball_vy = target.ball_vy

    predicted_ball_x := target.ball_x
    predicted_ball_y := target.ball_y

    // The newest host snapshot is already roughly half an RTT old when it arrives.
    // Extrapolate the ball only a short, capped distance toward "now"; authoritative
    // snapshots still correct every frame and scoring remains host-owned.
    if prediction_seconds > 0 && !target.game_over &&
       target.countdown_timer <= 0 && target.serve_timer <= 0 {
        predicted_ball_x += target.ball_vx * prediction_seconds
        predicted_ball_y += target.ball_vy * prediction_seconds

        if predicted_ball_y - BALL_RADIUS < 0 {
            predicted_ball_y = BALL_RADIUS + (BALL_RADIUS - predicted_ball_y)
        } else if predicted_ball_y + BALL_RADIUS > FIELD_H {
            limit := FIELD_H - BALL_RADIUS
            predicted_ball_y = limit - (predicted_ball_y - limit)
        }

        // Never visually invent a score before the host reports it.
        predicted_ball_x = math.clamp(predicted_ball_x, -BALL_RADIUS, FIELD_W + BALL_RADIUS)
    }

    // Faster correction than the old dt*18 chase removes a large amount of
    // additional visual latency while still smoothing ordinary packet jitter.
    world_t := math.clamp(dt * 30.0, f32(0), f32(1))
    render.p1_y = lerp_f32(render.p1_y, target.p1_y, world_t)
    render.ball_x = lerp_f32(render.ball_x, predicted_ball_x, world_t)
    render.ball_y = lerp_f32(render.ball_y, predicted_ball_y, world_t)

    // The client predicts its own (right) paddle locally. Correct it gently so
    // normal RTT does not turn into visible snapping.
    local_error := target.p2_y - render.p2_y
    local_t := math.clamp(dt * 7.0, f32(0), f32(1))
    if math.abs(local_error) > 90 {
        local_t = math.clamp(dt * 20.0, f32(0), f32(1))
    }
    render.p2_y = lerp_f32(render.p2_y, target.p2_y, local_t)
}

local_input_direction :: proc() -> f32 {
    when PONG_ANDROID {
        if rl.GetTouchPointCount() <= 0 { return 0 }

        // Map physical phone coordinates back into the fixed 960x540 game
        // canvas so the control split follows the actual play field even on
        // letterboxed screens.
        touch := rl.GetTouchPosition(0)
        screen_w := f32(rl.GetScreenWidth())
        screen_h := f32(rl.GetScreenHeight())
        if screen_w <= 0 || screen_h <= 0 { return 0 }

        scale_x := screen_w / f32(WINDOW_W)
        scale_y := screen_h / f32(WINDOW_H)
        scale := min(scale_x, scale_y)
        if scale <= 0 { return 0 }
        offset_x := (screen_w - f32(WINDOW_W) * scale) * 0.5
        offset_y := (screen_h - f32(WINDOW_H) * scale) * 0.5
        logical_x := (touch[0] - offset_x) / scale
        logical_y := (touch[1] - offset_y) / scale

        // The Android-only MENU button lives in this corner. A menu tap must
        // not leak through as one frame of paddle movement.
        if logical_x >= f32(WINDOW_W - 125) && logical_y <= 60 { return 0 }

        // Preserve desktop gameplay parity: mobile input is still exactly
        // -1/0/+1 and therefore uses the same fixed paddle speed as keyboard.
        if logical_y < f32(FIELD_H) * 0.5 { return -1 }
        return 1
    } else {
        up := rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)
        down := rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)

        if up == down { return 0 }
        if up { return -1 }
        return 1
    }
}
