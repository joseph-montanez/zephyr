import XCTest
@testable import ZephyrCore

/// TTF path resolution must be a pure function of the filename: repeated
/// queries agree, so per-entity, per-regen directory rescans are redundant.
/// (The resolver caches hits and misses; these tests pin the contract the
/// cache relies on. They pass regardless of which fonts exist on the host.)
@MainActor
final class FontResolutionCacheTests: XCTestCase {

    func testRepeatedQueryAgrees() {
        let first = CADFontManager.getTTFEquivalent(filename: "Arial.ttf")
        let second = CADFontManager.getTTFEquivalent(filename: "Arial.ttf")
        XCTAssertEqual(first, second)
    }

    func testUnresolvableNameResolvesConsistently() {
        // Unknown names fall back to a generic font when one exists (or nil
        // when none does). Either way both calls must agree: the second one
        // is served from the miss/hit cache without rescanning.
        let name = "__no_such_font_zz__.ttf"
        XCTAssertEqual(
            CADFontManager.getTTFEquivalent(filename: name),
            CADFontManager.getTTFEquivalent(filename: name))
    }

    func testCaseVariantsAgree() {
        XCTAssertEqual(
            CADFontManager.getTTFEquivalent(filename: "ARIAL.TTF"),
            CADFontManager.getTTFEquivalent(filename: "arial.ttf"))
    }
}
