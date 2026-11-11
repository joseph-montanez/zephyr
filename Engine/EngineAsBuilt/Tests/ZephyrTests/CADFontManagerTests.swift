import XCTest
import Foundation
@testable import ZephyrCore

/// Explicit SHX search-directory registration.
///
/// The `dxf-roundtrip` bench gate digests DXF export bytes, and export header
/// extents use SHX text bounds when a font resolves (an estimated rectangle
/// otherwise). Registration pins discovery to a known tree so the gate does
/// not depend on the process working directory or on assets staged next to
/// the binary — the Windows CI failure where the bench ran from the repo root
/// before `Fonts` were staged is the case this covers.
@MainActor
final class CADFontManagerTests: XCTestCase {

    /// Source-tree package directory derived from this file's location, so the
    /// test works no matter which directory the test runner starts in.
    private func packageDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CADFontManagerTests.swift
            .deletingLastPathComponent() // ZephyrTests
            .deletingLastPathComponent() // Tests
    }

    /// Copies the source-tree simplex.shx under a unique name so the lookup
    /// below cannot accidentally hit an ambiently staged font.
    private func uniqueFontCopy(in directory: URL) throws -> String {
        let source = packageDirectory()
            .appendingPathComponent("Fonts", isDirectory: true)
            .appendingPathComponent("simplex.shx")
        let uniqueName = "zephyrtest_\(UUID().uuidString).shx"
        try FileManager.default.copyItem(
            at: source,
            to: directory.appendingPathComponent(uniqueName))
        return uniqueName
    }

    func testRegisteredFontDirectoryIsSearched() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "zephyr-font-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let uniqueName = try uniqueFontCopy(in: tempDir)

        XCTAssertNil(
            CADFontManager.getOrLoadSHXFont(
                filename: uniqueName, allowFallback: false),
            "a uniquely named font must not resolve before its directory is registered")

        CADFontManager.registerFontDirectory(tempDir)

        let font = try XCTUnwrap(
            CADFontManager.getOrLoadSHXFont(
                filename: uniqueName, allowFallback: false),
            "a registered font directory must be searched first")
        XCTAssertTrue(font.isUsable)

        // Duplicate registrations are ignored but must keep resolving.
        CADFontManager.registerFontDirectory(tempDir)
        XCTAssertNotNil(
            CADFontManager.getOrLoadSHXFont(
                filename: uniqueName, allowFallback: false),
            "duplicate registration must keep resolving the font")
    }

    func testSourceTreeFontsResolveSimplex() throws {
        CADFontManager.registerFontDirectory(
            packageDirectory().appendingPathComponent("Fonts", isDirectory: true))
        let font = try XCTUnwrap(
            CADFontManager.getOrLoadSHXFont(
                filename: "simplex.shx", allowFallback: false),
            "source-tree Fonts must provide simplex.shx once registered")
        XCTAssertTrue(font.isUsable)
    }
}
