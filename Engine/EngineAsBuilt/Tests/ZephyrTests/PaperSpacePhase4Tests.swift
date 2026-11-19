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

    // MARK: - Legacy Window/Fit sheet coincidence (SHEET 3 regression)

    /// SHEET 3 (HYD. PRO.) page setup: Tabloid, inches, landscape, Window
    /// plot type with Scaled-to-Fit 1:27.8711, centred (flags 692).
    private func sheet3LikeSettings() -> CADPlotSettings {
        CADPlotSettings(
            paperWidthMM: 279.4, paperHeightMM: 431.8,
            marginLM: 5.027, marginBM: 5.027, marginRM: 5.027, marginTM: 5.027,
            plotPaperUnits: 0, plotRotation: 1,
            plotOriginXMM: 0.0, plotOriginYMM: 3.048,
            plotWindowMinX: 702.0429721660568, plotWindowMinY: 149.2231489467952,
            plotWindowMaxX: 1157.875219820294, plotWindowMaxY: 444.7729192754576,
            customScaleNumerator: 1.0, customScaleDenominator: 27.87110050658384,
            plotFlags: 692, plotType: 4, standardScaleType: 0)
    }

    /// SHEET 3's floating viewport (id 2) with real converted-DXF numbers.
    private func sheet3Viewport() -> DXFImporter.SheetViewport {
        DXFImporter.SheetViewport(
            paperCenterX: 929.9590959931754, paperCenterY: 296.9980341111269,
            paperWidth: 469.3921584880686, paperHeight: 303.7243378452208,
            status: 2, id: 2,
            viewCenterX: 560.3756489519383, viewCenterY: 365.0950717644659,
            viewTargetX: 0, viewTargetY: 0,
            viewHeight: 148.8124, twistAngle: 0,
            layerName: "Text - General")
    }

    @MainActor
    func testLegacyWindowSheetPaperViewportAndPickCoincide() throws {
        // A model line inside SHEET 3's model window (world coords).
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        let modelLayer = modelDoc.allLayers.first!
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 500, y: -350, z: 0), to: Vector3(x: 620, y: -380, z: 0)))
        let modelLine = try XCTUnwrap(modelDoc.entitiesView.first)

        var cache = DXFImporter.SheetProjectionCache()
        cache.exactViewports = [sheet3Viewport()]
        let projected = DXFImporter.projectedEntities(
            modelEntities: [modelLine], cache: cache, xrefBlockIDs: [])
        XCTAssertEqual(projected.count, 1)
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        sheetDoc.importLayersBlocksEntities(
            layers: [modelLayer], blocks: [], entities: projected)
        let ps = sheet3LikeSettings()
        sheetDoc.plotSettings = ps
        sheetDoc.layoutSettings = ps.layoutSettings

        // Projected content lands inside the viewport frame.
        let viewport = sheet3Viewport()
        let rect = viewport.paperRect
        let box = try XCTUnwrap(projected.first?.worldBoundingBox)
        XCTAssertGreaterThanOrEqual(box.min.x, rect.minX - 1e-6)
        XCTAssertGreaterThanOrEqual(box.min.y, rect.minY - 1e-6)
        XCTAssertLessThanOrEqual(box.max.x, rect.maxX + 1e-6)
        XCTAssertLessThanOrEqual(box.max.y, rect.maxY + 1e-6)

        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        XCTAssertTrue(manager.switchToView(at: 1))

        // The overlay paper sits on the viewport frame: same centre (overlay
        // is DXF-frame, world negates Y), edges within the frame-border
        // slack (the viewport systematically exceeds the plot window ~3%).
        let rects = try XCTUnwrap(PaperSheetGeometry.overlayRects(for: ps))
        let oCX = (rects.paper.minX + rects.paper.maxX) * 0.5
        let oCY = (rects.paper.minY + rects.paper.maxY) * 0.5
        let vCX = (rect.minX + rect.maxX) * 0.5
        let vCY = (rect.minY + rect.maxY) * 0.5
        XCTAssertEqual(oCX, vCX, accuracy: 1e-6)
        XCTAssertEqual(oCY, -vCY, accuracy: 1e-6)
        let oWorldMinX = rects.paper.minX, oWorldMinY = -rects.paper.maxY
        let oWorldMaxX = rects.paper.maxX, oWorldMaxY = -rects.paper.minY
        XCTAssertEqual(oWorldMinX, rect.minX, accuracy: 10.0)
        XCTAssertEqual(oWorldMinY, rect.minY, accuracy: 10.0)
        XCTAssertEqual(oWorldMaxX, rect.maxX, accuracy: 10.0)
        XCTAssertEqual(oWorldMaxY, rect.maxY, accuracy: 10.0)

        // Clicking the shared centre picks the viewport; the old mirrored
        // frame location (pre-fix draw position) picks nothing.
        let picked = manager.selectViewport(atPaperPoint: vCX, vCY)
        XCTAssertEqual(picked?.id, 2)
        XCTAssertNil(manager.selectViewport(atPaperPoint: vCX, -vCY))
    }

    @MainActor
    func testCreateLayoutFrameMatchesOverlayPaper() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 50, z: 0)))
        let manager = makeManager(
            modelDoc: modelDoc,
            sheetDoc: makeLayeredDoc(layerName: "SheetLayer").0)
        XCTAssertTrue(manager.createLayout(named: "Fresh"))
        let freshDoc = manager.activeTab!.drawingViews[manager.activeTab!.activeViewIndex].document
        let viewport = try XCTUnwrap(manager.activeSheetViewports().first)
        let rects = try XCTUnwrap(PaperSheetGeometry.overlayRects(
            for: freshDoc.plotSettings ?? CADPlotSettings()))
        // The new viewport frame is the overlay paper in world coords.
        XCTAssertEqual(viewport.paperRect.minX, rects.paper.minX, accuracy: 1e-9)
        XCTAssertEqual(viewport.paperRect.minY, -rects.paper.maxY, accuracy: 1e-9)
        XCTAssertEqual(viewport.paperRect.maxX, rects.paper.maxX, accuracy: 1e-9)
        XCTAssertEqual(viewport.paperRect.maxY, -rects.paper.minY, accuracy: 1e-9)
        // And the fitted model projection lands inside it.
        let projected = freshDoc.entitiesView.filter(\.isViewportProjected)
        XCTAssertFalse(projected.isEmpty)
        for entity in projected {
            let box = try XCTUnwrap(entity.worldBoundingBox)
            XCTAssertGreaterThanOrEqual(box.min.x, viewport.paperRect.minX - 1e-6)
            XCTAssertGreaterThanOrEqual(box.min.y, viewport.paperRect.minY - 1e-6)
            XCTAssertLessThanOrEqual(box.max.x, viewport.paperRect.maxX + 1e-6)
            XCTAssertLessThanOrEqual(box.max.y, viewport.paperRect.maxY + 1e-6)
        }
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
        _ = try XCTUnwrap(reimported.views.first(where: { $0.kind == .model }))
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

    // MARK: - AutoCAD LT LAYOUT FeatureCommand

    @MainActor
    func testLayoutCommandInteractiveNewAndDefaults() {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        let desc = CommandDescriptor.allCommands.first { $0.canonicalName == "LAYOUT" }
        XCTAssertEqual(desc?.aliases, ["SHEET", "LO", "-LAYOUT"])

        cmd.start(tabManager: manager, processor: processor)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertEqual(processor.commandPrompt, LayoutCommand.optionPrompt)
        XCTAssertEqual(cmd.phase, .option)
        XCTAssertEqual(
            cmd.commandTextOptions(for: "").map(\.value),
            ["C", "D", "N", "T", "R", "SA", "S", "?"])

        // Step 1: Type "n" + Enter
        let step1 = cmd.handleCommandText("n", tabManager: manager, processor: processor)
        XCTAssertEqual(step1, .consumed)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))
        XCTAssertEqual(processor.commandPrompt, "Enter new Layout name <Layout2>:")
        XCTAssertTrue(cmd.commandTextOptions(for: "Floor").isEmpty)

        // Duplicate or invalid names keep LayoutCommand in .newName
        XCTAssertEqual(
            cmd.handleCommandText("Layout1", tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))
        XCTAssertEqual(
            cmd.handleCommandText("Bad/Name", tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))

        // Step 2: Type custom layout name + Enter
        var zoomed = false
        let step2 = cmd.handleCommandText(
            "FloorPlan",
            tabManager: manager,
            processor: processor,
            onZoomExtents: { zoomed = true })
        XCTAssertEqual(step2, .finished)
        XCTAssertFalse(processor.commandLineActive)
        XCTAssertTrue(zoomed)
        XCTAssertEqual(manager.activeViewName, "FloorPlan")
        XCTAssertTrue(manager.paperLayoutNames.contains("FloorPlan"))

        // Bare Enter on .newName uses <Layout2>
        let cmd2 = LayoutCommand()
        cmd2.start(tabManager: manager, processor: processor)
        _ = cmd2.handleCommandText("N", tabManager: manager, processor: processor)
        XCTAssertEqual(cmd2.phase, .newName(defaultName: "Layout2"))
        XCTAssertEqual(
            cmd2.handleCommandText("", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "Layout2")
    }

    @MainActor
    func testLayoutCommandSetCopyRenameDeleteAndInformationalOptions() {
        let (modelDoc, _) = makeLayeredDoc(layerName: "ModelLayer")
        let (sheetDoc, _) = makeLayeredDoc(layerName: "SheetLayer")
        let manager = makeManager(modelDoc: modelDoc, sheetDoc: sheetDoc)
        let processor = CADCommandProcessor()

        // 1. Bare Enter at option prompt -> Set -> Bare Enter activates <Layout1>
        let setCmd = LayoutCommand()
        setCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            setCmd.handleCommandText("", tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(setCmd.phase, .setName(defaultName: "Layout1"))
        XCTAssertEqual(
            setCmd.handleCommandText("", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "Layout1")

        // 2. Copy with defaults -> Layout1 (2)
        let copyCmd = LayoutCommand()
        copyCmd.start(tabManager: manager, processor: processor)
        _ = copyCmd.handleCommandText("c", tabManager: manager, processor: processor)
        XCTAssertEqual(copyCmd.phase, .copySource(defaultSource: "Layout1"))
        _ = copyCmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(copyCmd.phase, .copyDest(sourceName: "Layout1", defaultDest: "Layout1 (2)"))
        XCTAssertEqual(
            copyCmd.handleCommandText("", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "Layout1 (2)")

        // 3. Rename Layout1 (2) -> SheetB
        let renameCmd = LayoutCommand()
        renameCmd.start(tabManager: manager, processor: processor)
        _ = renameCmd.handleCommandText("r", tabManager: manager, processor: processor)
        XCTAssertEqual(renameCmd.phase, .renameSource(defaultSource: "Layout1 (2)"))
        _ = renameCmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(renameCmd.phase, .renameDest(oldName: "Layout1 (2)"))
        XCTAssertEqual(
            renameCmd.handleCommandText("SheetB", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1", "SheetB"])

        // 4. ?, Template stay in .option (SAveas now copies the current layout)
        let infoCmd = LayoutCommand()
        infoCmd.start(tabManager: manager, processor: processor)
        for kw in ["?", "t"] {
            XCTAssertEqual(
                infoCmd.handleCommandText(kw, tabManager: manager, processor: processor),
                .consumed)
            XCTAssertEqual(infoCmd.phase, .option)
            XCTAssertTrue(processor.commandLineActive)
        }

        // 5. Delete SheetB (after guarding Model)
        let deleteCmd = LayoutCommand()
        deleteCmd.start(tabManager: manager, processor: processor)
        _ = deleteCmd.handleCommandText("d", tabManager: manager, processor: processor)
        XCTAssertEqual(
            deleteCmd.handleCommandText("Model", tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(
            deleteCmd.handleCommandText("SheetB", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1"])
    }
}
