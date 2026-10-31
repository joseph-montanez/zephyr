import XCTest
@testable import ZephyrCore

/// Paper-space Phase 2: live sheet viewports.
///
/// Sheets keep viewport definitions on their projected copies. Activating a
/// sheet rebuilds derived geometry from the current model document (undo-free,
/// revision-free). Projected copies are render-only: hit-testing, rect/lasso
/// selection, select-all, and document mutations must skip them.
final class PaperSpacePhase2Tests: XCTestCase {

    private func makeLayeredDoc(layerName: String) -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layerID = UUID()
        let layer = Layer(
            handle: layerID, name: layerName, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layerID)
    }

    private func makeLine(layerID: UUID, from: Vector3, to: Vector3) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: from, end: to, color: .white)],
            transform: .identity)
    }

    /// Build a sheet that carries one exact viewport definition by projecting
    /// a single model line through it, mirroring DXFImporter.projectedEntities.
    private func makeSheetWithViewport(
        modelLine: CADEntity, modelLayer: Layer
    ) -> CADDocument {
        let viewport = DXFImporter.SheetViewport(
            paperCenterX: 6, paperCenterY: 4.5,
            paperWidth: 12, paperHeight: 9,
            status: 2, id: 2,
            viewCenterX: 0, viewCenterY: 0,
            viewTargetX: 50, viewTargetY: 0,
            viewHeight: 100, twistAngle: 0,
            layerName: "MODEL")
        var cache = DXFImporter.SheetProjectionCache()
        cache.exactViewports = [viewport]
        let projected = DXFImporter.projectedEntities(
            modelEntities: [modelLine],
            cache: cache,
            xrefBlockIDs: [])
        XCTAssertEqual(projected.count, 1)
        XCTAssertTrue(projected[0].isViewportProjected)
        let (sheetDoc, sheetLayerID) = makeLayeredDoc(layerName: "SheetLayer")
        // Adopt the model layer so the projection resolves, then store it.
        sheetDoc.importLayersBlocksEntities(
            layers: [modelLayer], blocks: [], entities: projected)
        // Paper-owned geometry the refresh must preserve.
        let paperLine = makeLine(
            layerID: sheetLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 1, y: 1, z: 0))
        sheetDoc.addEntity(paperLine)
        return sheetDoc
    }

    @MainActor
    private func makeManager(modelDoc: CADDocument, sheetDoc: CADDocument) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Phase2",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    @MainActor
    func testSheetRefreshPicksUpModelEdit() {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)

        let sheetDoc = makeSheetWithViewport(
            modelLine: line, modelLayer: modelLayer)
        // Rebuild sheet with a stable paper layer handle for assertions.
        let paperLayerID = sheetDoc.allLayers.first(where: { $0.name == "SheetLayer" })!.handle
        // Baseline clean so refresh dirt can be observed.
        sheetDoc.savedRevision = sheetDoc.editRevision
        modelDoc.savedRevision = modelDoc.editRevision

        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        // Activate the sheet: initial projection of the one model line.
        XCTAssertTrue(manager.switchToView(at: 1))
        let initialProjected = sheetDoc.entitiesView.filter { $0.isViewportProjected }
        XCTAssertEqual(initialProjected.count, 1)

        // Edit the model, return to Model, then back to the sheet.
        XCTAssertTrue(manager.switchToView(at: 0))
        let line2 = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 10, z: 0), to: Vector3(x: 100, y: 10, z: 0))
        modelDoc.addEntity(line2)
        XCTAssertTrue(manager.switchToView(at: 1))

        let refreshed = sheetDoc.entitiesView.filter { $0.isViewportProjected }
        XCTAssertEqual(refreshed.count, 2, "sheet must re-project both model lines")
        // Paper geometry untouched.
        let paper = sheetDoc.entitiesView.filter { !$0.isViewportProjected }
        XCTAssertEqual(paper.count, 1)
        XCTAssertEqual(paper.first?.layerID, paperLayerID)
        // Refresh is undo-free and revision-free: sheet stays clean even
        // though the model edit dirtied the model document.
        XCTAssertFalse(sheetDoc.hasUnsavedChanges)
        XCTAssertTrue(modelDoc.hasUnsavedChanges)
    }

    @MainActor
    func testProjectedCopiesAreNotSelectableOrErasable() {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let sheetDoc = makeSheetWithViewport(
            modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))

        guard let projected = sheetDoc.entitiesView.first(where: { $0.isViewportProjected }),
              let paper = sheetDoc.entitiesView.first(where: { !$0.isViewportProjected }),
              let worldBox = projected.worldBoundingBox else {
            XCTFail("expected one projected and one paper entity")
            return
        }
        let center = worldBox.center

        // Point hit test skips derived copies: the hit (if any) must never
        // be a projected copy. Paper geometry may still hit within the
        // generous threshold.
        if let hit = CADHitTesting.hitTest(
            worldX: center.x, worldY: center.y, document: sheetDoc, threshold: 1000) {
            XCTAssertFalse(sheetDoc.entity(for: hit)?.isViewportProjected == true)
        }
        // Closest-entity query also skips them when paper geometry is far away.
        // (Paper line is at the origin; the projected copy may overlap it, so
        // assert at minimum that a projected handle is never returned.)
        if let closest = CADHitTesting.closestEntity(
            at: center.x, center.y, document: sheetDoc, threshold: 1000) {
            XCTAssertFalse(sheetDoc.entity(for: closest)?.isViewportProjected == true)
        }

        // Rect and lasso selection skip derived copies.
        let selection = CADSelectionManager()
        selection.selectAll(in: sheetDoc)
        XCTAssertFalse(selection.selectedHandles.contains(projected.handle))
        XCTAssertTrue(selection.selectedHandles.contains(paper.handle))

        // Erase / move / scale of derived copies are no-ops.
        let revisionBefore = sheetDoc.editRevision
        sheetDoc.removeEntity(handle: projected.handle)
        sheetDoc.removeEntities(handles: [projected.handle])
        sheetDoc.moveEntities(handles: [projected.handle], by: Vector3(x: 10, y: 0, z: 0))
        sheetDoc.scaleEntities(
            handles: [projected.handle], around: Vector3(x: 0, y: 0, z: 0), factor: 2)
        XCTAssertNotNil(sheetDoc.entity(for: projected.handle))
        XCTAssertEqual(sheetDoc.editRevision, revisionBefore)

        // Paper entities still edit normally.
        sheetDoc.moveEntities(handles: [paper.handle], by: Vector3(x: 5, y: 0, z: 0))
        XCTAssertNotEqual(sheetDoc.editRevision, revisionBefore)
    }

    @MainActor
    func testRefreshDoesNotDirtyCleanSheet() {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        modelDoc.addEntity(line)
        let sheetDoc = makeSheetWithViewport(
            modelLine: line, modelLayer: modelLayer)
        sheetDoc.savedRevision = sheetDoc.editRevision
        XCTAssertFalse(sheetDoc.hasUnsavedChanges)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        XCTAssertFalse(sheetDoc.hasUnsavedChanges)
        // Second activation with no model change is still clean.
        XCTAssertTrue(manager.switchToView(at: 0))
        XCTAssertTrue(manager.switchToView(at: 1))
        XCTAssertFalse(sheetDoc.hasUnsavedChanges)
    }
}
