# compile.ps1
# This script forces PowerShell to execute the build inside an initialized MSVC Arm64 CMD context.

# 1. Define the paths cleanly using forward slashes for Clang
$env:SDL3_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_LIB = "C:/dev/SDL3/lib/arm64"

# 2. Build the nested execution string for CMD
$vcvarsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
$buildCommand = "swift build -c debug -vv"

# 3. Call CMD, run the environment batch file, and chain the swift compilation right after it
cmd.exe /c "`"$vcvarsPath`" arm64 && $buildCommand"