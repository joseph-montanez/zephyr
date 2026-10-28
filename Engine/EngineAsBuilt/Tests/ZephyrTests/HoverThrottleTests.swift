import XCTest
@testable import ZephyrCore

/// P2 (selection cursor lag): CPU hover hit-tests must coalesce during
/// mouse-move bursts instead of running once per SDL motion event.
@MainActor
final class HoverThrottleTests: XCTestCase {

    func testNoHoverTargetAlwaysRuns() {
        // First highlight must appear promptly, even for a tiny move
        // immediately after the previous test.
        XCTAssertTrue(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 0, threshold: 6,
            hasHoverTarget: false, ticksSinceLastTest: 0))
    }

    func testRecentRetestSkipsWhileHovering() {
        XCTAssertFalse(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 100, threshold: 6,
            hasHoverTarget: true, ticksSinceLastTest: 0))
        XCTAssertFalse(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 100, threshold: 6,
            hasHoverTarget: true,
            ticksSinceLastTest: CADHoverCoordinator.hoverRetestIntervalTicks - 1))
    }

    func testIntervalExpiryPlusDistanceRuns() {
        XCTAssertTrue(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 100, threshold: 6,
            hasHoverTarget: true,
            ticksSinceLastTest: CADHoverCoordinator.hoverRetestIntervalTicks))
    }

    func testSmallMoveSkipsAfterInterval() {
        // Distance gate preserved: stationary cursor does not re-test.
        XCTAssertFalse(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 1, threshold: 6,
            hasHoverTarget: true, ticksSinceLastTest: 1000))
        XCTAssertTrue(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 3.01, threshold: 6,
            hasHoverTarget: true, ticksSinceLastTest: 1000))
    }

    func testTickWraparoundDoesNotFlood() {
        // SDL_GetTicks wraps every ~49 days; &- keeps the delta small.
        let last: UInt64 = .max - 3
        let now: UInt64 = 2
        XCTAssertFalse(CADHoverCoordinator.shouldRunHoverTest(
            moveDistance: 100, threshold: 6,
            hasHoverTarget: true, ticksSinceLastTest: now &- last))
    }
}
