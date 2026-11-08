import XCTest
import ImGui
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

    func testStrayRelativeModeIsForcedClear() {
        // SDL reports relative mode but no gesture claims it: a stranded
        // miss (lost mouse-up, focus change, float-window mismatch) that
        // parks the cursor at the window center.
        XCTAssertTrue(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: true, radialCapturing: false, panActive: false))
    }

    func testClaimedRelativeModeIsKept() {
        // An active radial zone drag or middle-button pan owns the mode.
        XCTAssertFalse(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: true, radialCapturing: true, panActive: false))
        XCTAssertFalse(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: true, radialCapturing: false, panActive: true))
        XCTAssertFalse(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: true, radialCapturing: true, panActive: true))
    }

    func testRelativeModeOffNeedsNoClear() {
        // Nothing to reconcile when SDL already reports absolute mode.
        XCTAssertFalse(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: false, radialCapturing: false, panActive: false))
        XCTAssertFalse(RadialNavCapture.shouldForceClear(
            sdlReportsRelative: false, radialCapturing: true, panActive: true))
    }
    func testRawPositionPrefersActiveMoveDrag() {
        // Zone-1 move drag: the nav follows the cursor minus the grab point,
        // ignoring any remembered spot. This is the drag that used to mirror
        // across windows when the offset was shared.
        let p = RadialNavCapture.resolveRawPosition(
            dragOffset: ImVec2(x: 10, y: 20),
            pinned: ImVec2(x: 1, y: 1),
            justShown: false,
            mousePos: ImVec2(x: 100, y: 120),
            defaultPosition: ImVec2(x: 0, y: 0))
        XCTAssertEqual(p.x, 90)
        XCTAssertEqual(p.y, 100)
    }

    func testRawPositionFallsBackToRememberedSpot() {
        let p = RadialNavCapture.resolveRawPosition(
            dragOffset: nil,
            pinned: ImVec2(x: 7, y: 9),
            justShown: false,
            mousePos: ImVec2(x: 100, y: 120),
            defaultPosition: ImVec2(x: 0, y: 0))
        XCTAssertEqual(p.x, 7)
        XCTAssertEqual(p.y, 9)
    }

    func testRawPositionIgnoresStaleSpotWhenJustReshown() {
        // A reopened nav re-seats at the default even with a remembered spot
        // (e.g. from a larger window), which the clamp then keeps on-screen.
        let p = RadialNavCapture.resolveRawPosition(
            dragOffset: nil,
            pinned: ImVec2(x: 7, y: 9),
            justShown: true,
            mousePos: ImVec2(x: 100, y: 120),
            defaultPosition: ImVec2(x: 5, y: 6))
        XCTAssertEqual(p.x, 5)
        XCTAssertEqual(p.y, 6)
    }

    func testRawPositionDefaultIsLazy() {
        // The default is an autoclosure: a drag or remembered spot must not
        // pay for the pane walk.
        var evaluated = false
        func fallback() -> ImVec2 {
            evaluated = true
            return ImVec2(x: 0, y: 0)
        }
        let p = RadialNavCapture.resolveRawPosition(
            dragOffset: ImVec2(x: 1, y: 1),
            pinned: nil,
            justShown: false,
            mousePos: ImVec2(x: 10, y: 10),
            defaultPosition: fallback())
        XCTAssertEqual(p.x, 9)
        XCTAssertEqual(p.y, 9)
        XCTAssertFalse(evaluated)
    }
}
