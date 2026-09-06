package main

import rl "vendor:raylib"

PONG_ANDROID :: #config(PONG_ANDROID, false)

Text_Input_Kind :: enum i32 {
    Text,
    Number,
    Uri,
    Code,
}

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

    pong_android_config_load :: proc "c" (
        output: [^]u8,
        output_capacity: i32,
    ) -> i32 ---

    pong_android_config_save :: proc "c" (text: cstring) -> i32 ---

    pong_android_begin_text_input :: proc "c" (
        initial_text: cstring,
        kind: i32,
    ) ---

    pong_android_end_text_input :: proc "c" () ---

    pong_android_get_text_input :: proc "c" (
        output: [^]u8,
        output_capacity: i32,
    ) -> i32 ---

    // Android async network worker. Bionic deliberately omits pthread
    // cancellation, so Android must not use Odin core:thread for rendezvous.
    pong_android_async_resolve_start :: proc "c" (host: cstring) -> i32 ---

    pong_android_async_http_start :: proc "c" (
        url: cstring,
        payload: cstring,
        timeout_ms: i32,
    ) -> i32 ---

    // 0 = idle, 1 = running, 2 = success, 3 = failed.
    pong_android_async_state :: proc "c" () -> i32 ---

    pong_android_async_take_result :: proc "c" (
        output: [^]u8,
        output_capacity: i32,
    ) -> i32 ---

    pong_android_async_abandon :: proc "c" () ---
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

platform_config_load :: proc(buf: []u8) -> string {
    when PONG_ANDROID {
        if len(buf) == 0 { return "" }
        n := int(pong_android_config_load(cast([^]u8)raw_data(buf), i32(len(buf))))
        if n <= 0 || n > len(buf) { return "" }
        return string(buf[:n])
    } else {
        return ""
    }
}

platform_config_save :: proc(text: string) -> bool {
    when PONG_ANDROID {
        buf: [2048]u8
        n := min(len(text), len(buf) - 1)
        if n > 0 {
            copy(buf[:n], transmute([]u8)text[:n])
        }
        buf[n] = 0
        return pong_android_config_save(cstring(raw_data(buf[:]))) != 0
    } else {
        return false
    }
}

platform_text_input_begin :: proc(initial_text: string, kind: Text_Input_Kind) {
    when PONG_ANDROID {
        buf: [192]u8
        n := min(len(initial_text), len(buf) - 1)
        if n > 0 {
            copy(buf[:n], transmute([]u8)initial_text[:n])
        }
        buf[n] = 0
        pong_android_begin_text_input(cstring(raw_data(buf[:])), i32(kind))
    }
}

platform_text_input_end :: proc() {
    when PONG_ANDROID {
        pong_android_end_text_input()
    }
}

platform_text_input_value :: proc(buf: []u8) -> string {
    when PONG_ANDROID {
        if len(buf) == 0 { return "" }
        n := int(pong_android_get_text_input(cast([^]u8)raw_data(buf), i32(len(buf))))
        if n < 0 { return "" }
        if n > len(buf) { n = len(buf) }
        return string(buf[:n])
    } else {
        return ""
    }
}

platform_window_back_pressed :: proc() -> bool {
    when PONG_ANDROID {
        return rl.IsKeyPressed(.ESCAPE)
    } else {
        return rl.IsKeyPressed(.ESCAPE)
    }
}
