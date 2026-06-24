// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Zephyr",
    platforms: [.macOS(.v11), .iOS(.v13)],
    products: [
        .library(name: "ZephyrCore", targets: ["ZephyrCore"]),
        .executable(name: "Zephyr", targets: ["Zephyr"]),
    ],
    dependencies: [
        .package(name: "SwiftSDL", path: "../SwiftSDL"),
        .package(name: "SwiftSDL_image", path: "../SwiftSDL_image"),
        .package(name: "SwiftSDL_ttf", path: "../SwiftSDL_ttf"),
        .package(name: "SwiftImGui", path: "../SwiftImGui"),
        .package(name: "SwiftDXFrw", path: "../SwiftDXFrw"),
        .package(name: "SwiftZLibNG", path: "../SwiftZLibNG"),
    ],
    targets: [
        .target(
            name: "ZephyrCore",
            dependencies: [
                .product(name: "CDXFRW", package: "SwiftDXFrw"),
                .product(name: "CZLibNG", package: "SwiftZLibNG"),
                .product(name: "CSDL3", package: "SwiftSDL"),
                .product(name: "SwiftSDL", package: "SwiftSDL"),
                .product(name: "SwiftSDL_image", package: "SwiftSDL_image"),
                .product(name: "SwiftSDL_ttf", package: "SwiftSDL_ttf"),
                .product(name: "ImGui", package: "SwiftImGui"),
            ],
            path: "Sources/ZephyrCore"
        ),
        .executableTarget(
            name: "Zephyr",
            dependencies: [
                "ZephyrCore",
                .product(name: "ImGui", package: "SwiftImGui"),
            ],
            path: "Sources/Zephyr"
        ),
        .testTarget(
            name: "ZephyrTests",
            dependencies: ["ZephyrCore"],
            path: "Tests/ZephyrTests"
        ),
    ]
)
