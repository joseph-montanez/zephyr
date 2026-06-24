
$env:SDL3_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_LIB = "C:/dev/SDL3/lib/arm64"
$env:SDL3_TTF_INCLUDE = "C:/dev/SDL3/include"
$env:SDL3_TTF_LIB = "C:/dev/SDL3/lib/arm64"

swift build -c debug -vv -Xcc "-I$($env:SDL3_INCLUDE)"