# run_tests.ps1
# This script executes swift test inside the initialized MSVC Arm64 CMD context.

$env:SDL3_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_LIB = "C:/dev/SDL3/lib/arm64"
$env:SDL3_IMAGE_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_IMAGE_LIB = "C:/dev/SDL3/lib/arm64"
$env:SDL3_TTF_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_TTF_LIB = "C:/dev/SDL3/lib/arm64"
$env:DXFRW_INCLUDE = "C:/dev/libdxfrw/src"
$env:DXFRW_LIB = "C:/dev/libdxfrw/build/Release"
$env:ICONV_LIB = "C:/dev/vcpkg/installed/arm64-windows/lib"

$vcvarsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
$testCommand = "swift test"
cmd.exe /c "`"$vcvarsPath`" arm64 && $testCommand"
