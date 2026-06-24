# compile.ps1
# This script forces PowerShell to execute the build inside an initialized MSVC Arm64 CMD context.
# Usage: .\compile.ps1 [--release]

param(
    [switch]$Release
)

# 1. Determine build configuration (supports both --release and -Release)
$isRelease = $Release -or ($args -contains "--release")
if ($isRelease) {
    $config = "release"
    Write-Host "### Building RELEASE configuration ###"
} else {
    $config = "debug"
    Write-Host "### Building DEBUG configuration ###"
}

# 2. Define the paths cleanly using forward slashes for Clang
$env:SDL3_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_LIB = "C:/dev/SDL3/lib/arm64"
$env:SDL3_IMAGE_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_IMAGE_LIB = "C:/dev/SDL3/lib/arm64"
$env:SDL3_TTF_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_TTF_LIB = "C:/dev/SDL3/lib/arm64"
$env:DXFRW_INCLUDE = "C:/dev/libdxfrw/src"
$env:DXFRW_LIB = "C:/dev/libdxfrw/build/Release"
$env:ZLIB_NG_INCLUDE = "C:/dev/zlib-ng/include"
$env:ZLIB_NG_LIB = "C:/dev/zlib-ng/lib/arm64"
# PDFium (optional - for PDF import). Download via Engine\SwiftPdfium\download_pdfium.ps1
$pdfiumRoot = "C:\dev\pdfium"
$pdfiumHeader = Join-Path $pdfiumRoot "include\fpdfview.h"
$pdfiumImportLibrary = Join-Path $pdfiumRoot "lib\pdfium.dll.lib"
$pdfiumDll = Join-Path $pdfiumRoot "bin\pdfium.dll"
$pdfiumAvailable = (Test-Path $pdfiumHeader) -and
                   (Test-Path $pdfiumImportLibrary) -and
                   (Test-Path $pdfiumDll)

if ($pdfiumAvailable) {
    $env:PDFIUM_INCLUDE = "$pdfiumRoot/include"
    $env:PDFIUM_LIB     = "$pdfiumRoot/lib"
} elseif ((Test-Path $pdfiumRoot)) {
    Write-Warning "PDFium installation is incomplete. PDF import will be unavailable."
    Write-Warning "Expected: $pdfiumHeader"
    Write-Warning "Expected: $pdfiumImportLibrary"
    Write-Warning "Expected: $pdfiumDll"
}
$env:ICONV_LIB = "C:/dev/vcpkg/installed/arm64-windows/lib"

# 3. Build the nested execution string for CMD
$vcvarsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
$buildCommand = "swift build -c $config -Xcc -I$($env:SDL3_INCLUDE)"

# 4. Call CMD, run the environment batch file, and chain the swift compilation right after it
cmd.exe /c "`"$vcvarsPath`" arm64 && $buildCommand"

# Check if build succeeded
if ($LASTEXITCODE -ne 0) {
    Write-Error "Swift build failed! Stopping script."
    exit $LASTEXITCODE
}

# 5. Copy SDL DLLs to build output directory
$dllSource = "C:\dev\SDL3\lib\arm64"
$dllDest = ".build\aarch64-unknown-windows-msvc\$config"

Write-Host ""
Write-Host "### Copying SDL DLLs to build output... ###"
Write-Host "Source: $dllSource"
Write-Host "Dest:   $dllDest"

New-Item -ItemType Directory -Path $dllDest -Force | Out-Null

Write-Host ""
Write-Host "### Compiling Shaders with DXC... ###"
$dxcPath = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\arm64\dxc.exe"
if (Test-Path $dxcPath) {
    & $dxcPath -T vs_6_0 -E main -Fo "$dllDest\cad.vert.dxil" "Shaders\cad.vert.hlsl"
    & $dxcPath -T ps_6_0 -E main -Fo "$dllDest\cad.frag.dxil" "Shaders\cad.frag.hlsl"
    & $dxcPath -T ps_6_0 -E main -Fo "$dllDest\cad_aa.frag.dxil" "Shaders\cad_aa.frag.hlsl"
    & $dxcPath -T vs_6_0 -E main -Fo "$dllDest\imgui.vert.dxil" "Shaders\imgui.vert.hlsl"
    & $dxcPath -T ps_6_0 -E main -Fo "$dllDest\imgui.frag.dxil" "Shaders\imgui.frag.hlsl"
    & $dxcPath -T vs_6_0 -E main -Fo "$dllDest\cad_id.vert.dxil" "Shaders\cad_id.vert.hlsl"
    & $dxcPath -T ps_6_0 -E main -Fo "$dllDest\cad_id.frag.dxil" "Shaders\cad_id.frag.hlsl"
    Write-Host "Shaders compiled successfully."
} else {
    Write-Warning "dxc.exe not found at $dxcPath. Skipping shader compilation."
}

Copy-Item -Path "$dllSource\SDL3.dll"       -Destination $dllDest -Force
Copy-Item -Path "$dllSource\SDL3_image.dll"  -Destination $dllDest -Force
Copy-Item -Path "$dllSource\SDL3_ttf.dll"    -Destination $dllDest -Force

# 6. Copy PDFium DLL to the executable directory for runtime loading
if ($pdfiumAvailable) {
    Copy-Item -LiteralPath $pdfiumDll -Destination $dllDest -Force
    Write-Host "PDFium copied: $dllDest\pdfium.dll"
} else {
    Write-Warning "pdfium.dll was not copied. PDF import will be unavailable."
}

# 7. Copy libdxfrw DLLs to build output directory
$dxfrwDllSource = "C:\dev\libdxfrw\build\Release"
$iconvDebug = "C:\dev\vcpkg\installed\arm64-windows\debug\bin\iconv-2.dll"
$iconvRelease = "C:\dev\vcpkg\installed\arm64-windows\bin\iconv-2.dll"

Write-Host ""
Write-Host "### Copying libdxfrw DLLs to build output... ###"

Copy-Item -Path "$dxfrwDllSource\dxfrw.dll"  -Destination $dllDest -Force -ErrorAction SilentlyContinue

if ($isRelease) {
    Copy-Item -Path $iconvRelease -Destination $dllDest -Force -ErrorAction SilentlyContinue
    Write-Host "  iconv-2.dll (release)"
} else {
    Copy-Item -Path $iconvDebug -Destination $dllDest -Force -ErrorAction SilentlyContinue
    Write-Host "  iconv-2.dll (debug)"
}

Write-Host "DLLs copied successfully."

Write-Host ""
Write-Host "### Copying SHX Fonts to build output... ###"
$fontSource = "Fonts"
$fontDest = "$dllDest\Fonts"
if (Test-Path $fontSource) {
    New-Item -ItemType Directory -Path $fontDest -Force | Out-Null
    Copy-Item -Path "$fontSource\*.shx" -Destination $fontDest -Force
    Copy-Item -Path "$fontSource\*.ttf" -Destination $fontDest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$fontSource\*.otf" -Destination $fontDest -Force -ErrorAction SilentlyContinue
    Write-Host "Fonts copied: $fontDest"
}
else {
    Write-Host "No Fonts directory found -- skipping."
}

Write-Host "### Build complete. Run with: .\$dllDest\Zephyr.exe ###"
