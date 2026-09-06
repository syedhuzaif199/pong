# Android CI notes (v1.4.0)

The Android release job mirrors the native build path that was validated during v1.3 and keeps the following invariants:

- never assume Odin object suffixes; discover the object(s) emitted from the `pong_android` basename
- compile `android_bridge.cpp` as C++ and `android_native_app_glue.c` as C
- link `libmain.so` with static libc++ so the APK does not depend on an omitted `libc++_shared.so`
- use CMake 3.25+ for raylib 6.0
- invoke shell wrappers through `bash` so Windows checkout executable-bit loss does not break CI
- derive artifact version strings from `VERSION`
- validate a debug APK first; if Android signing secrets exist, additionally build a release-signed APK and AAB
- keep gameplay protocol 4; v1.4 is not a wire-protocol migration
