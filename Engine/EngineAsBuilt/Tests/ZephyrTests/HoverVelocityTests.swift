import XCTest
@testable import ZephyrCore

/// Whip suppression: fast pointer motion must not pay for (or show) hover
/// highlights; the highlight re-arms as soon as the pointer slows down.
/// Snap is deliberately ungated by this (drafting commands need it at speed);
/// only the hover highlight and the selection-cycling pile are suppressed.
@MainActor
final class HoverVelocityTests: XCTestCase {

    func testFastAlwaysSuppresses() {
        XCTAssertTrue(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 1500, currentlySuppressed: false))
        XCTAssertTrue(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 8000, currentlySuppressed: false))
        XCTAssertTrue(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 800, currentlySuppressed: true))
    }

    func testSlowAlwaysRearms() {
        XCTAssertFalse(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 0, currentlySuppressed: true))
        XCTAssertFalse(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 600, currentlySuppressed: true))
        XCTAssertFalse(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 599, currentlySuppressed: false))
    }

    func testHysteresisBandHoldsState() {
        // Between the thresholds the current state wins: no flapping when
        // cruising at edge speeds.
        XCTAssertTrue(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 1000, currentlySuppressed: true))
        XCTAssertFalse(CADHoverCoordinator.shouldSuppressHover(
            speedPxPerSec: 1000, currentlySuppressed: false))
    }
}
