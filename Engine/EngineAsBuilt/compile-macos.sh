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
export DWG_INCLUDE=/Users/josephmontanez/Documents/dev/libredwg/build/include
export DWG_LIB=/Users/josephmontanez/Documents/dev/libredwg/build/lib
export DWG_SRC=/Users/josephmontanez/Documents/dev/libredwg/src
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
echo "### Copying Shaders, Fonts, and Plot Styles to build output... ###"
BUILD_DIR=".build/debug"
if [ "$CONFIG" = "release" ]; then
    BUILD_DIR=".build/release"
fi
mkdir -p "$BUILD_DIR"
cp -R Fonts "$BUILD_DIR/"
cp -R "Plot Styles" "$BUILD_DIR/" || true
cp -R Patterns "$BUILD_DIR/" || true
cp -R lisp "$BUILD_DIR/" || true
cp Shaders/*.msl "$BUILD_DIR/"
# Stage the MCP stdio bridge (Tools/mcp-bridge.py) next to the binary.
mkdir -p "$BUILD_DIR/Tools"
cp Tools/mcp-bridge.py "$BUILD_DIR/Tools/"
chmod +x "$BUILD_DIR/Tools/mcp-bridge.py"
if [ -f "libpdfium.dylib" ]; then
    cp libpdfium.dylib "$BUILD_DIR/"
fi
echo "Resources copied to $BUILD_DIR"

# ------------------------------------------------------------------
# Assemble a launchable Zephyr.app for local dev. A bare binary has
# no LaunchServices registration, so the WindowServer may never make
# its window key on first launch (permanently input-dead window).
# The bundle mirrors the CI release recipe (.github/workflows/
# build-macos.yml) with one deliberate difference: resources sit next
# to the executable (Contents/MacOS) because the app resolves
# Fonts/lisp/Patterns relative to Bundle.main.executableURL.
# ------------------------------------------------------------------
APP_ROOT="$BUILD_DIR/Zephyr.app"
APP_MACOS="$APP_ROOT/Contents/MacOS"
echo ""
echo "### Assembling $APP_ROOT ... ###"
rm -rf "$APP_ROOT"
mkdir -p "$APP_MACOS"
cp "$BUILD_DIR/Zephyr" "$APP_MACOS/Zephyr"
cp -R Fonts "$APP_MACOS/"
cp -R "Plot Styles" "$APP_MACOS/" || true
cp -R Patterns "$APP_MACOS/" || true
cp -R lisp "$APP_MACOS/" || true
cp Shaders/*.msl "$APP_MACOS/"
mkdir -p "$APP_MACOS/Tools"
cp Tools/mcp-bridge.py "$APP_MACOS/Tools/"
chmod +x "$APP_MACOS/Tools/mcp-bridge.py"
if [ -f "libpdfium.dylib" ]; then
    cp libpdfium.dylib "$APP_MACOS/"
fi
cat > "$APP_ROOT/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleExecutable</key>
    <string>Zephyr</string>
    <key>CFBundleName</key>
    <string>Zephyr</string>
    <key>CFBundleIdentifier</key>
    <string>com.zephyr.cad</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLISTEOF
echo "Bundle assembled at $APP_ROOT"
echo ""
echo "### Build complete! ###"
echo "Run as app (recommended on macOS): open $BUILD_DIR/Zephyr.app"
echo "Run as bare binary:                $BUILD_DIR/Zephyr"
