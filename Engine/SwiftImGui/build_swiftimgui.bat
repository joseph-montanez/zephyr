@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" arm64 >nul 2>&1
cd /d C:\dev\as-built\Engine\SwiftImGui
echo Running swift build...
swift build -c debug > C:\dev\as-built\Engine\SwiftImGui\_swift_build.log 2>&1
echo DONE > C:\dev\as-built\Engine\SwiftImGui\_swift_done.txt
echo Exit code: %ERRORLEVEL% >> C:\dev\as-built\Engine\SwiftImGui\_swift_done.txt
