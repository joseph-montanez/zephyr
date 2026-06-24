@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" arm64
cd /d C:\dev\as-built\Engine\SwiftImGui
swift run AutoWrapper
echo EXIT_CODE=%ERRORLEVEL%
