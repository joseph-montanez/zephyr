# win_ext.ps1
# Sets environment variables for zlib-ng (static library) and builds the package.
# Run this from inside the SwiftZLibNG directory.
#
# Prerequisites:
#   zlib-ng headers at C:\dev\zlib-ng\include
#   zlib-ng static lib at C:\dev\zlib-ng\lib\arm64\zlibstatic-ng.lib
#   Visual Studio 2022 with ARM64 toolchain

param(
    [switch]$Release
)

$config = if ($Release) { "release" } else { "debug" }

# Paths to the prebuilt zlib-ng library
$env:ZLIB_NG_INCLUDE = "C:/dev/zlib-ng/include"
$env:ZLIB_NG_LIB = "C:/dev/zlib-ng/lib/arm64"

# Build using the MSVC ARM64 toolchain
$vcvarsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
$buildCommand = "swift build -c $config"

cmd.exe /c "`"$vcvarsPath`" arm64 && $buildCommand"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Swift build failed!"
    exit $LASTEXITCODE
}

Write-Host "### SwiftZLibNG build complete. ###"
