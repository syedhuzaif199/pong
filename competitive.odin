package main

import "core:fmt"
import rl "vendor:raylib"

// v1.6 competitive match rules. `best_of` is always normalized to one of
// 1, 3, 5, or 7 games. The host owns these rules for online matches.
normalize_best_of :: proc(value: int) -> int {
    if value <= 1 { return 1 }
    if value <= 3 { return 3 }
    if value <= 5 { return 5 }
    return 7
}

best_of_previous :: proc(value: int) -> int {
    switch normalize_best_of(value) {
    case 1: return 7
    case 3: return 1
    case 5: return 3
    case 7: return 5
    }
    return 3
}

best_of_next :: proc(value: int) -> int {
    switch normalize_best_of(value) {
    case 1: return 3
    case 3: return 5
    case 5: return 7
    case 7: return 1
    }
    return 3
}

games_needed_to_win :: proc(best_of: int) -> int {
    normalized := normalize_best_of(best_of)
    return normalized / 2 + 1
}

competitive_format_name :: proc(best_of: int) -> string {
    switch normalize_best_of(best_of) {
    case 1: return "BO1"
    case 3: return "BO3"
    case 5: return "BO5"
    case 7: return "BO7"
    }
    return "BO3"
}

on_off :: proc(value: bool) -> string {
    if value { return "ON" }
    return "OFF"
}

// Compact competitive controls used by local, LAN-host, and room-code host
// screens. It intentionally stays visually consistent with the clean v1.5 UI.
draw_competitive_rules_controls :: proc(rules: ^Game_Rules, y: f32, enabled := true) {
    draw_text("Format", 92, int(y) + 9, 16, MUTED)
    if button("<", rl.Rectangle{150, y, 34, 36}, enabled) {
        rules.best_of = best_of_previous(rules.best_of)
    }
    draw_text_centered_in(competitive_format_name(rules.best_of), rl.Rectangle{188, y, 58, 36}, 15, ACCENT)
    if button(">", rl.Rectangle{250, y, 34, 36}, enabled) {
        rules.best_of = best_of_next(rules.best_of)
    }

    draw_text("Win by 2", 318, int(y) + 9, 16, MUTED)
    if button(on_off(rules.win_by_two), rl.Rectangle{392, y, 72, 36}, enabled) {
        rules.win_by_two = !rules.win_by_two
    }

    draw_text("Spin", 498, int(y) + 9, 16, MUTED)
    if button(on_off(rules.paddle_spin), rl.Rectangle{540, y, 72, 36}, enabled) {
        rules.paddle_spin = !rules.paddle_spin
    }

    draw_text("Accel", 646, int(y) + 9, 16, MUTED)
    if button(on_off(rules.ball_acceleration), rl.Rectangle{696, y, 72, 36}, enabled) {
        rules.ball_acceleration = !rules.ball_acceleration
    }
}

competitive_rules_summary :: proc(rules: Game_Rules, buf: []u8) -> string {
    return fmt.bprintf(
        buf,
        "%s   |   Win by 2 %s   |   Spin %s   |   Accel %s",
        competitive_format_name(rules.best_of),
        on_off(rules.win_by_two),
        on_off(rules.paddle_spin),
        on_off(rules.ball_acceleration),
    )
}

format_match_time :: proc(seconds: f32, buf: []u8) -> string {
    total := int(seconds)
    if total < 0 { total = 0 }
    minutes := total / 60
    secs := total % 60
    return fmt.bprintf(buf, "%02d:%02d", minutes, secs)
}

reset_match_rtt_stats :: proc(app: ^App) {
    app.match_rtt_sum_ms = 0
    app.match_rtt_samples = 0
    app.match_rtt_sample_timer = 0
    for i in 0..<len(app.game_history1) {
        app.game_history1[i] = 0
        app.game_history2[i] = 0
    }
    app.game_history_count = 0
}

update_match_rtt_stats :: proc(app: ^App, dt: f32) {
    if app.match_mode != .Online || !app.net.rtt_valid || app.render_game.game_over { return }
    app.match_rtt_sample_timer -= dt
    if app.match_rtt_sample_timer > 0 { return }
    app.match_rtt_sample_timer = 0.5
    app.match_rtt_sum_ms += f64(app.net.rtt_smoothed_ms)
    app.match_rtt_samples += 1
}

average_match_rtt_ms :: proc(app: ^App) -> f32 {
    if app.match_rtt_samples <= 0 { return 0 }
    return f32(app.match_rtt_sum_ms / f64(app.match_rtt_samples))
}

record_completed_game :: proc(app: ^App, before, after: Game_State) {
    before_games := before.games1 + before.games2
    after_games := after.games1 + after.games2
    if after_games <= before_games { return }
    if app.game_history_count >= len(app.game_history1) { return }

    index := app.game_history_count
    app.game_history1[index] = after.score1
    app.game_history2[index] = after.score2
    app.game_history_count += 1
}

game_history_text :: proc(app: ^App, buf: []u8) -> string {
    if app.game_history_count <= 0 { return "" }
    used := 0
    for i in 0..<app.game_history_count {
        part_buf: [32]u8
        part := fmt.bprintf(part_buf[:], "%d-%d", app.game_history1[i], app.game_history2[i])
        if i > 0 {
            if used + 2 >= len(buf) { break }
            buf[used] = ' '
            buf[used + 1] = ' '
            used += 2
        }
        available := len(buf) - used
        n := min(len(part), available)
        if n <= 0 { break }
        copy(buf[used:used+n], transmute([]u8)part[:n])
        used += n
    }
    return string(buf[:used])
}

draw_match_progress :: proc(g: ^Game_State, rules: Game_Rules, y: int) {
    game_number := g.games1 + g.games2 + 1
    if g.game_over { game_number = g.games1 + g.games2 }
    if game_number < 1 { game_number = 1 }
    buf: [128]u8
    text := fmt.bprintf(
        buf[:],
        "GAMES %d - %d   |   GAME %d / %s",
        g.games1,
        g.games2,
        game_number,
        competitive_format_name(rules.best_of),
    )
    draw_text_centered(text, y, 14, MUTED)
}

draw_between_game_overlay :: proc(g: ^Game_State, player1_name, player2_name: string) {
    if g.between_games_timer <= 0 || g.game_over { return }

    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{7, 8, 12, 150})
    surface({180, 142, 600, 230}, PANEL)
    winner_name := player1_name
    if g.last_game_winner == 2 { winner_name = player2_name }

    game_number := g.games1 + g.games2
    heading_buf: [128]u8
    heading := fmt.bprintf(heading_buf[:], "GAME %d WON", game_number)
    draw_text_centered(heading, 174, 26, MUTED)

    winner_buf: [160]u8
    winner := fmt.bprintf(winner_buf[:], "%s", winner_name)
    draw_text_centered(winner, 214, 40, FG)

    games_buf: [96]u8
    games := fmt.bprintf(games_buf[:], "MATCH %d - %d", g.games1, g.games2)
    draw_text_centered(games, 276, 22, ACCENT)
    draw_text_centered("NEXT GAME...", 320, 16, MUTED)
}

draw_match_complete_overlay :: proc(app: ^App, g: ^Game_State, player1_name, player2_name: string) {
    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{7, 8, 12, 215})
    surface({140, 66, 680, 422}, PANEL)
    rl.DrawRectangleRounded({400, 66, 160, 3}, 0.8, 6, ACCENT)

    winner_name := player1_name
    if g.winner == 2 { winner_name = player2_name }

    draw_text_centered("MATCH COMPLETE", 92, 24, ACCENT)
    winner_buf: [160]u8
    winner_text := fmt.bprintf(winner_buf[:], "%s WINS", winner_name)
    draw_text_centered_in(winner_text, {160, 126, 640, 52}, 40, FG)

    result_buf: [160]u8
    result := fmt.bprintf(
        result_buf[:],
        "Games %d - %d   |   Points %d - %d",
        g.games1,
        g.games2,
        g.total_points1,
        g.total_points2,
    )
    draw_text_centered(result, 190, 19, FG)

    history_buf: [192]u8
    history := game_history_text(app, history_buf[:])
    if len(history) > 0 {
        history_line_buf: [224]u8
        history_line := fmt.bprintf(history_line_buf[:], "Games: %s", history)
        draw_text_centered(history_line, 218, 15, MUTED)
    }

    time_buf: [32]u8
    time_text := format_match_time(g.match_elapsed, time_buf[:])
    stats_buf: [192]u8
    stats := fmt.bprintf(
        stats_buf[:],
        "Longest rally %d   |   Fastest ball %.0f px/s   |   Time %s",
        g.longest_rally,
        g.fastest_ball,
        time_text,
    )
    draw_text_centered(stats, 246, 16, MUTED)

    rules_buf: [192]u8
    rules := fmt.bprintf(
        rules_buf[:],
        "%s   |   Game to %d   |   Win by 2 %s   |   Spin %s   |   Accel %s",
        competitive_format_name(app.network_rules.best_of),
        app.network_rules.winning_score,
        on_off(app.network_rules.win_by_two),
        on_off(app.network_rules.paddle_spin),
        on_off(app.network_rules.ball_acceleration),
    )
    draw_text_centered(rules, 272, 14, MUTED)

    if app.match_mode == .Online {
        if app.match_rtt_samples > 0 {
            rtt_buf: [96]u8
            rtt := fmt.bprintf(rtt_buf[:], "Average RTT %.0f ms", average_match_rtt_ms(app))
            draw_text_centered(rtt, 296, 14, MUTED)
        }

        local_status := "YOU: NOT READY"
        opponent_status := "OPPONENT: NOT READY"
        if app.net.local_rematch { local_status = "YOU: REMATCH READY" }
        if app.net.remote_rematch { opponent_status = "OPPONENT: REMATCH READY" }
        local_colour := MUTED
        opponent_colour := MUTED
        if app.net.local_rematch { local_colour = GOOD }
        if app.net.remote_rematch { opponent_colour = GOOD }
        draw_text_centered(local_status, 320, 16, local_colour)
        draw_text_centered(opponent_status, 342, 16, opponent_colour)

        rematch_label := "REMATCH"
        rematch_enabled := !app.net.local_rematch && !app.paused
        if app.net.local_rematch { rematch_label = "WAITING..." }
        if button(rematch_label, rl.Rectangle{330, 372, 300, 48}, rematch_enabled) {
            net_request_rematch(&app.net)
        }
        when !PONG_ANDROID {
            draw_text_centered("ENTER / controller A also requests a rematch", 432, 14, MUTED)
        }
        draw_text_centered("The next match starts when both players accept.", 454, 14, MUTED)
    } else {
        mode_text := "LOCAL 2P"
        if app.match_mode == .Vs_CPU { mode_text = "VS CPU" }
        draw_text_centered(mode_text, 304, 15, ACCENT)
        if button("REMATCH", rl.Rectangle{330, 346, 300, 50}, !app.paused) {
            start_local_rematch(app)
        }
        when !PONG_ANDROID {
            draw_text_centered("ENTER / controller A also starts a rematch", 410, 14, MUTED)
        }
        draw_text_centered("Pause menu lets you leave or change local settings.", 438, 14, MUTED)
    }
}
