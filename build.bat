@echo off
setlocal
cd /d "%~dp0"

rem v1.2 uses vendor:curl for HTTPS rendezvous. On Windows, static raylib
rem and static libcurl are built against opposite CRT choices, so build
rem raylib as a DLL to keep the executable on libcurl/Odin's libcmt side.
odin build . -out:pong.exe -define:RAYLIB_SHARED=true %*
if errorlevel 1 exit /b %errorlevel%

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
copy /Y "%RAYLIB_DLL%" "%CD%\raylib.dll" >nul
