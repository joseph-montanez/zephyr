import XCTest
@testable import ZephyrCore

/// Synthetic H2: complex-block bbox shortcut must not miss fill interiors.
@MainActor
final class ComplexBlockInteriorTests: XCTestCase {
    func testComplexBlockFillInteriorHitsWithSimplify() {
        let doc = CADDocument()
        let layer = Layer(name: "WALLS")
        doc.addLayer(layer)
        var prims: [CADPrimitive] = []
        for i in 0..<60 {
            let x = Double(i) * 10.0
            prims.append(.line(start: Vector3(x: x, y: 0, z: 0), end: Vector3(x: x + 1, y: 0, z: 0), color: nil))
        }
        let fillOuter = [
            Vector3(x: 300, y: 100, z: 0),
            Vector3(x: 310, y: 100, z: 0),
            Vector3(x: 310, y: 110, z: 0),
            Vector3(x: 300, y: 110, z: 0),
        ]
        prims.append(.fillPolygon(points: fillOuter, color: nil))
        let block = CADBlock(name: "COMPLEX", geometry: prims)
        doc.addBlock(block)
        let ent = CADEntity(layerID: layer.handle, blockID: block.handle, localGeometry: nil, transform: .identity, drawOrder: 1)
        doc.addEntity(ent)
        doc.rebuildEntityGrid()
        guard let stored = doc.entitiesView.first else { XCTFail("no entity"); return }
        let geomCount = doc.resolvedGeometry(for: stored)?.count ?? 0
        XCTAssertGreaterThan(geomCount, 50, "fixture must exercise the complex-block path")
        let probe = Vector3(x: 305, y: 105, z: 0)
        let hit = CADHitTesting.hitTest(worldX: probe.x, worldY: probe.y, document: doc, threshold: 3.0, simplifyComplexBlocks: true)
        XCTAssertEqual(hit, stored.handle, "complex-block fill interior must hit with simplify=true")
        let list = CADHitTesting.allHitsAt(worldX: probe.x, worldY: probe.y, document: doc, threshold: 3.0, simplifyComplexBlocks: true)
        XCTAssertTrue(list.contains(where: { $0.handle == stored.handle }), "fill must appear in pile list")
    }
}
