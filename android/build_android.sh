#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
BUILD_DIR="$ANDROID_DIR/.build"
DEPS_DIR="$ANDROID_DIR/.deps"
ABI="arm64-v8a"
API="29"
RAYLIB_TAG="6.0"

: "${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK directory}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your Android NDK directory}"

command -v odin >/dev/null || { echo "odin not found in PATH" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found in PATH" >&2; exit 1; }
command -v git >/dev/null || { echo "git not found in PATH" >&2; exit 1; }

HOST_TAG="linux-x86_64"
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux) HOST_TAG="linux-x86_64" ;;
  *) echo "build_android.sh currently supports Linux/macOS hosts. Use WSL on Windows." >&2; exit 1 ;;
esac

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG"
CXX="$TOOLCHAIN/bin/aarch64-linux-android${API}-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
GLUE="$ANDROID_NDK_HOME/sources/android/native_app_glue"

[[ -x "$CXX" ]] || { echo "NDK compiler not found: $CXX" >&2; exit 1; }
[[ -f "$GLUE/android_native_app_glue.c" ]] || { echo "android_native_app_glue.c not found in NDK" >&2; exit 1; }

mkdir -p "$BUILD_DIR" "$DEPS_DIR"

RAYLIB_SRC="${RAYLIB_SRC:-$DEPS_DIR/raylib}"
if [[ ! -f "$RAYLIB_SRC/src/raylib.h" ]]; then
  echo "Fetching raylib $RAYLIB_TAG..."
  rm -rf "$RAYLIB_SRC"
  git clone --depth 1 --branch "$RAYLIB_TAG" https://github.com/raysan5/raylib.git "$RAYLIB_SRC"
fi

RAYLIB_BUILD="$BUILD_DIR/raylib"
cmake -S "$RAYLIB_SRC" -B "$RAYLIB_BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DPLATFORM=Android \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=MinSizeRel
cmake --build "$RAYLIB_BUILD" --config MinSizeRel -j

RAYLIB_LIB="$(find "$RAYLIB_BUILD" -name libraylib.a -print -quit)"
[[ -n "$RAYLIB_LIB" ]] || { echo "Could not locate libraylib.a after raylib build" >&2; exit 1; }

PONG_OBJ="$BUILD_DIR/pong_android.o"
export ODIN_ANDROID_NDK="$ANDROID_NDK_HOME"
export ODIN_ANDROID_SDK="$ANDROID_HOME"
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
    -out:"$PONG_OBJ"
)

JNI_DIR="$ANDROID_DIR/app/src/main/jniLibs/$ABI"
mkdir -p "$JNI_DIR"
OUT_SO="$JNI_DIR/libmain.so"

echo "Linking libmain.so..."
"$CXX" \
  -static-libstdc++ \
  -shared \
  -Wl,-soname,libmain.so \
  -Wl,--no-undefined \
  -Wl,-z,relro,-z,now \
  -Wl,--wrap=fopen \
  -Wl,-u,ANativeActivity_onCreate \
  -I"$RAYLIB_SRC/src" \
  -I"$GLUE" \
  "$PONG_OBJ" \
  "$ANDROID_DIR/bridge/android_bridge.cpp" \
  "$GLUE/android_native_app_glue.c" \
  "$RAYLIB_LIB" \
  -landroid -llog -lEGL -lGLESv2 -lOpenSLES -ldl -lm -lc \
  -o "$OUT_SO"

"$STRIP" --strip-unneeded "$OUT_SO" || true

rm -rf "$ANDROID_DIR/app/src/main/assets/assets"
mkdir -p "$ANDROID_DIR/app/src/main/assets"
cp -R "$ROOT/assets" "$ANDROID_DIR/app/src/main/assets/assets"

echo "Native Android library ready: $OUT_SO"

if [[ -x "$ANDROID_DIR/gradlew" ]]; then
  (cd "$ANDROID_DIR" && ./gradlew assembleDebug)
elif command -v gradle >/dev/null; then
  (cd "$ANDROID_DIR" && gradle wrapper --gradle-version 9.6.0 && ./gradlew assembleDebug)
else
  echo
  echo "Gradle was not found. Open '$ANDROID_DIR' in Android Studio and build the app,"
  echo "or install Gradle once and rerun this script to generate the wrapper."
  exit 0
fi

echo
echo "APK: $ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
