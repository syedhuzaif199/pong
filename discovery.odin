package main

import "core:fmt"
import "core:net"
import "core:os"
import rl "vendor:raylib"

DISCOVERY_VERSION :: 1
DISCOVERY_PORT :: 37776
DISCOVERY_QUERY_INTERVAL :: 1.0
DISCOVERY_ENTRY_TTL :: 3.5
MAX_DISCOVERED_GAMES :: 8

Discovered_Game :: struct {
    host_name: [32]u8,
    host_name_length: int,
    ipv6: [64]u8,
    ipv6_length: int,
    ipv4: [32]u8,
    ipv4_length: int,
    game_port: int,
    game_protocol: int,
    last_seen: f64,
    ping_ms: f32,
}

Discovery_Host :: struct {
    socket: net.UDP_Socket,
    socket_open: bool,
    game_port: int,
    host_name: [32]u8,
    host_name_length: int,
    ipv6: [64]u8,
    ipv6_length: int,
    ipv4: [32]u8,
    ipv4_length: int,
}

Discovery_Client :: struct {
    socket: net.UDP_Socket,
    socket_open: bool,
    attempted_start: bool,
    last_query_time: f64,
    query_sent_time: f64,
    query_nonce: u32,
    local_ipv4: [32]u8,
    local_ipv4_length: int,
    games: [MAX_DISCOVERED_GAMES]Discovered_Game,
    game_count: int,
}

copy_discovery_name :: proc(dst: ^[32]u8, dst_len: ^int, value: string) {
    n := min(len(value), len(dst^))
    if n > 0 { copy(dst^[:n], transmute([]u8)value[:n]) }
    dst_len^ = n
}

copy_discovery_ipv6 :: proc(dst: ^[64]u8, dst_len: ^int, value: string) {
    n := min(len(value), len(dst^))
    if n > 0 { copy(dst^[:n], transmute([]u8)value[:n]) }
    dst_len^ = n
}

copy_discovery_ipv4 :: proc(dst: ^[32]u8, dst_len: ^int, value: string) {
    n := min(len(value), len(dst^))
    if n > 0 { copy(dst^[:n], transmute([]u8)value[:n]) }
    dst_len^ = n
}

discovered_game_name :: proc(game: ^Discovered_Game) -> string {
    if game.host_name_length <= 0 { return "Host" }
    return string(game.host_name[:game.host_name_length])
}

discovered_game_ipv6 :: proc(game: ^Discovered_Game) -> string {
    return string(game.ipv6[:game.ipv6_length])
}

discovered_game_ipv4 :: proc(game: ^Discovered_Game) -> string {
    return string(game.ipv4[:game.ipv4_length])
}

discovery_host_ipv6 :: proc(d: ^Discovery_Host) -> string {
    return string(d.ipv6[:d.ipv6_length])
}

discovery_host_ipv4 :: proc(d: ^Discovery_Host) -> string {
    return string(d.ipv4[:d.ipv4_length])
}

is_advertisable_ip6 :: proc(addr: net.IP6_Address) -> bool {
    if addr == net.IP6_Any || addr == net.IP6_Loopback { return false }

    bytes := transmute([16]u8)addr
    // An IPv4-mapped IPv6 value is not a native IPv6 candidate. Windows can
    // expose these through interface enumeration; advertising one as IPv6 makes
    // the rendezvous server (correctly) reject its address family.
    ipv4_mapped := true
    for i in 0..<10 {
        if bytes[i] != 0 {
            ipv4_mapped = false
            break
        }
    }
    if ipv4_mapped && bytes[10] == 0xff && bytes[11] == 0xff { return false }

    // Link-local addresses require an interface scope id, which core:net.Endpoint
    // does not currently carry. Do not advertise those.
    if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
    if bytes[0] == 0xff { return false } // multicast
    return true
}

hex_nibble :: proc(c: u8) -> (value: u8, ok: bool) {
    switch c {
    case '0'..='9': return c - '0', true
    case 'a'..='f': return c - 'a' + 10, true
    case 'A'..='F': return c - 'A' + 10, true
    }
    return 0, false
}

linux_proc_ipv6_field :: proc(line: []u8, wanted: int) -> []u8 {
    i := 0
    field_index := 0
    for i < len(line) {
        for i < len(line) && (line[i] == ' ' || line[i] == '\t') { i += 1 }
        if i >= len(line) { break }

        start := i
        for i < len(line) && line[i] != ' ' && line[i] != '\t' { i += 1 }
        if field_index == wanted { return line[start:i] }
        field_index += 1
    }
    return nil
}

linux_proc_ipv6_flags :: proc(line: []u8) -> (flags: u32, ok: bool) {
    field := linux_proc_ipv6_field(line, 4)
    if len(field) == 0 { return }

    value: u32 = 0
    for c in field {
        nibble, valid := hex_nibble(c)
        if !valid { return }
        value = value*16 + u32(nibble)
    }
    return value, true
}

linux_proc_ipv6_is_global :: proc(line: []u8) -> bool {
    scope := linux_proc_ipv6_field(line, 3)
    return len(scope) == 2 && scope[0] == '0' && scope[1] == '0'
}

copy_linux_proc_ipv6 :: proc(dst: ^[64]u8, hex_address: []u8) -> (n: int, ok: bool) {
    if len(hex_address) < 32 { return }

    out := 0
    for i in 0..<32 {
        _, valid := hex_nibble(hex_address[i])
        if !valid { return 0, false }
        if i > 0 && i % 4 == 0 {
            dst[out] = ':'
            out += 1
        }
        dst[out] = hex_address[i]
        out += 1
    }
    return out, true
}

find_advertisable_ipv6_linux :: proc() -> (result: [64]u8, result_len: int, ok: bool) {
    // Odin's core:net.enumerate_interfaces() is currently a stub on Linux,
    // so read the kernel's IPv6 interface table directly instead.
    data, err := os.read_entire_file("/proc/net/if_inet6", context.temp_allocator)
    if err != nil { return }

    // Prefer a stable/non-temporary global address. If the system only has a
    // privacy/temporary global address, keep the first one as a fallback.
    fallback: [64]u8
    fallback_len := 0

    line_start := 0
    for line_start < len(data) {
        line_end := line_start
        for line_end < len(data) && data[line_end] != '\n' { line_end += 1 }
        line := data[line_start:line_end]

        if linux_proc_ipv6_is_global(line) {
            candidate: [64]u8
            address_field := linux_proc_ipv6_field(line, 0)
            candidate_len, candidate_ok := copy_linux_proc_ipv6(&candidate, address_field)
            if candidate_ok {
                flags, flags_ok := linux_proc_ipv6_flags(line)
                is_temporary := flags_ok && (flags & 0x01) != 0

                if !is_temporary {
                    result = candidate
                    result_len = candidate_len
                    ok = true
                    return
                }

                if fallback_len == 0 {
                    fallback = candidate
                    fallback_len = candidate_len
                }
            }
        }

        line_start = line_end + 1
    }

    if fallback_len > 0 {
        result = fallback
        result_len = fallback_len
        ok = true
    }
    return
}

find_advertisable_ipv6 :: proc() -> (result: [64]u8, result_len: int, ok: bool) {
    when ODIN_OS == .Linux {
        return find_advertisable_ipv6_linux()
    } else {
        interfaces, err := net.enumerate_interfaces()
        if err != nil { return }
        defer net.destroy_interfaces(interfaces)

        // Prefer ordinary Ethernet/Wi-Fi style interfaces before tunnel/VPN
        // interfaces. Fall back to any interface if needed.
        for pass in 0..<2 {
            for iface in interfaces {
                if pass == 0 && iface.tunnel_type != .None { continue }
                for lease in iface.unicast {
                    #partial switch address in lease.address {
                    case net.IP6_Address:
                        if !is_advertisable_ip6(address) { continue }
                        text := net.address_to_string(address)
                        result_len = min(len(text), len(result))
                        if result_len > 0 {
                            copy(result[:result_len], transmute([]u8)text[:result_len])
                            ok = true
                            return
                        }
                    case:
                    }
                }
            }
        }
        return
    }
}

discovery_host_start :: proc(
    d: ^Discovery_Host,
    game_port: int,
    player_name: string,
    gameplay_supports_ipv6: bool,
) -> bool {
    discovery_host_shutdown(d)

    // Discovery itself is IPv4 and must remain useful on IPv4-only LANs.
    // IPv6 is optional metadata used as the preferred gameplay endpoint.
    if gameplay_supports_ipv6 {
        if ipv6, ipv6_len, have_ipv6 := find_advertisable_ipv6(); have_ipv6 {
            d.ipv6 = ipv6
            d.ipv6_length = ipv6_len
        }
    }

    if local_ipv4, have_ipv4 := find_preferred_discovery_ip4(); have_ipv4 {
        ipv4_text := net.address_to_string(local_ipv4)
        copy_discovery_ipv4(&d.ipv4, &d.ipv4_length, ipv4_text)
    }

    // Keep any usable invite endpoint even if opening the discovery socket
    // fails, so COPY INVITE can still work.
    d.game_port = game_port
    copy_discovery_name(&d.host_name, &d.host_name_length, player_name)

    socket, err := net.make_bound_udp_socket(net.IP4_Any, DISCOVERY_PORT)
    if err != nil { return false }

    block_err := net.set_blocking(socket, false)
    if block_err != nil {
        net.close(socket)
        return false
    }

    d.socket = socket
    d.socket_open = true
    return true
}

discovery_host_shutdown :: proc(d: ^Discovery_Host) {
    if d.socket_open { net.close(d.socket) }
    d^ = Discovery_Host{}
}

discovery_host_update :: proc(d: ^Discovery_Host) {
    if !d.socket_open { return }

    for {
        buffer: [512]u8
        count, remote, err := net.recv_udp(d.socket, buffer[:])
        if err == .Would_Block { break }
        if err != nil || count <= 0 { break }

        packet := string(buffer[:count])
        kind, rest, ok := packet_head(packet)
        if !ok || kind != "PONG_DISCOVER" { continue }

        discovery_version, dv_ok := next_int(&rest)
        nonce, nonce_ok := next_u32(&rest)
        client_game_protocol, gp_ok := next_int(&rest)
        _ = client_game_protocol
        if !dv_ok || !nonce_ok || !gp_ok || discovery_version != DISCOVERY_VERSION { continue }

        name := string(d.host_name[:d.host_name_length])
        ipv6 := discovery_host_ipv6(d)
        if len(ipv6) == 0 { ipv6 = "-" }
        reply_buf: [384]u8
        reply := fmt.bprintf(
            reply_buf[:],
            "PONG_GAME|%d|%d|%d|%s|%d|%s",
            DISCOVERY_VERSION,
            nonce,
            PROTOCOL_VERSION,
            name,
            d.game_port,
            ipv6,
        )
        _, _ = net.send_udp(d.socket, transmute([]u8)reply, remote)
    }
}

is_usable_discovery_ip4 :: proc(addr: net.IP4_Address) -> bool {
    if addr == net.IP4_Any { return false }
    if addr[0] == 127 { return false }
    if addr[0] >= 224 { return false }
    return true
}

copy_discovery_local_ip4 :: proc(d: ^Discovery_Client, addr: net.IP4_Address) {
    text := net.address_to_string(addr)
    d.local_ipv4_length = min(len(text), len(d.local_ipv4))
    if d.local_ipv4_length > 0 {
        copy(d.local_ipv4[:d.local_ipv4_length], transmute([]u8)text[:d.local_ipv4_length])
    }
}

// Windows may route a limited broadcast (255.255.255.255) through a virtual
// adapter when the UDP socket is unbound (WSL/Hyper-V/VPN adapters are common).
// Pick an active, non-tunnel IPv4 interface with a gateway and bind the
// discovery socket to that address. This pins the broadcast to the physical
// LAN interface without needing subnet-mask/prefix information.
find_preferred_discovery_ip4 :: proc() -> (result: net.IP4_Address, ok: bool) {
    when ODIN_OS == .Linux {
        return find_preferred_discovery_ip4_linux()
    } else {
        interfaces, err := net.enumerate_interfaces()
        if err != nil { return }
        defer net.destroy_interfaces(interfaces)

        for pass in 0..<3 {
            for iface in interfaces {
                if !(.Up in iface.link.state) { continue }
                if pass < 2 && iface.tunnel_type != .None { continue }

                has_ip4_gateway := false
                for gateway in iface.gateways {
                    #partial switch g in gateway {
                    case net.IP4_Address:
                        if is_usable_discovery_ip4(g) {
                            has_ip4_gateway = true
                            break
                        }
                    case:
                    }
                }
                if pass == 0 && !has_ip4_gateway { continue }

                for lease in iface.unicast {
                    #partial switch address in lease.address {
                    case net.IP4_Address:
                        if !is_usable_discovery_ip4(address) { continue }
                        return address, true
                    case:
                    }
                }
            }
        }
        return
    }
}

discovery_client_start :: proc(d: ^Discovery_Client) -> bool {
    discovery_client_shutdown(d)
    d.attempted_start = true

    socket: net.UDP_Socket
    socket_ok := false

    local_ip4, have_local_ip4 := find_preferred_discovery_ip4()
    if have_local_ip4 {
        copy_discovery_local_ip4(d, local_ip4)
    }

    when ODIN_OS == .Windows {
        if have_local_ip4 {
            bound_socket, bind_err := net.make_bound_udp_socket(local_ip4, 0)
            if bind_err == nil {
                socket = bound_socket
                socket_ok = true
            }
        }
    }

    // Fallback for Linux/macOS, or if Windows interface enumeration/binding
    // fails. Discovery remains best-effort.
    if !socket_ok {
        unbound_socket, err := net.make_unbound_udp_socket(.IP4)
        if err != nil { return false }
        socket = unbound_socket
        socket_ok = true
    }

    if net.set_option(socket, .Broadcast, true) != nil {
        net.close(socket)
        return false
    }

    if net.set_blocking(socket, false) != nil {
        net.close(socket)
        return false
    }

    d.socket = socket
    d.socket_open = true
    d.last_query_time = -1000
    return true
}

discovery_client_shutdown :: proc(d: ^Discovery_Client) {
    if d.socket_open { net.close(d.socket) }
    d^ = Discovery_Client{}
}

discovery_client_refresh :: proc(d: ^Discovery_Client) {
    if !d.socket_open { return }
    d.last_query_time = -1000
}

discovery_send_query_if_due :: proc(d: ^Discovery_Client) {
    if !d.socket_open { return }
    now := rl.GetTime()
    if now - d.last_query_time < DISCOVERY_QUERY_INTERVAL { return }

    d.query_nonce += 1
    if d.query_nonce == 0 { d.query_nonce = 1 }

    buf: [96]u8
    msg := fmt.bprintf(buf[:], "PONG_DISCOVER|%d|%d|%d", DISCOVERY_VERSION, d.query_nonce, PROTOCOL_VERSION)
    broadcast := net.Endpoint{address = net.IP4_Address{255, 255, 255, 255}, port = DISCOVERY_PORT}
    _, err := net.send_udp(d.socket, transmute([]u8)msg, broadcast)
    if err == nil {
        d.query_sent_time = now
        d.last_query_time = now
    }
}

find_discovered_game :: proc(d: ^Discovery_Client, ipv4: string, port: int) -> int {
    for i in 0..<d.game_count {
        game := &d.games[i]
        if game.game_port == port && discovered_game_ipv4(game) == ipv4 { return i }
    }
    return -1
}

oldest_discovered_game :: proc(d: ^Discovery_Client) -> int {
    if d.game_count <= 0 { return 0 }
    oldest := 0
    for i in 1..<d.game_count {
        if d.games[i].last_seen < d.games[oldest].last_seen { oldest = i }
    }
    return oldest
}

record_discovered_game :: proc(
    d: ^Discovery_Client,
    nonce: u32,
    game_protocol: int,
    host_name: string,
    game_port: int,
    advertised_ipv6: string,
    remote: net.Endpoint,
) {
    if game_port < 1 || game_port > 65535 { return }

    ipv4_text := ""
    #partial switch address in remote.address {
    case net.IP4_Address:
        if !is_usable_discovery_ip4(address) { return }
        ipv4_text = net.address_to_string(address)
    case:
        return
    }

    ipv6_text := ""
    if advertised_ipv6 != "-" {
        if _, ok := net.parse_ip6_address(advertised_ipv6); ok {
            ipv6_text = advertised_ipv6
        }
    }

    index := find_discovered_game(d, ipv4_text, game_port)
    if index < 0 {
        if d.game_count < MAX_DISCOVERED_GAMES {
            index = d.game_count
            d.game_count += 1
        } else {
            index = oldest_discovered_game(d)
        }
    }

    game := &d.games[index]
    copy_discovery_name(&game.host_name, &game.host_name_length, host_name)
    copy_discovery_ipv4(&game.ipv4, &game.ipv4_length, ipv4_text)
    copy_discovery_ipv6(&game.ipv6, &game.ipv6_length, ipv6_text)
    game.game_port = game_port
    game.game_protocol = game_protocol
    game.last_seen = rl.GetTime()
    if nonce == d.query_nonce && d.query_sent_time > 0 {
        game.ping_ms = f32((rl.GetTime() - d.query_sent_time) * 1000.0)
    }
}

prune_discovered_games :: proc(d: ^Discovery_Client) {
    now := rl.GetTime()
    i := 0
    for i < d.game_count {
        if now - d.games[i].last_seen <= DISCOVERY_ENTRY_TTL {
            i += 1
            continue
        }
        d.game_count -= 1
        if i != d.game_count { d.games[i] = d.games[d.game_count] }
        d.games[d.game_count] = Discovered_Game{}
    }
}

discovery_client_update :: proc(d: ^Discovery_Client) {
    if !d.socket_open { return }

    discovery_send_query_if_due(d)

    for {
        buffer: [512]u8
        count, remote, err := net.recv_udp(d.socket, buffer[:])
        if err == .Would_Block { break }
        if err != nil || count <= 0 { break }

        packet := string(buffer[:count])
        kind, rest, ok := packet_head(packet)
        if !ok || kind != "PONG_GAME" { continue }

        discovery_version, dv_ok := next_int(&rest)
        nonce, nonce_ok := next_u32(&rest)
        game_protocol, gp_ok := next_int(&rest)
        host_name, name_ok := next_string(&rest)
        game_port, port_ok := next_int(&rest)
        ipv6, ipv6_ok := next_string(&rest)
        if !dv_ok || !nonce_ok || !gp_ok || !name_ok || !port_ok || !ipv6_ok { continue }
        if discovery_version != DISCOVERY_VERSION { continue }

        record_discovered_game(d, nonce, game_protocol, host_name, game_port, ipv6, remote)
    }

    prune_discovered_games(d)
}
