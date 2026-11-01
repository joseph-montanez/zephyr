import XCTest
@testable import ZephyrCore

/// Phase 4 steps 25 + 30: `-PAGESETUP` / `-PLOT` / `-PSETUPIN` prompt flows.
@MainActor
final class PlotCliTests: XCTestCase {

    private func makeManager() -> TabManager {
        let manager = TabManager()
        let modelDoc = CADDocument()
        modelDoc.importLayersBlocksEntities(layers: [Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")], blocks: [], entities: [])
        let sheetDoc = CADDocument()
        sheetDoc.importLayersBlocksEntities(layers: [Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")], blocks: [], entities: [])
        sheetDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Cli",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        return manager
    }

    private final class Harness: @unchecked Sendable {
        var lines: [String] = []
        var finished = false
        var saveRequests: [String] = []
        var saveURL: URL? = nil
    }

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

    // MARK: - Pure helpers

    func testParseScale() {
        XCTAssertEqual(PlotCliPrompts.parseScale("Fit"),
                       PlotCliPrompts.ParsedScale(type: 0, useStandard: false, num: 1, den: 1))
        XCTAssertEqual(PlotCliPrompts.parseScale("1=2"),
                       PlotCliPrompts.ParsedScale(type: 16, useStandard: false, num: 1, den: 2))
        XCTAssertEqual(PlotCliPrompts.parseScale("1:50"),
                       PlotCliPrompts.ParsedScale(type: 25, useStandard: true, num: 1, den: 1))
        XCTAssertNil(PlotCliPrompts.parseScale("bogus"))
        XCTAssertNil(PlotCliPrompts.parseScale("1="))
    }

    func testWildcardMatch() {
        XCTAssertTrue(PlotCliPrompts.wildcardMatch(pattern: "A1", name: "A1"))
        XCTAssertTrue(PlotCliPrompts.wildcardMatch(pattern: "a1", name: "A1"))
        XCTAssertFalse(PlotCliPrompts.wildcardMatch(pattern: "a1", name: "A1 PDF"))
        XCTAssertTrue(PlotCliPrompts.wildcardMatch(pattern: "A*", name: "A1 PDF"))
        XCTAssertTrue(PlotCliPrompts.wildcardMatch(pattern: "*", name: "Anything"))
        XCTAssertTrue(PlotCliPrompts.wildcardMatch(pattern: "A? PDF", name: "A1 PDF"))
        XCTAssertFalse(PlotCliPrompts.wildcardMatch(pattern: "B*", name: "A1 PDF"))
        XCTAssertFalse(PlotCliPrompts.wildcardMatch(pattern: "A1", name: "A2"))
    }

    // MARK: - -PAGESETUP

    func testPageSetupAssignAndClear() {
        let manager = makeManager()
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        XCTAssertTrue(manager.createNamedSetup(
            name: "A1 PDF",
            from: CADPlotSettings(paperWidthMM: 420, paperHeightMM: 297, plotPaperUnits: 1)))
        let session = PlotCliSession.start(flow: .pageSetup, ctx: ctx)
        session.handle("", ctx: ctx) // default layout
        session.handle("A1 PDF", ctx: ctx)
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(manager.activeTab?.drawingViews[1].document.plotSettings?.pageSetupName, "A1 PDF")

        // Clear back to <None>.
        let harness2 = Harness()
        let ctx2 = context(manager: manager, harness: harness2)
        let session2 = PlotCliSession.start(flow: .pageSetup, ctx: ctx2)
        session2.handle("Layout1", ctx: ctx2)
        session2.handle(".", ctx: ctx2)
        XCTAssertTrue(harness2.finished)
        XCTAssertEqual(manager.activeTab?.drawingViews[1].document.plotSettings?.pageSetupName, "")
    }

    func testPageSetupListsAndRetries() {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "A1 PDF", from: CADPlotSettings()))
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .pageSetup, ctx: ctx)
        session.handle("?", ctx: ctx)
        XCTAssertTrue(harness.lines.joined().contains("Layout1"))
        XCTAssertFalse(harness.finished)
        session.handle("Nope", ctx: ctx)
        XCTAssertFalse(harness.finished) // unknown layout retries
        session.handle("Layout1", ctx: ctx)
        session.handle("?", ctx: ctx)
        XCTAssertTrue(harness.lines.joined().contains("A1 PDF"))
        session.handle("A1 PDF", ctx: ctx)
        XCTAssertTrue(harness.finished)
    }

    // MARK: - -PLOT scripted run

    func testPlotQuickRunNoFile() {
        let manager = makeManager()
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .plot, ctx: ctx)
        // Not detailed → straight to write/save/proceed.
        session.handle("", ctx: ctx) // not detailed
        session.handle("N", ctx: ctx) // no file
        session.handle("N", ctx: ctx) // no save
        session.handle("Y", ctx: ctx) // proceed → save dialog (cancelled)
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(harness.saveRequests, ["Layout1.pdf"])
        XCTAssertTrue(harness.lines.joined().contains("Plot cancelled."))
    }

    func testPlotDetailedRunSavesSetup() {
        let manager = makeManager()
        let harness = Harness()
        harness.saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-plot-\(UUID().uuidString).pdf")
        defer { if let url = harness.saveURL { try? FileManager.default.removeItem(at: url) } }
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .plot, ctx: ctx)
        let answers = [
            "Y", // detailed
            "", // layout = current
            "DWG To PDF.pc3", // device
            "ISO A4 (297.00 x 210.00 MM)", // paper
            "", // units stay mm
            "Landscape", // orientation
            "N", // upside
            "Layout", // area
            "1:1", // scale
            "0,0", // offset
            "Y", // plot styles
            ".", // no style table
            "Y", // lineweights
            "N", // scale lineweights
            "N", // paperspace first → draw viewports first
            "N", // hide paperspace
            "N", // no file yet
            "Y", // save changes
            "Y", // proceed → plots via dialog
        ]
        for answer in answers { session.handle(answer, ctx: ctx) }
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(harness.saveRequests, ["Layout1.pdf"])
        XCTAssertTrue(harness.saveURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        let doc = manager.activeTab?.drawingViews[1].document
        XCTAssertEqual(doc?.plotSettings?.plotRotation, 1)
        XCTAssertEqual(doc?.plotSettings?.plotConfigName, "DWG To PDF.pc3")
        XCTAssertEqual(doc?.layoutSettings?.paperWidthMM ?? 0, 297, accuracy: 1e-9)
        XCTAssertNotNil(manager.activeTab?.lastPlotSettings)
    }

    // MARK: - -PSETUPIN with conflict

    private func fixtureWithTwoSetups() throws -> URL {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "A1 PDF", from: CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297, plotPaperUnits: 1)))
        XCTAssertTrue(manager.createNamedSetup(name: "A3 PDF", from: CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210, plotPaperUnits: 1)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("psetupin-\(UUID().uuidString).dxf")
        try DXFExporter.export(
            views: manager.activeTab!.drawingViews, to: url,
            namedSetups: manager.activeTab!.namedPageSetups)
        return url
    }

    func testPSetupInImportAndConflict() throws {
        let url = try fixtureWithTwoSetups()
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = makeManager()
        let harness = Harness()
        let ctx = context(manager: manager, harness: harness)
        let session = PlotCliSession.start(flow: .psetupin, ctx: ctx)
        session.handle(url.path, ctx: ctx)
        session.handle("?", ctx: ctx)
        XCTAssertTrue(harness.lines.joined().contains("A1 PDF"))
        session.handle("A*", ctx: ctx)
        XCTAssertTrue(harness.finished)
        XCTAssertEqual(manager.activeTab?.namedPageSetups.count, 2)

        // Re-import collides → redefine prompt.
        let harness2 = Harness()
        let ctx2 = context(manager: manager, harness: harness2)
        let session2 = PlotCliSession.start(flow: .psetupin, ctx: ctx2)
        session2.handle(url.path, ctx: ctx2)
        session2.handle("A1 PDF", ctx: ctx2)
        XCTAssertFalse(harness2.finished)
        XCTAssertTrue(harness2.lines.joined().contains("already exists"))
        session2.handle("Y", ctx: ctx2) // redefine
        XCTAssertTrue(harness2.finished)
        XCTAssertTrue(harness2.lines.joined().contains("Redefined"))

        // Skip path.
        let harness3 = Harness()
        let ctx3 = context(manager: manager, harness: harness3)
        let session3 = PlotCliSession.start(flow: .psetupin, ctx: ctx3)
        session3.handle(url.path, ctx: ctx3)
        session3.handle("A3 PDF", ctx: ctx3)
        session3.handle("N", ctx: ctx3)
        XCTAssertTrue(harness3.finished)
        XCTAssertTrue(harness3.lines.joined().contains("Skipped"))
    }
}
