// swift-tools-version: 6.2.0
import Foundation  // Required for ProcessInfo
import PackageDescription

// --- Read Environment Variables ---
let env = ProcessInfo.processInfo.environment
let zlibIncludePath = env["ZLIB_NG_INCLUDE"]
let zlibLibraryPath = env["ZLIB_NG_LIB"]

// --- Diagnostic Print ---
print("--- SwiftZLibNG Manifest Diagnostic ---")
print("ZLIB_NG_INCLUDE env var is: \(zlibIncludePath ?? "NOT SET")")
print("ZLIB_NG_LIB env var is: \(zlibLibraryPath ?? "NOT SET")")
print("---------------------------------------")

// --- Prepare Settings ---
var cSettings: [CSetting] = []
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = []

#if os(Windows)
    // --- zlib-ng Include Path ---
    if let includePath = zlibIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I", "-Xcc", "\(includePath)"]))
    }

    // --- zlib-ng Static Library ---
    // On Windows MSVC, we link against the static .lib directly.
    // The library path is passed via ZLIB_NG_LIB env var.
    // zlibstatic-ng.lib is the static library (vs zlib-ng.lib which is the DLL import lib).
    if let libPath = zlibLibraryPath {
        // Pass the library search path to the linker
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
        // On MSVC, link.exe needs the .lib file directly for static linking.
        // We pass the full path to the static library so the linker finds it.
        linkerSettings.append(.unsafeFlags(["\(libPath)\\zlibstatic-ng.lib"]))
    } else {
        print("WARNING: ZLIB_NG_LIB not set. zlib-ng will not be linked!")
    }

    // zlib-ng may also need the C runtime. On MSVC this is automatic
    // when compiling with the VS toolchain, so no extra flags needed.

#elseif os(macOS)
    // --- zlib-ng Include Path ---
    if let includePath = zlibIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    } else {
        // Fallback: check common Homebrew paths
        let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        cSettings.append(.unsafeFlags(["-I", "\(brewPrefix)/include"]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include"]))
    }

    // --- zlib-ng Library Path ---
    if let libPath = zlibLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    } else {
        let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        linkerSettings.append(.unsafeFlags(["-L\(brewPrefix)/lib"]))
    }

    // On macOS, link against the static zlib-ng library (Homebrew installs as libz-ng)
    linkerSettings.append(.linkedLibrary("z-ng"))

#elseif os(Linux)
    // --- zlib-ng Include Path ---
    if let includePath = zlibIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    }

    // --- zlib-ng Library Path ---
    if let libPath = zlibLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }

    linkerSettings.append(.linkedLibrary("z-ng"))
#endif

let package = Package(
    name: "SwiftZLibNG",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "CZLibNG", targets: ["CZLibNG"]),
        .library(name: "SwiftZLibNG", targets: ["SwiftZLibNG"]),
    ],
    targets: [
        // C system library target: exposes zlib-ng.h via a module map.
        // No C/C++ source files needed — the zlib-ng library is precompiled.
        .target(
            name: "CZLibNG",
            path: "Dependencies/CZLibNG",
            publicHeadersPath: ".",
            cSettings: cSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),

        // Swift wrapper target: re-exports CZLibNG for ergonomic importing.
        .target(
            name: "SwiftZLibNG",
            dependencies: [
                .target(name: "CZLibNG"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
