package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import rl "vendor:raylib"

APP_VERSION :: "v1.1.0"
PRE_COUNTDOWN_FADE_TIME :: f32(0.40)
LAN_IPV4_FALLBACK_DELAY :: f64(0.75)

Screen :: enum {
    Main_Menu,
    Online,
    Host_Setup,
    Join_Setup,
    Lobby,
    Settings,
    Game,
}

Online_Status :: enum {
    Idle,
    Hosting,
    Joining,
    Error,
}

App :: struct {
    screen: Screen,
    running: bool,

    preferences: App_Settings,
    last_game_rules: Game_Rules,
    network_rules: Game_Rules,

    address: Text_Field,
    port: Text_Field,

    lan_fallback_ipv4: [32]u8,
    lan_fallback_ipv4_length: int,
    lan_fallback_pending: bool,
    lan_fallback_used: bool,
    online_status: Online_Status,
    status_message: string,

    net: Net_State,
    discovery_host: Discovery_Host,
    discovery_client: Discovery_Client,
    game: Game_State,
    render_game: Game_State,
    target_game: Game_State,

    music: Music_System,
    audio: Audio_System,
    fx: Visual_FX,

    paused: bool,
    pause_settings: bool,
    countdown_sound_stage: int,
    transition_alpha: f32,

    match_start_pending: bool,
    match_start_timer: f32,

    display_change_pending: bool,
}

prepare_runtime_directory :: proc() {
    original_dir, original_err := os.get_working_directory(context.temp_allocator)
    executable_dir, executable_err := os.get_executable_directory(context.temp_allocator)
    if executable_err != nil {
        return
    }

    if os.set_working_directory(executable_dir) != nil {
        return
    }

    // `odin run .` may place its temporary executable somewhere that does not
    // contain the project's assets. Release builds keep assets beside the
    // executable, but development runs should gracefully fall back to the
    // directory from which Odin was invoked.
    _, assets_err := os.read_entire_file_from_path("assets/README.txt", context.temp_allocator)
    if assets_err != nil && original_err == nil {
        _ = os.set_working_directory(original_dir)
    }
}

main :: proc() {
    prepare_runtime_directory()

    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
    rl.InitWindow(WINDOW_W, WINDOW_H, "UDP Pong")
    defer rl.CloseWindow()
    rl.SetWindowMinSize(640, 360)
    rl.SetTargetFPS(120)
    // Keep Escape available to our menus instead of letting raylib close the window.
    rl.SetExitKey(.KEY_NULL)

    app := App{}
    app.running = true
    app.screen = .Main_Menu
    app.preferences = default_app_settings()
    app.last_game_rules = default_game_rules()
    load_config(&app.preferences, &app.last_game_rules)
    app.network_rules = app.last_game_rules

    app.address = app.preferences.last_join_address
    port_buf: [32]u8
    port_text := fmt.bprintf(port_buf[:], "%d", app.preferences.last_join_port)
    text_field_set(&app.port, port_text)
    reset_match(&app.game)
    app.render_game = app.game
    app.target_game = app.game

    if app.preferences.fullscreen != rl.IsWindowFullscreen() {
        rl.ToggleFullscreen()
    }

    rl.InitAudioDevice()
    audio_ready := rl.IsAudioDeviceReady()
    if audio_ready {
        audio_load_sfx(&app.audio)
        music_load(&app.music)
    }

    canvas := rl.LoadRenderTexture(WINDOW_W, WINDOW_H)

    for app.running && !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        if dt > 0.05 { dt = 0.05 }

        frame_screen := app.screen
        update_app(&app, dt)
        if app.screen != frame_screen { app.transition_alpha = 1 }

        if audio_ready {
            update_music_mode(&app)
            music_update(&app.music, app.preferences, dt)
        }

        rl.BeginTextureMode(canvas)
        rl.ClearBackground(BG)
        draw_app(&app)
        if app.screen != frame_screen { app.transition_alpha = 1 }
        if take_ui_click_request() {
            play_menu_click_sfx(&app.audio, app.preferences)
        }
        draw_transition_overlay(&app)
        rl.EndTextureMode()

        rl.BeginDrawing()
        rl.ClearBackground(rl.Color{5, 6, 9, 255})
        present_logical_canvas(canvas)
        rl.EndDrawing()
    }

    save_config(app.preferences, app.last_game_rules)
    discovery_host_shutdown(&app.discovery_host)
    discovery_client_shutdown(&app.discovery_client)
    net_shutdown(&app.net)
    rl.UnloadRenderTexture(canvas)

    if audio_ready {
        music_unload(&app.music)
        audio_unload_sfx(&app.audio)
        rl.CloseAudioDevice()
    }
}


begin_match_start_fade :: proc(app: ^App) {
    if app.match_start_pending { return }
    app.match_start_pending = true
    app.match_start_timer = PRE_COUNTDOWN_FADE_TIME
}

cancel_match_start_fade :: proc(app: ^App) {
    app.match_start_pending = false
    app.match_start_timer = 0
}

update_music_mode :: proc(app: ^App) {
    mode: Music_Mode = .Menu

    if app.match_start_pending &&
       (app.screen == .Lobby || (app.screen == .Game && app.render_game.game_over)) {
        mode = .Silent
    } else if app.screen == .Game {
        if app.render_game.countdown_timer > 0 {
            mode = .Silent
        } else if app.render_game.game_over {
            mode = .Menu
        } else {
            mode = .Gameplay
        }
    }

    music_set_mode(&app.music, mode)
}

update_app :: proc(app: ^App, dt: f32) {
    app.transition_alpha = max(f32(0), app.transition_alpha - dt * 4.5)
    update_visual_fx(&app.fx, dt)

    alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
    if alt_down && rl.IsKeyPressed(.ENTER) {
        app.preferences.fullscreen = !app.preferences.fullscreen
        app.display_change_pending = true
        save_config(app.preferences, app.last_game_rules)
    }

    if app.display_change_pending {
        if app.preferences.fullscreen != rl.IsWindowFullscreen() {
            rl.ToggleFullscreen()
        }
        app.display_change_pending = false
    }

    switch app.screen {
    case .Main_Menu:
        // Buttons perform transitions in draw_main_menu.

    case .Online:
        if rl.IsKeyPressed(.ESCAPE) {
            app.screen = .Main_Menu
        }

    case .Host_Setup:
        update_host_setup(app)

    case .Join_Setup:
        update_join_setup(app)

    case .Lobby:
        update_lobby(app, dt)

    case .Settings:
        text_field_update(&app.preferences.player_name, allow_player_name_char)
        if app.preferences.player_name.length > MAX_PLAYER_NAME {
            app.preferences.player_name.length = MAX_PLAYER_NAME
        }
        if rl.IsKeyPressed(.ESCAPE) {
            sanitize_player_name(&app.preferences.player_name)
            save_config(app.preferences, app.last_game_rules)
            app.screen = .Main_Menu
        }

    case .Game:
        update_game(app, dt)
    }
}

update_host_setup :: proc(app: ^App) {
    controls_disabled := app.online_status == .Hosting
    if !controls_disabled {
        text_field_update(&app.port, allow_port_char)
    }

    if rl.IsKeyPressed(.ESCAPE) {
        if controls_disabled {
            discovery_host_shutdown(&app.discovery_host)
            net_shutdown(&app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            app.screen = .Online
        }
        return
    }

    #partial switch app.online_status {
    case .Hosting:
        discovery_host_update(&app.discovery_host)
        connected, _ := net_receive_host(&app.net, app.network_rules, &app.game)
        if connected {
            discovery_host_shutdown(&app.discovery_host)
            app.render_game = app.game
            app.target_game = app.game
            app.screen = .Lobby
        }
    case:
    }
}

update_join_setup :: proc(app: ^App) {
    controls_disabled := app.online_status == .Joining
    if !controls_disabled {
        if !app.discovery_client.attempted_start {
            _ = discovery_client_start(&app.discovery_client)
        }
        discovery_client_update(&app.discovery_client)
        text_field_update(&app.address, allow_ip_address_char)
        text_field_update(&app.port, allow_port_char)
    }

    if rl.IsKeyPressed(.ESCAPE) {
        if controls_disabled {
            clear_lan_fallback(app)
            net_shutdown(&app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            discovery_client_shutdown(&app.discovery_client)
            app.screen = .Online
        }
        return
    }

    #partial switch app.online_status {
    case .Joining:
        client_send_handshake_if_due(&app.net)
        _, got_lobby, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
        if app.net.protocol_mismatch {
            app.status_message = "Protocol mismatch. Host is running a different Pong version."
            net_shutdown(&app.net, false)
            app.online_status = .Error
            return
        }
        if got_state {
            clear_lan_fallback(app)
            discovery_client_shutdown(&app.discovery_client)
            app.render_game = app.target_game
            app.paused = false
            app.pause_settings = false
            app.countdown_sound_stage = 0
            app.screen = .Game
            return
        }
        if got_lobby {
            clear_lan_fallback(app)
            discovery_client_shutdown(&app.discovery_client)
            app.screen = .Lobby
            return
        }

        if app.lan_fallback_pending && !app.net.welcomed &&
           rl.GetTime() - app.net.join_started_time >= LAN_IPV4_FALLBACK_DELAY {
            fallback := lan_fallback_address(app)
            app.lan_fallback_pending = false
            if len(fallback) > 0 {
                port, port_ok := parse_port_field(app)
                if port_ok && start_joining_address(app, fallback, port, false) {
                    app.lan_fallback_used = true
                    text_field_set(&app.address, fallback)
                    app.status_message = "IPv6 did not answer; trying IPv4 fallback..."
                    return
                }
            }
        }

        if join_timed_out(&app.net) {
            if app.net.send_errors > 0 {
                app.status_message = "UDP send failed. Check your network configuration and firewall."
            } else if app.net.welcomed {
                app.status_message = "Host replied, but game synchronization timed out."
            } else {
                app.status_message = "No reply from host. Check the IP address, port, and firewall."
            }
            net_shutdown(&app.net, false)
            app.online_status = .Error
        }
    case:
    }
}

update_lobby :: proc(app: ^App, dt: f32) {
    if rl.IsKeyPressed(.ESCAPE) {
        cancel_match_start_fade(app)
        net_shutdown(&app.net)
        app.online_status = .Idle
        app.status_message = ""
        app.screen = .Online
        return
    }

    #partial switch app.net.role {
    case .Host:
        _, _ = net_receive_host(&app.net, app.network_rules, &app.game)
        if app.net.peer_left {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Player left the lobby."
            app.screen = .Host_Setup
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Player timed out in the lobby."
            app.screen = .Host_Setup
            return
        }

        net_send_ping_if_due(&app.net)
        net_send_lobby_if_due(&app.net)

        if both_players_ready(&app.net) {
            if !app.match_start_pending {
                // Send one explicit both-ready state so the client begins fading too.
                send_lobby_state(&app.net)
                begin_match_start_fade(app)
            }

            app.match_start_timer -= dt
            if app.match_start_timer <= 0 {
                cancel_match_start_fade(app)
                clear_ready_state(&app.net)
                clear_rematch_state(&app.net)
                begin_match_countdown(&app.game)
                app.render_game = app.game
                app.target_game = app.game
                send_state(&app.net, app.game)
                app.paused = false
                app.pause_settings = false
                app.countdown_sound_stage = 0
                app.screen = .Game
            }
        } else {
            cancel_match_start_fade(app)
        }

    case .Client:
        _, _, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
        if got_state {
            cancel_match_start_fade(app)
            clear_ready_state(&app.net)
            app.render_game = app.target_game
            app.paused = false
            app.pause_settings = false
            app.countdown_sound_stage = 0
            app.screen = .Game
            return
        }
        if app.net.peer_left {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Host closed the lobby."
            app.screen = .Join_Setup
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Connection to host timed out in the lobby."
            app.screen = .Join_Setup
            return
        }

        net_send_ping_if_due(&app.net)
        net_send_lobby_if_due(&app.net)

        if both_players_ready(&app.net) {
            begin_match_start_fade(app)
        } else {
            cancel_match_start_fade(app)
        }
    case:
    }
}

update_game :: proc(app: ^App, dt: f32) {
    if rl.IsKeyPressed(.ESCAPE) {
        if app.pause_settings {
            app.pause_settings = false
            save_config(app.preferences, app.last_game_rules)
        } else {
            app.paused = !app.paused
        }
    }

    direction: f32 = 0
    if !app.paused {
        direction = local_input_direction()
    }

    #partial switch app.net.role {
    case .Host:
        before := app.game
        _, _ = net_receive_host(&app.net, app.network_rules, &app.game)
        if app.net.peer_left {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Opponent left the game."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = .Host_Setup
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Opponent timed out."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = .Host_Setup
            return
        }

        net_send_ping_if_due(&app.net)
        if app.game.game_over {
            host_send_state_if_due(&app.net, app.game)
            net_send_rematch_if_due(&app.net)
            alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
            if !app.paused && rl.IsKeyPressed(.ENTER) && !alt_down { net_request_rematch(&app.net) }

            if both_players_want_rematch(&app.net) {
                if !app.match_start_pending {
                    // Keep the game-over/menu track audible until both players agree,
                    // then fade it before the next countdown begins.
                    send_rematch_state(&app.net)
                    begin_match_start_fade(app)
                }

                app.match_start_timer -= dt
                if app.match_start_timer <= 0 {
                    cancel_match_start_fade(app)
                    clear_rematch_state(&app.net)
                    send_rematch_state(&app.net)
                    begin_match_countdown(&app.game)
                    app.render_game = app.game
                    app.paused = false
                    app.pause_settings = false
                    app.countdown_sound_stage = 0
                    send_state(&app.net, app.game)
                }
            } else {
                cancel_match_start_fade(app)
            }
        } else {
            cancel_match_start_fade(app)
            step_host_game(&app.game, app.network_rules, direction, app.net.remote_input, dt)
            host_send_state_if_due(&app.net, app.game)
        }
        process_game_events(app, before, app.game)
        app.render_game = app.game

    case .Client:
        if !app.render_game.game_over {
            client_send_input_if_due(&app.net, direction)
        }
        before := app.target_game
        _, _, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
        if got_state {
            process_game_events(app, before, app.target_game)
            if before.game_over && !app.target_game.game_over && app.target_game.countdown_timer > 0 {
                cancel_match_start_fade(app)
                app.paused = false
                app.pause_settings = false
                app.countdown_sound_stage = 0
            }
        }

        if app.net.peer_left {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Opponent left the game."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = .Join_Setup
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Host timed out."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = .Join_Setup
            return
        }

        net_send_ping_if_due(&app.net)
        interpolate_render_state(&app.render_game, app.target_game, dt)

        if !app.paused && app.render_game.countdown_timer <= 0 && !app.render_game.game_over {
            move_paddle(&app.render_game.p2_y, direction, app.network_rules.paddle_speed, dt)
        }

        if app.render_game.game_over {
            net_send_rematch_if_due(&app.net)
            alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
            if !app.paused && rl.IsKeyPressed(.ENTER) && !alt_down { net_request_rematch(&app.net) }

            if both_players_want_rematch(&app.net) {
                begin_match_start_fade(app)
            } else {
                cancel_match_start_fade(app)
            }
        } else {
            cancel_match_start_fade(app)
        }
    case:
    }

    update_countdown_sfx(app, &app.render_game)
}

draw_app :: proc(app: ^App) {
    switch app.screen {
    case .Main_Menu:
        draw_main_menu(app)
    case .Online:
        draw_online(app)
    case .Host_Setup:
        draw_host_setup(app)
    case .Join_Setup:
        draw_join_setup(app)
    case .Lobby:
        draw_lobby(app)
    case .Settings:
        draw_settings(app)
    case .Game:
        draw_game_screen(app)
    }
}

draw_main_menu :: proc(app: ^App) {
    draw_text_centered("PONG", 95, 72, FG)
    draw_text_centered("IPv4 + IPv6 / UDP", 174, 22, ACCENT)

    if button("PLAY ONLINE", rl.Rectangle{330, 245, 300, 58}) {
        app.screen = .Online
        app.online_status = .Idle
        app.status_message = ""
        return
    }
    if button("SETTINGS", rl.Rectangle{330, 317, 300, 58}) {
        app.screen = .Settings
        return
    }
    if button("QUIT", rl.Rectangle{330, 389, 300, 58}) {
        app.running = false
    }

    draw_text_centered("W/S or arrows to move during a match", 492, 17, MUTED)
    version_buf: [128]u8
    version_text := fmt.bprintf(version_buf[:], "%s  |  protocol 4  |  discovery 1", APP_VERSION)
    draw_text(version_text, 18, WINDOW_H - 24, 13, MUTED)
}

draw_online :: proc(app: ^App) {
    draw_text_centered("PLAY ONLINE", 72, 50, FG)
    draw_text_centered("Choose how you want to connect.", 138, 18, MUTED)

    if button("HOST GAME", rl.Rectangle{330, 215, 300, 62}) {
        app.online_status = .Idle
        app.status_message = ""
        app.screen = .Host_Setup
        return
    }
    if button("JOIN GAME", rl.Rectangle{330, 297, 300, 62}) {
        app.online_status = .Idle
        app.status_message = ""
        discovery_client_shutdown(&app.discovery_client)
        _ = discovery_client_start(&app.discovery_client)
        app.screen = .Join_Setup
        return
    }
    if button("BACK", rl.Rectangle{330, 405, 300, 52}) {
        app.screen = .Main_Menu
    }
}

draw_settings :: proc(app: ^App) {
    draw_text_centered("SETTINGS", 16, 38, FG)
    draw_text_centered("Local preferences only; these do not change match rules.", 58, 15, MUTED)

    text_field("Player name", &app.preferences.player_name, rl.Rectangle{500, 88, 268, 40})
    draw_text("Shown to the other player", 500, 132, 13, MUTED)

    _ = setting_row_int("Music volume", &app.preferences.music_volume, 166, 0, 100, 5)

    draw_text("Mute music", 285, 230, 21, FG)
    music_mute_label := "OFF"
    if app.preferences.music_muted { music_mute_label = "ON" }
    if button(music_mute_label, rl.Rectangle{618, 217, 150, 42}) {
        app.preferences.music_muted = !app.preferences.music_muted
    }

    _ = setting_row_int("SFX volume", &app.preferences.sfx_volume, 270, 0, 100, 5)

    draw_text("Mute SFX", 285, 334, 21, FG)
    sfx_mute_label := "OFF"
    if app.preferences.sfx_muted { sfx_mute_label = "ON" }
    if button(sfx_mute_label, rl.Rectangle{618, 321, 150, 42}) {
        app.preferences.sfx_muted = !app.preferences.sfx_muted
    }

    draw_text("Display mode", 285, 386, 21, FG)
    display_label := "WINDOWED"
    if app.preferences.fullscreen { display_label = "FULLSCREEN" }
    if button(display_label, rl.Rectangle{560, 373, 208, 42}) {
        app.preferences.fullscreen = !app.preferences.fullscreen
        app.display_change_pending = true
    }

    draw_text("Show net stats", 285, 438, 21, FG)
    stats_label := "OFF"
    if app.preferences.show_net_stats { stats_label = "ON" }
    if button(stats_label, rl.Rectangle{618, 425, 150, 42}) {
        app.preferences.show_net_stats = !app.preferences.show_net_stats
    }

    draw_text("Alt+Enter toggles fullscreen anywhere", 42, 508, 14, MUTED)
    if button("BACK", rl.Rectangle{360, 482, 240, 42}) {
        sanitize_player_name(&app.preferences.player_name)
        save_config(app.preferences, app.last_game_rules)
        app.screen = .Main_Menu
    }
}

draw_host_setup :: proc(app: ^App) {
    controls_disabled := app.online_status == .Hosting

    draw_text_centered("HOST GAME", 28, 42, FG)
    draw_text_centered("Choose this match's rules. They are remembered for your next hosted game.", 76, 16, MUTED)

    text_field("Port", &app.port, rl.Rectangle{370, 112, 220, 48}, !controls_disabled)

    _ = setting_row_int("Winning score", &app.last_game_rules.winning_score, 178, 1, 21, 1, !controls_disabled)
    _ = setting_row_f32("Ball speed", &app.last_game_rules.ball_speed, 236, 250, 900, 25, !controls_disabled)
    _ = setting_row_f32("Paddle speed", &app.last_game_rules.paddle_speed, 294, 250, 900, 25, !controls_disabled)

    if button("START HOSTING", rl.Rectangle{215, 366, 300, 50}, !controls_disabled) {
        start_hosting(app)
    }

    copy_enabled := controls_disabled && (app.discovery_host.ipv6_length > 0 || app.discovery_host.ipv4_length > 0)
    if button("COPY INVITE", rl.Rectangle{535, 366, 210, 50}, copy_enabled) {
        copy_host_invite(app)
    }

    #partial switch app.online_status {
    case .Hosting:
        draw_text_centered("Waiting for another player...", 430, 18, GOOD)
        if app.discovery_host.socket_open {
            lan_buf: [224]u8
            lan_text := "LAN discovery ON"
            if app.discovery_host.ipv6_length > 0 {
                ipv6 := discovery_host_ipv6(&app.discovery_host)
                lan_text = fmt.bprintf(lan_buf[:], "LAN discovery ON  |  [%s]:%d  |  IPv4 fallback", ipv6, app.discovery_host.game_port)
            } else if app.discovery_host.ipv4_length > 0 {
                ipv4 := discovery_host_ipv4(&app.discovery_host)
                lan_text = fmt.bprintf(lan_buf[:], "LAN discovery ON  |  %s:%d  |  IPv4", ipv4, app.discovery_host.game_port)
            }
            draw_text_centered(lan_text, 455, 14, MUTED)
        } else {
            draw_text_centered("LAN discovery unavailable; direct IP joining may still work.", 455, 14, MUTED)
        }
        if app.status_message != "" {
            draw_text_centered(app.status_message, 477, 14, ACCENT)
        }
    case .Error:
        draw_text_centered(app.status_message, 438, 17, DANGER)
    case:
        draw_text_centered("Hosting accepts IPv4 + IPv6 when available; LAN discovery prefers IPv6 and falls back to IPv4.", 438, 14, MUTED)
    }

    back_label := "BACK"
    if controls_disabled { back_label = "CANCEL" }
    if button(back_label, rl.Rectangle{360, 496, 240, 34}) {
        if controls_disabled {
            discovery_host_shutdown(&app.discovery_host)
            net_shutdown(&app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            app.screen = .Online
        }
    }
}

draw_join_setup :: proc(app: ^App) {
    controls_disabled := app.online_status == .Joining

    draw_text_centered("JOIN GAME", 14, 38, FG)

    // LAN discovery list.
    games_buf: [64]u8
    games_title := fmt.bprintf(games_buf[:], "LAN GAMES (%d)", app.discovery_client.game_count)
    draw_text(games_title, 92, 66, 18, FG)
    if button("REFRESH", rl.Rectangle{735, 55, 130, 34}, !controls_disabled && app.discovery_client.socket_open) {
        discovery_client_refresh(&app.discovery_client)
    }

    rl.DrawRectangleRec(rl.Rectangle{90, 96, 780, 154}, PANEL)
    rl.DrawRectangleLinesEx(rl.Rectangle{90, 96, 780, 154}, 1, MUTED)

    visible := min(app.discovery_client.game_count, 3)
    if visible == 0 {
        message := "Searching your LAN..."
        if app.discovery_client.attempted_start && !app.discovery_client.socket_open {
            message = "LAN discovery unavailable; use direct IP connect below."
        }
        draw_text_centered_in(message, rl.Rectangle{90, 96, 780, 154}, 17, MUTED)
    } else {
        for i in 0..<visible {
            game := &app.discovery_client.games[i]
            y := f32(104 + i * 47)
            if i > 0 { rl.DrawLine(105, i32(y - 5), 855, i32(y - 5), rl.Color{54, 60, 74, 255}) }

            name := discovered_game_name(game)
            draw_text(name, 108, int(y) + 4, 19, FG)

            endpoint_buf: [160]u8
            endpoint_text := ""
            if game.ipv6_length > 0 {
                ipv6 := discovered_game_ipv6(game)
                endpoint_text = fmt.bprintf(endpoint_buf[:], "[%s]:%d", ipv6, game.game_port)
            } else {
                ipv4 := discovered_game_ipv4(game)
                endpoint_text = fmt.bprintf(endpoint_buf[:], "%s:%d", ipv4, game.game_port)
            }
            draw_text(endpoint_text, 292, int(y) + 7, 13, MUTED)

            ping_buf: [64]u8
            ping_text := fmt.bprintf(ping_buf[:], "%.0f ms", game.ping_ms)
            draw_text(ping_text, 655, int(y) + 6, 14, MUTED)

            compatible := game.game_protocol == PROTOCOL_VERSION
            join_label := "JOIN"
            if !compatible { join_label = "OLD/NEW" }
            if button(join_label, rl.Rectangle{750, y, 100, 34}, compatible && !controls_disabled) {
                join_discovered_game(app, game)
            }
        }
    }

    if app.discovery_client.local_ipv4_length > 0 {
        local_ip4 := string(app.discovery_client.local_ipv4[:app.discovery_client.local_ipv4_length])
        route_buf: [96]u8
        route_text := fmt.bprintf(route_buf[:], "LAN search via %s", local_ip4)
        draw_text(route_text, 92, 257, 12, MUTED)
    }

    draw_text("DIRECT CONNECT", 92, 278, 18, FG)
    draw_text_centered("Use IPv4 or IPv6 for Internet play or when LAN discovery is unavailable.", 302, 14, MUTED)

    text_field("IP address", &app.address, rl.Rectangle{120, 344, 510, 46}, !controls_disabled)
    text_field("Port", &app.port, rl.Rectangle{650, 344, 120, 46}, !controls_disabled)
    if button("PASTE INVITE", rl.Rectangle{780, 344, 130, 46}, !controls_disabled) {
        if paste_invite_from_clipboard(app) {
            app.status_message = "Invite pasted."
        } else {
            app.status_message = "Clipboard does not contain a valid IPv4/IPv6 invite."
        }
    }

    if button("CONNECT", rl.Rectangle{330, 411, 300, 48}, !controls_disabled) {
        start_joining(app)
    }

    #partial switch app.online_status {
    case .Joining:
        elapsed := rl.GetTime() - app.net.join_started_time
        status_buf: [192]u8
        transport := net_transport_name(&app.net)
        if app.net.welcomed {
            status := fmt.bprintf(status_buf[:], "Host replied over %s; synchronizing... %.1f / %.0f s", transport, elapsed, JOIN_TIMEOUT)
            draw_text_centered(status, 470, 16, GOOD)
        } else if app.lan_fallback_used {
            status := fmt.bprintf(status_buf[:], "IPv6 did not answer; trying IPv4... %.1f / %.0f s", elapsed, JOIN_TIMEOUT)
            draw_text_centered(status, 470, 16, GOOD)
        } else {
            status := fmt.bprintf(status_buf[:], "Contacting host over %s... %.1f / %.0f s", transport, elapsed, JOIN_TIMEOUT)
            draw_text_centered(status, 470, 16, GOOD)
        }
    case .Error:
        draw_text_centered(app.status_message, 470, 15, DANGER)
    case:
        if app.status_message != "" {
            draw_text_centered(app.status_message, 470, 14, ACCENT)
        } else {
            draw_text_centered("LAN joins prefer IPv6 and automatically fall back to IPv4.", 470, 14, MUTED)
        }
    }

    back_label := "BACK"
    if controls_disabled { back_label = "CANCEL" }
    if button(back_label, rl.Rectangle{30, 496, 180, 34}) {
        if controls_disabled {
            clear_lan_fallback(app)
            net_shutdown(&app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            discovery_client_shutdown(&app.discovery_client)
            app.screen = .Online
        }
    }
}

clear_lan_fallback :: proc(app: ^App) {
    app.lan_fallback_ipv4_length = 0
    app.lan_fallback_pending = false
    app.lan_fallback_used = false
}

set_lan_fallback :: proc(app: ^App, ipv4: string) {
    clear_lan_fallback(app)
    n := min(len(ipv4), len(app.lan_fallback_ipv4))
    if n > 0 {
        copy(app.lan_fallback_ipv4[:n], transmute([]u8)ipv4[:n])
        app.lan_fallback_ipv4_length = n
        app.lan_fallback_pending = true
    }
}

lan_fallback_address :: proc(app: ^App) -> string {
    return string(app.lan_fallback_ipv4[:app.lan_fallback_ipv4_length])
}

start_joining_address :: proc(app: ^App, address_text: string, port: int, remember: bool) -> bool {
    if net.parse_address(address_text) == nil {
        app.online_status = .Error
        app.status_message = "That is not a valid IPv4 or IPv6 address."
        return false
    }

    if remember {
        text_field_set(&app.preferences.last_join_address, address_text)
        app.preferences.last_join_port = port
        save_config(app.preferences, app.last_game_rules)
    }

    sanitize_player_name(&app.preferences.player_name)
    if !net_join(&app.net, address_text, port, text_field_string(&app.preferences.player_name)) {
        app.online_status = .Error
        app.status_message = "Could not create the UDP client socket."
        return false
    }

    reset_match(&app.target_game)
    app.render_game = app.target_game
    app.network_rules = default_game_rules()
    app.online_status = .Joining
    app.status_message = ""
    return true
}

copy_host_invite :: proc(app: ^App) {
    buf: [160]u8
    invite := ""
    if app.discovery_host.ipv6_length > 0 {
        ipv6 := discovery_host_ipv6(&app.discovery_host)
        invite = fmt.bprintf(buf[:], "[%s]:%d", ipv6, app.discovery_host.game_port)
    } else if app.discovery_host.ipv4_length > 0 {
        ipv4 := discovery_host_ipv4(&app.discovery_host)
        invite = fmt.bprintf(buf[:], "%s:%d", ipv4, app.discovery_host.game_port)
    } else {
        return
    }
    clipboard_set_text(invite)
    app.status_message = "Invite copied to clipboard."
}

paste_invite_from_clipboard :: proc(app: ^App) -> bool {
    clipboard_c := rl.GetClipboardText()
    if clipboard_c == nil { return false }
    clipboard := string(clipboard_c)

    endpoint, ok := net.parse_endpoint(clipboard)
    if ok && endpoint.port >= 1 && endpoint.port <= 65535 {
        address_text := net.address_to_string(endpoint.address)
        text_field_set(&app.address, address_text)
        port_buf: [32]u8
        port_text := fmt.bprintf(port_buf[:], "%d", endpoint.port)
        text_field_set(&app.port, port_text)
        return true
    }

    if net.parse_address(clipboard) != nil {
        text_field_set(&app.address, clipboard)
        return true
    }
    return false
}

join_discovered_game :: proc(app: ^App, game: ^Discovered_Game) {
    clear_lan_fallback(app)

    ipv4 := discovered_game_ipv4(game)
    ipv6 := discovered_game_ipv6(game)
    use_ipv6 := false
    if len(ipv6) > 0 {
        _, _, local_has_ipv6 := find_advertisable_ipv6()
        use_ipv6 = local_has_ipv6
    }

    address := ipv4
    if use_ipv6 {
        address = ipv6
        if len(ipv4) > 0 { set_lan_fallback(app, ipv4) }
    }

    if len(address) == 0 {
        app.online_status = .Error
        app.status_message = "The discovered host did not provide a usable gameplay address."
        return
    }

    text_field_set(&app.address, address)
    port_buf: [32]u8
    port_text := fmt.bprintf(port_buf[:], "%d", game.game_port)
    text_field_set(&app.port, port_text)

    if !start_joining_address(app, address, game.game_port, true) {
        clear_lan_fallback(app)
    }
}

draw_lobby :: proc(app: ^App) {
    draw_text_centered("LOBBY", 32, 44, FG)

    host_name := remote_player_name(&app.net)
    client_name := local_player_name(&app.net)
    host_ready := app.net.remote_ready
    client_ready := app.net.local_ready
    if app.net.role == .Host {
        host_name = local_player_name(&app.net)
        client_name = remote_player_name(&app.net)
        host_ready = app.net.local_ready
        client_ready = app.net.remote_ready
    }

    draw_text_centered("Both players must be ready before the match starts.", 82, 16, MUTED)
    transport_buf: [96]u8
    transport_text := fmt.bprintf(transport_buf[:], "Connected over %s / UDP", net_transport_name(&app.net))
    draw_text_centered(transport_text, 104, 13, MUTED)

    rl.DrawRectangleRec(rl.Rectangle{105, 130, 340, 145}, PANEL)
    rl.DrawRectangleLinesEx(rl.Rectangle{105, 130, 340, 145}, 1, ACCENT)
    draw_text_centered_in("PLAYER 1 / HOST", rl.Rectangle{105, 142, 340, 28}, 16, MUTED)
    draw_text_centered_in(host_name, rl.Rectangle{105, 176, 340, 36}, 25, FG)
    host_status := "NOT READY"
    host_colour := MUTED
    if host_ready { host_status = "READY"; host_colour = GOOD }
    draw_text_centered_in(host_status, rl.Rectangle{105, 222, 340, 34}, 18, host_colour)

    rl.DrawRectangleRec(rl.Rectangle{515, 130, 340, 145}, PANEL)
    rl.DrawRectangleLinesEx(rl.Rectangle{515, 130, 340, 145}, 1, ACCENT)
    draw_text_centered_in("PLAYER 2", rl.Rectangle{515, 142, 340, 28}, 16, MUTED)
    draw_text_centered_in(client_name, rl.Rectangle{515, 176, 340, 36}, 25, FG)
    client_status := "NOT READY"
    client_colour := MUTED
    if client_ready { client_status = "READY"; client_colour = GOOD }
    draw_text_centered_in(client_status, rl.Rectangle{515, 222, 340, 34}, 18, client_colour)

    rules_buf: [192]u8
    rules_text := fmt.bprintf(
        rules_buf[:],
        "First to %d   |   Ball %.0f   |   Paddle %.0f",
        app.network_rules.winning_score,
        app.network_rules.ball_speed,
        app.network_rules.paddle_speed,
    )
    draw_text_centered(rules_text, 306, 17, MUTED)

    ready_label := "READY UP"
    if app.net.local_ready { ready_label = "UNREADY" }
    if button(ready_label, rl.Rectangle{330, 356, 300, 56}, !app.match_start_pending) {
        net_set_local_ready(&app.net, !app.net.local_ready)
    }

    if app.net.local_ready && !app.net.remote_ready {
        draw_text_centered("Waiting for opponent...", 426, 17, MUTED)
    } else if !app.net.local_ready && app.net.remote_ready {
        draw_text_centered("Opponent is ready.", 426, 17, GOOD)
    } else if app.net.local_ready && app.net.remote_ready {
        draw_text_centered("Starting match...", 426, 17, GOOD)
    }

    if button("LEAVE LOBBY", rl.Rectangle{360, 470, 240, 46}) {
        cancel_match_start_fade(app)
        net_shutdown(&app.net)
        app.online_status = .Idle
        app.status_message = ""
        app.screen = .Online
    }
}

parse_port_field :: proc(app: ^App) -> (int, bool) {
    value, ok := strconv.parse_int(text_field_string(&app.port))
    if !ok || value < 1 || value > 65535 {
        return 0, false
    }
    return value, true
}

start_hosting :: proc(app: ^App) {
    cancel_match_start_fade(app)
    port, ok := parse_port_field(app)
    if !ok {
        app.online_status = .Error
        app.status_message = "Port must be between 1 and 65535."
        return
    }

    app.network_rules = app.last_game_rules
    save_config(app.preferences, app.last_game_rules)

    sanitize_player_name(&app.preferences.player_name)
    if !net_host(&app.net, port, text_field_string(&app.preferences.player_name)) {
        app.online_status = .Error
        app.status_message = "Could not bind the UDP gameplay socket. Is the port already in use?"
        return
    }

    reset_match(&app.game)
    _ = discovery_host_start(&app.discovery_host, port, text_field_string(&app.preferences.player_name), app.net.accepts_ipv6)
    app.online_status = .Hosting
    app.status_message = ""
}

start_joining :: proc(app: ^App) {
    cancel_match_start_fade(app)
    clear_lan_fallback(app)
    port, ok := parse_port_field(app)
    if !ok {
        app.online_status = .Error
        app.status_message = "Port must be between 1 and 65535."
        return
    }

    address_text := text_field_string(&app.address)
    _ = start_joining_address(app, address_text, port, true)
}

draw_game_screen :: proc(app: ^App) {
    g := &app.render_game

    for y := 12; y < WINDOW_H; y += 30 {
        rl.DrawRectangle(WINDOW_W / 2 - 2, i32(y), 4, 16, rl.Color{56, 63, 78, 255})
    }

    draw_ball_trail(g)

    p1_colour := FG
    p2_colour := FG
    if app.fx.p1_flash > 0 { p1_colour = GOOD }
    if app.fx.p2_flash > 0 { p2_colour = GOOD }
    rl.DrawRectangleRec(rl.Rectangle{P1_X, g.p1_y, PADDLE_W, PADDLE_H}, p1_colour)
    rl.DrawRectangleRec(rl.Rectangle{P2_X, g.p2_y, PADDLE_W, PADDLE_H}, p2_colour)
    rl.DrawCircleV([2]f32{g.ball_x, g.ball_y}, BALL_RADIUS, ACCENT)
    draw_visual_fx(&app.fx)

    score_buf: [128]u8
    score_text := fmt.bprintf(score_buf[:], "%d     %d", g.score1, g.score2)
    draw_text_centered(score_text, 28, 46, FG)

    host_name := remote_player_name(&app.net)
    client_name := local_player_name(&app.net)
    if app.net.role == .Host {
        host_name = local_player_name(&app.net)
        client_name = remote_player_name(&app.net)
    }
    names_buf: [160]u8
    names := fmt.bprintf(names_buf[:], "%s  vs  %s", host_name, client_name)
    draw_text_centered(names, 78, 16, MUTED)
    draw_text("ESC: menu", WINDOW_W - 108, 14, 16, MUTED)

    if app.preferences.show_net_stats {
        loss := packet_loss_percent(&app.net)
        silent_for := seconds_since_last_recv(&app.net)
        stats_buf: [256]u8
        if app.net.rtt_valid {
            stats := fmt.bprintf(stats_buf[:], "RTT: %.0f ms   loss: %.1f%%   last packet: %.2f s", app.net.rtt_smoothed_ms, loss, silent_for)
            draw_text(stats, 18, WINDOW_H - 46, 15, MUTED)
        } else {
            stats := fmt.bprintf(stats_buf[:], "RTT: measuring...   loss: %.1f%%   last packet: %.2f s", loss, silent_for)
            draw_text(stats, 18, WINDOW_H - 46, 15, MUTED)
        }

        counts_buf: [256]u8
        counts := fmt.bprintf(
            counts_buf[:],
            "%s UDP   session:%d   sent:%d recv:%d   stream recv:%d lost:%d   errors:%d/%d",
            net_transport_name(&app.net),
            app.net.session_id,
            app.net.packets_sent,
            app.net.packets_recv,
            app.net.stream_packets_recv,
            app.net.stream_packets_lost,
            app.net.send_errors,
            app.net.recv_errors,
        )
        draw_text(counts, 18, WINDOW_H - 26, 15, MUTED)
    }

    if g.countdown_timer > 0 {
        countdown := "1"
        if g.countdown_timer > 2 { countdown = "3" } else if g.countdown_timer > 1 { countdown = "2" }
        rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{7, 8, 12, 100})
        draw_text_centered(countdown, 198, 108, FG)
    } else if g.go_timer > 0 {
        draw_text_centered("GO!", 216, 80, GOOD)
    } else if g.serve_timer > 0 && !g.game_over {
        draw_text_centered("GET READY", WINDOW_H / 2 - 16, 24, MUTED)
    }

    if g.game_over {
        rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{7, 8, 12, 205})
        winner_name := host_name
        if g.winner == 2 { winner_name = client_name }
        win_buf: [128]u8
        winner_text := fmt.bprintf(win_buf[:], "%s WINS", winner_name)
        draw_text_centered(winner_text, 160, 42, FG)

        local_status := "YOU: NOT READY"
        opponent_status := "OPPONENT: NOT READY"
        if app.net.local_rematch { local_status = "YOU: REMATCH READY" }
        if app.net.remote_rematch { opponent_status = "OPPONENT: REMATCH READY" }
        local_colour := MUTED
        opponent_colour := MUTED
        if app.net.local_rematch { local_colour = GOOD }
        if app.net.remote_rematch { opponent_colour = GOOD }
        draw_text_centered(local_status, 225, 18, local_colour)
        draw_text_centered(opponent_status, 252, 18, opponent_colour)

        rematch_label := "REMATCH"
        rematch_enabled := !app.net.local_rematch && !app.paused
        if app.net.local_rematch { rematch_label = "WAITING..." }
        if button(rematch_label, rl.Rectangle{330, 305, 300, 52}, rematch_enabled) {
            net_request_rematch(&app.net)
        }
        draw_text_centered("ENTER also requests a rematch", 372, 15, MUTED)
        draw_text_centered("The next match starts when both players accept.", 410, 16, MUTED)
    }

    if app.paused {
        draw_pause_overlay(app)
    }
}

local_player_number :: proc(app: ^App) -> int {
    if app.net.role == .Host { return 1 }
    return 2
}

process_game_events :: proc(app: ^App, before, after: Game_State) {
    paddle_hit := before.ball_vx != 0 && after.ball_vx != 0 &&
                  ((before.ball_vx < 0 && after.ball_vx > 0) ||
                   (before.ball_vx > 0 && after.ball_vx < 0))

    if paddle_hit {
        play_paddle_sfx(&app.audio, app.preferences)
        hit_left := after.ball_vx > 0
        if hit_left {
            app.fx.p1_flash = 0.12
        } else {
            app.fx.p2_flash = 0.12
        }
        spawn_hit_particles(&app.fx, after.ball_x, after.ball_y, after.ball_vx > 0)
    }

    wall_hit := !paddle_hit && before.ball_vy != 0 && after.ball_vy != 0 &&
                ((before.ball_vy < 0 && after.ball_vy > 0) ||
                 (before.ball_vy > 0 && after.ball_vy < 0))
    if wall_hit {
        play_wall_sfx(&app.audio, app.preferences)
    }

    if after.score1 > before.score1 || after.score2 > before.score2 {
        play_score_sfx(&app.audio, app.preferences)
        app.fx.score_flash = 0.22
        if after.score1 > before.score1 {
            app.fx.score_side = 1
        } else {
            app.fx.score_side = 2
        }
    }

    if !before.game_over && after.game_over {
        if after.winner == local_player_number(app) {
            play_win_sfx(&app.audio, app.preferences)
        } else {
            play_lose_sfx(&app.audio, app.preferences)
        }
    }
}

update_countdown_sfx :: proc(app: ^App, g: ^Game_State) {
    stage := 0
    if g.countdown_timer > 2 {
        stage = 3
    } else if g.countdown_timer > 1 {
        stage = 2
    } else if g.countdown_timer > 0 {
        stage = 1
    } else if g.go_timer > 0 {
        stage = -1
    }

    if stage == app.countdown_sound_stage { return }
    app.countdown_sound_stage = stage
    if stage > 0 {
        play_countdown_sfx(&app.audio, app.preferences)
    } else if stage == -1 {
        play_go_sfx(&app.audio, app.preferences)
    }
}

leave_current_match :: proc(app: ^App) {
    cancel_match_start_fade(app)
    net_shutdown(&app.net)
    app.online_status = .Idle
    app.status_message = ""
    app.paused = false
    app.pause_settings = false
    app.countdown_sound_stage = 0
    save_config(app.preferences, app.last_game_rules)
    app.screen = .Online
}

draw_pause_overlay :: proc(app: ^App) {
    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{5, 6, 9, 218})

    if app.pause_settings {
        draw_pause_settings(app)
        return
    }

    draw_text_centered("MENU", 102, 48, FG)
    draw_text_centered("The online match continues while this menu is open.", 162, 16, DANGER)

    if button("RESUME", rl.Rectangle{330, 218, 300, 52}) {
        app.paused = false
    }
    if button("SETTINGS", rl.Rectangle{330, 286, 300, 52}) {
        app.pause_settings = true
    }
    if button("LEAVE MATCH", rl.Rectangle{330, 354, 300, 52}) {
        leave_current_match(app)
    }

    draw_text_centered("ESC resumes", 430, 15, MUTED)
}

draw_pause_settings :: proc(app: ^App) {
    draw_text_centered("SETTINGS", 42, 38, FG)
    draw_text_centered("Local settings; gameplay keeps running in the background.", 86, 15, MUTED)

    _ = setting_row_int("Music volume", &app.preferences.music_volume, 126, 0, 100, 5)
    draw_text("Mute music", 285, 190, 21, FG)
    music_label := "OFF"
    if app.preferences.music_muted { music_label = "ON" }
    if button(music_label, rl.Rectangle{618, 177, 150, 42}) {
        app.preferences.music_muted = !app.preferences.music_muted
    }

    _ = setting_row_int("SFX volume", &app.preferences.sfx_volume, 230, 0, 100, 5)
    draw_text("Mute SFX", 285, 294, 21, FG)
    sfx_label := "OFF"
    if app.preferences.sfx_muted { sfx_label = "ON" }
    if button(sfx_label, rl.Rectangle{618, 281, 150, 42}) {
        app.preferences.sfx_muted = !app.preferences.sfx_muted
    }

    draw_text("Display mode", 285, 346, 21, FG)
    display_label := "WINDOWED"
    if app.preferences.fullscreen { display_label = "FULLSCREEN" }
    if button(display_label, rl.Rectangle{560, 333, 208, 42}) {
        app.preferences.fullscreen = !app.preferences.fullscreen
        app.display_change_pending = true
    }

    draw_text("Show net stats", 285, 398, 21, FG)
    stats_label := "OFF"
    if app.preferences.show_net_stats { stats_label = "ON" }
    if button(stats_label, rl.Rectangle{618, 385, 150, 42}) {
        app.preferences.show_net_stats = !app.preferences.show_net_stats
    }

    if button("BACK", rl.Rectangle{360, 460, 240, 44}) {
        save_config(app.preferences, app.last_game_rules)
        app.pause_settings = false
    }
}

draw_transition_overlay :: proc(app: ^App) {
    if app.transition_alpha <= 0 { return }
    alpha := u8(app.transition_alpha * 255.0)
    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{5, 6, 9, alpha})
}

