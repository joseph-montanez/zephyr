import XCTest
@testable import ZephyrCore

/// Phase 1A-1 tests: inquiry math (areas, lengths, formatting with live
/// precision), the AREA tally accumulation, LIST description contracts,
/// and the AreaCommand option surface. All headless; live-pointer picking
/// stays a manual sweep per the plan.
@MainActor
final class InquiryTests: XCTestCase {

    func testFormatLengthPrecision() {
        XCTAssertEqual(InquiryMath.formatLength(3.14159, precision: 4), "3.1416")
        XCTAssertEqual(InquiryMath.formatLength(3.14159, precision: 2), "3.14")
        XCTAssertEqual(InquiryMath.formatLength(3.14159, precision: 0), "3")
        XCTAssertEqual(InquiryMath.formatLength(-0.00001, precision: 4), "0.0000")
        XCTAssertEqual(InquiryMath.formatLength(2.5, precision: 9), "2.50000000")
    }

    func testFormatAngleDeg() {
        XCTAssertEqual(InquiryMath.formatAngleDeg(0, precision: 0), "0")
        XCTAssertEqual(
            InquiryMath.formatAngleDeg(Double.pi / 4, precision: 0), "45")
        XCTAssertEqual(
            InquiryMath.formatAngleDeg(-Double.pi / 2, precision: 0), "270")
        XCTAssertEqual(
            InquiryMath.formatAngleDeg(2 * Double.pi, precision: 1), "0.0")
    }

    func testPolygonPerimeter() {
        let square = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0),
        ]
        XCTAssertEqual(InquiryMath.polygonPerimeter(square, closed: true), 40)
        XCTAssertEqual(InquiryMath.polygonPerimeter(square, closed: false), 30)
        XCTAssertEqual(InquiryMath.polygonPerimeter([], closed: true), 0)
    }

    func testEntityAreaByType() {
        let circle = CADEntity(
            layerID: UUID(),
            localGeometry: [.circle(center: .zero, radius: 2, color: nil)],
            transform: .identity)
        XCTAssertEqual(
            InquiryMath.entityArea(circle)!, Double.pi * 4, accuracy: 1e-9)

        let line = CADEntity(
            layerID: UUID(),
            localGeometry: [.line(
                start: .zero, end: Vector3(x: 3, y: 4, z: 0), color: nil)],
            transform: .identity)
        XCTAssertNil(InquiryMath.entityArea(line))
        XCTAssertEqual(InquiryMath.entityLength(line)!, 5, accuracy: 1e-9)

        let closed = CADEntity(
            layerID: UUID(),
            localGeometry: [.polyline(path: CADPolyline(
                vertices: [
                    Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                    Vector3(x: 4, y: 3, z: 0),
                ].map {
                    CADPolylineVertex(
                        position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                }, isClosed: true), color: nil)],
            transform: .identity)
        XCTAssertEqual(InquiryMath.entityArea(closed)!, 6, accuracy: 1e-9)

        let open = CADEntity(
            layerID: UUID(),
            localGeometry: [.polyline(path: CADPolyline(
                vertices: [
                    Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                ].map {
                    CADPolylineVertex(
                        position: $0, bulge: 0, startWidth: 0, endWidth: 0)
                }, isClosed: false), color: nil)],
            transform: .identity)
        XCTAssertNil(InquiryMath.entityArea(open))
        XCTAssertEqual(InquiryMath.entityLength(open)!, 4, accuracy: 1e-9)
    }

    func testAreaTally() {
        var tally = AreaTally()
        tally.add(area: 100, perimeter: 40)
        tally.add(area: 50, perimeter: 30)
        tally.subtract(area: 10, perimeter: 5)
        XCTAssertEqual(tally.area, 140)
        XCTAssertEqual(tally.perimeter, 65)
        XCTAssertEqual(tally.picks, 3)
        tally.reset()
        XCTAssertEqual(tally.area, 0)
        XCTAssertEqual(tally.picks, 0)
    }

    func testAreaCommandOptions() {
        let options = AreaCommand().commandTextOptions(for: "")
        XCTAssertEqual(
            Set(options.map { $0.value }),
            ["O", "A", "S", "X"])
    }

    func testListDescribeLine() {
        let doc = CADDocument()
        let layer = Layer(name: "Walls", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: .zero, end: Vector3(x: 10, y: 0, z: 0), color: nil)],
            transform: .identity)
        let lines = ListCommand.describe(
            entity, document: doc, luprec: 4, auprec: 0)
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("LINE"), body)
        XCTAssertTrue(body.contains("Walls"), body)
        XCTAssertTrue(body.contains("Length = 10.0000"), body)
        XCTAssertTrue(body.contains("Angle in XY Plane = 0"), body)
    }

    func testListDescribeCircle() {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.circle(center: .zero, radius: 1, color: nil)],
            transform: .identity)
        let lines = ListCommand.describe(
            entity, document: doc, luprec: 4, auprec: 0)
        let body = lines.joined(separator: "\n")
        XCTAssertTrue(body.contains("CIRCLE"), body)
        XCTAssertTrue(body.contains("radius 1.0000"), body)
        XCTAssertTrue(body.contains("Area = 3.1416"), body)
        XCTAssertTrue(body.contains("Circumference = 6.2832"), body)
    }
}
