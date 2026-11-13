import XCTest
@testable import ZephyrCore

/// Regression coverage for the DDEDIT text-shift bug: double-clicking an
/// imported paragraph-centered MTEXT (e.g. "CIMENTACIONES / GENERALES") and
/// pressing OK used to rebuild it with FormattedText.plain, resetting
/// paragraph alignment [1,1] -> [0,0] and shifting every line off its
/// centered anchor; writing mtextRaw = "" also blanked the exported text.
///
/// `DDEditCommand.applyTextEdits` needs a live PhrostEngine (SDL window) so
/// it is not constructible here; these tests pin the engine-free seams it
/// now delegates to: `FormattedText.applyingPlainText`, the transform delta,
/// and the DXFWriterBridge legacy-raw fallback.
@MainActor
final class DDEditPreservationTests: XCTestCase {

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddedit_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    private func decodedFormatted(_ entity: CADEntity) throws -> FormattedText {
        guard case .string(let json) = entity.xdata["dxf.formattedText"] else {
            XCTFail("missing formatted text")
            throw NSError(domain: "DDEditPreservationTests", code: 1)
        }
        return try JSONDecoder().decode(
            FormattedText.self, from: Data(json.utf8))
    }

    private func exportTexts(_ doc: CADDocument) throws -> [String] {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddedit_export_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let reimported = CADDocument()
        try reimported.importDXF(url: outURL)
        var texts: [String] = []
        for entity in reimported.allEntities {
            if case .string(let s) = entity.xdata["dxf.text"] {
                texts.append(s)
            }
        }
        return texts
    }

    /// MTEXT like the reported sheet: attachment 5 (center-middle),
    /// paragraph centered via \pxqc; on both lines, reference width 100.
    private var centeredMTEXT: String {
        """
        0
        SECTION
          2
        ENTITIES
          0
        MTEXT
          8
        0
         10
        50.0
         20
        50.0
         30
        0.0
         40
        10.0
         41
        100.0
         71
        5
         72
        1
          1
        \\pxqc;CIMENTACIONES\\P\\pxqc;GENERALES
          7
        Standard
          0
        ENDSEC
          0
        EOF
        """
    }

    func testImportIsParagraphCentered() throws {
        let doc = try importDXFString(centeredMTEXT)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let formatted = try decodedFormatted(entity)
        XCTAssertEqual(formatted.paragraphs.map(\.alignment), [1, 1])
    }

    func testNoOpEditPreservesParagraphAlignment() throws {
        let doc = try importDXFString(centeredMTEXT)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let original = try decodedFormatted(entity)
        let edited = original.applyingPlainText(
            original.toPlainText(), styleName: "Standard",
            font: original.defaultFont, height: original.defaultHeight)
        XCTAssertEqual(edited.paragraphs.map(\.alignment), [1, 1])
        XCTAssertEqual(edited.toPlainText(), original.toPlainText())
    }

    func testOneCharacterEditKeepsNeighboringParagraphCentered() throws {
        let doc = try importDXFString(centeredMTEXT)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let original = try decodedFormatted(entity)
        let edited = original.applyingPlainText(
            "CIMENTACIONES\nGENERALES!", styleName: "Standard",
            font: original.defaultFont, height: original.defaultHeight)
        XCTAssertEqual(edited.paragraphs.map(\.alignment), [1, 1])
        XCTAssertEqual(edited.paragraphs[0].plainText, "CIMENTACIONES")
        XCTAssertEqual(edited.paragraphs[1].plainText, "GENERALES!")
    }

    func testLineCountChangeKeepsPerIndexAlignment() throws {
        let original = FormattedText(
            styleName: "Standard", defaultFont: "simplex.shx",
            defaultHeight: 2.5,
            paragraphs: [
                FormattedParagraph(
                    alignment: 1,
                    runs: [FormattedTextRun(text: "one")]),
                FormattedParagraph(
                    alignment: 2,
                    runs: [FormattedTextRun(text: "two")]),
            ])
        let edited = original.applyingPlainText(
            "one\ntwo\nthree", styleName: "Standard",
            font: "simplex.shx", height: 2.5)
        XCTAssertEqual(edited.paragraphs.map(\.alignment), [1, 2, 0])
        XCTAssertEqual(edited.toPlainText(), "one\ntwo\nthree")
    }

    func testHeightChangeScalesRunHeightsAndKeepsAlignment() throws {
        var original = FormattedText.plain(
            "BIG small", styleName: "Standard",
            font: "simplex.shx", height: 10.0)
        original.paragraphs[0].alignment = 1
        original.paragraphs[0].runs = [
            FormattedTextRun(text: "BIG", height: 20.0),
            FormattedTextRun(text: " small", height: 10.0),
        ]
        let edited = original.applyingPlainText(
            "BIG small", styleName: "Standard",
            font: "simplex.shx", height: 5.0)
        XCTAssertEqual(edited.paragraphs[0].alignment, 1)
        XCTAssertEqual(edited.defaultHeight, 5.0)
        let heights = edited.paragraphs[0].runs.compactMap(\.height)
        XCTAssertEqual(heights.count, 2)
        if heights.count == 2 {
            XCTAssertEqual(heights[0], 10.0, accuracy: 1e-9)
            XCTAssertEqual(heights[1], 5.0, accuracy: 1e-9)
        }
    }

    /// Legacy files edited before the fix carry mtextRaw = "" (non-nil).
    /// Export must fall back to the serialized formatted text instead of
    /// writing an empty MTEXT value.
    func testExportWithLegacyEmptyMTextRawKeepsText() throws {
        let doc = try importDXFString(centeredMTEXT)
        let entity = try XCTUnwrap(doc.allEntities.first)
        var edited = entity
        edited.xdata["dxf.mtextRaw"] = .string("")
        doc.replaceEntity(edited)
        let texts = try exportTexts(doc)
        XCTAssertTrue(
            texts.contains { $0.contains("CIMENTACIONES") },
            "exported MTEXT must keep its text, got \(texts)")
    }

    /// The new DDEDIT writes the serialized raw string; export then
    /// re-imports with paragraph alignment intact.
    func testExportWithSerializedMTextRawKeepsAlignment() throws {
        let doc = try importDXFString(centeredMTEXT)
        let entity = try XCTUnwrap(doc.allEntities.first)
        let formatted = try decodedFormatted(entity)
        let updated = formatted.applyingPlainText(
            "CIMENTACIONES\nGENERALES", styleName: "Standard",
            font: formatted.defaultFont, height: formatted.defaultHeight)
        var edited = entity
        edited.xdata["dxf.mtextRaw"] = .string(
            MTEXTFormatter.serialize(updated))
        doc.replaceEntity(edited)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddedit_export_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let reimported = CADDocument()
        try reimported.importDXF(url: outURL)
        let roundTrip = try XCTUnwrap(reimported.allEntities.first)
        let roundTripFormatted = try decodedFormatted(roundTrip)
        XCTAssertEqual(roundTripFormatted.paragraphs.map(\.alignment), [1, 1])
        XCTAssertEqual(roundTripFormatted.toPlainText(), "CIMENTACIONES\nGENERALES")
    }

    /// Rotation-only edits compose a local delta onto the original
    /// transform, so scale (and position) survive. Mirrors the math in
    /// DDEditCommand.applyTextEdits.
    func testRotationDeltaPreservesTransformScale() {
        let original = Transform3D.translated(by: Vector3(x: 10, y: 10, z: 0))
            .multiplying(by: .scaled(by: Vector3(x: 2, y: 2, z: 1)))
            .multiplying(by: .rotated(by: 0.3))
        XCTAssertEqual(original.rotation, 0.3, accuracy: 1e-9,
                       "fixture must exercise a nontrivial original rotation")
        let newRotation = original.rotation + 0.25
        let updated = original.multiplying(
            by: .rotated(by: newRotation - original.rotation))
        XCTAssertEqual(updated.scale.x, original.scale.x, accuracy: 1e-9)
        XCTAssertEqual(updated.scale.y, original.scale.y, accuracy: 1e-9)
        XCTAssertEqual(updated.position.x, original.position.x, accuracy: 1e-9)
        XCTAssertEqual(updated.position.y, original.position.y, accuracy: 1e-9)
        XCTAssertEqual(updated.rotation, newRotation, accuracy: 1e-9)
    }
}
