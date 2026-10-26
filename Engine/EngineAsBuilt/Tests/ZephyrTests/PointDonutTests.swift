import XCTest
@testable import ZephyrCore

/// Phase 1A-5 tests: PDMODE validation, PDSIZE resolution, donut ring
/// construction (2-arc wide polyline, FILLMODE honored), live
/// PDMODE/PDSIZE/FILLMODE sysvars, and the DXF POINT round trip.
@MainActor
final class PointDonutTests: XCTestCase {

    func testValidPointDisplayModes() {
        for m in [0, 1, 2, 3, 4, 32, 33, 34, 35, 36, 64, 65, 68, 96, 97, 100] {
            XCTAssertTrue(CADDocument.isValidPointDisplayMode(m), "mode \(m) valid")
        }
        for m in [-1, 5, 31, 37, 63, 69, 95, 101, 128] {
            XCTAssertFalse(CADDocument.isValidPointDisplayMode(m), "mode \(m) invalid")
        }
    }

    func testResolvePointSize() {
        XCTAssertEqual(TessInput.resolvePointSize(2, regionHeight: 100), 2, accuracy: 1e-9)
        XCTAssertEqual(TessInput.resolvePointSize(0, regionHeight: 100), 5, accuracy: 1e-9)
        XCTAssertEqual(TessInput.resolvePointSize(-10, regionHeight: 100), 10, accuracy: 1e-9)
        XCTAssertEqual(TessInput.resolvePointSize(0, regionHeight: 0), 0.05, accuracy: 1e-9)
    }

    func testDonutRingFilled() {
        let ring = DonutMath.ring(
            center: Vector3(x: 0, y: 0, z: 0),
            innerRadius: 1, outerRadius: 3, fill: true)
        XCTAssertTrue(ring.isClosed)
        XCTAssertEqual(ring.vertices.count, 2)
        for v in ring.vertices {
            XCTAssertEqual(v.bulge, 1.0, accuracy: 1e-12)
            XCTAssertEqual(v.startWidth, 2.0, accuracy: 1e-9)
            XCTAssertEqual(v.endWidth, 2.0, accuracy: 1e-9)
        }
        // Mid radius 2 on the x axis.
        XCTAssertEqual(ring.vertices[0].position.x, 2, accuracy: 1e-9)
        XCTAssertEqual(ring.vertices[1].position.x, -2, accuracy: 1e-9)
    }

    func testDonutRingUnfilledHasZeroWidths() {
        let ring = DonutMath.ring(
            center: Vector3(x: 5, y: 5, z: 0),
            innerRadius: 1, outerRadius: 3, fill: false)
        XCTAssertTrue(ring.isClosed)
        for v in ring.vertices {
            XCTAssertEqual(v.startWidth, 0, accuracy: 1e-12)
            XCTAssertEqual(v.endWidth, 0, accuracy: 1e-12)
        }
    }

    func testPointSysvarsLive() {
        let processor = CADCommandProcessor()
        let doc = CADDocument()
        XCTAssertNil(processor.lispVars.set("PDMODE", .int(3), document: doc))
        XCTAssertEqual(doc.pointDisplayMode, 3)
        XCTAssertEqual(
            processor.lispVars.get("PDMODE", document: doc, activeCommand: nil),
            .int(3))
        XCTAssertNotNil(processor.lispVars.set("PDMODE", .int(7), document: doc))
        XCTAssertEqual(doc.pointDisplayMode, 3, "invalid PDMODE must not apply")
        XCTAssertNil(processor.lispVars.set("PDSIZE", .real(2.5), document: doc))
        XCTAssertEqual(doc.pointDisplaySize, 2.5, accuracy: 1e-12)
        XCTAssertNil(processor.lispVars.set("FILLMODE", .int(0), document: doc))
        XCTAssertFalse(doc.fillMode)
        XCTAssertEqual(
            processor.lispVars.get("FILLMODE", document: doc, activeCommand: nil),
            .int(0))
    }

    func testDXFPointRoundTrip() {
        let e = DXFPointEntity()
        e.basePoint = Vector3(x: 4, y: -6, z: 0)
        let prims = DXFEntityConverter.convertEntityToPrimitives(e)
        XCTAssertEqual(prims.count, 1)
        guard case .point(let pos, _) = prims.first else {
            return XCTFail("expected .point, got \(prims)")
        }
        XCTAssertEqual(pos.x, 4, accuracy: 1e-9)
        XCTAssertEqual(pos.y, 6, accuracy: 1e-9)
    }
}
