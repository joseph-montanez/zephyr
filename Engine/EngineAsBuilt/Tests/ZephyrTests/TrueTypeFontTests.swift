import XCTest
import Foundation
@testable import ZephyrCore

/// Unit tests for the TrueType reader backing PDF text export
/// (metrics, embedding maps, and convert-to-geometry outlines).
@MainActor
final class TrueTypeFontTests: XCTestCase {

    private func fontURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" && dir.path != "." {
            let candidate = dir.appendingPathComponent("Fonts/ARIALN.TTF")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Fonts/ARIALN.TTF not found from \(#filePath)")
    }

    private func loadFont() throws -> CADTrueTypeFont {
        try CADTrueTypeFont(url: try fontURL())
    }

    func testParsesHeaderAndUnitsPerEm() throws {
        let font = try loadFont()
        XCTAssertEqual(font.unitsPerEm, 2048, "Arial Narrow uses 2048 units per em")
        XCTAssertTrue(font.hasGlyphOutlines, "TrueType-flavored font must expose glyf outlines")
    }

    func testPDFMetricsAreReadable() throws {
        let font = try loadFont()
        XCTAssertGreaterThan(font.capHeightUnits, 1000, "cap height must be plausible")
        XCTAssertLessThan(font.capHeightUnits, font.unitsPerEm)
        XCTAssertGreaterThan(font.ascentUnits, 0)
        XCTAssertLessThan(font.descentUnits, 0)
        XCTAssertFalse(font.postScriptName.isEmpty)
        XCTAssertFalse(font.postScriptName.contains(" "))
        let (xMin, yMin, xMax, yMax) = font.boundingBox
        XCTAssertLessThan(xMin, xMax)
        XCTAssertLessThan(yMin, yMax)
    }

    func testCmapMapsBasicLatin() throws {
        let font = try loadFont()
        let gidA = font.glyphID(for: "A")
        let gidSpace = font.glyphID(for: " ")
        XCTAssertGreaterThan(gidA, 0, "'A' must map to a real glyph")
        XCTAssertGreaterThan(gidSpace, 0, "space must map to a real glyph")
        XCTAssertNotEqual(gidA, gidSpace)
        // Unmapped control character falls back to .notdef.
        XCTAssertEqual(font.glyphID(for: "\u{1}"), 0)
    }

    func testAdvancesAreProportional() throws {
        let font = try loadFont()
        let narrow = font.advanceWidth(glyphID: font.glyphID(for: "i"))
        let wide = font.advanceWidth(glyphID: font.glyphID(for: "W"))
        XCTAssertGreaterThan(narrow, 0)
        XCTAssertGreaterThan(wide, narrow, "W must advance more than i in a proportional face")
        // Narrower than Helvetica: 'A' in Arial Narrow is ~1139/2048 em.
        let advA = font.advanceWidth(glyphID: font.glyphID(for: "A"))
        XCTAssertLessThan(Double(advA) / Double(font.unitsPerEm), 0.62)
    }

    func testWidthEmSumsAdvances() throws {
        let font = try loadFont()
        let word = font.widthEm(of: "PIRATE")
        XCTAssertGreaterThan(word, 2.5, "6 narrow caps must exceed 2.5 em")
        XCTAssertLessThan(word, 4.0)
        XCTAssertEqual(font.widthEm(of: ""), 0, accuracy: 1e-12)
    }

    func testEmbeddingPermissionReadable() throws {
        let font = try loadFont()
        // Arial Narrow MT is embeddable (preview/print); a restricted
        // font would report false here and take the geometry path.
        XCTAssertTrue(font.embeddingAllowed)
        XCTAssertNotNil(font.familyName)
    }

    func testOutlineOfCapLetterHasContours() throws {
        let font = try loadFont()
        let gid = font.glyphID(for: "H")
        let outline = try XCTUnwrap(font.outline(glyphID: gid), "H must have an outline")
        XCTAssertFalse(outline.contours.isEmpty)
        let xs = outline.contours.flatMap { $0.points.map { $0.x } }
        let ys = outline.contours.flatMap { $0.points.map { $0.y } }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return XCTFail("H outline has no points")
        }
        XCTAssertGreaterThan(maxX - minX, 500, "H must be wider than 500 font units")
        XCTAssertGreaterThan(maxY - minY, 1000, "cap H must be taller than 1000 font units")
        // Outline fits within the em box.
        XCTAssertGreaterThanOrEqual(minX, -500)
        XCTAssertLessThanOrEqual(maxY, 2500)
    }

    func testOutlineOfSpaceIsEmpty() throws {
        let font = try loadFont()
        let outline = try XCTUnwrap(
            font.outline(glyphID: font.glyphID(for: " ")), "space must resolve")
        XCTAssertTrue(outline.contours.isEmpty, "space has no contours")
    }

    func testMalformedDataThrows() {
        XCTAssertThrowsError(try CADTrueTypeFont(data: Data([0, 1, 2, 3])))
        XCTAssertThrowsError(try CADTrueTypeFont(data: Data(repeating: 0, count: 64)))
    }
}
