import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Phase 5 layer-parity regressions: LAYMRG/LAYDEL/COPYTOLAYER batch ops
/// (single undo, guards, LAYERP checkpoint), layer-history depth, the
/// VPLAYER document data path, new command descriptors/aliases, the
/// LAYLOCKFADECTL/TRANSPARENCYDISPLAY/LWDISPLAY sysvar links, the
/// layer-* Lisp family, VLA layer accessors, enriched LAYER table
/// entries, and scripted `(command "-LAYER"/"LAYERSTATE"/"LAYERP")`.
@MainActor
final class LayerParityPhase5Tests: XCTestCase {

    // MARK: - Fixtures

    private func lineEntity(layer: Layer, y: Double = 0) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: y, z: 0),
                end: Vector3(x: 10, y: y, z: 0),
                color: nil)])
    }

    private func mergeDoc() -> CADDocument {
        let doc = CADDocument()
        let target = Layer(name: "A")
        let b = Layer(name: "B")
        let c = Layer(name: "C")
        doc.importLayersBlocksEntities(layers: [target, b, c], blocks: [], entities: [])
        doc.importLayersBlocksEntities(
            layers: [], blocks: [],
            entities: [lineEntity(layer: b, y: 1), lineEntity(layer: c, y: 2)])
        doc.activeLayerID = target.handle
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        try! XCTUnwrap(doc.findLayer(named: name)).handle
    }

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.addLayer(Layer(name: "Walls"))
        doc.activeLayerID = doc.findLayer(named: "0")?.handle
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        return host
    }

    private func eval(
        _ source: String, host: LispCADHost, env: inout LispEnvironment
    ) async throws -> LispValue {
        let forms = try LispReader().readAll(source)
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    private func check(
        _ source: String, _ expected: LispValue,
        host: LispCADHost, env: inout LispEnvironment,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let got = try await eval(source, host: host, env: &env)
        XCTAssertEqual(got, expected, source, file: file, line: line)
    }

    private func checkThrows(
        _ source: String, host: LispCADHost, env: inout LispEnvironment,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await eval(source, host: host, env: &env)
            XCTFail("expected error: \(source)", file: file, line: line)
        } catch { }
    }

    private func assoc(_ code: Int, _ list: LispValue) -> LispValue? {
        guard let items = list.properList else { return nil }
        for item in items {
            if case let .cons(head, tail) = item,
               case let .int(c) = head, c == code {
                return tail
            }
        }
        return nil
    }

    // MARK: - LAYMRG

    func testMergeMovesEntitiesAndDeletesSourcesInOneUndo() {
        let doc = mergeDoc()
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let historyDepth = service.layerHistoryDepth(in: doc)
        guard case .success(let outcome) = service.mergeLayers(
            in: doc, from: ["B", "C"], into: "A") else {
            return XCTFail("expected merge success")
        }
        XCTAssertEqual(outcome.moved, 2)
        XCTAssertEqual(outcome.deleted, 2)
        XCTAssertNil(doc.findLayer(named: "B"))
        XCTAssertNil(doc.findLayer(named: "C"))
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "merge is one undo step")
        XCTAssertGreaterThan(service.layerHistoryDepth(in: doc), historyDepth)
        for entity in doc.allEntities {
            XCTAssertEqual(entity.layerID, handle(doc, "A"))
        }
        doc.undo()
        XCTAssertNotNil(doc.findLayer(named: "B"))
        XCTAssertNotNil(doc.findLayer(named: "C"))
        let restored = Set(doc.allEntities.map(\.layerID))
        XCTAssertTrue(restored.contains(handle(doc, "B")))
        XCTAssertTrue(restored.contains(handle(doc, "C")))
    }

    func testMergeRefusalsLeaveStateUntouched() {
        let doc = mergeDoc()
        let service = LayerTransactionService()
        doc.addLayer(Layer(name: "0"))
        let depth = doc.undoManager.undoDepth
        guard case .failure(let unknownTarget) = service.mergeLayers(
            in: doc, from: ["B"], into: "Nope") else {
            return XCTFail("unknown target must fail")
        }
        XCTAssertEqual(unknownTarget, .unknownLayer("Nope"))
        guard case .failure(let unknownSource) = service.mergeLayers(
            in: doc, from: ["Nope"], into: "A") else {
            return XCTFail("unknown source must fail")
        }
        XCTAssertEqual(unknownSource, .unknownLayer("Nope"))
        guard case .failure(let itself) = service.mergeLayers(
            in: doc, from: ["B"], into: "B") else {
            return XCTFail("merging into itself must fail")
        }
        XCTAssertEqual(itself, .invalidValue("Cannot merge layer 'B' into itself."))
        guard case .failure(let zero) = service.mergeLayers(
            in: doc, from: ["0"], into: "A") else {
            return XCTFail("merging layer 0 must fail")
        }
        XCTAssertEqual(zero, .protectedLayer("Layer '0' cannot be merged."))
        doc.activeLayerID = handle(doc, "B")
        guard case .failure(let current) = service.mergeLayers(
            in: doc, from: ["B"], into: "A") else {
            return XCTFail("merging the current layer must fail")
        }
        XCTAssertEqual(current, .activeLayerGuard("Layer 'B' is current and cannot be merged."))
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "refusals push no undo")
        XCTAssertNotNil(doc.findLayer(named: "B"))
        XCTAssertNotNil(doc.findLayer(named: "C"))
    }

    // MARK: - LAYDEL

    func testDeleteLayerAndEntitiesInOneUndo() {
        let doc = CADDocument()
        let doomed = Layer(name: "Doomed")
        let keep = Layer(name: "Keep")
        doc.importLayersBlocksEntities(layers: [doomed, keep], blocks: [], entities: [])
        doc.importLayersBlocksEntities(
            layers: [], blocks: [],
            entities: [lineEntity(layer: doomed, y: 1), lineEntity(layer: doomed, y: 2)])
        doc.activeLayerID = handle(doc, "Keep")
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        guard case .success(let count) = service.deleteLayerAndEntities(
            in: doc, named: "Doomed") else {
            return XCTFail("expected delete success")
        }
        XCTAssertEqual(count, 2)
        XCTAssertNil(doc.findLayer(named: "Doomed"))
        XCTAssertTrue(doc.allEntities.isEmpty)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        XCTAssertEqual(doc.oopsRestore(), 2, "erased entities land in OOPS")
        doc.undo()
        doc.undo()
        XCTAssertNotNil(doc.findLayer(named: "Doomed"))
    }

    func testDeleteLayerAndEntitiesRefusals() {
        let doc = mergeDoc()
        let service = LayerTransactionService()
        doc.addLayer(Layer(name: "0"))
        let depth = doc.undoManager.undoDepth
        guard case .failure(let unknown) = service.deleteLayerAndEntities(
            in: doc, named: "Nope") else {
            return XCTFail("unknown layer must fail")
        }
        XCTAssertEqual(unknown, .unknownLayer("Nope"))
        guard case .failure(let zero) = service.deleteLayerAndEntities(
            in: doc, named: "0") else {
            return XCTFail("layer 0 must fail")
        }
        XCTAssertEqual(zero, .protectedLayer("Layer '0' cannot be deleted."))
        doc.activeLayerID = handle(doc, "B")
        guard case .failure(let current) = service.deleteLayerAndEntities(
            in: doc, named: "B") else {
            return XCTFail("current layer must fail")
        }
        XCTAssertEqual(current, .activeLayerGuard("Layer 'B' is current and cannot be deleted."))
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
    }

    // MARK: - COPYTOLAYER

    func testCopyEntitiesToLayer() {
        let doc = mergeDoc()
        let service = LayerTransactionService()
        let source = doc.allEntities.first(where: { $0.layerID == handle(doc, "B") })!
        let depth = doc.undoManager.undoDepth
        guard case .success(let count) = service.copyEntitiesToLayer(
            in: doc, handles: [source.handle], target: "A") else {
            return XCTFail("expected copy success")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        let onA = doc.allEntities.filter { $0.layerID == handle(doc, "A") }
        XCTAssertEqual(onA.count, 1)
        XCTAssertNotEqual(onA[0].handle, source.handle, "copies gain fresh handles")
        XCTAssertNotNil(doc.entity(for: source.handle), "original is kept")
        guard case .failure(let unknown) = service.copyEntitiesToLayer(
            in: doc, handles: [source.handle], target: "Nope") else {
            return XCTFail("unknown target must fail")
        }
        XCTAssertEqual(unknown, .unknownLayer("Nope"))
        doc.undo()
        XCTAssertTrue(doc.allEntities.filter { $0.layerID == handle(doc, "A") }.isEmpty)
    }

    // MARK: - VPLAYER document path

    func testViewportFreezeDocumentPath() {
        let doc = mergeDoc()
        let target = handle(doc, "A")
        let depth = doc.undoManager.undoDepth
        doc.setViewportLayerFrozen(viewportID: "VP1", layer: target, frozen: true)
        XCTAssertTrue(doc.isLayerFrozenInViewport(viewportID: "VP1", layer: target))
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        doc.setViewportLayerFrozen(viewportID: "VP1", layer: target, frozen: false)
        XCTAssertFalse(doc.isLayerFrozenInViewport(viewportID: "VP1", layer: target))
        doc.setViewportLayerFrozen(viewportID: "VP1", layer: target, frozen: true)
        doc.clearViewportOverrides(forViewport: "VP1")
        XCTAssertFalse(doc.isLayerFrozenInViewport(viewportID: "VP1", layer: target))
    }

    // MARK: - VPLAYER manager path

    func testVPlayerManagerReportAndReset() throws {
        let modelDoc = CADDocument()
        let modelLayer = Layer(
            handle: UUID(), name: "Walls", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        modelDoc.importLayersBlocksEntities(layers: [modelLayer], blocks: [], entities: [])
        modelDoc.addEntity(CADEntity(
            layerID: modelLayer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 100, y: 0, z: 0),
                color: nil)],
            transform: .identity))
        let vp = DXFImporter.SheetViewport(
            paperCenterX: 6, paperCenterY: 4.5,
            paperWidth: 12, paperHeight: 9,
            status: 2, id: 2,
            viewCenterX: 0, viewCenterY: 0,
            viewTargetX: 50, viewTargetY: 0,
            viewHeight: 100, twistAngle: 0,
            layerName: "MODEL")
        var cache = DXFImporter.SheetProjectionCache()
        cache.exactViewports = [vp]
        let line = CADEntity(
            layerID: modelLayer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 100, y: 0, z: 0),
                color: nil)],
            transform: .identity)
        let projected = DXFImporter.projectedEntities(
            modelEntities: [line], cache: cache, xrefBlockIDs: [])
        XCTAssertEqual(projected.count, 1)
        let sheetDoc = CADDocument()
        sheetDoc.importLayersBlocksEntities(
            layers: [modelLayer], blocks: [], entities: projected)
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Phase5",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        let viewportID = try XCTUnwrap(manager.activeSheetViewports().first?.id)
        var report = try XCTUnwrap(manager.viewportFrozenLayerReport())
        XCTAssertTrue(report.allSatisfy { $0.frozenLayers.isEmpty })
        XCTAssertTrue(manager.setViewportLayerFrozen(
            viewportID: viewportID, layerNamed: "walls", frozen: true))
        report = try XCTUnwrap(manager.viewportFrozenLayerReport())
        XCTAssertEqual(
            report.first(where: { $0.id == viewportID })?.frozenLayers, ["Walls"])
        XCTAssertTrue(manager.resetViewportLayers(viewportID: viewportID))
        report = try XCTUnwrap(manager.viewportFrozenLayerReport())
        XCTAssertTrue(report.allSatisfy { $0.frozenLayers.isEmpty })
        XCTAssertFalse(manager.resetViewportLayers(viewportID: 9999))
        XCTAssertTrue(manager.switchToView(at: 0))
        XCTAssertNil(manager.viewportFrozenLayerReport(), "model space has no viewports")
    }

    // MARK: - Registration / aliases / completion

    func testNewCommandDescriptorsExist() {
        for name in ["LAYFRZ", "LAYTHW", "LAYLCK", "LAYULK", "LAYDEL",
                    "LAYMRG", "LAYWALK", "COPYTOLAYER", "VPLAYER"] {
            XCTAssertNotNil(
                CommandDescriptor.allCommands.first(where: { $0.canonicalName == name }),
                "\(name) needs a command descriptor")
            XCTAssertNotNil(
                CADCommandAliasTable.entry(canonicalName: name),
                "\(name) needs an alias-table entry")
        }
        let dash = try! XCTUnwrap(CommandDescriptor.allCommands.first(
            where: { $0.canonicalName == "-LAYER" }))
        XCTAssertTrue(dash.syntax.contains("VPFreeze"), "dash syntax lists VPFreeze")
        XCTAssertTrue(dash.syntax.contains("NoPlot"), "dash syntax lists NoPlot")
        XCTAssertTrue(dash.syntax.contains("State"), "dash syntax lists State")
    }

    func testNewAliasesResolveThroughCompletion() {
        let processor = CADCommandProcessor()
        for (input, expected) in [
            ("LAYFREEZE", "LAYFRZ"), ("LAYTHAW", "LAYTHW"),
            ("LAYLOCK", "LAYLCK"), ("LAYUNLOCK", "LAYULK"),
            ("LAYDELETE", "LAYDEL"), ("LAYMERGE", "LAYMRG"),
            ("LAYWALK", "LAYWALK"), ("COPYTOLAYER", "COPYTOLAYER"),
            ("VPLAYER", "VPLAYER"),
        ] {
            let top = processor.matchCommands(input: input)
                .prefix(3)
                .map { $0.descriptor.canonicalName }
            XCTAssertTrue(
                top.contains(expected),
                "'\(input)' should resolve to \(expected); top-3 was \(top)")
        }
    }

    // MARK: - Sysvars

    func testLayerSysvarLinks() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        try await check(#"(getvar "LAYLOCKFADECTL")"#, .int(50), host: host, env: &env)
        try await check(#"(getvar "TRANSPARENCYDISPLAY")"#, .int(1), host: host, env: &env)
        try await check(#"(getvar "LWDISPLAY")"#, .int(1), host: host, env: &env)
        _ = try await eval(#"(setvar "LAYLOCKFADECTL" 70)"#, host: host, env: &env)
        XCTAssertEqual(host.document.lockedLayerFadePercent, 70)
        _ = try await eval(#"(setvar "TRANSPARENCYDISPLAY" 0)"#, host: host, env: &env)
        XCTAssertFalse(host.document.transparencyDisplayEnabled)
        _ = try await eval(#"(setvar "LWDISPLAY" 0)"#, host: host, env: &env)
        XCTAssertFalse(host.document.lineweightDisplayEnabled)
        _ = try? await eval(#"(setvar "LAYLOCKFADECTL" 500)"#, host: host, env: &env)
        XCTAssertEqual(host.document.lockedLayerFadePercent, 70, "out-of-range sticks")
        _ = try? await eval(#"(setvar "TRANSPARENCYDISPLAY" 2)"#, host: host, env: &env)
        XCTAssertFalse(host.document.transparencyDisplayEnabled, "out-of-range sticks")
    }

    // MARK: - Lisp layer family

    func testLispLayerVerbs() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        try await check(#"(layer-make "Fences")"#, .t, host: host, env: &env)
        XCTAssertNotNil(host.document.findLayer(named: "Fences"))
        try await check(#"(layer-make "Fences")"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-freeze "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-frozenp "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-thaw "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-frozenp "Fences")"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-lock "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-lockedp "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-unlock "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-off "Fences")"#, .t, host: host, env: &env)
        try await check(#"(layer-onp "Fences")"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-freeze "Nope")"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-frozenp "Nope")"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-freeze "0")"#, .nilValue, host: host, env: &env)
        let names = try await eval("(layer-names)", host: host, env: &env)
        XCTAssertEqual(names, LispValue(stringList: ["0", "Fences", "Walls"]))
        let depth = try await eval("(layer-history-depth)", host: host, env: &env)
        XCTAssertEqual(depth, .int(host.document.layerPreviousHistory.depth))
        XCTAssertGreaterThan(host.document.layerPreviousHistory.depth, 0)
    }

    func testLispLayerMergeAndDelete() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        try await check(#"(layer-make "Src")"#, .t, host: host, env: &env)
        try await check(#"(layer-merge "Walls" '("Src"))"#, .t, host: host, env: &env)
        XCTAssertNil(host.document.findLayer(named: "Src"))
        try await check(#"(layer-merge "Walls" '("Gone"))"#, .nilValue, host: host, env: &env)
        try await check(#"(layer-delete "Walls")"#, .t, host: host, env: &env)
        XCTAssertNil(host.document.findLayer(named: "Walls"))
        try await check(#"(layer-delete "0")"#, .nilValue, host: host, env: &env)
    }

    // MARK: - VLA + table

    func testVlaLayerAccessors() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let layers = try await eval("(vla-get-layers)", host: host, env: &env)
        XCTAssertEqual(layers, LispValue(stringList: ["0", "Walls"]))
        try await check(#"(vla-put-layer-frozen "Walls" T)"#, .t, host: host, env: &env)
        try await check(#"(vla-get-layer-frozen "Walls")"#, .t, host: host, env: &env)
        try await check(#"(vla-put-layer-frozen "Walls" nil)"#, .t, host: host, env: &env)
        try await check(#"(vla-get-layer-frozen "Walls")"#, .nilValue, host: host, env: &env)
        try await check(#"(vla-put-layer-locked "Walls" T)"#, .t, host: host, env: &env)
        try await check(#"(vla-get-layer-locked "Walls")"#, .t, host: host, env: &env)
        try await check(#"(vla-get-layer-frozen "Nope")"#, .nilValue, host: host, env: &env)
    }

    func testTblsearchLayerCarriesStateFields() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        try await check(#"(layer-freeze "Walls")"#, .t, host: host, env: &env)
        host.document.setLayerTransparency(handle(host.document, "Walls"), transparency: 50)
        host.document.setLayerDescription(handle(host.document, "Walls"), description: "Exterior")
        let found = try await eval(#"(tblsearch "LAYER" "WALLS")"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, found), .string("LAYER"))
        XCTAssertEqual(assoc(2, found), .string("Walls"))
        XCTAssertEqual(assoc(70, found), .int(1), "frozen bit in group 70")
        XCTAssertEqual(assoc(440, found), .int(50), "transparency in group 440")
        XCTAssertEqual(assoc(3, found), .string("Exterior"), "description in group 3")
    }

    // MARK: - Scripted (command ...) surface

    func testScriptedDashLayer() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "-LAYER" "Freeze" "Walls")"#, host: host, env: &env)
        XCTAssertTrue(host.document.findLayer(named: "Walls")!.isFrozen)
        _ = try await eval(#"(command "-LAYER" "Thaw" "Walls")"#, host: host, env: &env)
        XCTAssertFalse(host.document.findLayer(named: "Walls")!.isFrozen)
        _ = try await eval(#"(command "-LAYER" "Make" "Scripted")"#, host: host, env: &env)
        XCTAssertNotNil(host.document.findLayer(named: "Scripted"))
        XCTAssertEqual(host.document.layer(for: host.document.activeLayerID!)?.name, "Scripted")
        _ = try await eval(#"(command "-LAYER" "Color" 3 "Walls")"#, host: host, env: &env)
        XCTAssertEqual(host.document.findLayer(named: "Walls")!.colorSource, .aci(3))
        _ = try await eval(
            #"(command "-LAYER" "Transparency" 45 "Walls")"#, host: host, env: &env)
        XCTAssertEqual(host.document.findLayer(named: "Walls")!.transparency, 45)
        await checkThrows(#"(command "-LAYER" "Freeze" "Nope")"#, host: host, env: &env)
        await checkThrows(#"(command "-LAYER" "Bogus" "Walls")"#, host: host, env: &env)
    }

    func testScriptedLayerStateAndPrevious() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "LAYERSTATE" "Save" "Day")"#, host: host, env: &env)
        XCTAssertTrue(
            LayerTransactionService().layerStateNames(in: host.document).contains("Day"))
        _ = try await eval(#"(command "-LAYER" "Off" "Walls")"#, host: host, env: &env)
        XCTAssertFalse(host.document.findLayer(named: "Walls")!.isVisible)
        _ = try await eval(#"(command "LAYERP")"#, host: host, env: &env)
        XCTAssertTrue(host.document.findLayer(named: "Walls")!.isVisible)
        _ = try await eval(#"(command "LAYERSTATE" "Restore" "Day")"#, host: host, env: &env)
        XCTAssertTrue(host.document.findLayer(named: "Walls")!.isVisible)
        await checkThrows(
            #"(command "LAYERSTATE" "Restore" "Missing")"#, host: host, env: &env)
    }
}
