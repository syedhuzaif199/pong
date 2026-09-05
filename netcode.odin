package main

import "core:fmt"
import "core:net"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

PROTOCOL_VERSION :: 4
HELLO_INTERVAL :: 0.50
STATE_INTERVAL :: 1.0 / 60.0
INPUT_INTERVAL :: 1.0 / 60.0
PING_INTERVAL :: 1.0
PING_RETRY_AFTER :: 2.0
JOIN_TIMEOUT :: 8.0
CONNECTION_TIMEOUT :: 5.0
CONTROL_INTERVAL :: 0.50
MAX_PLAYER_NAME :: 24

Net_Role :: enum {
    None,
    Host,
    Client,
}

Net_State :: struct {
    role:        Net_Role,
    socket:      net.UDP_Socket,
    socket_open: bool,

    peer:        net.Endpoint,
    peer_known:  bool,
    connected:   bool,
    welcomed:    bool,
    peer_left:   bool,
    protocol_mismatch: bool,
    remote_protocol_version: int,

    hello_nonce:   u32,
    session_id:    u32,
    session_valid: bool,

    local_name:        [32]u8,
    local_name_length: int,
    remote_name:       [32]u8,
    remote_name_length:int,

    local_ready:  bool,
    remote_ready: bool,
    local_rematch:  bool,
    remote_rematch: bool,

    last_recv_time: f64,
    last_stream_send_time: f64,
    last_hello_time: f64,
    join_started_time: f64,
    last_control_send_time: f64,

    send_seq: u32,
    recv_seq: u32,

    remote_input: f32,

    packets_sent: u64,
    packets_recv: u64,
    send_errors: u64,
    recv_errors: u64,

    stream_seq_valid: bool,
    last_stream_seq: u32,
    stream_packets_recv: u64,
    stream_packets_lost: u64,

    last_ping_time: f64,
    ping_sent_time: f64,
    ping_nonce: u32,
    ping_outstanding: bool,
    rtt_ms: f32,
    rtt_smoothed_ms: f32,
    rtt_valid: bool,
}

new_random_id :: proc() -> u32 {
    id := rand.uint32()
    if id == 0 { id = 1 }
    return id
}

copy_net_name :: proc(dst: ^[32]u8, dst_len: ^int, value: string) {
    n := len(value)
    if n > MAX_PLAYER_NAME { n = MAX_PLAYER_NAME }
    if n > len(dst^) { n = len(dst^) }
    if n > 0 { copy(dst^[:n], transmute([]u8)value[:n]) }
    dst_len^ = n
    if dst_len^ == 0 {
        fallback := "Player"
        copy(dst^[:len(fallback)], transmute([]u8)fallback)
        dst_len^ = len(fallback)
    }
}

local_player_name :: proc(n: ^Net_State) -> string {
    return string(n.local_name[:n.local_name_length])
}

remote_player_name :: proc(n: ^Net_State) -> string {
    if n.remote_name_length == 0 { return "Opponent" }
    return string(n.remote_name[:n.remote_name_length])
}

session_matches :: proc(n: ^Net_State, id: u32) -> bool {
    return n.session_valid && id == n.session_id
}

send_bye :: proc(n: ^Net_State) {
    if !n.session_valid { return }
    buf: [64]u8
    msg := fmt.bprintf(buf[:], "BYE|%d", n.session_id)
    _ = net_send_text(n, msg)
}

net_shutdown :: proc(n: ^Net_State, send_bye_packet := true) {
    if n.socket_open {
        if send_bye_packet && n.peer_known && n.session_valid { send_bye(n) }
        net.close(n.socket)
    }
    n^ = Net_State{}
}

net_host :: proc(n: ^Net_State, port: int, player_name: string) -> bool {
    net_shutdown(n, false)

    socket, err := net.make_bound_udp_socket(net.IP6_Any, port)
    if err != nil { return false }

    block_err := net.set_blocking(socket, false)
    if block_err != nil {
        net.close(socket)
        return false
    }

    n.role = .Host
    n.socket = socket
    n.socket_open = true
    n.session_id = new_random_id()
    n.session_valid = true
    copy_net_name(&n.local_name, &n.local_name_length, player_name)
    n.last_recv_time = rl.GetTime()
    n.last_ping_time = -1000
    return true
}

net_join :: proc(n: ^Net_State, address_text: string, port: int, player_name: string) -> bool {
    net_shutdown(n, false)

    ip, ok := net.parse_ip6_address(address_text)
    if !ok { return false }

    socket, err := net.make_unbound_udp_socket(.IP6)
    if err != nil { return false }

    block_err := net.set_blocking(socket, false)
    if block_err != nil {
        net.close(socket)
        return false
    }

    n.role = .Client
    n.socket = socket
    n.socket_open = true
    n.peer = net.Endpoint{address = ip, port = port}
    n.peer_known = true
    n.hello_nonce = new_random_id()
    copy_net_name(&n.local_name, &n.local_name_length, player_name)
    now := rl.GetTime()
    n.last_recv_time = now
    n.join_started_time = now
    n.last_hello_time = -1000
    n.last_ping_time = -1000
    return true
}

net_send_text :: proc(n: ^Net_State, text: string) -> bool {
    if !n.socket_open || !n.peer_known { return false }
    _, err := net.send_udp(n.socket, transmute([]u8)text, n.peer)
    if err != nil {
        n.send_errors += 1
        return false
    }
    n.packets_sent += 1
    return true
}

send_welcome :: proc(n: ^Net_State, hello_nonce: u32, rules: Game_Rules) {
    buf: [320]u8
    msg := fmt.bprintf(
        buf[:],
        "WELCOME|%d|%d|%d|%d|%.0f|%.0f|%s",
        PROTOCOL_VERSION,
        hello_nonce,
        n.session_id,
        rules.winning_score,
        rules.ball_speed,
        rules.paddle_speed,
        local_player_name(n),
    )
    _ = net_send_text(n, msg)
}

send_lobby_state :: proc(n: ^Net_State) {
    if n.role != .Host || !n.session_valid || !n.peer_known { return }
    host_ready: int = 0
    client_ready: int = 0
    if n.local_ready { host_ready = 1 }
    if n.remote_ready { client_ready = 1 }
    buf: [96]u8
    msg := fmt.bprintf(buf[:], "LOBBY_STATE|%d|%d|%d", n.session_id, host_ready, client_ready)
    _ = net_send_text(n, msg)
}

net_set_local_ready :: proc(n: ^Net_State, ready: bool) {
    if !n.connected || !n.session_valid { return }
    n.local_ready = ready
    if n.role == .Host {
        send_lobby_state(n)
    } else if n.role == .Client {
        ready_value: int = 0
        if ready { ready_value = 1 }
        buf: [96]u8
        msg := fmt.bprintf(buf[:], "LOBBY_READY|%d|%d", n.session_id, ready_value)
        _ = net_send_text(n, msg)
    }
    n.last_control_send_time = rl.GetTime()
}

net_send_lobby_if_due :: proc(n: ^Net_State) {
    if !n.connected || !n.session_valid { return }
    now := rl.GetTime()
    if now - n.last_control_send_time < CONTROL_INTERVAL { return }
    if n.role == .Host {
        send_lobby_state(n)
    } else if n.role == .Client {
        ready_value: int = 0
        if n.local_ready { ready_value = 1 }
        buf: [96]u8
        msg := fmt.bprintf(buf[:], "LOBBY_READY|%d|%d", n.session_id, ready_value)
        _ = net_send_text(n, msg)
    }
    n.last_control_send_time = now
}

both_players_ready :: proc(n: ^Net_State) -> bool {
    return n.local_ready && n.remote_ready
}

clear_ready_state :: proc(n: ^Net_State) {
    n.local_ready = false
    n.remote_ready = false
}

send_rematch_state :: proc(n: ^Net_State) {
    if n.role != .Host || !n.session_valid || !n.peer_known { return }
    host_wants: int = 0
    client_wants: int = 0
    if n.local_rematch { host_wants = 1 }
    if n.remote_rematch { client_wants = 1 }
    buf: [96]u8
    msg := fmt.bprintf(buf[:], "REMATCH_STATE|%d|%d|%d", n.session_id, host_wants, client_wants)
    _ = net_send_text(n, msg)
}

net_request_rematch :: proc(n: ^Net_State) {
    if !n.connected || !n.session_valid || n.local_rematch { return }
    n.local_rematch = true
    if n.role == .Host {
        send_rematch_state(n)
    } else if n.role == .Client {
        buf: [64]u8
        msg := fmt.bprintf(buf[:], "REMATCH|%d|1", n.session_id)
        _ = net_send_text(n, msg)
    }
    n.last_control_send_time = rl.GetTime()
}

net_send_rematch_if_due :: proc(n: ^Net_State) {
    if !n.connected || !n.session_valid { return }
    now := rl.GetTime()
    if now - n.last_control_send_time < CONTROL_INTERVAL { return }
    if n.role == .Host {
        send_rematch_state(n)
    } else if n.role == .Client {
        wanted: int = 0
        if n.local_rematch { wanted = 1 }
        buf: [64]u8
        msg := fmt.bprintf(buf[:], "REMATCH|%d|%d", n.session_id, wanted)
        _ = net_send_text(n, msg)
    }
    n.last_control_send_time = now
}

both_players_want_rematch :: proc(n: ^Net_State) -> bool {
    return n.local_rematch && n.remote_rematch
}

clear_rematch_state :: proc(n: ^Net_State) {
    n.local_rematch = false
    n.remote_rematch = false
}

send_input :: proc(n: ^Net_State, direction: f32) {
    if !n.session_valid { return }
    n.send_seq += 1
    dir: int = 0
    if direction < 0 { dir = -1 }
    if direction > 0 { dir = 1 }
    buf: [128]u8
    msg := fmt.bprintf(buf[:], "INPUT|%d|%d|%d", n.session_id, n.send_seq, dir)
    if net_send_text(n, msg) { n.last_stream_send_time = rl.GetTime() }
}

send_state :: proc(n: ^Net_State, g: Game_State) {
    if !n.session_valid { return }

    n.send_seq += 1
    over: int = 0
    if g.game_over { over = 1 }

    buf: [512]u8
    msg := fmt.bprintf(
        buf[:],
        "STATE|%d|%d|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%d|%d|%d|%d|%.3f|%.0f|%.3f|%.3f",
        n.session_id,
        n.send_seq,
        g.ball_x,
        g.ball_y,
        g.ball_vx,
        g.ball_vy,
        g.p1_y,
        g.p2_y,
        g.score1,
        g.score2,
        over,
        g.winner,
        g.serve_timer,
        g.serve_dir,
        g.countdown_timer,
        g.go_timer,
    )
    if net_send_text(n, msg) { n.last_stream_send_time = rl.GetTime() }
}

endpoints_equal :: proc(a, b: net.Endpoint) -> bool { return a == b }

record_stream_seq :: proc(n: ^Net_State, seq: u32) -> bool {
    if !n.stream_seq_valid {
        n.stream_seq_valid = true
        n.last_stream_seq = seq
        n.recv_seq = seq
        n.stream_packets_recv += 1
        return true
    }
    if seq <= n.last_stream_seq { return false }
    if seq > n.last_stream_seq + 1 {
        n.stream_packets_lost += u64(seq - n.last_stream_seq - 1)
    }
    n.last_stream_seq = seq
    n.recv_seq = seq
    n.stream_packets_recv += 1
    return true
}

send_pong :: proc(n: ^Net_State, nonce: u32) {
    if !n.session_valid { return }
    buf: [96]u8
    msg := fmt.bprintf(buf[:], "PONG|%d|%d", n.session_id, nonce)
    _ = net_send_text(n, msg)
}

record_pong :: proc(n: ^Net_State, nonce: u32) {
    if !n.ping_outstanding || nonce != n.ping_nonce { return }
    sample_ms := f32((rl.GetTime() - n.ping_sent_time) * 1000.0)
    n.rtt_ms = sample_ms
    if n.rtt_valid {
        n.rtt_smoothed_ms = n.rtt_smoothed_ms * 0.80 + sample_ms * 0.20
    } else {
        n.rtt_smoothed_ms = sample_ms
        n.rtt_valid = true
    }
    n.ping_outstanding = false
}

net_send_ping_if_due :: proc(n: ^Net_State) {
    if !n.connected || !n.peer_known { return }
    now := rl.GetTime()
    if n.ping_outstanding && now - n.ping_sent_time < PING_RETRY_AFTER { return }
    if now - n.last_ping_time < PING_INTERVAL { return }
    n.last_ping_time = now
    n.ping_nonce += 1
    buf: [96]u8
    msg := fmt.bprintf(buf[:], "PING|%d|%d", n.session_id, n.ping_nonce)
    if net_send_text(n, msg) {
        n.ping_sent_time = now
        n.ping_outstanding = true
    } else {
        n.ping_outstanding = false
    }
}

packet_loss_percent :: proc(n: ^Net_State) -> f32 {
    total := n.stream_packets_recv + n.stream_packets_lost
    if total == 0 { return 0 }
    return f32(n.stream_packets_lost) * 100.0 / f32(total)
}

join_timed_out :: proc(n: ^Net_State) -> bool {
    return n.role == .Client && !n.connected && rl.GetTime() - n.join_started_time > JOIN_TIMEOUT
}

seconds_since_last_recv :: proc(n: ^Net_State) -> f64 {
    if n.last_recv_time <= 0 { return 0 }
    return rl.GetTime() - n.last_recv_time
}

net_receive_host :: proc(n: ^Net_State, rules: Game_Rules, g: ^Game_State) -> (newly_connected: bool, got_packet: bool) {
    if !n.socket_open { return }

    for {
        buffer: [1024]u8
        count, remote, err := net.recv_udp(n.socket, buffer[:])
        if err == .Would_Block { break }
        if err != nil {
            n.recv_errors += 1
            break
        }
        if count <= 0 { break }

        packet := string(buffer[:count])
        kind, rest, ok := packet_head(packet)
        if !ok { continue }

        if kind == "HELLO" {
            version, version_ok := next_int(&rest)
            hello_nonce, nonce_ok := next_u32(&rest)
            client_name, name_ok := next_string(&rest)
            if version_ok && nonce_ok && version != PROTOCOL_VERSION {
                mismatch_buf: [96]u8
                mismatch := fmt.bprintf(mismatch_buf[:], "VERSION_MISMATCH|%d|%d", PROTOCOL_VERSION, hello_nonce)
                _, _ = net.send_udp(n.socket, transmute([]u8)mismatch, remote)
                continue
            }
            if !version_ok || !nonce_ok || !name_ok || version != PROTOCOL_VERSION { continue }

            if !n.peer_known {
                n.peer = remote
                n.peer_known = true
                n.connected = false
                n.remote_input = 0
                copy_net_name(&n.remote_name, &n.remote_name_length, client_name)
            }

            if endpoints_equal(remote, n.peer) {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                send_welcome(n, hello_nonce, rules)
            }
            continue
        }

        if !n.peer_known || !endpoints_equal(remote, n.peer) { continue }

        if kind == "READY" {
            version, version_ok := next_int(&rest)
            packet_session, session_ok := next_u32(&rest)
            if !version_ok || !session_ok || version != PROTOCOL_VERSION || !session_matches(n, packet_session) { continue }

            n.packets_recv += 1
            n.last_recv_time = rl.GetTime()
            got_packet = true
            if !n.connected {
                n.connected = true
                n.remote_input = 0
                n.local_ready = false
                n.remote_ready = false
                n.local_rematch = false
                n.remote_rematch = false
                newly_connected = true
            }
            send_lobby_state(n)
            continue
        }

        packet_session, session_ok := next_u32(&rest)
        if !session_ok || !session_matches(n, packet_session) { continue }

        if kind == "INPUT" {
            seq, seq_ok := next_u32(&rest)
            direction, dir_ok := next_int(&rest)
            if seq_ok && dir_ok && record_stream_seq(n, seq) {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                if direction < 0 { n.remote_input = -1 } else if direction > 0 { n.remote_input = 1 } else { n.remote_input = 0 }
            }
        } else if kind == "LOBBY_READY" {
            ready_value, ready_ok := next_int(&rest)
            if ready_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                n.remote_ready = ready_value != 0
                send_lobby_state(n)
            }
        } else if kind == "PING" {
            nonce, nonce_ok := next_u32(&rest)
            if nonce_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                send_pong(n, nonce)
            }
        } else if kind == "PONG" {
            nonce, nonce_ok := next_u32(&rest)
            if nonce_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                record_pong(n, nonce)
            }
        } else if kind == "REMATCH" {
            wanted, wanted_ok := next_int(&rest)
            if wanted_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                got_packet = true
                n.remote_rematch = wanted != 0
                send_rematch_state(n)
            }
        } else if kind == "BYE" {
            n.packets_recv += 1
            n.last_recv_time = rl.GetTime()
            got_packet = true
            n.peer_left = true
            n.connected = false
            n.remote_input = 0
        }
    }
    return
}

net_receive_client :: proc(n: ^Net_State, rules: ^Game_Rules, target: ^Game_State) -> (welcomed: bool, got_lobby: bool, got_state: bool) {
    if !n.socket_open { return }

    for {
        buffer: [1024]u8
        count, remote, err := net.recv_udp(n.socket, buffer[:])
        if err == .Would_Block { break }
        if err != nil {
            n.recv_errors += 1
            break
        }
        if count <= 0 { break }

        packet := string(buffer[:count])
        kind, rest, ok := packet_head(packet)
        if !ok { continue }

        if kind == "VERSION_MISMATCH" {
            remote_version, version_ok := next_int(&rest)
            echoed_nonce, nonce_ok := next_u32(&rest)
            if version_ok && nonce_ok && echoed_nonce == n.hello_nonce {
                n.protocol_mismatch = true
                n.remote_protocol_version = remote_version
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
            }
            continue
        }

        if kind == "WELCOME" {
            if n.welcomed {
                if !endpoints_equal(remote, n.peer) { continue }
            } else if remote.port != n.peer.port {
                continue
            }

            version, v_ok := next_int(&rest)
            echoed_nonce, nonce_ok := next_u32(&rest)
            session_id, session_ok := next_u32(&rest)
            win, win_ok := next_int(&rest)
            ball, ball_ok := next_f32(&rest)
            paddle, paddle_ok := next_f32(&rest)
            host_name, name_ok := next_string(&rest)
            if v_ok && nonce_ok && session_ok && win_ok && ball_ok && paddle_ok && name_ok &&
               version == PROTOCOL_VERSION && echoed_nonce == n.hello_nonce && session_id != 0 {
                if n.session_valid && session_id != n.session_id { continue }
                n.peer = remote
                n.peer_known = true
                n.welcomed = true
                n.session_id = session_id
                n.session_valid = true
                copy_net_name(&n.remote_name, &n.remote_name_length, host_name)
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                rules.winning_score = win
                rules.ball_speed = ball
                rules.paddle_speed = paddle
                welcomed = true
            }
            continue
        }

        if !n.welcomed || !endpoints_equal(remote, n.peer) || !n.session_valid { continue }

        packet_session, session_ok := next_u32(&rest)
        if !session_ok || !session_matches(n, packet_session) { continue }

        if kind == "LOBBY_STATE" {
            host_ready, h_ok := next_int(&rest)
            client_ready, c_ok := next_int(&rest)
            if h_ok && c_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                n.connected = true
                n.remote_ready = host_ready != 0
                n.local_ready = client_ready != 0
                got_lobby = true
            }
        } else if kind == "STATE" {
            state, seq, state_ok := parse_state(rest)
            if state_ok && record_stream_seq(n, seq) {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                target^ = state
                n.connected = true
                got_state = true
            }
        } else if kind == "PING" {
            nonce, nonce_ok := next_u32(&rest)
            if nonce_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                send_pong(n, nonce)
            }
        } else if kind == "PONG" {
            nonce, nonce_ok := next_u32(&rest)
            if nonce_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                record_pong(n, nonce)
            }
        } else if kind == "REMATCH_STATE" {
            host_wants, h_ok := next_int(&rest)
            client_wants, c_ok := next_int(&rest)
            if h_ok && c_ok {
                n.packets_recv += 1
                n.last_recv_time = rl.GetTime()
                n.remote_rematch = host_wants != 0
                n.local_rematch = client_wants != 0
            }
        } else if kind == "BYE" {
            n.packets_recv += 1
            n.last_recv_time = rl.GetTime()
            n.peer_left = true
            n.connected = false
        }
    }
    return
}

client_send_handshake_if_due :: proc(n: ^Net_State) {
    now := rl.GetTime()
    if now - n.last_hello_time < HELLO_INTERVAL { return }

    buf: [160]u8
    if n.welcomed && n.session_valid {
        msg := fmt.bprintf(buf[:], "READY|%d|%d", PROTOCOL_VERSION, n.session_id)
        _ = net_send_text(n, msg)
    } else {
        msg := fmt.bprintf(buf[:], "HELLO|%d|%d|%s", PROTOCOL_VERSION, n.hello_nonce, local_player_name(n))
        _ = net_send_text(n, msg)
    }
    n.last_hello_time = now
}

client_send_input_if_due :: proc(n: ^Net_State, direction: f32) {
    now := rl.GetTime()
    if now - n.last_stream_send_time >= INPUT_INTERVAL { send_input(n, direction) }
}

host_send_state_if_due :: proc(n: ^Net_State, g: Game_State) {
    if !n.connected || !n.peer_known { return }
    now := rl.GetTime()
    if now - n.last_stream_send_time >= STATE_INTERVAL { send_state(n, g) }
}

connection_timed_out :: proc(n: ^Net_State) -> bool {
    return n.connected && rl.GetTime() - n.last_recv_time > CONNECTION_TIMEOUT
}

packet_head :: proc(packet: string) -> (kind, rest: string, ok: bool) {
    rest = packet
    kind, ok = strings.split_iterator(&rest, "|")
    return
}

next_string :: proc(rest: ^string) -> (string, bool) {
    field, ok := strings.split_iterator(rest, "|")
    return field, ok
}

next_int :: proc(rest: ^string) -> (int, bool) {
    field, ok := strings.split_iterator(rest, "|")
    if !ok { return 0, false }
    return strconv.parse_int(field)
}

next_u32 :: proc(rest: ^string) -> (u32, bool) {
    value, ok := next_int(rest)
    if !ok || value < 0 { return 0, false }
    return u32(value), true
}

next_f32 :: proc(rest: ^string) -> (f32, bool) {
    field, ok := strings.split_iterator(rest, "|")
    if !ok { return 0, false }
    return strconv.parse_f32(field)
}

parse_state :: proc(rest_value: string) -> (Game_State, u32, bool) {
    rest := rest_value
    seq, ok0 := next_u32(&rest)
    bx, ok1 := next_f32(&rest)
    by, ok2 := next_f32(&rest)
    bvx, ok3 := next_f32(&rest)
    bvy, ok4 := next_f32(&rest)
    p1y, ok5 := next_f32(&rest)
    p2y, ok6 := next_f32(&rest)
    s1, ok7 := next_int(&rest)
    s2, ok8 := next_int(&rest)
    over, ok9 := next_int(&rest)
    winner, ok10 := next_int(&rest)
    serve_timer, ok11 := next_f32(&rest)
    serve_dir, ok12 := next_f32(&rest)
    countdown_timer, ok13 := next_f32(&rest)
    go_timer, ok14 := next_f32(&rest)

    if !(ok0 && ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7 && ok8 && ok9 && ok10 && ok11 && ok12 && ok13 && ok14) {
        return Game_State{}, 0, false
    }

    return Game_State{
        ball_x = bx,
        ball_y = by,
        ball_vx = bvx,
        ball_vy = bvy,
        p1_y = p1y,
        p2_y = p2y,
        score1 = s1,
        score2 = s2,
        game_over = over != 0,
        winner = winner,
        serve_timer = serve_timer,
        serve_dir = serve_dir,
        countdown_timer = countdown_timer,
        go_timer = go_timer,
    }, seq, true
}
