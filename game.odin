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
    doubles: bool,
    winning_score:    int,
    ball_speed:       f32,
    paddle_speed:     f32,
    best_of:          int,
    win_by_two:       bool,
    paddle_spin:      bool,
    ball_acceleration: bool,
}

Game_State :: struct {
    power_window: [4]f32,
    power_cooldown: [4]f32,
    shot_flash: f32,
    last_hit_slot: int,
    last_hit_spin: f32,
    ball_power: bool,

    doubles: bool,
    p3_y, p4_y: f32,
    p1_y: f32,
    p2_y: f32,

    ball_x:  f32,
    ball_y:  f32,
    ball_vx: f32,
    ball_vy: f32,

    score1: int,
    score2: int,

    // A competitive match is a best-of set of games. `game_over` means the
    // entire match is complete, not merely that one game has ended.
    games1: int,
    games2: int,
    last_game_winner: int,
    between_games_timer: f32,

    total_points1: int,
    total_points2: int,
    current_rally: int,
    longest_rally: int,
    fastest_ball: f32,
    match_elapsed: f32,

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
        best_of = 3,
        win_by_two = true,
        paddle_spin = true,
        ball_acceleration = true,
    }
}

reset_match :: proc(g: ^Game_State) {
    g^ = Game_State{}
    g.p1_y = (FIELD_H - PADDLE_H) * 0.5
    g.p2_y = (FIELD_H - PADDLE_H) * 0.5
    g.serve_dir = 1
    reset_round(g)
}

begin_match_countdown :: proc(g: ^Game_State, doubles := false) {
    reset_match(g)
    configure_doubles(g, doubles)
    g.countdown_timer = 3.0
    g.go_timer = 0
    g.serve_timer = 0
    g.ball_vx = 0
    g.ball_vy = 0
}

reset_round :: proc(g: ^Game_State) {
    g.power_window = {}
    g.ball_power = false
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

step_host_game :: proc(g: ^Game_State, rules: Game_Rules, p1_input, p2_input, dt: f32, p3_input: f32 = 0, p4_input: f32 = 0) {
    if g.doubles != rules.doubles { configure_doubles(g, rules.doubles) }
    if g.game_over {
        return
    }

    g.match_elapsed += dt
    g.shot_flash = max(f32(0), g.shot_flash - dt)
    for slot in 0..<4 { g.power_cooldown[slot] = max(f32(0), g.power_cooldown[slot] - dt) }
    // Expire after collision processing so a press gets its full timing window.
    defer for slot in 0..<4 { g.power_window[slot] = max(f32(0), g.power_window[slot] - dt) }

    if g.between_games_timer > 0 {
        g.between_games_timer -= dt
        if g.between_games_timer <= 0 {
            g.between_games_timer = 0
            g.score1 = 0
            g.score2 = 0
            g.p1_y = (FIELD_H - PADDLE_H) * 0.5
            g.p2_y = (FIELD_H - PADDLE_H) * 0.5
            configure_doubles(g, rules.doubles)
            g.power_window = {}
            g.ball_power = false
            g.ball_x = FIELD_W * 0.5
            g.ball_y = FIELD_H * 0.5
            g.ball_vx = 0
            g.ball_vy = 0
            g.current_rally = 0
            if ((g.games1 + g.games2) & 1) != 0 {
                g.serve_dir = -1
            } else {
                g.serve_dir = 1
            }
            g.countdown_timer = 3.0
            g.go_timer = 0
            g.serve_timer = 0
        }
        return
    }

    if g.countdown_timer > 0 {
        g.countdown_timer -= dt
        if g.countdown_timer <= 0 {
            g.countdown_timer = 0
            g.go_timer = 0.45
            launch_ball(g, rules.ball_speed)
            update_fastest_ball(g)
        }
        return
    }

    if g.go_timer > 0 {
        g.go_timer -= dt
        if g.go_timer < 0 { g.go_timer = 0 }
    }

    inputs := [4]f32{p1_input, p3_input, p2_input, p4_input}
    velocities: [4]f32
    for slot in 0..<4 {
        if !rules.doubles && (slot == 1 || slot == 3) { continue }
        y := paddle_position(g, slot)
        before := y^
        move_player_paddle(g, slot, inputs[slot], rules.paddle_speed, dt)
        if dt > 0 { velocities[slot] = (y^ - before) / dt }
    }

    if g.serve_timer > 0 {
        g.serve_timer -= dt
        if g.serve_timer <= 0 {
            launch_ball(g, rules.ball_speed)
            update_fastest_ball(g)
        }
        return
    }

    previous_x := g.ball_x
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

    for slot in 0..<4 {
        if !rules.doubles && (slot == 1 || slot == 3) { continue }
        left := slot < 2
        x := P2_X
        if left { x = P1_X }
        y := paddle_position(g, slot)^
        crossing := (!left && g.ball_vx > 0 && previous_x - BALL_RADIUS <= x + PADDLE_W && g.ball_x + BALL_RADIUS >= x) ||
                    (left && g.ball_vx < 0 && previous_x + BALL_RADIUS >= x && g.ball_x - BALL_RADIUS <= x + PADDLE_W)
        if crossing && g.ball_y + BALL_RADIUS >= y && g.ball_y - BALL_RADIUS <= y + PADDLE_H {
            if left { g.ball_x = x + PADDLE_W + BALL_RADIUS } else { g.ball_x = x - BALL_RADIUS }
            powered := g.power_window[slot] > 0
            bounce_from_paddle(g, y, velocities[slot], left, rules, powered)
            g.power_window[slot] = 0
            g.last_hit_slot = slot
            g.last_hit_spin = 0
            if rules.paddle_spin { g.last_hit_spin = velocities[slot] / max(f32(1), rules.paddle_speed) }
            g.shot_flash = 0.45
            record_rally_hit(g)
            break
        }
    }

    update_fastest_ball(g)

    if g.ball_x + BALL_RADIUS < 0 {
        g.score2 += 1
        g.total_points2 += 1
        g.current_rally = 0
        finish_point(g, 2, rules)
    } else if g.ball_x - BALL_RADIUS > FIELD_W {
        g.score1 += 1
        g.total_points1 += 1
        g.current_rally = 0
        finish_point(g, 1, rules)
    }
}

record_rally_hit :: proc(g: ^Game_State) {
    g.current_rally += 1
    if g.current_rally > g.longest_rally {
        g.longest_rally = g.current_rally
    }
}

update_fastest_ball :: proc(g: ^Game_State) {
    speed := math.sqrt(g.ball_vx*g.ball_vx + g.ball_vy*g.ball_vy)
    if speed > g.fastest_ball {
        g.fastest_ball = speed
    }
}

bounce_from_paddle :: proc(g: ^Game_State, paddle_y, paddle_velocity: f32, go_right: bool, rules: Game_Rules, powered := false) {
    impact := math.clamp((g.ball_y - paddle_y - PADDLE_H/2) / (PADDLE_H/2), f32(-1), f32(1))
    speed := math.sqrt(g.ball_vx*g.ball_vx + g.ball_vy*g.ball_vy)
    if g.ball_power { speed /= POWER_SPEED_MULTIPLIER }
    if rules.ball_acceleration { speed = min(max(speed, rules.ball_speed) * 1.035, rules.ball_speed * 1.75) } else { speed = rules.ball_speed }
    // Contact position deliberately selects the return angle: centre is flat,
    // edges are steep. Moving through contact adds bounded, directional spin.
    angle := impact * 55
    if rules.paddle_spin { angle += math.clamp(paddle_velocity / max(f32(1), rules.paddle_speed), f32(-1), f32(1)) * 18 }
    angle = math.clamp(angle, f32(-70), f32(70)) * math.PI / 180
    if powered { speed = min(speed * POWER_SPEED_MULTIPLIER, rules.ball_speed * 2.1) }
    g.ball_power = powered
    g.ball_vx = math.cos(angle) * speed
    if !go_right { g.ball_vx = -g.ball_vx }
    g.ball_vy = math.sin(angle) * speed
}

POWER_WINDOW :: f32(0.18)
POWER_COOLDOWN :: f32(3)
POWER_SPEED_MULTIPLIER :: f32(1.32)

arm_power_return :: proc(g: ^Game_State, slot: int) -> bool {
    if slot < 0 || slot > 3 || (!g.doubles && (slot == 1 || slot == 3)) { return false }
    if g.game_over || g.countdown_timer > 0 || g.serve_timer > 0 || g.between_games_timer > 0 || g.power_cooldown[slot] > 0 { return false }
    g.power_window[slot] = POWER_WINDOW
    // Every attempt spends the cooldown; holding/spamming cannot guarantee a power hit.
    g.power_cooldown[slot] = POWER_COOLDOWN
    return true
}

game_score_is_winning :: proc(score, other_score: int, rules: Game_Rules) -> bool {
    if score < rules.winning_score { return false }
    if !rules.win_by_two { return true }
    return score - other_score >= 2
}

finish_point :: proc(g: ^Game_State, scorer: int, rules: Game_Rules) {
    game_won := false
    if scorer == 1 {
        game_won = game_score_is_winning(g.score1, g.score2, rules)
    } else {
        game_won = game_score_is_winning(g.score2, g.score1, rules)
    }

    if game_won {
        g.last_game_winner = scorer
        if scorer == 1 {
            g.games1 += 1
        } else {
            g.games2 += 1
        }

        needed := games_needed_to_win(rules.best_of)
        if g.games1 >= needed || g.games2 >= needed {
            g.game_over = true
            g.winner = scorer
            g.ball_vx = 0
            g.ball_vy = 0
            return
        }

        g.ball_vx = 0
        g.ball_vy = 0
        g.serve_timer = 0
        g.go_timer = 0
        g.between_games_timer = 1.6
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

interpolate_render_state :: proc(render: ^Game_State, target: Game_State, dt, prediction_seconds, jitter_ms: f32, local_slot: int = 2) {
    render.doubles = target.doubles
    render.power_window = target.power_window
    render.power_cooldown = target.power_cooldown
    render.shot_flash = target.shot_flash
    render.last_hit_slot = target.last_hit_slot
    render.last_hit_spin = target.last_hit_spin
    render.ball_power = target.ball_power
    // Scores and terminal state should never visually lag behind a snapshot.
    render.score1 = target.score1
    render.score2 = target.score2
    render.games1 = target.games1
    render.games2 = target.games2
    render.last_game_winner = target.last_game_winner
    render.between_games_timer = target.between_games_timer
    render.total_points1 = target.total_points1
    render.total_points2 = target.total_points2
    render.current_rally = target.current_rally
    render.longest_rally = target.longest_rally
    render.fastest_ball = target.fastest_ball
    render.match_elapsed = target.match_elapsed
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
    if prediction_seconds > 0 && !target.game_over && target.between_games_timer <= 0 &&
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

    // Clean links can correct aggressively; jittery links get more damping so
    // packet bunching does not turn into visible micro-teleports. Large errors
    // always catch up quickly regardless of the current jitter estimate.
    world_speed: f32 = 38.0
    if jitter_ms > 12 { world_speed = 30.0 }
    if jitter_ms > 25 { world_speed = 24.0 }

    ball_error_x := predicted_ball_x - render.ball_x
    ball_error_y := predicted_ball_y - render.ball_y
    if math.abs(ball_error_x) > 80 || math.abs(ball_error_y) > 70 {
        world_speed = max(world_speed, f32(70))
    }

    world_t := math.clamp(dt * world_speed, f32(0), f32(1))
    render.ball_x = lerp_f32(render.ball_x, predicted_ball_x, world_t)
    render.ball_y = lerp_f32(render.ball_y, predicted_ball_y, world_t)
    target_copy := target
    for slot in 0..<4 {
        y := paddle_position(render, slot)
        desired := paddle_position(&target_copy, slot)^
        correction := world_t
        if slot == local_slot {
            correction = math.clamp(dt * 7, f32(0), f32(1))
            if math.abs(desired - y^) > 90 { correction = math.clamp(dt * 20, f32(0), f32(1)) }
        }
        y^ = lerp_f32(y^, desired, correction)
    }
}

// Slots 0/1 are cyan upper/lower; slots 2/3 are coral upper/lower.
paddle_position :: proc(g: ^Game_State, slot: int) -> ^f32 {
    switch slot {
    case 0: return &g.p1_y
    case 1: return &g.p3_y
    case 3: return &g.p4_y
    }
    return &g.p2_y
}

configure_doubles :: proc(g: ^Game_State, enabled: bool) {
    g.doubles = enabled
    if enabled {
        g.p1_y = (FIELD_H / 2 - PADDLE_H) / 2
        g.p2_y = g.p1_y
        g.p3_y = g.p1_y + FIELD_H / 2
        g.p4_y = g.p3_y
    }
}

move_player_paddle :: proc(g: ^Game_State, slot: int, direction, speed, dt: f32) {
    y := paddle_position(g, slot)
    move_paddle(y, direction, speed, dt)
    if g.doubles {
        low: f32 = 0
        if slot % 2 == 1 { low = FIELD_H / 2 }
        y^ = math.clamp(y^, low, low + FIELD_H / 2 - PADDLE_H)
    }
}
