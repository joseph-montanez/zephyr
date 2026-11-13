import XCTest
import Foundation
@testable import ZephyrCore

// Byte-level DXF encoding regression tests (Vivienda Unifamiliar 2.dwg:
// "Ubicación" / "Diseño" rendered as "UbicaciÃ³n" / "DiseÃ±o").
//
// Fixtures are built as raw Data, not Swift Strings, so the test controls
// the exact file bytes: UTF-8 (R2007+), CP1252 (pre-2007), \U+ escapes,
// header order, and mixed invalid bytes.
@MainActor
final class DXFEncodingTests: XCTestCase {

    // MARK: - DXF byte builders

    private func p(_ code: Int, _ value: String) -> Data {
        pb(code, Data(value.utf8))
    }

    private func pb(_ code: Int, _ value: Data) -> Data {
        var d = Data(String(format: "%3d\r\n", code).utf8)
        d.append(value)
        d.append(Data("\r\n".utf8))
        return d
    }

    private func utf8(_ s: String) -> Data { Data(s.utf8) }

    private func buildDXF(
        version: Data,
        codePage: Data? = nil,
        reversedHeader: Bool = false,
        layers: [Data] = [],
        styles: [(Data, Data)] = [],
        entities: Data = Data()
    ) -> Data {
        var d = Data()
        let ver = version
        let cp = codePage
        // HEADER
        d.append(p(0, "SECTION"))
        d.append(p(2, "HEADER"))
        if reversedHeader {
            if let cp {
                d.append(p(9, "$DWGCODEPAGE"))
                d.append(pb(3, cp))
            }
            d.append(p(9, "$ACADVER"))
            d.append(pb(1, ver))
        } else {
            d.append(p(9, "$ACADVER"))
            d.append(pb(1, ver))
            if let cp {
                d.append(p(9, "$DWGCODEPAGE"))
                d.append(pb(3, cp))
            }
        }
        d.append(p(0, "ENDSEC"))
        // TABLES
        d.append(p(0, "SECTION"))
        d.append(p(2, "TABLES"))
        if !layers.isEmpty {
            d.append(p(0, "TABLE"))
            d.append(p(2, "LAYER"))
            d.append(p(70, String(layers.count)))
            for name in layers {
                d.append(p(0, "LAYER"))
                d.append(pb(2, name))
                d.append(p(70, "0"))
                d.append(p(62, "7"))
                d.append(p(6, "CONTINUOUS"))
            }
            d.append(p(0, "ENDTAB"))
        }
        if !styles.isEmpty {
            d.append(p(0, "TABLE"))
            d.append(p(2, "STYLE"))
            d.append(p(70, String(styles.count)))
            for (name, font) in styles {
                d.append(p(0, "STYLE"))
                d.append(pb(2, name))
                d.append(p(70, "0"))
                d.append(p(40, "0.0"))
                d.append(p(41, "1.0"))
                d.append(p(50, "0.0"))
                d.append(p(71, "0"))
                d.append(p(42, "0.0"))
                d.append(pb(3, font))
                d.append(p(4, ""))
            }
            d.append(p(0, "ENDTAB"))
        }
        d.append(p(0, "ENDSEC"))
        // BLOCKS (minimal model space)
        d.append(p(0, "SECTION"))
        d.append(p(2, "BLOCKS"))
        d.append(p(0, "BLOCK"))
        d.append(p(8, "0"))
        d.append(p(2, "*Model_Space"))
        d.append(p(70, "1"))
        d.append(p(10, "0.0"))
        d.append(p(20, "0.0"))
        d.append(p(30, "0.0"))
        d.append(p(3, "*Model_Space"))
        d.append(pb(1, Data()))
        d.append(p(0, "ENDBLK"))
        d.append(p(8, "0"))
        d.append(p(10, "0.0"))
        d.append(p(20, "0.0"))
        d.append(p(30, "0.0"))
        d.append(p(0, "ENDSEC"))
        // ENTITIES
        d.append(p(0, "SECTION"))
        d.append(p(2, "ENTITIES"))
        d.append(entities)
        d.append(p(0, "ENDSEC"))
        d.append(p(0, "EOF"))
        return d
    }

    private func textEntity(
        handle: String,
        layer: Data,
        text: Data,
        style: Data = Data("Standard".utf8)
    ) -> Data {
        var d = Data()
        d.append(p(0, "TEXT"))
        d.append(p(5, handle))
        d.append(p(330, "0"))
        d.append(p(100, "AcDbEntity"))
        d.append(pb(8, layer))
        d.append(p(100, "AcDbText"))
        d.append(p(10, "0.0"))
        d.append(p(20, "0.0"))
        d.append(p(30, "0.0"))
        d.append(p(40, "2.5"))
        d.append(pb(1, text))
        d.append(pb(7, style))
        return d
    }

    private func mTextEntity(
        handle: String,
        layer: Data,
        chunks: [(Int, Data)],
        style: Data = Data("Standard".utf8)
    ) -> Data {
        var d = Data()
        d.append(p(0, "MTEXT"))
        d.append(p(5, handle))
        d.append(p(330, "0"))
        d.append(p(100, "AcDbEntity"))
        d.append(pb(8, layer))
        d.append(p(100, "AcDbMText"))
        d.append(p(10, "0.0"))
        d.append(p(20, "0.0"))
        d.append(p(30, "0.0"))
        d.append(p(40, "2.5"))
        d.append(p(41, "0.0"))
        d.append(p(71, "1"))
        d.append(p(72, "5"))
        for (code, value) in chunks {
            d.append(pb(code, value))
        }
        d.append(pb(7, style))
        return d
    }

    private func importBytes(_ data: Data) throws -> DXFImportResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoding_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try DXFImporter.importDXFViews(filePath: url.path)
    }

    private func mTextRaw(
        _ imported: DXFImportResult,
        handle: String? = nil,
        containing needle: String
    ) -> String? {
        for entity in imported.entities {
            guard case .string(let s) = entity.xdata["dxf.mtextRaw"] else { continue }
            if s.contains(needle) { return s }
        }
        if let handle {
            for entity in imported.entities {
                guard case .string(let s) = entity.xdata["dxf.mtextRaw"] else { continue }
                if case .string(let h) = entity.xdata["dxf.handle"], h == handle {
                    return s
                }
            }
        }
        return nil
    }

    private func formattedPlainText(_ imported: DXFImportResult, containing needle: String) -> String? {
        for entity in imported.entities {
            guard case .string(let json) = entity.xdata["dxf.formattedText"] else { continue }
            guard let data = json.data(using: .utf8),
                  let formatted = try? JSONDecoder().decode(FormattedText.self, from: data)
            else { continue }
            let plain = formatted.toPlainText()
            if plain.contains(needle) { return plain }
        }
        return nil
    }

    // MARK: - Reader-level: R2018 UTF-8 with ANSI_1252 header

    func testR2018Utf8MTextPreservesAccentedScalars() throws {
        let entities =
            mTextEntity(handle: "D2ABC", layer: utf8("0"),
                        chunks: [(1, utf8("{\\Fromans|c0;\\W1;\\T0.75;\\C7;Ubicación{\\W0.1; }:}"))])
            + mTextEntity(handle: "D2ABD", layer: utf8("0"),
                          chunks: [(1, utf8("{\\Fromans|c0;\\W1;\\T0.75;\\C7;Diseño{\\W0.1; }:}"))])
        let data = buildDXF(
            version: utf8("AC1032"), codePage: utf8("ANSI_1252"),
            layers: [utf8("E-03 Textos Pequeños"), utf8("Pórticos")],
            styles: [(utf8("TJ Eléctricas"), utf8("swissel.ttf")),
                     (utf8("CVLARRY"), utf8("swissel.ttf"))],
            entities: entities)
        let reader = try DXFReader().readData(data)
        XCTAssertEqual(reader.version.rawValue, "AC1032")
        XCTAssertEqual(reader.header.codePage, "ANSI_1252")
        XCTAssertEqual(reader.textCodec.version.rawValue, "AC1032")

        let mtexts = reader.entities.compactMap { $0 as? DXFMTextEntity }
        let ubi = try XCTUnwrap(mtexts.first { $0.text.contains("Ubicaci") })
        let dis = try XCTUnwrap(mtexts.first { $0.text.contains("Dise") })
        XCTAssertTrue(ubi.text.contains("Ubicación"), "MTEXT Ubicación decoded as \(ubi.text)")
        XCTAssertTrue(dis.text.contains("Diseño"), "MTEXT Diseño decoded as \(dis.text)")
        XCTAssertFalse(ubi.text.contains("UbicaciÃ"), "MTEXT shows UTF-8-as-Latin1 mojibake")
        XCTAssertFalse(dis.text.contains("DiseÃ"), "MTEXT shows UTF-8-as-Latin1 mojibake")
        // Scalar-level pin: single U+00F3 / U+00F1, not U+00C3 + continuations.
        XCTAssertTrue(ubi.text.contains("\u{00F3}"))
        XCTAssertTrue(dis.text.contains("\u{00F1}"))
        XCTAssertFalse(ubi.text.contains("\u{00C3}"))
        XCTAssertFalse(dis.text.contains("\u{00C3}"))

        XCTAssertTrue(reader.layers.contains { $0.name == "E-03 Textos Pequeños" })
        XCTAssertTrue(reader.layers.contains { $0.name == "Pórticos" })
        XCTAssertTrue(reader.textstyles.contains { $0.name == "TJ Eléctricas" })

        let imported = try importBytes(data)
        XCTAssertNotNil(mTextRaw(imported, containing: "Ubicación"))
        XCTAssertNotNil(mTextRaw(imported, containing: "Diseño"))
        XCTAssertNotNil(formattedPlainText(imported, containing: "Ubicación"))
        XCTAssertNotNil(formattedPlainText(imported, containing: "Diseño"))
        XCTAssertTrue(imported.entities.contains { entity in
            if case .string(let s) = entity.xdata["dxf.text"] { return s.contains("Ubicación") }
            return false
        })
    }

    // MARK: - Reader-level: R2004 CP1252 (including 0x93 smart quote)

    func testR2004Cp1252DecodesWithWindowsTable() throws {
        let phrase = Data("Dise".utf8) + Data([0xF1]) + Data("o ".utf8) + Data([0x93]) + Data("X".utf8) + Data([0x94])
        let mtext = mTextEntity(handle: "A1", layer: Data("P".utf8) + Data([0xF3]) + Data("rticos".utf8),
                                chunks: [(1, phrase)])
        let data = buildDXF(
            version: utf8("AC1018"), codePage: utf8("ANSI_1252"),
            layers: [Data("P".utf8) + Data([0xF3]) + Data("rticos".utf8)],
            entities: mtext)
        // The file must be invalid UTF-8 (bare 0xF3) while remaining valid CP1252.
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertNotNil(String(data: data, encoding: .windowsCP1252))

        let reader = try DXFReader().readData(data)
        let decoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(decoded.text.contains("Diseño"), "CP1252 ñ decoded as \(decoded.text)")
        XCTAssertTrue(decoded.text.contains("\u{201C}X\u{201D}"),
                      "CP1252 0x93/0x94 must be smart quotes, got \(decoded.text)")
        XCTAssertFalse(decoded.text.contains("\u{0093}"), "CP1252 decoded as Latin-1 control")
        XCTAssertTrue(reader.layers.contains { $0.name == "Pórticos" })
        XCTAssertEqual(reader.layers.first?.name, "Pórticos")
    }

    // MARK: - Reader-level: \U+ escapes

    func testUnicodeEscapesDecode() throws {
        let mtext = mTextEntity(handle: "B2", layer: utf8("0"),
                                chunks: [(1, utf8("Ubicaci\\U+00F3n Dise\\U+00F1o \\U+5BB6"))])
        let data = buildDXF(version: utf8("AC1018"), codePage: utf8("ANSI_1252"), entities: mtext)
        let reader = try DXFReader().readData(data)
        let decoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(decoded.text.contains("Ubicación"), "escape ó decoded as \(decoded.text)")
        XCTAssertTrue(decoded.text.contains("Diseño"), "escape ñ decoded as \(decoded.text)")
        XCTAssertTrue(decoded.text.contains("\u{5BB6}"), "CJK escape decoded as \(decoded.text)")
    }

    // MARK: - Header order / missing code page

    func testReversedHeaderOrderPreservesUtf8() throws {
        let mtext = mTextEntity(handle: "C3", layer: utf8("0"),
                                chunks: [(1, utf8("Diseño"))])
        let data = buildDXF(
            version: utf8("AC1032"), codePage: utf8("ANSI_1252"),
            reversedHeader: true, entities: mtext)
        let reader = try DXFReader().readData(data)
        XCTAssertEqual(reader.version.rawValue, "AC1032")
        let decoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(decoded.text.contains("Diseño"), "reversed header decoded as \(decoded.text)")
    }

    func testMissingCodePageDefaultsToCp1252() throws {
        // Pre-2007 CP1252 bytes with no $DWGCODEPAGE: default is ANSI_1252.
        let phrase = Data("Ubicaci".utf8) + Data([0xF3]) + Data("n".utf8)
        let mtext = mTextEntity(handle: "D4", layer: utf8("0"), chunks: [(1, phrase)])
        let data = buildDXF(version: utf8("AC1018"), codePage: nil, entities: mtext)
        let reader = try DXFReader().readData(data)
        let decoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(decoded.text.contains("Ubicación"), "default CP1252 decoded as \(decoded.text)")
    }

    // MARK: - MTEXT group 3+1 chunks and significant spaces

    func testMTextChunkedGroup3PlusGroup1PreservesAccentsAndSpaces() throws {
        // Group 3 then group 1 in file order; leading space in group 1 is content.
        let part1 = utf8("{\\Fromans|c0;\\W1;\\T0.75;\\C7;Ubicación{\\W0.1; }:}")
        let part2 = utf8(" -  SE UTILIZARA Diseño")
        let mtext = mTextEntity(handle: "E5", layer: utf8("0"),
                                chunks: [(3, part1), (1, part2)])
        let data = buildDXF(version: utf8("AC1032"), codePage: utf8("ANSI_1252"), entities: mtext)
        let reader = try DXFReader().readData(data)
        let decoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(decoded.text.contains("Ubicación"), "chunk part 1 decoded as \(decoded.text)")
        XCTAssertTrue(decoded.text.contains(" -  SE UTILIZARA Diseño"),
                      "group-1 leading spaces + accents decoded as \(decoded.text)")
        XCTAssertTrue(decoded.text.contains(" -  "))
    }

    // MARK: - Mixed invalid byte must not poison valid UTF-8 values (tokenizer branch)

    func testOneCp1252DegreeByteDoesNotPoisonUtf8Values() throws {
        // R2018 UTF-8 file with one unrelated CP1252 degree byte (like floorplan.dxf's 0xB0).
        // Whole-file UTF-8 decode fails on that byte; per-value handling must still
        // keep the UTF-8 MTEXT correct and decode the CP1252 value via code page.
        let mtext = mTextEntity(handle: "F6", layer: utf8("0"),
                                chunks: [(1, utf8("Diseño"))])
        let cp1252Text = textEntity(handle: "F7", layer: utf8("0"),
                                    text: Data("45".utf8) + Data([0xB0]) + Data(" TO 60".utf8))
        let data = buildDXF(
            version: utf8("AC1032"), codePage: utf8("ANSI_1252"),
            entities: mtext + cp1252Text)
        XCTAssertNil(String(data: data, encoding: .utf8), "fixture must be invalid UTF-8")
        let reader = try DXFReader().readData(data)
        let mdecoded = try XCTUnwrap(reader.entities.compactMap { $0 as? DXFMTextEntity }.first)
        XCTAssertTrue(mdecoded.text.contains("Diseño"),
                      "valid UTF-8 value must survive one invalid byte, got \(mdecoded.text)")
        let texts = reader.entities.compactMap { $0 as? DXFTextEntity }.filter { !($0 is DXFMTextEntity) }
        let cpText = try XCTUnwrap(texts.first)
        XCTAssertTrue(cpText.text.contains("\u{00B0}"), "CP1252 degree decoded as \(cpText.text)")
    }

    // MARK: - Export byte encoding

    private func exportBytes(version: DXFVersion) throws -> Data {
        let doc = CADDocument()
        let layer = Layer(name: "Ubicación", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let prim = CADPrimitive.text(
            position: Vector3(x: 0, y: 0, z: 0),
            text: "Diseño",
            height: 2.5, rotation: 0, style: "Standard",
            alignH: 0, alignV: 0, mtextWidth: 0, color: .white)
        let block = CADBlock(name: "B", geometry: [prim])
        doc.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc_export_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: doc, to: url, dxfVersion: version)
        return try Data(contentsOf: url)
    }

    func testR2018ExportWritesUtf8Bytes() throws {
        let data = try exportBytes(version: .r2018)
        XCTAssertNotNil(data.range(of: Data("Diseño".utf8)), "R2018 export must contain UTF-8 ñ")
        XCTAssertNotNil(data.range(of: Data("Ubicación".utf8)), "R2018 export must contain UTF-8 ó")
        XCTAssertNil(data.range(of: Data("DiseÃ±o".utf8)), "R2018 export must not contain mojibake")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8), "R2018 export must be valid UTF-8")
        XCTAssertTrue(text.contains("AC1032"))
    }

    func testR2004ExportWritesCp1252Bytes() throws {
        let data = try exportBytes(version: .r2004)
        XCTAssertNotNil(data.range(of: Data("Dise".utf8) + Data([0xF1]) + Data("o".utf8)),
                        "R2004 export must contain CP1252 ñ (F1)")
        XCTAssertNil(data.range(of: Data("Diseño".utf8)), "R2004 export must not contain UTF-8 ñ")
        XCTAssertNil(data.range(of: Data("DiseÃ±o".utf8)), "R2004 export must not contain mojibake")
        let text = try XCTUnwrap(String(data: data, encoding: .windowsCP1252),
                                 "R2004 export must be valid CP1252")
        XCTAssertTrue(text.contains("Diseño"))
        XCTAssertTrue(text.contains("AC1018"))
    }

    // MARK: - EAB round-trip preserves scalars

    func testEABRoundTripPreservesAccentedScalars() throws {
        let doc = CADDocument()
        let layer = Layer(name: "Ubicación", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let prim = CADPrimitive.text(
            position: Vector3(x: 0, y: 0, z: 0),
            text: "Diseño",
            height: 2.5, rotation: 0, style: "Standard",
            alignH: 0, alignV: 0, mtextWidth: 0, color: .white)
        let block = CADBlock(name: "B", geometry: [prim])
        doc.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc_eab_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: doc, to: url)
        let views = try EABReader.readViews(from: url)
        let reread = try XCTUnwrap(views.first).document
        XCTAssertTrue(reread.allLayers.contains { $0.name == "Ubicación" })
        var foundText = false
        for b in reread.allBlocks {
            for p in b.geometry {
                if case .text(_, let t, _, _, _, _, _, _, _) = p, t == "Diseño" {
                    foundText = true
                }
            }
        }
        XCTAssertTrue(foundText, "EAB round-trip must preserve Diseño")
    }
}
