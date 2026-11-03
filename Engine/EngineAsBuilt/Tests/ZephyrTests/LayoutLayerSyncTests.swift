import XCTest
@testable import ZephyrCore

/// Layout views must apply line-color overrides from layers: layers are
/// drawing-global in AutoCAD, so a layer color edit in one view has to
/// reach every sibling view (each view document keeps its own layer copy).
/// Without reconciliation a change made in Model never reaches Layout1 —
/// sheets keep rendering (and saving) stale layer colors.
final class LayoutLayerSyncTests: XCTestCase {

    private func makeDocs() -> (model: CADDocument, sheet: CADDocument, layerID: UUID) {
        let layerID = UUID()
        let model = CADDocument()
        model.importLayersBlocksEntities(
            layers: [Layer(handle: layerID, name: "Hatch", color: .white)],
            blocks: [], entities: [])
        let sheet = CADDocument()
        sheet.importLayersBlocksEntities(
            layers: [Layer(handle: layerID, name: "Hatch", color: .white)],
            blocks: [], entities: [])
        return (model, sheet, layerID)
    }

    private func makeTab(model: CADDocument, sheet: CADDocument) -> DocumentTab {
        DocumentTab(
            document: model,
            displayName: "Sync",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: model),
                DrawingView(name: "Layout1", kind: .sheet, document: sheet),
            ])
    }

    private func byLayerLine(layerID: UUID) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0),
                color: nil)],
            transform: .identity)
    }

    // MARK: - Reconciliation

    func testReconcilePropagatesLayerColorToSheet() {
        let docs = makeDocs()
        let tab = makeTab(model: docs.model, sheet: docs.sheet)
        docs.model.setLayerColor(docs.layerID, color: .yellow)

        XCTAssertEqual(docs.sheet.layer(for: docs.layerID)?.color, .white,
                       "precondition: sheet copy is stale before reconciliation")
        let sheetRevision = docs.sheet.editRevision
        tab.reconcileLayersFromActiveView()

        XCTAssertEqual(tab.drawingViews[1].document.layer(for: docs.layerID)?.color, .yellow,
                       "active view layer color must reach the sheet")
        XCTAssertEqual(docs.sheet.editRevision, sheetRevision,
                       "reconciliation is render-only: it must not dirty the sheet")
    }

    func testReconcileKeepsSiblingOnlyLayers() {
        let docs = makeDocs()
        let tab = makeTab(model: docs.model, sheet: docs.sheet)
        // Paper-only layer owned by the sheet.
        docs.sheet.importLayersBlocksEntities(
            layers: [Layer(name: "TitleBlock", color: .green)],
            blocks: [], entities: [])
        docs.model.setLayerColor(docs.layerID, color: .yellow)

        tab.reconcileLayersFromActiveView()

        XCTAssertEqual(docs.sheet.layer(for: docs.layerID)?.color, .yellow)
        XCTAssertNotNil(docs.sheet.allLayers.first(where: { $0.name == "TitleBlock" }),
                        "merge must not delete layers owned only by the sibling")
    }

    @MainActor
    func testSwitchToViewPropagatesLayerColor() {
        let docs = makeDocs()
        let manager = TabManager()
        manager.addTab(makeTab(model: docs.model, sheet: docs.sheet))
        docs.model.setLayerColor(docs.layerID, color: .yellow)

        XCTAssertTrue(manager.switchToView(at: 1))
        XCTAssertEqual(docs.sheet.layer(for: docs.layerID)?.color, .yellow,
                       "activating Layout1 must pick up the Model layer color")
    }

    // MARK: - Rendering

    func testSheetSpecsUseCurrentLayerColor() async throws {
        let docs = makeDocs()
        docs.model.addEntity(byLayerLine(layerID: docs.layerID))
        docs.sheet.addEntity(byLayerLine(layerID: docs.layerID))
        docs.model.setLayerColor(docs.layerID, color: .yellow)
        docs.sheet.adoptLayers(from: docs.model)

        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.sheet.snapshot(), simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertEqual(spec.color.0, 255)
        XCTAssertEqual(spec.color.1, 255)
        XCTAssertEqual(spec.color.2, 0)
    }

    /// Explicit per-entity colors (e.g. an ACI-31 hatch line on a white
    /// layer) keep winning over the layer color in sheet views.
    func testSheetKeepsExplicitEntityColorOverLayer() async throws {
        let docs = makeDocs()
        let salmon = ColorRGBA(r: 255, g: 191, b: 128)
        var line = byLayerLine(layerID: docs.layerID)
        line.localGeometry = [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0),
            color: salmon)]
        line.xdata["dxf.color"] = .string("#FFBF80")
        docs.sheet.addEntity(line)

        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.sheet.snapshot(), simplifyComplexBlocks: false)
        XCTAssertEqual(results.count, 1)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertEqual(spec.color.0, 255)
        XCTAssertEqual(spec.color.1, 191)
        XCTAssertEqual(spec.color.2, 128)
    }

    // MARK: - Sheet pixel colors match AutoCAD

    /// The GPU draws precomputed adjusted colors: on a light sheet
    /// background the pixel must equal the authored explicit color
    /// (AutoCAD shows entity/layer colors raw on white paper and only
    /// maps white itself to black). This is the reported symptom: the
    /// Layout1 hatch (explicit ACI 31) must not render dark.
    func testSheetPixelKeepsExplicitColorOnLightBackground() async throws {
        let docs = makeDocs()
        let salmon = ColorRGBA(r: 255, g: 191, b: 128)
        var line = byLayerLine(layerID: docs.layerID)
        line.localGeometry = [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0),
            color: salmon)]
        line.xdata["dxf.color"] = .string("#FFBF80")
        docs.sheet.addEntity(line)

        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.sheet.snapshot(), simplifyComplexBlocks: false)
        let spec = try XCTUnwrap(results.first?.specs.first)
        let pixel = ColorRGBA(r: spec.color.0, g: spec.color.1, b: spec.color.2, a: spec.color.3)
            .displayAdjusted(forLightBackground: true)
        XCTAssertEqual(pixel, salmon)
    }

    func testLightBackgroundKeepsBrightColorsRaw() {
        // The reported hatch color and pure yellow render as authored.
        XCTAssertEqual(
            ColorRGBA(r: 255, g: 191, b: 128).displayAdjusted(forLightBackground: true),
            ColorRGBA(r: 255, g: 191, b: 128))
        XCTAssertEqual(
            ColorRGBA.yellow.displayAdjusted(forLightBackground: true), .yellow)
        XCTAssertEqual(
            ColorRGBA(r: 0, g: 255, b: 0).displayAdjusted(forLightBackground: true), .green)
        // Near-white still maps to charcoal so it stays visible on paper.
        XCTAssertEqual(
            ColorRGBA.white.displayAdjusted(forLightBackground: true),
            ColorRGBA(r: 24, g: 24, b: 24))
    }

    func testDarkBackgroundBehaviorUnchanged() {
        XCTAssertEqual(
            ColorRGBA.black.displayAdjusted(forLightBackground: false),
            ColorRGBA(r: 115, g: 115, b: 115))
        XCTAssertEqual(
            ColorRGBA(r: 255, g: 191, b: 128).displayAdjusted(forLightBackground: false),
            ColorRGBA(r: 255, g: 191, b: 128))
    }

    // MARK: - ACI vs TrueColor source tracking

    /// The importer records HOW an explicit color was specified (ACI
    /// index vs 24-bit TrueColor) so later stages can tell explicit white
    /// apart from ACI 7 (AutoCAD parity: only ACI white inverts).
    func testImporterRecordsEntityColorSource() throws {
        let dxfContent = """
          0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        0
         62
         31
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10.0
         21
        0.0
         31
        0.0
          0
        LINE
          8
        0
         420
         16777215
         10
        0.0
         20
        0.0
         30
        0.0
         11
        10.0
         21
        0.0
         31
        0.0
          0
        ENDSEC
          0
        EOF
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_color_source_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try dxfContent.write(to: tempURL, atomically: true, encoding: .utf8)
        let imported = try DXFImporter.importDXFViews(filePath: tempURL.path)
        XCTAssertEqual(imported.entities.count, 2)
        let byHex = Dictionary(uniqueKeysWithValues: imported.entities.compactMap { e -> (String, CADEntity)? in
            guard case .string(let hex)? = e.xdata["dxf.color"] else { return nil }
            return (hex, e)
        })
        let aciLine = try XCTUnwrap(byHex["#FFBF80"])
        if case .int(let index)? = aciLine.xdata["dxf.colorIndex"] {
            XCTAssertEqual(index, 31)
        } else {
            XCTFail("ACI entity must record dxf.colorIndex")
        }
        XCTAssertNil(aciLine.xdata["dxf.color24"])
        let trueLine = try XCTUnwrap(byHex["#FFFFFF"])
        if case .int(let rgb)? = trueLine.xdata["dxf.color24"] {
            XCTAssertEqual(rgb, 16777215)
        } else {
            XCTFail("TrueColor entity must record dxf.color24")
        }
        XCTAssertNil(trueLine.xdata["dxf.colorIndex"])
    }

    /// Explicit TrueColor white renders raw on light backgrounds
    /// (AutoCAD shows it as-is, invisible on white paper) instead of
    /// inverting to charcoal like ACI 7 does.
    func testTrueColorWhiteRendersRawOnLightBackground() async throws {
        let docs = makeDocs()
        var line = byLayerLine(layerID: docs.layerID)
        line.localGeometry = [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0),
            color: .white)]
        line.xdata["dxf.color"] = .string("#FFFFFF")
        line.xdata["dxf.color24"] = .int(16777215)
        line.xdata["dxf.isTrueColor"] = .int(1)
        docs.sheet.addEntity(line)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.sheet.snapshot(), simplifyComplexBlocks: false)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertTrue(spec.isTrueColor)
        let pixel = ColorRGBA(r: spec.color.0, g: spec.color.1, b: spec.color.2, a: spec.color.3)
            .displayAdjusted(forLightBackground: true, isTrueColor: spec.isTrueColor)
        XCTAssertEqual(pixel, .white)
    }

    /// Explicit ACI 7 still inverts to charcoal on light backgrounds.
    func testAciSevenInvertsOnLightBackground() async throws {
        let docs = makeDocs()
        var line = byLayerLine(layerID: docs.layerID)
        line.localGeometry = [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0),
            color: .white)]
        line.xdata["dxf.color"] = .string("#FFFFFF")
        line.xdata["dxf.colorIndex"] = .int(7)
        docs.sheet.addEntity(line)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.sheet.snapshot(), simplifyComplexBlocks: false)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertFalse(spec.isTrueColor)
        let pixel = ColorRGBA(r: spec.color.0, g: spec.color.1, b: spec.color.2, a: spec.color.3)
            .displayAdjusted(forLightBackground: true, isTrueColor: spec.isTrueColor)
        XCTAssertEqual(pixel, ColorRGBA(r: 24, g: 24, b: 24))
    }

    /// ByLayer on a TrueColor white layer renders raw (the layer source
    /// is known explicit RGB, not ACI 7).
    func testByLayerOnTrueColorWhiteLayerRendersRaw() async throws {
        let model = CADDocument()
        let layerID = UUID()
        model.importLayersBlocksEntities(
            layers: [Layer(handle: layerID, name: "TC", color: .white, colorSource: .trueColor)],
            blocks: [], entities: [])
        model.addEntity(byLayerLine(layerID: layerID))
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: model.snapshot(), simplifyComplexBlocks: false)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertTrue(spec.isTrueColor)
        let pixel = ColorRGBA(r: spec.color.0, g: spec.color.1, b: spec.color.2, a: spec.color.3)
            .displayAdjusted(forLightBackground: true, isTrueColor: spec.isTrueColor)
        XCTAssertEqual(pixel, .white)
    }

    /// ByLayer on a default (ACI 7) white layer still inverts.
    func testByLayerOnAciWhiteLayerInverts() async throws {
        let docs = makeDocs()
        XCTAssertEqual(docs.model.layer(for: docs.layerID)?.colorSource, .aci(7))
        docs.model.addEntity(byLayerLine(layerID: docs.layerID))
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: docs.model.snapshot(), simplifyComplexBlocks: false)
        let spec = try XCTUnwrap(results.first?.specs.first)
        XCTAssertFalse(spec.isTrueColor)
        let pixel = ColorRGBA(r: spec.color.0, g: spec.color.1, b: spec.color.2, a: spec.color.3)
            .displayAdjusted(forLightBackground: true, isTrueColor: spec.isTrueColor)
        XCTAssertEqual(pixel, ColorRGBA(r: 24, g: 24, b: 24))
    }

    /// The GPU primitive carries the source flag through and resolves
    /// the light palette accordingly (covers both init-time and
    /// post-init flag paths used by the vertex upload).
    func testRenderPrimitiveTrueColorWhiteStaysRaw() {
        let id = SpriteID(id1: 1, id2: 2)
        let prim = RenderPrimitive(
            id: id, type: .line, z: 0,
            color: (255, 255, 255, 255),
            isScreenSpace: false, isTrueColor: true)
        XCTAssertEqual(prim.adjustedColorLight.0, 255)
        XCTAssertEqual(prim.adjustedColorLight.1, 255)
        XCTAssertEqual(prim.adjustedColorLight.2, 255)
        prim.isTrueColor = false
        prim.color = (255, 255, 255, 255)
        XCTAssertEqual(prim.adjustedColorLight.0, 24)
        let aci = RenderPrimitive(
            id: id, type: .line, z: 0,
            color: (255, 255, 255, 255),
            isScreenSpace: false)
        XCTAssertEqual(aci.adjustedColorLight.0, 24)
        XCTAssertEqual(aci.adjustedColorDark.0, 255)
    }
}
