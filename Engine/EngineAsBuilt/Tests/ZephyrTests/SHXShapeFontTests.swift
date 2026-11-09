import XCTest
@testable import ZephyrCore

final class SHXShapeFontTests: XCTestCase {

    private func findTestFile(_ name: String) -> String {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return name
    }

    private func loadIsocp() throws -> SHXShapeFont {
        let path = findTestFile("Fonts/isocp.shx")
        let font = try SHXShapeFont(url: URL(fileURLWithPath: path))
        XCTAssertTrue(font.isUsable)
        return font
    }

    /// Renders at native scale (height == fontHeight). In that setup world X
    /// equals glyph X and world Y equals negated glyph Y (baseline at 0).
    private func lineBounds(
        _ font: SHXShapeFont, _ text: String
    ) -> (count: Int, minX: Double, maxX: Double, minY: Double, maxY: Double) {
        let primitives = font.renderText(text, origin: .zero, height: font.fontHeight)
        var count = 0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for case .line(let start, let end, _) in primitives {
            count += 1
            minX = min(minX, start.x, end.x)
            maxX = max(maxX, start.x, end.x)
            minY = min(minY, start.y, end.y)
            maxY = max(maxY, start.y, end.y)
        }
        return (count, minX, maxX, minY, maxY)
    }

    /// isocp.shx glyphs O, G, R are built from clockwise octant arcs
    /// (opcode 10 spec bytes 0xC4/0x84, 0xE2/0xC2, 0xA4). The SHX spec byte
    /// `(-)0SC` is sign-magnitude: bit 7 is the direction, bits 6-4 the start
    /// octant, bits 2-0 the octant count. Decoding it via Int8/abs (two's
    /// complement) rotates every clockwise arc and can triple its sweep.
    /// Correct glyph-space bounds for all three caps are x 6...26, y 2...38
    /// (world Y negated), with segment counts O=38, G=23, R=22.
    func testClockwiseOctantArcGlyphs() throws {
        let font = try loadIsocp()

        let o = lineBounds(font, "O")
        XCTAssertEqual(o.count, 38)
        XCTAssertEqual(o.minX, 6.0, accuracy: 0.02)
        XCTAssertEqual(o.maxX, 26.0, accuracy: 0.02)
        XCTAssertEqual(o.minY, -38.0, accuracy: 0.02)
        XCTAssertEqual(o.maxY, -2.0, accuracy: 0.02)

        let g = lineBounds(font, "G")
        XCTAssertEqual(g.count, 23)
        XCTAssertEqual(g.minX, 6.0, accuracy: 0.02)
        XCTAssertEqual(g.maxX, 26.0, accuracy: 0.02)
        XCTAssertEqual(g.minY, -38.0, accuracy: 0.02)
        XCTAssertEqual(g.maxY, -2.0, accuracy: 0.02)

        let r = lineBounds(font, "R")
        XCTAssertEqual(r.count, 22)
        XCTAssertEqual(r.minX, 6.0, accuracy: 0.02)
        XCTAssertEqual(r.maxX, 26.0, accuracy: 0.02)
        XCTAssertEqual(r.minY, -38.0, accuracy: 0.02)
        XCTAssertEqual(r.maxY, -2.0, accuracy: 0.02)

        // Advance width is the glyph's final pen X, so a mis-decoded arc also
        // shifts the following character. Both caps advance 32 units:
        // "GO" spans x 6...58 (32 + O's maxX 26) in 61 segments.
        let go = lineBounds(font, "GO")
        XCTAssertEqual(go.count, 61)
        XCTAssertEqual(go.minX, 6.0, accuracy: 0.02)
        XCTAssertEqual(go.maxX, 58.0, accuracy: 0.02)
    }

    /// Fractional arcs (opcode 11) carry an octant *span* like opcode 10,
    /// not an absolute end octant: the arc ends in octant
    /// `start ± span ∓ 1` at endOffset/256 of an octant past that boundary,
    /// with offsets applied in the direction of travel and an end offset
    /// of 0 meaning a full offset (256). isocp "9" (spec 0x62) is the
    /// canonical case: as an absolute end octant its bowl lands at
    /// x -11.9...22.1, y 2...56 with advance 10.1; correctly decoded it
    /// sits in the same box as every other digit, advance 28.14.
    func testFractionalArcNine() throws {
        let font = try loadIsocp()

        let nine = lineBounds(font, "9")
        XCTAssertEqual(nine.count, 38)
        XCTAssertEqual(nine.minX, 6.144, accuracy: 0.05)
        XCTAssertEqual(nine.maxX, 22.144, accuracy: 0.05)
        XCTAssertEqual(nine.minY, -38.021, accuracy: 0.05)
        XCTAssertEqual(nine.maxY, -2.0, accuracy: 0.05)

        // Advance 28.144: second "9" starts there, so "99" ends at 50.289.
        let nn = lineBounds(font, "99")
        XCTAssertEqual(nn.count, 76)
        XCTAssertEqual(nn.maxX, 50.289, accuracy: 0.05)
    }

    /// "§" (167) uses fractional arcs in both directions, including isocp's
    /// only clockwise one (spec byte 0xE6). "&" (38) uses a CCW fractional
    /// arc. Both must stay inside the cap-height box and return to the
    /// baseline metrics these bounds pin down.
    func testFractionalArcSectionAndAmpersand() throws {
        let font = try loadIsocp()

        let s = lineBounds(font, "§")
        XCTAssertEqual(s.count, 88)
        XCTAssertEqual(s.minX, 5.674, accuracy: 0.05)
        XCTAssertEqual(s.maxX, 17.674, accuracy: 0.05)
        XCTAssertEqual(s.minY, -37.942, accuracy: 0.05)
        XCTAssertEqual(s.maxY, -1.963, accuracy: 0.05)

        let a = lineBounds(font, "&")
        XCTAssertEqual(a.count, 44)
        XCTAssertEqual(a.minX, 5.998, accuracy: 0.05)
        XCTAssertEqual(a.maxX, 30.0, accuracy: 0.05)
        XCTAssertEqual(a.minY, -38.051, accuracy: 0.05)
        XCTAssertEqual(a.maxY, -1.815, accuracy: 0.05)
    }

    /// "B" uses only counter-clockwise octant arcs (spec byte 0x64) and
    /// decoded correctly even before the sign-magnitude fix; it must not
    /// change. 40 segments, x 6...26, glyph y 2...38.
    func testCounterClockwiseOctantArcGlyphUnchanged() throws {
        let font = try loadIsocp()

        let b = lineBounds(font, "B")
        XCTAssertEqual(b.count, 40)
        XCTAssertEqual(b.minX, 6.0, accuracy: 0.02)
        XCTAssertEqual(b.maxX, 26.0, accuracy: 0.02)
        XCTAssertEqual(b.minY, -38.0, accuracy: 0.02)
        XCTAssertEqual(b.maxY, -2.0, accuracy: 0.02)
    }

    // MARK: - Outline Shape Font Filling

    func testOutlineFontDetectionAndFilling() throws {
        let path = findTestFile("Fonts/HELV_OUT.SHX")
        let font = try SHXShapeFont(url: URL(fileURLWithPath: path))
        XCTAssertTrue(font.isUsable)
        XCTAssertTrue(font.isOutlineFont)

        // "A" in an outline font should produce a filled complex polygon with 1 hole
        let aPrims = font.renderText("A", origin: .zero, height: font.fontHeight, fillOutline: true)
        let aComplex = aPrims.compactMap { prim -> (outer: [Vector3], holes: [[Vector3]])? in
            if case .fillComplexPolygon(let outer, let holes, _) = prim { return (outer, holes) }
            return nil
        }
        XCTAssertEqual(aComplex.count, 1)
        XCTAssertEqual(aComplex.first?.holes.count, 1)

        // "V" in an outline font should produce a filled simple polygon (0 holes)
        let vPrims = font.renderText("V", origin: .zero, height: font.fontHeight, fillOutline: true)
        let vPolys = vPrims.compactMap { prim -> [Vector3]? in
            if case .fillPolygon(let pts, _) = prim { return pts }
            return nil
        }
        XCTAssertEqual(vPolys.count, 1)
        XCTAssertGreaterThanOrEqual(vPolys.first?.count ?? 0, 7)

        // When fillOutline is false, outline fonts render as line strokes (wireframe)
        let wireframePrims = font.renderText("A", origin: .zero, height: font.fontHeight, fillOutline: false)
        XCTAssertTrue(wireframePrims.allSatisfy { prim in
            if case .line = prim { return true }
            return false
        })

        // Multi-character title "PVC"
        let titlePrims = font.renderText("PVC", origin: .zero, height: font.fontHeight, fillOutline: true)
        let filledCount = titlePrims.filter { prim in
            switch prim {
            case .fillPolygon, .fillComplexPolygon: return true
            default: return false
            }
        }.count
        XCTAssertEqual(filledCount, 3)
    }

    func testStickFontRemainsLinesOnly() throws {
        let font = try loadIsocp()
        XCTAssertFalse(font.isOutlineFont)

        let prims = font.renderText("AVO", origin: .zero, height: font.fontHeight, fillOutline: true)
        XCTAssertFalse(prims.isEmpty)
        XCTAssertTrue(prims.allSatisfy { prim in
            if case .line = prim { return true }
            return false
        })
    }

    private func loadRomans() throws -> SHXShapeFont {
        let path = findTestFile("Fonts/romans.shx")
        let font = try SHXShapeFont(url: URL(fileURLWithPath: path))
        XCTAssertTrue(font.isUsable)
        XCTAssertEqual(font.fontHeight, 21.0, accuracy: 1e-9)
        return font
    }

    private func bounds(
        _ prims: [CADPrimitive]
    ) -> (minX: Double, maxX: Double, minY: Double, maxY: Double) {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for case .line(let start, let end, _) in prims {
            minX = min(minX, start.x, end.x)
            maxX = max(maxX, start.x, end.x)
            minY = min(minY, start.y, end.y)
            maxY = max(maxY, start.y, end.y)
        }
        return (minX, maxX, minY, maxY)
    }

    /// Handles 37BF9 / 37C78 of "Vivienda Unifamiliar 2.dwg" (style
    /// R80-50 = romans.shx). Advance sums parsed independently from the
    /// SHX shape definitions: 37BF9 = 1427 units, 37C78 = 447 units
    /// (cap height 21). At the entity width factor 1.0 (DXF default for
    /// an absent group 41) both fit their drawn geometry - the spec box
    /// leaves 6.8791 from 37BF9's insertion point, 37C78's table cell
    /// is 2.1309 wide; at the style factor 1.3 neither fits.
    func testRomansAdvanceWidthsForReportedHandles() throws {
        let font = try loadRomans()
        let h = 0.0926476727069243
        let line37BF9 = "-  TODOS LOS MATERIALES, TUBERIAS Y ACCESORIOS A UTILIZARSE EN LAS REDES DE"
        let line37C78 = "TUBERIA DE AGUA CALIENTE"

        let w1 = font.measuredAdvanceWidth(line37BF9, height: h, widthFactor: 1.0)
        XCTAssertEqual(w1, 1427.0 / 21.0 * h, accuracy: 0.02)
        XCTAssertLessThanOrEqual(w1, 6.8791)
        let w1Wide = font.measuredAdvanceWidth(line37BF9, height: h, widthFactor: 1.3)
        XCTAssertEqual(w1Wide, w1 * 1.3, accuracy: 0.02)
        XCTAssertGreaterThan(w1Wide, 6.8791)

        let w2 = font.measuredAdvanceWidth(line37C78, height: h, widthFactor: 1.0)
        XCTAssertEqual(w2, 447.0 / 21.0 * h, accuracy: 0.02)
        XCTAssertLessThanOrEqual(w2, 2.1309)
        XCTAssertGreaterThan(
            font.measuredAdvanceWidth(line37C78, height: h, widthFactor: 1.3), 2.1309)
    }

    /// Fit (alignH 5) keeps the height and stretches width so the pen
    /// ends exactly at the span; Aligned (alignH 3) scales both axes.
    /// Both anchor at the origin (first definition point), never centered.
    func testFitAndAlignedRenderSpansExactly() throws {
        let font = try loadRomans()
        let h = 0.0926476727069243
        let span = 2.1309
        let text = "TUBERIA DE AGUA CALIENTE"

        let natural = bounds(font.renderText(text, origin: .zero, height: h))
        let naturalHeight = natural.maxY - natural.minY
        XCTAssertGreaterThan(naturalHeight, 0)

        let fit = bounds(font.renderText(
            text, origin: .zero, height: h, alignH: 5, fitWidth: span))
        XCTAssertGreaterThanOrEqual(fit.minX, -1e-9)
        XCTAssertLessThanOrEqual(fit.maxX, span + 1e-9)
        XCTAssertGreaterThan(fit.maxX, span * 0.95)
        XCTAssertEqual(fit.maxY - fit.minY, naturalHeight, accuracy: 0.005)

        let k = span / font.measuredAdvanceWidth(text, height: h, widthFactor: 1.0)
        let aligned = bounds(font.renderText(
            text, origin: .zero, height: h, alignH: 3, fitWidth: span))
        XCTAssertGreaterThanOrEqual(aligned.minX, -1e-9)
        XCTAssertLessThanOrEqual(aligned.maxX, span + 1e-9)
        XCTAssertGreaterThan(aligned.maxX, span * 0.95)
        XCTAssertEqual(aligned.maxY - aligned.minY, naturalHeight * k, accuracy: 0.01)

        // Without a span, 3/5 keep the legacy centered placement.
        let legacy = bounds(font.renderText(text, origin: .zero, height: h, alignH: 5))
        XCTAssertLessThan(legacy.minX, 0)
    }

    func testMultiStrokeFontsDetectedAndHavePositiveStrokeWidthRatio() throws {
        let boldPath = findTestFile("Fonts/bold.shx")
        let boldFont = try SHXShapeFont(url: URL(fileURLWithPath: boldPath))
        XCTAssertFalse(boldFont.isOutlineFont)
        XCTAssertGreaterThan(boldFont.strokeWidthRatio, 0.0)

        // Bold and duplex fonts should render clean line primitives, not mixed broken polygons
        let boldPrims = boldFont.renderText("PVC LATERAL 123", origin: .zero, height: 60.0, fillOutline: true)
        XCTAssertFalse(boldPrims.isEmpty)
        XCTAssertTrue(boldPrims.allSatisfy { prim in
            if case .line = prim { return true }
            return false
        })

        let romandPath = findTestFile("Fonts/romand.shx")
        let romandFont = try SHXShapeFont(url: URL(fileURLWithPath: romandPath))
        XCTAssertFalse(romandFont.isOutlineFont)
        XCTAssertGreaterThan(romandFont.strokeWidthRatio, 0.0)
        XCTAssertEqual(romandFont.strokeWidthRatio, 1.0 / 21.0, accuracy: 1e-4)

        let romandPrims = romandFont.renderText("PVC LATERAL AND RAISER", origin: .zero, height: 21.0, fillOutline: true)
        XCTAssertFalse(romandPrims.isEmpty)
        XCTAssertTrue(romandPrims.allSatisfy { prim in
            if case .line = prim { return true }
            return false
        })
    }
}
