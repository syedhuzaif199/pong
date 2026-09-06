# Android CI notes (v1.3.0 r8)

The Android release job intentionally mirrors the proven native Windows build pipeline.

Important invariants:

- Do not assume Odin object suffixes. `android/build_android.sh` discovers the object(s) emitted by Odin after compiling to the `pong_android` basename.
- Compile `android_bridge.cpp` as C++ and `android_native_app_glue.c` as C before final linking.
- Link `libmain.so` with `-static-libstdc++` so the APK does not require a separately packaged `libc++_shared.so`.
- CI uses Ubuntu 24.04 system CMake rather than an Android SDK CMake pin. raylib 6.0 requires CMake 3.25+; Ubuntu 24.04 provides a compatible version.
- The wrapper entry script invokes the inner script through `bash`, so Git executable-bit loss on Windows checkouts does not break CI.
- Release APK naming is derived from `VERSION`, not hard-coded in the workflow.
