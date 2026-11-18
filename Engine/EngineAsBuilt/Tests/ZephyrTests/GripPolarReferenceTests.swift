import XCTest
@testable import ZephyrCore

/// Polar/ortho reference selection for grip drags.
///
/// During a vertex/midpoint grip drag there is no command reference point,
/// so polar tracking silently never fired. The fix measures the drag
/// displacement from the grip's original position; every other grip kind
/// keeps legacy behavior (no reference).
@MainActor
final class GripPolarReferenceTests: XCTestCase {

    private let origin = Vector3(x: 3, y: 4, z: 0)
    private let handle = UUID()

    func testVertexDragTracksFromOrigin() {
        XCTAssertEqual(
            SnapArbitration.gripStretchReferencePoint(
                gripActive: true,
                gripType: .vertex(entity: handle, index: 0),
                gripStart: origin),
            origin)
    }

    func testMidpointDragTracksFromOrigin() {
        XCTAssertEqual(
            SnapArbitration.gripStretchReferencePoint(
                gripActive: true,
                gripType: .midpoint(entity: handle, betweenA: 0, andB: 1),
                gripStart: origin),
            origin)
    }

    func testRotationGripHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: true, gripType: .rotation, gripStart: origin))
    }

    func testCornerGripHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: true, gripType: .corner(index: 0), gripStart: origin))
    }

    func testCenterGripHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: true, gripType: .center, gripStart: origin))
    }

    func testArrayGripHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: true, gripType: .arrayBase, gripStart: origin))
    }

    func testInactiveGripHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: false,
            gripType: .vertex(entity: handle, index: 0),
            gripStart: origin))
    }

    func testMissingOriginHasNoPolarReference() {
        XCTAssertNil(SnapArbitration.gripStretchReferencePoint(
            gripActive: true,
            gripType: .vertex(entity: handle, index: 0),
            gripStart: nil))
    }
}
