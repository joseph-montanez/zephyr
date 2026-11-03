import XCTest
@testable import ZephyrCore

/// PAN press-and-hold state machine (AutoCAD parity): motion pans only while
/// the button is held. Releasing stops the pan but stays armed for the next
/// drag; hover without a press must never produce a delta.
///
/// `PanPressDragTracker` is the engine-free core of `PanCommand`, so these
/// transitions run without a live `PhrostEngine`. The thin wiring
/// (press on `handleMouseClick`, release on `handleMouseUp`, camera pan on
/// motion) lives in `PanCommand` and the `handleToolMouseUp` dispatch.
@MainActor
final class PanPressDragTrackerTests: XCTestCase {

    func testMotionWithoutPressProducesNoDelta() {
        var drag = PanPressDragTracker()
        XCTAssertFalse(drag.isDragging)
        XCTAssertNil(drag.motion(toX: 100, y: 100))
    }

    func testPressThenMotionProducesDelta() {
        var drag = PanPressDragTracker()
        drag.press(atX: 10, y: 20)
        XCTAssertTrue(drag.isDragging)
        let delta = drag.motion(toX: 30, y: 50)
        XCTAssertNotNil(delta)
        XCTAssertEqual(Double(delta!.dx), 20, accuracy: 1e-6)
        XCTAssertEqual(Double(delta!.dy), 30, accuracy: 1e-6)
    }

    func testMotionTracksIncrementallyWhileHeld() {
        var drag = PanPressDragTracker()
        drag.press(atX: 0, y: 0)
        _ = drag.motion(toX: 10, y: 0)
        let second = drag.motion(toX: 25, y: -5)
        XCTAssertNotNil(second)
        XCTAssertEqual(Double(second!.dx), 15, accuracy: 1e-6)
        XCTAssertEqual(Double(second!.dy), -5, accuracy: 1e-6)
    }

    func testReleaseStopsDeltasButStaysArmed() {
        var drag = PanPressDragTracker()
        drag.press(atX: 0, y: 0)
        _ = drag.motion(toX: 10, y: 10)
        drag.release()
        XCTAssertFalse(drag.isDragging)
        // The reported bug: after release, hover must not pan.
        XCTAssertNil(drag.motion(toX: 999, y: 999))
    }

    func testSecondPressAfterReleasePansAgain() {
        var drag = PanPressDragTracker()
        drag.press(atX: 0, y: 0)
        _ = drag.motion(toX: 10, y: 10)
        drag.release()
        drag.press(atX: 100, y: 100)
        XCTAssertTrue(drag.isDragging)
        let delta = drag.motion(toX: 110, y: 90)
        XCTAssertNotNil(delta)
        XCTAssertEqual(Double(delta!.dx), 10, accuracy: 1e-6)
        XCTAssertEqual(Double(delta!.dy), -10, accuracy: 1e-6)
    }

    func testCancelResetsToIdle() {
        var drag = PanPressDragTracker()
        drag.press(atX: 5, y: 5)
        drag.cancel()
        XCTAssertFalse(drag.isDragging)
        XCTAssertNil(drag.motion(toX: 50, y: 50))
    }
}
