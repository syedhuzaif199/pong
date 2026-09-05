package main

import rl "vendor:raylib"

Audio_System :: struct {
    paddle_hit: rl.Sound,
    wall_hit:   rl.Sound,
    score:      rl.Sound,
    countdown:  rl.Sound,
    go:         rl.Sound,
    menu_click: rl.Sound,
    win:        rl.Sound,
    lose:       rl.Sound,
    ready:      bool,
}

audio_load_sfx :: proc(audio: ^Audio_System) {
    audio.paddle_hit = rl.LoadSound("assets/paddle_hit.wav")
    audio.wall_hit   = rl.LoadSound("assets/wall_hit.wav")
    audio.score      = rl.LoadSound("assets/score.wav")
    audio.countdown  = rl.LoadSound("assets/countdown.wav")
    audio.go         = rl.LoadSound("assets/go.wav")
    audio.menu_click = rl.LoadSound("assets/menu_click.wav")
    audio.win        = rl.LoadSound("assets/win.wav")
    audio.lose       = rl.LoadSound("assets/lose.wav")

    audio.ready = true
}

audio_unload_sfx :: proc(audio: ^Audio_System) {
    if rl.IsSoundValid(audio.paddle_hit) { rl.UnloadSound(audio.paddle_hit) }
    if rl.IsSoundValid(audio.wall_hit)   { rl.UnloadSound(audio.wall_hit) }
    if rl.IsSoundValid(audio.score)      { rl.UnloadSound(audio.score) }
    if rl.IsSoundValid(audio.countdown)  { rl.UnloadSound(audio.countdown) }
    if rl.IsSoundValid(audio.go)         { rl.UnloadSound(audio.go) }
    if rl.IsSoundValid(audio.menu_click) { rl.UnloadSound(audio.menu_click) }
    if rl.IsSoundValid(audio.win)        { rl.UnloadSound(audio.win) }
    if rl.IsSoundValid(audio.lose)       { rl.UnloadSound(audio.lose) }
    audio^ = Audio_System{}
}

sfx_volume :: proc(settings: App_Settings) -> f32 {
    if settings.sfx_muted { return 0 }
    return f32(settings.sfx_volume) / 100.0
}

play_sfx :: proc(audio: ^Audio_System, sound: rl.Sound, settings: App_Settings) {
    if !audio.ready || settings.sfx_muted || settings.sfx_volume <= 0 { return }
    if !rl.IsSoundValid(sound) { return }
    rl.SetSoundVolume(sound, sfx_volume(settings))
    rl.PlaySound(sound)
}

play_paddle_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.paddle_hit, settings) }
play_wall_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.wall_hit, settings) }
play_score_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.score, settings) }
play_countdown_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.countdown, settings) }
play_go_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.go, settings) }
play_menu_click_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.menu_click, settings) }
play_win_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.win, settings) }
play_lose_sfx :: proc(audio: ^Audio_System, settings: App_Settings) { play_sfx(audio, audio.lose, settings) }
