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
```