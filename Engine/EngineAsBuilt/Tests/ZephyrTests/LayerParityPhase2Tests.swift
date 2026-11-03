import XCTest
@testable import ZephyrCore

/// Phase 2 layer-parity regressions: the shared `LayerAccess`/`LayerDisplayOptions`
/// resolver and its wiring through regeneration (off kept, frozen excluded),
/// picking (frozen/off excluded, locked kept), snapping (locked kept),
/// editing (locked refused), display toggles (lock fade, transparency,
/// lineweight), NoPlot/Defpoints enforcement, and CTB-vs-STB plot styles.
@MainActor
final class LayerParityPhase2Tests: XCTestCase {

    // MARK: - Fixtures

    private func lineEntity(layer: Layer, y: Double = 0) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: y, z: 0),
                end: Vector3(x: 10, y: y, z: 0),
                color: nil)])
    }

    private func docWithLayers(_ layers: [Layer]) -> CADDocument {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: layers, blocks: [], entities: [])
        return doc
    }

    private func plottedDoc() -> (CADDocument, [String: CADEntity]) {
        let normal = Layer(name: "Normal")
        let locked = Layer(name: "Locked", isLocked: true)
        var noplot = Layer(name: "NoPlot")
        noplot.isPlottable = false
        let defpoints = Layer(name: "Defpoints")
        let frozen = Layer(name: "Frozen", isFrozen: true)
        var off = Layer(name: "Off")
        off.isVisible = false
        let layers = [normal, locked, noplot, defpoints, frozen, off]
        let doc = docWithLayers(layers)
        var entities: [String: CADEntity] = [:]
        for (index, layer) in layers.enumerated() {
            let entity = lineEntity(layer: layer, y: Double(index) * 10)
            entities[layer.name] = entity
            doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [entity])
        }
        doc.rebuildEntityGrid()
        return (doc, entities)
    }

    // MARK: - Resolver matrix

    func testAccessMatrix() {
        let normal = Layer(name: "A")
        XCTAssertTrue(LayerAccess.isDrawn(normal))
        XCTAssertTrue(LayerAccess.isRegenerated(normal))
        XCTAssertTrue(LayerAccess.isPickable(normal))
        XCTAssertTrue(LayerAccess.isSnappable(normal))
        XCTAssertTrue(LayerAccess.isEditable(normal))
        XCTAssertTrue(LayerAccess.isPlottable(normal))

        var off = Layer(name: "B")
        off.isVisible = false
        XCTAssertFalse(LayerAccess.isDrawn(off))
        XCTAssertTrue(LayerAccess.isRegenerated(off), "off stays in regeneration")
        XCTAssertFalse(LayerAccess.isPickable(off))
        XCTAssertFalse(LayerAccess.isSnappable(off))
        XCTAssertFalse(LayerAccess.isEditable(off))
        XCTAssertTrue(LayerAccess.isPlottable(off), "no-plot flag is separate from on/off")

        let frozen = Layer(name: "C", isFrozen: true)
        XCTAssertFalse(LayerAccess.isDrawn(frozen))
        XCTAssertFalse(LayerAccess.isRegenerated(frozen))
        XCTAssertFalse(LayerAccess.isPickable(frozen))
        XCTAssertFalse(LayerAccess.isSnappable(frozen))
        XCTAssertFalse(LayerAccess.isEditable(frozen))
        XCTAssertTrue(LayerAccess.isPlottable(frozen), "frozen is excluded by drawn, not by plottable")

        let locked = Layer(name: "D", isLocked: true)
        XCTAssertTrue(LayerAccess.isDrawn(locked))
        XCTAssertTrue(LayerAccess.isRegenerated(locked))
        XCTAssertTrue(LayerAccess.isPickable(locked), "locked stays selectable")
        XCTAssertTrue(LayerAccess.isSnappable(locked), "locked keeps snaps")
        XCTAssertFalse(LayerAccess.isEditable(locked), "locked refuses edits")
        XCTAssertTrue(LayerAccess.isPlottable(locked))

        var noplot = Layer(name: "E")
        noplot.isPlottable = false
        XCTAssertTrue(LayerAccess.isDrawn(noplot))
        XCTAssertTrue(LayerAccess.isRegenerated(noplot))
        XCTAssertTrue(LayerAccess.isPickable(noplot))
        XCTAssertTrue(LayerAccess.isSnappable(noplot))
        XCTAssertTrue(LayerAccess.isEditable(noplot))
        XCTAssertFalse(LayerAccess.isPlottable(noplot))
    }

    func testDefpointsNeverPlots() {
        for name in ["Defpoints", "DEFPOINTS", "defpoints", " Defpoints "] {
            XCTAssertTrue(LayerAccess.isDefpointsLayerName(name), name)
            XCTAssertFalse(LayerAccess.isPlottable(Layer(name: name)), name)
        }
        XCTAssertFalse(LayerAccess.isDefpointsLayerName("Walls"))
        // Defpoints stays fully interactive on screen.
        let layer = Layer(name: "DEFPOINTS")
        XCTAssertTrue(LayerAccess.isDrawn(layer))
        XCTAssertTrue(LayerAccess.isPickable(layer))
        XCTAssertTrue(LayerAccess.isSnappable(layer))
        XCTAssertTrue(LayerAccess.isEditable(layer))
    }

    func testLockedFadeMultiplier() {
        let locked = Layer(name: "L", isLocked: true)
        let unlocked = Layer(name: "U")
        XCTAssertEqual(LayerAccess.lockedFadeMultiplier(layer: locked, fadePercent: 50), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LayerAccess.lockedFadeMultiplier(layer: locked, fadePercent: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(LayerAccess.lockedFadeMultiplier(layer: unlocked, fadePercent: 50), 1.0, accuracy: 1e-12)
        XCTAssertEqual(LayerAccess.lockedFadeMultiplier(layer: nil, fadePercent: 50), 1.0, accuracy: 1e-12)
        XCTAssertEqual(LayerAccess.lockedFadeMultiplier(layer: locked, fadePercent: 120), 0.1, accuracy: 1e-12)
        XCTAssertEqual(LayerDisplayOptions(lockFadePercent: 120).lockFadePercent, 90)
    }

    func testDisplayOptionsOpacityAndLineweight() {
        let shown = LayerDisplayOptions()
        XCTAssertEqual(shown.effectiveOpacity(layerOpacity: 0.5, entityOpacity: 1.0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(shown.effectiveLineWeight(0.35), 0.35, accuracy: 1e-12)
        let noTransparency = LayerDisplayOptions(transparencyShown: false)
        XCTAssertEqual(noTransparency.effectiveOpacity(layerOpacity: 0.5, entityOpacity: 0.5), 1.0, accuracy: 1e-12)
        let noLineweights = LayerDisplayOptions(lineweightsShown: false)
        XCTAssertEqual(noLineweights.effectiveLineWeight(0.35), 0.0, accuracy: 1e-12)
    }

    func testPlotPenResolution() {
        let black = PlotStylePen(name: "Color_7", colorARGB: 0xFF00_0000, colorPolicy: 5)
        let ctb = PlotStyleTable(
            kind: .ctb,
            pens: (1...8).map { i in
                i == 7 ? black : PlotStylePen(name: "Color_\(i)")
            })
        let layer = Layer(name: "Walls")
        XCTAssertEqual(
            LayerAccess.plotPen(layer: layer, objectACI: 7, pstyleMode: 1, table: ctb)?.name,
            "Color_7")
        XCTAssertNil(LayerAccess.plotPen(layer: layer, objectACI: 7, pstyleMode: 1, table: nil))

        let bold = PlotStylePen(name: "Bold", colorARGB: 0xFFFF_0000, colorPolicy: 5)
        let normal = PlotStylePen(name: "Normal")
        let stb = PlotStyleTable(kind: .stb, pens: [normal, bold])
        let boldLayer = Layer(name: "S1", plotStyleName: "Bold")
        XCTAssertEqual(
            LayerAccess.plotPen(layer: boldLayer, objectACI: 7, pstyleMode: 0, table: stb)?.name,
            "Bold")
        // Case-insensitive with a "Normal" fallback.
        let lower = Layer(name: "S2", plotStyleName: "bold")
        XCTAssertEqual(
            LayerAccess.plotPen(layer: lower, objectACI: 7, pstyleMode: 0, table: stb)?.name,
            "Bold")
        let unknown = Layer(name: "S3", plotStyleName: "No Such Style")
        XCTAssertEqual(
            LayerAccess.plotPen(layer: unknown, objectACI: 7, pstyleMode: 0, table: stb)?.name,
            "Normal")
        let blank = Layer(name: "S4", plotStyleName: "   ")
        XCTAssertEqual(
            LayerAccess.plotPen(layer: blank, objectACI: 7, pstyleMode: 0, table: stb)?.name,
            "Normal")
    }

    // MARK: - Regeneration

    func testRegenerationPlanKeepsOffExcludesFrozen() {
        let (doc, entities) = plottedDoc()
        let plan = LayerAccess.regenerationPlan(snapshot: doc.snapshot())
        XCTAssertEqual(
            plan.regenerated,
            Set(["Normal", "Locked", "NoPlot", "Defpoints", "Off"].compactMap { entities[$0]?.handle }))
        XCTAssertEqual(
            plan.drawn,
            Set(["Normal", "Locked", "NoPlot", "Defpoints"].compactMap { entities[$0]?.handle }))
    }

    func testComputeSpecsHidesOffExcludesFrozen() async {
        let (doc, entities) = plottedDoc()
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        let handles = Set(results.map(\.handle))
        XCTAssertTrue(handles.contains(entities["Normal"]!.handle))
        XCTAssertTrue(handles.contains(entities["Locked"]!.handle))
        XCTAssertFalse(handles.contains(entities["Off"]!.handle), "off regenerates but draws nothing")
        XCTAssertFalse(handles.contains(entities["Frozen"]!.handle))
        XCTAssertTrue(handles.contains(entities["NoPlot"]!.handle), "no-plot still draws on screen")
        XCTAssertTrue(handles.contains(entities["Defpoints"]!.handle))
    }

    func testLockedFadeDimsRenderedSpecs() async {
        let locked = Layer(name: "Locked", isLocked: true)
        let doc = docWithLayers([locked])
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [lineEntity(layer: locked)])
        let faded = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        let alphas = faded.flatMap { $0.specs.map { $0.color.3 } }
        XCTAssertFalse(alphas.isEmpty)
        XCTAssertTrue(alphas.allSatisfy { $0 == 127 }, "fade 50 -> alpha 127, got \(alphas)")
        doc.lockedLayerFadePercent = 0
        let unfaded = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertTrue(unfaded.flatMap { $0.specs.map { $0.color.3 } }.allSatisfy { $0 == 255 })
    }

    func testTransparencyDisplayToggle() async {
        let layer = Layer(name: "T", transparency: 50)
        let doc = docWithLayers([layer])
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [lineEntity(layer: layer)])
        let shown = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertTrue(shown.flatMap { $0.specs.map { $0.color.3 } }.allSatisfy { $0 == 127 })
        doc.transparencyDisplayEnabled = false
        let hidden = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        XCTAssertTrue(hidden.flatMap { $0.specs.map { $0.color.3 } }.allSatisfy { $0 == 255 })
    }

    func testDisplaySnapshotRoundTrip() {
        let doc = docWithLayers([Layer(name: "A")])
        XCTAssertEqual(doc.lockedLayerFadePercent, 50)
        XCTAssertTrue(doc.transparencyDisplayEnabled)
        XCTAssertTrue(doc.lineweightDisplayEnabled)
        doc.lockedLayerFadePercent = 70
        doc.transparencyDisplayEnabled = false
        doc.lineweightDisplayEnabled = false
        let snap = doc.snapshot()
        XCTAssertEqual(snap.layerDisplay.lockFadePercent, 70)
        XCTAssertFalse(snap.layerDisplay.transparencyShown)
        XCTAssertFalse(snap.layerDisplay.lineweightsShown)
        let restored = CADDocument()
        restored.restore(from: snap)
        XCTAssertEqual(restored.lockedLayerFadePercent, 70)
        XCTAssertFalse(restored.transparencyDisplayEnabled)
        XCTAssertFalse(restored.lineweightDisplayEnabled)
        // Clamp follows the document contract.
        restored.lockedLayerFadePercent = 200
        XCTAssertEqual(restored.lockedLayerFadePercent, 90)
    }

    // MARK: - Selection

    func testHitTestIncludesLockedExcludesFrozenAndOff() {
        let (doc, entities) = plottedDoc()
        XCTAssertEqual(
            CADHitTesting.hitTest(worldX: 5, worldY: 0, document: doc, threshold: 2.0),
            entities["Normal"]?.handle)
        XCTAssertEqual(
            CADHitTesting.hitTest(worldX: 5, worldY: 10, document: doc, threshold: 2.0),
            entities["Locked"]?.handle,
            "locked layers stay pickable")
        XCTAssertNil(CADHitTesting.hitTest(worldX: 5, worldY: 40, document: doc, threshold: 2.0))
        XCTAssertNil(CADHitTesting.hitTest(worldX: 5, worldY: 50, document: doc, threshold: 2.0))
    }

    func testSelectAllSkipsOffAndFrozenKeepsLocked() {
        let (doc, entities) = plottedDoc()
        let selection = CADSelectionManager()
        selection.selectAll(in: doc)
        XCTAssertEqual(
            selection.selectedHandles,
            Set(["Normal", "Locked", "NoPlot", "Defpoints"].compactMap { entities[$0]?.handle }))
    }

    func testEntityFilterVisibility() {
        let (doc, entities) = plottedDoc()
        XCTAssertTrue(EntityFilter.isVisibleForSelection(entities["Normal"]!, in: doc))
        XCTAssertTrue(EntityFilter.isVisibleForSelection(entities["Locked"]!, in: doc))
        XCTAssertFalse(EntityFilter.isVisibleForSelection(entities["Frozen"]!, in: doc))
        XCTAssertFalse(EntityFilter.isVisibleForSelection(entities["Off"]!, in: doc))
        doc.hideEntitiesIsolated([entities["Normal"]!.handle])
        XCTAssertFalse(EntityFilter.isVisibleForSelection(entities["Normal"]!, in: doc))
    }

    func testRectSelectSkipsFrozenAndOff() {
        let (doc, entities) = plottedDoc()
        let handles = CADRectSelect.handlesInRect(
            worldX: -5, worldY: -5, worldW: 20, worldH: 70,
            document: doc, style: .window)
        XCTAssertEqual(
            handles,
            Set(["Normal", "Locked", "NoPlot", "Defpoints"].compactMap { entities[$0]?.handle }))
    }

    // MARK: - Editing

    func testLockedLayerRefusesEdits() {
        let (doc, entities) = plottedDoc()
        XCTAssertTrue(LayerAccess.isEditable(entity: entities["Normal"]!, in: doc))
        XCTAssertFalse(LayerAccess.isEditable(entity: entities["Locked"]!, in: doc))
        XCTAssertFalse(LayerAccess.isEditable(entity: entities["Frozen"]!, in: doc))
        XCTAssertFalse(LayerAccess.isEditable(entity: entities["Off"]!, in: doc))
        let orphan = CADEntity(layerID: UUID(), localGeometry: [])
        XCTAssertFalse(LayerAccess.isEditable(entity: orphan, in: doc))
        // Picking and snapping still work on the locked entity.
        XCTAssertTrue(LayerAccess.isPickable(entity: entities["Locked"]!, in: doc))
        XCTAssertTrue(LayerAccess.isSnappable(entity: entities["Locked"]!, in: doc))
        XCTAssertFalse(LayerAccess.isSnappable(entity: entities["Frozen"]!, in: doc))
        XCTAssertFalse(LayerAccess.isRegenerated(entity: entities["Frozen"]!, in: doc))
        XCTAssertTrue(LayerAccess.isRegenerated(entity: entities["Off"]!, in: doc))
        XCTAssertFalse(LayerAccess.isDrawn(entity: entities["Off"]!, in: doc))
    }

    // MARK: - Plot / PDF

    func testCollectItemsEnforcesNoPlotDefpointsAndFrozen() {
        let (doc, entities) = plottedDoc()
        let items = PDFExporter.collectItems(document: doc)
        var handles = Set<UUID>()
        for item in items {
            if case .geometry(let entity, _, _) = item { handles.insert(entity.handle) }
        }
        XCTAssertEqual(
            handles,
            Set(["Normal", "Locked"].compactMap { entities[$0]?.handle }),
            "only drawn + plottable layers reach the plotter, got \(handles)")
    }

    func testApplyPlotStylesSTBResolvesByName() {
        let bold = Layer(name: "S1", plotStyleName: "Bold")
        let plain = Layer(name: "S2")
        let doc = docWithLayers([bold, plain])
        doc.pstyleMode = 0
        doc.importLayersBlocksEntities(
            layers: [], blocks: [],
            entities: [lineEntity(layer: bold), lineEntity(layer: plain)])
        var settings = CADPlotSettings()
        settings.plotFlags |= 32
        let table = PlotStyleTable(kind: .stb, pens: [
            PlotStylePen(name: "Normal"),
            PlotStylePen(name: "Bold", colorARGB: 0xFFFF_0000, colorPolicy: 5),
        ])
        let items = PDFExporter.collectItems(document: doc)
        let styled = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: settings, plotTable: table)
        var colors: [UUID: (UInt8, UInt8, UInt8)] = [:]
        for item in styled {
            if case .geometry(let entity, let color, _) = item {
                colors[entity.handle] = (color.r, color.g, color.b)
            }
        }
        let boldEntity = doc.entitiesView.first { $0.layerID == bold.handle }!
        let plainEntity = doc.entitiesView.first { $0.layerID == plain.handle }!
        XCTAssertEqual(colors[boldEntity.handle]?.0, 255)
        XCTAssertEqual(colors[boldEntity.handle]?.1, 0)
        XCTAssertEqual(colors[boldEntity.handle]?.2, 0)
        XCTAssertEqual(colors[plainEntity.handle]?.0, 255)
        XCTAssertEqual(colors[plainEntity.handle]?.1, 255)
        XCTAssertEqual(colors[plainEntity.handle]?.2, 255)
    }

    func testApplyPlotStylesCTBResolvesByACI() {
        let walls = Layer(name: "Walls", color: .white)
        let doc = docWithLayers([walls])
        doc.pstyleMode = 1
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: [lineEntity(layer: walls)])
        var settings = CADPlotSettings()
        settings.plotFlags |= 32
        let table = PlotStyleTable(
            kind: .ctb,
            pens: (1...8).map { i in
                PlotStylePen(
                    name: "Color_\(i)", colorARGB: 0xFF00_0000,
                    colorPolicy: 5, screeningPercent: 100)
            })
        let items = PDFExporter.collectItems(document: doc)
        let styled = PDFExporter.applyPlotStyles(
            items: items, document: doc, settings: settings, plotTable: table)
        for item in styled {
            if case .geometry(_, let color, _) = item {
                XCTAssertEqual(color.r, 0)
                XCTAssertEqual(color.g, 0)
                XCTAssertEqual(color.b, 0)
            }
        }
        XCTAssertFalse(styled.isEmpty)
    }
}
