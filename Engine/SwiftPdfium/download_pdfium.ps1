# download_pdfium.ps1
# Downloads prebuilt PDFium binaries for Windows from bblanchon/pdfium-binaries
# and sets PDFIUM_INCLUDE / PDFIUM_LIB environment variables.
#
# Usage:  .\download_pdfium.ps1
#   or:   .\download_pdfium.ps1 -DestDir "D:\libs\pdfium"
#   or:   .\download_pdfium.ps1 -Tag "chromium%2F7891"
#
# After running, rebuild and PDF import will work on Windows.

param(
    [string]$DestDir = "C:\dev\pdfium",
    [string]$Tag = "chromium%2F7891"
)

$ErrorActionPreference = "Continue"

Write-Host "=== PDFium Binary Downloader ==="
Write-Host "Destination: ${DestDir}"
Write-Host "Tag:         ${Tag}"
Write-Host ""

# Determine platform
$arch = $env:PROCESSOR_ARCHITECTURE
Write-Host "Detected architecture: $arch"

if ($arch -eq "ARM64") {
    $platform = "win-arm64"
} elseif ($arch -eq "AMD64") {
    $platform = "win-x64"
} else {
    Write-Host "ERROR: Unsupported architecture: $arch"
    Write-Host "Manual download: https://github.com/bblanchon/pdfium-binaries/releases"
    exit 1
}

$filename = "pdfium-v8-${platform}.tgz"
$url = "https://github.com/bblanchon/pdfium-binaries/releases/download/${Tag}/${filename}"

Write-Host "Platform:    ${platform}"
Write-Host "File:        ${filename}"
Write-Host "URL:         ${url}"
Write-Host ""

# Download
$tgzPath = Join-Path $env:TEMP $filename
Write-Host "Downloading..."

try {
    Invoke-WebRequest -Uri $url -OutFile $tgzPath -ErrorAction Stop
} catch {
    Write-Host "ERROR: Download failed: $_"
    Write-Host ""
    Write-Host "Manual download:"
    Write-Host "  1. Go to: https://github.com/bblanchon/pdfium-binaries/releases"
    Write-Host "  2. Find the latest release and download: ${filename}"
    Write-Host "  3. Extract to: ${DestDir}"
    Write-Host ""
    Write-Host "Or try a different tag:"
    Write-Host "  .\download_pdfium.ps1 -Tag 'chromium%2FXXXX'"
    exit 1
}

$sizeMB = [math]::Round((Get-Item $tgzPath).Length / 1MB, 1)
Write-Host "Downloaded: ${sizeMB} MB"

# Extract
Write-Host "Extracting to: ${DestDir}"
New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
Remove-Item -Path "${DestDir}\*" -Recurse -Force -ErrorAction SilentlyContinue

try {
    tar -xzf $tgzPath -C $DestDir
    if ($LASTEXITCODE -ne 0) { throw "tar exited with code ${LASTEXITCODE}" }
} catch {
    Write-Host "ERROR: Extraction failed: $_"
    Write-Host "Try: tar -xzf ${tgzPath} -C ${DestDir}"
    exit 1
}

Write-Host "Extraction complete."

# Verify
Write-Host ""
Write-Host "Verifying..."

$libFile = Get-ChildItem -Recurse $DestDir -Filter "pdfium.dll.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
$includeFile = Get-ChildItem -Recurse $DestDir -Filter "fpdfview.h" -ErrorAction SilentlyContinue | Select-Object -First 1
$dllFile = Get-ChildItem -Recurse $DestDir -Filter "pdfium.dll" -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $libFile -or -not $includeFile) {
    Write-Host "ERROR: Expected files not found."
    Write-Host "Contents of ${DestDir}:"
    Get-ChildItem -Recurse -Depth 3 $DestDir -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.FullName)" }
    exit 1
}

$libDir = $libFile.DirectoryName
$includeDir = $includeFile.DirectoryName

Write-Host "  Library:  ${libDir}"
Write-Host "  Headers:  ${includeDir}"
if ($dllFile) { Write-Host "  DLL:      $($dllFile.FullName)" }

# Copy DLL to the build output so it's found at runtime
$dllDest = ".build\aarch64-unknown-windows-msvc\debug"
if ($dllFile -and (Test-Path $dllDest)) {
    Copy-Item -Path $dllFile.FullName -Destination $dllDest -Force
    Write-Host "  DLL copied to: ${dllDest}"
}

# Set env vars
$env:PDFIUM_INCLUDE = $includeDir
$env:PDFIUM_LIB     = $libDir

Write-Host ""
Write-Host "=== SUCCESS ==="
Write-Host "PDFIUM_INCLUDE = ${includeDir}"
Write-Host "PDFIUM_LIB     = ${libDir}"
Write-Host ""
Write-Host "compile.ps1 will auto-detect these when C:\dev\pdfium\include\fpdfview.h exists."
Write-Host "Run:  cd Engine\EngineAsBuilt && .\compile.ps1"

# Cleanup
Remove-Item $tgzPath -Force -ErrorAction SilentlyContinue
