#+build windows

package main

import "core:testing"

@(test)
cpu_accurate_prediction :: proc(t: ^testing.T) {
    testing.expect_value(t, cpu_path_landing(100, 160, 400, 0), f32(160))
    for vy in ([6]f32{-1400, -700, -200, 200, 700, 1400}) {
        y := f32(120) + vy * (P2_X - BALL_RADIUS - 100) / 400
        for _ in 0..<20 {
            if y < BALL_RADIUS { y = BALL_RADIUS * 2 - y; continue }
            if y > FIELD_H - BALL_RADIUS { y = (FIELD_H - BALL_RADIUS) * 2 - y; continue }
            break
        }
        testing.expect(t, abs(cpu_path_landing(100, 120, 400, vy) - y) < 0.01)
    }
    g := Game_State{ball_x = 100, ball_y = 120, ball_vx = 400, ball_vy = 200, p2_y = 218}
    ai: CPU_AI
    _ = cpu_paddle_direction(&ai, &g, .Easy, 0.01)
    before := ai.target_y
    g.ball_x = P2_X - BALL_RADIUS
    g.ball_y = 400
    _ = cpu_paddle_direction(&ai, &g, .Easy, 0.01)
    testing.expect_value(t, ai.target_y, f32(400))
    testing.expect(t, ai.target_y != before)
    g.doubles = true
    g.ball_vx = -400
    _ = cpu_doubles_direction(&ai, &g, .Easy, 0.01, 3)
    testing.expect_value(t, ai.target_y, f32(405))
    g.serve_timer = 0.75
    testing.expect_value(t, cpu_paddle_direction(&ai, &g, .Easy, 0.01), f32(0))
}
