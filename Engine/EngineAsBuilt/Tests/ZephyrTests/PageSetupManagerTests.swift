import XCTest
@testable import ZephyrCore

/// Phase 2 steps 13/14/16: `TabManager` named-setup operations
/// (validate / create / rename / delete guard / apply / propagate).
final class PageSetupManagerTests: XCTestCase {

    private func makeLayeredDoc(layerName: String) -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            handle: UUID(), name: layerName, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return doc
    }

    @MainActor
    private func makeManager() -> TabManager {
        let manager = TabManager()
        let modelDoc = makeLayeredDoc(layerName: "ModelLayer")
        let sheetDoc = makeLayeredDoc(layerName: "SheetLayer")
        sheetDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Mgr",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    private func paperSettings(named name: String = "") -> CADPlotSettings {
        CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 0,
            pageSetupName: name,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A3_(420.00_x_297.00_MM)")
    }

    @MainActor
    func testValidateCreateRenameDelete() throws {
        let manager = makeManager()
        XCTAssertNotNil(manager.validatePageSetupName(""))
        XCTAssertNotNil(manager.validatePageSetupName("A/B"))
        XCTAssertNil(manager.validatePageSetupName("A1 PDF"))
        XCTAssertTrue(manager.createNamedSetup(name: "A1 PDF", from: paperSettings()))
        // Duplicate (case-insensitive) and blank rejected.
        XCTAssertFalse(manager.createNamedSetup(name: "a1 pdf", from: paperSettings()))
        XCTAssertFalse(manager.createNamedSetup(name: "  ", from: paperSettings()))
        // Stored name normalizes pageSetupName.
        let stored = try XCTUnwrap(manager.activeTab?.namedPageSetups.first)
        XCTAssertEqual(stored.settings.pageSetupName, "A1 PDF")

        // Rename re-points bound layouts.
        XCTAssertTrue(manager.applyNamedSetupToLayout("A1 PDF", layoutName: "Layout1"))
        XCTAssertTrue(manager.renameNamedSetup(from: "A1 PDF", to: "A1 Final"))
        let doc = manager.activeTab?.drawingViews[1].document
        XCTAssertEqual(doc?.plotSettings?.pageSetupName, "A1 Final")
        XCTAssertTrue(manager.renameNamedSetup(from: "A1 Final", to: "A1 Final"))
        XCTAssertFalse(manager.renameNamedSetup(from: "Nope", to: "X"))

        // Delete refused while bound; allowed after unbinding.
        XCTAssertFalse(manager.deleteNamedSetup(named: "A1 Final"))
        var unbound = paperSettings()
        unbound.pageSetupName = ""
        XCTAssertTrue(manager.applyNamedSetupToLayout("A1 Final", layoutName: "Layout1") == true)
        // Directly clear the binding (simulates editing the layout to <None>).
        doc?.plotSettings?.pageSetupName = ""
        XCTAssertTrue(manager.deleteNamedSetup(named: "A1 Final"))
        XCTAssertFalse(manager.deleteNamedSetup(named: "A1 Final"))
    }

    @MainActor
    func testApplyCopiesFieldsAndIsUndoable() throws {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "A3 PDF", from: paperSettings()))
        XCTAssertTrue(manager.applyNamedSetupToLayout("A3 PDF", layoutName: "Layout1"))
        let doc = try XCTUnwrap(manager.activeTab?.drawingViews[1].document)
        XCTAssertEqual(doc.plotSettings?.canonicalMediaName, "ISO_A3_(420.00_x_297.00_MM)")
        XCTAssertEqual(doc.plotSettings?.plotConfigName, "DWG To PDF.pc3")
        XCTAssertEqual(doc.layoutSettings?.paperWidthMM, 420)
        // One undoable step restores the pre-apply settings.
        doc.undo()
        XCTAssertNotEqual(doc.plotSettings?.canonicalMediaName, "ISO_A3_(420.00_x_297.00_MM)")
    }

    @MainActor
    func testCustomScaleListOpsAndPersistence() throws {
        let manager = makeManager()
        XCTAssertTrue(manager.addCustomScaleFactor(0.02))
        XCTAssertFalse(manager.addCustomScaleFactor(0.02)) // duplicate
        XCTAssertFalse(manager.addCustomScaleFactor(0))
        XCTAssertFalse(manager.addCustomScaleFactor(Double.nan))
        XCTAssertTrue(manager.addCustomScaleFactor(2))
        XCTAssertEqual(manager.activeTab?.customScaleFactors ?? [], [0.02, 2.0])
        XCTAssertFalse(manager.removeCustomScaleFactor(atOneBasedIndex: 0))
        XCTAssertFalse(manager.removeCustomScaleFactor(atOneBasedIndex: 9))
        XCTAssertTrue(manager.removeCustomScaleFactor(atOneBasedIndex: 1))
        XCTAssertEqual(manager.activeTab?.customScaleFactors ?? [], [2.0])
        XCTAssertEqual(TabManager.customScaleLabel(for: 0.02), "Custom 1:50")
        XCTAssertEqual(TabManager.customScaleLabel(for: 2), "Custom 2:1")
        manager.resetCustomScaleFactors()
        XCTAssertEqual(manager.activeTab?.customScaleFactors ?? [], [])

        // EAB round-trip.
        XCTAssertTrue(manager.addCustomScaleFactor(0.02))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scalelist-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: manager.activeTab!.drawingViews, to: url,
                            scaleList: manager.activeTab!.customScaleFactors)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try EABReader.readScaleList(from: data), [0.02])
    }

    @MainActor
    func testUpdatePropagatesToBoundLayoutsOnly() throws {
        let manager = makeManager()
        XCTAssertTrue(manager.createNamedSetup(name: "A3 PDF", from: paperSettings()))
        XCTAssertTrue(manager.applyNamedSetupToLayout("A3 PDF", layoutName: "Layout1"))
        // Second unbound layout stays put.
        XCTAssertTrue(manager.createLayout(named: "Layout2"))
        var revised = paperSettings()
        revised.styleSheet = "monochrome.ctb"
        XCTAssertTrue(manager.updateNamedSetup(name: "A3 PDF", with: revised))
        let bound = manager.activeTab?.drawingViews.first(where: { $0.name == "Layout1" })?.document
        XCTAssertEqual(bound?.plotSettings?.styleSheet, "monochrome.ctb")
        XCTAssertEqual(bound?.plotSettings?.pageSetupName, "A3 PDF")
        let other = manager.activeTab?.drawingViews.first(where: { $0.name == "Layout2" })?.document
        XCTAssertNotEqual(other?.plotSettings?.styleSheet, "monochrome.ctb")
        XCTAssertFalse(manager.updateNamedSetup(name: "Nope", with: revised))
    }
}
