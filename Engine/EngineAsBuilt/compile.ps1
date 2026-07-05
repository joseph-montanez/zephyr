# compile.ps1
# This script forces PowerShell to execute the build inside an initialized MSVC CMD context.
# Usage: .\compile.ps1 [--release] [-DevRoot "D:\workspace"]

param(
    [switch]$Release,
    [string]$DevRoot = "C:\dev"
)

$ErrorActionPreference = "Stop"

# Calculate project paths reliably regardless of where the terminal is currently CD'd
$zephyrDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($zephyrDir)) { $zephyrDir = "." }
$swiftBuildDir = "$zephyrDir\Engine\EngineAsBuilt"

# 1. Determine build configuration
$isRelease = $Release -or ($args -contains "--release")
$config = if ($isRelease) { "release" } else { "debug" }
Write-Host "### Building $config configuration in $DevRoot ###" -ForegroundColor Cyan

# 2. Detect Architecture for Target Triple & DXC
$hostArch = $env:PROCESSOR_ARCHITECTURE
if ($hostArch -eq "ARM64") {
    $vcvarsArch = "arm64"
    $swiftTriple = "aarch64-unknown-windows-msvc"
    $dxcArch = "arm64"
    $vcpkgTriplet = "arm64-windows"
} else {
    $vcvarsArch = "x64"
    $swiftTriple = "x86_64-unknown-windows-msvc"
    $dxcArch = "x64"
    $vcpkgTriplet = "x64-windows"
}

# 3. Define the paths cleanly using forward slashes for Clang
$clangDevRoot = $DevRoot -replace '\\', '/'

$env:SDL3_INCLUDE       = "$clangDevRoot/SDL3/include"
$env:SDL3_LIB           = "$clangDevRoot/SDL3/lib"
$env:SDL3_IMAGE_INCLUDE = $env:SDL3_INCLUDE
$env:SDL3_IMAGE_LIB     = $env:SDL3_LIB
$env:SDL3_TTF_INCLUDE   = $env:SDL3_INCLUDE
$env:SDL3_TTF_LIB       = $env:SDL3_LIB

$env:DXFRW_INCLUDE      = "$clangDevRoot/libdxfrw/src"
$env:DXFRW_LIB          = "$clangDevRoot/libdxfrw/build/Release"

$env:DWG_INCLUDE        = "$clangDevRoot/libredwg/include"
$env:DWG_LIB            = "$clangDevRoot/libredwg/build"

$env:ZLIB_NG_INCLUDE    = "$clangDevRoot/zlib-ng/include"
$env:ZLIB_NG_LIB        = "$clangDevRoot/zlib-ng/lib"

$env:ICONV_LIB          = "$clangDevRoot/vcpkg/installed/$vcpkgTriplet/lib"

# PDFium
$pdfiumRoot = "$DevRoot\pdfium"
$pdfiumHeader = Join-Path $pdfiumRoot "include\fpdfview.h"
$pdfiumImportLibrary = Join-Path $pdfiumRoot "lib\pdfium.dll.lib"
$pdfiumDll = Join-Path $pdfiumRoot "bin\pdfium.dll"

$pdfiumAvailable = (Test-Path $pdfiumHeader) -and (Test-Path $pdfiumImportLibrary) -and (Test-Path $pdfiumDll)
if ($pdfiumAvailable) {
    $env:PDFIUM_INCLUDE = "$clangDevRoot/pdfium/include"
    $env:PDFIUM_LIB     = "$clangDevRoot/pdfium/lib"
} else {
    Write-Warning "PDFium installation is incomplete. PDF import will be unavailable."
}

# 4. Find Visual Studio and Build
$vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vsInstallerPath -latest -property installationPath
$vcvarsPath = "$vsPath\VC\Auxiliary\Build\vcvarsall.bat"

$buildCommand = "swift build -c $config -Xcc -I`"$($env:SDL3_INCLUDE)`""
$cmdScriptPath = "$env:TEMP\swift-compile-local.cmd"
Set-Content -Path $cmdScriptPath -Encoding ASCII -Value @(
    "@echo off",
    "cd /d `"$swiftBuildDir`"",
    "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
    $buildCommand,
    "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
)

Write-Host "Running Swift Compiler..."
cmd.exe /c $cmdScriptPath
if ($LASTEXITCODE -ne 0) { throw "Swift build failed!" }

# 5. Copy DLLs and Compile Shaders
$dllDest = "$swiftBuildDir\.build\$swiftTriple\$config"
New-Item -ItemType Directory -Path $dllDest -Force | Out-Null
Write-Host "`n### Staging Binaries to $dllDest ###" -ForegroundColor Yellow

# Locate DXC dynamically in Windows Kits
$dxcCandidates = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter "dxc.exe" -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -match "\\$dxcArch$" }
if ($dxcCandidates) {
    $dxcPath = $dxcCandidates[0].FullName
    Write-Host "Compiling Shaders with DXC..."
    
    # Needs to be wrapped in vcvars context for ARM64 runtime dependencies
    $dxcLines = @(
        "`"$dxcPath`" -T vs_6_0 -E main -Fo `"$dllDest\cad.vert.dxil`" `"$swiftBuildDir\Shaders\cad.vert.hlsl`"",
        "`"$dxcPath`" -T ps_6_0 -E main -Fo `"$dllDest\cad.frag.dxil`" `"$swiftBuildDir\Shaders\cad.frag.hlsl`"",
        "`"$dxcPath`" -T ps_6_0 -E main -Fo `"$dllDest\cad_aa.frag.dxil`" `"$swiftBuildDir\Shaders\cad_aa.frag.hlsl`"",
        "`"$dxcPath`" -T vs_6_0 -E main -Fo `"$dllDest\imgui.vert.dxil`" `"$swiftBuildDir\Shaders\imgui.vert.hlsl`"",
        "`"$dxcPath`" -T ps_6_0 -E main -Fo `"$dllDest\imgui.frag.dxil`" `"$swiftBuildDir\Shaders\imgui.frag.hlsl`"",
        "`"$dxcPath`" -T vs_6_0 -E main -Fo `"$dllDest\cad_id.vert.dxil`" `"$swiftBuildDir\Shaders\cad_id.vert.hlsl`"",
        "`"$dxcPath`" -T ps_6_0 -E main -Fo `"$dllDest\cad_id.frag.dxil`" `"$swiftBuildDir\Shaders\cad_id.frag.hlsl`""
    )
    $dxcScriptPath = "$env:TEMP\compile-shaders-local.cmd"
    Set-Content -Path $dxcScriptPath -Encoding ASCII -Value (@(
        "@echo off",
        "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1"
    ) + $dxcLines)
    cmd.exe /c $dxcScriptPath
} else {
    Write-Warning "dxc.exe not found for $dxcArch. Skipping shader compilation."
}

# Copy SDL DLLs
$sdlLib = "$DevRoot\SDL3\lib"
Copy-Item -Path "$sdlLib\SDL3.dll"       -Destination $dllDest -Force
Copy-Item -Path "$sdlLib\SDL3_image.dll" -Destination $dllDest -Force
Copy-Item -Path "$sdlLib\SDL3_ttf.dll"   -Destination $dllDest -Force

if ($pdfiumAvailable) { Copy-Item -LiteralPath $pdfiumDll -Destination $dllDest -Force }

# Copy libdxfrw & LibreDWG
Copy-Item -Path "$DevRoot\libdxfrw\build\Release\dxfrw.dll" -Destination $dllDest -Force -ErrorAction SilentlyContinue
Copy-Item -Path "$DevRoot\libredwg\build\libredwg.dll" -Destination $dllDest -Force -ErrorAction SilentlyContinue

# Copy Iconv
$iconvType = if ($isRelease) { "bin" } else { "debug\bin" }
Copy-Item -Path "$DevRoot\vcpkg\installed\$vcpkgTriplet\$iconvType\iconv-2.dll" -Destination $dllDest -Force -ErrorAction SilentlyContinue

# Copy Fonts & Plot Styles
foreach ($asset in @("Fonts", "Plot Styles")) {
    if (Test-Path "$swiftBuildDir\$asset") {
        $assetDest = "$dllDest\$asset"
        New-Item -ItemType Directory -Path $assetDest -Force | Out-Null
        Copy-Item -Path "$swiftBuildDir\$asset\*" -Destination $assetDest -Force -Recurse -ErrorAction SilentlyContinue
    }
}

Write-Host "`n### Build complete. Run with: .\$dllDest\Zephyr.exe ###" -ForegroundColor Green