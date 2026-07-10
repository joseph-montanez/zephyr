// swift-tools-version: 6.2.0
import Foundation
import PackageDescription

// --- Read Environment Variables ---
let env = ProcessInfo.processInfo.environment
let iconvIncludePath = env["ICONV_INCLUDE"]
let iconvLibraryPath = env["ICONV_LIB"]

// --- Prepare Settings ---
var ciconvCSettings: [CSetting] = []
var ciconvSwiftSettings: [SwiftSetting] = []
var ciconvLinkerSettings: [LinkerSetting] = []

// --- Platform Specific Settings ---
#if os(Windows)
    if let includePath = iconvIncludePath {
        ciconvCSettings.append(.unsafeFlags(["-I", includePath]))
        ciconvSwiftSettings.append(.unsafeFlags(["-Xcc", "-I", "-Xcc", "\(includePath)"]))
    }
    if let libPath = iconvLibraryPath {
        ciconvLinkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }
    ciconvLinkerSettings.append(.linkedLibrary("iconv"))
#elseif os(macOS)
    // iconv is a system library on macOS - just link it
    ciconvLinkerSettings.append(.linkedLibrary("iconv"))
#elseif os(Linux)
    // On Linux, iconv may be part of glibc or separate
    if let includePath = iconvIncludePath {
        ciconvCSettings.append(.unsafeFlags(["-I", includePath]))
    }
    if let libPath = iconvLibraryPath {
        ciconvLinkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }
    ciconvLinkerSettings.append(.linkedLibrary("iconv"))
#endif

let package = Package(
    name: "SwiftDXFrw",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SwiftDXFrw", targets: ["SwiftDXFrw"]),
    ],
    targets: [
        // C module wrapping iconv (cross-platform)
        .target(
            name: "CIconv",
            path: "Dependencies/CIconv",
            publicHeadersPath: ".",
            cSettings: ciconvCSettings,
            swiftSettings: ciconvSwiftSettings,
            linkerSettings: ciconvLinkerSettings
        ),
        // Pure Swift DXF reader/writer target
        .target(
            name: "SwiftDXFrw",
            dependencies: ["CIconv"],
            path: "Sources/SwiftDXFrw",
            swiftSettings: ciconvSwiftSettings + [
                .enableExperimentalFeature("StrictConcurrency=complete"),
            ]
        ),
    ]
)
