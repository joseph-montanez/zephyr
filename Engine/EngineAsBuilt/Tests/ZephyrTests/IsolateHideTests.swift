import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2e ISOLATEOBJECTS/HIDEOBJECTS/UNISOLATEOBJECTS: per-entity
/// isolation as render-only session state — never undoable, never
/// persisted — honored by selection, hit-testing, the renderer bridge,
/// and undo survival.
@MainActor
final class IsolateHideTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func textEntity(at x: Double) -> CADEntity {
        CADEntity(
            layerID: UUID(),
            localGeometry: [.text(
                position: Vector3(x: x, y: 0, z: 0), text: "t", height: 2.5,
                rotation: 0, style: "Standard", alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)],
            transform: .identity)
    }

    /// Three entities on layer "0" (fixes the random layerID up front so
    /// isolation is the only variable under test).
    private func seedThree(_ document: CADDocument) -> [UUID] {
        let zero = zeroID(document)
        return (0..<3).map { i in
            var entity = textEntity(at: Double(i) * 10)
            entity.layerID = zero
            let handle = entity.handle
            document.addEntity(entity)
            return handle
        }
    }

    // MARK: - hide / isolate / unisolate

    func testHideMarksOnlyPicked() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated([handles[0]])
        XCTAssertTrue(document.isIsolatedHidden(handles[0]))
        XCTAssertFalse(document.isIsolatedHidden(handles[1]))
        XCTAssertFalse(document.isIsolatedHidden(handles[2]))
    }

    func testHideUnknownHandlesIgnored() {
        let document = makeDocument()
        _ = seedThree(document)
        document.hideEntitiesIsolated([UUID()])
        XCTAssertEqual(document.unisolateEntities(), 0)
    }

    func testIsolateKeepsOnly() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.isolateEntities(keeping: [handles[1]])
        XCTAssertFalse(document.isIsolatedHidden(handles[1]))
        XCTAssertTrue(document.isIsolatedHidden(handles[0]))
        XCTAssertTrue(document.isIsolatedHidden(handles[2]))
        XCTAssertEqual(document.unisolateEntities(), 2)
    }

    func testUnisolateEmptyReportsZero() {
        XCTAssertEqual(makeDocument().unisolateEntities(), 0)
    }

    func testUnisolatePrunesDeletedEntities() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated(Set(handles))
        document.removeEntity(handle: handles[0])
        XCTAssertEqual(document.unisolateEntities(), 2)
        XCTAssertFalse(document.isIsolatedHidden(handles[1]))
    }

    // MARK: - never undoable

    func testIsolationPushesNoUndo() {
        let document = makeDocument()
        let handles = seedThree(document)
        let depth = document.undoManager.undoDepth
        document.hideEntitiesIsolated([handles[0]])
        document.isolateEntities(keeping: [handles[1]])
        document.unisolateEntities()
        XCTAssertEqual(document.undoManager.undoDepth, depth)
    }

    func testIsolationSurvivesUndo() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated([handles[0]])
        var extra = textEntity(at: 99)
        extra.layerID = zeroID(document)
        let extraHandle = extra.handle
        document.addEntity(extra)
        document.undo()
        XCTAssertNil(document.entity(for: extraHandle))
        XCTAssertTrue(document.isIsolatedHidden(handles[0]))
    }

    // MARK: - selection integration

    func testSelectAllSkipsHidden() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated([handles[0]])
        let selection = CADSelectionManager()
        selection.selectAll(in: document)
        XCTAssertEqual(selection.selectedHandles, Set(handles[1...]))
    }

    func testSelectionPredicateSkipsHidden() {
        let document = makeDocument()
        let handles = seedThree(document)
        let visible = try! XCTUnwrap(document.entity(for: handles[0]))
        XCTAssertTrue(EntityFilter.isVisibleForSelection(visible, in: document))
        document.hideEntitiesIsolated([handles[0]])
        let hidden = try! XCTUnwrap(document.entity(for: handles[0]))
        XCTAssertFalse(EntityFilter.isVisibleForSelection(hidden, in: document))
    }

    // MARK: - render bridge integration

    func testComputeSpecsSkipsHidden() async {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated([handles[0]])
        let specs = await CADRendererBridge.computeSpecs(
            fromSnapshot: document.snapshot(), simplifyComplexBlocks: false)
        let rendered = Set(specs.map(\.handle))
        XCTAssertFalse(rendered.contains(handles[0]))
        XCTAssertTrue(rendered.contains(handles[1]))
        XCTAssertTrue(rendered.contains(handles[2]))
    }

    func testSnapshotCarriesIsolation() {
        let document = makeDocument()
        let handles = seedThree(document)
        document.hideEntitiesIsolated([handles[2]])
        XCTAssertEqual(document.snapshot().isolatedHiddenHandles, [handles[2]])
    }
}
