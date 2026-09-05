package main

import "core:math"
import rl "vendor:raylib"

Particle :: struct {
    active: bool,
    x, y: f32,
    vx, vy: f32,
    life: f32,
    max_life: f32,
}

Visual_FX :: struct {
    particles: [48]Particle,
    p1_flash: f32,
    p2_flash: f32,
    score_flash: f32,
    score_side: int,
}

spawn_hit_particles :: proc(fx: ^Visual_FX, x, y: f32, to_right: bool) {
    dirs := [8][2]f32{
        [2]f32{1.00, 0.00}, [2]f32{0.72, 0.70}, [2]f32{0.72, -0.70},
        [2]f32{0.25, 0.97}, [2]f32{0.25, -0.97}, [2]f32{0.90, 0.34},
        [2]f32{0.90, -0.34}, [2]f32{0.50, 0.00},
    }
    sign: f32 = 1
    if !to_right { sign = -1 }

    spawned := 0
    for &p in fx.particles {
        if p.active { continue }
        d := dirs[spawned % len(dirs)]
        speed := f32(105 + spawned * 13)
        p = Particle{
            active = true,
            x = x,
            y = y,
            vx = d[0] * speed * sign,
            vy = d[1] * speed,
            life = 0.22,
            max_life = 0.22,
        }
        spawned += 1
        if spawned >= len(dirs) { break }
    }
}

update_visual_fx :: proc(fx: ^Visual_FX, dt: f32) {
    fx.p1_flash = max(f32(0), fx.p1_flash - dt)
    fx.p2_flash = max(f32(0), fx.p2_flash - dt)
    fx.score_flash = max(f32(0), fx.score_flash - dt)

    for &p in fx.particles {
        if !p.active { continue }
        p.life -= dt
        if p.life <= 0 {
            p.active = false
            continue
        }
        p.x += p.vx * dt
        p.y += p.vy * dt
        p.vx *= 0.96
        p.vy *= 0.96
    }
}

draw_ball_trail :: proc(g: ^Game_State) {
    speed_sq := g.ball_vx*g.ball_vx + g.ball_vy*g.ball_vy
    if speed_sq < 1 { return }
    for i in 1..<6 {
        lag := f32(i) * 0.012
        x := g.ball_x - g.ball_vx * lag
        y := g.ball_y - g.ball_vy * lag
        alpha := u8(56 - i * 8)
        radius := BALL_RADIUS * (1.0 - f32(i) * 0.08)
        rl.DrawCircleV([2]f32{x, y}, radius, rl.Color{ACCENT.r, ACCENT.g, ACCENT.b, alpha})
    }
}

draw_visual_fx :: proc(fx: ^Visual_FX) {
    if fx.score_flash > 0 {
        alpha := u8(math.clamp(fx.score_flash / 0.22 * 34.0, f32(0), f32(34)))
        if fx.score_side == 1 {
            rl.DrawRectangle(0, 0, WINDOW_W/2, WINDOW_H, rl.Color{GOOD.r, GOOD.g, GOOD.b, alpha})
        } else if fx.score_side == 2 {
            rl.DrawRectangle(WINDOW_W/2, 0, WINDOW_W/2, WINDOW_H, rl.Color{GOOD.r, GOOD.g, GOOD.b, alpha})
        }
    }

    for &p in fx.particles {
        if !p.active { continue }
        alpha := u8(math.clamp(p.life / p.max_life * 210.0, f32(0), f32(210)))
        rl.DrawCircleV([2]f32{p.x, p.y}, 3.0, rl.Color{ACCENT.r, ACCENT.g, ACCENT.b, alpha})
    }
}
