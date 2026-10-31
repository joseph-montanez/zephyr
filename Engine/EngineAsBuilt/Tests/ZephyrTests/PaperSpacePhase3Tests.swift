import XCTest
@testable import ZephyrCore

/// Paper-space Phase 3: floating-viewport editing and scale.
///
/// Covers viewport pick/inspect, MVIEW create, scale/twist/on-off updates,
/// ZOOM nXP parsing, and CHSPACE moves in both directions — all at the
/// TabManager model level (command text wiring is exercised separately).
final class PaperSpacePhase3Tests: XCTestCase {

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

    /// Sheet with one exact viewport showing `modelLine`, plus one paper line.
    private func makeSheetWithViewport(
        modelLine: CADEntity, modelLayer: Layer
    ) -> (sheetDoc: CADDocument, paperLayerID: UUID) {
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
        let (sheetDoc, sheetLayerID) = makeLayeredDoc(layerName: "SheetLayer")
        sheetDoc.importLayersBlocksEntities(
            layers: [modelLayer], blocks: [], entities: projected)
        let paperLine = makeLine(
            layerID: sheetLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 1, y: 1, z: 0))
        sheetDoc.addEntity(paperLine)
        return (sheetDoc, sheetLayerID)
    }

    @MainActor
    private func makeManager(modelDoc: CADDocument, sheetDoc: CADDocument) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Phase3",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    @MainActor
    func testViewportPickAndInspect() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))

        let viewports = manager.activeSheetViewports()
        XCTAssertEqual(viewports.count, 1)
        let viewport = try XCTUnwrap(viewports.first)
        XCTAssertEqual(viewport.id, 2)
        XCTAssertTrue(viewport.isUsable)
        XCTAssertEqual(viewport.scale, 9.0 / 100.0, accuracy: 1e-9)

        // Frame center in sheet coordinates: paperCenterY stored positive-down.
        let rect = viewport.paperRect
        XCTAssertLessThan(rect.minX, rect.maxX)
        XCTAssertLessThan(rect.minY, rect.maxY)
        let centerX = (rect.minX + rect.maxX) / 2.0
        let centerY = (rect.minY + rect.maxY) / 2.0
        let picked = manager.selectViewport(atPaperPoint: centerX, centerY)
        XCTAssertEqual(picked?.id, 2)
        // Active viewport follows the pick.
        XCTAssertEqual(manager.activeViewport()?.id, 2)
        // Far outside the frame picks nothing.
        XCTAssertNil(manager.selectViewport(
            atPaperPoint: rect.minX - 1000, rect.minY - 1000))
    }

    @MainActor
    func testCreateViewportAddsProjections() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        for y in [0.0, 10.0] {
            modelDoc.addEntity(makeLine(
                layerID: modelLayerID,
                from: Vector3(x: 0, y: y, z: 0),
                to: Vector3(x: 100, y: y, z: 0)))
        }
        let firstLine = try XCTUnwrap(modelDoc.entitiesView.first)
        let (sheetDoc, _) = makeSheetWithViewport(
            modelLine: firstLine, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        // Baseline refresh projects both model lines through viewport 2.
        manager.refreshActiveSheetProjections()
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ $0.isViewportProjected }).count, 2)

        let newID = manager.createSheetViewport(
            paperX1: 20, paperY1: -8, paperX2: 32, paperY2: 8)
        XCTAssertEqual(newID, 3)
        XCTAssertEqual(manager.activeSheetViewports().count, 2)
        // Both viewports project both model lines.
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ $0.isViewportProjected }).count, 4)
        // Paper geometry preserved; refresh stays clean.
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ !$0.isViewportProjected }).count, 1)
    }

    @MainActor
    func testViewportScaleUpdate() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        let before = try XCTUnwrap(
            sheetDoc.entitiesView.first(where: { $0.isViewportProjected })?.transform)

        XCTAssertTrue(manager.updateActiveSheetViewport(id: 2, scale: 2.0))
        let viewport = try XCTUnwrap(manager.activeViewport())
        XCTAssertEqual(viewport.scale, 2.0, accuracy: 1e-9)
        // Projections rebuild through the new (tighter) view height.
        let after = try XCTUnwrap(
            sheetDoc.entitiesView.first(where: { $0.isViewportProjected })?.transform)
        XCTAssertNotEqual(before, after)
        // Unknown id fails honestly.
        XCTAssertFalse(manager.updateActiveSheetViewport(id: 99, scale: 2.0))
    }

    @MainActor
    func testViewportOffRemovesAndOnRestores() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ $0.isViewportProjected }).count, 1)

        XCTAssertTrue(manager.updateActiveSheetViewport(id: 2, status: 0))
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ $0.isViewportProjected }).count, 0)
        // Paper geometry survives the off state.
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ !$0.isViewportProjected }).count, 1)

        // The OFF viewport persists via the store and comes back on.
        XCTAssertTrue(manager.updateActiveSheetViewport(id: 2, status: 2))
        XCTAssertEqual(
            sheetDoc.entitiesView.filter({ $0.isViewportProjected }).count, 1)
    }

    @MainActor
    func testViewportDetailDescription() {
        let viewport = DXFImporter.SheetViewport(
            paperCenterX: 6, paperCenterY: 4.5,
            paperWidth: 12, paperHeight: 9,
            status: 2, id: 2,
            viewCenterX: 0, viewCenterY: 0,
            viewTargetX: 50, viewTargetY: 0,
            viewHeight: 100, twistAngle: 0,
            layerName: "MODEL")
        let detail = viewport.detailDescription
        XCTAssertTrue(detail.contains("id=2"), detail)
        XCTAssertTrue(detail.contains("scale=1:0.09"), detail)
        XCTAssertTrue(detail.contains("twist=0deg"), detail)
        XCTAssertTrue(detail.contains("rect="), detail)
    }

    @MainActor
    func testZoomXPParsesPaperScale() {
        let zoom = ZoomCommand()
        if case .paperSpace(let n) = zoom.parseScaleInput("2XP") {
            XCTAssertEqual(n, 2.0, accuracy: 1e-9)
        } else {
            XCTFail("2XP must parse as paperSpace")
        }
        if case .paperSpace(let n) = zoom.parseScaleInput("0.5xp") {
            XCTAssertEqual(n, 0.5, accuracy: 1e-9)
        } else {
            XCTFail("0.5xp must parse as paperSpace")
        }
        if case .viewRelative(let n) = zoom.parseScaleInput("2X") {
            XCTAssertEqual(n, 2.0, accuracy: 1e-9)
        } else {
            XCTFail("2X must parse as viewRelative")
        }
        if case .drawingRelative(let n) = zoom.parseScaleInput("2") {
            XCTAssertEqual(n, 2.0, accuracy: 1e-9)
        } else {
            XCTFail("2 must parse as drawingRelative")
        }
        if case .invalid = zoom.parseScaleInput("abc") {
        } else {
            XCTFail("abc must be invalid")
        }
    }

    @MainActor
    func testChspacePaperToModel() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))

        let paper = try XCTUnwrap(
            sheetDoc.entitiesView.first(where: { !$0.isViewportProjected }))
        let viewport = try XCTUnwrap(manager.activeViewport())
        let expected = viewport.modelToPaperTransform.inverse()
            .multiplying(by: paper.transform)

        let moved = manager.chspace(handles: [paper.handle])
        XCTAssertEqual(moved, 1)
        XCTAssertNil(sheetDoc.entity(for: paper.handle))
        let inModel = modelDoc.entitiesView.first(where: {
            $0.localGeometry == paper.localGeometry && $0.handle != line.handle
        })
        let movedEntity = try XCTUnwrap(inModel)
        XCTAssertEqual(movedEntity.transform, expected)
        XCTAssertFalse(movedEntity.isViewportProjected)
    }

    @MainActor
    func testChspaceModelToSheet() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let extra = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 50, z: 0), to: Vector3(x: 50, y: 50, z: 0))
        modelDoc.addEntity(extra)
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        // Stay on the Model view: CHSPACE targets the first sheet.
        XCTAssertEqual(manager.activeViewName, "Model")

        let viewport = try XCTUnwrap(
            manager.sheetViewports(for: sheetDoc).first(where: { $0.isUsable }))
        let expected = viewport.modelToPaperTransform
            .multiplying(by: extra.transform)
        let moved = manager.chspace(handles: [extra.handle])
        XCTAssertEqual(moved, 1)
        XCTAssertNil(modelDoc.entity(for: extra.handle))
        let inSheet = sheetDoc.entitiesView.first(where: {
            $0.localGeometry == extra.localGeometry && !$0.isViewportProjected
        })
        let movedEntity = try XCTUnwrap(inSheet)
        XCTAssertEqual(movedEntity.transform, expected)
    }
}
