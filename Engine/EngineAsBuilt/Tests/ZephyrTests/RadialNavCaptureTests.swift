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

    func testClampedPositionKeepsVisibleSpot() {
        let p = RadialNavCapture.clampedPosition(x: 100, y: 120, dw: 1920, dh: 1080, size: 320)
        XCTAssertEqual(p.x, 100)
        XCTAssertEqual(p.y, 120)
    }

    func testClampedPositionPullsIntoShrunkenWindow() {
        // Remembered spot from a larger window lands off-screen bottom-right.
        let p = RadialNavCapture.clampedPosition(x: 1580, y: 740, dw: 1280, dh: 720, size: 320)
        XCTAssertEqual(p.x, 960)
        XCTAssertEqual(p.y, 400)
    }

    func testClampedPositionFloorsAtOrigin() {
        let p = RadialNavCapture.clampedPosition(x: -40, y: -8, dw: 1920, dh: 1080, size: 320)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 0)
    }

    func testClampedPositionTinyWindowPinsToOrigin() {
        // Window smaller than the nav: the origin is the only visible spot.
        let p = RadialNavCapture.clampedPosition(x: 50, y: 50, dw: 200, dh: 200, size: 320)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 0)
    }
}
