// swift-tools-version: 6.2.0
import Foundation  // Required for ProcessInfo
import PackageDescription

// --- Read Environment Variables ---
let env = ProcessInfo.processInfo.environment
let dxfrwIncludePath = env["DXFRW_INCLUDE"]
let dxfrwLibraryPath = env["DXFRW_LIB"]

// --- Diagnostic Print ---
print("--- SwiftDXFrw Manifest Diagnostic ---")
print("DXFRW_INCLUDE env var is: \(dxfrwIncludePath ?? "NOT SET")")
print("DXFRW_LIB env var is: \(dxfrwLibraryPath ?? "NOT SET")")
print("--------------------------------------")

// --- Prepare Settings ---
var cxxSettings: [CXXSetting] = []
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = []

// --- Platform Specific Settings ---
// SPM defines DEBUG=1 in debug builds, but libdxfrw uses DEBUG as an identifier.
// Undefine it so the C++ bridge compiles cleanly.
cxxSettings.append(.unsafeFlags(["-U", "DEBUG"]))

#if os(macOS)
    // --- libdxfrw Include Path ---
    if let includePath = dxfrwIncludePath {
        cxxSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    } else {
        // Fallback: check common Homebrew paths
        let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        cxxSettings.append(.unsafeFlags(["-I", "\(brewPrefix)/include"]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"]))
    }

    // --- libdxfrw Library Path ---
    if let libPath = dxfrwLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    } else {
        let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        linkerSettings.append(.unsafeFlags(["-L\(brewPrefix)/lib"]))
    }

    linkerSettings.append(.linkedLibrary("dxfrw"))
    // iconv is a system library on macOS
    linkerSettings.append(.linkedLibrary("iconv"))

#elseif os(Windows)
    // --- libdxfrw Include Path ---
    if let includePath = dxfrwIncludePath {
        cxxSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I", "-Xcc", "\(includePath)"]))
    }

    // --- libdxfrw Library Path ---
    if let libPath = dxfrwLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }

    // --- iconv Library Path (vcpkg on Windows) ---
    if let iconvLibPath = ProcessInfo.processInfo.environment["ICONV_LIB"] {
        linkerSettings.append(.unsafeFlags(["-L\(iconvLibPath)"]))
    }

    linkerSettings.append(.linkedLibrary("dxfrw"))
    linkerSettings.append(.linkedLibrary("iconv"))

#elseif os(Linux)
    // --- libdxfrw Include Path ---
    if let includePath = dxfrwIncludePath {
        cxxSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    }

    // --- libdxfrw Library Path ---
    if let libPath = dxfrwLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }

    linkerSettings.append(.linkedLibrary("dxfrw"))
    linkerSettings.append(.linkedLibrary("iconv"))
#endif

let package = Package(
    name: "SwiftDXFrw",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "CDXFRW", targets: ["CDXFRW"]),
        .library(name: "SwiftDXFrw", targets: ["SwiftDXFrw"]),
    ],
    targets: [
        // C++ interop target: compiles dxfrw_bridge.cpp, exposes dxfrw_bridge.h
        .target(
            name: "CDXFRW",
            path: "Dependencies/CDXFRW",
            publicHeadersPath: ".",
            cxxSettings: cxxSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),

        // Swift wrapper target
        .target(
            name: "SwiftDXFrw",
            dependencies: [
                .target(name: "CDXFRW"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
