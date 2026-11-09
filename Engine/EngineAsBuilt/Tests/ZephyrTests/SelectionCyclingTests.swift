import XCTest
@testable import ZephyrCore
@testable import ZephyrLisp

/// Selection Cycling (AutoCAD parity): overlapping-object list, hover badge
/// pile detection, SELECTIONCYCLING sysvar, and the shared pick ordering.
@MainActor
final class SelectionCyclingTests: XCTestCase {

    // MARK: - Fixtures

    private func lineEntity(layer: Layer, y: Double = 0, drawOrder: Int = .max) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: y, z: 0),
                end: Vector3(x: 10, y: y, z: 0),
                color: nil)],
            drawOrder: drawOrder)
    }

    private func docWithEntities(layers: [Layer], entities: [CADEntity]) -> CADDocument {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: layers, blocks: [], entities: [])
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: entities)
        doc.rebuildEntityGrid()
        return doc
    }

    private func withCyclingValue(_ value: Int, _ body: () -> Void) {
        let saved = SelectionCyclingSettings.value
        SelectionCyclingSettings.value = value
        defer { SelectionCyclingSettings.value = saved }
        body()
    }

    // MARK: - Resolver matrix

    func testShouldOpenListMatrix() {
        // Mode 2 opens the list only for real piles without an armed cycle.
        XCTAssertTrue(SelectionCyclingResolver.shouldOpenList(
            hitCount: 2, mode: 2, hasActiveCycle: false))
        XCTAssertTrue(SelectionCyclingResolver.shouldOpenList(
            hitCount: 5, mode: 2, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenList(
            hitCount: 2, mode: 2, hasActiveCycle: true))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenList(
            hitCount: 1, mode: 2, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenList(
            hitCount: 0, mode: 2, hasActiveCycle: false))
        // Badge-only and off modes never open the list.
        for mode in [-2, -1, 0, 1] {
            XCTAssertFalse(SelectionCyclingResolver.shouldOpenList(
                hitCount: 3, mode: mode, hasActiveCycle: false),
                "mode \(mode) must not open the list")
        }
    }

    func testListBeforeBlockMemberGripOnlyInPiles() {
        // Dense block-member grips must not preempt a genuine pile in
        // mode 2; loose grips and single hits keep grip priority.
        XCTAssertTrue(SelectionCyclingResolver.shouldOpenListBeforeGrip(
            isBlockMemberGrip: true, hitCount: 2, mode: 2, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenListBeforeGrip(
            isBlockMemberGrip: false, hitCount: 2, mode: 2, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenListBeforeGrip(
            isBlockMemberGrip: true, hitCount: 1, mode: 2, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenListBeforeGrip(
            isBlockMemberGrip: true, hitCount: 2, mode: 1, hasActiveCycle: false))
        XCTAssertFalse(SelectionCyclingResolver.shouldOpenListBeforeGrip(
            isBlockMemberGrip: true, hitCount: 2, mode: 2, hasActiveCycle: true))
    }

    func testToggleCyclesThroughSign() {
        withCyclingValue(0) { XCTAssertEqual(SelectionCyclingSettings.toggle(), 2) }
        withCyclingValue(2) { XCTAssertEqual(SelectionCyclingSettings.toggle(), -2) }
        withCyclingValue(-2) { XCTAssertEqual(SelectionCyclingSettings.toggle(), 2) }
        withCyclingValue(1) { XCTAssertEqual(SelectionCyclingSettings.toggle(), -1) }
        withCyclingValue(-1) { XCTAssertEqual(SelectionCyclingSettings.toggle(), 1) }
    }

    // MARK: - Threshold parity (caller's pickbox wins)

    func testAllHitsAtHonorsCallerThreshold() {
        let layer = Layer(name: "WALLS")
        let doc = docWithEntities(
            layers: [layer],
            entities: [lineEntity(layer: layer, y: 0), lineEntity(layer: layer, y: 10)])
        // Narrow pickbox: only the y=0 line.
        XCTAssertEqual(doc.entityCount, 2)
        let narrow = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0)
        XCTAssertEqual(narrow.count, 1)
        // Wide pickbox: both lines (the old hardcoded 3.0 would still give 1).
        let wide = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 12.0)
        XCTAssertEqual(wide.count, 2)
        XCTAssertTrue(CADHitTesting.hasMultipleHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 12.0))
        XCTAssertFalse(CADHitTesting.hasMultipleHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0))
    }

    // MARK: - Shared ordering (row 1 == hitTest)

    func testAllHitsFirstEqualsHitTestWithAreaTieBreak() {
        let layer = Layer(name: "A")
        let fill = CADEntity(
            layerID: layer.handle,
            localGeometry: [.fillRect(
                origin: Vector3(x: 0, y: 0, z: 0),
                size: Vector3(x: 10, y: 10, z: 0),
                color: nil)])
        let line = lineEntity(layer: layer, y: 5)
        let doc = docWithEntities(layers: [layer], entities: [fill, line])
        let threshold = 6.0
        let winner = CADHitTesting.hitTest(
            worldX: 5, worldY: 5, document: doc, threshold: threshold)
        XCTAssertEqual(winner, line.handle, "smaller area wins at equal draw order")
        let rows = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 5, document: doc, threshold: threshold)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].handle, winner)
    }

    func testDrawOrderBeatsArea() {
        let layer = Layer(name: "A")
        let bottomFill = CADEntity(
            layerID: layer.handle,
            localGeometry: [.fillRect(
                origin: Vector3(x: 0, y: 0, z: 0),
                size: Vector3(x: 10, y: 10, z: 0),
                color: nil)],
            drawOrder: 9)
        let topLine = lineEntity(layer: layer, y: 5, drawOrder: 1)
        let doc = docWithEntities(layers: [layer], entities: [bottomFill, topLine])
        let rows = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 5, document: doc, threshold: 6.0)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].handle, bottomFill.handle)
        XCTAssertEqual(
            CADHitTesting.hitTest(worldX: 5, worldY: 5, document: doc, threshold: 6.0),
            rows[0].handle)
    }

    // MARK: - Pile membership (locked in, hidden out, self never)

    func testLockedLayersJoinThePile() {
        let normal = Layer(name: "A")
        let locked = Layer(name: "B", isLocked: true)
        let doc = docWithEntities(
            layers: [normal, locked],
            entities: [lineEntity(layer: normal), lineEntity(layer: locked)])
        XCTAssertTrue(CADHitTesting.hasMultipleHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0))
        let rows = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { $0.label.contains("[locked]") })
    }

    func testHiddenLayersLeaveThePile() {
        let normal = Layer(name: "A")
        var off = Layer(name: "B")
        off.isVisible = false
        let doc = docWithEntities(
            layers: [normal, off],
            entities: [lineEntity(layer: normal), lineEntity(layer: off)])
        XCTAssertFalse(CADHitTesting.hasMultipleHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0))
        XCTAssertEqual(CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0).count, 1)
    }

    func testSingleMultiPrimitiveEntityIsNotAPile() {
        let layer = Layer(name: "A")
        // One entity, two primitives sharing a vertex: still one pickable.
        let corner = CADEntity(
            layerID: layer.handle,
            localGeometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 10, y: 0, z: 0), color: nil),
                .line(start: Vector3(x: 10, y: 0, z: 0),
                      end: Vector3(x: 10, y: 10, z: 0), color: nil),
            ])
        let doc = docWithEntities(layers: [layer], entities: [corner])
        XCTAssertFalse(CADHitTesting.hasMultipleHitsAt(
            worldX: 10, worldY: 0, document: doc, threshold: 6.0))
        XCTAssertEqual(CADHitTesting.allHitsAt(
            worldX: 10, worldY: 0, document: doc, threshold: 6.0).count, 1)
    }

    // MARK: - Labels

    func testIdenticalRowsDisambiguateByHandle() {
        let layer = Layer(name: "WALLS")
        let doc = docWithEntities(
            layers: [layer],
            entities: [lineEntity(layer: layer), lineEntity(layer: layer)])
        let rows = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 6.0)
        XCTAssertEqual(rows.count, 2)
        // Same type and layer: handles tell the rows apart.
        XCTAssertNotEqual(rows[0].label, rows[1].label)
        XCTAssertTrue(rows[0].label.contains("LINE"))
        // Distinct layers read distinctly without handle noise.
        let other = Layer(name: "DOORS")
        let doc2 = docWithEntities(
            layers: [layer, other],
            entities: [lineEntity(layer: layer), lineEntity(layer: other)])
        let rows2 = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc2, threshold: 6.0)
        XCTAssertEqual(rows2.count, 2)
        XCTAssertFalse(rows2[0].label.contains("#"))
        XCTAssertFalse(rows2[1].label.contains("#"))
    }

    // MARK: - Sysvar

    func testSelectionCyclingSysvarValidation() {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let store = LispVarStore()
        withCyclingValue(2) {
            XCTAssertNil(store.set("SELECTIONCYCLING", .int(1), document: doc))
            XCTAssertEqual(SelectionCyclingSettings.value, 1)
            XCTAssertEqual(store.get("SELECTIONCYCLING", document: doc, activeCommand: nil), .int(1))
            XCTAssertNotNil(store.set("SELECTIONCYCLING", .int(5), document: doc))
            XCTAssertEqual(SelectionCyclingSettings.value, 1, "rejected writes stick")
            XCTAssertNotNil(store.set("SELECTIONCYCLING", .int(-3), document: doc))
            XCTAssertNil(store.set("SELECTIONCYCLING", .int(-2), document: doc))
            XCTAssertEqual(SelectionCyclingSettings.value, -2)
        }
    }
}
