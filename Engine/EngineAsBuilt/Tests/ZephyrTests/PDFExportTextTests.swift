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
