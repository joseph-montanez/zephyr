import XCTest
import Foundation
@testable import ZephyrCore

/// Place-on-sheet viewport half: `placeNamedView` puts a named model
/// view on the active sheet at an exact scale (paper frame derived as
/// `model / scale`, viewport span exactly the view bounds). The
/// `createSheetViewport` regression pins the shared insertion tail.
@MainActor
final class PlaceNamedViewTests: XCTestCase {

    private func managerWithSheet(
        modelDoc: CADDocument, sheetDoc: CADDocument
    ) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Place",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        return manager
    }

    private func lineEntity(layerID: UUID, from: Vector3, to: Vector3) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: from, end: to, color: nil)],
            transform: .identity)
    }

    func testPlaceNamedViewExactScale() {
        let manager = managerWithSheet(
            modelDoc: CADDocument(), sheetDoc: CADDocument())
        let before = manager.activeSheetViewports().count
        // Named view: center (10, 20), 100 x 50 model units, placed 1:50
        // at paper point (7, -4) Y-up.
        let id = manager.placeNamedView(
            paperCenterXUp: 7, paperCenterYUp: -4,
            modelCenterX: 10, modelCenterY: 20,
            modelWidth: 100, modelHeight: 50,
            scaleDenominator: 50)
        let placedID = try? XCTUnwrap(id)
        XCTAssertNotNil(placedID)
        let placed = manager.activeSheetViewports().first(where: { $0.id == placedID })
        let viewport = try? XCTUnwrap(placed)
        XCTAssertEqual(manager.activeSheetViewports().count, before + 1)
        XCTAssertEqual(viewport?.viewTargetX ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(viewport?.viewTargetY ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(viewport?.viewHeight ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(viewport?.paperWidth ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(viewport?.paperHeight ?? 0, 1, accuracy: 1e-9)
        // Scale invariant: paper/model ratio is exactly 1:50.
        let ratio = (viewport?.paperHeight ?? 0) / (viewport?.viewHeight ?? 1)
        XCTAssertEqual(ratio, 1.0 / 50.0, accuracy: 1e-9)
        // Paper center stored positive-down.
        XCTAssertEqual(viewport?.paperCenterX ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(viewport?.paperCenterY ?? 0, 4, accuracy: 1e-9)
        XCTAssertFalse(viewport?.stableID.isEmpty ?? true)
    }

    func testPlaceNamedViewRejectsDegenerate() {
        let manager = managerWithSheet(
            modelDoc: CADDocument(), sheetDoc: CADDocument())
        let before = manager.activeSheetViewports().count
        XCTAssertNil(manager.placeNamedView(
            paperCenterXUp: 0, paperCenterYUp: 0,
            modelCenterX: 0, modelCenterY: 0,
            modelWidth: 100, modelHeight: 50,
            scaleDenominator: 0))
        XCTAssertNil(manager.placeNamedView(
            paperCenterXUp: 0, paperCenterYUp: 0,
            modelCenterX: 0, modelCenterY: 0,
            modelWidth: 0, modelHeight: 50,
            scaleDenominator: 50))
        XCTAssertEqual(manager.activeSheetViewports().count, before)
    }

    func testPlaceSheetViewAttachesInsertsAndPlaces() throws {
        let modelDoc = CADDocument()
        let manager = managerWithSheet(modelDoc: modelDoc, sheetDoc: CADDocument())
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceSheetView-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modelURL = dir.appendingPathComponent("model.dxf")
        try DXFExporter.export(document: CADDocument(), to: modelURL)
        let placed = try manager.placeSheetView(
            modelFileURL: modelURL,
            modelCenterX: 0, modelCenterY: 0,
            modelWidth: 100, modelHeight: 50,
            paperCenterXUp: 5, paperCenterYUp: -2,
            scaleDenominator: 50)
        XCTAssertTrue(modelDoc.allBlocks.contains(where: {
            $0.handle == placed.blockHandle && $0.isXref
        }))
        let counts = XrefPalettePolicy.instanceCounts(documents: [modelDoc])
        XCTAssertEqual(counts[placed.blockHandle], 1)
        let viewport = try XCTUnwrap(
            manager.activeSheetViewports().first(where: { $0.id == placed.viewportID }))
        XCTAssertEqual(viewport.viewTargetX, 0, accuracy: 1e-9)
        XCTAssertEqual(viewport.viewHeight, 50, accuracy: 1e-9)
        XCTAssertEqual(viewport.paperWidth, 2, accuracy: 1e-9)
        XCTAssertEqual(viewport.paperHeight, 1, accuracy: 1e-9)
        // A second place reuses the definition and the instance.
        let again = try manager.placeSheetView(
            modelFileURL: modelURL,
            modelCenterX: 0, modelCenterY: 0,
            modelWidth: 100, modelHeight: 50,
            paperCenterXUp: 9, paperCenterYUp: -2,
            scaleDenominator: 50)
        XCTAssertEqual(again.blockHandle, placed.blockHandle)
        XCTAssertEqual(modelDoc.allBlocks.filter(\.isXref).count, 1)
        let recount = XrefPalettePolicy.instanceCounts(documents: [modelDoc])
        XCTAssertEqual(recount[placed.blockHandle], 1)
        XCTAssertEqual(manager.activeSheetViewports().count, 2)
    }

    func testPlaceSheetViewRejectsGeometryBeforeAttaching() throws {
        let modelDoc = CADDocument()
        let manager = managerWithSheet(modelDoc: modelDoc, sheetDoc: CADDocument())
        XCTAssertThrowsError(try manager.placeSheetView(
            modelFileURL: URL(fileURLWithPath: "/nonexistent/model.dxf"),
            modelCenterX: 0, modelCenterY: 0,
            modelWidth: 100, modelHeight: 50,
            paperCenterXUp: 0, paperCenterYUp: 0,
            scaleDenominator: 0))
        XCTAssertTrue(modelDoc.allBlocks.filter(\.isXref).isEmpty)
    }

    func testCreateSheetViewportStillFitsExtents() {
        let modelDoc = CADDocument()
        let layer = Layer(name: "0")
        modelDoc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        modelDoc.addEntity(lineEntity(
            layerID: layer.handle,
            from: Vector3(x: 10, y: 20, z: 0),
            to: Vector3(x: 110, y: 20, z: 0)))
        modelDoc.addEntity(lineEntity(
            layerID: layer.handle,
            from: Vector3(x: 10, y: 20, z: 0),
            to: Vector3(x: 10, y: 70, z: 0)))
        let manager = managerWithSheet(modelDoc: modelDoc, sheetDoc: CADDocument())
        let newID = manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 20, paperY2: 10)
        let createdID = try? XCTUnwrap(newID)
        XCTAssertNotNil(createdID)
        let created = manager.activeSheetViewports().first(where: { $0.id == createdID })
        // Bounds center (60, 45) with 0.9 fit factor preserved by refactor.
        XCTAssertEqual(created?.viewTargetX ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(created?.viewTargetY ?? 0, 45, accuracy: 1e-9)
        let fitScale = min(20.0 / 100.0, 10.0 / 50.0) * 0.9
        XCTAssertEqual(created?.viewHeight ?? 0, 10.0 / fitScale, accuracy: 1e-6)
    }
}
