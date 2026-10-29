# compile.ps1
# This script forces PowerShell to execute the build inside an initialized MSVC CMD context.
# Usage: .\compile.ps1 [-Release] [-DevRoot "D:\workspace"]

param(
    [switch]$Release,
    [string]$DevRoot = "C:\dev"
)

# PowerShell does not recognize --release as matching -Release (switch).
# When passed as --release, it gets bound positionally to $DevRoot instead.
# Detect and recover from this case.
if ($DevRoot -eq "--release") {
    $DevRoot = "C:\dev"
    $Release = $true
}

$ErrorActionPreference = "Stop"

# Calculate project paths reliably regardless of where the terminal is currently CD'd
$zephyrDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($zephyrDir)) { $zephyrDir = "." }

# Auto-detect: if Package.swift exists here, we're already in the project. Otherwise, descend.
if (Test-Path "$zephyrDir\Package.swift") {
    $swiftBuildDir = "$zephyrDir"
} elseif (Test-Path "$zephyrDir\Engine\EngineAsBuilt\Package.swift") {
    $swiftBuildDir = "$zephyrDir\Engine\EngineAsBuilt"
} else {
    throw "Could not find Package.swift in $zephyrDir or $zephyrDir\Engine\EngineAsBuilt"
}

# 1. Determine build configuration
$isRelease = $Release -or ($args -contains "--release")
$config = if ($isRelease) { "release" } else { "debug" }
Write-Host "### Building $config configuration in $DevRoot ###" -ForegroundColor Cyan

# 2. Detect Architecture for Target Triple & DXC
# Ask the Swift toolchain first — it decides which MSVC libraries the link step
# needs. $env:PROCESSOR_ARCHITECTURE is unreliable when this script is launched
# from an emulated (x64) shell on ARM64 Windows: it reports AMD64, so vcvarsall
# would load the x64 MSVC/UCRT libs and the linker fails with
# "msvcrt.lib(chkstk.obj): machine type x64 conflicts with arm64".
$hostArch = $env:PROCESSOR_ARCHITECTURE
$toolchainTokens = $null
if (Get-Command swift -ErrorAction SilentlyContinue) {
    try {
        $toolchainInfo = (& swift -print-target-info 2>$null | Out-String)
        if ($toolchainInfo -match '"triple"\s*:\s*"([^"]+)"') {
            $toolchainTokens = $Matches[1]
        }
    } catch { $toolchainTokens = $null }
}
if ($toolchainTokens) {
    $hostArch = if ($toolchainTokens -like "aarch64*") { "ARM64" } else { "AMD64" }
} elseif ($env:PROCESSOR_ARCHITEW6432) {
    # Emulated x64 shell on ARM64: PROCESSOR_ARCHITECTURE says AMD64 but the
    # real machine is ARM64.
    $hostArch = $env:PROCESSOR_ARCHITEW6432
}
Write-Host "### Host architecture: $hostArch (toolchain: $toolchainTokens) ###" -ForegroundColor DarkGray
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

$env:ICONV_INCLUDE      = "$clangDevRoot/vcpkg/installed/$vcpkgTriplet/include"
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

# Swift 6.4 made `swiftbuild` the default build system. It scans every Swift Platform SDK under
# %LOCALAPPDATA%\Programs\Swift\Platforms and errors out with "platform 'windows' already registered"
# when more than one toolchain version is installed. Single-toolchain machines (CI runners) are fine,
# so only fall back to the (deprecated) native build system when multiple platforms are present.
# Long-term fix on a developer machine: uninstall the older Swift toolchains.
$swiftPlatformsRoot = "$env:LOCALAPPDATA\Programs\Swift\Platforms"
$swiftBuildSystemFlag = @()
if ((Test-Path $swiftPlatformsRoot) -and (@(Get-ChildItem $swiftPlatformsRoot -Directory).Count -gt 1)) {
    $platformVersions = (@(Get-ChildItem $swiftPlatformsRoot -Directory | Select-Object -ExpandProperty Name)) -join ', '
    Write-Host "Multiple Swift Platform SDKs found ($platformVersions) - using --build-system native" -ForegroundColor Yellow
    $swiftBuildSystemFlag = @("--build-system", "native")
}

# Release builds keep CodeView debug info so Instruments/perf tooling can symbolize optimized binaries.
$codeviewFlag = @()
if ($isRelease) { $codeviewFlag = @("-debug-info-format=codeview") }
$buildCommand = (@("swift build", "--configuration", $config) + $swiftBuildSystemFlag + $codeviewFlag + @("-Xcc", "-I`"$($env:SDL3_INCLUDE)`"")) -join " "
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

# 5. Determine build output directory and stage binaries
Push-Location "$swiftBuildDir"
try {
    $showBinCmd = (@("swift build", "--configuration", $config) + $swiftBuildSystemFlag + @("--show-bin-path")) -join " "
    $binDirOutput = cmd.exe /c "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1 && $showBinCmd"
    $dllDest = ($binDirOutput | Where-Object { $_ -and -not ($_ -match "warning:") } | Select-Object -Last 1).Trim()
} catch {
    $dllDest = $null
}
Pop-Location

# Fallback to locating the freshly built Zephyr.exe or the legacy triple path
if (-not $dllDest -or -not (Test-Path $dllDest)) {
    $foundExe = Get-ChildItem "$swiftBuildDir\.build" -Recurse -Filter "Zephyr.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($foundExe) {
        $dllDest = $foundExe.DirectoryName
    } else {
        $dllDest = "$swiftBuildDir\.build\$swiftTriple\$config"
    }
}

$destDirs = @($dllDest)
$legacyDest = "$swiftBuildDir\.build\$swiftTriple\$config"
if ($legacyDest -ne $dllDest -and (Test-Path $legacyDest)) {
    $destDirs += $legacyDest
}

foreach ($dest in $destDirs) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}
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

    if ($destDirs.Count -gt 1) {
        foreach ($dest in ($destDirs | Where-Object { $_ -ne $dllDest })) {
            Copy-Item -Path "$dllDest\*.dxil" -Destination $dest -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Warning "dxc.exe not found for $dxcArch. Skipping shader compilation."
}

foreach ($dest in $destDirs) {
    # Copy SDL DLLs
    $sdlLib = "$DevRoot\SDL3\lib"
    Copy-Item -Path "$sdlLib\SDL3.dll"       -Destination $dest -Force
    Copy-Item -Path "$sdlLib\SDL3_image.dll" -Destination $dest -Force
    Copy-Item -Path "$sdlLib\SDL3_ttf.dll"   -Destination $dest -Force

    if ($pdfiumAvailable) { Copy-Item -LiteralPath $pdfiumDll -Destination $dest -Force }

    # Copy libdxfrw & LibreDWG
    Copy-Item -Path "$DevRoot\libdxfrw\build\Release\dxfrw.dll" -Destination $dest -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "$DevRoot\libredwg\build\libredwg.dll" -Destination $dest -Force -ErrorAction SilentlyContinue

    # Copy Iconv
    $iconvType = if ($isRelease) { "bin" } else { "debug\bin" }
    Copy-Item -Path "$DevRoot\vcpkg\installed\$vcpkgTriplet\$iconvType\iconv-2.dll" -Destination $dest -Force -ErrorAction SilentlyContinue

    # Copy Fonts & Plot Styles
    foreach ($asset in @("Fonts", "Plot Styles", "Patterns", "lisp")) {
        if (Test-Path "$swiftBuildDir\$asset") {
            $assetDest = "$dest\$asset"
            New-Item -ItemType Directory -Path $assetDest -Force | Out-Null
            Copy-Item -Path "$swiftBuildDir\$asset\*" -Destination $assetDest -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

# Mirror the SwiftPM resource bundle (ZephyrCore hatch Patterns) next to
# every exe copy; the primary output dir already has it from the build.
foreach ($dest in ($destDirs | Where-Object { $_ -ne $dllDest })) {
    foreach ($bundle in @("Zephyr_ZephyrCore.bundle", "Zephyr_ZephyrCore.resources")) {
        if (Test-Path "$dllDest\$bundle") {
            Copy-Item -Path "$dllDest\$bundle" -Destination "$dest\$bundle" -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

# If legacy directory exists and differs from SwiftPM product output, mirror executables so legacy launch paths work
if ($destDirs.Count -gt 1) {
    foreach ($dest in ($destDirs | Where-Object { $_ -ne $dllDest })) {
        Copy-Item -Path "$dllDest\*.exe" -Destination $dest -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "$dllDest\*.lib" -Destination $dest -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n### Build complete. Run: cd `"$dllDest`" ; .\Zephyr.exe ###" -ForegroundColor Green