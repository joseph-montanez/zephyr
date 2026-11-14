import XCTest
@testable import ZephyrCore

/// Regression tests for the lazy loop's RenderGate wake predicate. Each
/// deferred-work term alone must require a frame; an all-clear engine
/// must not. The invisible-document exclusion is tested through the
/// visible-set helper contract (flags only count when a frame will
/// service them), so an invisible tab can never hold the loop awake.
@MainActor
final class RenderGateTests: XCTestCase {

    private func makeContext() -> WindowRenderContext {
        WindowRenderContext(
            geometry: GeometryManager(),
            sprites: SpriteManager(),
            bridge: CADRendererBridge())
    }

    private func settledContext() -> WindowRenderContext {
        let ctx = makeContext()
        ctx.regenGeneration = 3
        ctx.appliedGeneration = 3
        ctx.regenInFlight = nil
        ctx.vbInFlightToken = nil
        ctx.pendingSwapResult = nil
        return ctx
    }

    func testSettledContextNeedsNoRender() {
        let snap = RenderGate.snapshot(for: settledContext())
        XCTAssertFalse(snap.needsRender)
        XCTAssertFalse(RenderGate.anyContextNeedsRender([snap]))
    }

    func testPendingVertexSwapAloneNeedsRender() {
        let ctx = settledContext()
        ctx.pendingSwapResult = VertexBuildResult(vertices: [], batches: [], vertexCount: 0, regionMinX: 0, regionMinY: 0, regionMaxX: 10, regionMaxY: 10, builtZoom: 1, mutationGen: 0)
        XCTAssertTrue(RenderGate.snapshot(for: ctx).needsRender)
    }

    func testGenerationMismatchAloneNeedsRender() {
        let ctx = settledContext()
        ctx.regenGeneration = 4
        XCTAssertTrue(RenderGate.snapshot(for: ctx).generationMismatch)
        XCTAssertTrue(RenderGate.snapshot(for: ctx).needsRender)
    }

    func testFreshContextNeedsRender() {
        let ctx = makeContext()
        XCTAssertEqual(ctx.regenGeneration, 0)
        XCTAssertEqual(ctx.appliedGeneration, -1)
        XCTAssertTrue(RenderGate.snapshot(for: ctx).needsRender)
    }

    func testRegenInFlightAloneNeedsRender() {
        let ctx = settledContext()
        ctx.regenInFlight = 3
        XCTAssertTrue(RenderGate.snapshot(for: ctx).needsRender)
    }

    func testVertexBuildInFlightAloneNeedsRender() {
        let ctx = settledContext()
        ctx.vbInFlightToken = 7
        XCTAssertTrue(RenderGate.snapshot(for: ctx).needsRender)
    }

    func testAnyContextNeedsRenderUsesOrAcrossContexts() {
        let settled = RenderGate.snapshot(for: settledContext())
        let busyCtx = settledContext()
        busyCtx.pendingSwapResult = VertexBuildResult(vertices: [], batches: [], vertexCount: 0, regionMinX: 0, regionMinY: 0, regionMaxX: 10, regionMaxY: 10, builtZoom: 1, mutationGen: 0)
        let busy = RenderGate.snapshot(for: busyCtx)
        XCTAssertFalse(RenderGate.anyContextNeedsRender([settled]))
        XCTAssertTrue(RenderGate.anyContextNeedsRender([settled, busy]))
    }

    func testEmptySnapshotListNeedsNoRender() {
        XCTAssertFalse(RenderGate.anyContextNeedsRender([]))
    }

    func testGenerationMismatchDoesNotCountDuringLispEvaluation() {
        XCTAssertTrue(RenderGate.generationMismatchCounts(isLispActivelyEvaluating: false))
        XCTAssertFalse(RenderGate.generationMismatchCounts(isLispActivelyEvaluating: true))
    }
}

