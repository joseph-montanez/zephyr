import XCTest
@testable import ZephyrCore

/// Unit 0 (xref plan): per-primitive style-layer visibility must govern
/// rendering, hit-testing, rectangle selection, zoom-extents bounds, and
/// PDF output; COPY must share named block definitions.
@MainActor
final class PrimitiveLayerVisibilityTests: XCTestCase {

    /// Document with one block holding two lines on two different style
    /// layers, one instance on a visible host layer.
    /// Line 0 (y=0) is on "Shown", line 1 (y=10) is on "Hidden".
    private func makeFixture(hiddenVisible: Bool) -> (doc: CADDocument, entity: CADEntity, block: CADBlock) {
        let doc = CADDocument()
        let host = Layer(name: "Host", color: .white)
        let shown = Layer(name: "Shown", color: .white)
        var hidden = Layer(name: "Hidden", color: .white)
        hidden.isVisible = hiddenVisible
        let geom: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 10, y: 0, z: 0), color: nil),
            .line(start: Vector3(x: 0, y: 10, z: 0), end: Vector3(x: 10, y: 10, z: 0), color: nil),
        ]
        let block = CADBlock(
            name: "TwoLayerBlock",
            geometry: geom,
            primitiveStyles: [
                0: CADPrimitiveStyle(layerName: "Shown"),
                1: CADPrimitiveStyle(layerName: "Hidden"),
            ])
        let entity = CADEntity(layerID: host.handle, blockID: block.handle, transform: .identity)
        doc.importLayersBlocksEntities(layers: [host, shown, hidden], blocks: [block], entities: [entity])
        doc.rebuildEntityGrid()
        return (doc, entity, block)
    }

    func testComputeSpecsSkipsHiddenStyleLayerPrimitives() async {
        let (doc, entity, _) = makeFixture(hiddenVisible: false)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        let result = results.first { $0.handle == entity.handle }
        XCTAssertNotNil(result)
        // Exactly one line (the "Shown" one at y=0) may produce specs.
        let ys = Set((result?.specs ?? []).flatMap { $0.points.map { $0.y } })
        XCTAssertTrue(ys.contains(0), "visible line specs missing: \(ys)")
        XCTAssertFalse(ys.contains(10), "hidden-layer line produced specs: \(ys)")
    }

    func testComputeSpecsIncludesBothWhenVisible() async {
        let (doc, entity, _) = makeFixture(hiddenVisible: true)
        let results = await CADRendererBridge.computeSpecs(
            fromSnapshot: doc.snapshot(), simplifyComplexBlocks: false)
        let result = results.first { $0.handle == entity.handle }
        let ys = Set((result?.specs ?? []).flatMap { $0.points.map { $0.y } })
        XCTAssertTrue(ys.contains(0) && ys.contains(10), "expected both lines, got \(ys)")
    }

    func testHitTestMissesHiddenPrimitiveHitsVisible() {
        let (doc, entity, _) = makeFixture(hiddenVisible: false)
        let hitShown = CADHitTesting.hitTest(
            worldX: 5, worldY: 0, document: doc, threshold: 0.5, simplifyComplexBlocks: false)
        XCTAssertEqual(hitShown, entity.handle)
        let hitHidden = CADHitTesting.hitTest(
            worldX: 5, worldY: 10, document: doc, threshold: 0.5, simplifyComplexBlocks: false)
        XCTAssertNil(hitHidden, "hidden-layer primitive must not be hit")
    }

    func testHitEntitySimplifyPathRespectsAllHidden() {
        // Block whose only primitives are on the hidden layer: the
        // bounding-box (simplify) hit path must also miss.
        let doc = CADDocument()
        let host = Layer(name: "Host", color: .white)
        var hidden = Layer(name: "Hidden", color: .white)
        hidden.isVisible = false
        let geom: [CADPrimitive] = (0..<60).map { i in
            .line(start: Vector3(x: 0, y: Double(i), z: 0),
                  end: Vector3(x: 10, y: Double(i), z: 0), color: nil)
        }
        let styles = Dictionary(uniqueKeysWithValues: geom.indices.map {
            ($0, CADPrimitiveStyle(layerName: "Hidden"))
        })
        let block = CADBlock(name: "AllHidden", geometry: geom, primitiveStyles: styles)
        let entity = CADEntity(layerID: host.handle, blockID: block.handle, transform: .identity)
        doc.importLayersBlocksEntities(layers: [host, hidden], blocks: [block], entities: [entity])
        let hit = CADHitTesting.hitEntity(
            entity, point: Vector3(x: 5, y: 5, z: 0), threshold: 0.5,
            document: doc, simplifyComplexBlocks: true)
        XCTAssertFalse(hit, "all-hidden block must not hit via bbox path")
    }

    func testRectSelectCrossingSkipsHiddenPrimitive() {
        let (doc, entity, _) = makeFixture(hiddenVisible: false)
        // Crossing rect tightly around the hidden line only.
        let inHidden = CADRectSelect.entityIntersectsRect(
            entity,
            rectMin: Vector3(x: 4, y: 9.5, z: 0),
            rectMax: Vector3(x: 6, y: 10.5, z: 0),
            document: doc)
        XCTAssertFalse(inHidden)
        let inShown = CADRectSelect.entityIntersectsRect(
            entity,
            rectMin: Vector3(x: 4, y: -0.5, z: 0),
            rectMax: Vector3(x: 6, y: 0.5, z: 0),
            document: doc)
        XCTAssertTrue(inShown)
    }

    func testRenderableBoundsHonorStyleLayerVisibility() {
        let (doc, _, _) = makeFixture(hiddenVisible: false)
        let bounds = doc.renderableWorldBoundingBox(visibleLayersOnly: true)
        XCTAssertNotNil(bounds)
        XCTAssertEqual(bounds?.max.y ?? .infinity, 0, accuracy: 1e-9,
                       "hidden line at y=10 must not extend visible bounds")
        let all = doc.renderableWorldBoundingBox(visibleLayersOnly: false)
        XCTAssertEqual(all?.max.y ?? 0, 10, accuracy: 1e-9)
    }

    func testSnapTier3SkipsHiddenPrimitive() {
        let (doc, entity, _) = makeFixture(hiddenVisible: false)
        let engine = SnapEngine()
        // Cursor directly over the hidden line's midpoint area, offset so
        // no discrete anchor is in range: Tier-3 must not snap to it.
        let snap = engine.nearestSnap(
            worldX: 5.3, worldY: 10.2,
            entities: [entity],
            threshold: 1.0,
            resolveGeometry: { doc.resolvedGeometry(for: $0) },
            primitiveVisibility: { doc.primitiveVisibility(for: $0) })
        if let snap {
            XCTAssertGreaterThan(abs(snap.worldPos.y - 10), 0.5,
                                 "snapped onto hidden primitive at \(snap.worldPos)")
        }
    }

    // MARK: - COPY / duplicate semantics

    func testDuplicateNamedBlockSharesBlockID() {
        let (doc, entity, block) = makeFixture(hiddenVisible: true)
        let result = doc.duplicateEntities(handles: [entity.handle])
        XCTAssertEqual(result.entities.count, 1)
        XCTAssertEqual(result.entities.first?.blockID, block.handle,
                       "named block copies must share the definition")
        XCTAssertNil(result.blockRemap[block.handle],
                     "named blocks must not be remapped/cloned")
    }

    func testEffectiveLayerUppercasedNormalization() {
        XCTAssertNil(CADPrimitiveStyle(layerName: nil).effectiveLayerUppercased)
        XCTAssertNil(CADPrimitiveStyle(layerName: "").effectiveLayerUppercased)
        XCTAssertNil(CADPrimitiveStyle(layerName: "   ").effectiveLayerUppercased)
        XCTAssertNil(CADPrimitiveStyle(layerName: "0").effectiveLayerUppercased)
        XCTAssertNil(CADPrimitiveStyle(layerName: " 0 ").effectiveLayerUppercased)
        XCTAssertEqual(CADPrimitiveStyle(layerName: "Walls").effectiveLayerUppercased, "WALLS")
        XCTAssertEqual(CADPrimitiveStyle(layerName: "  walls ").effectiveLayerUppercased, "WALLS")
    }

    func testEffectiveLayerUppercasedFollowsMutation() {
        var style = CADPrimitiveStyle(layerName: "Walls")
        XCTAssertEqual(style.effectiveLayerUppercased, "WALLS")
        style.layerName = "  Doors "
        XCTAssertEqual(style.effectiveLayerUppercased, "DOORS")
        XCTAssertEqual(style.effectiveLayerName, "Doors")
        style.layerName = "0"
        XCTAssertNil(style.effectiveLayerUppercased)
        XCTAssertNil(style.effectiveLayerName)
    }

    func testLayersByUppercasedNameReflectsRenameAndVisibility() {
        let doc = CADDocument()
        let walls = Layer(name: "Walls", color: .white)
        doc.importLayersBlocksEntities(layers: [walls], blocks: [], entities: [])
        XCTAssertNotNil(doc.layersByUppercasedName()["WALLS"])
        doc.renameLayer(handle: walls.handle, name: "Partitions")
        XCTAssertNil(doc.layersByUppercasedName()["WALLS"])
        XCTAssertNotNil(doc.layersByUppercasedName()["PARTITIONS"])
        doc.setLayerVisible(walls.handle, visible: false)
        XCTAssertEqual(doc.layersByUppercasedName()["PARTITIONS"]?.isVisible, false)
        // Cached callers must see the same dictionary contents on repeat reads.
        XCTAssertEqual(doc.layersByUppercasedName(), doc.layersByUppercasedName())
    }

    func testDuplicateAnonymousBlockClonesWithStyles() {
        let doc = CADDocument()
        let host = Layer(name: "Host", color: .white)
        let geom: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 5, y: 0, z: 0), color: nil)
        ]
        let block = CADBlock(
            name: "*D12", geometry: geom,
            primitiveStyles: [0: CADPrimitiveStyle(layerName: "Dims", lineWeight: 0.5)],
            primitiveXData: [0: ["dxf.test": .string("v")]],
            dxfFlags: 1)
        let entity = CADEntity(layerID: host.handle, blockID: block.handle, transform: .identity)
        doc.importLayersBlocksEntities(layers: [host], blocks: [block], entities: [entity])

        let result = doc.duplicateEntities(handles: [entity.handle])
        let newBlockID = result.blockRemap[block.handle]
        XCTAssertNotNil(newBlockID, "anonymous blocks must still clone")
        XCTAssertEqual(result.entities.first?.blockID, newBlockID)
        let cloned = result.clonedBlocks.first { $0.handle == newBlockID }
        XCTAssertNotNil(cloned, "duplicateEntities must vend the cloned blocks")
        XCTAssertEqual(cloned?.primitiveStyles[0]?.layerName, "Dims")
        XCTAssertEqual(cloned?.primitiveStyles[0]?.lineWeight, 0.5)
        XCTAssertEqual(cloned?.primitiveXData[0]?["dxf.test"], XDataValue.string("v"))
        XCTAssertEqual(cloned?.dxfFlags, 1)
    }

    func testRenderableBoundsCacheRefreshesOnEdit() {
        // Repeated reads must agree (cache hit); edits must be reflected
        // (revision-keyed invalidation) so zoom-extents never goes stale.
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let first = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: nil)],
            transform: .identity)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [first])
        let b1 = doc.renderableWorldBoundingBox()
        let b1again = doc.renderableWorldBoundingBox()
        XCTAssertNotNil(b1)
        XCTAssertEqual(b1?.max.x, b1again?.max.x)
        XCTAssertEqual(b1?.min.x, b1again?.min.x)
        let far = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 100, y: 0, z: 0),
                end: Vector3(x: 110, y: 0, z: 0), color: nil)],
            transform: .identity)
        doc.addEntity(far)
        let b2 = doc.renderableWorldBoundingBox()
        XCTAssertEqual(b2?.max.x ?? 0, 110, accuracy: 1e-9)
    }
}
