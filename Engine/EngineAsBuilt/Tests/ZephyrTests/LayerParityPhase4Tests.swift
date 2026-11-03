import XCTest
@testable import ZephyrCore

/// Phase 4 layer-parity regressions: persistent named layer states with
/// LAS import/export, property/group filters with invert, the LAYERP
/// settings history, and reconciled-layer baseline tracking with
/// notifications. Also covers moving isolation into
/// `LayerTransactionService` and EAB persistence of states + filters.
@MainActor
final class LayerParityPhase4Tests: XCTestCase {

    private let service = LayerTransactionService()

    private func docWithLayers(_ names: String...) -> CADDocument {
        let doc = CADDocument()
        for name in names { doc.addLayer(Layer(name: name)) }
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        try! XCTUnwrap(doc.findLayer(named: name)).handle
    }

    private func visible(_ doc: CADDocument, _ name: String) -> Bool {
        try! XCTUnwrap(doc.findLayer(named: name)).isVisible
    }

    // MARK: - States: save / restore

    func testStateSaveRestoreRoundTrip() throws {
        let doc = docWithLayers("A", "B")
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        doc.setLayerLocked(handle(doc, "B"), locked: true)
        doc.setLayerTransparency(handle(doc, "A"), transparency: 40)
        let saved = try service.saveLayerState(in: doc, name: "Baseline").get()
        XCTAssertEqual(saved.entries.count, 2)

        doc.setLayerFrozen(handle(doc, "A"), frozen: false)
        doc.setLayerLocked(handle(doc, "B"), locked: false)
        doc.setLayerVisible(handle(doc, "B"), visible: false)

        let report = try service.restoreLayerState(in: doc, named: "baseline").get()
        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.missing, 0)
        XCTAssertTrue(doc.findLayer(named: "A")!.isFrozen)
        XCTAssertTrue(doc.findLayer(named: "B")!.isLocked)
        XCTAssertTrue(visible(doc, "B"))
        XCTAssertEqual(doc.findLayer(named: "A")!.transparency, 40)
    }

    func testStateRestoreHonorsMask() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(
            in: doc, name: "S", mask: [.onOff]).get()
        doc.setLayerVisible(handle(doc, "A"), visible: false)
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        let report = try service.restoreLayerState(in: doc, named: "S").get()
        XCTAssertEqual(report.applied, 1)
        XCTAssertTrue(visible(doc, "A"), "masked on/off restores")
        XCTAssertTrue(
            doc.findLayer(named: "A")!.isFrozen,
            "unmasked frozen stays as edited")
    }

    func testStateRestoreTurnOffMissing() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(
            in: doc, name: "S", turnOffLayersNotInState: true).get()
        // "Extra" postdates the state: the restore turns it off.
        doc.addLayer(Layer(name: "Extra"))
        let report = try service.restoreLayerState(in: doc, named: "S").get()
        XCTAssertEqual(report.turnedOff, 1)
        XCTAssertFalse(visible(doc, "Extra"))
        XCTAssertTrue(visible(doc, "A"))
    }

    func testStateRestoreCountsMissingEntries() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(in: doc, name: "S").get()
        doc.removeLayer(handle: handle(doc, "A"))
        let report = try service.restoreLayerState(in: doc, named: "S").get()
        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.missing, 1)
    }

    func testStateValidationErrorsChangeNothing() throws {
        let doc = docWithLayers("A")
        XCTAssertEqual(
            service.restoreLayerState(in: doc, named: "Nope"),
            .failure(.unknownState("Nope")))
        XCTAssertEqual(
            service.saveLayerState(in: doc, name: "   "),
            .failure(.blankName))
        _ = try service.saveLayerState(in: doc, name: "S").get()
        XCTAssertEqual(
            service.saveLayerState(in: doc, name: "s"),
            .failure(.duplicateName("s")))
        if case .failure(let error) =
            service.deleteLayerState(in: doc, named: "Missing") {
            XCTAssertEqual(error, .unknownState("Missing"))
        } else {
            XCTFail("expected unknown-state failure")
        }
        XCTAssertEqual(
            service.renameLayerState(in: doc, from: "S", to: "  "),
            .failure(.blankName))
        // Failed validations push no undo and store no state.
        XCTAssertEqual(doc.layerStates.count, 1)
    }

    func testStateRenameAndDelete() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(in: doc, name: "Old").get()
        let renamed = try service.renameLayerState(
            in: doc, from: "OLD", to: "New").get()
        XCTAssertEqual(renamed.name, "New")
        XCTAssertEqual(service.layerStateNames(in: doc), ["New"])
        _ = try service.deleteLayerState(in: doc, named: "new").get()
        XCTAssertTrue(doc.layerStates.isEmpty)
    }

    func testStateRestoreIsSingleUndo() throws {
        let doc = docWithLayers("A", "B")
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        _ = try service.saveLayerState(in: doc, name: "S").get()
        doc.setLayerFrozen(handle(doc, "A"), frozen: false)
        doc.setLayerVisible(handle(doc, "B"), visible: false)
        _ = try service.restoreLayerState(in: doc, named: "S").get()
        XCTAssertTrue(doc.findLayer(named: "A")!.isFrozen)
        doc.undo()
        XCTAssertFalse(doc.findLayer(named: "A")!.isFrozen)
        XCTAssertFalse(visible(doc, "B"), "one undo reverts the whole restore")
    }

    // MARK: - LAS import/export

    func testLASExportImportRoundTrip() throws {
        let doc = docWithLayers("Walls", "Doors")
        var doors = doc.findLayer(named: "Doors")!
        doors.isVisible = false
        doors.isLocked = true
        doors.transparency = 25
        doors.lineType = "DASHED"
        doors.lineWeight = 0.5
        doors.plotStyleName = "Bold"
        doors.layerDescription = "door leaves"
        doors.colorSource = .colorBook(name: "PANTONE 185 C")
        doc.storeLayer(doors)
        _ = try service.saveLayerState(
            in: doc, name: "Plan", stateDescription: "issue set").get()

        let text = try service.exportLayerState(in: doc, named: "plan").get()
        XCTAssertTrue(text.contains("ZEPHYR_LAYERSTATE_V1"))

        let fresh = docWithLayers("Walls", "Doors")
        let imported = try service.importLayerState(in: fresh, from: text).get()
        XCTAssertEqual(imported.name, "Plan")
        let report = try service.restoreLayerState(
            in: fresh, named: "Plan").get()
        XCTAssertEqual(report.applied, 2)
        let back = fresh.findLayer(named: "Doors")!
        XCTAssertFalse(back.isVisible)
        XCTAssertTrue(back.isLocked)
        XCTAssertEqual(back.transparency, 25)
        XCTAssertEqual(back.lineType, "DASHED")
        XCTAssertEqual(back.lineWeight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(back.plotStyleName, "Bold")
        XCTAssertEqual(back.layerDescription, "door leaves")
        XCTAssertEqual(back.colorSource, .colorBook(name: "PANTONE 185 C"))
    }

    func testLASImportRejectsGarbageToleratesUnknownCodes() throws {
        let doc = docWithLayers("A")
        XCTAssertThrowsError(
            try LayerStateFileCodec.import(from: "not a las file\n"))
        XCTAssertThrowsError(
            try LayerStateFileCodec.import(
                from: "0\nZEPHYR_LAYERSTATE_V1\n0\nEND\n"))
        var lines = LayerStateFileCodec.export(
            LayerState(name: "S", entries: [
                "A": LayerStateEntry(layer: Layer(name: "A")),
            ])).components(separatedBy: "\n")
        // Insert an unknown header code and an unknown per-layer code.
        lines.insert("Variant", at: 6)
        lines.insert("999", at: 6)
        let tolerant = try LayerStateFileCodec.import(
            from: lines.joined(separator: "\n"))
        XCTAssertEqual(tolerant.name, "S")
        XCTAssertEqual(tolerant.entries.count, 1)
        _ = try service.importLayerState(
            in: doc, from: lines.joined(separator: "\n")).get()
        // Name clash without overwrite fails; overwrite succeeds.
        let again = LayerStateFileCodec.export(
            LayerState(name: "S", entries: [:]))
        XCTAssertEqual(
            service.importLayerState(in: doc, from: again),
            .failure(.duplicateName("S")))
        XCTAssertNoThrow(
            try service.importLayerState(
                in: doc, from: again, overwrite: true).get())
    }

    func testLASTrueColorRoundTrip() throws {
        var layer = Layer(name: "RGB")
        layer.color = ColorRGBA(r: 10, g: 20, b: 30)
        layer.colorSource = .trueColor
        let state = LayerState(
            name: "C", entries: ["RGB": LayerStateEntry(layer: layer)])
        let back = try LayerStateFileCodec.import(
            from: LayerStateFileCodec.export(state))
        XCTAssertEqual(back.entries["RGB"]?.colorSource, .trueColor)
        XCTAssertEqual(back.entries["RGB"]?.color.r, 10)
        XCTAssertEqual(back.entries["RGB"]?.color.g, 20)
        XCTAssertEqual(back.entries["RGB"]?.color.b, 30)
    }

    // MARK: - Filters

    func testPropertyFilterMatchesAndInverts() throws {
        let doc = docWithLayers("WALL-FULL", "wall-part", "Doors")
        doc.setLayerFrozen(handle(doc, "WALL-FULL"), frozen: true)
        let filter = LayerFilter(
            name: "Walls",
            kind: .property(LayerPropertyFilter(
                namePattern: "WALL-*", wantFrozen: false)))
        XCTAssertTrue(filter.matches(doc.findLayer(named: "wall-part")!))
        XCTAssertFalse(filter.matches(doc.findLayer(named: "WALL-FULL")!))
        XCTAssertFalse(filter.matches(doc.findLayer(named: "Doors")!))
        var inverted = filter
        inverted.inverted = true
        XCTAssertFalse(inverted.matches(doc.findLayer(named: "wall-part")!))
        XCTAssertTrue(inverted.matches(doc.findLayer(named: "Doors")!))
        XCTAssertTrue(LayerPropertyFilter.wildcardMatch("A?C", "abc"))
        XCTAssertFalse(LayerPropertyFilter.wildcardMatch("A?C", "ac"))
    }

    func testPropertyFilterCriteriaCoverage() {
        let layer = Layer(
            name: "A-Note", isVisible: false, isFrozen: true, isLocked: true,
            layerDescription: "demolition sleeve", transparency: 30,
            lineWeight: 0.5, color: .white, lineType: "DASHED", isPlottable: false)
        XCTAssertTrue(LayerPropertyFilter(
            wantOn: false, wantFrozen: true, wantLocked: true,
            wantPlottable: false, aciColor: 7, lineType: "dashed",
            minLineWeight: 0.4, maxLineWeight: 0.6, transparency: 30,
            descriptionContains: "SLEEVE").matches(layer))
        XCTAssertFalse(LayerPropertyFilter(wantOn: true).matches(layer))
        XCTAssertFalse(LayerPropertyFilter(aciColor: 1).matches(layer))
        XCTAssertFalse(
            LayerPropertyFilter(minLineWeight: 0.6).matches(layer))
        XCTAssertFalse(
            LayerPropertyFilter(descriptionContains: "new").matches(layer))
    }

    func testGroupFilterMembershipAndInvert() throws {
        let doc = docWithLayers("A", "B", "C")
        _ = try service.saveFilter(
            in: doc,
            filter: LayerFilter(name: "AB", kind: .group(members: ["a"]))).get()
        XCTAssertEqual(
            try service.addLayersToGroupFilter(
                in: doc, filter: "ab", layers: ["B", "b"]).get(), 2)
        XCTAssertEqual(
            try service.layers(in: doc, matching: "AB").get().map(\.name).sorted(),
            ["A", "B"])
        XCTAssertEqual(
            try service.removeLayersFromGroupFilter(
                in: doc, filter: "AB", layers: ["a"]).get(), 1)
        XCTAssertEqual(
            doc.layers(matching: doc.layerFilters["AB"]!).map(\.name), ["B"])
        var inverted = doc.layerFilters["AB"]!
        inverted.inverted = true
        XCTAssertEqual(
            Set(doc.layers(matching: inverted).map(\.name)), ["A", "C"])
        XCTAssertEqual(
            service.addLayersToGroupFilter(
                in: doc, filter: "Missing", layers: ["A"]),
            .failure(.unknownState("Missing")))
    }

    func testFilterValidationAndAllKind() throws {
        let doc = docWithLayers("A")
        XCTAssertEqual(
            service.saveFilter(
                in: doc, filter: LayerFilter(name: "  ")),
            .failure(.blankName))
        _ = try service.saveFilter(in: doc, filter: LayerFilter(name: "All")).get()
        XCTAssertEqual(
            service.saveFilter(in: doc, filter: LayerFilter(name: "ALL")),
            .failure(.duplicateName("ALL")))
        XCTAssertEqual(service.filterNames(in: doc), ["All"])
        XCTAssertEqual(
            try service.layers(in: doc, matching: "all").get().count, 1)
        let updated = try service.updateFilter(
            in: doc, named: "ALL",
            kind: .property(LayerPropertyFilter(wantOn: true)),
            inverted: true).get()
        XCTAssertTrue(updated.inverted)
        XCTAssertTrue(doc.layers(matching: updated).isEmpty)
        _ = try service.deleteFilter(in: doc, named: "all").get()
        XCTAssertTrue(doc.layerFilters.isEmpty)
    }

    // MARK: - LAYERP history

    func testLayerPreviousRestoresSettings() throws {
        let doc = docWithLayers("A", "B")
        // Fresh layer adds already checkpointed; clear to test the empty
        // stack, then exercise LIFO restores.
        doc.layerPreviousHistory.clear()
        XCTAssertFalse(service.restoreLayerPrevious(in: doc))
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        doc.setLayerVisible(handle(doc, "B"), visible: false)
        // LIFO: the last checkpoint precedes hiding B, so restoring
        // brings B back but keeps A's freeze.
        XCTAssertTrue(service.restoreLayerPrevious(in: doc))
        XCTAssertTrue(doc.findLayer(named: "A")!.isFrozen)
        XCTAssertTrue(visible(doc, "B"))
        // The older checkpoint precedes freezing A.
        XCTAssertTrue(service.restoreLayerPrevious(in: doc))
        XCTAssertFalse(doc.findLayer(named: "A")!.isFrozen)
    }

    func testLayerPreviousDepthIsBounded() {
        var history = LayerPreviousHistory()
        for _ in 0..<40 { history.push([:]) }
        XCTAssertEqual(history.depth, LayerPreviousHistory.maxDepth)
    }

    func testLayerPreviousCoversStateRestoreAndUndoLeavesHistory() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(in: doc, name: "S").get()
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        _ = try service.restoreLayerState(in: doc, named: "S").get()
        XCTAssertFalse(doc.findLayer(named: "A")!.isFrozen)
        doc.undo()
        XCTAssertTrue(doc.findLayer(named: "A")!.isFrozen)
        // The state restore checkpointed first, so LAYERP steps back to
        // the pre-restore (frozen) settings; undo never consumes history.
        XCTAssertTrue(service.restoreLayerPrevious(in: doc))
        XCTAssertTrue(doc.findLayer(named: "A")!.isFrozen)
        XCTAssertFalse(doc.layerPreviousHistory.isEmpty)
    }

    // MARK: - Isolation via the core service

    func testIsolationMovedToServiceWithSiblings() throws {
        let primary = docWithLayers("Keep", "Drop")
        // Sibling views share layer handles (snapshot/restore), which is
        // what the handle-based render-only propagation keys on.
        let sibling = CADDocument()
        sibling.restore(from: primary.snapshot())
        service.isolateLayers(
            in: primary, siblings: [sibling],
            keeping: [handle(primary, "Keep")])
        XCTAssertTrue(visible(primary, "Keep"))
        XCTAssertFalse(visible(primary, "Drop"))
        XCTAssertFalse(visible(sibling, "Drop"), "render-only propagation")
        XCTAssertTrue(service.unisolateLayers(
            in: primary, siblings: [sibling]))
        XCTAssertTrue(visible(primary, "Drop"))
        XCTAssertTrue(visible(sibling, "Drop"))
        XCTAssertFalse(service.unisolateLayers(in: primary))
    }

    // MARK: - Reconciled baseline + notifications

    func testReconcileBaselineNotifiesOnce() {
        let doc = docWithLayers("A")
        var notifications: [[String]] = []
        doc.reconcileNotificationHandler = { layers in
            notifications.append(layers.map(\.name).sorted())
        }
        var fresh = Layer(name: "XREF|Walls")
        fresh.isReconciled = false
        doc.addLayer(fresh)
        XCTAssertEqual(notifications, [["XREF|Walls"]])
        // Second update reports nothing new.
        XCTAssertTrue(doc.updateReconcileBaseline().isEmpty)
        XCTAssertEqual(notifications.count, 1)
        // Reconciled layers never notify.
        doc.addLayer(Layer(name: "Plain"))
        XCTAssertEqual(notifications.count, 1)
    }

    func testReconcileAllMarksAndCounts() {
        let doc = docWithLayers("A")
        var x = Layer(name: "X1")
        x.isReconciled = false
        var y = Layer(name: "X2")
        y.isReconciled = false
        // Silence notifications for direct setup; the service refreshes
        // the baseline itself.
        doc.reconciledBaseline = Set(doc.allLayers.map(\.handle))
        doc.addLayer(x)
        doc.addLayer(y)
        doc.reconciledBaseline = Set(
            doc.allLayers.map(\.handle).filter {
                doc.layer(for: $0)?.isReconciled == true
            })
        XCTAssertEqual(service.reconcileAllLayers(in: doc), 2)
        XCTAssertTrue(doc.allLayers.allSatisfy(\.isReconciled))
        XCTAssertTrue(doc.updateReconcileBaseline().isEmpty)
    }

    // MARK: - Persistence and propagation

    func testEABRoundTripPreservesStatesAndFilters() throws {
        let doc = docWithLayers("A", "B")
        doc.setLayerFrozen(handle(doc, "A"), frozen: true)
        _ = try service.saveLayerState(in: doc, name: "Milestone").get()
        _ = try service.saveFilter(
            in: doc,
            filter: LayerFilter(
                name: "Frozen",
                kind: .property(LayerPropertyFilter(wantFrozen: true)))).get()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4_\(UUID().uuidString).eab")
        try EABWriter.write(document: doc, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let views = try EABReader.readViews(from: tempURL)
        let back = try XCTUnwrap(views.first).document
        XCTAssertEqual(back.layerStates.count, 1)
        XCTAssertEqual(back.layerStates["MILESTONE"]?.entries.count, 2)
        XCTAssertTrue(
            back.layerStates["MILESTONE"]?.entries["A"]?.isFrozen == true)
        XCTAssertEqual(back.layerFilters.count, 1)
        XCTAssertEqual(
            back.layers(
                matching: back.layerFilters["FROZEN"]!).map(\.name), ["A"])
    }

    func testAdoptLayersPropagatesStatesAndFilters() throws {
        let primary = docWithLayers("A")
        let sibling = docWithLayers("A")
        _ = try service.saveLayerState(in: primary, name: "S").get()
        _ = try service.saveFilter(
            in: primary, filter: LayerFilter(name: "G")).get()
        XCTAssertTrue(sibling.adoptLayers(from: primary))
        XCTAssertEqual(sibling.layerStates.count, 1)
        XCTAssertEqual(sibling.layerFilters.count, 1)
        XCTAssertFalse(sibling.adoptLayers(from: primary))
    }

    func testSnapshotRoundTripCarriesStatesAndFilters() throws {
        let doc = docWithLayers("A")
        _ = try service.saveLayerState(in: doc, name: "S").get()
        _ = try service.saveFilter(
            in: doc, filter: LayerFilter(name: "G")).get()
        let snapshot = doc.snapshot()
        let other = docWithLayers("A")
        other.restore(from: snapshot)
        XCTAssertEqual(other.layerStates.count, 1)
        XCTAssertEqual(other.layerFilters.count, 1)
        other.undo()
        XCTAssertTrue(other.layerStates.isEmpty)
    }
}
