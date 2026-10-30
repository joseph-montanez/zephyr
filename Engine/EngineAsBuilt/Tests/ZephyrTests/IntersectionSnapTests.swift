import XCTest
import Foundation
@testable import ZephyrCore

/// Intersection (INT) object snap: the crossing point of two entities is a
/// discrete snap target even though neither entity owns an anchor there.
/// Regression: two crossing construction lines offered no snap at their
/// crossing, so geometry could not be placed (e.g. a circle centred) on
/// offset-derived intersections — only the fuzzy nearest-on-curve point.
final class IntersectionSnapTests: XCTestCase {
    private let layer = UUID()

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADEntity {
        CADEntity(layerID: layer, localGeometry: [
            .line(start: Vector3(x: x1, y: y1, z: 0),
                  end: Vector3(x: x2, y: y2, z: 0), color: nil),
        ])
    }

    /// Line A (0,0)-(10,4) and line B (2,6)-(8,0) cross where 0.4x = 8 - x,
    /// i.e. x = 8/1.4, y = 3.2/1.4 — deliberately not a midpoint of either.
    func testLineLineIntersectionSnapsExactly() throws {
        let snap = SnapEngine().nearestSnap(
            worldX: 5.9, worldY: 2.1,
            entities: [line(0, 0, 10, 4), line(2, 6, 8, 0)],
            threshold: 0.5,
            nearestOnCurveOverride: false)
        let hit = try XCTUnwrap(snap, "no snap at line/line crossing")
        XCTAssertEqual(hit.worldPos.x, 8.0 / 1.4, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 3.2 / 1.4, accuracy: 1e-9)
        guard case .intersection = hit.anchor else {
            return XCTFail("expected .intersection anchor, got \(hit.anchor)")
        }
    }

    /// Discrete intersections beat nearest-on-curve: a cursor sitting ON
    /// line A (on-curve distance 0) still locks to the crossing.
    func testIntersectionBeatsNearestOnCurve() throws {
        let snap = SnapEngine().nearestSnap(
            worldX: 6.25, worldY: 2.5,
            entities: [line(0, 0, 10, 4), line(2, 6, 8, 0)],
            threshold: 1.0)
        let hit = try XCTUnwrap(snap, "no snap near line/line crossing")
        XCTAssertEqual(hit.worldPos.x, 8.0 / 1.4, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 3.2 / 1.4, accuracy: 1e-9)
        guard case .intersection = hit.anchor else {
            return XCTFail("expected .intersection anchor, got \(hit.anchor)")
        }
    }

    func testLineCircleIntersectionSnaps() throws {
        // Circle centre (5,3) r=5 meets y=0 at x=1 and x=9.
        let circle = CADEntity(layerID: layer, localGeometry: [
            .circle(center: Vector3(x: 5, y: 3, z: 0), radius: 5, color: nil),
        ])
        let snap = SnapEngine().nearestSnap(
            worldX: 1.2, worldY: 0.3,
            entities: [line(0, 0, 10, 0), circle],
            threshold: 0.6,
            nearestOnCurveOverride: false)
        let hit = try XCTUnwrap(snap, "no snap at line/circle crossing")
        XCTAssertEqual(hit.worldPos.x, 1, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 0, accuracy: 1e-9)
        guard case .intersection = hit.anchor else {
            return XCTFail("expected .intersection anchor, got \(hit.anchor)")
        }
    }

    func testSelfIntersectingPolylineSnaps() throws {
        // Bowtie: segment (0,0)-(10,6) crosses (10,0)-(0,8) at 0.6x = 8-0.8x.
        let bowtie = CADEntity(layerID: layer, localGeometry: [
            .polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 6, z: 0),
                Vector3(x: 10, y: 0, z: 0), Vector3(x: 0, y: 8, z: 0),
            ]), color: nil),
        ])
        let snap = SnapEngine().nearestSnap(
            worldX: 5.8, worldY: 3.3,
            entities: [bowtie],
            threshold: 0.4,
            nearestOnCurveOverride: false)
        let hit = try XCTUnwrap(snap, "no snap at polyline self-crossing")
        XCTAssertEqual(hit.worldPos.x, 8.0 / 1.4, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 4.8 / 1.4, accuracy: 1e-9)
        guard case .intersection = hit.anchor else {
            return XCTFail("expected .intersection anchor, got \(hit.anchor)")
        }
    }

    func testParallelLinesProduceNoIntersectionSnap() {
        let snap = SnapEngine().nearestSnap(
            worldX: 5, worldY: 0.4,
            entities: [line(0, 0, 10, 0), line(0, 2, 10, 2)],
            threshold: 0.6,
            nearestOnCurveOverride: false)
        // Midpoints (5,0) is within 0.4 — assert only that no *intersection*
        // is invented between parallels.
        if let snap, case .intersection = snap.anchor {
            XCTFail("parallel lines must not report an intersection snap")
        }
    }

    /// Where two lines merely share an endpoint, the endpoint anchor keeps
    /// priority over relabelling the same point as an intersection.
    func testSharedEndpointStaysVertexSnap() throws {
        let snap = SnapEngine().nearestSnap(
            worldX: 10.2, worldY: 0.1,
            entities: [line(0, 0, 10, 0), line(10, 0, 10, 10)],
            threshold: 0.5,
            nearestOnCurveOverride: false)
        let hit = try XCTUnwrap(snap, "no snap at shared endpoint")
        XCTAssertEqual(hit.worldPos.x, 10, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 0, accuracy: 1e-9)
        guard case .vertex = hit.anchor else {
            return XCTFail("expected .vertex anchor, got \(hit.anchor)")
        }
    }
}
