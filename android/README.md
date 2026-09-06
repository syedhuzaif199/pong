# UDP Pong v1.3 Android

Android is an **ARM64-first** port of the desktop v1.2 client. Gameplay protocol 4,
discovery protocol 1, rendezvous protocol 1, Cloudflare STUN, and the Render room
service are unchanged.

## Requirements

- Odin `dev-2026-07` or compatible
- Android Studio / Android SDK
- Android NDK (r28+ recommended)
- CMake
- Git
- JDK 17
- Linux/macOS host; on Windows, run the script from WSL with the SDK/NDK visible

Set:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<installed-version>"
```

Then:

```bash
./android/build_android.sh
```

The first build downloads raylib 6.0 into `android/.deps/raylib`, builds it for
`arm64-v8a`, compiles the Odin package as PIC Android ARM64 object code, and links
both into `libmain.so` for a NativeActivity APK.

If Gradle is installed, the script also builds:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

Install with:

```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

## Android-specific behavior

- Landscape/fullscreen NativeActivity.
- App assets are packaged under APK `assets/assets/`, preserving existing
  `assets/...` paths used by the desktop game.
- Config is stored under Android's app-private internal data directory.
- Menu buttons use first-touch as the primary pointer.
- During a match, touching the upper half moves the local paddle up; touching the
  lower half moves it down.
- HTTP rendezvous calls use Android `HttpURLConnection`; Android does not link
  desktop `libcurl`.
- STUN and gameplay remain native UDP and use the same protocol as v1.2 desktop.

## Current first-port caveats

- Android is ARM64-only for v1.3 initially.
- LAN discovery still uses the Linux-oriented discovery implementation and needs
  device testing; Internet room-code play is the primary Android path.
- Text entry currently asks Android to show the soft keyboard and consumes
  raylib key/character events. IME behavior varies by device; if a particular
  keyboard does not emit usable character events, the next patch should replace
  this with a small in-game keyboard/IME bridge.
- Rendezvous HTTP remains synchronous, matching v1.2 desktop behavior; a sleeping
  Render free service can still briefly stall the UI.

## Why the build compiles raylib

Odin includes raylib bindings and desktop binaries, but its distribution does not
ship an Android `libraylib.a`. Android therefore compiles raylib 6.0 against the NDK
and links it with Odin's Android object code.
