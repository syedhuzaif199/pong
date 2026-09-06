@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build

for %%I in (odin.exe) do set "ODIN_EXE=%%~$PATH:I"
if not defined ODIN_EXE (
  echo Could not locate odin.exe on PATH.
  exit /b 1
)
for %%I in ("%ODIN_EXE%") do set "ODIN_ROOT=%%~dpI"
set "RAYLIB_DLL=%ODIN_ROOT%vendor\raylib\windows\raylib.dll"
if not exist "%RAYLIB_DLL%" (
  echo Could not find raylib.dll at "%RAYLIB_DLL%".
  exit /b 1
)

odin build . -out:build\pong.exe -o:speed -subsystem:windows -define:RAYLIB_SHARED=true -resource:desktop\windows\pong.res %*
if errorlevel 1 exit /b %errorlevel%
python scripts\package_release.py --platform windows --arch x64 --binary build\pong.exe --raylib-dll "%RAYLIB_DLL%"
