
$env:DXFRW_INCLUDE = "C:/dev/libdxfrw/src"
$env:DXFRW_LIB = "C:/dev/libdxfrw/build/Release"

swift build -c debug -vv -Xcc "-I$($env:DXFRW_INCLUDE)"
