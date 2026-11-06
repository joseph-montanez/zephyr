// swift-tools-version: 6.4
import PackageDescription

// Swift 6.4 feature flags used by this branch.
//
// Currently empty on purpose. `LifetimeDependence` + `Lifetimes` were enabled to write `@_lifetime`-
// annotated accessors that vend a `Span`, which turned out to be unusable here for two independent
// reasons: a `borrow` accessor may only return a stored property (SE-0507), and `Array.span` itself
// needs macOS 26 — see Sources/ZephyrCore/Swift64FeatureCanary.swift for the full availability matrix.
// `borrow`/`mutate` accessors and `Span`/`RawSpan` need no flag, so nothing here is gated.
//
// Re-add the flags only if an explicitly annotated lifetime-dependent result becomes necessary again:
//   .enableExperimentalFeature("LifetimeDependence"), .enableExperimentalFeature("Lifetimes"),
let zephyrSwiftSettings: [SwiftSetting] = []

let package = Package(
    name: "Zephyr",
    platforms: [.macOS(.v12), .iOS(.v13)],
    products: [
        .library(name: "ZephyrKernel", targets: ["ZephyrKernel"]),
        .library(name: "ZephyrCore", targets: ["ZephyrCore"]),
        .executable(name: "Zephyr", targets: ["Zephyr"]),
    ],
    dependencies: [
        .package(name: "SwiftSDL", path: "../SwiftSDL"),
        .package(name: "SwiftSDL_image", path: "../SwiftSDL_image"),
        .package(name: "SwiftSDL_ttf", path: "../SwiftSDL_ttf"),
        .package(name: "SwiftImGui", path: "../SwiftImGui"),
        .package(name: "SwiftZLibNG", path: "../SwiftZLibNG"),
    ],
    targets: [
        // Pure-math 2D CAD geometry kernel — zero UI, SDL, or ImGui dependencies.
        // Foundation only. See PLAN-kernel-perf.md.
        .target(
            name: "ZephyrKernel",
            path: "Sources/ZephyrKernel",
            swiftSettings: zephyrSwiftSettings
        ),
        .target(
            name: "ZephyrCore",
            dependencies: [
                "ZephyrKernel",
                "ZephyrLisp",
                .product(name: "CZLibNG", package: "SwiftZLibNG"),
                .product(name: "CSDL3", package: "SwiftSDL"),
                .product(name: "SwiftSDL", package: "SwiftSDL"),
                .product(name: "SwiftSDL_image", package: "SwiftSDL_image"),
                .product(name: "SwiftSDL_ttf", package: "SwiftSDL_ttf"),
                .product(name: "ImGui", package: "SwiftImGui"),
            ],
            path: "Sources/ZephyrCore",
            resources: [
                .copy("../../Patterns")
            ],
            swiftSettings: zephyrSwiftSettings
        ),
        // Merged FDScript libraries (AutoLISP compiler frontend + emitter +
        // interpreter). Deliberately libs-only: the FieldDraftCompiler CLI,
        // FieldDraftLanguageServer, and FDScriptWasm executables were not merged.
        // These targets stay dependency-free (Foundation only) and macOS 12 clean.
        .target(
            name: "FieldDraftScriptCore",
            path: "Sources/FieldDraftScriptCore",
            swiftSettings: zephyrSwiftSettings
        ),
        .target(
            name: "FieldDraftScriptBackends",
            dependencies: ["FieldDraftScriptCore"],
            path: "Sources/FieldDraftScriptBackends",
            swiftSettings: zephyrSwiftSettings
        ),
        .target(
            name: "FieldDraftScriptRuntime",
            dependencies: ["FieldDraftScriptCore"],
            path: "Sources/FieldDraftScriptRuntime",
            swiftSettings: zephyrSwiftSettings
        ),
        .executableTarget(
            name: "Zephyr",
            dependencies: [
                "ZephyrCore",
                .product(name: "ImGui", package: "SwiftImGui"),
            ],
            path: "Sources/Zephyr",
            swiftSettings: zephyrSwiftSettings
        ),
        .testTarget(
            name: "FDScriptTests",
            dependencies: [
                "FieldDraftScriptCore",
                "FieldDraftScriptBackends",
                "FieldDraftScriptRuntime",
            ],
            path: "Tests/FDScriptTests",
            swiftSettings: zephyrSwiftSettings
        ),
        // Inventory extractor + registry generator (dev tool, not shipped):
        // swift run LispGen --input Tools/lisp/autolisp.html
        //   --corpus Tools/lisp/corpus
        //   --output Sources/ZephyrLisp/Generated/LispRegistry.generated.swift
        .executableTarget(
            name: "LispGen",
            path: "Sources/LispGen",
            swiftSettings: zephyrSwiftSettings
        ),
        // Native AutoLISP engine: reader, evaluator, input broker, builtins.
        // Dependency-free (Foundation only) and macOS 12 clean by policy:
        // no Regex, Clock/Duration, Span, or other post-12 APIs.
        .target(
            name: "ZephyrLisp",
            dependencies: ["ZephyrKernel"],
            path: "Sources/ZephyrLisp",
            swiftSettings: zephyrSwiftSettings
        ),
        .testTarget(
            name: "ZephyrKernelTests",
            dependencies: ["ZephyrKernel"],
            path: "Tests/ZephyrKernelTests",
            swiftSettings: zephyrSwiftSettings
        ),
        .testTarget(
            name: "ZephyrLispTests",
            dependencies: ["ZephyrLisp"],
            path: "Tests/ZephyrLispTests",
            swiftSettings: zephyrSwiftSettings
        ),
        .testTarget(
            name: "ZephyrTests",
            dependencies: [
                "ZephyrCore",
                "ZephyrKernel",
                .product(name: "CSDL3", package: "SwiftSDL"),
                .product(name: "ImGui", package: "SwiftImGui"),
            ],
            path: "Tests/ZephyrTests",
            swiftSettings: zephyrSwiftSettings
        ),
        // Perf harness (plain executable, not a test): `swift run -c release ZephyrBench ...`.
        // Kept out of the test target because that one needs the libdxfrw C module.
        .executableTarget(
            name: "ZephyrBench",
            dependencies: ["ZephyrCore", "ZephyrLisp", "ZephyrKernel"],
            path: "Sources/ZephyrBench",
            swiftSettings: zephyrSwiftSettings
        ),
    ]
)
