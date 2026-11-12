import XCTest
@testable import ZephyrCore

/// Quantized zoom bands for screen-constant line widths: a wheel tick
/// (x1.375) must not force a main-thread vertex rebuild, while large
/// moves must still refresh widths promptly.
@MainActor
final class ZoomBandTests: XCTestCase {

    func testBandOrigin() {
        XCTAssertEqual(EngineRenderer.lineWidthZoomBand(1.0), 0)
        XCTAssertEqual(EngineRenderer.lineWidthZoomBand(2.0), 2)
        XCTAssertEqual(EngineRenderer.lineWidthZoomBand(0.5), -2)
    }

    func testBandMonotonic() {
        XCTAssertLessThanOrEqual(
            EngineRenderer.lineWidthZoomBand(1.0),
            EngineRenderer.lineWidthZoomBand(1.375))
        XCTAssertLessThan(
            EngineRenderer.lineWidthZoomBand(1.0),
            EngineRenderer.lineWidthZoomBand(2.0))
    }

    func testWheelTickFromBandFloorStaysStable() {
        // 1.0 sits at a band floor, so x1.375 lands in the same band:
        // no width refresh needed.
        XCTAssertTrue(EngineRenderer.isLineWidthZoomStable(1.375, 1.0))
    }

    func testLargeMoveIsUnstable() {
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(1.5, 1.0))
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(2.0, 1.0))
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(1.5125, 1.1))
    }

    func testHysteresisAbsorbsEdgeFlutter() {
        // Adjacent bands but only 3.6% apart: reference band wins, so
        // hovering near an edge does not flap rebuilds.
        XCTAssertTrue(EngineRenderer.isLineWidthZoomStable(1.45, 1.4))
        XCTAssertTrue(EngineRenderer.isLineWidthZoomStable(0.9, 1.0))
    }

    func testNonPositiveZoomIsUnstable() {
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(0, 1.0))
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(1.0, 0))
        XCTAssertFalse(EngineRenderer.isLineWidthZoomStable(-1.0, 1.0))
    }
}
