import XCTest
import Foundation
@testable import ZephyrCore

/// Regression tests for the Pirate Ship PDF export text failures:
/// multi-paragraph TTF MTEXT collapsed to a single truncated line,
/// and ACAD_TABLE content (borders and cell text) dropped entirely.
@MainActor
final class PDFExportTextTests: XCTestCase {

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layer = Layer(handle: UUID(), name: "0", isVisible: true,
                          lineWeight: 0.25, color: .black, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layer.handle)
    }

    private func emittedContent(for doc: CADDocument) -> String {
        let items = PDFExporter.collectItems(document: doc)
        let cb = PDFContentBuilder()
        PDFExporter.writeContent(
            items: items, document: doc, scale: 2.0, margin: 0,
            minX: 0, maxX: 200, minY: -100, maxY: 100,
            pageW: 600, pageH: 600, isLightBackground: false, to: cb)
        return String(decoding: cb.build(), as: UTF8.self)
    }

    // MARK: - ACAD_TABLE must paint (RC3)

    func testTableEntityEmitsBorderStrokes() throws {
        let (doc, layerID) = makeDoc()
        let column = DataTableColumn(name: "Note")
        let data = DataTableData(
            columns: [column],
            rows: [
                DataTableRow(cells: [DataTableCell(columnID: column.id, value: .string("FIRST"))]),
                DataTableRow(cells: [DataTableCell(columnID: column.id, value: .string("SECOND"))]),
            ],
            title: "NOTES")
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.table(data: data, origin: .zero, color: nil)]))

        let output = emittedContent(for: doc)
        let strokeOps = output.components(separatedBy: " S\n").count - 1
        XCTAssertGreaterThan(
            strokeOps, 0,
            "table borders must be emitted to the PDF content stream; got: \(output)")
    }

    // MARK: - Export options persistence (EXPORTPDF popup)

    func testExportOptionsPersistRoundTrip() {
        let store = UserDefaults.standard
        let keys = [
            "Zephyr.ExportPDF.CaptureFonts",
            "Zephyr.ExportPDF.ConvertAllTextToGeometry",
            "Zephyr.ExportPDF.IncludeHiddenTextForSHX",
            "Zephyr.ExportPDF.OpenInViewer",
        ]
        let saved = keys.map { ($0, store.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    store.set(value, forKey: key)
                } else {
                    store.removeObject(forKey: key)
                }
            }
        }
        PDFExporter.PDFExportOptions(
            captureFonts: false, convertAllTextToGeometry: true,
            includeHiddenTextForSHX: false
        ).persist()
        PDFExporter.PDFExportOptions.persistOpenInViewer(true)
        let loaded = PDFExporter.PDFExportOptions.loadPersisted()
        XCTAssertFalse(loaded.captureFonts)
        XCTAssertTrue(loaded.convertAllTextToGeometry)
        XCTAssertFalse(loaded.includeHiddenTextForSHX)
        XCTAssertTrue(PDFExporter.PDFExportOptions.loadPersistedOpenInViewer())

        for key in keys { store.removeObject(forKey: key) }
        let defaults = PDFExporter.PDFExportOptions.loadPersisted()
        XCTAssertTrue(defaults.captureFonts, "AutoCAD default: capture on")
        XCTAssertFalse(defaults.convertAllTextToGeometry)
        XCTAssertTrue(defaults.includeHiddenTextForSHX)
        XCTAssertFalse(PDFExporter.PDFExportOptions.loadPersistedOpenInViewer())
    }

    // MARK: - Pirate Ship end to end

    func testPirateShipSheetExportsLiveTextAndTables() throws {
        let dxfPath = "C:/dev/dxf/186-841 - KOMPAN, Inc. - Pirate Ship.dxf"
        guard FileManager.default.fileExists(atPath: dxfPath) else {
            throw XCTSkip("external fixture \(dxfPath) not present")
        }
        let imported = try DXFImporter.importDXFViews(filePath: dxfPath)
        let sheet = try XCTUnwrap(imported.views.first(where: { $0.name == "CADdetails" }))

        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers, blocks: imported.blocks, entities: sheet.entities)
        for (name, style) in imported.textStyles {
            doc.textStyles[name] = style
        }
        doc.plotSettings = sheet.plotSettings
        doc.layoutSettings = sheet.layoutSettings

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(pdfString.contains("FontFile2"), "TTF faces must be embedded")
        XCTAssertTrue(pdfString.contains("ToUnicode"), "embedded text needs a ToUnicode map")
        XCTAssertFalse(
            pdfString.contains("SPECIFICATIONS\\n"),
            "SPECIFICATIONS must not collapse into one Tj with escaped newlines")

        // Searchable text via the pdfium vector extractor.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pirate_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try pdfData.write(to: tmpURL)
        guard let page = PDFiumBridge.extractVectorPage(path: tmpURL.path, pageIndex: 0) else {
            throw XCTSkip("pdfium unavailable in this environment")
        }
        let texts = page.textEntities.flatMap { $0 }.compactMap { prim -> String? in
            if case .text(_, let text, _, _, _, _, _, _, _) = prim { return text }
            return nil
        }
        XCTAssertTrue(
            texts.contains(where: { $0.contains("PIRATE") }),
            "PIRATE SHIP title must be extractable text, got \(texts.count) runs")
        XCTAssertTrue(
            texts.contains(where: { $0.contains("INSTALLATION TO BE COMPLETED") }),
            "NOTES table text must be extractable")
        XCTAssertTrue(
            texts.contains(where: { $0.contains("SPECIFICATIONS") }),
            "SPECIFICATIONS block must be extractable")
    }

    // MARK: - Scaled table entity must emit world-sized cell text

    func testScaledTableEntityEmitsWorldSizedText() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["NOTES"] = CADTextStyle(name: "NOTES", fontFile: "ARIALN.TTF")
        // Reference standalone TEXT at identity: world height 2.5.
        var refXData: [String: XDataValue] = [:]
        refXData["dxf.text"] = .string("REFMARK")
        refXData["dxf.textHeight"] = .double(2.5)
        refXData["dxf.textStyle"] = .string("NOTES")
        doc.addEntity(CADEntity(
            layerID: layerID, localGeometry: [],
            transform: .identity, xdata: refXData))
        // Table with local cell height 3.18 under a 4.69x entity transform:
        // cells must extract at 3.18 * 4.69, like the reference's 2.5 * 1.
        let column = DataTableColumn(name: "C", width: 60)
        let cell = DataTableCell(columnID: column.id, value: .string("SCALEDCELL"))
        let data = DataTableData(
            columns: [column], rows: [DataTableRow(cells: [cell])],
            rowHeights: [5.0], defaultRowHeight: 5.0, defaultColumnWidth: 60,
            textHeight: 3.18, textStyleName: "NOTES")
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.table(data: data, origin: .zero, color: nil)],
            transform: .scaled(by: Vector3(x: 4.69, y: 4.69, z: 1))))

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaled_table_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try pdfData.write(to: tmpURL)
        guard let page = PDFiumBridge.extractVectorPage(path: tmpURL.path, pageIndex: 0) else {
            throw XCTSkip("pdfium unavailable in this environment")
        }
        func height(of needle: String) -> Double? {
            page.textEntities.flatMap { $0 }.compactMap { prim -> Double? in
                if case .text(_, let text, let h, _, _, _, _, _, _) = prim,
                   text.contains(needle) { return h }
                return nil
            }.max()
        }
        let refH = try XCTUnwrap(height(of: "REFMARK"), "reference text must extract")
        let cellH = try XCTUnwrap(height(of: "SCALEDCELL"), "table cell text must extract")
        // Same face and route on both sides: extractor gain cancels, leaving
        // the world-height ratio (3.18 * 4.69) / (2.5 * 1).
        XCTAssertEqual(cellH / refH, (3.18 * 4.69) / 2.5, accuracy: 0.2 * (3.18 * 4.69) / 2.5)
    }

    // MARK: - TTF MTEXT must not collapse to one line (RC1/RC2)

    // MARK: - SS-11 title block (extension-less SHX styles vs tight TTF cells)

    /// SS-11 regression: styles backed by extension-less SHX names
    /// (`romand`, `simplex`, `txt`) must never resolve to a TrueType
    /// substitute. The exporter used to match them to the bundled Arial
    /// fallback, which is wider than romand and wrapped GENERAL NOTES.
    func testExtensionlessSHXStylesDoNotResolveToTTF() throws {
        for name in ["romand", "simplex", "txt", "bold.shx", "ROMANT.SHX"] {
            XCTAssertNotNil(
                CADFontManager.getOrLoadSHXFont(filename: name, allowFallback: false),
                "\(name) must load as an SHX face from the bundled Fonts")
            XCTAssertNil(
                CADFontManager.getTTFEquivalent(filename: name),
                "\(name) has a loadable SHX face, so no TTF equivalent may win")
        }
        XCTAssertNotNil(
            CADFontManager.getTTFEquivalent(filename: "arial.ttf"),
            "genuine TTF requests must keep resolving")
    }

    /// SS-11 regression: GENERAL NOTES is style TEXT (romand SHX) with a
    /// `\H0.8x;` run. It must take the SHX stroke route — never live Arial
    /// text — so the note keeps romand metrics and stays on one line.
    func testRomandNotesTakeSHXRoute() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["TEXT"] = CADTextStyle(name: "TEXT", fontFile: "romand")
        addMText(
            to: doc, layerID: layerID,
            raw: "GENERAL NOTES:\\P\\P{\\H0.8x;1. ALL SEWER PIPE SHALL BE ASTM 3034 SDR 35.\\P\\P2. LOCATED IN CENTER OF CUL-DE-SAC WHEN APPROPRIATE.}",
            style: "TEXT", height: 0.1, width: 3.30952380952381)

        let items = PDFExporter.collectItems(document: doc)
        let strokes = items.filter {
            if case .textStrokes = $0 { return true }; return false
        }
        let live = items.filter {
            if case .embeddedText = $0 { return true }; return false
        }
        XCTAssertFalse(strokes.isEmpty, "romand MTEXT must explode to SHX strokes")
        XCTAssertTrue(live.isEmpty, "romand MTEXT must not emit live TTF text, got \(live.count) runs")

        let output = emittedContent(for: doc)
        XCTAssertFalse(
            output.contains("/BaseFont /TEXT"),
            "no style-named substitute font may be registered")
    }

    /// SS-11 regression: title-block cells whose DXF reference widths are
    /// AutoCAD-tight (Arial measures 0.1–1% over) must not wrap in the PDF.
    /// The screen tolerates ~2% ( EngineTextManager wrap tolerance); the PDF
    /// must match, or `DWG. BY` collides with `PW` and `JAN. 2012` splits.
    func testTightTitleCellsDoNotWrap() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["JAYTEXT"] = CADTextStyle(name: "JAYTEXT", fontFile: "arial.ttf")
        doc.textStyles["SIMPLEX"] = CADTextStyle(name: "SIMPLEX", fontFile: "simplex")
        addMText(
            to: doc, layerID: layerID,
            raw: "DWG. BY", style: "JAYTEXT", height: 0.08,
            width: 0.4842379263301501)
        addMText(
            to: doc, layerID: layerID,
            raw: "JAN. 2012", style: "JAYTEXT", height: 0.08,
            width: 0.5167618008185539)
        addMText(
            to: doc, layerID: layerID,
            raw: "\\pxqc;{\\fArial|b0|i0|c0|p34;NOT TO\\PSCALE}",
            style: "SIMPLEX", height: 0.1, width: 0.5224188267394271)

        let output = emittedContent(for: doc)
        let tjCount = output.components(separatedBy: "Tj").count - 1
        XCTAssertEqual(
            tjCount, 4,
            "DWG. BY, JAN. 2012, and NOT TO/SCALE must stay on their own lines; got: \(output)")
    }

    /// `\H` run scaling must shrink the measured width on the TTF path, so
    /// a `\H0.8x;` note that fits on screen also fits in the PDF.
    func testPerRunHeightScalesWrapping() throws {
        let formatted = MTEXTFormatter.parse(
            "{\\H0.8x;1. ALL SEWER PIPE SHALL BE ASTM 3034 SDR 35.}",
            defaultFont: "F", defaultHeight: 0.1)
        let full = CADTextFormatter.layout(
            formatted: formatted, maxWidth: 3.30952380952381,
            measure: { Double($0.count) * 0.084 })
        XCTAssertEqual(full.count, 1, "scaled run must fit: \(full.map { $0.text })")
        let unscaled = CADTextFormatter.layout(
            "1. ALL SEWER PIPE SHALL BE ASTM 3034 SDR 35.",
            maxWidth: 3.30952380952381,
            measure: { Double($0.count) * 0.084 })
        XCTAssertGreaterThan(unscaled.count, 1, "unscaled text must wrap at this width")
    }

    /// Two registrations of the same face under different display names share
    /// one `/F` number in page resources (the old code emitted `/F7 /F7`
    /// and wrote the font objects twice).
    func testFontCatalogDedupesAliasedFacesInResources() throws {
        let path = try XCTUnwrap(
            CADFontManager.getTTFEquivalent(filename: "arial.ttf"),
            "bundled arial.ttf must resolve")
        let font = try XCTUnwrap(CADFontManager.getOrLoadTTFFont(path: path))
        let catalog = PDFTextEmitter.PDFFontCatalog()
        let first = PDFTextEmitter.ResolvedFace(
            font: font, path: path, substituted: false, simulatedBold: false)
        let n1 = catalog.register(
            face: first, displayName: "JAYTEXT", captureOn: false, scalars: [65])
        let n2 = catalog.register(
            face: first, displayName: "Arial", captureOn: false, scalars: [65])
        XCTAssertEqual(n1, n2, "the same face file shares one font object")
        let resources = catalog.resourceString()
        XCTAssertEqual(
            resources.components(separatedBy: "/F\(n1) ").count - 1, 1,
            "each font number must appear once; got: \(resources)")
    }

    /// End to end over the real sheet when the DWG is present (same gating
    /// style as the Pirate Ship test): convert with ODA, import, export the
    /// paper-space sheet, and check the SS-11 title block reads as drawn.
    func testSS11PaperSpaceExportsAsSeenOnScreen() throws {
        let dwg = "C:/Users/xingo/Downloads/SS-11 6 Inch Lateral Cleanout.dwg"
        guard FileManager.default.fileExists(atPath: dwg) else {
            throw XCTSkip("SS-11 fixture \(dwg) not present")
        }
        guard ODADWGConverter.locateConverter() != nil else {
            throw XCTSkip("ODA FileConverter not installed")
        }
        let tmpDXF = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss11_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmpDXF) }
        try ODADWGConverter.convertSync(
            input: URL(fileURLWithPath: dwg), output: tmpDXF, toFormat: "DXF")
        let imported = try DXFImporter.importDXFViews(filePath: tmpDXF.path)
        let sheet = try XCTUnwrap(
            imported.views.first(where: { view in
                view.entities.contains { entity in
                    guard case .string(let text) = entity.xdata["dxf.text"] else { return false }
                    return text.contains("SS-11")
                }
            }),
            "a paper-space view must carry the SS-11 title block")

        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers, blocks: imported.blocks, entities: sheet.entities)
        for (name, style) in imported.textStyles {
            doc.textStyles[name] = style
        }
        doc.plotSettings = sheet.plotSettings
        doc.layoutSettings = sheet.layoutSettings

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(
            pdfString.contains("/BaseFont /TEXT"),
            "no style-named substitute font may be registered")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss11_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try pdfData.write(to: tmpURL)
        guard let page = PDFiumBridge.extractVectorPage(path: tmpURL.path, pageIndex: 0) else {
            throw XCTSkip("pdfium unavailable in this environment")
        }
        let texts = page.textEntities.flatMap { $0 }.compactMap { prim -> String? in
            if case .text(_, let text, _, _, _, _, _, _, _) = prim { return text }
            return nil
        }
        XCTAssertTrue(
            texts.contains(where: { $0.contains("SHALL BE ASTM 3034 SDR 35.") }),
            "note 1 must extract on one line, got \(texts.count) runs")
        XCTAssertTrue(
            texts.contains(where: { $0.contains("LOCATED IN CENTER OF CUL-DE-SAC WHEN APPROPRIATE.") }),
            "note 2 must extract on one line, got \(texts.count) runs")
        for whole in ["DWG. BY", "CK'D BY", "NOT TO", "SCALE"] {
            XCTAssertTrue(
                texts.contains(where: { $0.contains(whole) }),
                "\(whole) must extract, got \(texts)")
        }
        for fragment in ["35.", "BY", "TO", "APPROPRIATE."] {
            XCTAssertFalse(
                texts.contains(where: { $0 == fragment }),
                "no wrapped fragment \(fragment) may extract on its own: \(texts)")
        }
    }

    private func addMText(
        to doc: CADDocument, layerID: UUID,
        raw: String, style: String, height: Double, width: Double
    ) {
        let formatted = MTEXTFormatter.parse(
            raw, defaultFont: style, defaultHeight: height)
        var xdata: [String: XDataValue] = [:]
        xdata["dxf.text"] = .string(raw)
        xdata["dxf.textEntityType"] = .string("MTEXT")
        xdata["dxf.textHeight"] = .double(height)
        xdata["dxf.textStyle"] = .string(style)
        xdata["dxf.alignH"] = .int(0)
        xdata["dxf.alignV"] = .int(3)
        xdata["dxf.mtextWidth"] = .double(width)
        if let data = try? JSONEncoder().encode(formatted),
           let json = String(data: data, encoding: .utf8) {
            xdata["dxf.formattedText"] = .string(json)
        }
        doc.addEntity(CADEntity(
            layerID: layerID, localGeometry: [],
            transform: .identity, xdata: xdata))
    }

    /// Mixed `\H` runs on the TTF path must emit one segment per scale with
    /// proportional font sizes, matching the scale-aware wrap width.
    func testMixedHeightRunsEmitScaledSizes() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["JAYTEXT"] = CADTextStyle(name: "JAYTEXT", fontFile: "arial.ttf")
        addMText(
            to: doc, layerID: layerID,
            raw: "A{\\H0.5x;B}", style: "JAYTEXT", height: 1.0,
            width: 100.0)

        let output = emittedContent(for: doc)
        let regex = try NSRegularExpression(pattern: #"BT /F\d+ ([\d.]+) Tf"#)
        let range = NSRange(output.startIndex..., in: output)
        let sizes: [Double] = regex.matches(in: output, range: range).compactMap {
            guard let r = Range($0.range(at: 1), in: output) else { return nil }
            return Double(output[r])
        }
        XCTAssertEqual(sizes.count, 2, "one Tj per scale group; got: \(output)")
        XCTAssertEqual(sizes[1] / sizes[0], 0.5, accuracy: 0.01)
    }

    /// Apostrophe round-trip: `CK'D BY` must emit its `'` CID and map it
    /// back to U+0027 — never to a control character.
    func testApostropheRoundTripsThroughLiveText() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["JAYTEXT"] = CADTextStyle(name: "JAYTEXT", fontFile: "arial.ttf")
        addMText(
            to: doc, layerID: layerID,
            raw: "CK'D BY", style: "JAYTEXT", height: 0.08,
            width: 0.43736207366985)

        let output = emittedContent(for: doc)
        let tjCount = output.components(separatedBy: "Tj").count - 1
        XCTAssertEqual(tjCount, 1, "CK'D BY must stay on one line; got: \(output)")

        // The apostrophe CID must map back to U+0027 in ToUnicode (SS-11
        // extracted it as a newline when aliased catalog entries diverged).
        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ckd_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try pdfData.write(to: tmpURL)
        guard let page = PDFiumBridge.extractVectorPage(path: tmpURL.path, pageIndex: 0) else {
            throw XCTSkip("pdfium unavailable in this environment")
        }
        let texts = page.textEntities.flatMap { $0 }.compactMap { prim -> String? in
            if case .text(_, let text, _, _, _, _, _, _, _) = prim { return text }
            return nil
        }
        XCTAssertTrue(
            texts.contains(where: { $0.contains("CK'D BY") }),
            "apostrophe must extract intact, got \(texts)")
    }

    /// Full-sheet font-registration check: exports the SS-11 sheet exactly
    /// like the E2E test and asserts on the raw PDF (runs even where pdfium
    /// is unavailable and the E2E skips). Keeps the PDF at a deterministic
    /// path for manual inspection.
    func testSS11ExportRegistersNoSubstituteFonts() throws {
        let dwg = "C:/Users/xingo/Downloads/SS-11 6 Inch Lateral Cleanout.dwg"
        guard FileManager.default.fileExists(atPath: dwg) else {
            throw XCTSkip("SS-11 fixture \(dwg) not present")
        }
        guard ODADWGConverter.locateConverter() != nil else {
            throw XCTSkip("ODA FileConverter not installed")
        }
        let tmpDXF = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss11_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmpDXF) }
        try ODADWGConverter.convertSync(
            input: URL(fileURLWithPath: dwg), output: tmpDXF, toFormat: "DXF")
        let imported = try DXFImporter.importDXFViews(filePath: tmpDXF.path)
        let sheet = try XCTUnwrap(
            imported.views.first(where: { view in
                view.entities.contains { entity in
                    guard case .string(let text) = entity.xdata["dxf.text"] else { return false }
                    return text.contains("SS-11")
                }
            }))
        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers, blocks: imported.blocks, entities: sheet.entities)
        for (name, style) in imported.textStyles {
            doc.textStyles[name] = style
        }
        doc.plotSettings = sheet.plotSettings
        doc.layoutSettings = sheet.layoutSettings
        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent("ss11dbg.pdf")
        try pdfData.write(to: probeURL)
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(
            pdfString.contains("/BaseFont /TEXT"),
            "no style-named substitute font may be registered")
        XCTAssertTrue(pdfString.contains("FontFile2"), "TTF faces must embed")
        XCTAssertTrue(pdfString.contains("ToUnicode"), "embedded text needs a ToUnicode map")
        print("SS11-PROBE-PDF: \(probeURL.path)")
    }

    func testTTFMultilineMTextEmitsOneOperationPerLine() throws {
        let (doc, layerID) = makeDoc()
        doc.textStyles["NOTES"] = CADTextStyle(name: "NOTES", fontFile: "ARIALN.TTF")
        let plain = "SPECIFICATIONS\nPRODUCT #: PCM103231\nPLAY CAPACITY: 24 USERS"
        let formatted = FormattedText.plain(
            plain, styleName: "NOTES", font: "ARIALN.TTF", height: 2.5)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(formatted), encoding: .utf8))
        var xdata: [String: XDataValue] = [:]
        xdata["dxf.text"] = .string(plain)
        xdata["dxf.textEntityType"] = .string("MTEXT")
        xdata["dxf.textHeight"] = .double(2.5)
        xdata["dxf.textStyle"] = .string("NOTES")
        xdata["dxf.alignH"] = .int(0)
        xdata["dxf.alignV"] = .int(0)
        xdata["dxf.mtextWidth"] = .double(87.7)
        xdata["dxf.formattedText"] = .string(json)
        doc.addEntity(CADEntity(
            layerID: layerID, localGeometry: [],
            transform: .identity, xdata: xdata))

        let output = emittedContent(for: doc)
        let tjCount = output.components(separatedBy: "Tj").count - 1
        XCTAssertEqual(
            tjCount, 3,
            "each MTEXT paragraph must be emitted separately, not collapsed into one Tj; got: \(output)")
    }
}
