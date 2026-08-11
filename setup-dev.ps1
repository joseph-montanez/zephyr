param (
    [string]$DevRoot = "C:\dev"
)

$ErrorActionPreference = "Stop"

# Version Definitions
$SDL3_VERSION = "3.4.12"
$SDL3_TTF_VERSION = "3.2.2"
$SDL3_IMAGE_VERSION = "3.4.4"
$ZLIB_NG_VERSION = "2.3.3"
$PDFIUM_TAG = "chromium%2F7891"

Write-Host "Using Development Root: $DevRoot" -ForegroundColor Green

# 1. Detect System Architecture
$hostArch = $env:PROCESSOR_ARCHITECTURE
if ($hostArch -eq "ARM64") {
    $cmakeArch    = "arm64"
    $vcpkgTriplet = "arm64-windows"
    $vcvarsArch   = "arm64"
    $libArch      = "ARM64"
    $zlibArch     = "arm64"
    $swiftTriple  = "aarch64-unknown-windows-msvc"
    $dxcArch      = "arm64"
    Write-Host "Detected ARM64 architecture. Configuring builds for Native ARM64." -ForegroundColor Cyan
} else {
    $cmakeArch    = "x64"
    $vcpkgTriplet = "x64-windows"
    $vcvarsArch   = "x64"
    $libArch      = "x64"
    $zlibArch     = "x86-64"
    $swiftTriple  = "x86_64-unknown-windows-msvc"
    $dxcArch      = "x64"
    Write-Host "Detected AMD64/x86_64 architecture. Configuring builds for x64." -ForegroundColor Cyan
}

if (-not (Test-Path $DevRoot)) {
    New-Item -ItemType Directory -Force -Path $DevRoot | Out-Null
}

# 2. Install / Locate Visual Studio Build Tools
Write-Host "`n--- Installing Visual Studio Build Tools ---" -ForegroundColor Yellow

$vsComponents = @(
    "Microsoft.VisualStudio.Component.Windows11SDK.22621",
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    "Microsoft.VisualStudio.Component.VC.CMake.Project"
)
$vsCustomArgs = ($vsComponents | ForEach-Object { "--add $_" }) -join " "

Write-Host "Installing Visual Studio 2022 Community with required components via winget..."
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom $vsCustomArgs --source winget

if ($LASTEXITCODE -ne 0) {
    throw "winget install of Visual Studio 2022 Community failed with exit code $LASTEXITCODE"
}

# Refresh environment PATH (winget may have added vswhere)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$vsInstallerPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsInstallerPath)) { throw "Visual Studio Installer (vswhere) not found after installation." }

$vsPath = & $vsInstallerPath -latest -products "Microsoft.VisualStudio.Product.Community" -version "[17.0,18.0)" -property installationPath
if (-not $vsPath) { throw "Could not locate Visual Studio 2022 Community installation." }

$cmakeExe = "$vsPath\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$vcvarsPath = "$vsPath\VC\Auxiliary\Build\vcvarsall.bat"

if (-not (Test-Path $cmakeExe) -or -not (Test-Path $vcvarsPath)) {
    throw "Required Visual Studio tools missing after install. Check that C++ CMake tools were included."
}
Write-Host "Found Visual Studio at: $vsPath" -ForegroundColor Cyan
Write-Host "Found vcvarsall.bat at: $vcvarsPath" -ForegroundColor Cyan


# 3. Setup Vcpkg & iconv
Write-Host "`n--- Setting up Vcpkg ---" -ForegroundColor Yellow
$vcpkgDir = "$DevRoot\vcpkg"
if (-not (Test-Path $vcpkgDir)) {
    Set-Location $DevRoot
    git clone https://github.com/microsoft/vcpkg.git
}
Set-Location $vcpkgDir
if (-not (Test-Path "$vcpkgDir\vcpkg.exe")) { .\bootstrap-vcpkg.bat }

$env:VCPKG_VISUAL_STUDIO_PATH = "C:\Program Files\Microsoft Visual Studio\2022\Community"
.\vcpkg.exe install "libiconv:$vcpkgTriplet"


# 4. Download and Install zlib-ng
Write-Host "`n--- Setting up zlib-ng ---" -ForegroundColor Yellow
$zlibRoot = "$DevRoot\zlib-ng"
New-Item -ItemType Directory -Force -Path "$zlibRoot\include" | Out-Null
New-Item -ItemType Directory -Force -Path "$zlibRoot\lib" | Out-Null

$zlibUrl = "https://github.com/zlib-ng/zlib-ng/releases/download/$ZLIB_NG_VERSION/zlib-ng-win-${zlibArch}.zip"
$zlibZip = "$env:TEMP\zlib-ng.zip"
Invoke-WebRequest -Uri $zlibUrl -OutFile $zlibZip
Expand-Archive -Path $zlibZip -DestinationPath "$env:TEMP\zlib_ext" -Force

$srcInclude = Get-ChildItem -Path "$env:TEMP\zlib_ext" -Recurse -Directory -Filter "include" | Select-Object -First 1
if ($srcInclude) { Copy-Item -Path "$($srcInclude.FullName)\*" -Destination "$zlibRoot\include" -Recurse -Force }

$srcLib = Get-ChildItem -Path "$env:TEMP\zlib_ext" -Recurse -Directory -Filter "lib" | Select-Object -First 1
if ($srcLib) { Copy-Item -Path "$($srcLib.FullName)\*" -Destination "$zlibRoot\lib" -Recurse -Force }


# 5. Setup SDL3 (Core, TTF, Image) and Generate Import Libs
Write-Host "`n--- Setting up SDL3 ---" -ForegroundColor Yellow
$sdlRoot = "$DevRoot\SDL3"
$sdlInclude = "$sdlRoot\include"
$sdlLib = "$sdlRoot\lib"
New-Item -ItemType Directory -Force -Path $sdlInclude | Out-Null
New-Item -ItemType Directory -Force -Path $sdlLib | Out-Null

function Generate-ImportLib {
    param($DllPath, $LibOut)
    $name = [IO.Path]::GetFileNameWithoutExtension($DllPath)
    $defPath = "$env:TEMP\$name.def"
    $exportsPath = "$env:TEMP\$name-exports.txt"
    $tmpBatch = "$env:TEMP\genlib-$name.cmd"

    Set-Content -Path $tmpBatch -Encoding ASCII -Value @(
        "@echo off",
        "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
        "dumpbin.exe /exports `"$DllPath`" > `"$exportsPath`" 2>&1",
        "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
    )
    cmd /c $tmpBatch

    $raw = Get-Content $exportsPath -Raw
    $funcs = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $funcs += $Matches[1] }
    }
    
    $deflines = @('EXPORTS') + ($funcs | ForEach-Object { "  $_" })
    [System.IO.File]::WriteAllLines($defPath, $deflines, [System.Text.Encoding]::ASCII)

    Set-Content -Path $tmpBatch -Encoding ASCII -Value @(
        "@echo off",
        "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
        "lib.exe /def:`"$defPath`" /machine:$libArch /out:`"$LibOut`"",
        "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
    )
    cmd /c $tmpBatch
    Write-Host "Generated: $LibOut"
}

function Install-SDLComponent {
    param($Name, $Version)
    $RepoName = $Name -replace '3', ''
    Write-Host "Downloading $Name v$Version from repo $RepoName..."
    
    $srcZip = "$env:TEMP\${Name}-src.zip"
    Invoke-WebRequest -Uri "https://github.com/libsdl-org/$RepoName/releases/download/release-$Version/${Name}-${Version}.zip" -OutFile $srcZip
    Expand-Archive -Path $srcZip -DestinationPath "$env:TEMP\${Name}_src" -Force
    $includeDir = Get-ChildItem -Path "$env:TEMP\${Name}_src" -Recurse -Directory -Filter $Name | Where-Object { $_.Parent.Name -eq "include" } | Select-Object -First 1
    if ($includeDir) { Copy-Item -Path "$($includeDir.FullName)" -Destination $sdlInclude -Recurse -Force }

    if ($Name -eq "SDL3") {
        $rootInc = Get-ChildItem -Path "$env:TEMP\${Name}_src" -Recurse -Directory -Filter "include" | Select-Object -First 1
        Copy-Item -Path "$($rootInc.FullName)\*.h" -Destination $sdlInclude -Force -ErrorAction SilentlyContinue
    }

    $binZip = "$env:TEMP\${Name}-bin.zip"
    Invoke-WebRequest -Uri "https://github.com/libsdl-org/$RepoName/releases/download/release-$Version/${Name}-${Version}-win32-${cmakeArch}.zip" -OutFile $binZip
    Expand-Archive -Path $binZip -DestinationPath "$env:TEMP\${Name}_bin" -Force
    $dll = Get-ChildItem -Path "$env:TEMP\${Name}_bin" -Recurse -Filter "${Name}.dll" | Select-Object -First 1
    if ($dll) {
        Copy-Item -Path $dll.FullName -Destination $sdlLib -Force
        Generate-ImportLib -DllPath "$sdlLib\${Name}.dll" -LibOut "$sdlLib\${Name}.lib"
    }
}

Install-SDLComponent -Name "SDL3" -Version $SDL3_VERSION
Install-SDLComponent -Name "SDL3_ttf" -Version $SDL3_TTF_VERSION
Install-SDLComponent -Name "SDL3_image" -Version $SDL3_IMAGE_VERSION


# 7.5 Setup PDFium
Write-Host "`n--- Setting up PDFium ---" -ForegroundColor Yellow
$pdfiumRoot = "$DevRoot\pdfium"
New-Item -ItemType Directory -Force -Path $pdfiumRoot | Out-Null

$pdfiumArch = if ($hostArch -eq "ARM64") { "win-arm64" } else { "win-x64" }
$pdfiumUrl = "https://github.com/bblanchon/pdfium-binaries/releases/download/$PDFIUM_TAG/pdfium-v8-$pdfiumArch.tgz"
$pdfiumTgz = "$env:TEMP\pdfium.tgz"

Write-Host "Downloading PDFium ($pdfiumArch)..."
Invoke-WebRequest -Uri $pdfiumUrl -OutFile $pdfiumTgz
tar -xzf $pdfiumTgz -C $pdfiumRoot
Remove-Item $pdfiumTgz -Force -ErrorAction SilentlyContinue


# 6. Build Zephyr
Write-Host "`n--- Compiling Zephyr ---" -ForegroundColor Yellow
$zephyrDir = "$DevRoot\zephyr"
if (-not (Test-Path $zephyrDir)) {
    Set-Location $DevRoot
    git clone https://github.com/joseph-montanez/zephyr.git
}

$swiftBuildDir = "$zephyrDir\Engine\EngineAsBuilt"
if (-not (Test-Path $swiftBuildDir)) {
    throw "Could not find $swiftBuildDir. Ensure the repository is cloned correctly."
}

$env:SDL3_INCLUDE       = "$DevRoot\SDL3\include" -replace '\\', '/'
$env:SDL3_LIB           = "$DevRoot\SDL3\lib" -replace '\\', '/'
$env:SDL3_IMAGE_INCLUDE = $env:SDL3_INCLUDE
$env:SDL3_IMAGE_LIB     = $env:SDL3_LIB
$env:SDL3_TTF_INCLUDE   = $env:SDL3_INCLUDE
$env:SDL3_TTF_LIB       = $env:SDL3_LIB

$env:ZLIB_NG_INCLUDE    = "$DevRoot\zlib-ng\include" -replace '\\', '/'
$env:ZLIB_NG_LIB        = "$DevRoot\zlib-ng\lib" -replace '\\', '/'

$env:ICONV_LIB          = "$vcpkgDir\installed\$vcpkgTriplet\lib" -replace '\\', '/'

$env:PDFIUM_INCLUDE     = "$DevRoot\pdfium\include" -replace '\\', '/'
$env:PDFIUM_LIB         = "$DevRoot\pdfium\lib" -replace '\\', '/'

$swiftBuildCmd = "swift build -c release -Xcc -I`"$env:SDL3_INCLUDE`""
$cmdScriptPath = "$env:TEMP\swift-build-local.cmd"
Set-Content -Path $cmdScriptPath -Encoding ASCII -Value @(
    "@echo off",
    "cd /d `"$swiftBuildDir`"",
    "call `"$vcvarsPath`" $vcvarsArch >nul 2>&1",
    $swiftBuildCmd,
    "if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%"
)

cmd.exe /c $cmdScriptPath

if ($LASTEXITCODE -ne 0) {
    throw "Zephyr build failed with exit code $LASTEXITCODE"
}


# 7. Stage DLLs and Compile Shaders
$config = "release"
$dllDest = "$swiftBuildDir\.build\$swiftTriple\$config"
New-Item -ItemType Directory -Path $dllDest -Force | Out-Null
Write-Host "`n### Staging Binaries to $dllDest ###" -ForegroundColor Yellow

$dxcCandidates = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter "dxc.exe" -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -match "\\$dxcArch$" }
if ($dxcCandidates) {
    $dxcPath = $dxcCandidates[0].FullName
    Write-Host "Compiling Shaders with DXC..."
    
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
    Write-Warning "dxc.exe not found. Shaders were not compiled."
}

# Copy DLLs
Copy-Item -Path "$DevRoot\SDL3\lib\SDL3.dll"       -Destination $dllDest -Force
Copy-Item -Path "$DevRoot\SDL3\lib\SDL3_image.dll" -Destination $dllDest -Force
Copy-Item -Path "$DevRoot\SDL3\lib\SDL3_ttf.dll"   -Destination $dllDest -Force

if (Test-Path "$DevRoot\pdfium\bin\pdfium.dll") { Copy-Item -LiteralPath "$DevRoot\pdfium\bin\pdfium.dll" -Destination $dllDest -Force }

Copy-Item -Path "$DevRoot\vcpkg\installed\$vcpkgTriplet\bin\iconv-2.dll" -Destination $dllDest -Force -ErrorAction SilentlyContinue

# Assets
foreach ($asset in @("Fonts", "Plot Styles")) {
    if (Test-Path "$swiftBuildDir\$asset") {
        $assetDest = "$dllDest\$asset"
        New-Item -ItemType Directory -Path $assetDest -Force | Out-Null
        Copy-Item -Path "$swiftBuildDir\$asset\*" -Destination $assetDest -Force -Recurse -ErrorAction SilentlyContinue
    }
}

Set-Location $zephyrDir
Write-Host "`nZephyr build completed successfully! Run with: .\$dllDest\Zephyr.exe" -ForegroundColor Green