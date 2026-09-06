package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import rl "vendor:raylib"

APP_VERSION :: "v1.5.0"
PRE_COUNTDOWN_FADE_TIME :: f32(0.40)
LAN_IPV4_FALLBACK_DELAY :: f64(0.75)

Screen :: enum {
    Main_Menu,
    Local_Play,
    Local_Setup,
    Online,
    Host_Setup,
    Join_Setup,
    Internet_Host,
    Internet_Join,
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

    match_mode: Match_Mode,
    selected_local_mode: Match_Mode,
    cpu_difficulty: CPU_Difficulty,
    cpu_ai: CPU_AI,

    address: Text_Field,
    port: Text_Field,
    rendezvous_url: Text_Field,
    room_code: Text_Field,

    internet: Internet_State,

    lan_fallback_ipv4: [32]u8,
    lan_fallback_ipv4_length: int,
    lan_fallback_pending: bool,
    lan_fallback_used: bool,
    online_status: Online_Status,
    status_message: string,
    connection_origin: Screen,

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

    saved_preferences: App_Settings,
    saved_game_rules: Game_Rules,
    config_autosave_timer: f32,

    mobile_control_hint_timer: f32,
    input: Input_State,

    connection_was_interrupted: bool,
    reconnect_notice_timer: f32,
    resume_notice_timer: f32,
}

prepare_runtime_directory :: proc() {
    when PONG_ANDROID { return }

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

run_game :: proc() {
    prepare_runtime_directory()
    http_ready := internet_http_init()
    defer if http_ready { internet_http_shutdown() }

    when PONG_ANDROID {
        rl.SetConfigFlags({.VSYNC_HINT})
        rl.InitWindow(0, 0, "UDP Pong")
        rl.SetTargetFPS(60)
    } else {
        rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE})
        rl.InitWindow(WINDOW_W, WINDOW_H, "UDP Pong")
        rl.SetWindowMinSize(640, 360)
        rl.SetTargetFPS(120)
    }
    defer rl.CloseWindow()
    // Keep Escape available to our menus instead of letting raylib close the window.
    rl.SetExitKey(.KEY_NULL)

    app := App{}
    app.running = true
    app.screen = .Main_Menu
    app.preferences = default_app_settings()
    app.last_game_rules = default_game_rules()
    load_config(&app.preferences, &app.last_game_rules)
    app.match_mode = .Online
    app.selected_local_mode = .Vs_CPU
    if app.preferences.cpu_difficulty == 0 {
        app.cpu_difficulty = .Easy
    } else if app.preferences.cpu_difficulty == 2 {
        app.cpu_difficulty = .Hard
    } else {
        app.cpu_difficulty = .Normal
    }
    reset_cpu_ai(&app.cpu_ai)
    app.saved_preferences = app.preferences
    app.saved_game_rules = app.last_game_rules
    app.network_rules = app.last_game_rules

    app.address = app.preferences.last_join_address
    port_buf: [32]u8
    port_text := fmt.bprintf(port_buf[:], "%d", app.preferences.last_join_port)
    text_field_set(&app.port, port_text)

    app.rendezvous_url = app.preferences.rendezvous_url
    reset_match(&app.game)
    app.render_game = app.game
    app.target_game = app.game

    when !PONG_ANDROID {
        if app.preferences.fullscreen != rl.IsWindowFullscreen() {
            rl.ToggleFullscreen()
        }
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

        foreground := platform_app_foreground()
        when PONG_ANDROID {
            if !foreground {
                // Android may kill a backgrounded activity without returning through
                // the normal shutdown path. Flush any pending preferences immediately.
                save_app_config(&app)
                if audio_ready { music_suspend(&app.music) }
            }
            if platform_consume_resume_event() {
                if audio_ready { music_resume(&app.music) }
                app.resume_notice_timer = 2.5
                if app.screen == .Game { begin_mobile_control_hint(&app) }
            }
        }

        frame_screen := app.screen
        if foreground {
            update_app(&app, dt)
            update_config_autosave(&app, dt)
        }
        if app.screen != frame_screen { app.transition_alpha = 1 }

        if audio_ready && foreground {
            update_music_mode(&app)
            music_update(&app.music, app.preferences, dt)
        }

        ui_begin_frame()

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
        ui_end_frame()
    }

    save_app_config(&app)
    discovery_host_shutdown(&app.discovery_host)
    discovery_client_shutdown(&app.discovery_client)
    internet_cancel(&app.internet, &app.net)
    rl.UnloadRenderTexture(canvas)

    if audio_ready {
        music_unload(&app.music)
        audio_unload_sfx(&app.audio)
        rl.CloseAudioDevice()
    }
}


main :: proc() {
    run_game()
}


save_app_config :: proc(app: ^App) {
    if save_config(app.preferences, app.last_game_rules) {
        app.saved_preferences = app.preferences
        app.saved_game_rules = app.last_game_rules
        app.config_autosave_timer = 0
    }
}

update_config_autosave :: proc(app: ^App, dt: f32) {
    if config_values_equal(app.preferences, app.saved_preferences, app.last_game_rules, app.saved_game_rules) {
        app.config_autosave_timer = 0
        return
    }

    app.config_autosave_timer += dt
    if app.config_autosave_timer >= 0.20 {
        save_app_config(app)
    }
}

begin_mobile_control_hint :: proc(app: ^App) {
    when PONG_ANDROID {
        app.mobile_control_hint_timer = 6.0
    }
}

update_connection_feedback :: proc(app: ^App) {
    net_update_diagnostics(&app.net)

    interrupted := connection_interrupted(&app.net)
    if app.connection_was_interrupted && !interrupted && app.net.connected {
        app.reconnect_notice_timer = 2.5
    }
    app.connection_was_interrupted = interrupted
}

reset_connection_feedback :: proc(app: ^App) {
    app.connection_was_interrupted = false
    app.reconnect_notice_timer = 0
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
    if app.reconnect_notice_timer > 0 {
        app.reconnect_notice_timer = max(f32(0), app.reconnect_notice_timer - dt)
    }
    if app.resume_notice_timer > 0 {
        app.resume_notice_timer = max(f32(0), app.resume_notice_timer - dt)
    }
    update_visual_fx(&app.fx, dt)

    when !PONG_ANDROID {
        alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
        if alt_down && rl.IsKeyPressed(.ENTER) {
            app.preferences.fullscreen = !app.preferences.fullscreen
            app.display_change_pending = true
            save_app_config(app)
        }

        if app.display_change_pending {
            if app.preferences.fullscreen != rl.IsWindowFullscreen() {
                rl.ToggleFullscreen()
            }
            app.display_change_pending = false
        }
    }

    switch app.screen {
    case .Main_Menu:
        // Buttons perform transitions in draw_main_menu.

    case .Local_Play:
        if input_back_pressed() {
            app.screen = .Main_Menu
        }

    case .Local_Setup:
        if input_back_pressed() {
            app.screen = .Local_Play
        }

    case .Online:
        if input_back_pressed() {
            app.screen = .Main_Menu
        }

    case .Host_Setup:
        update_host_setup(app)

    case .Join_Setup:
        update_join_setup(app)

    case .Internet_Host:
        update_internet_host(app)

    case .Internet_Join:
        update_internet_join(app)

    case .Lobby:
        update_lobby(app, dt)

    case .Settings:
        text_field_update(&app.preferences.player_name, allow_player_name_char)
        if app.preferences.player_name.length > MAX_PLAYER_NAME {
            app.preferences.player_name.length = MAX_PLAYER_NAME
        }
        if input_back_pressed() {
            sanitize_player_name(&app.preferences.player_name)
            save_app_config(app)
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

    if input_back_pressed() {
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

    if input_back_pressed() {
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
            begin_mobile_control_hint(app)
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

persist_rendezvous_settings :: proc(app: ^App) {
    app.preferences.rendezvous_url = app.rendezvous_url
    save_app_config(app)
}

start_internet_hosting :: proc(app: ^App) {
    app.match_mode = .Online
    cancel_match_start_fade(app)
    reset_connection_feedback(app)

    rendezvous_url := text_field_string(&app.rendezvous_url)
    if !internet_valid_rendezvous_url(rendezvous_url) {
        app.online_status = .Error
        app.status_message = "Enter a rendezvous URL beginning with http:// or https://."
        return
    }

    sanitize_player_name(&app.preferences.player_name)
    app.network_rules = app.last_game_rules
    reset_match(&app.game)
    app.render_game = app.game
    app.target_game = app.game
    persist_rendezvous_settings(app)

    if !internet_begin_host(
        &app.internet,
        &app.net,
        rendezvous_url,
        text_field_string(&app.preferences.player_name),
    ) {
        app.online_status = .Error
        app.status_message = "Could not start Internet rendezvous."
        return
    }

    app.online_status = .Hosting
    app.connection_origin = .Internet_Host
    app.status_message = ""
}

start_internet_joining :: proc(app: ^App) {
    app.match_mode = .Online
    cancel_match_start_fade(app)
    reset_connection_feedback(app)

    rendezvous_url := text_field_string(&app.rendezvous_url)
    if !internet_valid_rendezvous_url(rendezvous_url) {
        app.online_status = .Error
        app.status_message = "Enter a rendezvous URL beginning with http:// or https://."
        return
    }

    sanitize_player_name(&app.preferences.player_name)
    reset_match(&app.target_game)
    app.render_game = app.target_game
    app.network_rules = default_game_rules()
    persist_rendezvous_settings(app)

    if !internet_begin_join(
        &app.internet,
        &app.net,
        rendezvous_url,
        text_field_string(&app.room_code),
        text_field_string(&app.preferences.player_name),
    ) {
        app.online_status = .Error
        app.status_message = "Could not start Internet rendezvous."
        return
    }

    app.online_status = .Joining
    app.connection_origin = .Internet_Join
    app.status_message = ""
}

update_internet_host :: proc(app: ^App) {
    active := app.online_status == .Hosting
    if !active {
        text_field_update(&app.rendezvous_url, allow_server_url_char)
    }

    if input_back_pressed() {
        if active {
            internet_cancel(&app.internet, &app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            if app.net.socket_open { internet_cancel(&app.internet, &app.net) }
            app.screen = .Online
        }
        return
    }

    if !active { return }

    if app.internet.phase != .Ready {
        internet_update(&app.internet, &app.net)
    }
    if app.internet.phase == .Error {
        app.online_status = .Error
        return
    }
    if app.internet.phase != .Ready { return }

    connected, _ := net_receive_host(&app.net, app.network_rules, &app.game)
    if connected {
        internet_detach(&app.internet)
        app.render_game = app.game
        app.target_game = app.game
        app.screen = .Lobby
        return
    }

    if rl.GetTime() - app.internet.phase_started_time > JOIN_TIMEOUT {
        internet_fail(&app.internet, "Direct UDP path opened, but the Pong handshake timed out.")
        app.online_status = .Error
    }
}

update_internet_join :: proc(app: ^App) {
    active := app.online_status == .Joining
    if !active {
        text_field_update(&app.rendezvous_url, allow_server_url_char)
        text_field_update(&app.room_code, allow_room_code_char)
        if app.room_code.length > 8 { app.room_code.length = 8 }
    }

    if input_back_pressed() {
        if active {
            internet_cancel(&app.internet, &app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            if app.net.socket_open { internet_cancel(&app.internet, &app.net) }
            app.screen = .Online
        }
        return
    }

    if !active { return }

    if app.internet.phase != .Ready {
        internet_update(&app.internet, &app.net)
    }
    if app.internet.phase == .Error {
        app.online_status = .Error
        return
    }
    if app.internet.phase != .Ready { return }

    client_send_handshake_if_due(&app.net)
    _, got_lobby, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
    if app.net.protocol_mismatch {
        internet_fail(&app.internet, "Peer is running an incompatible gameplay protocol.")
        app.online_status = .Error
        return
    }

    if got_state || got_lobby {
        internet_detach(&app.internet)
        if got_state {
            app.render_game = app.target_game
            app.paused = false
            app.pause_settings = false
            app.countdown_sound_stage = 0
            begin_mobile_control_hint(app)
            app.screen = .Game
        } else {
            app.screen = .Lobby
        }
        return
    }

    if join_timed_out(&app.net) {
        internet_fail(&app.internet, "Direct UDP path opened, but the Pong handshake timed out.")
        app.online_status = .Error
    }
}

host_setup_return_screen :: proc(app: ^App) -> Screen {
    if app.connection_origin == .Internet_Host { return .Internet_Host }
    return .Host_Setup
}

join_setup_return_screen :: proc(app: ^App) -> Screen {
    if app.connection_origin == .Internet_Join { return .Internet_Join }
    return .Join_Setup
}

update_lobby :: proc(app: ^App, dt: f32) {
    if input_back_pressed() {
        cancel_match_start_fade(app)
        net_shutdown(&app.net)
        app.online_status = .Idle
        app.status_message = ""
        app.screen = .Online
        return
    }

    if input_confirm_pressed() && app.net.connected && !connection_interrupted(&app.net) && !app.match_start_pending {
        net_set_local_ready(&app.net, !app.net.local_ready)
    }

    #partial switch app.net.role {
    case .Host:
        _, _ = net_receive_host(&app.net, app.network_rules, &app.game)
        update_connection_feedback(app)
        if app.net.peer_left {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Player left the lobby."
            app.screen = host_setup_return_screen(app)
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Player did not return before the reconnect grace expired."
            app.screen = host_setup_return_screen(app)
            return
        }

        net_send_ping_if_due(&app.net)
        net_send_lobby_if_due(&app.net)
        if connection_interrupted(&app.net) {
            cancel_match_start_fade(app)
            return
        }

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
                begin_mobile_control_hint(app)
                app.screen = .Game
            }
        } else {
            cancel_match_start_fade(app)
        }

    case .Client:
        _, _, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
        update_connection_feedback(app)
        if got_state {
            cancel_match_start_fade(app)
            clear_ready_state(&app.net)
            app.render_game = app.target_game
            app.paused = false
            app.pause_settings = false
            app.countdown_sound_stage = 0
            begin_mobile_control_hint(app)
            app.screen = .Game
            return
        }
        if app.net.peer_left {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Host closed the lobby."
            app.screen = join_setup_return_screen(app)
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            cancel_match_start_fade(app)
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Host did not return before the reconnect grace expired."
            app.screen = join_setup_return_screen(app)
            return
        }

        net_send_ping_if_due(&app.net)
        net_send_lobby_if_due(&app.net)
        if connection_interrupted(&app.net) {
            cancel_match_start_fade(app)
            return
        }

        if both_players_ready(&app.net) {
            begin_match_start_fade(app)
        } else {
            cancel_match_start_fade(app)
        }
    case:
    }
}

start_local_match :: proc(app: ^App) {
    cancel_match_start_fade(app)
    reset_connection_feedback(app)
    net_shutdown(&app.net, false)
    app.match_mode = app.selected_local_mode
    app.network_rules = app.last_game_rules
    save_app_config(app)

    begin_match_countdown(&app.game)
    app.render_game = app.game
    app.target_game = app.game
    reset_cpu_ai(&app.cpu_ai)
    app.paused = false
    app.pause_settings = false
    app.countdown_sound_stage = 0
    begin_mobile_control_hint(app)
    app.screen = .Game
}

start_local_rematch :: proc(app: ^App) {
    cancel_match_start_fade(app)
    begin_match_countdown(&app.game)
    app.render_game = app.game
    app.target_game = app.game
    reset_cpu_ai(&app.cpu_ai)
    app.paused = false
    app.pause_settings = false
    app.countdown_sound_stage = 0
    begin_mobile_control_hint(app)
}

update_local_game :: proc(app: ^App, dt: f32) {
    if app.game.game_over {
        alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
        if !app.paused && input_confirm_pressed() && !alt_down {
            start_local_rematch(app)
        }
        app.render_game = app.game
        return
    }

    if app.paused {
        app.render_game = app.game
        return
    }

    p1_input: f32 = 0
    p2_input: f32 = 0

    if app.match_mode == .Vs_CPU {
        p1_input = input_paddle_direction(&app.input)
        p2_input = cpu_paddle_direction(&app.cpu_ai, &app.game, app.cpu_difficulty, dt)
    } else if app.match_mode == .Local_2P {
        when PONG_ANDROID {
            p1_input, p2_input = input_android_local_2p()
        } else {
            p1_input = input_local_p1_direction()
            p2_input = input_local_p2_direction()
        }
    }

    before := app.game
    step_host_game(&app.game, app.network_rules, p1_input, p2_input, dt)
    process_game_events(app, before, app.game)
    app.render_game = app.game
}

update_game :: proc(app: ^App, dt: f32) {
    when PONG_ANDROID {
        if !app.paused && app.mobile_control_hint_timer > 0 {
            app.mobile_control_hint_timer = max(f32(0), app.mobile_control_hint_timer - dt)
        }
    }
    if input_pause_pressed() {
        if app.pause_settings {
            app.pause_settings = false
            save_app_config(app)
        } else {
            app.paused = !app.paused
        }
    }

    if app.match_mode != .Online {
        update_local_game(app, dt)
        update_countdown_sfx(app, &app.render_game)
        return
    }

    direction: f32 = 0
    if !app.paused {
        direction = input_paddle_direction(&app.input)
    }

    #partial switch app.net.role {
    case .Host:
        before := app.game
        _, _ = net_receive_host(&app.net, app.network_rules, &app.game)
        update_connection_feedback(app)
        if app.net.peer_left {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Opponent left the game."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = host_setup_return_screen(app)
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Opponent did not return before the reconnect grace expired."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = host_setup_return_screen(app)
            return
        }

        interrupted := connection_interrupted(&app.net)
        if interrupted { direction = 0 }

        net_send_ping_if_due(&app.net)
        if app.game.game_over {
            host_send_state_if_due(&app.net, app.game)
            net_send_rematch_if_due(&app.net)
            alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
            if !interrupted && !app.paused && input_confirm_pressed() && !alt_down { net_request_rematch(&app.net) }

            if !interrupted && both_players_want_rematch(&app.net) {
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
                    begin_mobile_control_hint(app)
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
            if !interrupted {
                step_host_game(&app.game, app.network_rules, direction, app.net.remote_input, dt)
            }
            // Keep sending the last authoritative state during the grace window.
            // If only the peer->host path was interrupted, this helps the peer
            // stay synchronized while probes restore the reverse direction.
            host_send_state_if_due(&app.net, app.game)
        }
        process_game_events(app, before, app.game)
        app.render_game = app.game

    case .Client:
        before := app.target_game
        _, _, got_state := net_receive_client(&app.net, &app.network_rules, &app.target_game)
        update_connection_feedback(app)
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
            app.screen = join_setup_return_screen(app)
            return
        }
        if !app.net.connected || connection_timed_out(&app.net) {
            net_shutdown(&app.net, false)
            app.online_status = .Error
            app.status_message = "Host did not return before the reconnect grace expired."
            cancel_match_start_fade(app)
            app.paused = false
            app.pause_settings = false
            app.screen = join_setup_return_screen(app)
            return
        }

        interrupted := connection_interrupted(&app.net)
        if interrupted { direction = 0 }

        if !app.render_game.game_over {
            client_send_input_if_due(&app.net, direction)
        }
        net_send_ping_if_due(&app.net)

        if !interrupted {
            interpolate_render_state(&app.render_game, app.target_game, dt, client_prediction_horizon(&app.net), max(app.net.rtt_jitter_ms, app.net.state_jitter_ms))
        }

        if !interrupted && !app.paused && app.render_game.countdown_timer <= 0 && !app.render_game.game_over {
            move_paddle(&app.render_game.p2_y, direction, app.network_rules.paddle_speed, dt)
        }

        if app.render_game.game_over {
            net_send_rematch_if_due(&app.net)
            alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
            if !interrupted && !app.paused && input_confirm_pressed() && !alt_down { net_request_rematch(&app.net) }

            if !interrupted && both_players_want_rematch(&app.net) {
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

draw_connection_banner :: proc(app: ^App, y: f32) {
    if connection_interrupted(&app.net) {
        remaining := connection_grace_remaining(&app.net)
        buf: [160]u8
        text := fmt.bprintf(buf[:], "CONNECTION INTERRUPTED  -  retrying for %.1f s", remaining)
        rect := rl.Rectangle{230, y, 500, 34}
        rl.DrawRectangleRec(rect, rl.Color{48, 25, 29, 225})
        rl.DrawRectangleLinesEx(rect, 1, DANGER)
        draw_text_centered_in(text, rect, 16, DANGER)
    } else if app.reconnect_notice_timer > 0 {
        rect := rl.Rectangle{330, y, 300, 32}
        rl.DrawRectangleRec(rect, rl.Color{20, 46, 33, 220})
        rl.DrawRectangleLinesEx(rect, 1, GOOD)
        draw_text_centered_in("CONNECTION RESTORED", rect, 16, GOOD)
    } else if app.resume_notice_timer > 0 {
        rect := rl.Rectangle{350, y, 260, 32}
        rl.DrawRectangleRec(rect, rl.Color{20, 34, 48, 210})
        rl.DrawRectangleLinesEx(rect, 1, ACCENT)
        draw_text_centered_in("RESUMED", rect, 16, ACCENT)
    }
}

draw_internet_phase_badge :: proc(s: ^Internet_State, y: f32) {
    step := internet_phase_step(s.phase)
    if step <= 0 { return }
    label := internet_phase_label(s.phase)
    buf: [96]u8
    text := fmt.bprintf(buf[:], "STEP %d/5  %s", step, label)
    rect := rl.Rectangle{720, y, 210, 28}
    rl.DrawRectangleRec(rect, rl.Color{20, 26, 36, 220})
    rl.DrawRectangleLinesEx(rect, 1, ACCENT)
    draw_text_centered_in(text, rect, 13, ACCENT)
}

draw_mobile_control_affordance :: proc(app: ^App) {
    when PONG_ANDROID {
        if app.paused || app.render_game.game_over { return }
        colour := rl.Color{143, 153, 170, 72}

        if app.match_mode == .Local_2P {
            draw_text("P1 ^", 42, 142, 18, colour)
            draw_text("LEFT HALF", 28, 174, 11, colour)
            draw_text("P1 v", 42, 365, 18, colour)
            draw_text("P2 ^", WINDOW_W - 82, 142, 18, colour)
            draw_text("RIGHT HALF", WINDOW_W - 112, 174, 11, colour)
            draw_text("P2 v", WINDOW_W - 82, 365, 18, colour)
            return
        }

        x: int = 66
        if app.match_mode == .Online && app.net.role == .Client { x = WINDOW_W - 82 }
        draw_text("^", x, 142, 24, colour)
        draw_text("TOUCH / SWIPE", x - 36, 174, 11, colour)
        draw_text("v", x, 365, 24, colour)
    }
}

draw_app :: proc(app: ^App) {
    switch app.screen {
    case .Main_Menu:
        draw_main_menu(app)
    case .Local_Play:
        draw_local_play(app)
    case .Local_Setup:
        draw_local_setup(app)
    case .Online:
        draw_online(app)
    case .Host_Setup:
        draw_host_setup(app)
    case .Join_Setup:
        draw_join_setup(app)
    case .Internet_Host:
        draw_internet_host(app)
    case .Internet_Join:
        draw_internet_join(app)
    case .Lobby:
        draw_lobby(app)
    case .Settings:
        draw_settings(app)
    case .Game:
        draw_game_screen(app)
    }
}

draw_main_menu :: proc(app: ^App) {
    draw_text_centered("PONG", 70, 72, FG)
    draw_text_centered("LOCAL + ONLINE / UDP", 151, 22, ACCENT)

    if button("PLAY LOCAL", rl.Rectangle{330, 215, 300, 54}) {
        app.screen = .Local_Play
        app.status_message = ""
        return
    }
    if button("PLAY ONLINE", rl.Rectangle{330, 281, 300, 54}) {
        app.match_mode = .Online
        app.screen = .Online
        app.online_status = .Idle
        app.status_message = ""
        return
    }
    if button("SETTINGS", rl.Rectangle{330, 347, 300, 54}) {
        app.screen = .Settings
        return
    }
    if button("QUIT", rl.Rectangle{330, 413, 300, 54}) {
        app.running = false
    }

    draw_text_centered("VS CPU, local 2-player, online room codes, LAN/direct", 488, 16, MUTED)
    version_buf: [128]u8
    version_text := fmt.bprintf(version_buf[:], "%s  |  protocol 4  |  discovery 1  |  rendezvous 1", APP_VERSION)
    draw_text(version_text, 18, WINDOW_H - 24, 13, MUTED)
}

draw_local_play :: proc(app: ^App) {
    draw_text_centered("LOCAL PLAY", 50, 48, FG)
    draw_text_centered("Same Pong physics, no network required.", 108, 17, MUTED)

    if button("VS CPU", rl.Rectangle{330, 180, 300, 58}) {
        app.selected_local_mode = .Vs_CPU
        app.screen = .Local_Setup
        return
    }
    draw_text_centered("Solo match against a fair reaction-based opponent", 246, 14, MUTED)

    if button("LOCAL 2P", rl.Rectangle{330, 300, 300, 58}) {
        app.selected_local_mode = .Local_2P
        app.screen = .Local_Setup
        return
    }
    when PONG_ANDROID {
        draw_text_centered("Two fingers: left half controls P1, right half controls P2", 366, 14, MUTED)
    } else {
        draw_text_centered("P1: W/S or controller 1   |   P2: arrows or controller 2", 366, 14, MUTED)
    }

    if button("BACK", rl.Rectangle{360, 458, 240, 46}) {
        app.screen = .Main_Menu
    }
}

draw_local_setup :: proc(app: ^App) {
    title := "LOCAL 2P SETUP"
    if app.selected_local_mode == .Vs_CPU { title = "VS CPU SETUP" }
    draw_text_centered(title, 30, 44, FG)

    y: f32 = 108
    if app.selected_local_mode == .Vs_CPU {
        draw_text("CPU difficulty", 285, int(y) + 10, 21, FG)
        if button("<", rl.Rectangle{560, f32(y), 48, 42}) {
            app.cpu_difficulty = cpu_difficulty_previous(app.cpu_difficulty)
            app.preferences.cpu_difficulty = int(app.cpu_difficulty)
        }
        difficulty := cpu_difficulty_name(app.cpu_difficulty)
        draw_text_centered_in(difficulty, rl.Rectangle{614, f32(y), 110, 42}, 18, ACCENT)
        if button(">", rl.Rectangle{730, f32(y), 48, 42}) {
            app.cpu_difficulty = cpu_difficulty_next(app.cpu_difficulty)
            app.preferences.cpu_difficulty = int(app.cpu_difficulty)
        }
        draw_text_centered("Difficulty changes reaction/aim only; CPU paddle speed obeys the same rules.", 158, 13, MUTED)
        y = 190
    } else {
        when PONG_ANDROID {
            draw_text_centered("P1 uses the left half of the screen; P2 uses the right half.", 118, 15, MUTED)
            draw_text_centered("Hold above/below center with two fingers to move both paddles.", 142, 13, MUTED)
        } else {
            draw_text_centered("P1: W/S or controller 1     P2: arrows or controller 2", 128, 15, MUTED)
        }
        y = 184
    }

    _ = setting_row_int("Winning score", &app.last_game_rules.winning_score, y, 1, 21, 1)
    _ = setting_row_f32("Ball speed", &app.last_game_rules.ball_speed, y + 58, 250, 900, 25)
    _ = setting_row_f32("Paddle speed", &app.last_game_rules.paddle_speed, y + 116, 250, 900, 25)

    if button("START MATCH", rl.Rectangle{330, 405, 300, 52}) {
        start_local_match(app)
        return
    }
    if button("BACK", rl.Rectangle{360, 474, 240, 44}) {
        save_app_config(app)
        app.screen = .Local_Play
    }
}

draw_online :: proc(app: ^App) {
    draw_text_centered("PLAY ONLINE", 42, 48, FG)
    draw_text_centered("Use a short room code over the Internet, or connect directly on a LAN/IP.", 104, 16, MUTED)

    if button("HOST WITH CODE", rl.Rectangle{330, 156, 300, 56}) {
        app.online_status = .Idle
        app.status_message = ""
        internet_reset(&app.internet)
        app.screen = .Internet_Host
        return
    }
    if button("JOIN WITH CODE", rl.Rectangle{330, 224, 300, 56}) {
        app.online_status = .Idle
        app.status_message = ""
        internet_reset(&app.internet)
        app.screen = .Internet_Join
        return
    }
    if button("HOST LAN / DIRECT", rl.Rectangle{330, 312, 300, 52}) {
        app.online_status = .Idle
        app.status_message = ""
        app.screen = .Host_Setup
        return
    }
    if button("JOIN LAN / DIRECT", rl.Rectangle{330, 376, 300, 52}) {
        app.online_status = .Idle
        app.status_message = ""
        discovery_client_shutdown(&app.discovery_client)
        _ = discovery_client_start(&app.discovery_client)
        app.screen = .Join_Setup
        return
    }
    if button("BACK", rl.Rectangle{360, 472, 240, 44}) {
        app.screen = .Main_Menu
    }

    draw_text_centered("Room-code play uses Cloudflare STUN + HTTP rendezvous + direct UDP hole punching.", 532, 13, MUTED)
}

draw_internet_host :: proc(app: ^App) {
    active := app.online_status == .Hosting

    draw_text_centered("HOST WITH CODE", 18, 40, FG)
    draw_text_centered("Cloudflare discovers your UDP mapping; the rendezvous service only exchanges room data.", 62, 14, MUTED)
    if active || app.internet.phase == .Error { draw_internet_phase_badge(&app.internet, 20) }

    text_field("Rendezvous URL", &app.rendezvous_url, rl.Rectangle{190, 94, 610, 44}, !active, .Uri)

    _ = setting_row_int("Winning score", &app.last_game_rules.winning_score, 156, 1, 21, 1, !active)
    _ = setting_row_f32("Ball speed", &app.last_game_rules.ball_speed, 208, 250, 900, 25, !active)
    _ = setting_row_f32("Paddle speed", &app.last_game_rules.paddle_speed, 260, 250, 900, 25, !active)

    if button("CREATE ROOM", rl.Rectangle{330, 320, 300, 48}, !active) {
        start_internet_hosting(app)
    }

    code := internet_room_code(&app.internet)
    if len(code) > 0 {
        draw_text_centered("ROOM CODE", 382, 14, MUTED)
        draw_text_centered(code, 402, 36, ACCENT)
        if button("COPY CODE", rl.Rectangle{660, 397, 150, 38}) {
            clipboard_set_text(code)
            app.status_message = "Room code copied."
        }
    }

    if app.internet.public_endpoint_valid {
        endpoint_buf: [128]u8
        endpoint := internet_public_endpoint_text(&app.internet, endpoint_buf[:])
        public_buf: [192]u8
        public_text := fmt.bprintf(public_buf[:], "STUN public endpoint: %s", endpoint)
        draw_text_centered(public_text, 452, 13, MUTED)
    }

    if active || app.internet.phase == .Error {
        status := internet_status(&app.internet)
        colour := GOOD
        if app.internet.phase == .Error { colour = DANGER }
        draw_text_centered(status, 478, 14, colour)
    } else if app.status_message != "" {
        draw_text_centered(app.status_message, 478, 14, ACCENT)
    } else {
        draw_text_centered("Share the six-character code. No IP address needs to be exchanged manually.", 478, 14, MUTED)
    }

    back_label := "BACK"
    if active { back_label = "CANCEL" }
    if button(back_label, rl.Rectangle{30, 500, 180, 34}) {
        if active {
            internet_cancel(&app.internet, &app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            if app.net.socket_open { internet_cancel(&app.internet, &app.net) }
            app.screen = .Online
        }
    }
}

draw_internet_join :: proc(app: ^App) {
    active := app.online_status == .Joining

    draw_text_centered("JOIN WITH CODE", 24, 40, FG)
    draw_text_centered("Enter the same HTTP rendezvous URL and the code sent by the host.", 70, 14, MUTED)
    if active || app.internet.phase == .Error { draw_internet_phase_badge(&app.internet, 24) }

    text_field("Rendezvous URL", &app.rendezvous_url, rl.Rectangle{190, 112, 610, 46}, !active, .Uri)
    text_field("Room code", &app.room_code, rl.Rectangle{300, 206, 360, 54}, !active, .Code)

    if button("JOIN ROOM", rl.Rectangle{330, 292, 300, 52}, !active) {
        start_internet_joining(app)
    }

    if app.internet.public_endpoint_valid {
        endpoint_buf: [128]u8
        endpoint := internet_public_endpoint_text(&app.internet, endpoint_buf[:])
        public_buf: [192]u8
        public_text := fmt.bprintf(public_buf[:], "STUN public endpoint: %s", endpoint)
        draw_text_centered(public_text, 376, 13, MUTED)
    }

    if active || app.internet.phase == .Error {
        status := internet_status(&app.internet)
        colour := GOOD
        if app.internet.phase == .Error { colour = DANGER }
        draw_text_centered(status, 420, 15, colour)
    } else if app.status_message != "" {
        draw_text_centered(app.status_message, 420, 15, DANGER)
    } else {
        draw_text_centered("Pong tries native IPv6, same-LAN IPv4, then the STUN-observed public IPv4 mapping.", 420, 13, MUTED)
    }

    draw_text_centered("If all direct candidates fail, this NAT likely needs relay/TURN support.", 456, 13, MUTED)

    back_label := "BACK"
    if active { back_label = "CANCEL" }
    if button(back_label, rl.Rectangle{30, 500, 180, 34}) {
        if active {
            internet_cancel(&app.internet, &app.net)
            app.online_status = .Idle
            app.status_message = ""
        } else {
            if app.net.socket_open { internet_cancel(&app.internet, &app.net) }
            app.screen = .Online
        }
    }
}

draw_settings :: proc(app: ^App) {
    draw_text_centered("SETTINGS", 16, 38, FG)
    draw_text_centered("Local preferences only; these do not change match rules.", 58, 15, MUTED)

    text_field("Player name", &app.preferences.player_name, rl.Rectangle{500, 88, 268, 40})
    draw_text("Shown online and in VS CPU", 500, 132, 13, MUTED)

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

    when !PONG_ANDROID {
        draw_text("Alt+Enter toggles fullscreen anywhere", 42, 508, 14, MUTED)
    }
    if button("BACK", rl.Rectangle{360, 482, 240, 42}) {
        sanitize_player_name(&app.preferences.player_name)
        save_app_config(app)
        app.screen = .Main_Menu
    }
}

draw_host_setup :: proc(app: ^App) {
    controls_disabled := app.online_status == .Hosting

    draw_text_centered("HOST GAME", 28, 42, FG)
    draw_text_centered("Choose this match's rules. They are remembered for your next hosted game.", 76, 16, MUTED)

    text_field("Port", &app.port, rl.Rectangle{370, 112, 220, 48}, !controls_disabled, .Number)

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

    text_field("IP address", &app.address, rl.Rectangle{120, 344, 510, 46}, !controls_disabled, .Uri)
    text_field("Port", &app.port, rl.Rectangle{650, 344, 120, 46}, !controls_disabled, .Number)
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
        save_app_config(app)
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
    app.connection_origin = .Join_Setup
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
    draw_connection_banner(app, 112)

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
    when !PONG_ANDROID {
        draw_text_centered("ENTER / controller A toggles ready", 418, 13, MUTED)
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
    app.match_mode = .Online
    cancel_match_start_fade(app)
    reset_connection_feedback(app)
    port, ok := parse_port_field(app)
    if !ok {
        app.online_status = .Error
        app.status_message = "Port must be between 1 and 65535."
        return
    }

    app.network_rules = app.last_game_rules
    save_app_config(app)

    sanitize_player_name(&app.preferences.player_name)
    if !net_host(&app.net, port, text_field_string(&app.preferences.player_name)) {
        app.online_status = .Error
        app.status_message = "Could not bind the UDP gameplay socket. Is the port already in use?"
        return
    }

    reset_match(&app.game)
    _ = discovery_host_start(&app.discovery_host, port, text_field_string(&app.preferences.player_name), app.net.accepts_ipv6)
    app.online_status = .Hosting
    app.connection_origin = .Host_Setup
    app.status_message = ""
}

start_joining :: proc(app: ^App) {
    app.match_mode = .Online
    cancel_match_start_fade(app)
    reset_connection_feedback(app)
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

    host_name := "PLAYER 1"
    client_name := "PLAYER 2"
    cpu_name_buf: [64]u8

    if app.match_mode == .Online {
        host_name = remote_player_name(&app.net)
        client_name = local_player_name(&app.net)
        if app.net.role == .Host {
            host_name = local_player_name(&app.net)
            client_name = remote_player_name(&app.net)
        }
    } else if app.match_mode == .Vs_CPU {
        player_field := app.preferences.player_name
        host_name = text_field_string(&player_field)
        if len(host_name) == 0 { host_name = "PLAYER" }
        client_name = fmt.bprintf(cpu_name_buf[:], "CPU / %s", cpu_difficulty_name(app.cpu_difficulty))
    }

    names_buf: [160]u8
    names := fmt.bprintf(names_buf[:], "%s  vs  %s", host_name, client_name)
    draw_text_centered(names, 78, 16, MUTED)
    if app.match_mode == .Online {
        draw_connection_banner(app, 102)
    }
    when PONG_ANDROID {
        if !app.paused && button("MENU", rl.Rectangle{WINDOW_W - 138, 12, 120, 44}) {
            app.paused = true
        }
    } else {
        draw_text("ESC: menu", WINDOW_W - 108, 14, 16, MUTED)
    }

    if app.match_mode == .Online && app.preferences.show_net_stats {
        loss := packet_loss_percent(&app.net)
        silent_for := seconds_since_last_recv(&app.net)
        stats_buf: [256]u8
        jitter := max(app.net.rtt_jitter_ms, app.net.state_jitter_ms)
        if app.net.rtt_valid {
            stats := fmt.bprintf(stats_buf[:], "RTT %.0f ms   jitter %.1f ms   loss %.1f%%   stream %.1f/s   last %.2f s", app.net.rtt_smoothed_ms, jitter, loss, app.net.stream_recv_rate, silent_for)
            draw_text(stats, 18, WINDOW_H - 46, 15, MUTED)
        } else {
            stats := fmt.bprintf(stats_buf[:], "RTT measuring...   loss %.1f%%   stream %.1f/s   last %.2f s", loss, app.net.stream_recv_rate, silent_for)
            draw_text(stats, 18, WINDOW_H - 46, 15, MUTED)
        }

        counts_buf: [256]u8
        counts := fmt.bprintf(
            counts_buf[:],
            "%s UDP   input:%s   session:%d   sent:%d recv:%d   stream recv:%d lost:%d   errors:%d/%d",
            net_transport_name(&app.net),
            input_source_name(app.input.source),
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

    when PONG_ANDROID {
        draw_mobile_control_affordance(app)
        if app.mobile_control_hint_timer > 0 && !app.paused && !g.game_over {
            fade := min(f32(1), app.mobile_control_hint_timer / 1.25)
            alpha := u8(f32(190) * fade)
            hint_colour := rl.Color{143, 153, 170, alpha}
            hint_bg := rl.Color{5, 6, 9, u8(f32(105) * fade)}

            rl.DrawRectangle(190, 120, 580, 42, hint_bg)
            if app.match_mode == .Local_2P {
                draw_text_centered("P1: LEFT HALF     P2: RIGHT HALF     HOLD TOP / BOTTOM", 131, 15, hint_colour)
            } else {
                draw_text_centered("HOLD TOP / BOTTOM  OR  SWIPE UP / DOWN", 131, 17, hint_colour)
            }
            rl.DrawRectangle(282, 378, 396, 36, hint_bg)
            draw_text_centered("PADDLE SPEED FOLLOWS THE SAME MATCH RULES", 387, 13, hint_colour)
        }
    }

    if g.game_over {
        rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{7, 8, 12, 205})
        winner_name := host_name
        if g.winner == 2 { winner_name = client_name }
        win_buf: [128]u8
        winner_text := fmt.bprintf(win_buf[:], "%s WINS", winner_name)
        draw_text_centered(winner_text, 160, 42, FG)

        if app.match_mode == .Online {
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
            draw_text_centered("ENTER / controller A also requests a rematch", 372, 15, MUTED)
            draw_text_centered("The next match starts when both players accept.", 410, 16, MUTED)
        } else {
            mode_text := "LOCAL 2P"
            if app.match_mode == .Vs_CPU {
                mode_text = "VS CPU"
            }
            draw_text_centered(mode_text, 226, 17, ACCENT)
            if button("REMATCH", rl.Rectangle{330, 294, 300, 54}, !app.paused) {
                start_local_rematch(app)
            }
            when !PONG_ANDROID {
                draw_text_centered("ENTER / controller A also starts a rematch", 366, 15, MUTED)
            }
            draw_text_centered("Pause menu lets you leave or change local settings.", 407, 15, MUTED)
        }
    }

    if app.paused {
        draw_pause_overlay(app)
    }
}

local_player_number :: proc(app: ^App) -> int {
    if app.match_mode == .Vs_CPU { return 1 }
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
        if app.match_mode == .Local_2P || after.winner == local_player_number(app) {
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
    reset_connection_feedback(app)
    if app.match_mode == .Online {
        net_shutdown(&app.net)
    } else {
        net_shutdown(&app.net, false)
    }
    app.online_status = .Idle
    app.status_message = ""
    app.paused = false
    app.pause_settings = false
    app.countdown_sound_stage = 0
    save_app_config(app)
    if app.match_mode == .Online {
        app.screen = .Online
    } else {
        app.screen = .Local_Play
    }
}

draw_pause_overlay :: proc(app: ^App) {
    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{5, 6, 9, 218})

    if app.pause_settings {
        draw_pause_settings(app)
        return
    }

    draw_text_centered("MENU", 102, 48, FG)
    if app.match_mode == .Online {
        draw_text_centered("The online match continues while this menu is open.", 162, 16, DANGER)
    } else {
        draw_text_centered("Local match paused.", 162, 16, MUTED)
    }

    if button("RESUME", rl.Rectangle{330, 218, 300, 52}) {
        app.paused = false
    }
    if button("SETTINGS", rl.Rectangle{330, 286, 300, 52}) {
        app.pause_settings = true
    }
    if button("LEAVE MATCH", rl.Rectangle{330, 354, 300, 52}) {
        leave_current_match(app)
    }

    when PONG_ANDROID {
        draw_text_centered("Android Back / MENU toggles this overlay", 430, 15, MUTED)
    } else {
        draw_text_centered("ESC resumes", 430, 15, MUTED)
    }
}

draw_pause_settings :: proc(app: ^App) {
    draw_text_centered("SETTINGS", 42, 38, FG)
    if app.match_mode == .Online {
        draw_text_centered("Local settings; online gameplay keeps running in the background.", 86, 15, MUTED)
    } else {
        draw_text_centered("Local match remains paused while settings are open.", 86, 15, MUTED)
    }

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
        save_app_config(app)
        app.pause_settings = false
    }
}

draw_transition_overlay :: proc(app: ^App) {
    if app.transition_alpha <= 0 { return }
    alpha := u8(app.transition_alpha * 255.0)
    rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Color{5, 6, 9, alpha})
}

