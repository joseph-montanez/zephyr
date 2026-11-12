# test.ps1
# Run the Zephyr test suite with the full toolchain environment set up.
#
# `swift test` needs the same MSVC + native-library environment that
# compile.ps1 sets up, plus these env vars - the sibling SwiftSDL /
# SwiftZLibNG / SwiftDWG manifests read them and silently omit their -L
# paths when unset. The failure mode is confusing: sources compile fine and
# only the *link* of ZephyrTests.dll / Zephyr.exe dies with
#   lld-link: error: could not open 'SDL3.lib'
#   lld-link: error: undefined symbol: zng_crc32
# which looks like a code error but is purely a missing env var.
#
# Usage:
#   .\test.ps1                        # full suite
#   .\test.ps1 -Filter DynamicNumericInputTests
#   .\test.ps1 --filter TrimCommand   # swift-style args also accepted
#   .\test.ps1 -List                  # list every test case, run nothing
#   .\test.ps1 -SkipBuild             # reuse the last build, just run
#   .\test.ps1 -DevRoot "D:\workspace"

param(
    # swift-test args passed straight through (e.g. -Filter X, --parallel,
    # -v). Anything unbound lands here, so `.\test.ps1 --filter Foo` works
    # without PowerShell trying to bind --filter to a named parameter.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestArgs,

    # Convenience mirror of `--filter`; merged into TestArgs below.
    [string]$Filter,

    # Print the discovered test list and exit without running anything.
    [switch]$List,

    # Assume the test bundle is already built; skip `swift build --build-tests`.
    [switch]$SkipBuild,

    # Build configuration to test.
    [ValidateSet("debug", "release")]
    [string]$Configuration = "debug",

    [string]$DevRoot = "C:\dev"
)

$ErrorActionPreference = "Stop"

# -- 0. Locate the Swift package ----------------------------------------
# Works whether this script is run from the repo root or from EngineAsBuilt.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = "." }

if (Test-Path "$scriptDir\Package.swift") {
    $swiftBuildDir = "$scriptDir"
} elseif (Test-Path "$scriptDir\Engine\EngineAsBuilt\Package.swift") {
    $swiftBuildDir = "$scriptDir\Engine\EngineAsBuilt"
} else {
    throw "Could not find Package.swift in $scriptDir or $scriptDir\Engine\EngineAsBuilt"
}

# -- 1. Architecture ----------------------------------------------------
# Ask the Swift toolchain, not $env:PROCESSOR_ARCHITECTURE: the latter
# reports AMD64 from an emulated x64 shell on ARM64 Windows, which makes
# vcvarsall load x64 MSVC/UCRT libs and the linker fail with
# "msvcrt.lib(chkstk.obj): machine type x64 conflicts with arm64".
$hostArch = $env:PROCESSOR_ARCHITECTURE
$toolchainTriple = $null
if (Get-Command swift -ErrorAction SilentlyContinue) {
    try {
        $toolchainInfo = (& swift -print-target-info 2>$null | Out-String)
        if ($toolchainInfo -match '"triple"\s*:\s*"([^"]+)"') {
            $toolchainTriple = $Matches[1]
        }
    } catch { $toolchainTriple = $null }
}
if ($toolchainTriple) {
    $hostArch = if ($toolchainTriple -like "aarch64*") { "ARM64" } else { "AMD64" }
} elseif ($env:PROCESSOR_ARCHITEW6432) {
    $hostArch = $env:PROCESSOR_ARCHITEW6432
}
if ($hostArch -eq "ARM64") {
    $vcvarsArch = "arm64"
    $vcpkgTriplet = "arm64-windows"
    $swiftTriple = "aarch64-unknown-windows-msvc"
} else {
    $vcvarsArch = "x64"
    $vcpkgTriplet = "x64-windows"
    $swiftTriple = "x86_64-unknown-windows-msvc"
}
Write-Host "### Host architecture: $hostArch (toolchain: $toolchainTriple) ###" -ForegroundColor DarkGray

# -- 2. Native dependency env vars -------------------------------------
# Forward slashes throughout: Clang and SwiftPM both dislike backslash
# escapes in -I / -L flags.
$clangDevRoot = $DevRoot -replace '\\', '/'

$env:SDL3_INCLUDE       = "$clangDevRoot/SDL3/include"
$env:SDL3_LIB           = "$clangDevRoot/SDL3/lib"
$env:SDL3_IMAGE_INCLUDE = $env:SDL3_INCLUDE
$env:SDL3_IMAGE_LIB     = $env:SDL3_LIB
$env:SDL3_TTF_INCLUDE   = $env:SDL3_INCLUDE
$env:SDL3_TTF_LIB       = $env:SDL3_LIB

$env:ZLIB_NG_INCLUDE    = "$clangDevRoot/zlib-ng/include"
$env:ZLIB_NG_LIB        = "$clangDevRoot/zlib-ng/lib"

$env:DXFRW_INCLUDE      = "$clangDevRoot/libdxfrw/src"
$env:DXFRW_LIB          = "$clangDevRoot/libdxfrw/build/Release"

$env:DWG_INCLUDE        = "$clangDevRoot/libredwg/include"
$env:DWG_LIB            = "$clangDevRoot/libredwg/build"

$env:ICONV_INCLUDE      = "$clangDevRoot/vcpkg/installed/$vcpkgTriplet/include"
$env:ICONV_LIB          = "$clangDevRoot/vcpkg/installed/$vcpkgTriplet/lib"

$pdfiumRoot = "$DevRoot\pdfium"
$pdfiumAvailable = (Test-Path (Join-Path $pdfiumRoot "include\fpdfview.h")) -and
                   (Test-Path (Join-Path $pdfiumRoot "lib\pdfium.dll.lib"))
if ($pdfiumAvailable) {
    $env:PDFIUM_INCLUDE = "$clangDevRoot/pdfium/include"
    $env:PDFIUM_LIB     = "$clangDevRoot/pdfium/lib"
}

# SDL3 and zlib-ng are the two whose absence breaks the LINK step outright,
# so fail loudly here instead of letting lld-link emit five cryptic lines.
$requiredDeps = @(
    @{ Name = "SDL3";    Include = $env:SDL3_INCLUDE;    Lib = $env:SDL3_LIB },
    @{ Name = "zlib-ng"; Include = $env:ZLIB_NG_INCLUDE; Lib = $env:ZLIB_NG_LIB }
)
$missing = @()
foreach ($dep in $requiredDeps) {
    if (-not (Test-Path $dep.Include)) { $missing += "$($dep.Name) include ($($dep.Include))" }
    if (-not (Test-Path $dep.Lib))     { $missing += "$($dep.Name) lib ($($dep.Lib))" }
}
if ($missing.Count -gt 0) {
    Write-Host "`n### Missing required native dependencies under $DevRoot ###" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Red }
    throw "Set up the dependencies first (see setup-dev.ps1) or pass -DevRoot."
}

# Optional deps: warn only - the matching Swift targets degrade gracefully.
$optionalDeps = @(
    @{ Name = "libdxfrw";    Path = $env:DXFRW_INCLUDE },
    @{ Name = "libredwg";    Path = $env:DWG_INCLUDE },
    @{ Name = "vcpkg iconv"; Path = $env:ICONV_INCLUDE }
)
foreach ($opt in $optionalDeps) {
    if (-not (Test-Path $opt.Path)) {
        Write-Host "  note: $($opt.Name) not found at $($opt.Path) - related tests may skip" -ForegroundColor DarkYellow
    }
}

# -- 3. Visual Studio environment --------------------------------------
$vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsInstallerPath) {
    $vsPath = & $vsInstallerPath -latest -property installationPath
    $vcvarsPath = "$vsPath\VC\Auxiliary\Build\vcvarsall.bat"
} else {
    # Fall back to the known-good 2022 Community path.
    $vcvarsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
}
if (-not (Test-Path $vcvarsPath)) {
    throw "vcvarsall.bat not found at $vcvarsPath - install the MSVC ARM64/x64 build tools."
}

# -- 4. Swift 6.4 multi-toolchain workaround ---------------------------
# `swiftbuild` scans every Platform SDK under %LOCALAPPDATA%\Programs\Swift\
# Platforms and errors with "platform 'windows' already registered" when more
# than one version is installed. Mirror compile.ps1's fallback.
$swiftBuildSystemFlag = @()
$swiftPlatformsRoot = "$env:LOCALAPPDATA\Programs\Swift\Platforms"
if ((Test-Path $swiftPlatformsRoot) -and (@(Get-ChildItem $swiftPlatformsRoot -Directory).Count -gt 1)) {
    $platformVersions = (@(Get-ChildItem $swiftPlatformsRoot -Directory | Select-Object -ExpandProperty Name)) -join ', '
    Write-Host "Multiple Swift Platform SDKs found ($platformVersions) - using --build-system native" -ForegroundColor Yellow
    $swiftBuildSystemFlag = @("--build-system", "native")
}

# -- 5. Assemble the swift test command line ---------------------------
$effectiveArgs = @()
if ($TestArgs) { $effectiveArgs += $TestArgs }
if ($Filter)   { $effectiveArgs += @("--filter", $Filter) }
if ($SkipBuild) { $effectiveArgs += "--skip-build" }

# `--list-tests` is deprecated; the dedicated `swift test list` subcommand
# is the supported spelling and needs no test bundle linked at all.
if ($List) {
    $invocation = (@("swift", "test", "list", "--configuration", $Configuration) +
                    $swiftBuildSystemFlag) -join " "
} else {
    $invocation = (@("swift", "test", "--configuration", $Configuration) +
                    $swiftBuildSystemFlag +
                    $effectiveArgs) -join " "
}

# -- 6. Build the test bundle first ------------------------------------
# Compiling through a separate `swift build --build-tests` step surfaces
# compile errors cleanly (and populates the incremental cache) before the
# runner starts, instead of interleaving build noise with test output.
if (-not $SkipBuild -and -not $List) {
    $buildCommand = (@("swift build", "--configuration", $Configuration) +
                     $swiftBuildSystemFlag +
                     @("--build-tests", "-Xcc", "-I`"$($env:SDL3_INCLUDE)`"")) -join " "

    # Unique per process: concurrent runs must not rewrite each other's
    # wrapper while cmd.exe is blocked in it (stale byte offset -> cmd
    # executes a line fragment of the new content).
    $buildScript = "$env:TEMP\zephyr-test-build-$PID.cmd"
    Set-Content -Path $buildScript -Encoding ASCII -Value @(
        "@echo off",
        "cd /d `"$swiftBuildDir`"",
        "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
        $buildCommand,
        "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
    )

    Write-Host "`n### Building test bundle ($Configuration) ###" -ForegroundColor Cyan
    try {
        cmd.exe /c "`"$buildScript`""
        if ($LASTEXITCODE -ne 0) {
            throw "Test bundle build failed. (Link errors naming SDL3.lib / zng_* mean a missing -DevRoot dependency, not a code error.)"
        }
    } finally {
        Remove-Item -Path $buildScript -Force -ErrorAction SilentlyContinue
    }
}

# -- 7. Run the tests --------------------------------------------------
# `swift test` links the xctest runner, which needs the SDL/zlib DLLs on
# PATH at run time, so prepend the dependency lib dirs.
# Unique per process: see the wrapper-race note on $buildScript above.
$runScript = "$env:TEMP\zephyr-test-run-$PID.cmd"
Set-Content -Path $runScript -Encoding ASCII -Value @(
    "@echo off",
    "cd /d `"$swiftBuildDir`"",
    "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
    "set PATH=$clangDevRoot/SDL3/lib;$clangDevRoot/zlib-ng/lib;%PATH%",
    $invocation,
    "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
)

Write-Host "`n### Running: $invocation ###" -ForegroundColor Cyan
$timer = [System.Diagnostics.Stopwatch]::StartNew()
try {
    cmd.exe /c "`"$runScript`""
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -Path $runScript -Force -ErrorAction SilentlyContinue
}
$timer.Stop()

$elapsed = "{0:mm\:ss}" -f $timer.Elapsed
if ($exitCode -eq 0) {
    Write-Host "`n### Tests passed in $elapsed ###" -ForegroundColor Green
} else {
    Write-Host "`n### Tests FAILED in $elapsed (exit $exitCode) ###" -ForegroundColor Red
}
exit $exitCode
