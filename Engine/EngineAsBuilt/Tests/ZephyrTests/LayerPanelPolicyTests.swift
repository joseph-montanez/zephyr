import XCTest
@testable import ZephyrCore

/// Layers panel pixel math: row zones, toolbar wrapping, scaling.
final class LayerPanelPolicyTests: XCTestCase {

    func testRowZonesAreOrderedAndNonOverlapping() {
        for frame in [Float(18), 22, 26, 33] {
            let zones = LayerPanelPolicy(frameHeight: frame).rowZones
            XCTAssertLessThan(0, zones.statusEnd)
            XCTAssertLessThan(zones.statusEnd, zones.eyeEnd)
            XCTAssertLessThan(zones.eyeEnd, zones.swatchEnd)
            XCTAssertLessThan(zones.swatchEnd, zones.nameStart)
            XCTAssertLessThan(zones.swatchRect.x0, zones.swatchRect.x1)
            XCTAssertGreaterThan(zones.swatchRect.x0, zones.eyeEnd)
            XCTAssertLessThan(zones.swatchRect.x1, zones.swatchEnd)
            XCTAssertGreaterThan(zones.propsWidth, 0)
            XCTAssertGreaterThan(zones.indicatorWidth, 0)
        }
    }

    func testToolbarColumnsScaleWithWidth() {
        let policy = LayerPanelPolicy(frameHeight: 22)
        XCTAssertEqual(policy.toolbarButtonSize, 28, accuracy: 0.01)
        XCTAssertEqual(policy.toolbarColumns(availableWidth: 10), 1)
        XCTAssertEqual(policy.toolbarColumns(availableWidth: 240), 7)
        XCTAssertEqual(policy.toolbarColumns(availableWidth: 460), 14)
        XCTAssertEqual(policy.toolbarColumns(availableWidth: 800), 25)
    }

    func testMetricsScaleWithFrameHeight() {
        let base = LayerPanelPolicy(frameHeight: 22)
        let big = LayerPanelPolicy(frameHeight: 44)
        XCTAssertEqual(big.scale, base.scale * 2, accuracy: 0.01)
        XCTAssertEqual(
            big.toolbarButtonSize, base.toolbarButtonSize * 2,
            accuracy: 0.01)
        XCTAssertGreaterThan(big.rowHeight, base.rowHeight)
    }

    func testWrapRows() {
        XCTAssertEqual(LayerPanelPolicy.wrapRows(count: 0, columns: 4), 0)
        XCTAssertEqual(LayerPanelPolicy.wrapRows(count: 1, columns: 4), 1)
        XCTAssertEqual(LayerPanelPolicy.wrapRows(count: 8, columns: 4), 2)
        XCTAssertEqual(LayerPanelPolicy.wrapRows(count: 9, columns: 4), 3)
        XCTAssertEqual(LayerPanelPolicy.wrapRows(count: 5, columns: 0), 0)
    }
}
