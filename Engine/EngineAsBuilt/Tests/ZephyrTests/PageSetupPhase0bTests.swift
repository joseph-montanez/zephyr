import XCTest
@testable import ZephyrCore

/// Page Setup Phase 0b: standard-scale table + Custom state, named page
/// setup DXF/EAB round-trip, XDATA transparency/PDFOptions, LIMMIN/LIMMAX
/// sync, and pre-0b EAB back-compat.
final class PageSetupPhase0bTests: XCTestCase {

    private func makeLayeredDoc(layerName: String) -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layerID = UUID()
        let layer = Layer(
            handle: layerID, name: layerName, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layerID)
    }

    // MARK: - Standard scale table (Code 75, 0–32)

    func testStandardScaleTableBothDirections() throws {
        // Spot-check canonical factors each way.
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 0), nil) // Fit
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 16), 1.0)
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 25), 0.02) // 1:50
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 12) ?? 0,
                       1.0 / 12.0, accuracy: 1e-12) // 1"=1'
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 27), 2.0)
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 32), 1000.0)
        XCTAssertEqual(CADPlotSettings.standardScaleFactor(for: 99), nil)
        // Reverse lookup (duplicates resolve to lowest type number).
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 1.0), 15)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 0.02), 25)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 2.0), 27)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 0.5), 14)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 0.25), 13)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 0.0625), 11)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: 0.12345), nil)
        XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: .nan), nil)
        // Unambiguous entries resolve both ways exactly.
        let ambiguous: Set<Int> = [11, 13, 14, 15, 16, 17, 18, 21]
        for t in 1...32 where !ambiguous.contains(t) {
            let f = try XCTUnwrap(CADPlotSettings.standardScaleFactor(for: t))
            XCTAssertEqual(CADPlotSettings.standardScaleType(forFactor: f), t)
        }
    }

    func testCustomScaleStateUsesBit16And142_143() throws {
        // Custom dialog state: bit 16 cleared, Code 75 stays 16, ratio in 142/143.
        // Default plotFlags is 0 so bit 16 starts cleared (Custom); a standard
        // scale selection sets it.
        var ps = CADPlotSettings(standardScaleType: 16)
        XCTAssertFalse(ps.useStandardScale)
        XCTAssertTrue(ps.isCustomScale)
        ps.useStandardScale = true
        XCTAssertTrue(ps.useStandardScale)
        XCTAssertFalse(ps.isCustomScale)
        ps.useStandardScale = false
        XCTAssertTrue(ps.isCustomScale)
        XCTAssertEqual(ps.standardScaleType, 16)
        ps.customScaleNumerator = 1
        ps.customScaleDenominator = 50
        XCTAssertEqual(ps.effectiveScaleFactor, 0.02, accuracy: 1e-12)
        // Standard path uses the table, not 142/143.
        var std = CADPlotSettings(standardScaleType: 25)
        std.useStandardScale = true
        XCTAssertEqual(std.effectiveScaleFactor, 0.02, accuracy: 1e-12)
    }

    // MARK: - Named setups DXF round-trip

    private func makeNamedSetups() -> [CADNamedPageSetup] {
        let paper = CADPlotSettings(
            paperName: "ISO_A3_(420.00_x_297.00_MM)",
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 0,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A3_(420.00_x_297.00_MM)",
            styleSheet: "monochrome.ctb",
            customScaleNumerator: 1, customScaleDenominator: 2,
            plotFlags: 16 | 32 | 128,
            plotType: 5, standardScaleType: 25,
            plotTransparency: true,
            pdfOptions: PDFOptions(vectorDPI: 600, rasterDPI: 300,
                                   mergeControl: .mergeLines,
                                   includeLayerInfo: true, includeHyperlinks: true,
                                   captureFonts: true, convertTextToGeometry: false))
        let model = CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            plotPaperUnits: 1,
            plotConfigName: "DWG To PDF.pc3",
            plotFlags: 16,
            plotType: 1, standardScaleType: 0)
        return [
            CADNamedPageSetup(name: "A3 PDF", settings: paper, isModelType: false),
            CADNamedPageSetup(name: "Model Fit", settings: model, isModelType: true),
        ]
    }

    @MainActor
    func testNamedSetupsDXFRoundTrip() throws {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, sheetLayerID) = makeLayeredDoc(layerName: "SheetLayer")
        sheetDoc.addEntity(CADEntity(
            layerID: sheetLayerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 1, z: 0), color: .white)],
            transform: .identity))
        // Layout bound to the named setup via plot Code 1.
        var bound = makeNamedSetups()[0].settings
        bound.pageSetupName = "A3 PDF"
        sheetDoc.plotSettings = bound
        sheetDoc.layoutSettings = bound.layoutSettings

        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let setups = makeNamedSetups()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagesetup-0b-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0, namedSetups: setups)

        let text = try String(contentsOf: url, encoding: .utf8)
        // Named objects + dictionary emitted.
        XCTAssertTrue(text.contains("ACAD_PLOTSETTINGS"))
        XCTAssertTrue(text.contains("A3 PDF"))
        XCTAssertTrue(text.contains("Model Fit"))
        // XDATA transparency / PDF options ride the layout.
        XCTAssertTrue(text.contains("ZEPHYR_PLOT"))

        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.namedPageSetups.count, 2)
        let paper = try XCTUnwrap(reimported.namedPageSetups.first(where: { $0.name == "A3 PDF" }))
        XCTAssertFalse(paper.isModelType)
        XCTAssertEqual(paper.settings.styleSheet, "monochrome.ctb")
        XCTAssertTrue(paper.settings.plotTransparency)
        XCTAssertEqual(paper.settings.pdfOptions.vectorDPI, 600)
        XCTAssertEqual(paper.settings.pdfOptions.mergeControl, .mergeLines)
        let model = try XCTUnwrap(reimported.namedPageSetups.first(where: { $0.name == "Model Fit" }))
        XCTAssertTrue(model.isModelType)
        // Layout association survived via plot Code 1.
        let sheet = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.plotSettings?.pageSetupName, "A3 PDF")
        XCTAssertTrue(sheet.plotSettings?.plotTransparency ?? false)
    }

    // MARK: - LIMMIN/LIMMAX sync

    @MainActor
    func testLimMinMaxSyncInWriter() throws {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        // Paper 420x297mm, 1:1, origin (5,5)mm → limits (-5,-5)-(415,292).
        sheetDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            plotPaperUnits: 1,
            plotOriginXMM: 5, plotOriginYMM: 5)
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagesetup-lim-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Synced limits appear as exact code/value pairs in the LAYOUT block.
        XCTAssertTrue(text.contains(" 11\r\n415"))
        XCTAssertTrue(text.contains(" 21\r\n292"))
    }

    // MARK: - EAB: transparency/options + named setups + back-compat

    @MainActor
    func testEABRoundTripTransparencyOptionsAndNamedSetups() throws {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        var ps = makeNamedSetups()[0].settings
        ps.pageSetupName = "A3 PDF"
        sheetDoc.plotSettings = ps
        sheetDoc.layoutSettings = ps.layoutSettings
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let setups = makeNamedSetups()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagesetup-0b-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: views, to: url, namedSetups: setups)
        let data = try Data(contentsOf: url)
        let reloaded = try EABReader.readViews(from: data)
        let sheet = try XCTUnwrap(reloaded.first(where: { $0.kind == .sheet }))
        XCTAssertTrue(sheet.document.plotSettings?.plotTransparency ?? false)
        XCTAssertEqual(sheet.document.plotSettings?.pdfOptions.vectorDPI, 600)
        XCTAssertEqual(sheet.document.plotSettings?.pdfOptions.mergeControl, .mergeLines)
        let named = try EABReader.readNamedPageSetups(from: data)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named.first(where: { $0.name == "Model Fit" })?.isModelType, true)
    }

    @MainActor
    func testEABBackCompatPre0bPayload() throws {
        // A real pre-Phase-0b archive must still load; new fields default.
        let url = URL(fileURLWithPath: "floorplan.eab")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("floorplan.eab fixture not present")
        }
        let views = try EABReader.readViews(from: url)
        XCTAssertFalse(views.isEmpty)
        for view in views {
            let ps = view.document.plotSettings
            // Nil (no settings) or defaults for the 0b extras.
            XCTAssertEqual(ps?.plotTransparency ?? false, false)
            XCTAssertEqual(ps?.pdfOptions ?? PDFOptions(), PDFOptions())
        }
    }
}
