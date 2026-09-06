package main

import rl "vendor:raylib"

Music_Mode :: enum {
    Silent,
    Menu,
    Gameplay,
}

Music_System :: struct {
    menu:     rl.Music,
    gameplay: rl.Music,

    menu_ready:     bool,
    gameplay_ready: bool,
    menu_playing:     bool,
    gameplay_playing: bool,

    menu_gain:     f32,
    gameplay_gain: f32,
    mode: Music_Mode,
    suspended: bool,
}

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

music_load :: proc(music: ^Music_System) {
    music.menu = rl.LoadMusicStream("assets/pong_menu_loop.wav")
    music.gameplay = rl.LoadMusicStream("assets/pong_gameplay_loop.wav")
    music.menu_ready = rl.IsMusicValid(music.menu)
    music.gameplay_ready = rl.IsMusicValid(music.gameplay)

    if music.menu_ready {
        music.menu.looping = true
    }
    if music.gameplay_ready {
        music.gameplay.looping = true
    }

    music.mode = .Silent
    music_set_mode(music, .Menu)
}

music_suspend :: proc(music: ^Music_System) {
    if music.suspended { return }
    if music.menu_ready && music.menu_playing { rl.PauseMusicStream(music.menu) }
    if music.gameplay_ready && music.gameplay_playing { rl.PauseMusicStream(music.gameplay) }
    music.suspended = true
}

music_resume :: proc(music: ^Music_System) {
    if !music.suspended { return }
    if music.menu_ready && music.menu_playing { rl.ResumeMusicStream(music.menu) }
    if music.gameplay_ready && music.gameplay_playing { rl.ResumeMusicStream(music.gameplay) }
    music.suspended = false
}

music_unload :: proc(music: ^Music_System) {
    if music.menu_ready {
        rl.StopMusicStream(music.menu)
        rl.UnloadMusicStream(music.menu)
    }
    if music.gameplay_ready {
        rl.StopMusicStream(music.gameplay)
        rl.UnloadMusicStream(music.gameplay)
    }
    music^ = Music_System{}
}

music_set_mode :: proc(music: ^Music_System, mode: Music_Mode) {
    if music.mode == mode { return }
    music.mode = mode

    #partial switch mode {
    case .Menu:
        if music.menu_ready && !music.menu_playing {
            // PlayMusicStream after StopMusicStream restarts the loop from its beginning.
            rl.StopMusicStream(music.menu)
            rl.PlayMusicStream(music.menu)
            music.menu_playing = true
            music.menu_gain = 0
        }
    case .Gameplay:
        if music.gameplay_ready && !music.gameplay_playing {
            // Every match begins at the start of the gameplay track.
            rl.StopMusicStream(music.gameplay)
            rl.PlayMusicStream(music.gameplay)
            music.gameplay_playing = true
            music.gameplay_gain = 0
        }
    case .Silent:
    }
}

approach_f32 :: proc(value, target, amount: f32) -> f32 {
    if value < target {
        return min(target, value + amount)
    }
    if value > target {
        return max(target, value - amount)
    }
    return value
}

music_update :: proc(music: ^Music_System, settings: App_Settings, dt: f32) {
    if music.suspended { return }
    menu_target: f32 = 0
    gameplay_target: f32 = 0
    #partial switch music.mode {
    case .Menu:
        menu_target = 1
    case .Gameplay:
        gameplay_target = 1
    case .Silent:
    }

    // Menu music fades out quickly before the synchronized countdown.
    menu_speed: f32 = 2.5
    if menu_target < music.menu_gain { menu_speed = 4.5 }

    // Gameplay enters briskly at GO, but leaves more gently at game over/exit.
    gameplay_speed: f32 = 3.0
    if gameplay_target > music.gameplay_gain { gameplay_speed = 6.0 }

    music.menu_gain = approach_f32(music.menu_gain, menu_target, menu_speed * dt)
    music.gameplay_gain = approach_f32(music.gameplay_gain, gameplay_target, gameplay_speed * dt)

    master := f32(settings.music_volume) / 100.0
    if settings.music_muted { master = 0 }

    if music.menu_playing {
        rl.SetMusicVolume(music.menu, master * music.menu_gain)
        rl.UpdateMusicStream(music.menu)
        if menu_target == 0 && music.menu_gain <= 0.001 {
            rl.StopMusicStream(music.menu)
            music.menu_playing = false
            music.menu_gain = 0
        }
    }

    if music.gameplay_playing {
        rl.SetMusicVolume(music.gameplay, master * music.gameplay_gain)
        rl.UpdateMusicStream(music.gameplay)
        if gameplay_target == 0 && music.gameplay_gain <= 0.001 {
            rl.StopMusicStream(music.gameplay)
            music.gameplay_playing = false
            music.gameplay_gain = 0
        }
    }
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
