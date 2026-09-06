# UDP Pong v1.4 Android

The Android client is ARM64 (`arm64-v8a`) and Android 10/API 29+. Gameplay protocol 4, discovery protocol 1, rendezvous protocol 1, Cloudflare STUN, and the Render-style HTTPS rendezvous service remain compatible with v1.3 desktop clients.

## Build requirements

- Odin `dev-2026-07` or compatible
- Android Studio / Android SDK
- Android NDK (side-by-side; r29/r30 are supported by the project build scripts)
- CMake 3.25+
- JDK 17
- Git

Windows: install SDK/NDK with Android Studio and run:

```bat
build-android.bat
```

Linux/macOS:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<installed-version>"
bash ./build-android.sh
```

The scripts build raylib 6.0 for Android, compile Odin as PIC ARM64 Android object code, build the Java/JNI bridge, link `libmain.so`, package assets, and run Gradle.

Debug APK:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

Install with:

```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

## v1.4 Android behavior

- landscape/fullscreen NativeActivity
- real Android IME-backed text entry for names, ports, addresses, URLs, and room codes
- settings stored in private `SharedPreferences`
- hold upper/lower half or swipe/drag vertically to request up/down paddle input
- touch never changes paddle speed; input remains `-1/0/+1` on every platform
- permanent faint control affordances plus onboarding hint
- Android Back and on-screen MENU open the existing pause overlay
- background/foreground lifecycle suspends/resumes music and participates in reconnect handling
- HTTPS rendezvous/DNS work runs asynchronously through the Java bridge so room creation/joining does not freeze rendering/audio
- STUN and gameplay remain native UDP

## Release signing

`app/build.gradle` reads signing credentials from environment variables. See the repository-root `ANDROID_SIGNING.md`. CI creates a signed release APK and AAB when signing secrets are configured; otherwise it publishes a clearly labeled debug APK.
