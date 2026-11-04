import XCTest
import Foundation
@testable import ZephyrCore

/// Ghost-preview geometry behind the PLACEVIEW/PLACECALLOUT canvas click:
/// centered paper-frame corners in Y-up paper coordinates. Overlay drawing
/// itself needs a live engine/canvas, so it stays covered by the manual
/// interactive run.
final class PlacePreviewTests: XCTestCase {

    func testUnitRectCenteredAtOrigin() {
        let corners = PlacePreview.rectCorners(centerX: 0, centerY: 0, width: 2, height: 2)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(corners[0].x, -1, accuracy: 1e-12)
        XCTAssertEqual(corners[0].y, -1, accuracy: 1e-12)
        XCTAssertEqual(corners[1].x, 1, accuracy: 1e-12)
        XCTAssertEqual(corners[1].y, -1, accuracy: 1e-12)
        XCTAssertEqual(corners[2].x, 1, accuracy: 1e-12)
        XCTAssertEqual(corners[2].y, 1, accuracy: 1e-12)
        XCTAssertEqual(corners[3].x, -1, accuracy: 1e-12)
        XCTAssertEqual(corners[3].y, 1, accuracy: 1e-12)
    }

    func testOffsetCenterKeepsSize() {
        let corners = PlacePreview.rectCorners(centerX: 5, centerY: 7, width: 4, height: 2)
        XCTAssertEqual(corners[0].x, 3, accuracy: 1e-12)
        XCTAssertEqual(corners[0].y, 6, accuracy: 1e-12)
        XCTAssertEqual(corners[2].x, 7, accuracy: 1e-12)
        XCTAssertEqual(corners[2].y, 8, accuracy: 1e-12)
        // Y-up paper frame: top edge above bottom edge, right of left.
        XCTAssertGreaterThan(corners[2].y, corners[0].y)
        XCTAssertGreaterThan(corners[1].x, corners[0].x)
    }

    func testZeroSizeCollapsesToCenter() {
        let corners = PlacePreview.rectCorners(centerX: 5, centerY: -3, width: 0, height: 0)
        XCTAssertTrue(corners.allSatisfy { $0.x == 5 && $0.y == -3 })
    }
}
