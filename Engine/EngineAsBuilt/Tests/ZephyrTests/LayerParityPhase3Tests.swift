import XCTest
@testable import ZephyrCore

/// Phase 3 layer-parity: stable viewport identity, per-layout override
/// storage (VPFREEZE + style deltas), DXF VIEWPORT 331 and ZEPHYR_VP
/// style-override records, EAB persistence, projection-aware rendering,
/// plot output, selection rules, and viewport creation behavior.
/// Global model entities always resolve through the plain layer table.
@MainActor
final class LayerParityPhase3Tests: XCTestCase {

    // MARK: - Fixtures

    private func makeLayer(name: String, freezeInNewViewports: Bool = false) -> (CADDocument, Layer) {
        let doc = CADDocument()
        var layer = Layer(
            handle: UUID(), name: name, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        layer.freezeInNewViewports = freezeInNewViewports
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layer)
    }

    private func lineEntity(layerID: UUID) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 100, y: 0, z: 0),
                color: nil)],
            transform: .identity)
    }

    private func viewport() -> DXFImporter.SheetViewport {
        DXFImporter.SheetViewport(
            paperCenterX: 6, paperCenterY: 4.5,
            paperWidth: 12, paperHeight: 9,
            status: 2, id: 2,
            viewCenterX: 0, viewCenterY: 0,
            viewTargetX: 50, viewTargetY: 0,
            viewHeight: 100, twistAngle: 0,
            layerName: "MODEL")
    }

    /// Sheet document holding one projected copy of `modelLine` through a
    /// fresh viewport, plus the viewport's stable key.
    private func sheetWithProjection(
        modelLine: CADEntity, modelLayer: Layer
    ) -> (sheetDoc: CADDocument, stableID: String, projected: CADEntity) {
        let vp = viewport()
        var cache = DXFImporter.SheetProjectionCache()
        cache.exactViewports = [vp]
        let projected = DXFImporter.projectedEntities(
            modelEntities: [modelLine], cache: cache, xrefBlockIDs: [])
        XCTAssertEqual(projected.count, 1)
        let sheetDoc = CADDocument()
        sheetDoc.importLayersBlocksEntities(
            layers: [modelLayer], blocks: [], entities: projected)
        return (sheetDoc, vp.stableID, projected[0])
    }

    @MainActor
    private func managerWithSheet(
        modelDoc: CADDocument, sheetDoc: CADDocument
    ) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Phase3",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        return manager
    }

    // MARK: - Stable identity

    func testStableIDRoundTripsThroughProjectedXData() {
        let first = viewport()
        let second = viewport()
        XCTAssertFalse(first.stableID.isEmpty)
        XCTAssertNotEqual(first.stableID, second.stableID, "each viewport gets a distinct key")
        let xdata = first.projectedXData([:])
        let back = DXFImporter.sheetProjectionCache(from: [
            CADEntity(
                layerID: UUID(), localGeometry: nil,
                transform: .identity, xdata: xdata)
        ])
        XCTAssertEqual(back.exactViewports.count, 1)
        XCTAssertEqual(back.exactViewports[0].stableID, first.stableID)
    }

    func testLegacyContentFallsBackToNumberedKey() {
        var xdata: [String: XDataValue] = viewport().projectedXData([:])
        xdata.removeValue(forKey: "dxf.viewport.stableID")
        let back = DXFImporter.sheetProjectionCache(from: [
            CADEntity(
                layerID: UUID(), localGeometry: nil,
                transform: .identity, xdata: xdata)
        ])
        XCTAssertEqual(back.exactViewports.count, 1)
        XCTAssertEqual(
            back.exactViewports[0].stableID,
            ViewportIdentity.fallbackKey(viewportNumber: 2))
    }

    // MARK: - Override storage

    func testOverrideStorageSetClearAndPrune() {
        let (doc, layer) = makeLayer(name: "Walls")
        let key = ViewportIdentity.makeStableID()
        XCTAssertNil(doc.viewportOverride(viewportID: key, layer: layer.handle))

        doc.setViewportLayerFrozen(viewportID: key, layer: layer.handle, frozen: true)
        XCTAssertTrue(doc.isLayerFrozenInViewport(viewportID: key, layer: layer.handle))
        XCTAssertEqual(doc.viewportOverrideKeys, [key])

        let style = ViewportLayerOverride(
            color: ColorRGBA(r: 255, g: 0, b: 0), lineType: "dashed",
            lineWeight: 0.5, transparency: 30, plotStyleName: "Bold")
        doc.setViewportLayerOverride(viewportID: key, layer: layer.handle, override: style)
        let back = try? XCTUnwrap(doc.viewportOverride(viewportID: key, layer: layer.handle))
        XCTAssertEqual(back?.color, ColorRGBA(r: 255, g: 0, b: 0))
        XCTAssertEqual(back?.lineType, "dashed", "storage keeps the raw value; applied(to:) normalizes")
        XCTAssertEqual(back?.lineWeight, 0.5)
        XCTAssertEqual(back?.transparency, 30)
        XCTAssertEqual(back?.plotStyleName, "Bold")
        XCTAssertFalse(back?.frozen ?? true, "replace semantics: omitted frozen resets to false")

        doc.setViewportLayerOverride(
            viewportID: key, layer: layer.handle, override: ViewportLayerOverride())
        XCTAssertNil(doc.viewportOverride(viewportID: key, layer: layer.handle))
        XCTAssertTrue(doc.viewportLayerOverrides.isEmpty, "empty keys are pruned")

        doc.setViewportLayerFrozen(viewportID: key, layer: layer.handle, frozen: true)
        doc.pruneViewportOverrides(forDeletedLayer: layer.handle)
        XCTAssertTrue(doc.viewportLayerOverrides.isEmpty, "deleted layers are pruned")
    }

    func testAppliedToMapsStyleFields() {
        var base = Layer(name: "Base", color: .white, lineType: "CONTINUOUS")
        base.transparency = 0
        let override = ViewportLayerOverride(
            frozen: true,
            color: ColorRGBA(r: 1, g: 2, b: 3),
            colorSource: .aci(1),
            lineType: "hidden",
            lineWeight: 0.51,
            transparency: 95,
            plotStyleName: "  Fine  ")
        let applied = override.applied(to: base)
        XCTAssertEqual(applied.color, ColorRGBA(r: 1, g: 2, b: 3))
        XCTAssertEqual(applied.colorSource, .aci(1))
        XCTAssertEqual(applied.lineType, "HIDDEN")
        XCTAssertEqual(applied.lineWeight, 0.5, "snaps to the fixed set")
        XCTAssertEqual(applied.transparency, 90, "clamped to the AutoCAD cap")
        XCTAssertEqual(applied.plotStyleName, "Fine")
        XCTAssertEqual(base.color, .white, "base layer untouched")
    }

    // MARK: - Record codec

    func testRecordCodecRoundTrip() throws {
        let override = ViewportLayerOverride(
            frozen: true,
            color: ColorRGBA(r: 10, g: 20, b: 30),
            colorSource: .colorBook(name: "PANTONE|185=C;X"),
            lineType: "DASHED",
            lineWeight: 0.35,
            transparency: 40,
            plotStyleName: "Bold")
        let record = ViewportOverrideRecord.encode(layerName: "A|B=C;D\\E", override: override)
        XCTAssertTrue(record.hasPrefix(ViewportOverrideRecord.prefix))
        let decoded = try XCTUnwrap(ViewportOverrideRecord.decode(record))
        XCTAssertEqual(decoded.layerName, "A|B=C;D\\E", "escapes survive the round trip")
        XCTAssertEqual(decoded.override, override)
    }

    func testRecordCodecRejectsMalformed() {
        XCTAssertNil(ViewportOverrideRecord.decode("LAYER=X|F=1"))
        XCTAssertNil(ViewportOverrideRecord.decode("ZVP|F=1"))
        let decoded = ViewportOverrideRecord.decode("ZVP|LAYER=X|F=9|C=notacolor|TR=abc")
        XCTAssertEqual(decoded?.layerName, "X")
        XCTAssertTrue(decoded?.override.frozen ?? false, "nonzero F freezes")
        XCTAssertNil(decoded?.override.color)
        XCTAssertNil(decoded?.override.transparency)
    }

    // MARK: - Projection-aware rendering

    func testComputeSpecsExcludesViewportFrozenProjected() async throws {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        modelDoc.addEntity(line)
        let (sheetDoc, stableID, _) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        let native = lineEntity(layerID: modelLayer.handle)
        sheetDoc.addEntity(native)
        sheetDoc.setViewportLayerFrozen(
            viewportID: stableID, layer: modelLayer.handle, frozen: true)

        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: sheetDoc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1, "only the native copy draws")
        XCTAssertEqual(results.first?.handle, native.handle)

        let modelResults = await CADRendererBridge.computeSpecs(
            fromSnapshot: modelDoc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertEqual(modelResults.count, 1, "model space keeps drawing")
    }

    func testComputeSpecsAppliesViewportColorOverride() async throws {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        modelDoc.addEntity(line)
        let (sheetDoc, stableID, projected) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        sheetDoc.setViewportLayerOverride(
            viewportID: stableID, layer: modelLayer.handle,
            override: ViewportLayerOverride(color: ColorRGBA(r: 255, g: 0, b: 0)))

        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: sheetDoc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertEqual(spec.color.0, 255)
        XCTAssertEqual(spec.color.1, 0)
        XCTAssertEqual(spec.color.2, 0)
        XCTAssertEqual(results.first?.handle, projected.handle)

        let modelResults = await CADRendererBridge.computeSpecs(
            fromSnapshot: modelDoc.snapshot(), simplifyComplexBlocks: false)
        let modelSpec = try XCTUnwrap(modelResults.first?.specs.first)
        XCTAssertFalse(
            modelSpec.color.0 == 255 && modelSpec.color.1 == 0 && modelSpec.color.2 == 0,
            "global model entities keep the layer color")
    }

    // MARK: - Selection rules

    func testAccessHelpersHonorViewportFreeze() {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        modelDoc.addEntity(line)
        let (sheetDoc, stableID, projected) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        let sheetProjected = try? XCTUnwrap(sheetDoc.entity(for: projected.handle))
        XCTAssertNotNil(sheetProjected)
        guard let sheetEntity = sheetProjected else { return }

        XCTAssertTrue(LayerAccess.isPickable(entity: sheetEntity, in: sheetDoc))
        XCTAssertTrue(LayerAccess.isDrawn(entity: sheetEntity, in: sheetDoc))
        XCTAssertTrue(LayerAccess.isSnappable(entity: sheetEntity, in: sheetDoc))
        XCTAssertTrue(LayerAccess.isEditable(entity: sheetEntity, in: sheetDoc))
        XCTAssertTrue(LayerAccess.isRegenerated(entity: sheetEntity, in: sheetDoc))

        sheetDoc.setViewportLayerFrozen(
            viewportID: stableID, layer: modelLayer.handle, frozen: true)
        XCTAssertFalse(LayerAccess.isPickable(entity: sheetEntity, in: sheetDoc))
        XCTAssertFalse(LayerAccess.isDrawn(entity: sheetEntity, in: sheetDoc))
        XCTAssertFalse(LayerAccess.isSnappable(entity: sheetEntity, in: sheetDoc))
        XCTAssertFalse(LayerAccess.isEditable(entity: sheetEntity, in: sheetDoc))
        XCTAssertFalse(LayerAccess.isRegenerated(entity: sheetEntity, in: sheetDoc))
        XCTAssertFalse(LayerAccess.isPlottable(entity: sheetEntity, in: sheetDoc))

        let modelEntity = try? XCTUnwrap(modelDoc.entity(for: line.handle))
        XCTAssertNotNil(modelEntity)
        if let modelEntity {
            XCTAssertTrue(LayerAccess.isPickable(entity: modelEntity, in: modelDoc))
        }
    }

    func testRegenerationPlanExcludesViewportFrozen() {
        let (_, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        let (sheetDoc, stableID, projected) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        var plan = LayerAccess.regenerationPlan(snapshot: sheetDoc.snapshot())
        XCTAssertTrue(plan.regenerated.contains(projected.handle))
        sheetDoc.setViewportLayerFrozen(
            viewportID: stableID, layer: modelLayer.handle, frozen: true)
        plan = LayerAccess.regenerationPlan(snapshot: sheetDoc.snapshot())
        XCTAssertFalse(plan.regenerated.contains(projected.handle))
        XCTAssertFalse(plan.drawn.contains(projected.handle))
    }

    // MARK: - Plot output

    func testPlotCollectItemsSkipsViewportFrozen() {
        let (_, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        let (sheetDoc, stableID, projected) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        var items = PDFExporter.collectItems(document: sheetDoc)
        XCTAssertEqual(items.count, 1)

        sheetDoc.setViewportLayerFrozen(
            viewportID: stableID, layer: modelLayer.handle, frozen: true)
        items = PDFExporter.collectItems(document: sheetDoc)
        XCTAssertTrue(items.isEmpty, "viewport-frozen layers never reach plot output")
        _ = projected
    }

    func testPlotCollectItemsAppliesViewportColor() {
        let (_, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        let (sheetDoc, stableID, _) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        sheetDoc.setViewportLayerOverride(
            viewportID: stableID, layer: modelLayer.handle,
            override: ViewportLayerOverride(color: ColorRGBA(r: 0, g: 0, b: 255)))
        let items = PDFExporter.collectItems(document: sheetDoc)
        XCTAssertEqual(items.count, 1)
        if case .geometry(_, let color, _) = items[0] {
            XCTAssertEqual(
                color,
                ColorRGBA(r: 0, g: 0, b: 255).displayAdjusted(forLightBackground: false),
                "override color flows through the same paper contrast as layer colors")
        } else {
            XCTFail("expected a geometry plot item")
        }
    }

    // MARK: - EAB persistence

    func testEABRoundTripPreservesViewportOverrides() throws {
        let (_, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        let (sheetDoc, stableID, _) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        sheetDoc.setViewportLayerOverride(
            viewportID: stableID, layer: modelLayer.handle,
            override: ViewportLayerOverride(
                frozen: true,
                color: ColorRGBA(r: 9, g: 9, b: 9),
                lineType: "hidden",
                transparency: 20,
                plotStyleName: "Fine"))
        let otherKey = ViewportIdentity.makeStableID()
        sheetDoc.setViewportLayerFrozen(
            viewportID: otherKey, layer: modelLayer.handle, frozen: true)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp3_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try EABWriter.write(document: sheetDoc, to: tempURL)
        let views = try EABReader.readViews(from: tempURL)
        let back = try XCTUnwrap(views.first).document

        let frozen = try XCTUnwrap(
            back.viewportOverride(viewportID: stableID, layer: modelLayer.handle))
        XCTAssertTrue(frozen.frozen)
        XCTAssertEqual(frozen.color, ColorRGBA(r: 9, g: 9, b: 9))
        XCTAssertEqual(frozen.lineType, "hidden")
        XCTAssertEqual(frozen.transparency, 20)
        XCTAssertEqual(frozen.plotStyleName, "Fine")
        XCTAssertTrue(back.isLayerFrozenInViewport(viewportID: otherKey, layer: modelLayer.handle))
    }

    func testDeleteLayerPrunesOverridesWithUndo() {
        let (doc, layer) = makeLayer(name: "Walls")
        let key = ViewportIdentity.makeStableID()
        doc.setViewportLayerFrozen(viewportID: key, layer: layer.handle, frozen: true)
        XCTAssertFalse(doc.viewportLayerOverrides.isEmpty)
        doc.removeLayer(handle: layer.handle)
        XCTAssertTrue(doc.viewportLayerOverrides.isEmpty, "deleting a layer drops its deltas")
        doc.undo()
        XCTAssertTrue(
            doc.isLayerFrozenInViewport(viewportID: key, layer: layer.handle),
            "undo restores the layer and its viewport deltas together")
    }

    func testEABSectionParsesEmpty() {
        let w = BinaryWriter()
        w.writeUInt32(0)
        let back = EABReader.parseViewportOverrides(BinaryReader(data: w.build()))
        XCTAssertTrue(back.isEmpty)
    }

    // MARK: - DXF round trip

    func testDXFViewportRoundTrip331AndRecords() throws {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls")
        let line = lineEntity(layerID: modelLayer.handle)
        modelDoc.addEntity(line)
        let (sheetDoc, stableID, _) = sheetWithProjection(
            modelLine: line, modelLayer: modelLayer)
        sheetDoc.setViewportLayerOverride(
            viewportID: stableID, layer: modelLayer.handle,
            override: ViewportLayerOverride(
                frozen: true, color: ColorRGBA(r: 255, g: 0, b: 0)))

        let modelView = DrawingView(name: "Model", kind: .model, document: modelDoc)
        let sheetView = DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp3_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try DXFWriterBridge.export(views: [modelView, sheetView], to: tempURL)
        let text = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(text.contains("331"), "frozen layers ride as VIEWPORT 331 handles")
        XCTAssertTrue(text.contains("VPOVR:"), "style deltas ride as ZEPHYR_VP records")
        XCTAssertTrue(text.contains("VPSTABLEID:"), "stable identity rides as XDATA")
        XCTAssertTrue(text.contains("ZEPHYR_VP"), "appid is registered")

        let imported = try DXFImporter.importDXFViews(filePath: tempURL.path)
        let sheet = try XCTUnwrap(imported.views.first(where: { $0.kind == .sheet }))
        XCTAssertEqual(sheet.viewportOverrides.count, 1)
        let key = try XCTUnwrap(sheet.viewportOverrides.keys.first)
        let importedWalls = try XCTUnwrap(imported.layers.first(where: { $0.name == "Walls" }))
        let entry = try XCTUnwrap(sheet.viewportOverrides[key]?[importedWalls.handle.uuidString])
        XCTAssertTrue(entry.frozen, "331 restores the freeze")
        XCTAssertEqual(entry.color, ColorRGBA(r: 255, g: 0, b: 0), "VPOVR restores the color")
    }

    // MARK: - Viewport creation behavior

    func testCreateSheetViewportFreezesNewViewportLayers() throws {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls", freezeInNewViewports: true)
        modelDoc.addEntity(lineEntity(layerID: modelLayer.handle))
        let (sheetDoc, _, _) = sheetWithProjection(
            modelLine: lineEntity(layerID: modelLayer.handle), modelLayer: modelLayer)
        let manager = managerWithSheet(modelDoc: modelDoc, sheetDoc: sheetDoc)
        let before = manager.activeSheetViewports().count

        let newID = try XCTUnwrap(manager.createSheetViewport(
            paperX1: 20, paperY1: -8, paperX2: 32, paperY2: 8))
        XCTAssertEqual(manager.activeSheetViewports().count, before + 1)
        let created = try XCTUnwrap(
            manager.activeSheetViewports().first(where: { $0.id == newID }))
        XCTAssertFalse(created.stableID.isEmpty)
        XCTAssertTrue(
            sheetDoc.isLayerFrozenInViewport(
                viewportID: created.stableID, layer: modelLayer.handle),
            "freeze-in-new-viewport layers start frozen in created viewports")
        XCTAssertFalse(
            sheetDoc.isLayerFrozenInViewport(
                viewportID: created.stableID, layer: UUID()),
            "unknown layers report unfrozen")
    }

    func testSetViewportLayerFrozenHelper() throws {
        let (modelDoc, modelLayer) = makeLayer(name: "Walls")
        modelDoc.addEntity(lineEntity(layerID: modelLayer.handle))
        let (sheetDoc, _, _) = sheetWithProjection(
            modelLine: lineEntity(layerID: modelLayer.handle), modelLayer: modelLayer)
        let manager = managerWithSheet(modelDoc: modelDoc, sheetDoc: sheetDoc)
        let viewportID = try XCTUnwrap(manager.activeSheetViewports().first?.id)

        XCTAssertTrue(manager.setViewportLayerFrozen(
            viewportID: viewportID, layerNamed: "walls", frozen: true))
        let stableID = try XCTUnwrap(
            manager.activeSheetViewports().first(where: { $0.id == viewportID })?.stableID)
        XCTAssertTrue(
            sheetDoc.isLayerFrozenInViewport(viewportID: stableID, layer: modelLayer.handle))
        XCTAssertTrue(manager.setViewportLayerFrozen(
            viewportID: viewportID, layerNamed: "WALLS", frozen: false))
        XCTAssertFalse(
            sheetDoc.isLayerFrozenInViewport(viewportID: stableID, layer: modelLayer.handle))

        XCTAssertFalse(manager.setViewportLayerFrozen(
            viewportID: 9999, layerNamed: "Walls", frozen: true))
        XCTAssertFalse(manager.setViewportLayerFrozen(
            viewportID: viewportID, layerNamed: "NoSuchLayer", frozen: true))
    }
}
