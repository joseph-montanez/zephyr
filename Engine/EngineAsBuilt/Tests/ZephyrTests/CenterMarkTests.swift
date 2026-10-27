import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 centermarks: cross/midline geometry, xdata source linkage,
/// MOVE fan-out expansion, and the move round-trip. (Command pick/commit
/// flow mirrors DimRadiusCommand; registration/parity/ribbon via gates.)
@MainActor
final class CenterMarkTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func lineEntity(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADEntity {
        CADEntity(
            layerID: UUID(),
            localGeometry: [.line(
                start: Vector3(x: x1, y: y1, z: 0),
                end: Vector3(x: x2, y: y2, z: 0), color: nil)])
    }

    // MARK: - Geometry

    func testCrossArmsSpanHalfSize() {
        let (w0, w1, h0, h1) = CenterMarkMath.crossArms(
            center: Vector3(x: 5, y: 5, z: 0), halfSize: 2)
        XCTAssertEqual(w0.x, 3)
        XCTAssertEqual(w1.x, 7)
        XCTAssertEqual(w0.y, 5)
        XCTAssertEqual(h0.y, 3)
        XCTAssertEqual(h1.y, 7)
        XCTAssertEqual(h0.x, 5)
    }

    func testMidlineBetweenParallelLines() {
        let (m1, m2) = try! XCTUnwrap(CenterMarkMath.midline(
            a1: Vector3(x: 0, y: 0, z: 0), a2: Vector3(x: 10, y: 0, z: 0),
            b1: Vector3(x: 2, y: 4, z: 0), b2: Vector3(x: 8, y: 4, z: 0)))
        XCTAssertEqual(m1.y, 2)
        XCTAssertEqual(m2.y, 2)
        // Spans the combined projected extent.
        XCTAssertEqual(m1.x, 0)
        XCTAssertEqual(m2.x, 10)
    }

    func testMidlineRejectsNonParallelAndDegenerate() {
        XCTAssertNil(CenterMarkMath.midline(
            a1: Vector3(x: 0, y: 0, z: 0), a2: Vector3(x: 10, y: 0, z: 0),
            b1: Vector3(x: 0, y: 0, z: 0), b2: Vector3(x: 0, y: 10, z: 0)))
        XCTAssertNil(CenterMarkMath.midline(
            a1: Vector3(x: 1, y: 1, z: 0), a2: Vector3(x: 1, y: 1, z: 0),
            b1: Vector3(x: 0, y: 4, z: 0), b2: Vector3(x: 8, y: 4, z: 0)))
    }

    // MARK: - Linkage + MOVE fan-out

    func testLinkedMarkFollowsSourceExpansion() {
        let doc = makeDocument()
        let circle = CADEntity(
            layerID: UUID(),
            localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 5, color: nil)])
        var mark = lineEntity(-1, 0, 1, 0)
        mark.xdata[CenterMarkLink.markSourceKey] = .string(circle.handle.uuidString)
        var stray = lineEntity(9, 9, 10, 10)
        stray.xdata[CenterMarkLink.markSourceKey] = .string("not-a-uuid")
        let plain = lineEntity(20, 20, 21, 21)
        doc.addEntities([circle, mark, stray, plain])

        let expanded = doc.centerLinkedHandles(following: [circle.handle])
        XCTAssertTrue(expanded.contains(circle.handle))
        XCTAssertTrue(expanded.contains(mark.handle))
        XCTAssertFalse(expanded.contains(stray.handle))
        XCTAssertFalse(expanded.contains(plain.handle))
        XCTAssertTrue(doc.centerLinkedHandles(following: []).isEmpty)
    }

    func testCenterlineFollowsEitherSource() {
        let doc = makeDocument()
        let a = lineEntity(0, 0, 10, 0)
        let b = lineEntity(0, 4, 10, 4)
        var mid = lineEntity(0, 2, 10, 2)
        mid.xdata[CenterMarkLink.lineSourcesKey] = .string(
            "\(a.handle.uuidString), \(b.handle.uuidString)")
        doc.addEntities([a, b, mid])

        XCTAssertTrue(doc.centerLinkedHandles(following: [a.handle]).contains(mid.handle))
        XCTAssertTrue(doc.centerLinkedHandles(following: [b.handle]).contains(mid.handle))
        XCTAssertFalse(doc.centerLinkedHandles(following: [UUID()]).contains(mid.handle))
    }

    func testMoveCarriesLinkedMark() {
        let doc = makeDocument()
        let circle = CADEntity(
            layerID: UUID(),
            localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 5, color: nil)])
        var mark = lineEntity(-1, 0, 1, 0)
        mark.xdata[CenterMarkLink.markSourceKey] = .string(circle.handle.uuidString)
        doc.addEntities([circle, mark])

        let delta = Vector3(x: 3, y: -2, z: 0)
        doc.moveEntities(
            handles: doc.centerLinkedHandles(following: [circle.handle]),
            by: delta)
        XCTAssertEqual(doc.entity(for: circle.handle)?.transform.position.x, 3)
        XCTAssertEqual(doc.entity(for: circle.handle)?.transform.position.y, -2)
        XCTAssertEqual(doc.entity(for: mark.handle)?.transform.position.x, 3)
        XCTAssertEqual(doc.entity(for: mark.handle)?.transform.position.y, -2)
    }
}
