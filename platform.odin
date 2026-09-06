package main

import rl "vendor:raylib"

PONG_ANDROID :: #config(PONG_ANDROID, false)

foreign {
    pong_android_http_post :: proc "c" (
        url: cstring,
        payload: cstring,
        output: [^]u8,
        output_capacity: i32,
        timeout_ms: i32,
    ) -> i32 ---

    pong_android_internal_data_path :: proc "c" (
        output: [^]u8,
        output_capacity: i32,
    ) -> i32 ---

    pong_android_show_keyboard :: proc "c" (show: bool) ---
}

platform_internal_data_path :: proc(buf: []u8) -> string {
    when PONG_ANDROID {
        if len(buf) == 0 { return "" }
        n := int(pong_android_internal_data_path(cast([^]u8)raw_data(buf), i32(len(buf))))
        if n <= 0 || n > len(buf) { return "" }
        return string(buf[:n])
    } else {
        return ""
    }
}

platform_show_keyboard :: proc(show: bool) {
    when PONG_ANDROID {
        pong_android_show_keyboard(show)
    }
}

platform_window_back_pressed :: proc() -> bool {
    when PONG_ANDROID {
        return rl.IsKeyPressed(.ESCAPE)
    } else {
        return rl.IsKeyPressed(.ESCAPE)
    }
}
