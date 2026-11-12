import XCTest
@testable import ZephyrCore

/// Single-pass hover scan: one document walk must produce the same best hit
/// as `hitTest` and the same pile order as `allHitsAt`, so the hover path
/// can replace up to three walks (hit + multi-check + full list) with one.
@MainActor
final class HoverScanTests: XCTestCase {

    private func layer0() -> Layer {
        Layer(name: "0", color: .white)
    }

    private func lineEntity(layer: Layer, y: Double = 0, drawOrder: Int = 0) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: y, z: 0),
                end: Vector3(x: 10, y: y, z: 0),
                color: nil)],
            drawOrder: drawOrder)
    }

    private func textEntity(layer: Layer, at point: Vector3) -> CADEntity {
        CADEntity(
            layerID: layer.handle,
            localGeometry: [.text(
                position: point, text: "Room A", height: 2.5, rotation: 0,
                style: nil, alignH: 0, alignV: 0, mtextWidth: nil, color: nil)],
            drawOrder: 0)
    }

    private func docWithEntities(layers: [Layer], entities: [CADEntity]) -> CADDocument {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: layers, blocks: [], entities: [])
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: entities)
        doc.rebuildEntityGrid()
        return doc
    }

    func testEmptyAreaReturnsNilBestAndEmptyPile() {
        let layer = layer0()
        let doc = docWithEntities(layers: [layer], entities: [lineEntity(layer: layer)])
        let scan = CADHitTesting.hoverScan(
            worldX: 500, worldY: 500, document: doc, threshold: 3.0)
        XCTAssertNil(scan.best)
        XCTAssertTrue(scan.pile.isEmpty)
    }

    func testSingleHitBestAndPileAgreeWithHitTest() {
        let layer = layer0()
        let line = lineEntity(layer: layer)
        let doc = docWithEntities(layers: [layer], entities: [line])
        let expected = CADHitTesting.hitTest(
            worldX: 5, worldY: 0.5, document: doc, threshold: 3.0)
        XCTAssertEqual(expected, line.handle)
        let scan = CADHitTesting.hoverScan(
            worldX: 5, worldY: 0.5, document: doc, threshold: 3.0)
        XCTAssertEqual(scan.best, expected)
        XCTAssertEqual(scan.pile, [line.handle])
    }

    func testPileOrderMatchesAllHitsAt() {
        let layer = layer0()
        // Three overlapping lines at different draw orders: shared pick
        // ordering (higher draw order wins) decides both row 1 and pile order.
        let low = lineEntity(layer: layer, y: 0, drawOrder: 1)
        let mid = lineEntity(layer: layer, y: 0.5, drawOrder: 2)
        let high = lineEntity(layer: layer, y: -0.5, drawOrder: 3)
        let doc = docWithEntities(layers: [layer], entities: [low, mid, high])
        let expectedBest = CADHitTesting.hitTest(
            worldX: 5, worldY: 0, document: doc, threshold: 3.0)
        let expectedPile = CADHitTesting.allHitsAt(
            worldX: 5, worldY: 0, document: doc, threshold: 3.0).map(\.handle)
        XCTAssertGreaterThanOrEqual(expectedPile.count, 2)
        let scan = CADHitTesting.hoverScan(
            worldX: 5, worldY: 0, document: doc, threshold: 3.0)
        XCTAssertEqual(scan.best, expectedBest)
        XCTAssertEqual(scan.pile, expectedPile)
    }

    func testTextHitParityWithHoistedContext() {
        // The per-entity text measurement context must behave identically
        // when built once per entity instead of once per primitive.
        let layer = layer0()
        let text = textEntity(layer: layer, at: Vector3(x: 5, y: 5, z: 0))
        let line = lineEntity(layer: layer, y: 50)
        let doc = docWithEntities(layers: [layer], entities: [text, line])
        let expected = CADHitTesting.hitTest(
            worldX: 6, worldY: 5, document: doc, threshold: 3.0)
        let scan = CADHitTesting.hoverScan(
            worldX: 6, worldY: 5, document: doc, threshold: 3.0)
        XCTAssertEqual(scan.best, expected)
        XCTAssertEqual(scan.best, text.handle)
    }
}
