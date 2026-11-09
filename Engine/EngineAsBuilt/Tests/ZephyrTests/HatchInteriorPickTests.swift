import XCTest
@testable import ZephyrCore

/// AutoCAD parity: clicking anywhere inside a hatch fills selects it, not
/// just the boundary edges. The interior test must handle concave
/// boundaries (rooms are L-shaped), and hatch holes exclude their interior.
@MainActor
final class HatchInteriorPickTests: XCTestCase {

    private func docWith(_ entities: [CADEntity]) -> CADDocument {
        let layer = Layer(name: "HATCH")
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let placed = entities.map { entity -> CADEntity in
            var copy = entity
            copy.layerID = layer.handle
            return copy
        }
        doc.importLayersBlocksEntities(layers: [], blocks: [], entities: placed)
        doc.rebuildEntityGrid()
        return doc
    }

    /// Concave L: (0,0)-(10,0)-(10,5)-(5,5)-(5,10)-(0,10).
    private var ell: [Vector3] {
        [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 5, z: 0),
            Vector3(x: 5, y: 5, z: 0),
            Vector3(x: 5, y: 10, z: 0),
            Vector3(x: 0, y: 10, z: 0),
        ]
    }

    func testConcaveHatchInteriorHits() {
        let hatch = CADEntity(
            layerID: UUID(),
            localGeometry: [.hatch(boundary: ell, pattern: "SOLID", scale: 1, angle: 0)])
        let doc = docWith([hatch])
        // Deep inside the upper arm, >1 from every edge: the convex-only
        // test rejects this point, so the old code misses.
        XCTAssertNotNil(CADHitTesting.hitTest(
            worldX: 2.5, worldY: 7.5, document: doc, threshold: 1.0))
        // The notch is outside the L: must still miss.
        XCTAssertNil(CADHitTesting.hitTest(
            worldX: 7.5, worldY: 7.5, document: doc, threshold: 1.0))
    }

    func testConcaveFillPolygonInteriorHits() {
        let fill = CADEntity(layerID: UUID(), localGeometry: [.fillPolygon(points: ell, color: nil)])
        let doc = docWith([fill])
        XCTAssertNotNil(CADHitTesting.hitTest(
            worldX: 2.5, worldY: 7.5, document: doc, threshold: 1.0))
        XCTAssertNil(CADHitTesting.hitTest(
            worldX: 7.5, worldY: 7.5, document: doc, threshold: 1.0))
    }

    func testConvexHatchInteriorStillHits() {
        let rect = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
            Vector3(x: 0, y: 10, z: 0),
        ]
        let hatch = CADEntity(
            layerID: UUID(),
            localGeometry: [.hatch(boundary: rect, pattern: "SOLID", scale: 1, angle: 0)])
        let doc = docWith([hatch])
        XCTAssertNotNil(CADHitTesting.hitTest(
            worldX: 5, worldY: 5, document: doc, threshold: 1.0))
        XCTAssertNil(CADHitTesting.hitTest(
            worldX: 20, worldY: 20, document: doc, threshold: 1.0))
    }

    func testHatchHoleInteriorMisses() {
        let outer = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
            Vector3(x: 0, y: 10, z: 0),
        ]
        let hole = [
            Vector3(x: 3, y: 3, z: 0),
            Vector3(x: 7, y: 3, z: 0),
            Vector3(x: 7, y: 7, z: 0),
            Vector3(x: 3, y: 7, z: 0),
        ]
        let entity = CADEntity(layerID: UUID(), localGeometry: [
            .fillComplexPolygon(outer: outer, holes: [hole]),
        ])
        let doc = docWith([entity])
        // Solid region hits.
        XCTAssertNotNil(CADHitTesting.hitTest(
            worldX: 1.5, worldY: 5, document: doc, threshold: 1.0))
        // Deep inside the hole (>1 from its edges): not the hatch.
        XCTAssertNil(CADHitTesting.hitTest(
            worldX: 5, worldY: 5, document: doc, threshold: 1.0))
    }

    func testHatchPathHoleInteriorMisses() {
        let outer = CADPolyline(
            points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
                Vector3(x: 10, y: 10, z: 0),
                Vector3(x: 0, y: 10, z: 0),
            ],
            isClosed: true)
        let hole = CADPolyline(
            points: [
                Vector3(x: 3, y: 3, z: 0),
                Vector3(x: 7, y: 3, z: 0),
                Vector3(x: 7, y: 7, z: 0),
                Vector3(x: 3, y: 7, z: 0),
            ],
            isClosed: true)
        let entity = CADEntity(layerID: UUID(), localGeometry: [
            .hatchPath(boundary: outer, holes: [hole], pattern: "SOLID", scale: 1, angle: 0),
        ])
        let doc = docWith([entity])
        XCTAssertNotNil(CADHitTesting.hitTest(
            worldX: 1.5, worldY: 5, document: doc, threshold: 1.0))
        // The old code ignores holes entirely and returns 0 here.
        XCTAssertNil(CADHitTesting.hitTest(
            worldX: 5, worldY: 5, document: doc, threshold: 1.0))
    }
}


