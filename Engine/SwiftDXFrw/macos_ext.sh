# Set environment variables (replace paths with your actual macOS paths)
export DXFRW_INCLUDE="/opt/homebrew/include"
export DXFRW_LIB="/opt/homebrew/lib"

# Run the swift build command
swift build -c release -vv -Xcc "-I${DXFRW_INCLUDE}"
