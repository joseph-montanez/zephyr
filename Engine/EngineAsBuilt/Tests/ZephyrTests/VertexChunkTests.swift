import XCTest
@testable import ZephyrCore

/// Chunked vertex uploads: large tessellations split into driver-safe
/// buffers without changing what gets drawn. All GPU pipelines here are
/// LIST topologies, so cutting a batch mid-run into consecutive same-pipe
/// draws is pixel-identical as long as order and vertex coverage hold.
@MainActor
final class VertexChunkTests: XCTestCase {

    private func batch(first: UInt32, count: UInt32, pipe: CADPipelineType = .triangle) -> CADDrawBatch {
        CADDrawBatch(pipelineType: pipe, firstVertex: first, vertexCount: count)
    }

    private func flattened(_ chunks: [[CADDrawBatch]]) -> [CADDrawBatch] {
        chunks.flatMap { $0 }
    }

    func testSmallBuildStaysWhole() {
        let batches = [batch(first: 0, count: 6), batch(first: 6, count: 12, pipe: .line)]
        let chunks = CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 2)
        XCTAssertEqual(chunks.first?.first?.firstVertex, 0)
    }

    func testBatchesSplitAcrossChunksWithRebasedOffsets() {
        let batches = [batch(first: 0, count: 6), batch(first: 6, count: 12), batch(first: 18, count: 6)]
        let chunks = CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 10)
        // 24 verts over a 10-vert budget: runs must not merge across the cut,
        // and every triangle batch piece stays a multiple of 3 (splits land
        // on primitive boundaries, never mid-triangle).
        XCTAssertGreaterThan(chunks.count, 1)
        let flat = flattened(chunks)
        for piece in flat {
            XCTAssertEqual(piece.vertexCount % 3, 0, "triangle piece not aligned")
        }
        // Order preserved, vertex coverage identical and contiguous.
        var global = 0
        for (ci, chunk) in chunks.enumerated() {
            var local: UInt32 = 0
            for b in chunk {
                XCTAssertEqual(b.firstVertex, local, "chunk \(ci) not rebased")
                local += b.vertexCount
                global += Int(b.vertexCount)
            }
        }
        XCTAssertEqual(global, 24)
        // Pipeline identity survives the split.
        XCTAssertTrue(flat.allSatisfy { $0.pipelineType == .triangle })
    }

    func testOversizedSingleBatchSplits() {
        let batches = [batch(first: 0, count: 30)]
        let chunks = CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 10)
        // Budget 10 with triangle granularity 3: pieces are 9, 9, 9, 3.
        XCTAssertEqual(chunks.count, 4)
        for chunk in chunks {
            XCTAssertEqual(chunk.count, 1)
            XCTAssertEqual(chunk.first?.firstVertex, 0)
            XCTAssertEqual((chunk.first?.vertexCount ?? 0) % 3, 0)
        }
        let total = chunks.reduce(0) { $0 + Int($1.first!.vertexCount) }
        XCTAssertEqual(total, 30)
    }

    /// Regression: the real 4M-vert cap is 1 mod 3, so a naive split
    /// phase-shifts every triangle after the first chunk (los-angeles.dxf
    /// rendered as map-spanning streaks). Chunk totals must stay aligned.
    func testRealCapKeepsTrianglesAligned() {
        let cap = CADVertexBufferBuilder.maxVertsPerChunk
        // ~2x cap, itself a multiple of 3 (well-formed triangle batch).
        let batches = [batch(first: 0, count: 8_388_612)]
        let chunks = CADVertexBufferBuilder.chunkBatches(batches)
        XCTAssertEqual(chunks.count, 3)
        for chunk in chunks {
            let total = chunk.reduce(UInt32(0)) { $0 + $1.vertexCount }
            XCTAssertEqual(total % 3, 0)
            XCTAssertLessThanOrEqual(Int(total), cap)
        }
    }

    func testPipelineRunsNeverMergeAcrossChunks() {
        let batches = [
            batch(first: 0, count: 8, pipe: .line),
            batch(first: 8, count: 8, pipe: .triangle),
            batch(first: 16, count: 8, pipe: .line),
        ]
        let chunks = CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(flattened(chunks).map(\.pipelineType), [.line, .triangle, .line])
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(CADVertexBufferBuilder.chunkBatches([], maxVertsPerChunk: 10).count, 0)
    }

    func testDegenerateBudgetFallsBackToWhole() {
        let batches = [batch(first: 0, count: 6)]
        XCTAssertEqual(CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 0).count, 1)
        XCTAssertEqual(CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: -1).count, 1)
    }
}
