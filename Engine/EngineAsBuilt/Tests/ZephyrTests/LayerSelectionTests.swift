import XCTest
@testable import ZephyrCore

/// Layer multi-selection model + bulk delete: the AutoCAD-style workflow
/// from the Layer Properties Manager plan (Ctrl/Shift clicks, selection
/// commands, Select Similar, bulk delete with skips, one-undo rule).
@MainActor
final class LayerSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private func selectionDoc() -> CADDocument {
        let doc = CADDocument()
        let a = Layer(name: "A-Frame")
        var b = Layer(name: "B-Walls")
        b.color = ColorRGBA(r: 255, g: 0, b: 0)
        b.colorSource = .trueColor
        var c = Layer(name: "C-Doors")
        c.color = ColorRGBA(r: 255, g: 0, b: 0)
        c.colorSource = .trueColor
        c.lineType = "DASHED"
        var d = Layer(name: "D-Windows")
        d.transparency = 50
        d.isPlottable = false
        doc.importLayersBlocksEntities(
            layers: [a, b, c, d], blocks: [], entities: [])
        doc.activeLayerID = doc.findLayer(named: "A-Frame")?.handle
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        try! XCTUnwrap(doc.findLayer(named: name)).handle
    }

    private func ordered(_ doc: CADDocument) -> [UUID] {
        ["A-Frame", "B-Walls", "C-Doors", "D-Windows"].map {
            handle(doc, $0)
        }
    }

    // MARK: - Click handling

    func testPlainClickSelectsOneAndSetsAnchor() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        model.click(handle: order[1], in: order, ctrl: false, shift: false)
        XCTAssertEqual(model.selected, [order[1]])
        XCTAssertEqual(model.anchor, order[1])
        model.click(handle: order[3], in: order, ctrl: false, shift: false)
        XCTAssertEqual(model.selected, [order[3]])
        XCTAssertEqual(model.anchor, order[3])
    }

    func testCtrlClickTogglesAndMovesAnchor() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        model.click(handle: order[0], in: order, ctrl: false, shift: false)
        model.click(handle: order[2], in: order, ctrl: true, shift: false)
        XCTAssertEqual(model.selected, Set([order[0], order[2]]))
        XCTAssertEqual(model.anchor, order[2])
        model.click(handle: order[0], in: order, ctrl: true, shift: false)
        XCTAssertEqual(model.selected, [order[2]])
        XCTAssertEqual(model.anchor, order[0])
    }

    func testShiftClickSelectsRangeFromAnchor() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        model.click(handle: order[0], in: order, ctrl: false, shift: false)
        model.click(handle: order[2], in: order, ctrl: false, shift: true)
        XCTAssertEqual(model.selected, Set(order[0...2]))
        // Anchor is preserved so repeated Shift+clicks extend the range.
        XCTAssertEqual(model.anchor, order[0])
        model.click(handle: order[3], in: order, ctrl: false, shift: true)
        XCTAssertEqual(model.selected, Set(order))
    }

    func testShiftClickReversedRange() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        model.click(handle: order[3], in: order, ctrl: false, shift: false)
        model.click(handle: order[1], in: order, ctrl: false, shift: true)
        XCTAssertEqual(model.selected, Set(order[1...3]))
    }

    func testShiftClickWithoutAnchorFallsBackToPlain() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        model.click(handle: order[2], in: order, ctrl: false, shift: true)
        XCTAssertEqual(model.selected, [order[2]])
        XCTAssertEqual(model.anchor, order[2])
    }

    func testClicksNeverChangeCurrentLayer() {
        let doc = selectionDoc()
        let current = doc.activeLayerID
        var model = LayerSelectionModel()
        let order = ordered(doc)
        model.click(handle: order[1], in: order, ctrl: false, shift: false)
        model.click(handle: order[2], in: order, ctrl: true, shift: false)
        model.click(handle: order[3], in: order, ctrl: false, shift: true)
        XCTAssertEqual(doc.activeLayerID, current)
        XCTAssertNotEqual(model.selected, [current])
    }

    // MARK: - Selection commands

    func testSelectAllPreservesOutOfScopePicks() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        let outsider = UUID()
        model.selected = [outsider]
        model.selectAll(in: Array(order.prefix(2)))
        XCTAssertEqual(
            model.selected, Set([outsider, order[0], order[1]]))
    }

    func testDeselectAllClearsEverything() {
        var model = LayerSelectionModel(
            selected: [UUID(), UUID()], anchor: UUID())
        model.deselectAll()
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertNil(model.anchor)
    }

    func testSelectAllExceptCurrent() {
        let doc = selectionDoc()
        var model = LayerSelectionModel()
        let order = ordered(doc)
        // The topo workflow: frame layer stays current, everything else
        // is picked for the bulk operation.
        model.selectAllExceptCurrent(in: order, current: doc.activeLayerID)
        XCTAssertFalse(model.selected.contains(doc.activeLayerID!))
        XCTAssertEqual(model.selected.count, order.count - 1)
    }

    func testInvertTogglesVisibleOnly() {
        var model = LayerSelectionModel()
        let order = ordered(selectionDoc())
        let outsider = UUID()
        model.selected = Set([order[0], outsider])
        model.invert(in: Array(order.prefix(2)))
        XCTAssertEqual(model.selected, Set([order[1], outsider]))
    }

    func testSelectCurrent() {
        let doc = selectionDoc()
        var model = LayerSelectionModel(selected: Set(ordered(doc)))
        model.selectCurrent(doc.activeLayerID)
        XCTAssertEqual(model.selected, [doc.activeLayerID!])
        XCTAssertEqual(model.anchor, doc.activeLayerID)
        model.selectCurrent(nil)
        XCTAssertTrue(model.selected.isEmpty)
    }

    // MARK: - Select Similar

    func testSelectSimilarByColorUsesExactRGB() {
        let doc = selectionDoc()
        var model = LayerSelectionModel()
        let layers = ordered(doc).compactMap { doc.layer(for: $0) }
        let reference = doc.findLayer(named: "B-Walls")!
        model.selectSimilar(
            to: reference, in: layers, criterion: .color)
        XCTAssertEqual(
            Set(model.selected),
            Set([handle(doc, "B-Walls"), handle(doc, "C-Doors")]))
    }

    func testSelectSimilarByLinetypeIsCaseInsensitive() {
        let doc = selectionDoc()
        var model = LayerSelectionModel()
        let layers = ordered(doc).compactMap { doc.layer(for: $0) }
        let reference = doc.findLayer(named: "C-Doors")!
        model.selectSimilar(
            to: reference, in: layers, criterion: .linetype)
        XCTAssertEqual(model.selected, [handle(doc, "C-Doors")])
    }

    func testSelectSimilarByTransparencyAndPlot() {
        let doc = selectionDoc()
        var model = LayerSelectionModel()
        let layers = ordered(doc).compactMap { doc.layer(for: $0) }
        let reference = doc.findLayer(named: "D-Windows")!
        model.selectSimilar(
            to: reference, in: layers, criterion: .transparency)
        XCTAssertEqual(model.selected, [handle(doc, "D-Windows")])
        model.deselectAll()
        model.selectSimilar(
            to: reference, in: layers, criterion: .plot)
        XCTAssertEqual(model.selected, [handle(doc, "D-Windows")])
    }

    // MARK: - Prune + partition

    func testPruneDropsStaleHandles() {
        let order = ordered(selectionDoc())
        var model = LayerSelectionModel(
            selected: Set([order[0], UUID()]), anchor: UUID())
        model.prune(valid: Set(order))
        XCTAssertEqual(model.selected, [order[0]])
        XCTAssertNil(model.anchor)
    }

    func testPartitionExcludingCurrent() {
        let doc = selectionDoc()
        let order = ordered(doc)
        let (targets, skipped) = LayerSelectionModel
            .partitionExcludingCurrent(order, current: doc.activeLayerID)
        XCTAssertFalse(targets.contains(doc.activeLayerID!))
        XCTAssertTrue(skipped)
        XCTAssertEqual(targets.count, order.count - 1)
        let (all, none) = LayerSelectionModel
            .partitionExcludingCurrent(order, current: nil)
        XCTAssertEqual(all, order)
        XCTAssertFalse(none)
    }

    // MARK: - Bulk delete

    private func deletableDoc() -> CADDocument {
        let doc = CADDocument()
        let keep = Layer(name: "Keep")
        let gone1 = Layer(name: "Gone-1")
        let gone2 = Layer(name: "Gone-2")
        let used = Layer(name: "Used")
        let zero = Layer(name: "0")
        let entity = CADEntity(layerID: used.handle, localGeometry: nil)
        doc.importLayersBlocksEntities(
            layers: [keep, gone1, gone2, used, zero],
            blocks: [], entities: [entity])
        doc.activeLayerID = doc.findLayer(named: "Keep")?.handle
        return doc
    }

    func testBulkDeleteSkipsProtectedCurrentAndInUse() {
        let doc = deletableDoc()
        let service = LayerTransactionService()
        let targets = [
            handle(doc, "Gone-1"), handle(doc, "Gone-2"),
            handle(doc, "Keep"), handle(doc, "Used"), handle(doc, "0"),
        ]
        guard case .success(let outcome) = service.deleteLayersBulk(
            in: doc, handles: targets, eraseEntities: false) else {
            return XCTFail("expected bulk delete success with skips")
        }
        XCTAssertEqual(outcome.deleted, 2)
        XCTAssertEqual(outcome.erasedEntities, 0)
        XCTAssertEqual(outcome.skipped.count, 3)
        XCTAssertNil(doc.findLayer(named: "Gone-1"))
        XCTAssertNil(doc.findLayer(named: "Gone-2"))
        XCTAssertNotNil(doc.findLayer(named: "Keep"))
        XCTAssertNotNil(doc.findLayer(named: "Used"))
        XCTAssertNotNil(doc.findLayer(named: "0"))
    }

    func testBulkDeleteWithEraseRemovesInUseLayerAndEntities() {
        let doc = deletableDoc()
        let service = LayerTransactionService()
        let before = doc.allEntities.count
        XCTAssertGreaterThan(before, 0)
        guard case .success(let outcome) = service.deleteLayersBulk(
            in: doc, handles: [handle(doc, "Used")], eraseEntities: true) else {
            return XCTFail("expected bulk delete success")
        }
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(outcome.erasedEntities, 1)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertNil(doc.findLayer(named: "Used"))
        XCTAssertEqual(doc.allEntities.count, before - 1)
    }

    func testBulkDeleteIsOneUndoStep() {
        let doc = deletableDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let historyDepth = service.layerHistoryDepth(in: doc)
        guard case .success = service.deleteLayersBulk(
            in: doc,
            handles: [handle(doc, "Gone-1"), handle(doc, "Gone-2")],
            eraseEntities: false) else {
            return XCTFail("expected bulk delete success")
        }
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        XCTAssertGreaterThan(
            service.layerHistoryDepth(in: doc), historyDepth)
        doc.undo()
        XCTAssertNotNil(doc.findLayer(named: "Gone-1"))
        XCTAssertNotNil(doc.findLayer(named: "Gone-2"))
    }

    func testBulkDeleteUnknownHandleFailsUntouched() {
        let doc = deletableDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        guard case .failure(let error) = service.deleteLayersBulk(
            in: doc,
            handles: [handle(doc, "Gone-1"), UUID()],
            eraseEntities: false) else {
            return XCTFail("unknown handle must fail")
        }
        if case .unknownLayer = error { } else {
            return XCTFail("expected unknownLayer, got \(error)")
        }
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        XCTAssertNotNil(doc.findLayer(named: "Gone-1"))
    }

    func testBulkDeletePropagatesToSiblingsRenderOnly() {
        let primary = deletableDoc()
        let sibling = CADDocument()
        sibling.importLayersBlocksEntities(
            layers: primary.allLayers, blocks: [], entities: [])
        let service = LayerTransactionService()
        let siblingDepth = sibling.undoManager.undoDepth
        guard case .success = service.deleteLayersBulk(
            in: primary, siblings: [sibling],
            handles: [handle(primary, "Gone-1")],
            eraseEntities: false) else {
            return XCTFail("expected bulk delete success")
        }
        XCTAssertNil(primary.findLayer(named: "Gone-1"))
        XCTAssertNil(sibling.findLayer(named: "Gone-1"))
        XCTAssertEqual(
            sibling.undoManager.undoDepth, siblingDepth,
            "sibling propagation pushes no undo")
    }

    func testAuditBulkDeletePreviewsWithoutMutating() {
        let doc = deletableDoc()
        let service = LayerTransactionService()
        guard case .success(let plan) = service.auditBulkDelete(
            in: doc,
            handles: [handle(doc, "Gone-1"), handle(doc, "Keep")],
            eraseEntities: false) else {
            return XCTFail("expected audit success")
        }
        XCTAssertEqual(plan.deletable, [handle(doc, "Gone-1")])
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertNotNil(doc.findLayer(named: "Gone-1"))
        XCTAssertNotNil(doc.findLayer(named: "Keep"))
    }
}
