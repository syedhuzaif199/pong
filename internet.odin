package main

import "base:runtime"
import c "core:c/libc"
import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:strings"
import "core:thread"
import curl "vendor:curl"
import rl "vendor:raylib"

RENDEZVOUS_VERSION :: 1
RENDEZVOUS_DEFAULT_URL :: "https://pong-rendezvous.onrender.com"
RENDEZVOUS_CONTROL_INTERVAL :: f64(0.75)
RENDEZVOUS_HTTP_TIMEOUT_MS :: c.long(6000)
RENDEZVOUS_LEAVE_TIMEOUT_MS :: c.long(1500)
INTERNET_PUNCH_INTERVAL :: f64(0.10)
INTERNET_STUN_TIMEOUT :: f64(4.0)
INTERNET_ROOM_TIMEOUT :: f64(120.0)
INTERNET_PUNCH_TIMEOUT :: f64(10.0)

STUN_DEFAULT_HOST :: "stun.cloudflare.com"
STUN_DEFAULT_PORT :: 3478
STUN_SEND_INTERVAL :: f64(0.50)
STUN_MAGIC_COOKIE :: u32(0x2112a442)
STUN_BINDING_SUCCESS :: u16(0x0101)
STUN_XOR_MAPPED_ADDRESS :: u16(0x0020)

Internet_Mode :: enum {
    None,
    Host,
    Join,
}

Internet_Phase :: enum {
    Idle,
    Resolving,
    Stun,
    Creating,
    Waiting,
    Joining,
    Punching,
    Ready,
    Error,
}

internet_phase_label :: proc(phase: Internet_Phase) -> string {
    switch phase {
    case .Idle:      return "IDLE"
    case .Resolving: return "DNS"
    case .Stun:      return "STUN"
    case .Creating:  return "RENDEZVOUS"
    case .Waiting:   return "PEER DISCOVERY"
    case .Joining:   return "RENDEZVOUS"
    case .Punching:  return "UDP PUNCH"
    case .Ready:     return "CONNECTED"
    case .Error:     return "ERROR"
    }
    return "UNKNOWN"
}

internet_phase_step :: proc(phase: Internet_Phase) -> int {
    switch phase {
    case .Idle, .Error:       return 0
    case .Resolving:          return 1
    case .Stun:               return 2
    case .Creating, .Joining: return 3
    case .Waiting:            return 4
    case .Punching, .Ready:   return 5
    }
    return 0
}

Internet_HTTP_Buffer :: struct {
    bytes: [2048]u8,
    length: int,
    overflow: bool,
}

Internet_Async_Kind :: enum {
    None,
    Resolve_Stun,
    Create,
    Join,
    Wait,
}

Internet_Async_Job :: struct {
    kind: Internet_Async_Kind,

    base_url: [160]u8,
    base_url_length: int,
    path: [32]u8,
    path_length: int,
    payload: [768]u8,
    payload_length: int,
    timeout_ms: c.long,

    response: [2048]u8,
    response_length: int,
    resolved_endpoint: net.Endpoint,
    ok: bool,
}

Internet_State :: struct {
    mode: Internet_Mode,
    phase: Internet_Phase,

    rendezvous_url: [160]u8,
    rendezvous_url_length: int,

    stun_server: net.Endpoint,
    stun_server_valid: bool,
    stun_txid: [12]u8,
    public_endpoint: net.Endpoint,
    public_endpoint_valid: bool,

    request_nonce: u32,
    room_code: [8]u8,
    room_code_length: int,
    token: [32]u8,
    token_length: int,

    punch_nonce: u32,
    candidates: [3]net.Endpoint,
    candidate_count: int,

    peer_name: [32]u8,
    peer_name_length: int,

    started_time: f64,
    phase_started_time: f64,
    last_send_time: f64,

    status: [192]u8,
    status_length: int,

    // Desktop stores ^thread.Thread here; Android uses a non-nil sentinel while
    // a Java DNS/HTTPS job is in flight. Keeping this raw avoids pulling the
    // unsupported core:thread implementation into Android builds.
    worker: rawptr,
    async_job: Internet_Async_Job,
}

internet_http_ready: bool

internet_http_init :: proc() -> bool {
    when PONG_ANDROID {
        internet_http_ready = true
    } else {
        internet_http_ready = curl.global_init(curl.GLOBAL_ALL) == nil
    }
    return internet_http_ready
}

internet_http_shutdown :: proc() {
    when PONG_ANDROID {
        internet_http_ready = false
    } else {
        if internet_http_ready {
            curl.global_cleanup()
            internet_http_ready = false
        }
    }
}

internet_curl_write :: proc "c" (contents: [^]byte, size: int, nmemb: int, userp: rawptr) -> int {
    context = runtime.default_context()

    total := size * nmemb
    if total <= 0 { return 0 }

    output := cast(^Internet_HTTP_Buffer)userp
    available := len(output.bytes) - output.length
    if total > available {
        output.overflow = true
        return 0
    }

    copy(output.bytes[output.length:output.length + total], contents[:total])
    output.length += total
    return total
}

internet_wait_for_worker :: proc(s: ^Internet_State) {
    if s.worker == nil { return }

    when PONG_ANDROID {
        // Android's Bionic libc does not implement pthread cancellation, which
        // Odin core:thread currently expects. Android async work therefore lives
        // in NativeLoader.java. Abandoning increments a generation so a late
        // Java result cannot be applied to a new Internet_State operation.
        pong_android_async_abandon()
    } else {
        worker := cast(^thread.Thread)s.worker
        thread.join(worker)
        thread.destroy(worker)
    }
    s.worker = nil
}

internet_async_worker :: proc(data: rawptr) {
    // Desktop-only worker body. Android never starts this procedure.
    job := cast(^Internet_Async_Job)data
    if job == nil { return }

    #partial switch job.kind {
    case .Resolve_Stun:
        ep4, _, err := net.resolve(STUN_DEFAULT_HOST)
        if err == nil && ep4.address != nil {
            ep4.port = STUN_DEFAULT_PORT
            job.resolved_endpoint = ep4
            job.ok = true
        }

    case .Create, .Join, .Wait:
        base_url := string(job.base_url[:job.base_url_length])
        path := string(job.path[:job.path_length])
        payload := string(job.payload[:job.payload_length])
        count, ok := internet_http_post(base_url, path, payload, job.response[:], job.timeout_ms)
        job.response_length = count
        job.ok = ok

    case:
    }
}

internet_async_start_resolve :: proc(s: ^Internet_State) -> bool {
    if s.worker != nil { return false }
    s.async_job = Internet_Async_Job{kind = .Resolve_Stun}

    when PONG_ANDROID {
        host_c, err := strings.clone_to_cstring(STUN_DEFAULT_HOST, context.temp_allocator)
        if err != nil { return false }
        defer delete(host_c, context.temp_allocator)

        if pong_android_async_resolve_start(host_c) == 0 {
            s.async_job = Internet_Async_Job{}
            return false
        }
        // The actual worker is Java-owned. A pointer to our in-state job is just
        // a stable non-nil "busy" sentinel and is never dereferenced as a thread.
        s.worker = &s.async_job
    } else {
        worker := thread.create_and_start_with_data(&s.async_job, internet_async_worker)
        if worker == nil {
            s.async_job = Internet_Async_Job{}
            return false
        }
        s.worker = worker
    }
    return true
}

internet_async_start_http :: proc(
    s: ^Internet_State,
    kind: Internet_Async_Kind,
    path: string,
    payload: string,
    timeout_ms := RENDEZVOUS_HTTP_TIMEOUT_MS,
) -> bool {
    if s.worker != nil || kind == .None || kind == .Resolve_Stun { return false }

    job := &s.async_job
    job^ = Internet_Async_Job{kind = kind, timeout_ms = timeout_ms}
    internet_copy_text(job.base_url[:], &job.base_url_length, internet_rendezvous_url(s))
    internet_copy_text(job.path[:], &job.path_length, path)
    internet_copy_text(job.payload[:], &job.payload_length, payload)

    when PONG_ANDROID {
        base := internet_rendezvous_url(s)
        for len(base) > 0 && base[len(base) - 1] == '/' {
            base = base[:len(base) - 1]
        }

        url_buf: [512]u8
        url := fmt.bprintf(url_buf[:], "%s%s", base, path)
        url_c, url_err := strings.clone_to_cstring(url, context.temp_allocator)
        if url_err != nil {
            job^ = Internet_Async_Job{}
            return false
        }
        defer delete(url_c, context.temp_allocator)

        payload_c, payload_err := strings.clone_to_cstring(payload, context.temp_allocator)
        if payload_err != nil {
            job^ = Internet_Async_Job{}
            return false
        }
        defer delete(payload_c, context.temp_allocator)

        if pong_android_async_http_start(url_c, payload_c, i32(timeout_ms)) == 0 {
            job^ = Internet_Async_Job{}
            return false
        }
        s.worker = job
    } else {
        worker := thread.create_and_start_with_data(job, internet_async_worker)
        if worker == nil {
            job^ = Internet_Async_Job{}
            return false
        }
        s.worker = worker
    }
    return true
}

internet_async_poll :: proc(s: ^Internet_State, n: ^Net_State) {
    if s.worker == nil { return }

    when PONG_ANDROID {
        // Java states: 0 idle, 1 running, 2 success, 3 failed.
        state := pong_android_async_state()
        if state == 1 { return }

        if state == 2 {
            count := int(pong_android_async_take_result(
                cast([^]u8)raw_data(s.async_job.response[:]),
                i32(len(s.async_job.response)),
            ))
            if count > 0 && count <= len(s.async_job.response) {
                s.async_job.response_length = count
                if s.async_job.kind == .Resolve_Stun {
                    text := string(s.async_job.response[:count])
                    address := net.parse_address(text)
                    if address != nil {
                        s.async_job.resolved_endpoint = net.Endpoint{
                            address = address,
                            port = STUN_DEFAULT_PORT,
                        }
                        s.async_job.ok = true
                    }
                } else {
                    s.async_job.ok = true
                }
            }
        } else {
            // Also resets a failed/idle Java job. Safe if it was already idle.
            pong_android_async_abandon()
        }
        s.worker = nil
    } else {
        worker := cast(^thread.Thread)s.worker
        if !thread.is_done(worker) { return }
        thread.join(worker)
        thread.destroy(worker)
        s.worker = nil
    }

    kind := s.async_job.kind
    ok := s.async_job.ok

    if kind == .Resolve_Stun {
        if s.phase == .Resolving && ok {
            if endpoint, endpoint_ok := internet_endpoint_for_socket(n, s.async_job.resolved_endpoint); endpoint_ok {
                s.stun_server = endpoint
                s.stun_server_valid = true
                internet_new_stun_transaction(s)
                internet_phase_set(s, .Stun)
                internet_set_status(s, "Discovering your public UDP endpoint with Cloudflare STUN...")
            }
        }

        if s.phase == .Resolving {
            if s.mode == .Host {
                internet_phase_set(s, .Creating)
                internet_set_status(s, "Cloudflare STUN lookup unavailable; creating room with direct candidates...")
            } else {
                internet_phase_set(s, .Joining)
                internet_set_status(s, "Cloudflare STUN lookup unavailable; looking up room with direct candidates...")
            }
        }

        s.async_job = Internet_Async_Job{}
        return
    }

    previous_phase := s.phase
    if ok && s.async_job.response_length > 0 {
        packet := string(s.async_job.response[:s.async_job.response_length])
        internet_handle_rendezvous_response(s, n, packet)
    }

    // A valid RV_WAITING response intentionally stays in .Waiting; do not
    // mistake that for a failed/garbled HTTPS response merely because the
    // phase did not change.
    if !ok || (kind != .Wait && s.phase == previous_phase) {
        #partial switch kind {
        case .Create:
            if s.phase == .Creating { internet_set_status(s, "Rendezvous HTTPS request failed; retrying...") }
        case .Join:
            if s.phase == .Joining { internet_set_status(s, "Rendezvous HTTPS request failed; retrying...") }
        case .Wait:
            if s.phase == .Waiting { internet_set_status(s, "Rendezvous HTTPS poll failed; retrying...") }
        case:
        }
    }

    s.last_send_time = rl.GetTime()
    s.async_job = Internet_Async_Job{}
}

internet_status :: proc(s: ^Internet_State) -> string {
    return string(s.status[:s.status_length])
}

internet_room_code :: proc(s: ^Internet_State) -> string {
    return string(s.room_code[:s.room_code_length])
}

internet_token :: proc(s: ^Internet_State) -> string {
    return string(s.token[:s.token_length])
}

internet_rendezvous_url :: proc(s: ^Internet_State) -> string {
    return string(s.rendezvous_url[:s.rendezvous_url_length])
}

internet_peer_name :: proc(s: ^Internet_State) -> string {
    if s.peer_name_length == 0 { return "Opponent" }
    return string(s.peer_name[:s.peer_name_length])
}

internet_set_status :: proc(s: ^Internet_State, text: string) {
    n := min(len(text), len(s.status))
    if n > 0 { copy(s.status[:n], transmute([]u8)text[:n]) }
    s.status_length = n
}

internet_copy_text :: proc(dst: []u8, dst_len: ^int, text: string) {
    n := min(len(text), len(dst))
    if n > 0 { copy(dst[:n], transmute([]u8)text[:n]) }
    dst_len^ = n
}

internet_reset :: proc(s: ^Internet_State) {
    internet_wait_for_worker(s)
    s^ = Internet_State{}
}

internet_phase_set :: proc(s: ^Internet_State, phase: Internet_Phase) {
    s.phase = phase
    s.phase_started_time = rl.GetTime()
    s.last_send_time = -1000
}

internet_fail :: proc(s: ^Internet_State, text: string) {
    internet_set_status(s, text)
    internet_phase_set(s, .Error)
}

internet_valid_rendezvous_url :: proc(url: string) -> bool {
    if len(url) < 8 || len(url) > 159 { return false }
    if !(strings.has_prefix(url, "https://") || strings.has_prefix(url, "http://")) { return false }
    for ch in url {
        if ch <= ' ' || ch == '|' || ch == '\\' { return false }
    }
    return true
}

internet_http_post :: proc(
    base_url: string,
    path: string,
    payload: string,
    output: []u8,
    timeout_ms := RENDEZVOUS_HTTP_TIMEOUT_MS,
) -> (response_length: int, ok: bool) {
    if !internet_http_ready || len(output) == 0 || !internet_valid_rendezvous_url(base_url) { return }

    base := base_url
    for len(base) > 0 && base[len(base) - 1] == '/' {
        base = base[:len(base) - 1]
    }

    url_buf: [512]u8
    url := fmt.bprintf(url_buf[:], "%s%s", base, path)
    url_c, url_err := strings.clone_to_cstring(url, context.temp_allocator)
    if url_err != nil { return }
    defer delete(url_c, context.temp_allocator)

    payload_c, payload_err := strings.clone_to_cstring(payload, context.temp_allocator)
    if payload_err != nil { return }
    defer delete(payload_c, context.temp_allocator)

    when PONG_ANDROID {
        count := int(pong_android_http_post(
            url_c,
            payload_c,
            cast([^]u8)raw_data(output),
            i32(len(output)),
            i32(timeout_ms),
        ))
        if count <= 0 || count > len(output) { return }
        return count, true
    } else {
        handle := curl.easy_init()
        if handle == nil { return }
        defer curl.easy_cleanup(handle)

        response := Internet_HTTP_Buffer{}

        _ = curl.easy_setopt(handle, .URL, url_c)
        _ = curl.easy_setopt(handle, .POST, c.long(1))
        _ = curl.easy_setopt(handle, .POSTFIELDS, payload_c)
        _ = curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(payload)))
        _ = curl.easy_setopt(handle, .WRITEFUNCTION, internet_curl_write)
        _ = curl.easy_setopt(handle, .WRITEDATA, &response)
        _ = curl.easy_setopt(handle, .USERAGENT, cstring("UDP-Pong/1.4.0"))
        _ = curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1))
        _ = curl.easy_setopt(handle, .POSTREDIR, c.long(curl.REDIR_POST_ALL))
        _ = curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, min(timeout_ms, c.long(4000)))
        _ = curl.easy_setopt(handle, .TIMEOUT_MS, timeout_ms)
        _ = curl.easy_setopt(handle, .NOSIGNAL, c.long(1))

        result := curl.easy_perform(handle)
        if result != nil || response.overflow || response.length <= 0 { return }

        status: c.long
        if curl.easy_getinfo(handle, .RESPONSE_CODE, &status) != nil || status < 200 || status >= 300 {
            return
        }

        response_length = min(response.length, len(output))
        copy(output[:response_length], response.bytes[:response_length])
        ok = true
        return
    }
}

internet_ipv4_to_mapped_ipv6 :: proc(ip4: net.IP4_Address) -> net.IP6_Address {
    bytes: [16]u8
    bytes[10] = 0xff
    bytes[11] = 0xff
    bytes[12] = ip4[0]
    bytes[13] = ip4[1]
    bytes[14] = ip4[2]
    bytes[15] = ip4[3]
    return transmute(net.IP6_Address)bytes
}

internet_endpoint_for_socket :: proc(n: ^Net_State, ep: net.Endpoint) -> (net.Endpoint, bool) {
    #partial switch address in ep.address {
    case net.IP4_Address:
        if n.accepts_ipv6 {
            return net.Endpoint{address = internet_ipv4_to_mapped_ipv6(address), port = ep.port}, true
        }
        return ep, true
    case net.IP6_Address:
        if n.accepts_ipv6 { return ep, true }
        return net.Endpoint{}, false
    case:
        return net.Endpoint{}, false
    }
}

internet_open_gameplay_socket :: proc(n: ^Net_State, role: Net_Role, player_name: string) -> bool {
    net_shutdown(n, false)

    socket, create_err := net.make_unbound_udp_socket(.IP6)
    dual_stack_ok := false
    if create_err == nil {
        if set_udp_dual_stack(socket) {
            if net.bind(socket, net.Endpoint{address = net.IP6_Any, port = 0}) == nil {
                dual_stack_ok = true
            }
        }
        if !dual_stack_ok { net.close(socket) }
    }

    if dual_stack_ok {
        n.accepts_ipv4 = true
        n.accepts_ipv6 = true
    } else {
        ipv4_socket, ipv4_err := net.make_bound_udp_socket(net.IP4_Any, 0)
        if ipv4_err != nil { return false }
        socket = ipv4_socket
        n.accepts_ipv4 = true
        n.accepts_ipv6 = false
    }

    if net.set_blocking(socket, false) != nil {
        net.close(socket)
        return false
    }

    n.role = role
    n.socket = socket
    n.socket_open = true
    n.transport = .Unknown
    copy_net_name(&n.local_name, &n.local_name_length, player_name)
    now := rl.GetTime()
    n.last_recv_time = now
    n.last_ping_time = -1000

    #partial switch role {
    case .Host:
        n.session_id = new_random_id()
        n.session_valid = true
    case .Client:
        n.hello_nonce = new_random_id()
        n.session_valid = false
    case:
    }
    return true
}

internet_resolve_stun_server :: proc(n: ^Net_State) -> (net.Endpoint, bool) {
    ep4, _, err := net.resolve(STUN_DEFAULT_HOST)
    if err != nil || ep4.address == nil { return net.Endpoint{}, false }
    ep4.port = STUN_DEFAULT_PORT
    return internet_endpoint_for_socket(n, ep4)
}

internet_bound_port :: proc(n: ^Net_State) -> int {
    ep, err := net.bound_endpoint(n.socket)
    if err != nil { return 0 }
    return ep.port
}

internet_local_ipv6 :: proc(n: ^Net_State, buf: []u8) -> string {
    if !n.accepts_ipv6 || len(buf) == 0 { return "-" }
    address, address_len, ok := find_advertisable_ipv6()
    if !ok || address_len <= 0 { return "-" }

    // `find_advertisable_ipv6` returns its text in an array by value. Do not
    // return a string view into that local array: the view would dangle after
    // this procedure returns. Copy it into storage owned by the caller instead.
    count := min(address_len, len(buf))
    copy(buf[:count], address[:count])
    return string(buf[:count])
}

internet_local_ipv4 :: proc() -> string {
    address, ok := find_preferred_discovery_ip4()
    if !ok { return "-" }
    return net.address_to_string(address)
}

internet_begin_common :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    mode: Internet_Mode,
    rendezvous_url: string,
    player_name: string,
) -> bool {
    internet_reset(s)

    if !internet_http_ready {
        internet_fail(s, "HTTP support could not initialize (libcurl unavailable).")
        return false
    }
    if !internet_valid_rendezvous_url(rendezvous_url) {
        internet_fail(s, "Rendezvous URL must start with http:// or https://.")
        return false
    }

    role: Net_Role = .Client
    if mode == .Host { role = .Host }
    if !internet_open_gameplay_socket(n, role, player_name) {
        internet_fail(s, "Could not create the Internet gameplay UDP socket.")
        return false
    }

    s.mode = mode
    internet_copy_text(s.rendezvous_url[:], &s.rendezvous_url_length, rendezvous_url)
    s.request_nonce = new_random_id()
    s.started_time = rl.GetTime()

    internet_phase_set(s, .Resolving)
    internet_set_status(s, "Resolving Cloudflare STUN without blocking the game loop...")
    if !internet_async_start_resolve(s) {
        if mode == .Host {
            internet_phase_set(s, .Creating)
            internet_set_status(s, "Could not start STUN lookup; creating room with direct candidates...")
        } else {
            internet_phase_set(s, .Joining)
            internet_set_status(s, "Could not start STUN lookup; looking up room with direct candidates...")
        }
    }
    return true
}

internet_begin_host :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    rendezvous_url: string,
    player_name: string,
) -> bool {
    return internet_begin_common(s, n, .Host, rendezvous_url, player_name)
}

internet_normalize_code :: proc(input: string, dst: ^[8]u8, dst_len: ^int) -> bool {
    dst_len^ = 0
    for ch in input {
        c := ch
        if c == '-' || c == ' ' { continue }
        if c >= 'a' && c <= 'z' { c = c - ('a' - 'A') }
        allowed_letter := (c >= 'A' && c <= 'Z') && c != 'I' && c != 'O'
        allowed := allowed_letter || (c >= '2' && c <= '9')
        if !allowed || dst_len^ >= 6 { return false }
        dst^[dst_len^] = u8(c)
        dst_len^ += 1
    }
    return dst_len^ == 6
}

internet_begin_join :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    rendezvous_url: string,
    code: string,
    player_name: string,
) -> bool {
    normalized: [8]u8
    normalized_len: int
    if !internet_normalize_code(code, &normalized, &normalized_len) {
        internet_reset(s)
        internet_fail(s, "Room codes contain six letters/digits.")
        return false
    }

    if !internet_begin_common(s, n, .Join, rendezvous_url, player_name) {
        return false
    }
    s.room_code = normalized
    s.room_code_length = normalized_len
    return true
}

internet_cancel :: proc(s: ^Internet_State, n: ^Net_State) {
    // Do not block the render/audio thread on a best-effort HTTP leave request.
    // Rendezvous rooms have short TTLs and are cleaned up server-side.
    net_shutdown(n, false)
    internet_reset(s)
}

internet_detach :: proc(s: ^Internet_State) {
    // The gameplay socket belongs to Net_State and stays open. The rendezvous
    // room expires server-side; avoiding a synchronous leave keeps transitions smooth.
    internet_reset(s)
}

internet_new_stun_transaction :: proc(s: ^Internet_State) {
    for word_index in 0..<3 {
        value := rand.uint32()
        base := word_index * 4
        s.stun_txid[base + 0] = u8(value >> 24)
        s.stun_txid[base + 1] = u8(value >> 16)
        s.stun_txid[base + 2] = u8(value >> 8)
        s.stun_txid[base + 3] = u8(value)
    }
}

write_u16_be :: proc(buf: []u8, offset: int, value: u16) {
    buf[offset] = u8(value >> 8)
    buf[offset + 1] = u8(value)
}

write_u32_be :: proc(buf: []u8, offset: int, value: u32) {
    buf[offset] = u8(value >> 24)
    buf[offset + 1] = u8(value >> 16)
    buf[offset + 2] = u8(value >> 8)
    buf[offset + 3] = u8(value)
}

read_u16_be :: proc(buf: []u8, offset: int) -> u16 {
    return u16(buf[offset]) << 8 | u16(buf[offset + 1])
}

read_u32_be :: proc(buf: []u8, offset: int) -> u32 {
    return u32(buf[offset]) << 24 |
           u32(buf[offset + 1]) << 16 |
           u32(buf[offset + 2]) << 8 |
           u32(buf[offset + 3])
}

internet_send_stun :: proc(s: ^Internet_State, n: ^Net_State) {
    if !s.stun_server_valid { return }
    request: [20]u8
    write_u16_be(request[:], 0, 0x0001)
    write_u16_be(request[:], 2, 0)
    write_u32_be(request[:], 4, STUN_MAGIC_COOKIE)
    copy(request[8:20], s.stun_txid[:])
    _, _ = net.send_udp(n.socket, request[:], s.stun_server)
}

internet_parse_stun_response :: proc(
    s: ^Internet_State,
    packet: []u8,
) -> (endpoint: net.Endpoint, ok: bool) {
    if len(packet) < 20 { return }
    if read_u16_be(packet, 0) != STUN_BINDING_SUCCESS { return }
    message_len := int(read_u16_be(packet, 2))
    if read_u32_be(packet, 4) != STUN_MAGIC_COOKIE || 20 + message_len > len(packet) { return }

    transaction_matches := true
    for i in 0..<len(s.stun_txid) {
        if packet[8 + i] != s.stun_txid[i] {
            transaction_matches = false
            break
        }
    }
    if !transaction_matches { return }

    offset := 20
    end := 20 + message_len
    for offset + 4 <= end {
        attr_type := read_u16_be(packet, offset)
        attr_len := int(read_u16_be(packet, offset + 2))
        value := offset + 4
        if value + attr_len > end { return }

        if attr_type == STUN_XOR_MAPPED_ADDRESS && attr_len >= 8 {
            family := packet[value + 1]
            xor_port := read_u16_be(packet, value + 2)
            port := int(xor_port ~ u16(STUN_MAGIC_COOKIE >> 16))

            if family == 0x01 && attr_len >= 8 {
                cookie := [4]u8{0x21, 0x12, 0xa4, 0x42}
                address := net.IP4_Address{
                    packet[value + 4] ~ cookie[0],
                    packet[value + 5] ~ cookie[1],
                    packet[value + 6] ~ cookie[2],
                    packet[value + 7] ~ cookie[3],
                }
                return net.Endpoint{address = address, port = port}, true
            }
        }

        padded_len := ((attr_len + 3) / 4) * 4
        offset = value + padded_len
    }
    return
}

internet_public_candidate :: proc(s: ^Internet_State) -> (string, int) {
    if !s.public_endpoint_valid { return "-", 0 }
    return net.address_to_string(s.public_endpoint.address), s.public_endpoint.port
}

internet_send_create :: proc(s: ^Internet_State, n: ^Net_State) -> bool {
    port := internet_bound_port(n)
    ipv6_buf: [64]u8
    ipv6 := internet_local_ipv6(n, ipv6_buf[:])
    local4 := internet_local_ipv4()
    public_ip, public_port := internet_public_candidate(s)
    ipv6_port := 0
    local4_port := 0
    if ipv6 != "-" { ipv6_port = port }
    if local4 != "-" { local4_port = port }
    name := local_player_name(n)
    payload_buf: [768]u8
    payload := fmt.bprintf(
        payload_buf[:],
        "RV_CREATE|%d|%d|%d|%s|%s|%d|%s|%d|%s|%d",
        RENDEZVOUS_VERSION,
        PROTOCOL_VERSION,
        s.request_nonce,
        name,
        public_ip,
        public_port,
        ipv6,
        ipv6_port,
        local4,
        local4_port,
    )
    _ = n
    return internet_async_start_http(s, .Create, "/v1/create", payload)
}

internet_send_wait :: proc(s: ^Internet_State, n: ^Net_State) -> bool {
    code := internet_room_code(s)
    token := internet_token(s)
    if len(code) == 0 || len(token) == 0 { return false }
    payload_buf: [192]u8
    payload := fmt.bprintf(payload_buf[:], "RV_WAIT|%d|%s|%s", RENDEZVOUS_VERSION, code, token)
    _ = n
    return internet_async_start_http(s, .Wait, "/v1/wait", payload)
}

internet_send_join :: proc(s: ^Internet_State, n: ^Net_State) -> bool {
    port := internet_bound_port(n)
    ipv6_buf: [64]u8
    ipv6 := internet_local_ipv6(n, ipv6_buf[:])
    local4 := internet_local_ipv4()
    public_ip, public_port := internet_public_candidate(s)
    ipv6_port := 0
    local4_port := 0
    if ipv6 != "-" { ipv6_port = port }
    if local4 != "-" { local4_port = port }
    code := internet_room_code(s)
    name := local_player_name(n)
    payload_buf: [768]u8
    payload := fmt.bprintf(
        payload_buf[:],
        "RV_JOIN|%d|%d|%d|%s|%s|%s|%d|%s|%d|%s|%d",
        RENDEZVOUS_VERSION,
        PROTOCOL_VERSION,
        s.request_nonce,
        code,
        name,
        public_ip,
        public_port,
        ipv6,
        ipv6_port,
        local4,
        local4_port,
    )
    _ = n
    return internet_async_start_http(s, .Join, "/v1/join", payload)
}

internet_send_leave :: proc(s: ^Internet_State, n: ^Net_State) {
    _ = n
    if s.rendezvous_url_length == 0 || s.room_code_length == 0 || s.token_length == 0 { return }
    payload_buf: [192]u8
    payload := fmt.bprintf(payload_buf[:], "RV_LEAVE|%d|%s|%s", RENDEZVOUS_VERSION, internet_room_code(s), internet_token(s))
    response: [256]u8
    _, _ = internet_http_post(internet_rendezvous_url(s), "/v1/leave", payload, response[:], RENDEZVOUS_LEAVE_TIMEOUT_MS)
}

internet_candidate_add :: proc(s: ^Internet_State, n: ^Net_State, text: string, port: int) {
    if len(text) == 0 || text == "-" || port < 1 || port > 65535 || s.candidate_count >= len(s.candidates) { return }
    address := net.parse_address(text)
    if address == nil { return }
    endpoint := net.Endpoint{address = address, port = port}
    endpoint_for_socket, ok := internet_endpoint_for_socket(n, endpoint)
    if !ok { return }
    for i in 0..<s.candidate_count {
        if s.candidates[i] == endpoint_for_socket { return }
    }
    s.candidates[s.candidate_count] = endpoint_for_socket
    s.candidate_count += 1
}

internet_set_candidates :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    public_ip: string,
    public_port: int,
    ipv6: string,
    ipv6_port: int,
    local4: string,
    local4_port: int,
) {
    s.candidate_count = 0
    // Priority order: native global IPv6, same-LAN IPv4, STUN/reflexive IPv4.
    internet_candidate_add(s, n, ipv6, ipv6_port)
    internet_candidate_add(s, n, local4, local4_port)
    internet_candidate_add(s, n, public_ip, public_port)
}

internet_send_punches :: proc(s: ^Internet_State, n: ^Net_State) {
    if s.candidate_count == 0 { return }
    code := internet_room_code(s)
    buf: [160]u8
    msg := fmt.bprintf(buf[:], "PUNCH|%d|%s|%d", RENDEZVOUS_VERSION, code, s.punch_nonce)
    for i in 0..<s.candidate_count {
        _, _ = net.send_udp(n.socket, transmute([]u8)msg, s.candidates[i])
    }
}

internet_send_punch_ack :: proc(s: ^Internet_State, n: ^Net_State, remote: net.Endpoint) {
    buf: [160]u8
    msg := fmt.bprintf(buf[:], "PUNCH_ACK|%d|%s|%d", RENDEZVOUS_VERSION, internet_room_code(s), s.punch_nonce)
    _, _ = net.send_udp(n.socket, transmute([]u8)msg, remote)
}

internet_adopt_peer :: proc(s: ^Internet_State, n: ^Net_State, remote: net.Endpoint) {
    n.peer = remote
    n.peer_known = true
    n.transport = transport_from_address(remote.address)
    now := rl.GetTime()
    n.last_recv_time = now
    if n.role == .Client {
        n.join_started_time = now
        n.last_hello_time = -1000
    }
    internet_phase_set(s, .Ready)
    transport := net_transport_name(n)
    buf: [128]u8
    internet_set_status(s, fmt.bprintf(buf[:], "Direct %s path established; completing Pong handshake...", transport))
}

internet_handle_punch_packet :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    packet: string,
    remote: net.Endpoint,
) {
    kind, rest, ok := packet_head(packet)
    if !ok || (kind != "PUNCH" && kind != "PUNCH_ACK") { return }

    version, v_ok := next_int(&rest)
    code, code_ok := next_string(&rest)
    nonce, nonce_ok := next_u32(&rest)
    if !v_ok || !code_ok || !nonce_ok || version != RENDEZVOUS_VERSION { return }
    if code != internet_room_code(s) || nonce != s.punch_nonce || s.phase != .Punching { return }
    if kind == "PUNCH" { internet_send_punch_ack(s, n, remote) }
    internet_adopt_peer(s, n, remote)
}

internet_handle_rendezvous_response :: proc(
    s: ^Internet_State,
    n: ^Net_State,
    packet: string,
) {
    kind, rest, ok := packet_head(packet)
    if !ok { return }

    if kind == "RV_CREATED" {
        version, v_ok := next_int(&rest)
        echoed_nonce, nonce_ok := next_u32(&rest)
        code, code_ok := next_string(&rest)
        token, token_ok := next_string(&rest)
        if !v_ok || !nonce_ok || !code_ok || !token_ok || version != RENDEZVOUS_VERSION || echoed_nonce != s.request_nonce { return }
        internet_copy_text(s.room_code[:], &s.room_code_length, code)
        internet_copy_text(s.token[:], &s.token_length, token)
        internet_phase_set(s, .Waiting)
        internet_set_status(s, "Room created. Share the code and wait for your opponent.")
        return
    }

    if kind == "RV_JOINED" {
        version, v_ok := next_int(&rest)
        echoed_nonce, nonce_ok := next_u32(&rest)
        code, code_ok := next_string(&rest)
        token, token_ok := next_string(&rest)
        if !v_ok || !nonce_ok || !code_ok || !token_ok || version != RENDEZVOUS_VERSION || echoed_nonce != s.request_nonce { return }
        if code != internet_room_code(s) { return }
        internet_copy_text(s.token[:], &s.token_length, token)
        internet_phase_set(s, .Waiting)
        internet_set_status(s, "Room joined. Waiting for peer candidates...")
        return
    }

    if kind == "RV_WAITING" {
        version, v_ok := next_int(&rest)
        code, code_ok := next_string(&rest)
        if !v_ok || !code_ok || version != RENDEZVOUS_VERSION || code != internet_room_code(s) { return }
        if s.mode == .Host {
            internet_set_status(s, "Room created. Share the code and wait for your opponent.")
        } else {
            internet_set_status(s, "Room joined. Waiting for host candidates...")
        }
        return
    }

    if kind == "RV_PEER" {
        version, v_ok := next_int(&rest)
        code, code_ok := next_string(&rest)
        token, token_ok := next_string(&rest)
        public_ip, pub_ok := next_string(&rest)
        public_port, pub_port_ok := next_int(&rest)
        ipv6, ipv6_ok := next_string(&rest)
        ipv6_port, ipv6_port_ok := next_int(&rest)
        local4, local4_ok := next_string(&rest)
        local4_port, local4_port_ok := next_int(&rest)
        peer_name, name_ok := next_string(&rest)
        punch_nonce, punch_ok := next_u32(&rest)
        if !(v_ok && code_ok && token_ok && pub_ok && pub_port_ok && ipv6_ok && ipv6_port_ok && local4_ok && local4_port_ok && name_ok && punch_ok) { return }
        if version != RENDEZVOUS_VERSION || code != internet_room_code(s) || token != internet_token(s) { return }

        internet_copy_text(s.peer_name[:], &s.peer_name_length, peer_name)
        s.punch_nonce = punch_nonce
        internet_set_candidates(s, n, public_ip, public_port, ipv6, ipv6_port, local4, local4_port)
        if s.candidate_count == 0 {
            internet_fail(s, "Rendezvous succeeded, but the peer provided no usable UDP candidates.")
            return
        }
        internet_phase_set(s, .Punching)
        internet_set_status(s, "Peer found. Trying IPv6/LAN/STUN UDP candidates...")
        return
    }

    if kind == "RV_ERROR" {
        version, v_ok := next_int(&rest)
        echoed_nonce, nonce_ok := next_u32(&rest)
        reason, reason_ok := next_string(&rest)
        if !v_ok || !nonce_ok || !reason_ok || version != RENDEZVOUS_VERSION { return }
        if echoed_nonce != 0 && echoed_nonce != s.request_nonce { return }

        switch reason {
        case "ROOM_NOT_FOUND": internet_fail(s, "Room code not found or it expired.")
        case "PROTOCOL_MISMATCH": internet_fail(s, "That room is using an incompatible gameplay protocol.")
        case "ROOM_FULL": internet_fail(s, "That room already has two players.")
        case "SERVER_FULL": internet_fail(s, "The rendezvous service is currently full.")
        case "BAD_TOKEN": internet_fail(s, "The rendezvous room token was rejected.")
        case "BAD_REQUEST": internet_fail(s, "The rendezvous service rejected an invalid request.")
        case: internet_fail(s, "The rendezvous service rejected the request.")
        }
        return
    }
}

internet_advance_after_stun :: proc(s: ^Internet_State) {
    if s.mode == .Host {
        internet_phase_set(s, .Creating)
        if s.public_endpoint_valid {
            internet_set_status(s, "Cloudflare STUN succeeded. Creating room over HTTPS...")
        } else {
            internet_set_status(s, "Cloudflare STUN timed out; creating room with direct candidates...")
        }
    } else {
        internet_phase_set(s, .Joining)
        if s.public_endpoint_valid {
            internet_set_status(s, "Cloudflare STUN succeeded. Looking up room over HTTPS...")
        } else {
            internet_set_status(s, "Cloudflare STUN timed out; looking up room with direct candidates...")
        }
    }
}

internet_receive_udp_control :: proc(s: ^Internet_State, n: ^Net_State) {
    for {
        buffer: [1024]u8
        count, remote, err := net.recv_udp(n.socket, buffer[:])
        if err == .Would_Block { break }
        if err != nil || count <= 0 { break }

        if s.phase == .Stun && s.stun_server_valid && remote == s.stun_server {
            if endpoint, ok := internet_parse_stun_response(s, buffer[:count]); ok {
                s.public_endpoint = endpoint
                s.public_endpoint_valid = true
                internet_advance_after_stun(s)
                continue
            }
        }

        if s.phase == .Punching {
            internet_handle_punch_packet(s, n, string(buffer[:count]), remote)
            if s.phase == .Ready || s.phase == .Error { break }
        }
    }
}

internet_update :: proc(s: ^Internet_State, n: ^Net_State) {
    if s.phase == .Idle || s.phase == .Ready || s.phase == .Error || !n.socket_open { return }

    // Complete DNS/HTTPS work only after its worker has finished. The worker never
    // mutates gameplay/network state; responses are applied here on the game thread.
    internet_async_poll(s, n)
    if s.phase == .Ready || s.phase == .Error { return }

    now := rl.GetTime()
    internet_receive_udp_control(s, n)
    if s.phase == .Ready || s.phase == .Error { return }

    #partial switch s.phase {
    case .Resolving:
        if now - s.started_time > INTERNET_ROOM_TIMEOUT {
            internet_fail(s, "Cloudflare STUN DNS lookup did not complete before the rendezvous timeout.")
            return
        }

    case .Stun:
        if now - s.last_send_time >= STUN_SEND_INTERVAL {
            internet_send_stun(s, n)
            s.last_send_time = now
        }
        if now - s.phase_started_time > INTERNET_STUN_TIMEOUT {
            internet_advance_after_stun(s)
            return
        }

    case .Creating:
        if s.worker == nil && now - s.last_send_time >= RENDEZVOUS_CONTROL_INTERVAL {
            if internet_send_create(s, n) {
                internet_set_status(s, "Creating room over HTTPS...")
            } else {
                internet_set_status(s, "Could not start rendezvous HTTPS request; retrying...")
            }
            s.last_send_time = now
        }
        if now - s.started_time > INTERNET_ROOM_TIMEOUT {
            internet_fail(s, "Could not create the room before the rendezvous timeout.")
            return
        }

    case .Joining:
        if s.worker == nil && now - s.last_send_time >= RENDEZVOUS_CONTROL_INTERVAL {
            if internet_send_join(s, n) {
                internet_set_status(s, "Looking up room over HTTPS...")
            } else {
                internet_set_status(s, "Could not start rendezvous HTTPS request; retrying...")
            }
            s.last_send_time = now
        }
        if now - s.started_time > INTERNET_ROOM_TIMEOUT {
            internet_fail(s, "Could not join the room before the rendezvous timeout.")
            return
        }

    case .Waiting:
        if s.worker == nil && now - s.last_send_time >= RENDEZVOUS_CONTROL_INTERVAL {
            if !internet_send_wait(s, n) {
                internet_set_status(s, "Could not start rendezvous HTTPS poll; retrying...")
            }
            s.last_send_time = now
        }
        if now - s.started_time > INTERNET_ROOM_TIMEOUT {
            internet_fail(s, "Room expired before peer discovery completed.")
            return
        }

    case .Punching:
        if now - s.last_send_time >= INTERNET_PUNCH_INTERVAL {
            internet_send_punches(s, n)
            s.last_send_time = now
        }
        if now - s.phase_started_time > INTERNET_PUNCH_TIMEOUT {
            internet_fail(s, "UDP hole punching failed. This NAT may require a relay/TURN path.")
            return
        }

    case:
    }
}

internet_public_endpoint_text :: proc(s: ^Internet_State, buf: []u8) -> string {
    if !s.public_endpoint_valid { return "" }
    address := net.address_to_string(s.public_endpoint.address)
    return fmt.bprintf(buf, "%s:%d", address, s.public_endpoint.port)
}
