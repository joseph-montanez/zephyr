import XCTest
@testable import ZephyrCore

/// Phase 1A-2 tests: the layer quick tools' document model — batched
/// visibility (exactly one undo step), LAYISO hide/fade modes with nested
/// save-stack restore, and the empty-stack LAYUNISO no-op. Pick-driven
/// command behavior (hit-test resolution, current-layer refusal) stays a
/// manual sweep per the plan.
@MainActor
final class LayerCommandTests: XCTestCase {

    private func docWithLayers(_ names: String...) -> CADDocument {
        let doc = CADDocument()
        for name in names {
            doc.addLayer(Layer(name: name))
        }
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        doc.findLayer(named: name)!.handle
    }

    func testSetLayersVisibleIsSingleUndo() {
        let doc = docWithLayers("A", "B", "C")
        let depth = doc.undoManager.undoDepth
        doc.setLayersVisible(
            [handle(doc, "A"), handle(doc, "B"), handle(doc, "C")],
            visible: false)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        XCTAssertFalse(doc.layer(for: handle(doc, "A"))!.isVisible)
        XCTAssertFalse(doc.layer(for: handle(doc, "B"))!.isVisible)
        XCTAssertFalse(doc.layer(for: handle(doc, "C"))!.isVisible)
        doc.undo()
        XCTAssertTrue(doc.layer(for: handle(doc, "A"))!.isVisible)
        XCTAssertTrue(doc.layer(for: handle(doc, "B"))!.isVisible)
        XCTAssertTrue(doc.layer(for: handle(doc, "C"))!.isVisible)
    }

    func testIsolateHidesOthersAndUnisolateRestores() {
        let doc = docWithLayers("Keep", "Hide")
        let keep = handle(doc, "Keep")
        let hide = handle(doc, "Hide")
        let depth = doc.undoManager.undoDepth
        doc.isolateLayers(keeping: [keep])
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        XCTAssertTrue(doc.layer(for: keep)!.isVisible)
        XCTAssertFalse(doc.layer(for: hide)!.isVisible)
        XCTAssertTrue(doc.unisolateLayers())
        XCTAssertTrue(doc.layer(for: hide)!.isVisible)
        XCTAssertTrue(doc.layerIsolationStack.isEmpty)
    }

    func testIsolateFadeModeKeepsVisibilityAtReducedOpacity() {
        let doc = docWithLayers("Keep", "Fade")
        doc.layisoFadeOthers = true
        let keep = handle(doc, "Keep")
        let fade = handle(doc, "Fade")
        doc.isolateLayers(keeping: [keep])
        XCTAssertTrue(doc.layer(for: fade)!.isVisible)
        XCTAssertEqual(doc.layer(for: fade)!.opacity, 0.3, accuracy: 1e-9)
        XCTAssertTrue(doc.unisolateLayers())
        XCTAssertEqual(doc.layer(for: fade)!.opacity, 1.0, accuracy: 1e-9)
    }

    func testUnisolateEmptyStackIsNoOp() {
        let doc = docWithLayers("A")
        let depth = doc.undoManager.undoDepth
        XCTAssertFalse(doc.unisolateLayers())
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
    }

    func testNestedIsolationsRestoreInOrder() {
        let doc = docWithLayers("A", "B", "C")
        let a = handle(doc, "A")
        let b = handle(doc, "B")
        let c = handle(doc, "C")
        doc.isolateLayers(keeping: [a])
        doc.isolateLayers(keeping: [b])
        XCTAssertFalse(doc.layer(for: a)!.isVisible)
        XCTAssertTrue(doc.layer(for: b)!.isVisible)
        XCTAssertTrue(doc.unisolateLayers())
        // Back to the first isolation: A visible, B and C hidden.
        XCTAssertTrue(doc.layer(for: a)!.isVisible)
        XCTAssertFalse(doc.layer(for: b)!.isVisible)
        XCTAssertFalse(doc.layer(for: c)!.isVisible)
        XCTAssertTrue(doc.unisolateLayers())
        XCTAssertTrue(doc.layer(for: b)!.isVisible)
        XCTAssertTrue(doc.layer(for: c)!.isVisible)
    }
}
