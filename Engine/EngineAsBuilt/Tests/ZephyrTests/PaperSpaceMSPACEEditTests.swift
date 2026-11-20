import XCTest
@testable import ZephyrCore

/// MSPACE in-place editing + PSPACE border picking + dirty reproject.
/// Headless coverage for the Layout-as-editable-container slice.
final class PaperSpaceMSPACEEditTests: XCTestCase {

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

    @MainActor
    private func makeManager(modelDoc: CADDocument, sheetDoc: CADDocument) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "MSPACE",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    @MainActor
    func testViewportFrameMoveResizeSingleUndo() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        let before = try XCTUnwrap(manager.activeViewport())
        // Live moves mutate without pushing undo per mousemove.
        let depthBefore = sheetDoc.undoManager.undoDepth
        XCTAssertTrue(manager.updateViewportFrameLive(
            id: id, paperCenter: (x: before.paperCenterX + 10, y: before.paperCenterY)))
        XCTAssertTrue(manager.updateViewportFrameLive(
            id: id, paperCenter: (x: before.paperCenterX + 20, y: before.paperCenterY)))
        XCTAssertEqual(sheetDoc.undoManager.undoDepth, depthBefore)
        // Single-undo commit via the bordered update path.
        XCTAssertTrue(manager.moveActiveSheetViewport(
            id: id, toPaperCenter: (x: before.paperCenterX + 20, y: before.paperCenterY)))
        XCTAssertEqual(sheetDoc.undoManager.undoDepth, depthBefore + 1)
        // Corner resize keeps a valid frame.
        let resized = try XCTUnwrap(manager.activeViewport())
        XCTAssertTrue(manager.updateViewportFrameLive(
            id: id, paperSize: (width: resized.paperWidth + 10, height: resized.paperHeight + 10)))
        let after = try XCTUnwrap(manager.activeViewport())
        XCTAssertGreaterThan(after.paperWidth, resized.paperWidth)
    }

    @MainActor
    func testDimensionTargetMapsPaperToModel() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        let target = manager.dimensionTarget(activeDoc: sheetDoc)
        XCTAssertTrue(target.isFloating)
        XCTAssertTrue(target.doc === modelDoc)
        let paper = Vector3(x: 50, y: 10, z: 0)
        let mapped = target.map(paper)
        let ctx = try XCTUnwrap(manager.editSpaceContext())
        let expected = ctx.paperToModel.transformPoint(paper)
        XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-9)
        XCTAssertGreaterThan(manager.mapPaperDistanceToModel(10), 0)
    }

    @MainActor
    func testPaperToModelToPaperRoundTrip() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 50, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        let ctx = try XCTUnwrap(manager.editSpaceContext())
        let paper = ctx.modelToPaper.transformPoint(Vector3(x: 10, y: 5, z: 0))
        let back = ctx.paperToModel.transformPoint(paper)
        XCTAssertEqual(back.x, 10, accuracy: 1e-9)
        XCTAssertEqual(back.y, 5, accuracy: 1e-9)
    }

    @MainActor
    func testBorderPickIgnoresInterior() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        _ = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -20, paperX2: 100, paperY2: 20))
        // Interior point is inside the frame but far from the border.
        XCTAssertNil(manager.selectViewportBorder(atPaperPoint: 50, -0, tolerance: 2.0))
        // Border point near the left edge picks.
        XCTAssertNotNil(manager.selectViewportBorder(atPaperPoint: 1, -0, tolerance: 2.0))
        // Interior double-click entry still uses the interior test.
        XCTAssertNotNil(manager.selectViewport(atPaperPoint: 50, 0))
    }

    @MainActor
    func testFloatingHitTestAndBoxSelect() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 20, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        let ctx = try XCTUnwrap(manager.editSpaceContext())
        // Map a known model point to paper, then hit-test it.
        let paper = ctx.modelToPaper.transformPoint(Vector3(x: 10, y: 0, z: 0))
        let hit = manager.floatingHitTest(paperX: paper.x, paperY: paper.y, paperThreshold: 4.0)
        XCTAssertNotNil(hit)
        // Miss outside the clip.
        XCTAssertNil(manager.floatingHitTest(
            paperX: ctx.clipMaxX + 50, paperY: ctx.clipMaxY + 50, paperThreshold: 4.0))
        // Box select around the paper projection finds the model line.
        // Crossing (not window): the quad is smaller than the 20-unit line.
        let found = manager.floatingBoxSelect(
            paperMinX: paper.x - 5, paperMinY: paper.y - 5,
            paperMaxX: paper.x + 5, paperMaxY: paper.y + 5, isWindow: false)
        XCTAssertEqual(found.count, 1)
    }

    @MainActor
    func testCommitPaperEntitiesAsModel() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, sheetLayer) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        let before = modelDoc.entitiesView.count
        let paperEntity = makeLine(layerID: sheetLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        XCTAssertTrue(manager.commitPaperEntitiesAsModel([paperEntity]))
        XCTAssertEqual(modelDoc.entitiesView.count, before + 1)
        // Sheet doc itself gains no loose paper geometry from the MSPACE commit.
        XCTAssertTrue(sheetDoc.entitiesView.filter({ !$0.isViewportProjected }).isEmpty)
    }

    @MainActor
    func testFloatingUndoRefreshesAndPrunes() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        let ctx = try XCTUnwrap(manager.editSpaceContext())
        let paper = ctx.modelToPaper.transformPoint(Vector3(x: 5, y: 0, z: 0))
        let hit = try XCTUnwrap(manager.floatingHitTest(
            paperX: paper.x, paperY: paper.y, paperThreshold: 4.0))
        manager.floatingSelection = [hit]
        // Delete the model entity behind the floating selection, then undo
        // through the floating path: projections refresh and stale handles drop.
        let target = try XCTUnwrap(modelDoc.entitiesView.first).handle
        modelDoc.removeEntities(handles: [target])
        XCTAssertFalse(modelDoc.entitiesView.map(\.handle).contains(hit))
        manager.undoFloatingEdit()
        // Undo restores model geometry; prune keeps only live handles.
        XCTAssertTrue(modelDoc.entitiesView.map(\.handle).contains(hit))
        manager.pruneFloatingSelection()
        XCTAssertTrue(manager.floatingSelection.contains(hit))
        modelDoc.removeEntities(handles: [hit])
        manager.pruneFloatingSelection()
        XCTAssertFalse(manager.floatingSelection.contains(hit))
    }

    @MainActor
    func testSiblingLayoutReprojectsOnSwitch() throws {
        let (modelDoc, modelLayer) = makeLayeredDoc(layerName: "M")
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        let (sheetDoc, _) = makeLayeredDoc(layerName: "S")
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Sibling",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
                DrawingView(name: "Layout2", kind: .sheet, document: {
                    let d = CADDocument()
                    d.importLayersBlocksEntities(
                        layers: modelDoc.allLayers, blocks: modelDoc.allBlocks, entities: [])
                    return d
                }()),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        _ = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        XCTAssertTrue(manager.switchToView(at: 2))
        _ = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: -40, paperX2: 100, paperY2: 40))
        // Edit the model from Layout1's floating session, then switch to
        // Layout2: the dirty watermark must trigger a reproject on entry.
        XCTAssertTrue(manager.switchToView(at: 1))
        let id = try XCTUnwrap(manager.activeUsableViewports().first?.id)
        _ = try XCTUnwrap(manager.enterFloatingModelSpace(id: id))
        modelDoc.addEntity(makeLine(layerID: modelLayer,
            from: Vector3(x: 0, y: 20, z: 0), to: Vector3(x: 10, y: 20, z: 0)))
        manager.refreshActiveSheetProjections()
        manager.markActiveSheetProjected()
        manager.exitFloatingModelSpace()
        XCTAssertTrue(manager.switchToView(at: 2))
        let layout2 = manager.activeTab!.drawingViews[2].document
        XCTAssertFalse(layout2.entitiesView.filter({ $0.isViewportProjected }).isEmpty)
    }
}
