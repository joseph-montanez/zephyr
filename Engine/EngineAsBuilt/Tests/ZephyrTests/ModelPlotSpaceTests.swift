import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 1 Model-space completion: named-setup space scoping, Model
/// rename/delete binding, paper-unit sync rules, Model plot framing,
/// `-PAGESETUP`/`-PLOT` acceptance, the High Quality Print device, and
/// DXF/EAB round-trip.
final class ModelPlotSpaceTests: XCTestCase {

    @MainActor
    private func makeManager() -> TabManager {
        let manager = TabManager()
        let modelDoc = CADDocument()
        modelDoc.importLayersBlocksEntities(layers: [Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")], blocks: [], entities: [])
        modelDoc.unit = .millimeter
        modelDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1,
            plotType: 1, standardScaleType: 0)
        modelDoc.layoutSettings = modelDoc.plotSettings?.layoutSettings
        let sheetDoc = CADDocument()
        sheetDoc.importLayersBlocksEntities(layers: [Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")], blocks: [], entities: [])
        sheetDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Model",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        return manager
    }

    private func modelSettings() -> CADPlotSettings {
        CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)",
            plotType: 1, standardScaleType: 0)
    }

    private func layoutSettings() -> CADPlotSettings {
        CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1,
            plotConfigName: "AutoCAD PDF (High Quality Print).pc3",
            canonicalMediaName: "ISO_full_bleed_A3_(420.00_x_297.00_MM)",
            plotType: 5, standardScaleType: 16)
    }

    private func twoSetups() -> [CADNamedPageSetup] {
        [CADNamedPageSetup(name: "Model Plan", settings: modelSettings(), isModelType: true),
         CADNamedPageSetup(name: "Layout PDF", settings: layoutSettings(), isModelType: false)]
    }

    private final class Harness: @unchecked Sendable {
        var lines: [String] = []
        var finished = false
        var saveRequests: [String] = []
        var saveURL: URL? = nil
    }

    @MainActor
    private func context(manager: TabManager, harness: Harness) -> PlotCliContext {
        PlotCliContext(
            tabManager: manager,
            printLine: { [weak harness] in harness?.lines.append($0) },
            requestSavePDF: { [weak harness] suggested, completion in
                harness?.saveRequests.append(suggested)
                completion(harness?.saveURL)
            },
            paperUpdate: 0, plotOffset: 0, transparencyOverride: 1,
            onFinish: { [weak harness] in harness?.finished = true })
    }

    // MARK: - Setup scoping

    @MainActor
    func testModelSetupScoping() {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "Model Plan", from: modelSettings(), isModelType: true))
        XCTAssertTrue(manager.createNamedSetup(name: "Layout PDF", from: layoutSettings(), isModelType: false))
        // Strict matching: each setup applies only to its own space.
        XCTAssertTrue(manager.applyNamedSetupToLayout("Model Plan", layoutName: "Model"))
        XCTAssertFalse(manager.applyNamedSetupToLayout("Model Plan", layoutName: "Layout1"))
        XCTAssertFalse(manager.applyNamedSetupToLayout("Layout PDF", layoutName: "Model"))
        XCTAssertTrue(manager.applyNamedSetupToLayout("Layout PDF", layoutName: "Layout1"))
        XCTAssertEqual(
            manager.activeTab?.drawingViews[0].document.plotSettings?.pageSetupName, "Model Plan")
    }

    @MainActor
    func testModelRenameDeleteBinding() throws {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "Model Plan", from: modelSettings(), isModelType: true))
        XCTAssertTrue(manager.applyNamedSetupToLayout("Model Plan", layoutName: "Model"))
        // The Model view counts as bound (rename re-points it, delete refuses).
        XCTAssertEqual(manager.layoutsBound(to: "Model Plan"), ["Model"])
        XCTAssertTrue(manager.renameNamedSetup(from: "Model Plan", to: "Model Final"))
        XCTAssertEqual(
            manager.activeTab?.drawingViews[0].document.plotSettings?.pageSetupName, "Model Final")
        XCTAssertFalse(manager.deleteNamedSetup(named: "Model Final"))
        // Unbind the Model view, then deletion succeeds.
        let doc = try XCTUnwrap(manager.activeTab?.drawingViews[0].document)
        doc.plotSettings?.pageSetupName = ""
        XCTAssertTrue(manager.deleteNamedSetup(named: "Model Final"))
        XCTAssertFalse(manager.deleteNamedSetup(named: "Model Final"))
    }

    @MainActor
    func testModelApplySkipsDocumentUnitSync() {
        let manager = makeManager()
        // Inch paper on a Model target must not leak into the drawing unit.
        var inchModel = modelSettings()
        inchModel.plotPaperUnits = 0
        XCTAssertTrue(manager.createNamedSetup(name: "Model Inch", from: inchModel, isModelType: true))
        XCTAssertTrue(manager.applyNamedSetupToLayout("Model Inch", layoutName: "Model"))
        XCTAssertEqual(manager.activeTab?.drawingViews[0].document.unit, .millimeter)
        // Sheet targets still follow paper units.
        var inchLayout = layoutSettings()
        inchLayout.plotPaperUnits = 0
        XCTAssertTrue(manager.createNamedSetup(name: "Layout Inch", from: inchLayout, isModelType: false))
        XCTAssertTrue(manager.applyNamedSetupToLayout("Layout Inch", layoutName: "Layout1"))
        XCTAssertEqual(manager.activeTab?.drawingViews[1].document.unit, .inch)
    }

    // MARK: - Model plot framing

    func testModelPlotFraming() throws {
        var ps = modelSettings()
        ps.plotType = 1 // Extents
        ps.standardScaleType = 0 // Fit
        ps.useStandardScale = false
        let frame = try XCTUnwrap(PDFExporter.plotFrame(
            settings: ps, worldBounds: (minX: 0, minY: 0, maxX: 100, maxY: 50)))
        // 297 x 210 sheet in points (settings carry landscape A4 dims).
        XCTAssertEqual(frame.pageW, 297 * 72.0 / 25.4, accuracy: 0.5)
        XCTAssertEqual(frame.pageH, 210 * 72.0 / 25.4, accuracy: 0.5)
        XCTAssertGreaterThan(frame.scale, 0)
        XCTAssertGreaterThan(frame.clipPageW ?? 0, 0)
        XCTAssertGreaterThan(frame.clipPageH ?? 0, 0)
    }

    // MARK: - CLI acceptance

    @MainActor
    func testPagesetupCliAcceptsModel() {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "Model Plan", from: modelSettings(), isModelType: true))
        XCTAssertTrue(manager.createNamedSetup(name: "Layout PDF", from: layoutSettings(), isModelType: false))
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .pageSetup, ctx: ctx)
        session.handle("Model", ctx: ctx)
        session.handle("Model Plan", ctx: ctx)
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(
            manager.activeTab?.drawingViews[0].document.plotSettings?.pageSetupName, "Model Plan")

        // A layout-scoped setup cannot land on Model: the session retries.
        let harness2 = Harness()
        let ctx2 = context(manager: manager, harness: harness2)
        let session2 = PlotCliSession.start(flow: .pageSetup, ctx: ctx2)
        session2.handle("Model", ctx: ctx2)
        session2.handle("Layout PDF", ctx: ctx2)
        XCTAssertFalse(harness2.finished)
        XCTAssertTrue(harness2.lines.joined().contains("does not match"))
    }

    @MainActor
    func testPlotCliAcceptsModel() {
        let manager = makeManager()
        XCTAssertTrue(manager.switchToView(at: 0))
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .plot, ctx: ctx)
        session.handle("", ctx: ctx) // not detailed
        session.handle("N", ctx: ctx) // no file
        session.handle("N", ctx: ctx) // no save
        session.handle("Y", ctx: ctx) // proceed -> save dialog (cancelled)
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(harness.saveRequests, ["Model.pdf"])
    }

    // MARK: - Device

    func testHighQualityPrintDeviceExists() {
        guard let device = PlotDeviceCatalog.device(named: "AutoCAD PDF (High Quality Print).pc3") else {
            return XCTFail("missing AutoCAD PDF (High Quality Print).pc3 device")
        }
        XCTAssertTrue(device.isPDF)
        XCTAssertFalse(device.media.isEmpty)
        XCTAssertNotNil(device.medium(canonicalName: "ISO_full_bleed_A3_(420.00_x_297.00_MM)"))
    }

    // MARK: - Round-trips

    @MainActor
    func testModelDXFRoundTrip() throws {
        let manager = makeManager()
        let modelDoc = try XCTUnwrap(manager.activeTab?.drawingViews[0].document)
        var bound = modelSettings()
        bound.pageSetupName = "Model Plan"
        modelDoc.plotSettings = bound
        modelDoc.layoutSettings = bound.layoutSettings
        let views = try XCTUnwrap(manager.activeTab?.drawingViews)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelspace-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 1, namedSetups: twoSetups())

        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let model = try XCTUnwrap(reimported.views.first(where: { $0.kind == .model }))
        XCTAssertEqual(model.plotSettings?.paperWidthMM ?? 0, 297, accuracy: 1e-9)
        XCTAssertEqual(model.plotSettings?.plotType ?? -1, 1)
        XCTAssertEqual(model.plotSettings?.pageSetupName ?? "", "Model Plan")
        XCTAssertEqual(reimported.namedPageSetups.count, 2)
        XCTAssertEqual(
            reimported.namedPageSetups.first(where: { $0.name == "Model Plan" })?.isModelType, true)
        XCTAssertEqual(
            reimported.namedPageSetups.first(where: { $0.name == "Layout PDF" })?.isModelType, false)
    }

    @MainActor
    func testModelEABRoundTrip() throws {
        let manager = makeManager()
        let modelDoc = try XCTUnwrap(manager.activeTab?.drawingViews[0].document)
        modelDoc.plotSettings = modelSettings()
        modelDoc.layoutSettings = modelDoc.plotSettings?.layoutSettings
        let views = try XCTUnwrap(manager.activeTab?.drawingViews)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelspace-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: views, to: url, namedSetups: twoSetups())

        let data = try Data(contentsOf: url)
        let reloaded = try EABReader.readViews(from: data)
        let model = try XCTUnwrap(reloaded.first(where: { $0.kind == .model }))
        XCTAssertEqual(model.document.plotSettings?.paperWidthMM ?? 0, 297, accuracy: 1e-9)
        XCTAssertEqual(model.document.plotSettings?.plotType ?? -1, 1)
        let named = try EABReader.readNamedPageSetups(from: data)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(
            named.first(where: { $0.name == "Model Plan" })?.isModelType, true)
        XCTAssertEqual(
            named.first(where: { $0.name == "Layout PDF" })?.isModelType, false)
    }
}
