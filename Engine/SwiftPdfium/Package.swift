// swift-tools-version: 6.2.0
import Foundation
import PackageDescription

// --- Read Environment Variables ---
let env = ProcessInfo.processInfo.environment
let pdfiumIncludePath = env["PDFIUM_INCLUDE"]
let pdfiumLibraryPath = env["PDFIUM_LIB"]

// --- Diagnostic Print ---
print("--- SwiftPdfium Manifest Diagnostic ---")
print("PDFIUM_INCLUDE env var is: \(pdfiumIncludePath ?? "NOT SET")")
print("PDFIUM_LIB env var is: \(pdfiumLibraryPath ?? "NOT SET")")
print("----------------------------------------")

// --- Prepare Settings ---
var cSettings: [CSetting] = []
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = []

#if os(Windows)
    if let includePath = pdfiumIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I", "-Xcc", "\(includePath)"]))
    }

    if let libPath = pdfiumLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
        // On MSVC, link.exe needs the .lib file explicitly
        linkerSettings.append(.unsafeFlags(["\(libPath)\\pdfium.dll.lib"]))
    } else {
        print("WARNING: PDFIUM_LIB not set. Pdfium will not be linked!")
    }

#elseif os(macOS)
    if let includePath = pdfiumIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    } else {
        let brewPrefix = env["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        cSettings.append(.unsafeFlags(["-I", "\(brewPrefix)/include/pdfium"]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(brewPrefix)/include/pdfium"]))
    }

    if let libPath = pdfiumLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    } else {
        let brewPrefix = env["HOMEBREW_PREFIX"] ?? "/opt/homebrew"
        linkerSettings.append(.unsafeFlags(["-L\(brewPrefix)/lib"]))
    }

    linkerSettings.append(.linkedLibrary("pdfium"))

#elseif os(Linux)
    if let includePath = pdfiumIncludePath {
        cSettings.append(.unsafeFlags(["-I", includePath]))
        swiftSettings.append(.unsafeFlags(["-Xcc", "-I\(includePath)"]))
    }

    if let libPath = pdfiumLibraryPath {
        linkerSettings.append(.unsafeFlags(["-L\(libPath)"]))
    }

    linkerSettings.append(.linkedLibrary("pdfium"))
#endif

let package = Package(
    name: "SwiftPdfium",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "CPdfium", targets: ["CPdfium"]),
        .library(name: "SwiftPdfium", targets: ["SwiftPdfium"]),
    ],
    targets: [
        // C bridge target: compiles pdfium_bridge.c, links against pdfium.
        .target(
            name: "CPdfium",
            path: "Dependencies/CPdfium",
            publicHeadersPath: ".",
            cSettings: cSettings,
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),

        // Swift wrapper target: cross-platform PDFPageRenderer.
        .target(
            name: "SwiftPdfium",
            dependencies: [
                .target(name: "CPdfium"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
