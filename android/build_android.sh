#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
BUILD_DIR="$ANDROID_DIR/.build"
DEPS_DIR="$ANDROID_DIR/.deps"
ABI="arm64-v8a"
API="29"
RAYLIB_TAG="6.0"
GRADLE_VERSION="9.6.0"

: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK directory}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your Android NDK directory}"

command -v odin >/dev/null || { echo "ERROR: odin not found in PATH" >&2; exit 1; }
command -v cmake >/dev/null || { echo "ERROR: cmake not found in PATH" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 1; }

HOST_TAG=""
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux)  HOST_TAG="linux-x86_64" ;;
  *) echo "ERROR: build_android.sh supports Linux/macOS hosts. Use build-android.bat on Windows." >&2; exit 1 ;;
esac

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG"
CC="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
GLUE="$ANDROID_NDK_HOME/sources/android/native_app_glue"

[[ -x "$CC" ]] || { echo "ERROR: NDK C compiler not found: $CC" >&2; exit 1; }
[[ -x "$CXX" ]] || { echo "ERROR: NDK C++ compiler not found: $CXX" >&2; exit 1; }
[[ -x "$STRIP" ]] || { echo "ERROR: NDK llvm-strip not found: $STRIP" >&2; exit 1; }
[[ -f "$GLUE/android_native_app_glue.c" ]] || { echo "ERROR: android_native_app_glue.c not found: $GLUE/android_native_app_glue.c" >&2; exit 1; }

mkdir -p "$BUILD_DIR" "$DEPS_DIR"

RAYLIB_SRC="${RAYLIB_SRC:-$DEPS_DIR/raylib}"
if [[ ! -f "$RAYLIB_SRC/src/raylib.h" ]]; then
  echo "Fetching raylib $RAYLIB_TAG..."
  rm -rf "$RAYLIB_SRC"
  git clone --depth 1 --branch "$RAYLIB_TAG" https://github.com/raysan5/raylib.git "$RAYLIB_SRC"
fi

RAYLIB_BUILD="$BUILD_DIR/raylib"
echo "Configuring raylib for Android $ABI..."
cmake -S "$RAYLIB_SRC" -B "$RAYLIB_BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DPLATFORM=Android \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=MinSizeRel
cmake --build "$RAYLIB_BUILD" --config MinSizeRel --parallel

RAYLIB_LIB="$(find "$RAYLIB_BUILD" -type f -name libraylib.a -print -quit)"
[[ -n "$RAYLIB_LIB" && -f "$RAYLIB_LIB" ]] || {
  echo "ERROR: Could not locate libraylib.a after raylib build" >&2
  find "$RAYLIB_BUILD" -maxdepth 3 -type f -print >&2 || true
  exit 1
}
echo "raylib: $RAYLIB_LIB"

# Odin's object-file suffix is host/toolchain dependent. Do not assume .o or .obj.
# Remove all prior candidates, compile to a stable basename, then discover what Odin emitted.
rm -f "$BUILD_DIR"/pong_android "$BUILD_DIR"/pong_android.o "$BUILD_DIR"/pong_android.obj "$BUILD_DIR"/pong_android-*.o "$BUILD_DIR"/pong_android-*.obj
PONG_OUT_BASE="$BUILD_DIR/pong_android"
export ODIN_ANDROID_NDK="$ANDROID_NDK_HOME"
export ODIN_ANDROID_SDK="$ANDROID_HOME"
export ODIN_ANDROID_NDK_TOOLCHAIN="$TOOLCHAIN"

echo "Compiling Odin for Android ARM64..."
(
  cd "$ROOT"
  odin build . \
    -target:linux_arm64 \
    -subtarget:android \
    -build-mode:obj \
    -reloc-mode:pic \
    -define:PONG_ANDROID=true \
    -o:speed \
    -use-single-module \
    -out:"$PONG_OUT_BASE"
)

mapfile -t PONG_OBJECTS < <(
  find "$BUILD_DIR" -maxdepth 1 -type f \
    \( -name 'pong_android' -o -name 'pong_android.o' -o -name 'pong_android.obj' -o -name 'pong_android-*.o' -o -name 'pong_android-*.obj' \) \
    -print | sort
)
if (( ${#PONG_OBJECTS[@]} == 0 )); then
  echo "ERROR: Odin succeeded but emitted no pong_android object file." >&2
  echo "Build directory contents:" >&2
  find "$BUILD_DIR" -maxdepth 1 -type f -printf '  %f\n' >&2 || true
  exit 1
fi
printf 'Odin object(s):\n'
printf '  %s\n' "${PONG_OBJECTS[@]}"

# Compile C++ and C sources with their proper compilers before the final link.
BRIDGE_OBJ="$BUILD_DIR/android_bridge.o"
GLUE_OBJ="$BUILD_DIR/android_native_app_glue.o"
rm -f "$BRIDGE_OBJ" "$GLUE_OBJ"

echo "Compiling Android bridge..."
"$CXX" -fPIC -std=c++17 \
  -I"$GLUE" \
  -c "$ANDROID_DIR/bridge/android_bridge.cpp" \
  -o "$BRIDGE_OBJ"
[[ -f "$BRIDGE_OBJ" ]] || { echo "ERROR: bridge object was not created" >&2; exit 1; }

echo "Compiling android_native_app_glue..."
"$CC" -fPIC \
  -I"$GLUE" \
  -c "$GLUE/android_native_app_glue.c" \
  -o "$GLUE_OBJ"
[[ -f "$GLUE_OBJ" ]] || { echo "ERROR: native_app_glue object was not created" >&2; exit 1; }

JNI_DIR="$ANDROID_DIR/app/src/main/jniLibs/$ABI"
mkdir -p "$JNI_DIR"
OUT_SO="$JNI_DIR/libmain.so"
rm -f "$OUT_SO"

echo "Linking libmain.so..."
"$CXX" \
  -static-libstdc++ \
  -shared \
  -Wl,-soname,libmain.so \
  -Wl,--no-undefined \
  -Wl,-z,relro,-z,now \
  -Wl,--wrap=fopen \
  -Wl,-u,ANativeActivity_onCreate \
  "${PONG_OBJECTS[@]}" \
  "$BRIDGE_OBJ" \
  "$GLUE_OBJ" \
  "$RAYLIB_LIB" \
  -landroid -llog -lEGL -lGLESv2 -lOpenSLES -ldl -lm -lc \
  -o "$OUT_SO"
[[ -f "$OUT_SO" ]] || { echo "ERROR: linker returned success but libmain.so was not created" >&2; exit 1; }

"$STRIP" --strip-unneeded "$OUT_SO" || echo "WARNING: llvm-strip failed; packaging unstripped libmain.so" >&2

echo "Native Android library ready: $OUT_SO"

ASSET_DST="$ANDROID_DIR/app/src/main/assets/assets"
rm -rf "$ASSET_DST"
[[ -d "$ROOT/assets" ]] || { echo "ERROR: required assets directory is missing: $ROOT/assets" >&2; exit 1; }
mkdir -p "$(dirname "$ASSET_DST")"
cp -R "$ROOT/assets" "$ASSET_DST"

if [[ -x "$ANDROID_DIR/gradlew" || -f "$ANDROID_DIR/gradlew" ]]; then
  (cd "$ANDROID_DIR" && bash ./gradlew --no-daemon assembleDebug)
elif command -v gradle >/dev/null; then
  echo "Gradle wrapper not found; generating Gradle $GRADLE_VERSION wrapper..."
  (cd "$ANDROID_DIR" && gradle wrapper --gradle-version "$GRADLE_VERSION" --distribution-type bin)
  (cd "$ANDROID_DIR" && bash ./gradlew --no-daemon assembleDebug)
else
  echo "ERROR: neither android/gradlew nor a host 'gradle' command is available." >&2
  exit 1
fi

APK="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$APK" ]] || { echo "ERROR: Gradle completed but APK was not found: $APK" >&2; exit 1; }
echo
echo "APK: $APK"
