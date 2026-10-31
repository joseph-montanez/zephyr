import XCTest
@testable import ZephyrCore

/// Page Setup Phase 0: full-fidelity `CADPlotSettings` model and its
/// lossless DXF/EAB round-trip (the strict `AcDbPlotSettings` vs.
/// `AcDbLayout` two-state split for group codes 1/70/76).
final class PlotSettingsTests: XCTestCase {

    private func makeLayeredDoc(layerName: String) -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layerID = UUID()
        let layer = Layer(
            handle: layerID, name: layerName, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layerID)
    }

    private func makePlotSettings() -> CADPlotSettings {
        CADPlotSettings(
            // DXF carries one media field (code 4): the display name
            // round-trips as the canonical media name.
            paperName: "ISO_A3_(420.00_x_297.00_MM)",
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1,
            plotRotation: 1,
            pageSetupName: "A3 PDF",
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A3_(420.00_x_297.00_MM)",
            plotViewName: "",
            styleSheet: "Coplestone.ctb",
            plotOriginXMM: 5, plotOriginYMM: 5,
            plotWindowMinX: 0, plotWindowMinY: 0,
            plotWindowMaxX: 400, plotWindowMaxY: 277,
            customScaleNumerator: 1, customScaleDenominator: 2,
            standardScaleFactor: 0.5,
            paperImageOriginX: 0, paperImageOriginY: 0,
            plotFlags: 36,
            plotType: 4,
            standardScaleType: 0,
            shadePlotMode: 0,
            shadePlotResolution: 2,
            shadePlotCustomDPI: 300,
            layoutFlags: 3)
    }

    @MainActor
    func testDXFRoundTripPreservesPlotSettings() throws {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, sheetLayerID) = makeLayeredDoc(layerName: "SheetLayer")
        let line = CADEntity(
            layerID: sheetLayerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 1, z: 0), color: .white)],
            transform: .identity)
        sheetDoc.addEntity(line)
        sheetDoc.plotSettings = makePlotSettings()
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings

        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotsettings-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0)

        // Raw text pins real values (not the legacy all-zero synthetic block).
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("DWG To PDF.pc3"))
        XCTAssertTrue(text.contains("Coplestone.ctb"))
        XCTAssertTrue(text.contains("A3 PDF"))

        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let sheet = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        let back = try XCTUnwrap(sheet.plotSettings)
        XCTAssertEqual(back, makePlotSettings())
        // Paper size flows through to the lightweight view too.
        XCTAssertEqual(sheet.layoutSettings?.paperWidthMM, 420)
        XCTAssertEqual(sheet.layoutSettings?.plotRotation, 1)
        // The two code-70s stay on their own side of the split.
        XCTAssertEqual(back.plotFlags, 36)
        XCTAssertEqual(back.layoutFlags, 3)
    }

    @MainActor
    func testDXFRoundTripDefaultsStaySynthetic() throws {
        // No plot settings anywhere: output must match the legacy writer
        // (zeros/defaults), so old diffs stay byte-identical.
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(CADEntity(
            layerID: modelLayerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: .white)],
            transform: .identity))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotsettings-def-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let sheet = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.plotSettings, CADPlotSettings())
    }

    @MainActor
    func testEABRoundTripPreservesPlotSettings() throws {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        sheetDoc.plotSettings = makePlotSettings()
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotsettings-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: views, to: url)
        let data = try Data(contentsOf: url)
        let reloaded = try EABReader.readViews(from: data)
        let sheet = try XCTUnwrap(reloaded.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.document.plotSettings, makePlotSettings())
        XCTAssertEqual(sheet.document.layoutSettings?.paperHeightMM, 297)
    }
}
