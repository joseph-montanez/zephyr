import XCTest
@testable import ZephyrCore
import SwiftSDL

/// Batch merging must collapse consecutive same-pipeline inputs however
/// their line weights differ (width is baked per-vertex; the batch key
/// must not fragment it), while never reordering across pipelines.
@MainActor
final class BatchMergeTests: XCTestCase {

    private func lineInput(weight: Double) -> TessInput {
        TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 10, y: 0)],
            rects: [],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: weight,
            geomWidth: 0.0,
            entityIndex: 1)
    }

    private func fillInput() -> TessInput {
        TessInput(
            type: .fillRect,
            points: [],
            rects: [SDL_FRect(x: 0, y: 0, w: 10, h: 10)],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.25,
            geomWidth: 0.0,
            entityIndex: 2)
    }

    private func tessellate(_ inputs: [TessInput]) -> VertexBuildResult? {
        CADVertexBufferBuilder.tessellate(
            inputs,
            cameraZoom: 1.0,
            pixelScale: 1.0,
            antiAliasLines: false,
            hairlineQuads: false,
            region: (minX: -100, minY: -100, maxX: 100, maxY: 100),
            mutationGen: 0)
    }

    /// Same pipeline (wide-line quads), different weights: one draw call.
    /// Width lives in the vertices; the batch key must not split it.
    func testSamePipelineDifferentWeightsMerge() {
        let result = tessellate([lineInput(weight: 0.5), lineInput(weight: 1.0)])
        XCTAssertEqual(result?.batches.count, 1)
        XCTAssertEqual(result?.batches.first?.pipelineType, .triangle)
    }

    /// Different pipelines must never merge or reorder: fill, hairline,
    /// fill stays three batches in order (plain-line path).
    func testDifferentPipelinesNeverMergeOrReorder() {
        let hairline = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 5, y: 5)],
            rects: [],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.25,
            geomWidth: 0.0,
            entityIndex: 3)
        let result = tessellate([fillInput(), hairline, fillInput()])
        XCTAssertEqual(result?.batches.count, 3)
        XCTAssertEqual(result?.batches.map(\.pipelineType),
                       [.triangle, .line, .triangle])
    }

    /// With hairline quads (the app's rendering path), thin lines, fills,
    /// and points all share the triangle pipeline and merge into ONE draw
    /// call, preserving input order. This is the 24k-draws-to-1 collapse.
    func testHairlineQuadsCollapseEverythingIntoOneBatch() {
        let thin = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 5, y: 5)],
            rects: [],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.25,
            geomWidth: 0.0,
            entityIndex: 3)
        let point = TessInput(
            type: .point,
            points: [SDL_FPoint(x: 1, y: 1)],
            rects: [],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.0,
            geomWidth: 0.0,
            entityIndex: 4)
        let result = CADVertexBufferBuilder.tessellate(
            [fillInput(), thin, point, lineInput(weight: 0.0)],
            cameraZoom: 1.0,
            pixelScale: 1.0,
            antiAliasLines: false,
            hairlineQuads: true,
            region: (minX: -100, minY: -100, maxX: 100, maxY: 100),
            mutationGen: 0)
        XCTAssertEqual(result?.batches.count, 1)
        XCTAssertEqual(result?.batches.first?.pipelineType, .triangle)
        // Order preserved: fill verts come before thin-line verts.
        let entityOrder = (result?.vertices ?? []).map(\.entityIndex)
        XCTAssertEqual(entityOrder.first, 2)
        XCTAssertEqual(entityOrder.last, 1)
    }

    /// Pan-proxy runs stay isolated from normal runs of the same pipeline.
    func testPanProxyStaysIsolated() {
        let proxy = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 10, y: 0)],
            rects: [],
            corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.5,
            geomWidth: 0.0,
            entityIndex: 1,
            isHatchLine: false,
            hatchSpacing: 0.0,
            isPanProxy: true)
        let result = tessellate([proxy, lineInput(weight: 0.5)])
        XCTAssertEqual(result?.batches.count, 2)
    }
}
