#+build windows

package main

import "core:testing"
import "core:net"
import rl "vendor:raylib"

@(test)
doubles_physics :: proc(t: ^testing.T) {
    rules := default_game_rules()
    rules.doubles = true
    g: Game_State
    begin_match_countdown(&g, true)
    testing.expect(t, g.p1_y < FIELD_H/2 && g.p3_y >= FIELD_H/2)
    g.countdown_timer = 0
    g.serve_timer = 1
    before := g
    step_host_game(&g, rules, -1, 1, 0.01, 1, -1)
    testing.expect(t, g.p1_y < before.p1_y && g.p3_y > before.p3_y)
    testing.expect(t, g.p2_y > before.p2_y && g.p4_y < before.p4_y)
    for slot in 0..<4 {
        move_player_paddle(&g, slot, -1, 900, 10)
        expected: f32 = 0
        if slot % 2 == 1 { expected = FIELD_H/2 }
        testing.expect_value(t, paddle_position(&g, slot)^, expected)
        move_player_paddle(&g, slot, 1, 900, 10)
        testing.expect_value(t, paddle_position(&g, slot)^, expected + FIELD_H/2 - PADDLE_H)
    }
    // Every paddle must return an incoming ball, including both lower teammates.
    for slot in 0..<4 {
        begin_match_countdown(&g, true)
        g.countdown_timer = 0
        g.serve_timer = 0
        g.ball_y = paddle_position(&g, slot)^ + PADDLE_H/2
        g.ball_vy = 0
        if slot < 2 { g.ball_x = P1_X + PADDLE_W + BALL_RADIUS + 2; g.ball_vx = -460 } else {
            g.ball_x = P2_X - BALL_RADIUS - 2; g.ball_vx = 460
        }
        step_host_game(&g, rules, 0, 0, 0.01)
        testing.expect_value(t, g.current_rally, 1)
        testing.expect(t, (slot < 2 && g.ball_vx > 0) || (slot >= 2 && g.ball_vx < 0))
    }
    // Team scoring, set transitions, and reset positions survive between games.
    rules.winning_score = 1
    rules.win_by_two = false
    g.score1 = 1
    finish_point(&g, 1, rules)
    testing.expect_value(t, g.games1, 1)
    step_host_game(&g, rules, 0, 0, 2)
    testing.expect(t, g.doubles && g.p3_y >= FIELD_H/2 && g.countdown_timer > 0)
    g.score1 = 1
    finish_point(&g, 1, rules)
    testing.expect(t, g.game_over && g.winner == 1)
    // Singles still has a full-height paddle range.
    reset_match(&g)
    move_player_paddle(&g, 0, 1, 900, 10)
    testing.expect_value(t, g.p1_y, FIELD_H - PADDLE_H)
}

// Actual loopback UDP sockets exercise per-guest handshake/session isolation,
// readiness, authoritative snapshots, rematches, and disconnection fan-out.
@(test)
doubles_udp_sessions :: proc(t: ^testing.T) {
    rl.SetConfigFlags({.WINDOW_HIDDEN})
    rl.InitWindow(64, 64, "Doubles protocol test")
    defer rl.CloseWindow()
    app := App{}
    app.network_rules = default_game_rules()
    app.network_rules.doubles = true
    root := &app.net
    if !testing.expect(t, net_host(root, 0, "Host")) { return }
    defer net_shutdown(root)
    if !testing.expect(t, start_doubles_links(&app, false)) { return }
    clients: [3]Net_State
    defer for &client in clients { net_shutdown(&client, false) }
    rules: [3]Game_Rules
    targets: [3]Game_State
    for peer, i in team_connections(root) {
        endpoint, err := net.bound_endpoint(peer.socket)
        if !testing.expect(t, err == nil) { return }
        if !testing.expect(t, net_join(&clients[i], "127.0.0.1", endpoint.port, "Guest")) { return }
        client_send_handshake_if_due(&clients[i])
    }
    for _ in 0..<10 {
        _, _ = net_receive_host(root, app.network_rules, &app.game)
        for &client, i in clients {
            _, _, _ = net_receive_client(&client, &rules[i], &targets[i])
            client.last_hello_time = -1000
            client_send_handshake_if_due(&client)
        }
    }
    testing.expect(t, root.connected && app.team_peers[0].connected && app.team_peers[1].connected)
    for client, i in clients {
        testing.expect(t, client.connected && rules[i].doubles)
        testing.expect_value(t, client.assigned_slot, i+1)
    }
    net_set_local_ready(root, true)
    net_set_local_ready(&clients[0], true)
    net_set_local_ready(&clients[1], true)
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect(t, !both_players_ready(root), "Three votes must not start a four-player match")
    net_set_local_ready(&clients[2], true)
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect(t, both_players_ready(root))
    for &client, i in clients {
        _, _, _ = net_receive_client(&client, &rules[i], &targets[i])
        testing.expect(t, both_players_ready(&client))
        for occupied in client.roster_connected { testing.expect(t, occupied) }
    }
    send_input(&clients[0], -1)
    send_input(&clients[1], 1)
    send_input(&clients[2], -1)
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect_value(t, root.remote_input, f32(-1))
    testing.expect_value(t, app.team_peers[0].remote_input, f32(1))
    testing.expect_value(t, app.team_peers[1].remote_input, f32(-1))
    // One guest cannot send input using another guest's session token.
    original_session := clients[1].session_id
    clients[1].session_id = root.session_id
    send_input(&clients[1], -1)
    clients[1].session_id = original_session
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect_value(t, app.team_peers[0].remote_input, f32(1))
    // A duplicate input sequence must not change authoritative input.
    clients[0].send_seq -= 1
    send_input(&clients[0], 1)
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect_value(t, root.remote_input, f32(-1))
    begin_match_countdown(&app.game, true)
    app.game.p3_y = 321
    app.game.p4_y = 400
    app.game.score1 = 6
    send_state(root, app.game)
    for &client, i in clients {
        _, _, state := net_receive_client(&client, &rules[i], &targets[i])
        testing.expect(t, state && targets[i].doubles)
        testing.expect_value(t, targets[i].p3_y, f32(321))
        testing.expect_value(t, targets[i].p4_y, f32(400))
        testing.expect_value(t, targets[i].score1, 6)
    }
    net_request_rematch(root)
    net_request_rematch(&clients[0])
    net_request_rematch(&clients[1])
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect(t, !both_players_want_rematch(root))
    net_request_rematch(&clients[2])
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect(t, both_players_want_rematch(root))
    for &client, i in clients {
        _, _, _ = net_receive_client(&client, &rules[i], &targets[i])
        testing.expect(t, both_players_want_rematch(&client))
    }
    app.team_peers[1].last_recv_time = rl.GetTime() - 11
    testing.expect(t, connection_interrupted(root) && connection_timed_out(root))
    net_shutdown(&clients[1])
    _, _ = net_receive_host(root, app.network_rules, &app.game)
    testing.expect(t, root.peer_left)
    net_shutdown(root, false)
    for i in ([2]int{0, 2}) {
        _, _, _ = net_receive_client(&clients[i], &rules[i], &targets[i])
        testing.expect(t, clients[i].peer_left, "Host shutdown must notify every remaining guest")
    }
    // Protocol 6 still supports ordinary one-client matches and assigns the right paddle.
    for &client in clients { net_shutdown(&client, false) }
    if !testing.expect(t, net_host(root, 0, "Singles host")) { return }
    endpoint, err := net.bound_endpoint(root.socket)
    if !testing.expect(t, err == nil && net_join(&clients[0], "127.0.0.1", endpoint.port, "Singles guest")) { return }
    singles := default_game_rules()
    for _ in 0..<10 {
        clients[0].last_hello_time = -1000
        client_send_handshake_if_due(&clients[0])
        _, _ = net_receive_host(root, singles, &app.game)
        _, _, _ = net_receive_client(&clients[0], &rules[0], &targets[0])
    }
    testing.expect(t, root.connected && clients[0].connected && !rules[0].doubles)
    testing.expect_value(t, clients[0].assigned_slot, 2)
    net_set_local_ready(root, true)
    net_set_local_ready(&clients[0], true)
    _, _ = net_receive_host(root, singles, &app.game)
    testing.expect(t, both_players_ready(root))
}
