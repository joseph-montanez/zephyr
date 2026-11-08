import XCTest
@testable import ZephyrCore

/// Phase 1: `PaperSheetGeometry` pure-function tests (revised spec §4).
final class PaperSheetGeometryTests: XCTestCase {

    private func letterLandscape() -> CADPlotSettings {
        CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 215.9,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 0)
    }

    func testSheetSizePortraitAndLandscapeSwap() {
        var ps = letterLandscape()
        ps.plotRotation = 0
        let portrait = PaperSheetGeometry.sheetSize(for: ps)
        XCTAssertEqual(portrait.width, 279.4, accuracy: 1e-9)
        XCTAssertEqual(portrait.height, 215.9, accuracy: 1e-9)
        ps.plotRotation = 1
        let landscape = PaperSheetGeometry.sheetSize(for: ps)
        XCTAssertEqual(landscape.width, 215.9, accuracy: 1e-9)
        XCTAssertEqual(landscape.height, 279.4, accuracy: 1e-9)
        ps.plotRotation = 3
        let upsideLandscape = PaperSheetGeometry.sheetSize(for: ps)
        XCTAssertEqual(upsideLandscape.width, 215.9, accuracy: 1e-9)
        ps.plotRotation = 2
        let upsidePortrait = PaperSheetGeometry.sheetSize(for: ps)
        XCTAssertEqual(upsidePortrait.width, 279.4, accuracy: 1e-9)
    }

    func testSheetSizeScalesBy143Over142() {
        // 1:50 layout: sheet frames 50× so model-like title blocks fit inside.
        var ps = letterLandscape()
        ps.customScaleNumerator = 1
        ps.customScaleDenominator = 50
        let s = PaperSheetGeometry.sheetSize(for: ps)
        XCTAssertEqual(s.width, 279.4 * 50, accuracy: 1e-6)
        XCTAssertEqual(s.height, 215.9 * 50, accuracy: 1e-6)
        // Imperial 1" = 1' (Code 75 = 12) via explicit 142/143 ratio 1:12.
        var imp = letterLandscape()
        imp.plotPaperUnits = 0 // inches
        imp.paperWidthMM = 279.4
        imp.paperHeightMM = 215.9
        imp.customScaleNumerator = 1
        imp.customScaleDenominator = 12
        let inchSheet = PaperSheetGeometry.sheetSize(for: imp)
        XCTAssertEqual(inchSheet.width, 279.4 / 25.4 * 12, accuracy: 1e-6)
    }

    func testMarginPermutationAllFourRotations() {
        var ps = letterLandscape()
        ps.marginLM = 1; ps.marginBM = 2; ps.marginRM = 3; ps.marginTM = 4
        ps.plotRotation = 0
        XCTAssertEqual(PaperSheetGeometry.permutedMargins(for: ps).left, 1, accuracy: 1e-9)
        ps.plotRotation = 1
        let r1 = PaperSheetGeometry.permutedMargins(for: ps)
        XCTAssertEqual(r1.left, 4, accuracy: 1e-9)
        XCTAssertEqual(r1.bottom, 1, accuracy: 1e-9)
        XCTAssertEqual(r1.right, 2, accuracy: 1e-9)
        XCTAssertEqual(r1.top, 3, accuracy: 1e-9)
        ps.plotRotation = 2
        let r2 = PaperSheetGeometry.permutedMargins(for: ps)
        XCTAssertEqual(r2.left, 3, accuracy: 1e-9)
        XCTAssertEqual(r2.bottom, 4, accuracy: 1e-9)
        XCTAssertEqual(r2.right, 1, accuracy: 1e-9)
        XCTAssertEqual(r2.top, 2, accuracy: 1e-9)
        ps.plotRotation = 3
        let r3 = PaperSheetGeometry.permutedMargins(for: ps)
        XCTAssertEqual(r3.left, 2, accuracy: 1e-9)
        XCTAssertEqual(r3.bottom, 3, accuracy: 1e-9)
        XCTAssertEqual(r3.right, 4, accuracy: 1e-9)
        XCTAssertEqual(r3.top, 1, accuracy: 1e-9)
    }

    func testPrintableRectAndOriginBothPlotOffsetModes() {
        var ps = letterLandscape()
        ps.plotOriginXMM = 5; ps.plotOriginYMM = 5
        let printable = PaperSheetGeometry.printableRect(for: ps)
        XCTAssertEqual(printable.minX, 10, accuracy: 1e-9)
        XCTAssertEqual(printable.minY, 10, accuracy: 1e-9)
        XCTAssertEqual(printable.maxX, 279.4 - 10, accuracy: 1e-9)
        XCTAssertEqual(printable.maxY, 215.9 - 10, accuracy: 1e-9)
        // PLOTOFFSET=0: origin at printable corner minus offset.
        let o0 = PaperSheetGeometry.paperSpaceOrigin(for: ps, plotOffset: 0)
        XCTAssertEqual(o0.x, 5, accuracy: 1e-9)
        XCTAssertEqual(o0.y, 5, accuracy: 1e-9)
        // PLOTOFFSET=1: origin at paper edge minus offset.
        let o1 = PaperSheetGeometry.paperSpaceOrigin(for: ps, plotOffset: 1)
        XCTAssertEqual(o1.x, -5, accuracy: 1e-9)
        XCTAssertEqual(o1.y, -5, accuracy: 1e-9)
    }

    func testStaticPlotAreaRectPerType() {
        var ps = letterLandscape()
        ps.plotType = 5
        let layout = try? XCTUnwrap(PaperSheetGeometry.staticPlotAreaRect(for: ps))
        XCTAssertEqual(layout?.minX ?? -1, 10, accuracy: 1e-9)
        ps.plotType = 4
        ps.plotWindowMinX = 1; ps.plotWindowMinY = 2
        ps.plotWindowMaxX = 100; ps.plotWindowMaxY = 50
        let window = try? XCTUnwrap(PaperSheetGeometry.staticPlotAreaRect(for: ps))
        XCTAssertEqual(window?.maxX ?? -1, 100, accuracy: 1e-9)
        ps.plotType = 1 // Extents needs live data
        XCTAssertNil(PaperSheetGeometry.staticPlotAreaRect(for: ps))
        ps.plotType = 3 // View needs named-view resolution
        XCTAssertNil(PaperSheetGeometry.staticPlotAreaRect(for: ps))
    }

    func testOverlayRectsArePureAndSeparateFromEntities() {
        // The overlay derives only from settings: no entities are added, so
        // extents/zoom-extents, selection, and PDFExporter bounds (all
        // entity-driven) can never see the sheet.
        let doc = CADDocument()
        let layerID = UUID()
        doc.importLayersBlocksEntities(layers: [Layer(
            handle: layerID, name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")], blocks: [], entities: [])
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                   end: Vector3(x: 10, y: 5, z: 0), color: .white)],
            transform: .identity))
        doc.plotSettings = CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297, plotPaperUnits: 1)
        let before = doc.renderableWorldBoundingBox()
        // Overlay computation touches no document state.
        let rects = try? XCTUnwrap(PaperSheetGeometry.overlayRects(
            for: doc.plotSettings ?? CADPlotSettings()))
        let after = doc.renderableWorldBoundingBox()
        XCTAssertEqual(before?.min.x, after?.min.x)
        XCTAssertEqual(before?.max.x, after?.max.x)
        // Entity bounds stay at the line; the paper rect is far larger.
        XCTAssertEqual(after?.max.x ?? -1, 10, accuracy: 1e-9)
        XCTAssertGreaterThan((rects?.paper.maxX ?? 0) - (rects?.paper.minX ?? 0), 400)
    }

    @MainActor
    func testApplyPlotSettingsRerendersSheet() {
        // Phase 1 step 7: rotating Letter → A3 landscape via the test hook
        // updates plot + paper views and marks the document edited.
        let modelDoc = CADDocument()
        let sheetDoc = CADDocument()
        sheetDoc.plotSettings = CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
        sheetDoc.layoutSettings = sheetDoc.plotSettings?.layoutSettings
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "SheetHook",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        let a3 = CADPlotSettings(
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 1)
        XCTAssertTrue(manager.applyPlotSettings(a3))
        let doc = manager.activeTab?.drawingViews[manager.activeTab?.activeViewIndex ?? 0].document
        XCTAssertEqual(doc?.plotSettings?.paperWidthMM, 420)
        XCTAssertEqual(doc?.plotSettings?.plotRotation, 1)
        XCTAssertEqual(doc?.layoutSettings?.paperWidthMM, 420)
        XCTAssertEqual(doc?.hasUnsavedChanges, true)
        // Geometry follows the new settings immediately.
        let rects = try? XCTUnwrap(PaperSheetGeometry.overlayRects(
            for: doc?.plotSettings ?? CADPlotSettings()))
        XCTAssertEqual((rects?.paper.maxX ?? 0) - (rects?.paper.minX ?? 0), 297, accuracy: 1e-9)
        XCTAssertFalse(manager.applyPlotSettings(a3, toViewNamed: "Nope"))
        _ = a3
    }

    func testSyncedLimitsMatchWriter() {
        var ps = letterLandscape()
        ps.paperWidthMM = 420; ps.paperHeightMM = 297
        ps.plotOriginXMM = 5; ps.plotOriginYMM = 5
        let synced = PaperSheetGeometry.syncedLimits(for: ps)
        XCTAssertEqual(synced.min.x, -5, accuracy: 1e-9)
        XCTAssertEqual(synced.min.y, -5, accuracy: 1e-9)
        XCTAssertEqual(synced.max.x, 415, accuracy: 1e-9)
        XCTAssertEqual(synced.max.y, 292, accuracy: 1e-9)
    }
}
