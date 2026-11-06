import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2 multi-page PDF engine: per-page renderer + document assembler with
/// an object-number allocator. Covers two-page output, mixed page sizes with
/// per-page MediaBox/Measure entries, monochrome/pen behavior through the
/// shared plot-style path, and unchanged single-page behavior.
final class PDFMultiPageTests: XCTestCase {

    private func makeDoc(color: ColorRGBA = .black) -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(handle: UUID(), name: "0", isVisible: true,
                          lineWeight: 0.25, color: color, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return doc
    }

    private func addLine(to doc: CADDocument) {
        // No per-primitive color: the entity resolves to the layer color, so
        // plot-style pen mapping is what decides the emitted ink.
        let layerID = doc.allLayers.first!.handle
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                  end: Vector3(x: 100, y: 50, z: 0))],
            transform: .identity))
    }

    private func a3Settings() -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperName: "ISO_A3_(420.00_x_297.00_MM)",
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 0,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A3_(420.00_x_297.00_MM)",
            plotType: 5, standardScaleType: 16)
        ps.useStandardScale = true
        return ps
    }

    private func a4Settings() -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperName: "ISO_A4_(297.00_x_210.00_MM)",
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1, plotRotation: 0,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)",
            plotType: 5, standardScaleType: 16)
        ps.useStandardScale = true
        return ps
    }

    private func pdfText(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Two pages, mixed sizes

    func testTwoPagesMixedSizes() throws {
        let doc1 = makeDoc()
        addLine(to: doc1)
        let doc2 = makeDoc()
        addLine(to: doc2)
        let sources = [
            PDFExporter.PDFMultiPageSource(snapshot: doc1.snapshot(), plotSettings: a3Settings(),
                               backgroundColor: .white),
            PDFExporter.PDFMultiPageSource(snapshot: doc2.snapshot(), plotSettings: a4Settings(),
                               backgroundColor: .white),
        ]
        let data = try PDFExporter.generateMultiPagePDF(sources: sources)
        XCTAssertGreaterThan(data.count, 1000)
        let text = pdfText(data)
        XCTAssertTrue(text.hasPrefix("%PDF-1.7"), "must keep the PDF header")
        XCTAssertTrue(text.contains("/Count 2"), "pages tree must count both pages")
        XCTAssertTrue(text.contains("/MediaBox [0 0 1191 842]"), "A3 page keeps exact points")
        XCTAssertTrue(text.contains("/MediaBox [0 0 842 595]"), "A4 page keeps exact points")
        XCTAssertEqual(text.components(separatedBy: "/MediaBox").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "/Type /Measure").count - 1, 2,
                       "each page keeps its own Measure dictionary")
        // The public file API writes the same document through atomicWrite.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipage-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFExporter.exportMultiPage(sources: sources, to: url)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, data)
    }

    // MARK: - Monochrome / pen behavior

    func testMonochromePlotStyleMapsToBlack() throws {
        let doc = makeDoc(color: .red)
        addLine(to: doc)
        var settings = a3Settings()
        settings.plotFlags |= 32 // PlotPlotStyles
        settings.styleSheet = "monochrome.ctb"
        let loader: ((String) -> PlotStyleTable?) = { name in
            guard name == "monochrome.ctb" else { return nil }
            return try? PlotStyleTable.parse(
                url: URL(fileURLWithPath: "Plot Styles/monochrome.ctb"))
        }
        let table = try XCTUnwrap(loader("monochrome.ctb"))
        // Unit level: the exporter's style pass resolves red through the table.
        let items = PDFExporter.collectItems(document: doc, isLightBackground: true)
        XCTAssertFalse(items.isEmpty)
        let styled = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: settings, plotTable: table)
        for item in styled {
            if case .geometry(_, let color, _) = item {
                XCTAssertEqual(color, .black, "monochrome pen must map red to black")
            }
        }
        // Page level: the baked multi-page content paints black strokes.
        let context = PDFExporter.PlotContext(plotTableLoader: loader)
        let catalog = PDFTextEmitter.PDFFontCatalog()
        let tempDoc = CADDocument()
        tempDoc.restore(from: doc.snapshot())
        tempDoc.plotSettings = settings
        tempDoc.layoutSettings = settings.layoutSettings
        let page = try PDFExporter.renderPage(document: tempDoc, backgroundColor: .white,
                                              plotContext: context, catalog: catalog)
        let content = String(decoding: page.contentData, as: UTF8.self)
        XCTAssertTrue(content.contains("0 0 0 RG"), "monochrome pen must emit black strokes")
        // Document level: the assembled multi-page file exports cleanly.
        let sources = [PDFExporter.PDFMultiPageSource(snapshot: doc.snapshot(), plotSettings: settings,
                                          backgroundColor: .white)]
        let data = try PDFExporter.generateMultiPagePDF(sources: sources, plotContext: context)
        XCTAssertTrue(pdfText(data).contains("/Count 1"))
    }

    func testMonochromePlotStyleMapsTextToBlack() throws {
        let doc = makeDoc(color: .red)
        let layerID = doc.allLayers.first!.handle
        var xdata: [String: XDataValue] = [:]
        xdata["dxf.text"] = .string("KOMPAN")
        xdata["dxf.textHeight"] = .double(10.0)
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [],
            transform: .identity,
            xdata: xdata))
        var settings = a3Settings()
        settings.plotFlags |= 32 // PlotPlotStyles
        settings.styleSheet = "monochrome.ctb"
        let loader: ((String) -> PlotStyleTable?) = { name in
            guard name == "monochrome.ctb" else { return nil }
            return try? PlotStyleTable.parse(
                url: URL(fileURLWithPath: "Plot Styles/monochrome.ctb"))
        }
        let table = try XCTUnwrap(loader("monochrome.ctb"))
        let items = PDFExporter.collectItems(document: doc, isLightBackground: true)
        XCTAssertFalse(items.isEmpty)
        let styled = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: settings, plotTable: table)
        var sawText = false
        for item in styled {
            switch item {
            case .textStrokes(_, let color, _):
                sawText = true
                XCTAssertEqual(color, .black, "monochrome pen must map red text strokes to black")
            case .embeddedText(let embedded, _):
                sawText = true
                XCTAssertEqual(embedded.color, .black, "monochrome pen must map red live text to black")
            case .textFallback(_, _, _, _, let color, _):
                sawText = true
                XCTAssertEqual(color, .black, "monochrome pen must map red fallback text to black")
            default:
                break
            }
        }
        XCTAssertTrue(sawText, "expected at least one text item")
    }

    func testMonochromePlotStyleMapsTableTextToBlack() throws {
        let doc = makeDoc(color: .black)
        let layerID = doc.allLayers.first!.handle
        let column = DataTableColumn(name: "Note")
        let data = DataTableData(
            columns: [column],
            rows: [DataTableRow(cells: [DataTableCell(columnID: column.id, value: .string("PIRATE"))])],
            title: "TITLE",
            textColor: .red,
            gridColor: .red)
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.table(data: data, origin: .zero, color: nil)],
            transform: .identity))
        var settings = a3Settings()
        settings.plotFlags |= 32 // PlotPlotStyles
        settings.styleSheet = "monochrome.ctb"
        let loader: ((String) -> PlotStyleTable?) = { name in
            guard name == "monochrome.ctb" else { return nil }
            return try? PlotStyleTable.parse(
                url: URL(fileURLWithPath: "Plot Styles/monochrome.ctb"))
        }
        let context = PDFExporter.PlotContext(plotTableLoader: loader)
        let catalog = PDFTextEmitter.PDFFontCatalog()
        let tempDoc = CADDocument()
        tempDoc.restore(from: doc.snapshot())
        tempDoc.plotSettings = settings
        tempDoc.layoutSettings = settings.layoutSettings
        let page = try PDFExporter.renderPage(document: tempDoc, backgroundColor: .white,
                                              plotContext: context, catalog: catalog)
        let content = String(decoding: page.contentData, as: UTF8.self)
        XCTAssertTrue(content.contains("0 0 0 RG") || content.contains("0 0 0 rg"),
                      "monochrome pen must emit black table ink, got: \(content.prefix(500))")
        XCTAssertFalse(content.contains("1 0 0 RG") || content.contains("1 0 0 rg"),
                       "monochrome pen must not emit red table ink")
    }

    func testMonochromePlotStyleMapsDimensionTextToBlack() throws {
        let doc = makeDoc(color: .black)
        let layerID = doc.allLayers.first!.handle
        let block = CADBlock(
            name: "DIMTEXT\(UUID().uuidString.prefix(6))",
            geometry: [
                .line(start: .zero, end: Vector3(x: 100, y: 0, z: 0), color: .red),
                .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 0, y: 10, z: 0), color: .red),
                .text(
                    position: .zero, text: "33'-2\"",
                    height: 2.5, rotation: 0, style: nil,
                    alignH: 1, alignV: 2, mtextWidth: nil,
                    color: .red),
            ])
        doc.addBlock(block)
        var entity = CADEntity(layerID: layerID)
        entity.blockID = block.handle
        doc.addEntity(entity)
        var settings = a3Settings()
        settings.plotFlags |= 32 // PlotPlotStyles
        settings.styleSheet = "monochrome.ctb"
        let loader: ((String) -> PlotStyleTable?) = { name in
            guard name == "monochrome.ctb" else { return nil }
            return try? PlotStyleTable.parse(
                url: URL(fileURLWithPath: "Plot Styles/monochrome.ctb"))
        }
        let context = PDFExporter.PlotContext(plotTableLoader: loader)
        let catalog = PDFTextEmitter.PDFFontCatalog()
        let tempDoc = CADDocument()
        tempDoc.restore(from: doc.snapshot())
        tempDoc.plotSettings = settings
        tempDoc.layoutSettings = settings.layoutSettings
        let page = try PDFExporter.renderPage(document: tempDoc, backgroundColor: .white,
                                              plotContext: context, catalog: catalog)
        let content = String(decoding: page.contentData, as: UTF8.self)
        XCTAssertTrue(content.contains("0 0 0 RG") || content.contains("0 0 0 rg"),
                      "monochrome pen must emit black dimension ink, got: \(content.prefix(500))")
        XCTAssertFalse(content.contains("1 0 0 RG") || content.contains("1 0 0 rg"),
                       "monochrome pen must not emit red dimension vectors or text")
    }

    /// Drive Roller sheet regression: the paper-space border polyline is
    /// ByLayer ACI 7 (white) with no per-primitive color. collectItems
    /// inverts it to charcoal for a light page, but applyPlotStyles used
    /// to recompute the raw layer color and plot it white-on-white —
    /// invisibly erasing every table edge that coincides with the sheet
    /// border (Parts List top/right, title-block bottom/right).
    func testPlotStylePassKeepsACIWhiteInvertedWhenNoPenRecolors() throws {
        let doc = makeDoc(color: .white)
        addLine(to: doc)

        let items = PDFExporter.collectItems(document: doc, isLightBackground: true)
        for item in items {
            if case .geometry(_, let color, _) = item {
                XCTAssertEqual(
                    color, ColorRGBA(r: 24, g: 24, b: 24),
                    "collectItems must invert ACI white for a light page")
            }
        }

        // Plot styles requested but no style sheet resolves (pen == nil):
        // the pass may still run for lineweight/screening policy, but it
        // must not restore the unadjusted white.
        var settings = a3Settings()
        settings.plotFlags |= 32 // PlotPlotStyles
        settings.styleSheet = ""
        let styled = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: settings, plotTable: nil)
        var sawGeometry = false
        for item in styled {
            if case .geometry(_, let color, _) = item {
                sawGeometry = true
                XCTAssertEqual(
                    color, ColorRGBA(r: 24, g: 24, b: 24),
                    "object-color plotting must keep ACI white as charcoal, not raw white")
            }
        }
        XCTAssertTrue(sawGeometry)

        // Page level: the rendered sheet must stroke charcoal, never white.
        let catalog = PDFTextEmitter.PDFFontCatalog()
        let tempDoc = CADDocument()
        tempDoc.restore(from: doc.snapshot())
        tempDoc.plotSettings = settings
        tempDoc.layoutSettings = settings.layoutSettings
        let page = try PDFExporter.renderPage(
            document: tempDoc, backgroundColor: .white, catalog: catalog)
        let content = String(decoding: page.contentData, as: UTF8.self)
        XCTAssertFalse(
            content.contains("1 1 1 RG"),
            "no white strokes may reach a white page; got: \(content.prefix(800))")
        XCTAssertTrue(
            content.contains("0.0941 0.0941 0.0941 RG"),
            "ACI white must stroke as charcoal; got: \(content.prefix(800))")
    }

    /// The catalog must be syntactically valid: /UseOutlines is a
    /// /PageMode value, not a value-less ViewerPreferences key (strict
    /// parsers such as MuPDF reject the whole catalog and see 0 pages).
    func testCatalogUsesValidPageModeEntry() throws {
        let doc = makeDoc()
        addLine(to: doc)
        let data = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let text = pdfText(data)
        XCTAssertTrue(text.contains("/PageMode /UseOutlines"))
        XCTAssertFalse(text.contains("/None /UseOutlines"))
    }

    // MARK: - Unchanged single-page behavior

    func testSinglePageWrapperMatchesMultiPage() throws {
        let doc = makeDoc()
        addLine(to: doc)
        let settings = a3Settings()
        doc.plotSettings = settings
        doc.layoutSettings = settings.layoutSettings
        let before = doc.plotSettings
        let single = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let singleText = pdfText(single)
        XCTAssertTrue(singleText.contains("/MediaBox [0 0 1191 842]"),
                      "single-page wrapper keeps the exact A3 paper size")
        XCTAssertTrue(singleText.contains("/Count 1"))
        // The same page through the multi-page API carries the same boxes.
        let sources = [PDFExporter.PDFMultiPageSource(snapshot: doc.snapshot(), plotSettings: settings,
                                          backgroundColor: .white)]
        let multi = try PDFExporter.generateMultiPagePDF(sources: sources)
        let multiText = pdfText(multi)
        XCTAssertTrue(multiText.contains("/MediaBox [0 0 1191 842]"))
        XCTAssertTrue(multiText.contains("/Count 1"))
        XCTAssertEqual(doc.plotSettings, before, "export must not mutate the source drawing")
    }

    func testMultiPageDoesNotMutateSourceDrawings() throws {
        let doc = makeDoc()
        addLine(to: doc)
        XCTAssertNil(doc.plotSettings)
        let sources = [PDFExporter.PDFMultiPageSource(snapshot: doc.snapshot(), plotSettings: a3Settings(),
                                          backgroundColor: .white)]
        _ = try PDFExporter.generateMultiPagePDF(sources: sources)
        XCTAssertNil(doc.plotSettings, "resolved settings apply to throwaway docs only")
    }

    func testEmptySourcesThrows() {
        XCTAssertThrowsError(try PDFExporter.generateMultiPagePDF(sources: []))
    }
}
