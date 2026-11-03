import XCTest
@testable import ZephyrCore

/// Phase 6 layer-parity regressions: the Layer Properties Manager model
/// (global + selected-viewport columns, filter/state/search scoping,
/// performance-safe row cap, status counts), bulk transactions (single
/// undo, validate-first refusals, sibling propagation), picker
/// validation, and the LAYWALK session.
@MainActor
final class LayerParityPhase6Tests: XCTestCase {

    // MARK: - Fixtures

    private func managerDoc() -> CADDocument {
        let doc = CADDocument()
        let a = Layer(name: "A")
        var b = Layer(name: "B-Bolt")
        b.isFrozen = true
        var c = Layer(name: "C-Nut")
        c.isLocked = true
        c.transparency = 50
        var d = Layer(name: "D-Plate")
        d.isReconciled = false
        d.layerDescription = "Exterior plate"
        doc.importLayersBlocksEntities(
            layers: [a, b, c, d], blocks: [], entities: [])
        doc.activeLayerID = doc.findLayer(named: "A")?.handle
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        try! XCTUnwrap(doc.findLayer(named: name)).handle
    }

    // MARK: - Manager rows: global columns

    func testRowsReturnAllLayersSortedByDefault() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(in: doc)
        XCTAssertEqual(result.total, 4)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(
            result.rows.map(\.layer.name),
            ["A", "B-Bolt", "C-Nut", "D-Plate"])
        XCTAssertTrue(result.rows.allSatisfy { $0.viewportID == nil })
        XCTAssertTrue(result.rows.allSatisfy { !$0.viewportFrozen })
    }

    func testRowsSearchFiltersByName() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(
            in: doc,
            query: LayerManagerQuery(searchText: "bolt"))
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.rows.first?.layer.name, "B-Bolt")
    }

    func testRowsUnknownFilterMatchesNothing() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(
            in: doc,
            query: LayerManagerQuery(filterName: "Missing"))
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testRowsNamedFilterScopes() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        guard case .success = service.saveFilter(
            in: doc,
            filter: LayerFilter(
                name: "Frozen",
                kind: .property(LayerPropertyFilter(wantFrozen: true)))) else {
            return XCTFail("expected filter save")
        }
        let result = LayerManagerModel.rows(
            in: doc,
            query: LayerManagerQuery(filterName: "frozen"))
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.rows.first?.layer.name, "B-Bolt")
    }

    func testRowsStateNameScopesToCapturedLayers() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        // Capture a state holding only A and B-Bolt by removing the rest
        // from a scratch document? States capture the whole table, so
        // scope to a state after deleting two layers in a copy.
        let copy = CADDocument()
        copy.importLayersBlocksEntities(
            layers: [Layer(name: "A"), Layer(name: "B-Bolt")],
            blocks: [], entities: [])
        guard case .success(let state) = service.saveLayerState(
            in: copy, name: "AB") else {
            return XCTFail("expected state save")
        }
        doc.pushUndo()
        doc.layerStates[state.key] = state
        let result = LayerManagerModel.rows(
            in: doc, query: LayerManagerQuery(stateName: "ab"))
        XCTAssertEqual(Set(result.rows.map(\.layer.name)), ["A", "B-Bolt"])
        let missing = LayerManagerModel.rows(
            in: doc, query: LayerManagerQuery(stateName: "Nope"))
        XCTAssertEqual(missing.total, 0)
    }

    func testRowsUnreconciledFlag() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(
            in: doc,
            query: LayerManagerQuery(showOnlyUnreconciled: true))
        XCTAssertEqual(result.rows.map(\.layer.name), ["D-Plate"])
    }

    func testRowsAreCappedForPerformance() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(
            in: doc, query: LayerManagerQuery(rowLimit: 2))
        XCTAssertEqual(result.total, 4)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.rows.count, 2)
    }

    // MARK: - Manager rows: selected-viewport columns

    func testRowsResolveViewportOverrides() {
        let doc = managerDoc()
        let target = handle(doc, "C-Nut")
        doc.setViewportLayerFrozen(
            viewportID: "VP1", layer: target, frozen: true)
        doc.setViewportLayerOverride(
            viewportID: "VP1", layer: handle(doc, "A"),
            override: ViewportLayerOverride(
                color: ColorRGBA(r: 255, g: 0, b: 0, a: 255),
                colorSource: .trueColor, transparency: 20))
        let result = LayerManagerModel.rows(in: doc, viewportID: "VP1")
        XCTAssertEqual(result.total, 4)
        let frozen = result.rows.first(
            where: { $0.layer.name == "C-Nut" })
        XCTAssertEqual(frozen?.viewportFrozen, true)
        XCTAssertEqual(frozen?.viewportID, "VP1")
        let styled = result.rows.first(where: { $0.layer.name == "A" })
        XCTAssertEqual(styled?.effectiveLayer.transparency, 20)
        XCTAssertEqual(
            styled?.effectiveLayer.color, ColorRGBA(r: 255, g: 0, b: 0, a: 255))
        // Global values are untouched by the viewport deltas.
        XCTAssertEqual(doc.findLayer(named: "A")?.transparency, 0)
    }

    func testRowsViewportFrozenFlagNeedsViewport() {
        let doc = managerDoc()
        let result = LayerManagerModel.rows(
            in: doc,
            query: LayerManagerQuery(showOnlyViewportFrozen: true))
        XCTAssertEqual(result.total, 0)
    }

    func testRowsViewportFrozenFlagScopes() {
        let doc = managerDoc()
        doc.setViewportLayerFrozen(
            viewportID: "VP1", layer: handle(doc, "B-Bolt"), frozen: true)
        let result = LayerManagerModel.rows(
            in: doc, viewportID: "VP1",
            query: LayerManagerQuery(showOnlyViewportFrozen: true))
        XCTAssertEqual(result.rows.map(\.layer.name), ["B-Bolt"])
    }

    // MARK: - Status

    func testStatusCountsAndHeaderSummary() {
        let doc = managerDoc()
        let status = LayerManagerModel.status(in: doc)
        XCTAssertEqual(status.total, 4)
        XCTAssertEqual(status.frozen, 1)
        XCTAssertEqual(status.locked, 1)
        XCTAssertEqual(status.unreconciled, 1)
        XCTAssertEqual(status.currentLayerName, "A")
        XCTAssertEqual(status.viewportFrozen, 0)
        let summary = LayerManagerModel.headerSummary(in: doc)
        XCTAssertTrue(summary.contains("4 layers"), summary)
        XCTAssertTrue(summary.contains("1 frozen"), summary)
        XCTAssertTrue(summary.contains("1 unreconciled"), summary)
    }

    func testStatusBarSuffixIsQuietWhenNothingToFlag() {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: [Layer(name: "A")], blocks: [], entities: [])
        XCTAssertEqual(LayerManagerModel.statusBarSuffix(in: doc), "")
        let flagged = managerDoc()
        let suffix = LayerManagerModel.statusBarSuffix(in: flagged)
        XCTAssertTrue(suffix.contains("1 unreconciled"), suffix)
    }

    func testStatusBarSuffixCountsViewportFreeze() {
        let doc = managerDoc()
        doc.setViewportLayerFrozen(
            viewportID: "VP7", layer: handle(doc, "A"), frozen: true)
        let suffix = LayerManagerModel.statusBarSuffix(in: doc, viewportID: "VP7")
        XCTAssertTrue(suffix.contains("1 VP frozen"), suffix)
    }

    // MARK: - Picker validation

    func testPickerValidation() {
        XCTAssertNil(LayerManagerModel.validateACI(7))
        XCTAssertNotNil(LayerManagerModel.validateACI(0))
        XCTAssertNotNil(LayerManagerModel.validateACI(256))
        XCTAssertNil(LayerManagerModel.validateTransparency(0))
        XCTAssertNil(LayerManagerModel.validateTransparency(90))
        XCTAssertNotNil(LayerManagerModel.validateTransparency(91))
        XCTAssertNil(LayerManagerModel.validatePlotStyleName("Normal"))
        XCTAssertNotNil(LayerManagerModel.validatePlotStyleName("  "))
        XCTAssertNil(LayerManagerModel.validateDescription("ok"))
        XCTAssertNotNil(LayerManagerModel.validateDescription(
            String(repeating: "x", count: 256)))
        XCTAssertNil(LayerManagerModel.validateLineWeight(0.25))
        XCTAssertNotNil(LayerManagerModel.validateLineWeight(-1))
    }

    func testAvailableLinetypesAndPlotStyles() {
        let doc = managerDoc()
        let linetypes = LayerManagerModel.availableLinetypes(in: doc)
        XCTAssertTrue(linetypes.contains("CONTINUOUS"))
        XCTAssertTrue(linetypes.contains("BYLAYER"))
        let styles = LayerManagerModel.availablePlotStyles(in: doc)
        XCTAssertTrue(styles.contains("Normal"))
    }

    // MARK: - Walk session

    func testWalkSessionOrderAndMovement() {
        let doc = managerDoc()
        let layers = LayerManagerModel.rows(in: doc).rows.map(\.layer)
        var walk = LayerWalkSession(layers: layers)
        XCTAssertEqual(walk.count, 4)
        XCTAssertEqual(walk.currentName, "A")
        XCTAssertEqual(walk.positionLabel, "1 of 4 — A")
        XCTAssertTrue(walk.next())
        XCTAssertEqual(walk.currentName, "B-Bolt")
        XCTAssertTrue(walk.moveTo(handle: handle(doc, "D-Plate")))
        XCTAssertEqual(walk.positionLabel, "4 of 4 — D-Plate")
        XCTAssertFalse(walk.next(), "walk stops at the last layer")
        XCTAssertTrue(walk.previous())
        XCTAssertEqual(walk.currentName, "C-Nut")
        XCTAssertFalse(walk.moveTo(handle: UUID()))
    }

    // MARK: - Bulk transactions

    func testBulkSetAppliesInOneUndo() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let historyDepth = service.layerHistoryDepth(in: doc)
        let targets = [handle(doc, "B-Bolt"), handle(doc, "C-Nut")]
        guard case .success(let count) = service.setLockedBulk(
            in: doc, handles: targets, locked: true) else {
            return XCTFail("expected bulk lock success")
        }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(doc.findLayer(named: "B-Bolt")!.isLocked)
        XCTAssertTrue(doc.findLayer(named: "C-Nut")!.isLocked)
        XCTAssertEqual(
            doc.undoManager.undoDepth, depth + 1, "bulk is one undo step")
        XCTAssertGreaterThan(
            service.layerHistoryDepth(in: doc), historyDepth)
        doc.undo()
        XCTAssertFalse(doc.findLayer(named: "B-Bolt")!.isLocked)
    }

    func testBulkOffRefusesCurrentLayerWithNoStateChange() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        guard case .failure(let error) = service.setVisibleBulk(
            in: doc,
            handles: [handle(doc, "A"), handle(doc, "C-Nut")],
            visible: false) else {
            return XCTFail("turning off the current layer must fail")
        }
        XCTAssertEqual(
            error,
            .activeLayerGuard("Layer 'A' is current and cannot be turned off."))
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        XCTAssertTrue(doc.findLayer(named: "C-Nut")!.isVisible)
    }

    func testBulkFreezeRefusesCurrentLayer() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        guard case .failure(let error) = service.setFrozenBulk(
            in: doc, handles: [handle(doc, "A")], frozen: true) else {
            return XCTFail("freezing the current layer must fail")
        }
        XCTAssertEqual(
            error,
            .activeLayerGuard("Layer 'A' is current and cannot be frozen."))
        XCTAssertFalse(doc.findLayer(named: "A")!.isFrozen)
    }

    func testBulkUnknownHandleFailsUntouched() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        guard case .failure(let error) = service.setLockedBulk(
            in: doc,
            handles: [handle(doc, "C-Nut"), UUID()], locked: true) else {
            return XCTFail("unknown handle must fail")
        }
        if case .unknownLayer = error { } else {
            return XCTFail("expected unknownLayer, got \(error)")
        }
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        XCTAssertTrue(doc.findLayer(named: "C-Nut")!.isLocked)
    }

    func testBulkPropertyValidation() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let targets = [handle(doc, "A")]
        guard case .failure(let transparency) = service.setTransparencyBulk(
            in: doc, handles: targets, transparency: 95) else {
            return XCTFail("transparency 95 must fail")
        }
        XCTAssertEqual(
            transparency,
            .invalidValue("Transparency 95 is out of range 0...90."))
        guard case .failure(let aci) = service.setColorBulk(
            in: doc, handles: targets,
            color: ColorRGBA(r: 1, g: 2, b: 3, a: 255),
            source: .aci(999)) else {
            return XCTFail("ACI 999 must fail")
        }
        XCTAssertEqual(
            aci, .invalidValue("ACI index 999 is out of range 1...255."))
        guard case .failure(let style) = service.setPlotStyleBulk(
            in: doc, handles: targets, plotStyleName: "  ") else {
            return XCTFail("blank plot style must fail")
        }
        XCTAssertEqual(
            style, .invalidValue("Plot-style name must not be blank."))
        guard case .failure(let weight) = service.setLineWeightBulk(
            in: doc, handles: targets, lineWeight: -2) else {
            return XCTFail("negative lineweight must fail")
        }
        XCTAssertEqual(
            weight,
            .invalidValue("Lineweight must be a finite value >= 0."))
        guard case .failure(let ltype) = service.setLineTypeBulk(
            in: doc, handles: targets, lineType: "  ") else {
            return XCTFail("blank linetype must fail")
        }
        XCTAssertEqual(
            ltype, .invalidValue("Linetype name must not be blank."))
        guard case .failure(let desc) = service.setDescriptionBulk(
            in: doc, handles: targets,
            description: String(repeating: "x", count: 300)) else {
            return XCTFail("overlong description must fail")
        }
        if case .invalidValue = desc { } else {
            return XCTFail("expected invalidValue, got \(desc)")
        }
    }

    func testBulkColorLinetypeWeightTransparencyPlotDescription() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let targets = [handle(doc, "A"), handle(doc, "D-Plate")]
        guard case .success = service.setColorBulk(
            in: doc, handles: targets,
            color: ColorRGBA(r: 10, g: 20, b: 30, a: 255),
            source: .aci(30)) else {
            return XCTFail("expected bulk color success")
        }
        guard case .success = service.setLineTypeBulk(
            in: doc, handles: targets, lineType: "dashed") else {
            return XCTFail("expected bulk linetype success")
        }
        guard case .success = service.setLineWeightBulk(
            in: doc, handles: targets, lineWeight: 0.51) else {
            return XCTFail("expected bulk lineweight success")
        }
        guard case .success = service.setTransparencyBulk(
            in: doc, handles: targets, transparency: 20) else {
            return XCTFail("expected bulk transparency success")
        }
        guard case .success = service.setPlotStyleBulk(
            in: doc, handles: targets, plotStyleName: "Bold") else {
            return XCTFail("expected bulk plot-style success")
        }
        guard case .success = service.setDescriptionBulk(
            in: doc, handles: targets, description: "Bulk") else {
            return XCTFail("expected bulk description success")
        }
        for name in ["A", "D-Plate"] {
            let layer = doc.findLayer(named: name)!
            XCTAssertEqual(layer.colorSource, .aci(30))
            XCTAssertEqual(layer.lineType, "DASHED")
            XCTAssertEqual(layer.lineWeight, 0.50, accuracy: 1e-9)
            XCTAssertEqual(layer.transparency, 20)
            XCTAssertEqual(layer.plotStyleName, "Bold")
            XCTAssertEqual(layer.layerDescription, "Bulk")
        }
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 6)
        doc.undo()
        XCTAssertEqual(doc.findLayer(named: "A")!.layerDescription, "")
    }

    func testBulkPropagatesToSiblingsRenderOnly() {
        let primary = managerDoc()
        let sibling = CADDocument()
        sibling.importLayersBlocksEntities(
            layers: primary.allLayers, blocks: [], entities: [])
        let service = LayerTransactionService()
        let siblingDepth = sibling.undoManager.undoDepth
        guard case .success = service.setPlottableBulk(
            in: primary, siblings: [sibling],
            handles: [handle(primary, "C-Nut")], plottable: false) else {
            return XCTFail("expected bulk plot success")
        }
        XCTAssertFalse(primary.findLayer(named: "C-Nut")!.isPlottable)
        XCTAssertFalse(sibling.findLayer(named: "C-Nut")!.isPlottable)
        XCTAssertEqual(
            sibling.undoManager.undoDepth, siblingDepth,
            "sibling propagation pushes no undo")
    }

    func testBulkViewportFreeze() {
        let doc = managerDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let targets = [handle(doc, "A"), handle(doc, "C-Nut")]
        guard case .success(let count) = service.setViewportFrozenBulk(
            in: doc, viewportID: "VP1", handles: targets, frozen: true) else {
            return XCTFail("expected viewport bulk freeze success")
        }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(doc.isLayerFrozenInViewport(
            viewportID: "VP1", layer: handle(doc, "A")))
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        guard case .failure(let blank) = service.setViewportFrozenBulk(
            in: doc, viewportID: "  ", handles: targets, frozen: true) else {
            return XCTFail("blank viewport id must fail")
        }
        XCTAssertEqual(
            blank, .invalidValue("Viewport id must not be blank."))
        guard case .failure(let unknown) = service.setViewportFrozenBulk(
            in: doc, viewportID: "VP1", handles: [UUID()], frozen: true) else {
            return XCTFail("unknown handle must fail")
        }
        if case .unknownLayer = unknown { } else {
            return XCTFail("expected unknownLayer, got \(unknown)")
        }
        // Manager rows surface the bulk freeze in the VP column.
        let rows = LayerManagerModel.rows(in: doc, viewportID: "VP1")
        XCTAssertEqual(
            rows.rows.filter(\.viewportFrozen).count, 2)
    }

    func testManagerColumnsCoverGlobalAndViewport() {
        let viewport = LayerManagerColumn.allCases.filter(\.isViewport)
        XCTAssertEqual(
            viewport.map(\.rawValue).sorted(),
            ["vpColor", "vpFreeze", "vpLinetype", "vpLineweight",
             "vpPlotStyle", "vpTransparency"])
        XCTAssertTrue(LayerManagerColumn.allCases.map(\.headerTitle).allSatisfy {
            !$0.isEmpty
        })
    }
}
