#!/bin/bash
# macos_ext.sh
# Sets environment variables for zlib-ng and builds the package.
# Run this from inside the SwiftZLibNG directory.
#
# Prerequisites:
#   zlib-ng installed via Homebrew: brew install zlib-ng

set -e

# Paths to zlib-ng (Homebrew default)
export ZLIB_NG_INCLUDE="${ZLIB_NG_INCLUDE:-$(brew --prefix zlib-ng)/include}"
export ZLIB_NG_LIB="${ZLIB_NG_LIB:-$(brew --prefix zlib-ng)/lib}"

echo "ZLIB_NG_INCLUDE=$ZLIB_NG_INCLUDE"
echo "ZLIB_NG_LIB=$ZLIB_NG_LIB"

swift build -c debug "$@"

echo "### SwiftZLibNG build complete. ###"
