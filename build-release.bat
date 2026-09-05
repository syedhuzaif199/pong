@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build
odin build . -out:build\pong.exe -o:speed -subsystem:windows %*
if errorlevel 1 exit /b %errorlevel%
python scripts\package_release.py --platform windows --arch x64 --binary build\pong.exe
