package main

import "core:math"
import rl "vendor:raylib"

Particle :: struct {
    active: bool,
    x, y: f32,
    vx, vy: f32,
    life: f32,
    max_life: f32,
    colour: rl.Color,
}

Visual_FX :: struct {
    particles: [96]Particle,
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

    colour := ACCENT
    if !to_right { colour = CORAL }
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
            life = 0.36,
            max_life = 0.36,
            colour = colour,
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
        drag := math.pow(f32(0.08), dt)
        p.vx *= drag
        p.vy *= drag
    }
}

draw_ball_trail :: proc(g: ^Game_State) {
    speed_sq := g.ball_vx*g.ball_vx + g.ball_vy*g.ball_vy
    if speed_sq < 1 { return }
    colour := ACCENT
    if g.ball_vx < 0 { colour = CORAL }
    for i := 14; i > 0; i -= 1 {
        lag := f32(i) * 0.006
        x := g.ball_x - g.ball_vx * lag
        y := g.ball_y - g.ball_vy * lag
        alpha := u8(110 - i * 7)
        radius := BALL_RADIUS * (1.0 - f32(i) * 0.055)
        rl.DrawCircleV({x, y}, radius, ink(colour, alpha))
    }
}

draw_visual_fx :: proc(fx: ^Visual_FX) {
    if fx.score_flash > 0 {
        alpha := u8(math.clamp(fx.score_flash / 0.22 * 34.0, f32(0), f32(34)))
        if fx.score_side == 1 {
            rl.DrawRectangle(0, 0, WINDOW_W/2, WINDOW_H, ink(ACCENT, alpha))
        } else if fx.score_side == 2 {
            rl.DrawRectangle(WINDOW_W/2, 0, WINDOW_W/2, WINDOW_H, ink(CORAL, alpha))
        }
    }

    for &p in fx.particles {
        if !p.active { continue }
        alpha := u8(math.clamp(p.life / p.max_life * 210.0, f32(0), f32(210)))
        rl.DrawLineEx({p.x, p.y}, {p.x - p.vx * 0.026, p.y - p.vy * 0.026}, 2, ink(p.colour, alpha))
        rl.DrawCircleV({p.x, p.y}, 2.5 * p.life / p.max_life, ink(FG, alpha))
    }
}
