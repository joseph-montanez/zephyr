import XCTest
@testable import ZephyrCore

/// Pins the anti-hitch policy: curve LOD refreshes and vertex rebuilds are
/// deferred until the camera is idle, and the vertex buffer is prefetched
/// before the viewport reaches its edge so panning never stalls.
@MainActor
final class PanHitchPolicyTests: XCTestCase {

    // MARK: - Idle gate

    func testCameraNotSettledImmediatelyAfterMove() {
        XCTAssertFalse(EngineRenderer.isCameraSettled(nowTicks: 1000, lastMoveTicks: 1000))
    }

    func testCameraNotSettledWhileStillWithinIdleWindow() {
        XCTAssertFalse(EngineRenderer.isCameraSettled(nowTicks: 1000 + 100, lastMoveTicks: 1000))
    }

    func testCameraSettledAfterIdleWindow() {
        XCTAssertTrue(EngineRenderer.isCameraSettled(nowTicks: 1000 + 500, lastMoveTicks: 1000))
    }

    func testCameraNeverSettledWhilePanActive() {
        XCTAssertFalse(EngineRenderer.isCameraSettled(nowTicks: 100_000, lastMoveTicks: 1000, panActive: true))
    }

    func testCameraNeverSettledWhileZoomActive() {
        XCTAssertFalse(EngineRenderer.isCameraSettled(nowTicks: 100_000, lastMoveTicks: 1000, zoomActive: true))
    }

    func testCameraSettledWhenNeverMoved() {
        XCTAssertTrue(EngineRenderer.isCameraSettled(nowTicks: 5000, lastMoveTicks: 0))
    }

    // MARK: - Prefetch

    private func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> ScreenTessellationViewport {
        ScreenTessellationViewport(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func testNoPrefetchWhenCenteredInBuffer() {
        let buffer = rect(0, 0, 200, 200)
        // Viewport exactly centered; threshold 0.7 means prefetch at 70% of half-extent.
        XCTAssertFalse(EngineRenderer.needsPrefetch(viewport: rect(70, 70, 130, 130), buffer: buffer, threshold: 0.7))
    }

    func testPrefetchNearRightEdge() {
        let buffer = rect(0, 0, 200, 200)
        // Right edge at 170: center 140 is 40 from buffer center 100, half-extent 100 => 0.4? adjust:
        // viewport 110..170 centered 140, normalized 0.4 -> not near. Use closer:
        // viewport 140..190 centered 165, normalized 0.65 -> still under 0.7. Go further:
        let near = rect(145, 70, 195, 130)
        XCTAssertTrue(EngineRenderer.needsPrefetch(viewport: near, buffer: buffer, threshold: 0.7))
    }

    func testPrefetchWhenViewportExitsBuffer() {
        let buffer = rect(0, 0, 200, 200)
        XCTAssertTrue(EngineRenderer.needsPrefetch(viewport: rect(150, 70, 210, 130), buffer: buffer, threshold: 0.7))
    }

    func testPrefetchWithReactiveThresholdRequiresExit() {
        let buffer = rect(0, 0, 200, 200)
        // At reactive threshold 1.0, only an exit prefetches.
        XCTAssertFalse(EngineRenderer.needsPrefetch(viewport: rect(145, 70, 195, 130), buffer: buffer, threshold: 1.0))
        XCTAssertTrue(EngineRenderer.needsPrefetch(viewport: rect(150, 70, 210, 130), buffer: buffer, threshold: 1.0))
    }

    func testPrefetchDegenerateBufferNeedsNoPrefetch() {
        let buffer = rect(50, 50, 50, 50)
        XCTAssertFalse(EngineRenderer.needsPrefetch(viewport: rect(50, 50, 50, 50), buffer: buffer, threshold: 0.7))
    }
}
