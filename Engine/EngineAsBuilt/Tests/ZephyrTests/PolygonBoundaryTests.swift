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

    func testBoundarySplitCircleLowerHalf() {
        // Screenshot repro: a circle crossed by an overshooting diagonal line.
        // A seed in the lower half must hatch only that half (~half the disc),
        // not the full circle.
        let doc = makeCircleSplitByLineDoc()
        let loop = CADBoundaryDetector.findEnclosingPolygon(
            seedX: 0, seedY: -5, document: doc)
        guard let found = loop else { return XCTFail("no loop found for lower half") }
        let area = CADBoundaryDetector.shoelaceArea(polygon: found)
        XCTAssertGreaterThan(area, 100, "lower half should be well above zero (got \(area))")
        XCTAssertLessThan(area, 200, "lower half must not be the full circle (got \(area))")
        XCTAssertTrue(pointInLoop(Vector3(x: 0, y: -5, z: 0), loop: found),
                      "seed must be inside the returned half")
        XCTAssertFalse(pointInLoop(Vector3(x: 0, y: 5, z: 0), loop: found),
                       "mirror point across the line must be outside the returned half")
    }

    func testBoundarySplitCircleUpperHalf() {
        let doc = makeCircleSplitByLineDoc()
        let loop = CADBoundaryDetector.findEnclosingPolygon(
            seedX: 0, seedY: 5, document: doc)
        guard let found = loop else { return XCTFail("no loop found for upper half") }
        let area = CADBoundaryDetector.shoelaceArea(polygon: found)
        XCTAssertGreaterThan(area, 100, "upper half should be well above zero (got \(area))")
        XCTAssertLessThan(area, 200, "upper half must not be the full circle (got \(area))")
        XCTAssertTrue(pointInLoop(Vector3(x: 0, y: 5, z: 0), loop: found),
                      "seed must be inside the returned half")
        XCTAssertFalse(pointInLoop(Vector3(x: 0, y: -5, z: 0), loop: found),
                       "mirror point across the line must be outside the returned half")
    }

    func testBoundaryRectangleSplitByLine() {
        // A 20x10 rectangle split by a vertical line through the middle:
        // each half must come back as ~100, not the full 200.
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let corners = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 20, y: 0, z: 0),
            Vector3(x: 20, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0),
        ]
        var prims: [CADPrimitive] = []
        for i in 0..<4 {
            prims.append(.line(start: corners[i], end: corners[(i + 1) % 4]))
        }
        prims.append(.line(start: Vector3(x: 10, y: -5, z: 0),
                           end: Vector3(x: 10, y: 15, z: 0)))
        let entity = CADEntity(layerID: layer.handle, localGeometry: prims)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        guard let found = CADBoundaryDetector.findEnclosingPolygon(
            seedX: 5, seedY: 5, document: doc) else {
            return XCTFail("no loop found for rectangle half")
        }
        let area = CADBoundaryDetector.shoelaceArea(polygon: found)
        XCTAssertEqual(area, 100, accuracy: 1.0)
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

    // MARK: - Split-face helpers

    /// Circle (r=10 at origin) crossed by a diagonal line through the centre
    /// with both endpoints outside the circle, mirroring the reported screenshot.
    private func makeCircleSplitByLineDoc() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let circle = CADEntity(
            layerID: layer.handle,
            localGeometry: [.circle(center: Vector3(x: 0, y: 0, z: 0), radius: 10)])
        let chord = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: Vector3(x: -20, y: 12, z: 0),
                end: Vector3(x: 20, y: -12, z: 0))])
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [circle, chord])
        return doc
    }

    /// Even-odd point-in-polygon for test assertions.
    private func pointInLoop(_ point: Vector3, loop: [Vector3]) -> Bool {
        guard loop.count >= 3 else { return false }
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let pi = loop[i]
            let pj = loop[j]
            if ((pi.y > point.y) != (pj.y > point.y)) {
                let denom = pj.y - pi.y
                if abs(denom) > 1e-12 {
                    let x = (pj.x - pi.x) * (point.y - pi.y) / denom + pi.x
                    if point.x < x { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }
}
