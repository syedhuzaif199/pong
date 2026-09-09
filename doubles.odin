package main

import "core:fmt"
import rl "vendor:raylib"

team_root :: proc(n: ^Net_State) -> ^Net_State {
    if n.captain != nil { return n.captain }
    return n
}

team_connections :: proc(n: ^Net_State) -> [3]^Net_State {
    if n.squad == nil { return {n, nil, nil} }
    return {n, &n.squad[0], &n.squad[1]}
}

welcome_slot :: proc(n: ^Net_State, rules: Game_Rules) -> int {
    if !rules.doubles { return 2 }
    return n.assigned_slot
}

update_team_roster :: proc(n: ^Net_State) {
    if !n.doubles { return }
    copy_net_name(&n.roster_names[0], &n.roster_lengths[0], local_player_name(n))
    n.roster_connected[0] = true
    n.roster_ready[0] = n.local_ready
    for peer, i in team_connections(n) {
        if peer == nil { continue }
        copy_net_name(&n.roster_names[i+1], &n.roster_lengths[i+1], remote_player_name(peer))
        n.roster_connected[i+1] = peer.connected
        n.roster_ready[i+1] = peer.remote_ready
    }
}

send_team_roster :: proc(root, peer: ^Net_State) {
    if !root.doubles { return }
    for i in 0..<4 {
        buf: [160]u8
        text := fmt.bprintf(buf[:], "ROSTER|%d|%d|%d|%d|%s", peer.session_id, i,
            int(root.roster_connected[i]), int(root.roster_ready[i]),
            string(root.roster_names[i][:root.roster_lengths[i]]))
        _ = net_send_text(peer, text)
    }
}

receive_team_roster :: proc(n: ^Net_State, value: string) {
    rest := value
    slot, a := next_int(&rest)
    connected, b := next_int(&rest)
    ready, c := next_int(&rest)
    name, d := next_string(&rest)
    if !n.doubles || !a || !b || !c || !d || slot < 0 || slot > 3 { return }
    copy_net_name(&n.roster_names[slot], &n.roster_lengths[slot], name)
    n.roster_connected[slot] = connected != 0
    n.roster_ready[slot] = ready != 0
}

// Each guest has an independent transport, sequence space and session token.
// Three invitations reuse the deployed two-endpoint rendezvous protocol.
start_doubles_links :: proc(app: ^App, use_internet: bool, port: int = 0) -> bool {
    if !app.network_rules.doubles { return true }
    app.net.doubles = true
    app.net.assigned_slot = 1
    for i in 0..<2 {
        peer := &app.team_peers[i]
        ok := false
        if use_internet {
            ok = internet_begin_host(&app.team_internet[i], peer, text_field_string(&app.rendezvous_url), local_player_name(&app.net))
        } else {
            guest_port := port + i + 1
            if port == 0 { guest_port = 0 } // Ephemeral ports for offline protocol tests.
            ok = net_host(peer, guest_port, local_player_name(&app.net))
        }
        if !ok {
            for j in 0..<2 { internet_cancel(&app.team_internet[j], &app.team_peers[j]) }
            internet_cancel(&app.internet, &app.net)
            app.online_status = .Error
            app.status_message = "Could not open all three guest connections. Check the ports and try again."
            return false
        }
        peer.doubles = true
        peer.assigned_slot = i + 2
        peer.captain = &app.net
        peer.internet_pending = use_internet
    }
    app.net.squad = &app.team_peers
    return true
}

update_doubles_links :: proc(app: ^App) {
    if app.net.squad == nil {
        for i in 0..<2 {
            if app.team_internet[i].phase != .Idle { internet_cancel(&app.team_internet[i], &app.team_peers[i]) }
        }
        return
    }
    if app.internet.phase == .Error {
        app.status_message = "The first guest invite failed. Leave and create a new doubles match."
    }
    for i in 0..<2 {
        peer := &app.team_peers[i]
        s := &app.team_internet[i]
        if peer.internet_pending { internet_update(s, peer) }
        if s.phase == .Ready { peer.internet_pending = false }
        if !peer.internet_pending && peer.socket_open {
            _, _ = net_receive_host(peer, app.network_rules, &app.game)
            if peer.peer_left { app.net.peer_left = true }
        }
        if s.phase == .Error {
            app.status_message = "A guest invite failed. Cancel and create a new doubles match."
        }
    }
}

draw_doubles_lobby :: proc(app: ^App) {
    n := &app.net
    if n.role == .Host { update_team_roster(n) }
    draw_text_centered("DOUBLES / 2 V 2", 28, 38, FG)
    draw_text_centered("Cyan: P1 + P2    /    Coral: P3 + P4", 78, 17, ACCENT)
    draw_text_centered("Each teammate covers one half of their side. All four players must be ready.", 105, 14, MUTED)
    for i in 0..<4 {
        y := f32(140 + i * 68)
        colour := ACCENT
        if i >= 2 { colour = CORAL }
        surface({76, y, 808, 58}, PANEL)
        slot_buf: [48]u8
        lane := "UPPER"
        if i % 2 == 1 { lane = "LOWER" }
        draw_text(fmt.bprintf(slot_buf[:], "P%d / %s", i + 1, lane), 92, int(y)+20, 16, colour)
        name := "Waiting for player..."
        if n.roster_connected[i] { name = string(n.roster_names[i][:n.roster_lengths[i]]) }
        draw_text_centered_in(name, {250, y+6, 264, 46}, 18, FG)
        status := "NOT READY"
        if n.roster_ready[i] { status = "READY" }
        if !n.roster_connected[i] { status = "OPEN SLOT" }
        draw_text(status, 726, int(y)+22, 14, colour)
        if n.role == .Host && i > 0 && !n.roster_connected[i] {
            s := &app.internet
            if i > 1 { s = &app.team_internet[i-2] }
            invite_buf: [64]u8
            invite := ""
            if app.connection_origin == .Internet_Host {
                invite = internet_room_code(s)
                if len(invite) == 0 { invite = internet_phase_label(s.phase) }
            } else {
                port, _ := parse_port_field(app)
                invite = fmt.bprintf(invite_buf[:], "PORT %d", port + i - 1)
            }
            if button(invite, {538, y+10, 162, 38}) { clipboard_set_text(invite) }
        }
    }
    if app.status_message != "" { draw_text_centered(app.status_message, 422, 13, DANGER) } else {
        if n.role == .Host { draw_text_centered("Send each guest their own invite above. Click an invite to copy it.", 422, 14, MUTED) } else {
            buf: [80]u8
            draw_text_centered(fmt.bprintf(buf[:], "You are P%d. Use W/S, arrows, or your controller.", n.assigned_slot + 1), 422, 14, MUTED)
        }
    }
    if n.role == .Host && app.connection_origin != .Internet_Host {
        address_buf: [128]u8
        draw_text_centered(fmt.bprintf(address_buf[:], "HOST IP: %s / use the guest port shown above", text_field_string(&app.doubles_address)), 444, 12, ACCENT)
    }
    ready_label := "READY UP"
    if n.local_ready { ready_label = "UNREADY" }
    if button(ready_label, {480, 466, 270, 48}, n.connected && !app.match_start_pending && !connection_interrupted(n)) {
        net_set_local_ready(n, !n.local_ready)
    }
    if button("LEAVE", {210, 466, 240, 48}) {
        cancel_match_start_fade(app)
        discovery_host_shutdown(&app.discovery_host)
        net_shutdown(n)
        internet_detach(&app.internet)
        app.online_status = .Idle
        app.screen = .Online
    }
}
