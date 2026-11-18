import XCTest
@testable import ZephyrCore

/// Draw-order vs unordered (`Int.max`) entities.
///
/// Reported defect: on a fresh drawing every entity has `drawOrder == .max`
/// (no explicit order). Bring-to-front assigned `0`, which still sorts
/// behind every unordered entity, so a line brought to front over a dropped
/// image stayed underneath. Same class for send-to-back, undo coalescing,
/// and multi-select determinism.
@MainActor
final class DrawOrderIntMaxTests: XCTestCase {

    private func lineEntity(layer: Layer, drawOrder: Int = .max) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0),
                color: nil)],
            drawOrder: drawOrder)
    }

    private func makeDoc(count: Int) -> (CADDocument, [CADEntity]) {
        let doc = CADDocument()
        let layer = Layer(name: "L1", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        var entities: [CADEntity] = []
        for _ in 0..<count {
            let e = lineEntity(layer: layer)
            doc.addEntity(e)
            entities.append(e)
        }
        return (doc, entities)
    }

    /// Renderer/PDF comparator: lower draws first, ties by handle string.
    private func frontHandle(in doc: CADDocument) -> UUID {
        let sorted = doc.entitiesView.sorted {
            if $0.drawOrder != $1.drawOrder { return $0.drawOrder < $1.drawOrder }
            return $0.handle.uuidString < $1.handle.uuidString
        }
        return sorted.last!.handle
    }

    private func backHandle(in doc: CADDocument) -> UUID {
        let sorted = doc.entitiesView.sorted {
            if $0.drawOrder != $1.drawOrder { return $0.drawOrder < $1.drawOrder }
            return $0.handle.uuidString < $1.handle.uuidString
        }
        return sorted.first!.handle
    }

    func testBringToFrontBeatsUnorderedEntities() {
        let (doc, entities) = makeDoc(count: 2)
        let target = entities[0].handle
        _ = applyBringToFront(handles: [target], document: doc)
        XCTAssertEqual(
            frontHandle(in: doc), target,
            "bring-to-front must sort after every unordered (.max) entity")
    }

    func testSendToBackBelowUnorderedEntities() {
        let (doc, entities) = makeDoc(count: 2)
        let target = entities[0].handle
        _ = applySendToBack(handles: [target], document: doc)
        XCTAssertEqual(
            backHandle(in: doc), target,
            "send-to-back must sort before every unordered (.max) entity")
    }

    func testBringToFrontIsSingleUndoStep() {
        let (doc, entities) = makeDoc(count: 3)
        let depthBefore = doc.undoManager.undoDepth
        _ = applyBringToFront(
            handles: [entities[0].handle, entities[1].handle],
            document: doc)
        XCTAssertEqual(
            doc.undoManager.undoDepth, depthBefore + 1,
            "reorder of N entities must push exactly one undo entry")
    }

    func testBringToFrontPreservesSelectionVisualOrder() {
        let (doc, entities) = makeDoc(count: 3)
        // Pin a known visual order: entities[0] back ... entities[2] front.
        doc.setDrawOrder(for: entities[0].handle, to: 0)
        doc.setDrawOrder(for: entities[1].handle, to: 1)
        doc.setDrawOrder(for: entities[2].handle, to: 2)
        let depthBefore = doc.undoManager.undoDepth
        _ = applyBringToFront(
            handles: [entities[0].handle, entities[1].handle],
            document: doc)
        let orderOf: (UUID) -> Int = { doc.entity(for: $0)!.drawOrder }
        XCTAssertLessThan(
            orderOf(entities[0].handle), orderOf(entities[1].handle),
            "multi-select bring-to-front must keep the selection's prior relative order")
        XCTAssertEqual(doc.undoManager.undoDepth, depthBefore + 1)
    }
}
