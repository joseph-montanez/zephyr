import XCTest
@testable import ZephyrCore

/// Phase 1A-4 tests: POLYGON vertex math (inscribed / circumscribed /
/// edge modes) and BOUNDARY's enclosing-loop detection on a headless
/// document.
@MainActor
final class PolygonBoundaryTests: XCTestCase {

    func testInscribedSquareVertices() {
        let verts = PolygonMath.vertices(
            sides: 4, center: Vector3(x: 0, y: 0, z: 0),
            radius: 1, startAngle: 0, mode: .inscribed)
        XCTAssertEqual(verts.count, 4)
        let expected = [(1.0, 0.0), (0.0, 1.0), (-1.0, 0.0), (0.0, -1.0)]
        for (v, e) in zip(verts, expected) {
            XCTAssertEqual(v.x, e.0, accuracy: 1e-9)
            XCTAssertEqual(v.y, e.1, accuracy: 1e-9)
        }
    }

    func testCircumscribedSquareVertices() {
        // Flat distance 1: vertices at radius sqrt(2), offset half a step.
        let verts = PolygonMath.vertices(
            sides: 4, center: Vector3(x: 0, y: 0, z: 0),
            radius: 1, startAngle: 0, mode: .circumscribed)
        XCTAssertEqual(verts.count, 4)
        let expected = [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)]
        for (v, e) in zip(verts, expected) {
            XCTAssertEqual(v.x, e.0, accuracy: 1e-9)
            XCTAssertEqual(v.y, e.1, accuracy: 1e-9)
        }
    }

    func testEdgeModeUnitSquare() {
        let verts = PolygonMath.verticesFromEdge(
            sides: 4,
            first: Vector3(x: 0, y: 0, z: 0),
            second: Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(verts.count, 4)
        let expected = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        for (v, e) in zip(verts, expected) {
            XCTAssertEqual(v.x, e.0, accuracy: 1e-9)
            XCTAssertEqual(v.y, e.1, accuracy: 1e-9)
        }
    }

    func testBoundaryFindsRectangleLoop() {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let c = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 5, z: 0), Vector3(x: 0, y: 5, z: 0),
        ]
        var prims: [CADPrimitive] = []
        for i in 0..<4 {
            prims.append(.line(start: c[i], end: c[(i + 1) % 4]))
        }
        let entity = CADEntity(layerID: layer.handle, localGeometry: prims)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        let loop = CADBoundaryDetector.findEnclosingPolygon(
            seedX: 5, seedY: 2.5, document: doc)
        guard let found = loop else { return XCTFail("no loop found") }
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(
            abs(CADBoundaryDetector.shoelaceArea(polygon: found)),
            50, accuracy: 1e-6)
    }

    func testBoundaryMissesOpenGeometry() {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0))])
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        XCTAssertNil(CADBoundaryDetector.findEnclosingPolygon(
            seedX: 5, seedY: 2.5, document: doc))
    }
}
