

## Windows Setup

Install iconv for Windows using vcpkg:

    git clone https://github.com/microsoft/vcpkg.git
    cd vcpkg
    bootstrap-vcpkg.bat
    set VCPKG_VISUAL_STUDIO_PATH=C:\Program Files\Microsoft Visual Studio\2022\Community
    vcpkg install libiconv:arm64-windows

Download LibDXFRW

    https://github.com/codelibs/libdxfrw
    cd libdxfrw
    mkdir build
    cd build
    cmake .. -G "Visual Studio 17 2022" -A arm64 -DCMAKE_TOOLCHAIN_FILE="C:\dev\vcpkg\scripts\buildsystems\vcpkg.cmake"
    cmake --build . --config Release