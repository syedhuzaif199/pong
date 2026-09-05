package main

import "core:fmt"
import "core:os"
import "core:net"
import "core:strconv"
import "core:strings"

CONFIG_FILE :: "pong.cfg"
CONFIG_DIR_NAME :: "IPv6UDPPong"

config_directory :: proc() -> string {
    when ODIN_OS == .Windows {
        base := os.get_env("APPDATA", context.temp_allocator)
        if len(base) > 0 {
            return fmt.tprintf("%s%c%s", base, os.Path_Separator, CONFIG_DIR_NAME)
        }
    } else when ODIN_OS == .Darwin {
        home := os.get_env("HOME", context.temp_allocator)
        if len(home) > 0 {
            return fmt.tprintf("%s%cLibrary%cApplication Support%c%s", home, os.Path_Separator, os.Path_Separator, os.Path_Separator, CONFIG_DIR_NAME)
        }
    } else {
        xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
        if len(xdg) > 0 {
            return fmt.tprintf("%s%c%s", xdg, os.Path_Separator, CONFIG_DIR_NAME)
        }

        home := os.get_env("HOME", context.temp_allocator)
        if len(home) > 0 {
            return fmt.tprintf("%s%c.config%c%s", home, os.Path_Separator, os.Path_Separator, CONFIG_DIR_NAME)
        }
    }

    return "."
}

config_file_path :: proc() -> string {
    dir := config_directory()
    if dir == "." {
        return CONFIG_FILE
    }
    _ = os.make_directory_all(dir)
    return fmt.tprintf("%s%c%s", dir, os.Path_Separator, CONFIG_FILE)
}

// These are local application preferences. They never affect the other player.
App_Settings :: struct {
    player_name:     Text_Field,
    music_volume:    int,
    music_muted:     bool,
    sfx_volume:      int,
    sfx_muted:       bool,
    fullscreen:      bool,
    show_net_stats:  bool,
    last_join_ipv6:  Text_Field,
    last_join_port:  int,
}

default_app_settings :: proc() -> App_Settings {
    settings := App_Settings{
        music_volume = 35,
        music_muted = false,
        sfx_volume = 70,
        sfx_muted = false,
        fullscreen = false,
        show_net_stats = true,
        last_join_port = 7777,
    }
    text_field_set(&settings.player_name, "Player")
    text_field_set(&settings.last_join_ipv6, "::1")
    return settings
}

sanitize_player_name :: proc(field: ^Text_Field) {
    if field.length <= 0 {
        text_field_set(field, "Player")
    }
    if field.length > 24 {
        field.length = 24
    }
}

load_config :: proc(settings: ^App_Settings, last_rules: ^Game_Rules) {
    path := config_file_path()
    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil && path != CONFIG_FILE {
        // v8 and older stored pong.cfg beside the executable. Read that once as
        // a migration fallback; the next save writes to the platform config dir.
        data, err = os.read_entire_file_from_path(CONFIG_FILE, context.temp_allocator)
    }
    if err != nil {
        return
    }

    rest := string(data)
    for len(rest) > 0 {
        line, _ := strings.split_iterator(&rest, "\n")
        if len(line) == 0 {
            continue
        }

        value_rest := line
        key, ok := strings.split_iterator(&value_rest, "=")
        if !ok {
            continue
        }
        value := value_rest

        switch key {
        case "player_name":
            text_field_set(&settings.player_name, value)
            sanitize_player_name(&settings.player_name)
        case "music_volume":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok && parsed >= 0 && parsed <= 100 {
                settings.music_volume = parsed
            }
        case "music_muted":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok {
                settings.music_muted = parsed != 0
            }
        case "sfx_volume":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok && parsed >= 0 && parsed <= 100 {
                settings.sfx_volume = parsed
            }
        case "sfx_muted":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok {
                settings.sfx_muted = parsed != 0
            }
        case "fullscreen":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok {
                settings.fullscreen = parsed != 0
            }
        case "show_net_stats":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok {
                settings.show_net_stats = parsed != 0
            }
        case "last_join_ipv6":
            if _, address_ok := net.parse_ip6_address(value); address_ok {
                text_field_set(&settings.last_join_ipv6, value)
            }
        case "last_join_port":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok && parsed >= 1 && parsed <= 65535 {
                settings.last_join_port = parsed
            }
        case "last_winning_score":
            parsed, parse_ok := strconv.parse_int(value)
            if parse_ok && parsed >= 1 && parsed <= 21 {
                last_rules.winning_score = parsed
            }
        case "last_ball_speed":
            parsed, parse_ok := strconv.parse_f32(value)
            if parse_ok && parsed >= 250 && parsed <= 900 {
                last_rules.ball_speed = parsed
            }
        case "last_paddle_speed":
            parsed, parse_ok := strconv.parse_f32(value)
            if parse_ok && parsed >= 250 && parsed <= 900 {
                last_rules.paddle_speed = parsed
            }
        }
    }
}

save_config :: proc(settings: App_Settings, last_rules: Game_Rules) {
    muted: int = 0
    sfx_muted: int = 0
    fullscreen: int = 0
    stats: int = 0
    if settings.music_muted { muted = 1 }
    if settings.sfx_muted { sfx_muted = 1 }
    if settings.fullscreen { fullscreen = 1 }
    if settings.show_net_stats { stats = 1 }

    player_name := settings.player_name
    name := text_field_string(&player_name)
    if len(name) == 0 { name = "Player" }

    last_join_ipv6_field := settings.last_join_ipv6
    last_join_ipv6 := text_field_string(&last_join_ipv6_field)
    if len(last_join_ipv6) == 0 { last_join_ipv6 = "::1" }

    buf: [1024]u8
    text := fmt.bprintf(
        buf[:],
        "player_name=%s\nmusic_volume=%d\nmusic_muted=%d\nsfx_volume=%d\nsfx_muted=%d\nfullscreen=%d\nshow_net_stats=%d\nlast_join_ipv6=%s\nlast_join_port=%d\nlast_winning_score=%d\nlast_ball_speed=%.0f\nlast_paddle_speed=%.0f\n",
        name,
        settings.music_volume,
        muted,
        settings.sfx_volume,
        sfx_muted,
        fullscreen,
        stats,
        last_join_ipv6,
        settings.last_join_port,
        last_rules.winning_score,
        last_rules.ball_speed,
        last_rules.paddle_speed,
    )
    _ = os.write_entire_file_from_string(config_file_path(), text)
}
