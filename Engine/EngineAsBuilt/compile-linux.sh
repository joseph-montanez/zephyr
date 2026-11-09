#!/bin/bash
# compile-linux.sh
# Linux equivalent of compile.ps1 (see also compile-macos.sh).
# Usage: ./compile-linux.sh [--release] [DEV_ROOT]
#
# DEV_ROOT holds the prebuilt C dependencies in the same split layout as
# compile.ps1 (default: $HOME/dev):
#   $DEV_ROOT/SDL3/include, $DEV_ROOT/SDL3/lib
#   $DEV_ROOT/zlib-ng/include, $DEV_ROOT/zlib-ng/lib
#   $DEV_ROOT/pdfium/lib/libpdfium.so   (optional: PDF import is disabled when absent)
#
# Prerequisites: Swift toolchain on PATH (e.g. via Swiftly), a C/C++ toolchain,
# SDL3 build dependencies (see DEVELOPMENT.md), and optionally `dxc` on PATH
# (or $DXC) for compiling the HLSL shaders to SPIR-V.
set -e

CONFIG="debug"
DEV_ROOT="${DEV_ROOT:-$HOME/dev}"
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) DEV_ROOT="$arg" ;;
    esac
done

# Resolve the Swift package dir (like compile.ps1: runnable from repo root or here)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/Package.swift" ]; then
    SWIFT_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/Engine/EngineAsBuilt/Package.swift" ]; then
    SWIFT_DIR="$SCRIPT_DIR/Engine/EngineAsBuilt"
else
    echo "Could not find Package.swift under $SCRIPT_DIR" >&2
    exit 1
fi

echo "### Building $CONFIG configuration (DEV_ROOT=$DEV_ROOT) ###"

command -v swift >/dev/null 2>&1 || {
    echo "swift not found on PATH. Install it via Swiftly (see DEVELOPMENT.md)." >&2
    exit 1
}

export SDL3_INCLUDE="$DEV_ROOT/SDL3/include"
export SDL3_LIB="$DEV_ROOT/SDL3/lib"
export SDL3_IMAGE_INCLUDE="$SDL3_INCLUDE"
export SDL3_IMAGE_LIB="$SDL3_LIB"
export SDL3_TTF_INCLUDE="$SDL3_INCLUDE"
export SDL3_TTF_LIB="$SDL3_LIB"
export ZLIB_NG_INCLUDE="$DEV_ROOT/zlib-ng/include"
export ZLIB_NG_LIB="$DEV_ROOT/zlib-ng/lib"

[ -d "$SDL3_INCLUDE/SDL3" ] || echo "WARNING: $SDL3_INCLUDE/SDL3 not found."
[ -f "$SDL3_LIB/libSDL3.so" ] || echo "WARNING: $SDL3_LIB/libSDL3.so not found."
[ -f "$ZLIB_NG_LIB/libz-ng.so" ] || echo "WARNING: $ZLIB_NG_LIB/libz-ng.so not found."

# PDFium is loaded at runtime via dlopen (never linked); stage it when present.
PDFIUM_SO=""
for candidate in "$DEV_ROOT/pdfium/lib/libpdfium.so" "$DEV_ROOT/pdfium/libpdfium.so"; do
    if [ -f "$candidate" ]; then PDFIUM_SO="$candidate"; break; fi
done
[ -n "$PDFIUM_SO" ] || echo "WARNING: libpdfium.so not found under $DEV_ROOT/pdfium. PDF import will be unavailable."

# -rpath $ORIGIN lets the binary find the staged .so files next to it.
# shellcheck disable=SC2086
(
    cd "$SWIFT_DIR" && swift build -c "$CONFIG" \
        -Xcc "-I$SDL3_INCLUDE" \
        -Xcc "-I$ZLIB_NG_INCLUDE" \
        -Xlinker -rpath -Xlinker '$ORIGIN'
)
echo "Swift build succeeded."

# Locate the freshly built executable (layout varies by SwiftPM version)
BIN_PATH="$(find "$SWIFT_DIR/.build" -name Zephyr -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
[ -n "$BIN_PATH" ] || { echo "Zephyr executable not found under $SWIFT_DIR/.build" >&2; exit 1; }
BIN_DIR="$(dirname "$BIN_PATH")"
echo "### Staging runtime files to $BIN_DIR ###"

# Compile HLSL shaders to SPIR-V (flags mirror SDL_shadercross HLSL->SPIRV)
DXC="${DXC:-$(command -v dxc || true)}"
GLSLANG="$(command -v glslangValidator || true)"
compile_shaders_dxc() {
    echo "Compiling shaders with $DXC..."
    SPV_FLAGS="-spirv -fspv-flatten-resource-arrays -fspv-preserve-bindings -fspv-preserve-interface"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T vs_6_0 -E main -Fo "$BIN_DIR/cad.vert.spv"   "$SWIFT_DIR/Shaders/cad.vert.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T ps_6_0 -E main -Fo "$BIN_DIR/cad.frag.spv"   "$SWIFT_DIR/Shaders/cad.frag.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T ps_6_0 -E main -Fo "$BIN_DIR/cad_aa.frag.spv" "$SWIFT_DIR/Shaders/cad_aa.frag.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T vs_6_0 -E main -Fo "$BIN_DIR/imgui.vert.spv" "$SWIFT_DIR/Shaders/imgui.vert.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T ps_6_0 -E main -Fo "$BIN_DIR/imgui.frag.spv" "$SWIFT_DIR/Shaders/imgui.frag.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T vs_6_0 -E main -Fo "$BIN_DIR/cad_id.vert.spv" "$SWIFT_DIR/Shaders/cad_id.vert.hlsl"
    # shellcheck disable=SC2086
    "$DXC" $SPV_FLAGS -T ps_6_0 -E main -Fo "$BIN_DIR/cad_id.frag.spv" "$SWIFT_DIR/Shaders/cad_id.frag.hlsl"
    echo "Shaders compiled."
}
compile_shaders_glslang() {
    echo "Compiling shaders with $GLSLANG..."
    "$GLSLANG" -D -V -S vert -e main -o "$BIN_DIR/cad.vert.spv"   "$SWIFT_DIR/Shaders/cad.vert.hlsl"
    "$GLSLANG" -D -V -S frag -e main -o "$BIN_DIR/cad.frag.spv"   "$SWIFT_DIR/Shaders/cad.frag.hlsl"
    "$GLSLANG" -D -V -S frag -e main -o "$BIN_DIR/cad_aa.frag.spv" "$SWIFT_DIR/Shaders/cad_aa.frag.hlsl"
    "$GLSLANG" -D -V -S vert -e main -o "$BIN_DIR/imgui.vert.spv" "$SWIFT_DIR/Shaders/imgui.vert.hlsl"
    "$GLSLANG" -D -V -S frag -e main -o "$BIN_DIR/imgui.frag.spv" "$SWIFT_DIR/Shaders/imgui.frag.hlsl"
    "$GLSLANG" -D -V -S vert -e main -o "$BIN_DIR/cad_id.vert.spv" "$SWIFT_DIR/Shaders/cad_id.vert.hlsl"
    "$GLSLANG" -D -V -S frag -e main -o "$BIN_DIR/cad_id.frag.spv" "$SWIFT_DIR/Shaders/cad_id.frag.hlsl"
    echo "Shaders compiled."
}
if [ -n "$DXC" ] && [ -x "$DXC" ]; then
    compile_shaders_dxc
elif [ -n "$GLSLANG" ] && [ -x "$GLSLANG" ]; then
    echo "NOTE: dxc not found; using glslangValidator fallback instead."
    echo "DXC remains the reference compiler (used by CI); verify with it before release."
    compile_shaders_glslang
else
    echo "WARNING: neither dxc nor glslangValidator found. Skipping shader compilation;"
    echo "the app will fail to create GPU pipelines until .spv files are staged."
fi

# Stage shared libraries next to the binary (dereferenced, self-contained dir)
cp -L "$SDL3_LIB"/libSDL3*.so* "$BIN_DIR/" 2>/dev/null || echo "WARNING: no libSDL3*.so* staged."
cp -L "$ZLIB_NG_LIB"/libz-ng.so* "$BIN_DIR/" 2>/dev/null || echo "WARNING: no libz-ng.so* staged."
[ -n "$PDFIUM_SO" ] && cp -L "$PDFIUM_SO" "$BIN_DIR/"

# Stage Fonts, Plot Styles, Patterns
for asset in "Fonts" "Plot Styles" "Patterns" "lisp"; do
    if [ -d "$SWIFT_DIR/$asset" ]; then
        rm -rf "$BIN_DIR/$asset"
        cp -R "$SWIFT_DIR/$asset" "$BIN_DIR/"
    fi
done

# Stage the MCP stdio bridge (Tools/mcp-bridge.py) next to the binary.
if [ -f "$SWIFT_DIR/Tools/mcp-bridge.py" ]; then
    mkdir -p "$BIN_DIR/Tools"
    cp -L "$SWIFT_DIR/Tools/mcp-bridge.py" "$BIN_DIR/Tools/"
    chmod +x "$BIN_DIR/Tools/mcp-bridge.py"
fi

echo ""
echo "### Build complete. Run with: $BIN_PATH ###"
