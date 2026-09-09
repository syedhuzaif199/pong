package main

import rl "vendor:raylib"

// Build with -define:PONG_VISUAL_REVIEW=true for deterministic, offline screenshots.
// This path does not initialize networking/audio or read/write user preferences.
run_visual_review :: proc() {
    rl.SetConfigFlags({.WINDOW_HIDDEN})
    rl.InitWindow(WINDOW_W, WINDOW_H, "Pong visual review")
    defer rl.CloseWindow()
    app := App{}
    app.preferences = default_app_settings()
    app.last_game_rules = default_game_rules()
    app.network_rules = app.last_game_rules
    app.match_mode = .Vs_CPU
    app.selected_local_mode = .Vs_CPU
    app.cpu_difficulty = .Normal
    reset_match(&app.render_game)
    app.render_game.countdown_timer = 0
    app.render_game.serve_timer = 0
    app.render_game.ball_x = 610
    app.render_game.ball_y = 330
    app.render_game.ball_vx = 560
    app.render_game.ball_vy = 130
    app.render_game.score1 = 4
    app.render_game.score2 = 2
    app.render_game.p1_y = 230
    app.render_game.p2_y = 294
    canvas := rl.LoadRenderTexture(WINDOW_W, WINDOW_H)
    defer rl.UnloadRenderTexture(canvas)
    screens := [?]Screen{.Main_Menu, .Local_Play, .Online, .Local_Setup, .Settings, .Game, .Game, .Game, .Game}
    paths := [?]cstring{"review-home.png", "review-local.png", "review-online.png", "review-setup.png", "review-settings.png", "review-arena.png", "review-pause.png", "review-results.png", "review-countdown.png"}
    for screen, i in screens {
        app.screen = screen
        app.paused = i == 6
        app.render_game.game_over = i == 7
        app.render_game.winner = 1
        if i == 8 { app.render_game.countdown_timer = 2.6 }
        rl.BeginTextureMode(canvas)
        rl.ClearBackground(BG)
        draw_app(&app)
        rl.EndTextureMode()
        snapshot := rl.LoadImageFromTexture(canvas.texture)
        rl.ImageFlipVertical(&snapshot)
        _ = rl.ExportImage(snapshot, paths[i])
        rl.UnloadImage(snapshot)
    }
}
