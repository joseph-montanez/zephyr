import XCTest
@testable import ZephyrCore

@MainActor
final class CurveLODContainmentTests: XCTestCase {

    private func context(
        band: Int,
        viewport: ScreenTessellationViewport?
    ) -> CurveScreenTessellationContext {
        CurveScreenTessellationContext(
            pixelsPerUnit: 1000,
            band: band,
            designZoom: CurveScreenTessellation.designZoom(for: band),
            viewport: viewport)
    }

    func testContainedSameBandSatisfies() {
        let outer = ScreenTessellationViewport(minX: 0, minY: 0, maxX: 200, maxY: 200)
        let inner = ScreenTessellationViewport(minX: 50, minY: 50, maxX: 150, maxY: 150)
        XCTAssertTrue(CADRendererBridge.isCurveLODContainedSatisfied(
            applied: context(band: 9, viewport: outer),
            desired: context(band: 9, viewport: inner)))
    }

    func testDifferentBandNeverSatisfies() {
        let outer = ScreenTessellationViewport(minX: 0, minY: 0, maxX: 200, maxY: 200)
        let inner = ScreenTessellationViewport(minX: 50, minY: 50, maxX: 150, maxY: 150)
        XCTAssertFalse(CADRendererBridge.isCurveLODContainedSatisfied(
            applied: context(band: 9, viewport: outer),
            desired: context(band: 10, viewport: inner)))
    }

    func testEscapedViewportNeverSatisfies() {
        let applied = ScreenTessellationViewport(minX: 0, minY: 0, maxX: 100, maxY: 100)
        let desired = ScreenTessellationViewport(minX: 50, minY: 50, maxX: 150, maxY: 150)
        XCTAssertFalse(CADRendererBridge.isCurveLODContainedSatisfied(
            applied: context(band: 9, viewport: applied),
            desired: context(band: 9, viewport: desired)))
    }

    func testMissingViewportNeverSatisfies() {
        let outer = ScreenTessellationViewport(minX: 0, minY: 0, maxX: 200, maxY: 200)
        XCTAssertFalse(CADRendererBridge.isCurveLODContainedSatisfied(
            applied: context(band: 9, viewport: outer),
            desired: context(band: 9, viewport: nil)))
    }
}
