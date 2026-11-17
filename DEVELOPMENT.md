# Development Setup

The fastest way to get started is by installing the system prerequisites and then running the automated setup script. The script automatically detects your system architecture (x64 or ARM64) and configures the C++ build environment and dependencies accordingly.

## 1. System Prerequisites

Run these commands in an elevated (Administrator) PowerShell or Command Prompt to install the required base tools.

**Install Visual Studio Build Tools & SDKs (Combined)**
```powershell
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --add Microsoft.VisualStudio.Component.VC.CMake.Project --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset" --source winget
```

**Install Swift Toolchain**
```powershell
winget install --id Swift.Toolchain -e --source winget
```

**Install Git**
```powershell
winget install --id Git.Git -e --source winget
```

*Note: You must close and reopen your terminal after installing these tools to ensure `git` and `swift` are loaded into your system PATH.*

## 2. Automated Workspace Setup

Once the prerequisites are installed, open a standard PowerShell terminal and run the following one-liner. This script will download and compile Vcpkg, zlib-ng, LibreDWG, PDFium, SDL3 (Core, Image, TTF), and finally build Zephyr.

```powershell
Invoke-Command -ScriptBlock ([Scriptblock]::Create((irm [https://raw.githubusercontent.com/joseph-montanez/zephyr/refs/heads/main/setup-dev.ps1](https://raw.githubusercontent.com/joseph-montanez/zephyr/refs/heads/main/setup-dev.ps1)))) -ArgumentList "C:\dev"
```
*You can change `"C:\dev"` to your preferred workspace directory (e.g., `"D:\workspace"`).*

## 3. Day-to-Day Compilation

The initial setup script prepares your workspace. For everyday development, rebuilding the engine, and compiling HLSL shaders via DXC, use the included `compile.ps1` script from the root of the repository.

To build a standard debug configuration:
```powershell
.\compile.ps1
```

To build a release configuration:
```powershell
.\compile.ps1 --release
```

*Note: If you installed your workspace to a directory other than `C:\dev`, pass the path via the `-DevRoot` parameter (e.g., `.\compile.ps1 -DevRoot "D:\workspace"`).*

## 4. IDE Setup

To work on the Swift files with correct inferencing, use `launch-vscode.bat` to open the project. This ensures the environment variables are loaded properly unless you prefer to configure Swift manually in your VS Code `settings.json`.

---

## Manual Setup Reference (Optional)

If you need to compile dependencies manually without the script, here is the reference guide assuming a `C:\dev` workspace and an `x64` machine. (Substitute `x64` with `arm64` if on a Snapdragon/ARM device).

**Build LibreDWG**
```powershell
cd C:\dev
git clone [https://github.com/LibreDWG/libredwg.git](https://github.com/LibreDWG/libredwg.git)
cd libredwg
git submodule update --init --recursive
mkdir build
cd build
cmake .. -G "Visual Studio 17 2022" -A x64 -DCMAKE_TOOLCHAIN_FILE="C:\dev\vcpkg\scripts\buildsystems\vcpkg.cmake" -DVCPKG_TARGET_TRIPLET=x64-windows -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release
```

**Setup SDL3, PDFium & zlib-ng**
SDL3, PDFium, and zlib-ng require downloading pre-built Windows binaries and (for SDL3) manually generating `.lib` import files using MSVC's `dumpbin` and `lib.exe` inside a `vcvarsall.bat` environment. It is highly recommended to rely on `setup-dev.ps1` to handle this step for you.

**Build Zephyr**
To build Zephyr manually, you must map the include and library paths for all dependencies to your environment variables and execute the Swift compiler within the Visual Studio developer environment:
```powershell
cd C:\dev\zephyr\Engine\EngineAsBuilt

# Map dependencies
$env:SDL3_INCLUDE = "C:\dev\SDL3\include"
$env:SDL3_LIB = "C:\dev\SDL3\lib"
# Note: You must also map DWG_INCLUDE, DWG_LIB, ZLIB_NG_INCLUDE, ZLIB_NG_LIB, PDFIUM_INCLUDE, PDFIUM_LIB

# Launch build via vcvarsall.bat to ensure the MSVC linker is available
cmd.exe /c "call `"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat`" x64 && swift build -c release -Xcc -I`"$env:SDL3_INCLUDE`""

---

## Linux (Ubuntu)

Target: Ubuntu 22.04 LTS / 24.04 LTS, x64 and ARM64. Release builds target
Ubuntu 22.04 (glibc 2.35) on CI for maximum compatibility across Ubuntu 22.04+,
Debian 12+, Fedora, Linux Mint, Pop!_OS, and Arch. On WSL2, no extra X server is needed: WSLg runs Linux GUI apps
(X11 and Wayland) out of the box after `wsl --update`, with GPU acceleration
via your vendor's GPU driver.

### 1. Install Swift

Use Swiftly, the official Swift installer for Linux (see
https://www.swift.org/install/linux/):

```bash
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && \
tar zxf swiftly-$(uname -m).tar.gz && \
./swiftly init --quiet-shell-followup && \
. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" && \
hash -r
swiftly install 6.4.1
```

### 2. Run the automated setup script

From the repo root (mirrors `setup-dev.ps1` on Windows). This installs system
packages, verifies Swift, and builds SDL3 3.4.18, SDL3_image 3.4.8,
SDL3_ttf 3.2.2, and zlib-ng 2.3.3 from their release tarballs into a dev root
(default `$HOME/dev`), plus PDFium and DXC:

```bash
./setup-linux.sh            # provision $HOME/dev
./setup-linux.sh ~/mydev    # override the dev root
```

If you already have the system packages (CI, containers), pass `--skip-apt`.
On ARM64 there is no DXC binary (upstream ships Linux x86_64 only), so
`compile-linux.sh` automatically falls back to `glslangValidator` (installed
by the setup script) with an equivalent binding layout. DXC remains the
reference compiler used by CI. If neither compiler is present, the build
succeeds but GPU pipelines cannot be created until `.spv` files are staged.

Manual reference (what the script does): `sudo apt-get install` build-essential,
git, cmake, ninja-build, pkg-config, the SDL3 X11/Wayland/audio dependencies
(`libx11-dev` … `libdecor-0-dev`, see `build-linux.yml` for the full list),
`libvulkan-dev`, `libpng-dev libjpeg-dev libwebp-dev libtiff-dev`, and
`libfreetype-dev libharfbuzz-dev`; then CMake-build each C dependency with
`-DCMAKE_INSTALL_PREFIX=$HOME/dev/<name>` (exact flags in
`.github/workflows/build-linux.yml`), download `pdfium-linux-x64.tgz` from
https://github.com/bblanchon/pdfium-binaries/releases (tag `chromium/7891`)
into `$HOME/dev/pdfium`, and download Linux DXC from
https://github.com/microsoft/DirectXShaderCompiler/releases.

### 3. Day-to-day compilation

From `Engine/EngineAsBuilt`:

```bash
./compile-linux.sh            # debug build into .build
./compile-linux.sh --release  # release build
./compile-linux.sh ~/dev      # override the dev root
```

The script exports the `SDL3_*`/`ZLIB_NG_*` paths, runs `swift build`,
compiles the HLSL shaders to SPIR-V with DXC, and stages the `.so` files,
shaders, fonts, plot styles, and patterns next to the `Zephyr` binary (which
finds them via `$ORIGIN` rpath, so no `LD_LIBRARY_PATH` is needed to run it).

### 4. Snap packaging

`snap/snapcraft.yaml` builds a strictly-confined snap for amd64 and arm64 on
a `core24` (Ubuntu 24.04) base. It drives the same `compile-linux.sh` CI uses,
so there is no second build path to keep in sync — only the pinned versions
(SDL3, Swift, DXC, PDFium), which must match `build-linux.yml`.

```bash
sudo snap install snapcraft --classic   # one-time provision
snapcraft                               # builds for the host arch
sudo snap install --dangerous zephyr_1.0_amd64.snap
```

Then run `zephyr` from any terminal, or launch it from the app grid. To open
drawings from USB drives and other mounts outside `$HOME`:

```bash
sudo snap connect zephyr:removable-media
```

Publishing to the Snap Store (name `zephyr` is currently unregistered):

```bash
snapcraft login
snapcraft register zephyr
snapcraft upload zephyr_1.0_amd64.snap --release=edge
```

Notes:

- Build one snap per architecture on native hardware (or matching CI
  runners); the Swift toolchain, DXC-vs-glslang choice, and PDFium asset are
  selected per target arch inside the snap file.
- The snap bundles the Swift runtime and the SDL3/zlib-ng/PDFium libraries;
  system libraries (X11/Wayland clients, audio, Vulkan loader, image codecs)
  come from `stage-packages`, whose list was audited against the built
  binaries with `readelf`/`strings` — re-run that audit if SDL is upgraded.
- Settings and `imgui.ini` live under the snap's private data dir
  (`~/snap/zephyr/...`), so the read-only squashfs is never written to.
- The in-app ODA File Converter installer downloads and executes an external
  installer, which strict confinement blocks; that menu action reports an
  error inside the snap. Everything else is unaffected.
- `snap/gui/zephyr.png` is a placeholder badge until the real logo lands;
  `snap/gui/zephyr.svg` next to it is the editable source.
```

### 5. AppImage packaging

AppImage builds are produced automatically by CI (`.github/workflows/build-linux.yml`) for `x86_64` and `aarch64`. The bundle is self-contained: it includes the `Zephyr` binary, SDL3, zlib-ng, PDFium, SPIR-V shaders, fonts, patterns, plot styles, and the Swift runtime libraries.

To build an AppImage locally (requires `appimagetool` and an existing `./compile-linux.sh --release` build):

```bash
# 1. Download appimagetool for your architecture (x86_64 or aarch64)
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) TOOL_ARCH="x86_64" ;;
  aarch64|arm64) TOOL_ARCH="aarch64" ;;
esac
curl -sSL -o appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${TOOL_ARCH}.AppImage"
chmod +x appimagetool

# 2. Stage AppDir
mkdir -p Zephyr.AppDir/usr/bin Zephyr.AppDir/usr/lib Zephyr.AppDir/usr/share/applications Zephyr.AppDir/usr/share/icons/hicolor/256x256/apps Zephyr.AppDir/usr/share/icons/hicolor/scalable/apps Zephyr.AppDir/usr/share/metainfo
cp packaging/appimage/AppRun Zephyr.AppDir/AppRun && chmod +x Zephyr.AppDir/AppRun
cp packaging/shared/com.zephyr.cad.desktop Zephyr.AppDir/com.zephyr.cad.desktop
cp packaging/shared/com.zephyr.cad.desktop Zephyr.AppDir/usr/share/applications/
cp snap/gui/zephyr.png Zephyr.AppDir/com.zephyr.cad.png
cp snap/gui/zephyr.png Zephyr.AppDir/usr/share/icons/hicolor/256x256/apps/com.zephyr.cad.png
cp snap/gui/zephyr.svg Zephyr.AppDir/usr/share/icons/hicolor/scalable/apps/com.zephyr.cad.svg
cp packaging/shared/com.zephyr.cad.metainfo.xml Zephyr.AppDir/usr/share/metainfo/
# Copy build outputs from Engine/EngineAsBuilt/.build/... to Zephyr.AppDir/usr/bin/ and .so to Zephyr.AppDir/usr/lib/

# 3. Create the AppImage
ARCH="$TOOL_ARCH" ./appimagetool --appimage-extract-and-run Zephyr.AppDir "Zephyr-Linux-${ARCH}.AppImage"
```

To run the AppImage:
```bash
chmod +x Zephyr-Linux-x64.AppImage
./Zephyr-Linux-x64.AppImage
```

### 6. Flatpak packaging

`packaging/flatpak/com.zephyr.cad.yml` defines the Flatpak package based on the Freedesktop 25.08 runtime (`org.freedesktop.Platform//25.08` and `org.freedesktop.Sdk//25.08`). CI produces standalone `.flatpak` bundles (`Zephyr-Linux-x64.flatpak` and `Zephyr-Linux-arm64.flatpak`) for x86_64 and aarch64.

To install a `.flatpak` bundle produced by CI:

```bash
flatpak install --user Zephyr-Linux-x64.flatpak
flatpak run com.zephyr.cad
```

To build locally using `flatpak-builder` (requires a staged payload in `packaging/flatpak/payload`):

```bash
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08

flatpak-builder --force-clean --repo=repo build-dir packaging/flatpak/com.zephyr.cad.yml
flatpak build-bundle repo Zephyr.flatpak com.zephyr.cad
```

