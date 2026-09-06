@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "BUILD_REV=2026-09-06-v1.5-local-play-r1"

rem ============================================================================
rem UDP Pong v1.5 - Native Windows Android build
rem
rem Expected project layout:
rem   build-android.bat
rem   android\
rem   *.odin
rem   assets\
rem
rem Local builds intentionally auto-detect the installed NDK and CMake.
rem CI can remain pinned for reproducibility.
rem   Android API: 29 minimum / 36 compile+target
rem   NDK:         newest installed side-by-side NDK
rem   CMake:       newest installed Android SDK CMake
rem   Gradle:      9.6.0 (required by AGP 9.4.0)
rem   ABI:         arm64-v8a
rem ============================================================================

set "ROOT=%~dp0"
set "ANDROID_DIR=%ROOT%android"
set "BUILD_DIR=%ANDROID_DIR%\.build"
set "DEPS_DIR=%ANDROID_DIR%\.deps"
set "ABI=arm64-v8a"
set "API=29"
set "GRADLE_VERSION=9.6.0"
set "RAYLIB_TAG=6.0"

rem ----- Android SDK -----------------------------------------------------------
if not defined ANDROID_HOME set "ANDROID_HOME=C:\Users\Orchardly\AppData\Local\Android\Sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

if not exist "%ANDROID_HOME%\platforms\android-36\android.jar" (
    echo ERROR: Android platform 36 was not found.
    echo Expected: "%ANDROID_HOME%\platforms\android-36\android.jar"
    echo Install Android SDK Platform 36 from Android Studio SDK Manager.
    goto :fail
)

rem ----- Android NDK -----------------------------------------------------------
rem Respect an explicit valid ANDROID_NDK_HOME. Otherwise pick the newest
rem side-by-side NDK directory installed by Android Studio.
if defined ANDROID_NDK_HOME (
    if exist "%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" goto :ndk_ok
)

set "ANDROID_NDK_HOME="
if not exist "%ANDROID_HOME%\ndk" (
    echo ERROR: No Android NDK directory was found under:
    echo   "%ANDROID_HOME%\ndk"
    goto :fail
)

rem /O-N gives newest version-looking directory first for normal NDK names
rem such as 30.0.16138531, 29.0.14206865, etc.
for /f "delims=" %%D in ('dir /b /ad /o-n "%ANDROID_HOME%\ndk" 2^>nul') do (
    if not defined ANDROID_NDK_HOME (
        if exist "%ANDROID_HOME%\ndk\%%D\build\cmake\android.toolchain.cmake" (
            set "ANDROID_NDK_HOME=%ANDROID_HOME%\ndk\%%D"
        )
    )
)

:ndk_ok
if not defined ANDROID_NDK_HOME (
    echo ERROR: No valid Android NDK installation was found under:
    echo   "%ANDROID_HOME%\ndk"
    goto :fail
)
if not exist "%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" (
    echo ERROR: Selected NDK does not look valid:
    echo   "%ANDROID_NDK_HOME%"
    goto :fail
)

rem Odin's Android backend uses its own environment variable names.
set "ODIN_ANDROID_SDK=%ANDROID_HOME%"
set "ODIN_ANDROID_NDK=%ANDROID_NDK_HOME%"

rem ----- JDK -------------------------------------------------------------------
rem Keep an already-valid JAVA_HOME. Otherwise use Android Studio's bundled JBR.
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" goto :java_ok
set "JAVA_HOME=D:\Android\Android Studio\jbr"
:java_ok
if not exist "%JAVA_HOME%\bin\java.exe" (
    echo ERROR: Java was not found.
    echo Checked JAVA_HOME="%JAVA_HOME%"
    echo Expected Android Studio JBR at "D:\Android\AndroidStudio\jbr"
    goto :fail
)
set "PATH=%JAVA_HOME%\bin;%PATH%"

rem ----- Android CMake / Ninja -------------------------------------------------
rem Use the newest CMake installed by Android Studio. This is only used to build
rem raylib; it does not need to match the CI CMake version exactly.
set "CMAKE_HOME="
if not exist "%ANDROID_HOME%\cmake" (
    echo ERROR: No Android SDK CMake directory was found under:
    echo   "%ANDROID_HOME%\cmake"
    goto :fail
)
for /f "delims=" %%D in ('dir /b /ad /o-n "%ANDROID_HOME%\cmake" 2^>nul') do (
    if not defined CMAKE_HOME (
        if exist "%ANDROID_HOME%\cmake\%%D\bin\cmake.exe" (
            set "CMAKE_HOME=%ANDROID_HOME%\cmake\%%D"
        )
    )
)
if not defined CMAKE_HOME (
    echo ERROR: No valid Android SDK CMake installation was found under:
    echo   "%ANDROID_HOME%\cmake"
    goto :fail
)
set "CMAKE=%CMAKE_HOME%\bin\cmake.exe"
set "NINJA=%CMAKE_HOME%\bin\ninja.exe"
if not exist "%CMAKE%" (
    echo ERROR: cmake.exe was not found at "%CMAKE%"
    goto :fail
)
if not exist "%NINJA%" (
    echo ERROR: ninja.exe was not found at "%NINJA%"
    goto :fail
)

rem ----- Required host tools ---------------------------------------------------
where odin >nul 2>nul
if errorlevel 1 (
    echo ERROR: odin.exe was not found in PATH.
    goto :fail
)
where git >nul 2>nul
if errorlevel 1 (
    echo ERROR: git.exe was not found in PATH.
    goto :fail
)
where powershell >nul 2>nul
if errorlevel 1 (
    echo ERROR: powershell.exe was not found in PATH.
    goto :fail
)

rem ----- NDK tools -------------------------------------------------------------
set "TOOLCHAIN=%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64"
set "ODIN_ANDROID_NDK_TOOLCHAIN=%TOOLCHAIN%"
set "CLANG=%TOOLCHAIN%\bin\clang.exe"
set "CLANGXX=%TOOLCHAIN%\bin\clang++.exe"
set "TARGET_TRIPLE=aarch64-linux-android%API%"
set "STRIP=%TOOLCHAIN%\bin\llvm-strip.exe"
set "GLUE=%ANDROID_NDK_HOME%\sources\android\native_app_glue"

if not exist "%CLANG%" (
    echo ERROR: NDK clang.exe was not found.
    echo Expected: "%CLANG%"
    goto :fail
)
if not exist "%CLANGXX%" (
    echo ERROR: NDK clang++.exe was not found.
    echo Expected: "%CLANGXX%"
    goto :fail
)
if not exist "%STRIP%" (
    echo ERROR: llvm-strip.exe was not found.
    echo Expected: "%STRIP%"
    goto :fail
)
if not exist "%GLUE%\android_native_app_glue.c" (
    echo ERROR: android_native_app_glue.c was not found.
    echo Expected: "%GLUE%\android_native_app_glue.c"
    goto :fail
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%DEPS_DIR%" mkdir "%DEPS_DIR%"

rem ----- Environment summary --------------------------------------------------
echo.
echo === UDP Pong v1.5 Android build [%BUILD_REV%] ===
echo SDK:      %ANDROID_HOME%
echo NDK:      %ANDROID_NDK_HOME%
echo CMake:    %CMAKE%
echo Java:     %JAVA_HOME%
echo ABI:      %ABI%
echo API:      %API%
echo.

rem ----- Fetch raylib 6.0 ------------------------------------------------------
if not defined RAYLIB_SRC set "RAYLIB_SRC=%DEPS_DIR%\raylib"
if not exist "%RAYLIB_SRC%\src\raylib.h" (
    echo Fetching raylib %RAYLIB_TAG%...
    if exist "%RAYLIB_SRC%" rmdir /s /q "%RAYLIB_SRC%"
    git clone --depth 1 --branch "%RAYLIB_TAG%" https://github.com/raysan5/raylib.git "%RAYLIB_SRC%"
    if errorlevel 1 goto :fail
)

rem ----- Build raylib for Android ARM64 ---------------------------------------
set "RAYLIB_BUILD=%BUILD_DIR%\raylib"
echo.
echo Configuring raylib for Android %ABI%...
"%CMAKE%" -S "%RAYLIB_SRC%" -B "%RAYLIB_BUILD%" -G Ninja ^
    -DCMAKE_TOOLCHAIN_FILE="%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" ^
    -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
    -DPLATFORM=Android ^
    -DANDROID_ABI=%ABI% ^
    -DANDROID_PLATFORM=android-%API% ^
    -DBUILD_EXAMPLES=OFF ^
    -DBUILD_SHARED_LIBS=OFF ^
    -DCMAKE_BUILD_TYPE=MinSizeRel
if errorlevel 1 goto :fail

"%CMAKE%" --build "%RAYLIB_BUILD%" --parallel
if errorlevel 1 goto :fail

set "RAYLIB_LIB="
rem Use WHERE rather than FOR /R with a literal filename. FOR /R can synthesize
rem candidate paths for each directory even when the file is not present.
for /f "delims=" %%F in ('where /r "%RAYLIB_BUILD%" libraylib.a 2^>nul') do (
    if not defined RAYLIB_LIB set "RAYLIB_LIB=%%~fF"
)
if not defined RAYLIB_LIB (
    echo ERROR: Could not locate libraylib.a after the raylib build.
    echo Searched under: "%RAYLIB_BUILD%"
    echo Existing .a files:
    dir /s /b "%RAYLIB_BUILD%\*.a" 2^>nul
    goto :fail
)
if not exist "!RAYLIB_LIB!" (
    echo ERROR: raylib lookup produced a nonexistent path:
    echo   "!RAYLIB_LIB!"
    goto :fail
)
echo raylib:  !RAYLIB_LIB!

rem ----- Compile Odin to one PIC Android ARM64 object -------------------------
rem On Windows Odin emits a .obj file even for an Android/ELF target. Using
rem -use-single-module gives us one deterministic object and avoids filename
rem globbing/response-file quoting problems.
set "PONG_OBJ=%BUILD_DIR%\pong_android.obj"
del /q "%BUILD_DIR%\pong_android*.o" >nul 2>nul
del /q "%BUILD_DIR%\pong_android*.obj" >nul 2>nul

echo.
echo Compiling Odin for Android ARM64...
pushd "%ROOT%"
odin build . -target:linux_arm64 -subtarget:android -build-mode:obj -reloc-mode:pic -define:PONG_ANDROID=true -o:speed -use-single-module -out:"%PONG_OBJ%"
if errorlevel 1 (
    popd
    goto :fail
)
popd

if not exist "%PONG_OBJ%" (
    echo ERROR: Odin returned success but did not create:
    echo   "%PONG_OBJ%"
    echo Build directory contents:
    dir /b "%BUILD_DIR%"
    goto :fail
)
echo Odin object: "%PONG_OBJ%"

rem ----- Compile Android bridge/native_app_glue -------------------------------
set "BRIDGE_OBJ=%BUILD_DIR%\android_bridge.o"
set "GLUE_OBJ=%BUILD_DIR%\android_native_app_glue.o"

echo.
echo Compiling Android bridge...
"%CLANGXX%" --target=%TARGET_TRIPLE% -fPIC -std=c++17 ^
    -I"%GLUE%" ^
    -c "%ANDROID_DIR%\bridge\android_bridge.cpp" ^
    -o "%BRIDGE_OBJ%"
if errorlevel 1 goto :fail
if not exist "%BRIDGE_OBJ%" (
    echo ERROR: Android bridge compiler returned success but did not create:
    echo   "%BRIDGE_OBJ%"
    goto :fail
)

echo Compiling android_native_app_glue...
"%CLANG%" --target=%TARGET_TRIPLE% -fPIC ^
    -I"%GLUE%" ^
    -c "%GLUE%\android_native_app_glue.c" ^
    -o "%GLUE_OBJ%"
if errorlevel 1 goto :fail
if not exist "%GLUE_OBJ%" (
    echo ERROR: native_app_glue compiler returned success but did not create:
    echo   "%GLUE_OBJ%"
    goto :fail
)

rem ----- Link libmain.so -------------------------------------------------------
rem IMPORTANT: do not use a clang response file here with native Windows paths.
rem LLVM response-file parsing treats backslashes as escape characters, turning
rem C:\Users\... into C:Users... . Passing quoted arguments directly through
rem cmd.exe preserves the paths correctly.
set "JNI_DIR=%ANDROID_DIR%\app\src\main\jniLibs\%ABI%"
if not exist "%JNI_DIR%" mkdir "%JNI_DIR%"
set "OUT_SO=%JNI_DIR%\libmain.so"
if exist "%OUT_SO%" del /q "%OUT_SO%"
del /q "%BUILD_DIR%\link_android.rsp" >nul 2>nul

rem Convert linker file paths to forward slashes. LLVM on Windows accepts
rem C:/... paths directly; this also makes the link robust against response-file
rem and quoting/backslash interpretation problems.
set "PONG_OBJ_LINK=%PONG_OBJ:\=/%"
set "BRIDGE_OBJ_LINK=%BRIDGE_OBJ:\=/%"
set "GLUE_OBJ_LINK=%GLUE_OBJ:\=/%"
set "OUT_SO_LINK=%OUT_SO:\=/%"
set "RAYLIB_LIB_LINK=!RAYLIB_LIB:\=/!"

rem Refuse to invoke clang unless every link input actually exists.
if not exist "%PONG_OBJ%" (echo ERROR: Missing Odin object: "%PONG_OBJ%" & goto :fail)
if not exist "%BRIDGE_OBJ%" (echo ERROR: Missing bridge object: "%BRIDGE_OBJ%" & goto :fail)
if not exist "%GLUE_OBJ%" (echo ERROR: Missing glue object: "%GLUE_OBJ%" & goto :fail)
if not exist "!RAYLIB_LIB!" (echo ERROR: Missing raylib archive: "!RAYLIB_LIB!" & goto :fail)

echo.
echo Linking libmain.so...
echo   Odin:   "%PONG_OBJ_LINK%"
echo   Bridge: "%BRIDGE_OBJ_LINK%"
echo   Glue:   "%GLUE_OBJ_LINK%"
echo   raylib: "!RAYLIB_LIB_LINK!"
"%CLANGXX%" --target=%TARGET_TRIPLE% ^
    -static-libstdc++ ^
    -shared ^
    -Wl,-soname,libmain.so ^
    -Wl,--no-undefined ^
    -Wl,-z,relro,-z,now ^
    -Wl,--wrap=fopen ^
    -Wl,-u,ANativeActivity_onCreate ^
    "%PONG_OBJ_LINK%" ^
    "%BRIDGE_OBJ_LINK%" ^
    "%GLUE_OBJ_LINK%" ^
    "!RAYLIB_LIB_LINK!" ^
    -landroid -llog -lEGL -lGLESv2 -lOpenSLES -ldl -lm -lc ^
    -o "%OUT_SO_LINK%"
if errorlevel 1 goto :fail

if not exist "%OUT_SO%" (
    echo ERROR: Linker returned success but libmain.so was not created:
    echo   "%OUT_SO%"
    goto :fail
)

"%STRIP%" --strip-unneeded "%OUT_SO%"
if errorlevel 1 echo WARNING: llvm-strip failed; continuing with the unstripped library.

echo Native Android library ready: "%OUT_SO%"

rem ----- Package game assets --------------------------------------------------
set "APK_ASSET_DIR=%ANDROID_DIR%\app\src\main\assets\assets"
if exist "%APK_ASSET_DIR%" rmdir /s /q "%APK_ASSET_DIR%"
if not exist "%ANDROID_DIR%\app\src\main\assets" mkdir "%ANDROID_DIR%\app\src\main\assets"

if exist "%ROOT%assets" (
    mkdir "%APK_ASSET_DIR%" >nul 2>nul
    xcopy "%ROOT%assets\*" "%APK_ASSET_DIR%\" /E /I /Y /Q >nul
    if errorlevel 1 (
        echo ERROR: Failed to copy assets into the Android APK tree.
        goto :fail
    )
) else (
    echo.
    echo WARNING: "%ROOT%assets" does not exist.
    echo The APK can still be packaged, but the game will be missing runtime assets.
)

rem ----- Bootstrap Gradle wrapper if the archive does not have one ------------
if not exist "%ANDROID_DIR%\gradlew.bat" (
    echo.
    echo Gradle wrapper not found; bootstrapping Gradle %GRADLE_VERSION%...
    set "GRADLE_HOME_LOCAL=%DEPS_DIR%\gradle-%GRADLE_VERSION%"
    set "GRADLE_ZIP=%DEPS_DIR%\gradle-%GRADLE_VERSION%-bin.zip"

    if not exist "!GRADLE_HOME_LOCAL!\bin\gradle.bat" (
        if not exist "!GRADLE_ZIP!" (
            echo Downloading Gradle %GRADLE_VERSION%...
            powershell -NoProfile -ExecutionPolicy Bypass -Command ^
                "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing 'https://services.gradle.org/distributions/gradle-%GRADLE_VERSION%-bin.zip' -OutFile '!GRADLE_ZIP!'"
            if errorlevel 1 goto :fail
        )

        echo Extracting Gradle %GRADLE_VERSION%...
        if exist "!GRADLE_HOME_LOCAL!" rmdir /s /q "!GRADLE_HOME_LOCAL!"
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Expand-Archive -LiteralPath '!GRADLE_ZIP!' -DestinationPath '%DEPS_DIR%' -Force"
        if errorlevel 1 goto :fail
    )

    pushd "%ANDROID_DIR%"
    call "!GRADLE_HOME_LOCAL!\bin\gradle.bat" wrapper --gradle-version %GRADLE_VERSION% --distribution-type bin
    if errorlevel 1 (
        popd
        goto :fail
    )
    popd
)

rem ----- Build debug APK ------------------------------------------------------
echo.
echo Building Android APK with Gradle...
pushd "%ANDROID_DIR%"
call gradlew.bat --no-daemon assembleDebug
if errorlevel 1 (
    popd
    goto :fail
)
popd

set "APK=%ANDROID_DIR%\app\build\outputs\apk\debug\app-debug.apk"
if not exist "%APK%" (
    echo ERROR: Gradle completed but the expected APK was not found:
    echo "%APK%"
    goto :fail
)

echo.
echo ============================================================
echo BUILD SUCCEEDED
echo APK: "%APK%"
echo ============================================================
echo.
echo To install it, with adb available:
echo   adb install -r "%APK%"
echo.
exit /b 0

:fail
echo.
echo ============================================================
echo BUILD FAILED
if not "%ERRORLEVEL%"=="0" echo Exit code: %ERRORLEVEL%
echo ============================================================
exit /b 1
