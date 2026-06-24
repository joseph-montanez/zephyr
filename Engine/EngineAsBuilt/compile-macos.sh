#!/bin/bash
# compile-macos.sh
# Usage: ./compile-macos.sh [--release]

CONFIG="debug"
if [ "$1" = "--release" ]; then
    CONFIG="release"
    echo "### Building RELEASE configuration ###"
else
    echo "### Building DEBUG configuration ###"
fi

export SDL3_INCLUDE=/opt/homebrew/include
export SDL3_LIB=/opt/homebrew/lib
export SDL3_IMAGE_INCLUDE=/opt/homebrew/include
export SDL3_IMAGE_LIB=/opt/homebrew/lib
export SDL3_TTF_INCLUDE=/opt/homebrew/include
export SDL3_TTF_LIB=/opt/homebrew/lib
export DXFRW_INCLUDE=/Users/josephmontanez/Documents/dev/libdxfrw/src
export DXFRW_LIB=/Users/josephmontanez/Documents/dev/libdxfrw/build
export ZLIB_NG_INCLUDE=/opt/homebrew/include
export ZLIB_NG_LIB=/opt/homebrew/lib
export CPATH=/opt/homebrew/include
export MACOSX_DEPLOYMENT_TARGET=12.0

xcrun swift build -c "$CONFIG"
BUILD_STATUS=$?

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "ERROR: Swift build failed!"
    exit "$BUILD_STATUS"
fi

echo ""
echo "### Copying Shaders and Fonts to build output... ###"
BUILD_DIR=".build/debug"
if [ "$CONFIG" = "release" ]; then
    BUILD_DIR=".build/release"
fi
mkdir -p "$BUILD_DIR"
cp -R Fonts "$BUILD_DIR/"
cp Shaders/*.msl "$BUILD_DIR/"
if [ -f "libpdfium.dylib" ]; then
    cp libpdfium.dylib "$BUILD_DIR/"
fi
echo "Fonts and shaders copied to $BUILD_DIR"
echo ""
echo "### Build complete! Run with: $BUILD_DIR/EngineAsBuilt ###"
