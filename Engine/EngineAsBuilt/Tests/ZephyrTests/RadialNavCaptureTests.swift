import XCTest
@testable import ZephyrCore

@MainActor
final class RadialNavCaptureTests: XCTestCase {

    func testDeltaZonesCaptureRelativeMouse() {
        // Right (zoom in), bottom (pan), left (zoom out), outer ring (rotate).
        XCTAssertTrue(RadialNavCapture.wantsRelativeCapture(zone: 2))
        XCTAssertTrue(RadialNavCapture.wantsRelativeCapture(zone: 3))
        XCTAssertTrue(RadialNavCapture.wantsRelativeCapture(zone: 4))
        XCTAssertTrue(RadialNavCapture.wantsRelativeCapture(zone: 6))
    }

    func testAbsoluteZonesNeverCaptureRelativeMouse() {
        // Center (nav move/close) and top (extents) are absolute gestures;
        // capturing for them parks the cursor mid-window with no warp-back.
        XCTAssertFalse(RadialNavCapture.wantsRelativeCapture(zone: 0))
        XCTAssertFalse(RadialNavCapture.wantsRelativeCapture(zone: 1))
        XCTAssertFalse(RadialNavCapture.wantsRelativeCapture(zone: 5))
        XCTAssertFalse(RadialNavCapture.wantsRelativeCapture(zone: nil))
    }

    func testNavMoveDragKeepsCursorAtDropPoint() {
        // Dragging the nav itself (zone 1) owes no warp-back.
        XCTAssertFalse(RadialNavCapture.wantsWarpBack(activeZone: 1, wasDragged: true))
    }

    func testOtherZonesWarpBackToPressPoint() {
        XCTAssertTrue(RadialNavCapture.wantsWarpBack(activeZone: 3, wasDragged: true))
        XCTAssertTrue(RadialNavCapture.wantsWarpBack(activeZone: 2, wasDragged: true))
        XCTAssertTrue(RadialNavCapture.wantsWarpBack(activeZone: 6, wasDragged: true))
        XCTAssertTrue(RadialNavCapture.wantsWarpBack(activeZone: 1, wasDragged: false))
        XCTAssertTrue(RadialNavCapture.wantsWarpBack(activeZone: nil, wasDragged: true))
    }

    func testLostMouseUpForcesRelease() {
        // ImGui stuck active while hardware is up: the up event was lost.
        XCTAssertTrue(RadialNavCapture.shouldForceRelease(
            wasActive: true, isActive: true, physicalLeftDown: false))
    }

    func testHeldButtonNeverForcesRelease() {
        XCTAssertFalse(RadialNavCapture.shouldForceRelease(
            wasActive: true, isActive: true, physicalLeftDown: true))
        XCTAssertFalse(RadialNavCapture.shouldForceRelease(
            wasActive: false, isActive: true, physicalLeftDown: false))
        XCTAssertFalse(RadialNavCapture.shouldForceRelease(
            wasActive: true, isActive: false, physicalLeftDown: false))
        XCTAssertFalse(RadialNavCapture.shouldForceRelease(
            wasActive: false, isActive: false, physicalLeftDown: false))
    }
}
