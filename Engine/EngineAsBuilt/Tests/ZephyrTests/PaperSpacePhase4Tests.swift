import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Paper-space Phase 4: layout lifecycle, paper-space groups, PSLTSCALE,
/// and DXF/EAB round-trip hardening.
final class PaperSpacePhase4Tests: XCTestCase {

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

    private func makeSheetWithViewport(
        modelLine: CADEntity, modelLayer: Layer
    ) -> (sheetDoc: CADDocument, sheetLayerID: UUID) {
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
            document: modelDoc, displayName: "Phase4",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    // MARK: - Layout lifecycle

    @MainActor
    func testLayoutCreateRenameDelete() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0)))
        let manager = makeManager(
            modelDoc: modelDoc,
            sheetDoc: makeLayeredDoc(layerName: "SheetLayer").0)
        XCTAssertEqual(manager.availableViews.count, 2)

        // Named create becomes active with Letter paper + a fit viewport.
        XCTAssertTrue(manager.createLayout(named: "A1"))
        XCTAssertEqual(manager.activeViewName, "A1")
        XCTAssertEqual(manager.availableViews.count, 3)
        let created = manager.activeTab!.drawingViews[manager.activeTab!.activeViewIndex].document
        let createdW = try XCTUnwrap(created.layoutSettings?.paperWidthMM)
        let createdH = try XCTUnwrap(created.layoutSettings?.paperHeightMM)
        XCTAssertEqual(createdW, 279.4, accuracy: 1e-9)
        XCTAssertEqual(createdH, 215.9, accuracy: 1e-9)
        XCTAssertEqual(manager.activeSheetViewports().count, 1)
        XCTAssertEqual(
            created.entitiesView.filter({ $0.isViewportProjected }).count, 1)

        // Blank name falls back to the next free LayoutN.
        XCTAssertTrue(manager.createLayout())
        XCTAssertTrue(manager.activeViewName?.hasPrefix("Layout") == true)
        XCTAssertFalse(manager.createLayout(named: "A1"))

        // Rename guards.
        XCTAssertTrue(manager.renameLayout(from: "A1", to: "A2"))
        XCTAssertEqual(manager.paperLayoutNames.contains("A2"), true)
        XCTAssertFalse(manager.renameLayout(from: "Model", to: "M2"))
        XCTAssertFalse(manager.renameLayout(from: "A2", to: "Model"))
        XCTAssertFalse(manager.renameLayout(from: "Nope", to: "X"))

        // Delete guards: Model kept, last view kept.
        XCTAssertFalse(manager.deleteLayout(named: "Model"))
        XCTAssertFalse(manager.deleteLayout(named: "Nope"))
        XCTAssertTrue(manager.deleteLayout(named: "A2"))
        XCTAssertFalse(manager.availableViews.map(\.name).contains("A2"))
    }

    @MainActor
    func testLayoutCopyCarriesPaperAndViewports() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        let (sheetDoc, sheetLayerID) = makeSheetWithViewport(
            modelLine: line, modelLayer: modelLayer)
        // Paper group on the sheet.
        let paperHandle = try XCTUnwrap(
            sheetDoc.entitiesView.first(where: { !$0.isViewportProjected })?.handle)
        sheetDoc.groups = ["TITLE": CADGroup(name: "TITLE", members: [paperHandle])]
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))

        XCTAssertTrue(manager.copyLayout(from: "Layout1", to: "Layout1-Copy"))
        XCTAssertEqual(manager.activeViewName, "Layout1-Copy")
        let copyDoc = manager.activeTab!.drawingViews[manager.activeTab!.activeViewIndex].document
        // Paper geometry + groups + viewport defs carried over.
        XCTAssertEqual(
            copyDoc.entitiesView.filter({ !$0.isViewportProjected }).count, 1)
        XCTAssertEqual(copyDoc.groups["TITLE"]?.members, [paperHandle])
        XCTAssertEqual(
            manager.activeSheetViewports().map(\.id), [2])
        // Guards.
        XCTAssertFalse(manager.copyLayout(from: "Model", to: "M-Copy"))
        XCTAssertFalse(manager.copyLayout(from: "Layout1", to: "Layout1-Copy"))
        XCTAssertFalse(manager.copyLayout(from: "Nope", to: "X"))

        // Live link: a model edit re-projects in the copy.
        XCTAssertTrue(manager.switchToView(at: 0))
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 50, z: 0), to: Vector3(x: 50, y: 50, z: 0)))
        XCTAssertTrue(manager.switchToView(named: "Layout1-Copy"))
        XCTAssertEqual(
            copyDoc.entitiesView.filter({ $0.isViewportProjected }).count, 2)
        _ = sheetLayerID
    }

    // MARK: - Paper-space groups round-trip

    @MainActor
    func testPaperGroupsRoundTripPerView() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let m1 = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        let m2 = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 5, z: 0), to: Vector3(x: 10, y: 5, z: 0))
        modelDoc.addEntity(m1)
        modelDoc.addEntity(m2)
        modelDoc.groups = ["MGROUP": CADGroup(name: "MGROUP", members: [m1.handle, m2.handle])]
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: m1, modelLayer: modelLayer)
        let paperHandles = sheetDoc.entitiesView
            .filter({ !$0.isViewportProjected }).map(\.handle)
        XCTAssertEqual(paperHandles.count, 1)
        sheetDoc.groups = ["PGROUP": CADGroup(name: "PGROUP", members: paperHandles)]

        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-groups-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.views.count, 2)
        let modelView = try XCTUnwrap(reimported.views.first(where: { $0.kind == .model }))
        let sheetView = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        // Model groups stay on the model view; paper groups on the sheet.
        // Groups travel on the result + per-view payloads.
        XCTAssertTrue(reimported.groups.map(\.name).contains("MGROUP"))
        XCTAssertTrue(sheetView.groups.map(\.name).contains("PGROUP"))
        XCTAssertFalse(sheetView.groups.map(\.name).contains("MGROUP"))
        let regrouped = try XCTUnwrap(sheetView.groups.first(where: { $0.name == "PGROUP" }))
        XCTAssertEqual(regrouped.members.count, 1)
    }

    // MARK: - PSLTSCALE

    @MainActor
    func testPsltscaleSysvarAndMultiplier() async throws {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        var env = LispEnvironment()
        func eval(_ source: String) async throws -> LispValue {
            let forms = try LispReader().readAll(source)
            return try await LispEvaluator().run(forms, env: &env, host: host)
        }
        let psltscaleDefault = try await eval(#"(getvar "PSLTSCALE")"#)
        XCTAssertEqual(psltscaleDefault, .int(1))
        _ = try await eval(#"(setvar "PSLTSCALE" 0)"#)
        let psltscaleZero = try await eval(#"(getvar "PSLTSCALE")"#)
        XCTAssertEqual(psltscaleZero, .int(0))
        XCTAssertEqual(doc.paperSpaceLinetypeScale, 0)
        // Out of range rejected; document unchanged.
        _ = try? await eval(#"(setvar "PSLTSCALE" 5)"#)
        XCTAssertEqual(doc.paperSpaceLinetypeScale, 0)

        // Multiplier math on a projected copy.
        var xdata: [String: XDataValue] = [:]
        xdata["dxf.viewport.projected"] = .bool(true)
        xdata["dxf.viewport.paperHeight"] = .double(9)
        xdata["dxf.viewport.viewHeight"] = .double(100)
        let layerID = doc.findLayer(named: "0")!.handle
        let projected = CADEntity(layerID: layerID, xdata: xdata)
        XCTAssertTrue(projected.isViewportProjected)
        XCTAssertEqual(
            CADDocument.paperLinetypeMultiplier(for: projected, psltscale: 1),
            0.09, accuracy: 1e-9)
        XCTAssertEqual(
            CADDocument.paperLinetypeMultiplier(for: projected, psltscale: 0), 1)
        let plain = CADEntity(layerID: layerID)
        XCTAssertEqual(
            CADDocument.paperLinetypeMultiplier(for: plain, psltscale: 1), 1)
    }

    // MARK: - DXF round-trip hardening

    @MainActor
    func testDXFRoundTripLayoutsViewportsAndHeader() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0)))
        modelDoc.paperSpaceLinetypeScale = 0
        let (sheetDoc, _) = makeSheetWithViewport(
            modelLine: modelDoc.entitiesView.first!,
            modelLayer: modelLayer)
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-rt-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: views, to: url, tileMode: 0,
                              psltscale: modelDoc.paperSpaceLinetypeScale)

        // Header vars survive in the file text.
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\r\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func headerInt(_ name: String) throws -> String {
            guard let i = lines.firstIndex(of: name), i + 2 < lines.count else {
                throw NSError(domain: "test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(name) missing"])
            }
            XCTAssertEqual(lines[i + 1], "70")
            return lines[i + 2]
        }
        XCTAssertEqual(try headerInt("$TILEMODE"), "0")
        XCTAssertEqual(try headerInt("$PSLTSCALE"), "0")

        // Layouts, order, and viewport parameters survive.
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(reimported.views.map(\.name), ["Model", "Layout1"])
        XCTAssertEqual(reimported.views.map(\.kind), [.model, .sheet])
        XCTAssertEqual(reimported.paperSpaceLinetypeScale, 0)
        let sheet = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        let projected = sheet.entities.filter(\.isViewportProjected)
        XCTAssertFalse(projected.isEmpty)
        for entity in projected {
            XCTAssertEqual(entity.xdata["dxf.viewport.id"], .int(2))
            if case .double(let h) = entity.xdata["dxf.viewport.viewHeight"] {
                XCTAssertEqual(h, 100, accuracy: 1e-6)
            } else {
                XCTFail("viewHeight missing")
            }
            if case .double(let tw) = entity.xdata["dxf.viewport.twistDegrees"] {
                XCTAssertEqual(tw, 0, accuracy: 1e-9)
            } else {
                XCTFail("twistDegrees missing")
            }
        }
        // Switchable spaces still agree after the round trip.
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToPaperSpace())
        XCTAssertEqual(manager.tileMode, 0)
        XCTAssertTrue(manager.switchToModelSpace())
        XCTAssertEqual(manager.tileMode, 1)
    }

    // MARK: - EAB round-trip

    @MainActor
    func testEABRoundTripSheetViews() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        let line = makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0))
        modelDoc.addEntity(line)
        modelDoc.paperSpaceLinetypeScale = 0
        let (sheetDoc, _) = makeSheetWithViewport(modelLine: line, modelLayer: modelLayer)
        let paperHandle = try XCTUnwrap(
            sheetDoc.entitiesView.first(where: { !$0.isViewportProjected })?.handle)
        sheetDoc.groups = ["TITLE": CADGroup(name: "TITLE", members: [paperHandle])]
        sheetDoc.layoutSettings = CADLayoutSettings(
            paperName: "Letter", paperWidthMM: 279.4, paperHeightMM: 215.9,
            plotPaperUnits: 1)
        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: views, to: url)
        let data = try Data(contentsOf: url)
        let reloaded = try EABReader.readViews(from: data)
        XCTAssertEqual(reloaded.map(\.name), ["Model", "Layout1"])
        XCTAssertEqual(reloaded.map(\.kind), [.model, .sheet])
        let reloadedModel = try XCTUnwrap(reloaded.first(where: { $0.kind == .model }))
        XCTAssertEqual(reloadedModel.document.paperSpaceLinetypeScale, 0)
        let sheet = try XCTUnwrap(reloaded.first(where: { $0.kind == .sheet }))
        XCTAssertFalse(sheet.document.entitiesView.filter(\.isViewportProjected).isEmpty)
        XCTAssertEqual(sheet.document.groups["TITLE"]?.members.count, 1)
        // Per-view setting: model persisted 0, sheet kept its default 1.
        XCTAssertEqual(sheet.document.paperSpaceLinetypeScale, 1)
        let reloadedWidth = try XCTUnwrap(sheet.document.layoutSettings?.paperWidthMM)
        let reloadedHeight = try XCTUnwrap(sheet.document.layoutSettings?.paperHeightMM)
        XCTAssertEqual(reloadedWidth, 279.4, accuracy: 1e-9)
        XCTAssertEqual(reloadedHeight, 215.9, accuracy: 1e-9)
    }
}
