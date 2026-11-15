import XCTest
@testable import ZephyrCore

/// Viewport object model: lock, move/resize, delete, frame layer, undo —
/// plus lock surviving projection-xdata derivation.
final class PaperSpacePhaseViewportObjectTests: XCTestCase {

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

    @MainActor
    private func makeManager(modelDoc: CADDocument, sheetDoc: CADDocument) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "VPObject",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    @MainActor
    private func makeLoadedManager() -> TabManager {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 100, y: 0, z: 0)))
        let manager = makeManager(
            modelDoc: modelDoc,
            sheetDoc: makeLayeredDoc(layerName: "SheetLayer").0)
        XCTAssertTrue(manager.switchToView(at: 1))
        return manager
    }

    @MainActor
    func testLockSurvivesProjectionXData() throws {
        let manager = makeLoadedManager()
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 100))
        XCTAssertFalse(manager.activeViewport()?.isLocked ?? true)

        XCTAssertTrue(manager.setViewportLocked(id: id, locked: true))
        let locked = try XCTUnwrap(manager.activeViewport())
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(locked.detailDescription.contains("locked=1"))

        // Lock rides projection xdata and survives cache derivation.
        let sheetDoc = manager.activeTab!.drawingViews[1].document
        let projected = sheetDoc.entitiesView.filter { $0.isViewportProjected }
        XCTAssertFalse(projected.isEmpty)
        for entity in projected {
            XCTAssertEqual(entity.xdata["dxf.viewport.locked"], .bool(true))
        }
        let cache = DXFImporter.sheetProjectionCache(from: Array(sheetDoc.entitiesView))
        XCTAssertTrue(cache.exactViewports.contains(where: { $0.isLocked }))

        XCTAssertTrue(manager.setViewportLocked(id: id, locked: false))
        XCTAssertFalse(manager.activeViewport()?.isLocked ?? true)
    }

    @MainActor
    func testMoveResizeAndUndo() throws {
        let manager = makeLoadedManager()
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 20))
        let before = try XCTUnwrap(manager.activeViewport())
        let beforeRect = before.paperRect

        XCTAssertTrue(manager.moveActiveSheetViewport(
            id: id, toPaperCenter: (x: 50, y: 40)))
        let moved = try XCTUnwrap(manager.activeViewport())
        let movedRect = moved.paperRect
        XCTAssertEqual(movedRect.minX, beforeRect.minX + 50 - 50 + 0, accuracy: 1e-9)
        XCTAssertNotEqual(movedRect.minY, beforeRect.minY, accuracy: 1e-9)

        XCTAssertTrue(manager.resizeActiveSheetViewport(id: id, width: 200, height: 40))
        let resized = try XCTUnwrap(manager.activeViewport())
        XCTAssertEqual(resized.paperWidth, 200, accuracy: 1e-9)
        XCTAssertEqual(resized.paperHeight, 40, accuracy: 1e-9)
        // Scale preserved by resize.
        XCTAssertEqual(resized.scale, before.scale, accuracy: 1e-9)

        // Each op is one undo step: undo twice returns to original frame.
        let sheetDoc = manager.activeTab!.drawingViews[1].document
        sheetDoc.undo()
        let afterFirstUndo = try XCTUnwrap(manager.activeViewport())
        XCTAssertEqual(afterFirstUndo.paperWidth, before.paperWidth, accuracy: 1e-9)
        // Stored defs live on the document, so undo restores them too.
        sheetDoc.undo()
        let restored = try XCTUnwrap(manager.activeViewport())
        XCTAssertEqual(restored.paperRect.minX, beforeRect.minX, accuracy: 1e-9)
        XCTAssertEqual(restored.paperRect.minY, beforeRect.minY, accuracy: 1e-9)
    }

    @MainActor
    func testDeleteViewportRemovesProjectionsAndUndoRestores() throws {
        let manager = makeLoadedManager()
        let first = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))
        let second = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 50, paperX2: 100, paperY2: 90))
        let sheetDoc = manager.activeTab!.drawingViews[1].document
        let projectionsBefore = sheetDoc.entitiesView
            .filter { $0.isViewportProjected }.count
        XCTAssertGreaterThan(projectionsBefore, 0)

        XCTAssertTrue(manager.deleteActiveSheetViewport(id: second))
        XCTAssertEqual(manager.activeSheetViewports().count, 1)
        XCTAssertEqual(manager.activeSheetViewports().first?.id, first)
        XCTAssertFalse(manager.deleteActiveSheetViewport(id: 9999))
        XCTAssertFalse(manager.deleteActiveSheetViewport(id: second))

        sheetDoc.undo()
        XCTAssertEqual(manager.activeSheetViewports().count, 2)
        XCTAssertTrue(manager.activeSheetViewports().contains(where: { $0.id == second }))
    }

    @MainActor
    func testNewVpUsesDefpointsFrameLayer() throws {
        let manager = makeLoadedManager()
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))
        let vp = try XCTUnwrap(manager.activeSheetViewports().first(where: { $0.id == id }))
        XCTAssertEqual(vp.layerName, "Defpoints")
        let sheetDoc = manager.activeTab!.drawingViews[1].document
        let frameLayer = try XCTUnwrap(sheetDoc.findLayer(named: "Defpoints"))
        XCTAssertFalse(frameLayer.isPlottable)

        // Second viewport reuses the layer instead of duplicating it.
        let second = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 50, paperX2: 100, paperY2: 90))
        XCTAssertEqual(
            manager.activeSheetViewports().first(where: { $0.id == second })?.layerName,
            "Defpoints")
    }


    // MARK: - Interactive MVIEW create

    @MainActor
    func testMViewCreateCommandTwoCornerCreate() throws {
        let manager = makeLoadedManager()
        let processor = CADCommandProcessor()
        let cmd = MViewCreateCommand()

        cmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(processor.commandPrompt, "Specify first corner:")
        XCTAssertFalse(manager.activeSheetViewports().contains { !$0.isSystemViewport })

        XCTAssertEqual(
            cmd.handlePoint(0, 0, tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(processor.commandPrompt, "Specify second corner:")
        XCTAssertEqual(cmd.getDrawingSnapPoints().count, 1)

        XCTAssertEqual(
            cmd.handlePoint(100, 40, tabManager: manager, processor: processor),
            .finished)
        let usable = manager.activeUsableViewports()
        XCTAssertEqual(usable.count, 1)
        let rect = try XCTUnwrap(usable.first?.paperRect)
        XCTAssertEqual(rect.maxX - rect.minX, 100, accuracy: 1e-9)
        XCTAssertEqual(rect.maxY - rect.minY, 40, accuracy: 1e-9)
    }

    @MainActor
    func testMViewCreateCommandDegenerateRepicks() throws {
        let manager = makeLoadedManager()
        let processor = CADCommandProcessor()
        let cmd = MViewCreateCommand()
        cmd.start(tabManager: manager, processor: processor)

        XCTAssertEqual(
            cmd.handlePoint(10, 10, tabManager: manager, processor: processor),
            .consumed)
        // Same point: degenerate frame, reprompt for the first corner.
        XCTAssertEqual(
            cmd.handlePoint(10, 10, tabManager: manager, processor: processor),
            .consumed)
        XCTAssertEqual(processor.commandPrompt, "Degenerate viewport. Specify first corner:")
        XCTAssertTrue(manager.activeSheetViewports().isEmpty)
    }

    @MainActor
    func testMViewDescriptorListsNewOptions() {
        let desc = CommandDescriptor.allCommands.first { $0.canonicalName == "MVIEW" }
        XCTAssertNotNil(desc)
        for token in ["NEW", "LOCK", "UNLOCK", "DELETE", "MOVE"] {
            XCTAssertTrue(
                desc!.syntax.contains(token),
                "MVIEW syntax must list \(token); got: \(desc!.syntax)")
        }
    }


    // MARK: - Per-viewport clip (projection trim + PDF)

    @MainActor
    func testProjectedLineIsTrimmedToFrame() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: -500, y: 0, z: 0), to: Vector3(x: 500, y: 0, z: 0)))
        let manager = makeManager(
            modelDoc: modelDoc,
            sheetDoc: makeLayeredDoc(layerName: "SheetLayer").0)
        XCTAssertTrue(manager.switchToView(at: 1))

        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 20))
        let vp = try XCTUnwrap(
            manager.activeSheetViewports().first(where: { $0.id == id }))
        let rect = vp.paperRect
        let sheetDoc = manager.activeTab!.drawingViews[1].document
        let projected = sheetDoc.entitiesView.filter {
            $0.isViewportProjected && ($0.localGeometry ?? []).count == 1
        }
        XCTAssertFalse(projected.isEmpty)
        for entity in projected {
            guard case .line(let start, let end, _) = (entity.localGeometry ?? [])[0] else { continue }
            for point in [start, end] {
                let world = entity.transform.transformPoint(point)
                XCTAssertGreaterThanOrEqual(
                    world.x, rect.minX - 1e-6,
                    "Projected line end must stay inside the frame (x)")
                XCTAssertLessThanOrEqual(
                    world.x, rect.maxX + 1e-6,
                    "Projected line end must stay inside the frame (x)")
                XCTAssertGreaterThanOrEqual(
                    world.y, rect.minY - 1e-6,
                    "Projected line end must stay inside the frame (y)")
                XCTAssertLessThanOrEqual(
                    world.y, rect.maxY + 1e-6,
                    "Projected line end must stay inside the frame (y)")
            }
        }
    }

    @MainActor
    func testLineFullyOutsideFrameIsCulled() throws {
        let (modelDoc, modelLayerID) = makeLayeredDoc(layerName: "ModelLayer")
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0)))
        modelDoc.addEntity(makeLine(
            layerID: modelLayerID,
            from: Vector3(x: 1000, y: 10, z: 0), to: Vector3(x: 1010, y: 10, z: 0)))
        let manager = makeManager(
            modelDoc: modelDoc,
            sheetDoc: makeLayeredDoc(layerName: "SheetLayer").0)
        XCTAssertTrue(manager.switchToView(at: 1))

        // Frame fits both model lines (fit scale), so both project at first...
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 20))
        XCTAssertEqual(
            manager.activeTab!.drawingViews[1].document.entitiesView
                .filter { $0.isViewportProjected }.count, 2)
        // ...then pan the viewport to show only the left line.
        XCTAssertTrue(manager.updateActiveSheetViewport(
            id: id, viewTarget: (x: 5, y: 0)))
        let remaining = manager.activeTab!.drawingViews[1].document.entitiesView
            .filter { $0.isViewportProjected }
        XCTAssertFalse(remaining.isEmpty)
        let rect = try XCTUnwrap(
            manager.activeSheetViewports().first(where: { $0.id == id })).paperRect
        for entity in remaining {
            guard case .line(let start, let end, _) = (entity.localGeometry ?? [])[0] else { continue }
            for point in [start, end] {
                let world = entity.transform.transformPoint(point)
                XCTAssertGreaterThanOrEqual(world.x, rect.minX - 1e-6)
                XCTAssertLessThanOrEqual(world.x, rect.maxX + 1e-6)
            }
        }
    }

    @MainActor
    func testPDFClipsProjectedGeometryToFrame() throws {
        let layer = Layer(name: "0", color: .black)
        func makeEntity(withProjected: Bool) -> CADEntity {
            var xdata: [String: XDataValue] = [:]
            if withProjected {
                xdata["dxf.viewport.projected"] = .bool(true)
                xdata["dxf.viewport.paperCenterX"] = .double(6.0)
                xdata["dxf.viewport.paperCenterY"] = .double(4.5)
                xdata["dxf.viewport.paperWidth"] = .double(12.0)
                xdata["dxf.viewport.paperHeight"] = .double(9.0)
                xdata["dxf.viewport.status"] = .int(2)
                xdata["dxf.viewport.id"] = .int(2)
                xdata["dxf.viewport.stableID"] = .string("VP-TEST")
            }
            return CADEntity(
                layerID: layer.handle,
                localGeometry: [.line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 100, y: 0, z: 0), color: .black)],
                xdata: xdata)
        }
        // Content streams are FlateDecode-compressed in the file, so assert
        // at the uncompressed content-builder level.
        func contentString(withProjected: Bool) -> String {
            let doc = CADDocument()
            doc.addLayer(layer)
            doc.addEntity(makeEntity(withProjected: withProjected))
            let items = PDFExporter.collectItems(document: doc, isLightBackground: true)
            let cb = PDFContentBuilder()
            PDFExporter.writeContent(
                items: items, document: doc, scale: 1, margin: 0,
                minX: 0, maxY: 100, isLightBackground: true, to: cb)
            return String(decoding: cb.build(), as: UTF8.self)
        }
        // Frame rect: minX=0, minY=-9, w=12, h=9.
        let rect = try XCTUnwrap(PDFExporter.viewportClipRect(xdata: [
            "dxf.viewport.paperCenterX": .double(6.0),
            "dxf.viewport.paperCenterY": .double(4.5),
            "dxf.viewport.paperWidth": .double(12.0),
            "dxf.viewport.paperHeight": .double(9.0),
        ]))
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, -9, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX, 12, accuracy: 1e-9)
        XCTAssertEqual(rect.maxY, 0, accuracy: 1e-9)

        let withVP = contentString(withProjected: true)
        let withoutVP = contentString(withProjected: false)
        XCTAssertTrue(withVP.contains("re W n"),
            "Projected geometry must be wrapped in a viewport clip")
        XCTAssertFalse(withoutVP.contains("re W n"),
            "Non-projected geometry must not be clipped")

        // Two projected entities get one clip wrapper each.
        let doc = CADDocument()
        doc.addLayer(layer)
        doc.addEntity(makeEntity(withProjected: true))
        doc.addEntity(makeEntity(withProjected: true))
        let twoItems = PDFExporter.collectItems(document: doc, isLightBackground: true)
        let cb = PDFContentBuilder()
        PDFExporter.writeContent(
            items: twoItems, document: doc, scale: 1, margin: 0,
            minX: 0, maxY: 100, isLightBackground: true, to: cb)
        let twoString = String(decoding: cb.build(), as: UTF8.self)
        XCTAssertEqual(
            twoString.components(separatedBy: "re W n").count - 1, 2,
            "Each projected entity gets its own clip wrapper")
    }

    @MainActor
    func testUnknownIdOpsFailHonestly() {
        let manager = makeLoadedManager()
        XCTAssertFalse(manager.setViewportLocked(id: 4242, locked: true))
        XCTAssertFalse(manager.moveActiveSheetViewport(
            id: 4242, toPaperCenter: (x: 1, y: 1)))
        XCTAssertFalse(manager.resizeActiveSheetViewport(id: 4242, width: 10, height: 10))
        XCTAssertFalse(manager.deleteActiveSheetViewport(id: 4242))
    }

    // MARK: - Persistence (OFF + locked through DXF/EAB)

    @MainActor
    func testOFFAndLockedViewportsSurviveDXFRoundTrip() throws {
        let manager = makeLoadedManager()
        let lockedID = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))
        let offID = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 50, paperX2: 100, paperY2: 90))
        XCTAssertTrue(manager.setViewportLocked(id: lockedID, locked: true))
        XCTAssertTrue(manager.updateActiveSheetViewport(id: offID, status: 0))
        XCTAssertEqual(manager.activeSheetViewports().count, 2)
        XCTAssertEqual(
            manager.activeSheetViewports().filter { $0.status == 0 }.count, 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-off-locked-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(views: manager.activeTab!.drawingViews, to: url, tileMode: 0)

        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let sheet = try XCTUnwrap(reimported.views.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.storedViewportDefinitions.count, 2)
        XCTAssertTrue(
            sheet.storedViewportDefinitions.contains(where: { $0.status == 0 }),
            "OFF viewport must survive DXF export")
        XCTAssertTrue(
            sheet.storedViewportDefinitions.contains(where: { $0.isLocked }),
            "Locked viewport must survive DXF export")

        let rebuilt = DrawingViewFactory.makeDrawingViews(
            from: reimported, sourceFileName: "reloaded.dxf")
        let rebuiltSheet = try XCTUnwrap(rebuilt.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(rebuiltSheet.document.storedViewportDefinitions.count, 2)
    }

    @MainActor
    func testOFFAndLockedViewportsSurviveEABRoundTrip() throws {
        let manager = makeLoadedManager()
        let lockedID = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))
        let offID = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 50, paperX2: 100, paperY2: 90))
        XCTAssertTrue(manager.setViewportLocked(id: lockedID, locked: true))
        XCTAssertTrue(manager.updateActiveSheetViewport(id: offID, status: 0))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-off-locked-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(views: manager.activeTab!.drawingViews, to: url)
        let data = try Data(contentsOf: url)
        let reloaded = try EABReader.readViews(from: data)
        let sheet = try XCTUnwrap(reloaded.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.document.storedViewportDefinitions.count, 2)
        XCTAssertTrue(
            sheet.document.storedViewportDefinitions.contains(where: { $0.status == 0 }),
            "OFF viewport must survive EAB export")
        XCTAssertTrue(
            sheet.document.storedViewportDefinitions.contains(where: { $0.isLocked }),
            "Locked viewport must survive EAB export")
    }
    // MARK: - Floating model space (3a)

    @MainActor
    func testFloatingModelSpaceEnterExitAndCVPORT() throws {
        let manager = makeLoadedManager()
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))

        XCTAssertFalse(manager.isFloatingModelSpace)
        XCTAssertEqual(manager.currentViewportID, 1)

        // Enter adopts the usable viewport and reports CVPORT.
        XCTAssertEqual(manager.enterFloatingModelSpace(), id)
        XCTAssertTrue(manager.isFloatingModelSpace)
        XCTAssertEqual(manager.currentViewportID, id)
        XCTAssertEqual(manager.activeViewport()?.id, id)
        XCTAssertEqual(manager.floatingViewport()?.id, id)

        // Re-enter is a no-op; exit clears.
        XCTAssertEqual(manager.enterFloatingModelSpace(), id)
        XCTAssertTrue(manager.isFloatingModelSpace)
        manager.exitFloatingModelSpace()
        XCTAssertFalse(manager.isFloatingModelSpace)
        XCTAssertEqual(manager.currentViewportID, 1)

        // Explicit id must be usable.
        XCTAssertNil(manager.enterFloatingModelSpace(id: 4242))
        XCTAssertFalse(manager.isFloatingModelSpace)
        XCTAssertEqual(manager.enterFloatingModelSpace(id: id), id)
    }

    @MainActor
    func testFloatingExitsOnViewSwitchAndPSPACE() throws {
        let manager = makeLoadedManager()
        let id = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 0, paperY1: 0, paperX2: 100, paperY2: 40))
        XCTAssertEqual(manager.enterFloatingModelSpace(), id)
        XCTAssertTrue(manager.switchToView(at: 0))
        XCTAssertFalse(manager.isFloatingModelSpace)
        XCTAssertTrue(manager.switchToView(at: 1))
        XCTAssertEqual(manager.enterFloatingModelSpace(), id)
        XCTAssertTrue(manager.switchToPaperSpace())
        XCTAssertFalse(manager.isFloatingModelSpace)
        XCTAssertTrue(manager.isPaperSpace)
    }

    // MARK: - Scale labels

    func testViewportScaleLabels() {
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(for: 8), "1/4\"=1'")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(for: 15), "1'=1\"")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(for: 16), "1:1")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(for: 25), "1:50")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(for: 27), "2:1")
        // Factors round-trip through labels; non-standard reads Custom.
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(factor: 1.0 / 48.0), "1/4\"=1'")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(factor: 0.02), "1:50")
        XCTAssertEqual(
            CADPlotSettings.viewportScaleLabel(factor: 0.03).hasPrefix("Custom"), true)
    }
}
