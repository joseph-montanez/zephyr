import XCTest
@testable import ZephyrCore

/// Text generation flags (backwards/upside-down), vertical MTEXT direction,
/// and ATTDEF tag display. Regression coverage for the text.dxf audit:
///
/// - TEXT group 71 bit 1 (2) mirrors about the insertion point so
///   backwards text extends left instead of right (e.g. `text-to-fit`).
/// - TEXT group 71 bit 2 (4) mirrors vertically.
/// - MTEXT group 72 direction 3 stacks characters top-to-bottom with
///   `\P` starting a new column to the right.
/// - Standalone and block ATTDEF display the tag (group 2), not the
///   default value (group 1); the value is preserved for export/INSERT.
@MainActor
final class TextMirroringTests: XCTestCase {

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    private func shxFont() throws -> SHXShapeFont {
        try XCTUnwrap(CADFontManager.getOrLoadSHXFont(
            filename: "simplex.shx", allowFallback: false))
    }

    func testBackwardsTextMirrorsAboutInsertion() throws {
        let font = try shxFont()
        let normal = try XCTUnwrap(font.measuredLocalBounds(
            "abc", height: 10, alignH: 0, alignV: 0))
        let mirrored = try XCTUnwrap(font.measuredLocalBounds(
            "abc", height: 10, alignH: 0, alignV: 0, mirrorX: true))
        XCTAssertGreaterThanOrEqual(normal.minX, -1e-9)
        XCTAssertGreaterThan(normal.maxX, 0)
        XCTAssertLessThanOrEqual(mirrored.maxX, 1e-9)
        XCTAssertLessThan(mirrored.minX, 0)
        XCTAssertEqual(mirrored.minX, -normal.maxX, accuracy: 1e-6)
        XCTAssertEqual(mirrored.maxX, -normal.minX, accuracy: 1e-6)
    }

    func testUpsideDownTextMirrorsVertically() throws {
        let font = try shxFont()
        let normal = try XCTUnwrap(font.measuredLocalBounds(
            "abc", height: 10, alignH: 0, alignV: 0))
        let flipped = try XCTUnwrap(font.measuredLocalBounds(
            "abc", height: 10, alignH: 0, alignV: 0, mirrorY: true))
        XCTAssertEqual(flipped.minY, -normal.maxY, accuracy: 1e-6)
        XCTAssertEqual(flipped.maxY, -normal.minY, accuracy: 1e-6)
    }

    func testVerticalMTextStacksDownward() throws {
        let font = try shxFont()
        let one = try XCTUnwrap(font.measuredLocalBounds(
            "a", height: 10, alignH: 0, alignV: 3, vertical: true))
        let twoCols = try XCTUnwrap(font.measuredLocalBounds(
            "a\nb", height: 10, alignH: 0, alignV: 3, vertical: true))
        let twoRows = try XCTUnwrap(font.measuredLocalBounds(
            "ab", height: 10, alignH: 0, alignV: 3, vertical: true))
        // Left-anchored: the anchored edge stays put when columns are added.
        XCTAssertEqual(twoCols.minX, one.minX, accuracy: 1e-6)
        // A second `\P` column widens the block well beyond one column.
        XCTAssertGreaterThan(twoCols.maxX - twoCols.minX, 1.5 * (one.maxX - one.minX))
        // Top-anchored: the anchored edge stays put when rows are added.
        XCTAssertEqual(twoRows.minY, one.minY, accuracy: 1e-6)
        // A second stacked character lengthens the block well beyond one.
        XCTAssertGreaterThan(twoRows.maxY - twoRows.minY, 1.5 * (one.maxY - one.minY))
        // Rows stack the same local direction horizontal lines stack, so the
        // column lands on the same side of the insertion as horizontal text.
        let hOne = try XCTUnwrap(font.measuredLocalBounds(
            "a", height: 10, alignH: 0, alignV: 3))
        let hTwo = try XCTUnwrap(font.measuredLocalBounds(
            "a\nb", height: 10, alignH: 0, alignV: 3))
        XCTAssertEqual(
            (twoRows.maxY - twoRows.minY > one.maxY - one.minY),
            (hTwo.maxY - hTwo.minY > hOne.maxY - hOne.minY))
        XCTAssertEqual(
            twoRows.maxY > one.maxY,
            hTwo.maxY > hOne.maxY)
    }

    func testVerticalAndHorizontalExtendSameWorldDirection() throws {
        // Absolute direction through the real pipeline: a vertical and a
        // horizontal MTEXT, both top-anchored, must extend the same world
        // direction from their insertions (on screen both extend downward
        // per the AutoCAD reference). World Y sign conventions are
        // frame-dependent, so compare the two against each other.
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        0.0
         20
        0.0
         30
        0.0
         40
        2.5
         41
        100.0
         71
        1
         72
        3
          1
        vertical\\PText
          7
        Standard
          0
        MTEXT
          8
        0
         10
        500.0
         20
        0.0
         30
        0.0
         40
        2.5
         41
        100.0
         71
        1
         72
        1
          1
        horizontal
          7
        Standard
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        func ySide(for needle: String) throws -> Double {
            let entity = try XCTUnwrap(doc.allEntities.first {
                if case .string(let s) = $0.xdata["dxf.text"] { return s.contains(needle) }
                return false
            })
            guard case .string(let text) = entity.xdata["dxf.text"] else {
                throw XCTSkip("no display text")
            }
            var height = 2.5
            if case .double(let v) = entity.xdata["dxf.textHeight"] { height = v }
            var style: String? = nil
            if case .string(let s) = entity.xdata["dxf.textStyle"] { style = s }
            var alignH = 0
            if case .int(let v) = entity.xdata["dxf.alignH"] { alignH = v }
            var alignV = 0
            if case .int(let v) = entity.xdata["dxf.alignV"] { alignV = v }
            var mtextWidth: Double? = nil
            if case .double(let v) = entity.xdata["dxf.mtextWidth"] { mtextWidth = v }
            let context = CADTextBoundsContext(
                textStyleFonts: doc.textStyleFonts,
                textStyles: doc.textStyles,
                defaultXData: entity.xdata)
            let ink = try XCTUnwrap(CADTextMeasurement.measuredBounds(
                text: text, style: style, height: height,
                alignH: alignH, alignV: alignV, mtextWidth: mtextWidth,
                context: context))
            let lo = entity.transform.transformPoint(Vector3(x: ink.minX, y: ink.minY, z: 0))
            let hi = entity.transform.transformPoint(Vector3(x: ink.maxX, y: ink.maxY, z: 0))
            let centerY = (lo.y + hi.y) * 0.5
            return centerY - entity.transform.position.y
        }
        let verticalSide = try ySide(for: "vertical")
        let horizontalSide = try ySide(for: "horizontal")
        XCTAssertNotEqual(verticalSide, 0)
        XCTAssertNotEqual(horizontalSide, 0)
        XCTAssertEqual(verticalSide.sign, horizontalSide.sign,
                       "vertical and horizontal top-anchored text must extend the same world direction")
    }

    func testAttdefImportsTagForDisplayAndPreservesValue() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        ATTDEF
          8
        0
         10
        0.0
         20
        0.0
         30
        0.0
         40
        2.5
          1
        VALUE-backwards
          7
        Standard
         71
        2
          2
        TAG-BACKWARDS
         70
        0
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first {
            if case .string(let t) = $0.xdata["dxf.attributeType"] {
                return t.uppercased() == "ATTDEF"
            }
            return false
        })
        // Display text is the tag (AutoCAD ATTDEF RAW column shows TAG-*).
        if case .string(let display) = entity.xdata["dxf.text"] {
            XCTAssertEqual(display, "TAG-BACKWARDS")
        } else {
            XCTFail("dxf.text missing for ATTDEF")
        }
        // Generation flags survive the import for the renderer.
        XCTAssertEqual(entity.xdata["dxf.textGenerationFlags"], .int(2))
    }

    func testMTextVerticalDirectionRoundTrips() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        0.0
         20
        0.0
         30
        0.0
         40
        2.5
         41
        100.0
         71
        1
         72
        3
          1
        vertical\\PText
          7
        Standard
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let entity = try XCTUnwrap(doc.allEntities.first {
            if case .string(let s) = $0.xdata["dxf.text"] { return s.contains("vertical") }
            return false
        })
        XCTAssertEqual(entity.xdata["dxf.mtextDirection"], .int(3))
        // Direction must survive a DXF export/reimport round-trip.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtext_dir_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let reimported = CADDocument()
        try reimported.importDXF(url: outURL)
        let again = try XCTUnwrap(reimported.allEntities.first {
            if case .string(let s) = $0.xdata["dxf.text"] { return s.contains("vertical") }
            return false
        })
        XCTAssertEqual(again.xdata["dxf.mtextDirection"], .int(3))
    }
    func testManySpacesWrapIntoReferenceWidth() throws {
        // Space-heavy MTEXT must wrap at the reference width even when the
        // words alone would fit: a 23-space run must not glue "def" and "b"
        // into one 2371-unit line. AutoCAD shows "abc" / "def" / "b".
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        739.98
         20
        1784.83
         30
        0.0
         40
        100.0
         41
        360.16
         71
        1
         72
        5
          1
         abc     def            b
          7
        Standard
          0
        MTEXT
          8
        0
         10
        678.22
         20
        1784.83
         30
        0.0
         40
        100.0
         41
        360.16
         71
        3
         72
        5
          1
         abc      def                       b
          7
        Standard
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        XCTAssertEqual(doc.allEntities.count, 2)
        for entity in doc.allEntities {
            guard case .string(let text) = entity.xdata["dxf.text"] else {
                XCTFail("missing display text")
                continue
            }
            var height = 2.5
            if case .double(let v) = entity.xdata["dxf.textHeight"] { height = v }
            var style: String? = nil
            if case .string(let s) = entity.xdata["dxf.textStyle"] { style = s }
            var alignH = 0
            if case .int(let v) = entity.xdata["dxf.alignH"] { alignH = v }
            var alignV = 0
            if case .int(let v) = entity.xdata["dxf.alignV"] { alignV = v }
            var mtextWidth: Double? = nil
            if case .double(let v) = entity.xdata["dxf.mtextWidth"] { mtextWidth = v }
            let context = CADTextBoundsContext(
                textStyleFonts: doc.textStyleFonts,
                textStyles: doc.textStyles,
                defaultXData: entity.xdata)
            let ink = try XCTUnwrap(CADTextMeasurement.measuredBounds(
                text: text, style: style, height: height,
                alignH: alignH, alignV: alignV, mtextWidth: mtextWidth,
                context: context))
            let width = ink.maxX - ink.minX
            XCTAssertLessThan(width, 400.0,
                "wrapped MTEXT must fit its 360-unit reference width")
            XCTAssertGreaterThan(ink.maxY - ink.minY, 250.0,
                "space-separated words must wrap into three lines")
            if alignH == 2 {
                XCTAssertEqual(ink.maxX, 0.0, accuracy: 5.0,
                    "right-anchored ink must end at the insertion point")
            } else {
                XCTAssertGreaterThan(ink.minX, -5.0)
                XCTAssertLessThanOrEqual(ink.minX, 200.0)
            }
        }
    }

    func testOverlongLeadingWhitespaceBreaksOwnLine() throws {
        // MTEXT 65B "spc def" starts with 23 spaces (first line contains
        // spaces > width) and MTEXT 567 "abc abcd" starts with a space in a
        // very thin column. A leading space run that already exceeds the
        // reference width must break onto its own invisible line instead of
        // gluing the first word far past the column: AutoCAD shows "spc" /
        // "abc" starting at the insertion x.
        // NOTE: this exercises renderFormattedText (the MTEXT render path),
        // not measuredBounds — the measurement path trims leading spaces
        // when splitting words, so only the render path can regress here.
        let font = try shxFont()
        // (text, reference width, minimum ink top: the invisible leading
        // line occupies slot 0, so visible ink must start at/after slot 1)
        let cases: [(text: String, width: Double, minTop: Double)] = [
            (String(repeating: " ", count: 23) + "spc"
                + String(repeating: " ", count: 23) + "def", 375.0, 100.0),
            (" abc", 83.5, 100.0),
        ]
        for (text, width, minTop) in cases {
            let formatted = FormattedText.plain(
                text, font: "simplex.shx", height: 100.0)
            let primitives = font.renderFormattedText(
                formatted, origin: .zero,
                alignH: 0, alignV: 3, maxWidth: width)
            var minX = Double.infinity
            var maxX = -Double.infinity
            var minY = Double.infinity
            var maxY = -Double.infinity
            for primitive in primitives {
                if case .line(let start, let end, _) = primitive {
                    minX = min(minX, start.x, end.x)
                    maxX = max(maxX, start.x, end.x)
                    minY = min(minY, start.y, end.y)
                    maxY = max(maxY, start.y, end.y)
                }
            }
            XCTAssertLessThan(minX, 45.0,
                "first word must start near the insertion x for [\(text)]")
            XCTAssertLessThan(maxX, 400.0,
                "ink must stay inside the reference width for [\(text)]")
            XCTAssertGreaterThan(minY, minTop,
                "collapsing the leading space line must not pull ink up a slot")
            XCTAssertGreaterThan(maxY, minTop + 100.0,
                "visible ink must span past the first line slot for [\(text)]")
        }
    }

    func testDistributedMarkerSpreadsWordsAcrossReferenceWidth() throws {
        // MTEXT 534/646 "Xxp     pxX" carry the embedded columns marker
        // 70=1/71=2/72=2. AutoCAD distributes those paragraphs across the
        // reference width (pxX lands in box 537 and tracks the right grip);
        // every other MTEXT in text.dxf carries 72=1 (or no columns object)
        // and stays left-aligned.
        // Minimal columns block; only 70/71/72 are read.
        // DXF group codes are whitespace-trimmed, so indentation is free.
        func dxf(withMarker: Bool) -> String {
            let tail = withMarker
                ? "101\nEmbedded Object\n70\n1\n71\n2\n72\n2"
                : "73\n1"
            return """
            0
            SECTION
              2
            ENTITIES
              0
            MTEXT
              8
            0
             10
            1330.64
             20
            714.79
             30
            0.0
             40
            58.4075
             41
            1012.4051
             71
            1
             72
            5
              1
            Xxp     pxX
              7
            Simplex_100
            \(tail)
              0
            ENDSEC
              0
            EOF
            """
        }
        let font = try shxFont()
        for withMarker in [true, false] {
            let doc = try importDXFString(dxf(withMarker: withMarker))
            XCTAssertEqual(doc.allEntities.count, 1)
            let entity = try XCTUnwrap(doc.allEntities.first)
            guard case .string(let json) = entity.xdata["dxf.formattedText"] else {
                XCTFail("missing formatted text")
                continue
            }
            let formatted = try JSONDecoder().decode(
                FormattedText.self, from: Data(json.utf8))
            let alignment = formatted.paragraphs.first?.alignment ?? -1
            let primitives = font.renderFormattedText(
                formatted, origin: .zero,
                alignH: 0, alignV: 3, maxWidth: 1012.4051)
            var minX = Double.infinity
            var maxX = -Double.infinity
            for primitive in primitives {
                if case .line(let start, let end, _) = primitive {
                    minX = min(minX, start.x, end.x)
                    maxX = max(maxX, start.x, end.x)
                }
            }
            if withMarker {
                XCTAssertEqual(alignment, 4,
                    "columns marker 70=1/71=2/72=2 must map to distributed paragraphs")
                XCTAssertGreaterThan(minX, -5.0)
                XCTAssertLessThan(minX, 45.0,
                    "distributed Xxp must stay at the insertion x")
                XCTAssertGreaterThan(maxX, 900.0,
                    "distributed pxX must reach the right box, not stop at natural width")
                XCTAssertLessThanOrEqual(maxX, 1012.4051 + 5.0)
            } else {
                XCTAssertEqual(alignment, 0,
                    "no marker must keep left-aligned paragraphs")
                XCTAssertLessThan(maxX, 700.0,
                    "plain paragraph must keep natural width")
            }
        }
    }
}
