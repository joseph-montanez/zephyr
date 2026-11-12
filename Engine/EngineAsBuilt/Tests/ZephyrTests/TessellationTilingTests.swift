import XCTest
@testable import ZephyrCore
import SwiftSDL

/// Chunked upload is only correct if tessellated batches tile the vertex
/// buffer contiguously (each batch starts where the previous one ends).
/// This pins that invariant on real tessellator output over nasty inputs
/// (degenerate, zero-length, huge-coordinate, wide, hatch, point, fill),
/// then proves chunking round-trips the exact same vertices and draw
/// coverage. If this ever fails, chunked upload must not ship.
@MainActor
final class TessellationTilingTests: XCTestCase {

    private func line(_ pts: [SDL_FPoint], weight: Double = 0.25) -> TessInput {
        TessInput(
            type: pts.count == 2 ? .line : .lines,
            points: pts, rects: [], corners: [],
            color: (255, 255, 255, 255),
            lineWeight: weight, geomWidth: 0.0,
            entityIndex: 7)
    }

    private func nastyInputs() -> [TessInput] {
        var sine: [SDL_FPoint] = []
        for i in 0..<500 {
            let x = Float(i) * 0.37
            sine.append(SDL_FPoint(x: x, y: sin(x) * 10.0))
        }
        return [
            line([SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 10, y: 0)]),
            line([SDL_FPoint(x: 5, y: 5)]), // degenerate: single point
            line([SDL_FPoint(x: 3, y: 3), SDL_FPoint(x: 3, y: 3)]), // zero-length
            line(sine),
            line([SDL_FPoint(x: -1e9, y: 2e9), SDL_FPoint(x: 1e9, y: -2e9)]),
            line([SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 4, y: 4)], weight: 0.5),
            TessInput(
                type: .fillRect, points: [],
                rects: [SDL_FRect(x: 0, y: 0, w: 3, h: 3)], corners: [],
                color: (255, 0, 0, 255), lineWeight: 0.25, geomWidth: 0.0,
                entityIndex: 9),
            TessInput(
                type: .point, points: [SDL_FPoint(x: 42, y: 42)],
                rects: [], corners: [],
                color: (0, 255, 0, 255), lineWeight: 0.0, geomWidth: 0.0,
                entityIndex: 11),
            TessInput(
                type: .line,
                points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: Float.nan, y: 1)],
                rects: [], corners: [],
                color: (255, 255, 255, 255), lineWeight: 0.25, geomWidth: 0.0,
                entityIndex: 13),
        ]
    }

    private func tessellate(_ inputs: [TessInput], hairlines: Bool) -> VertexBuildResult? {
        CADVertexBufferBuilder.tessellate(
            inputs,
            cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: hairlines,
            region: (minX: -1e12, minY: -1e12, maxX: 1e12, maxY: 1e12),
            mutationGen: 0)
    }

    private func assertTilesAndRoundTrips(_ result: VertexBuildResult, file: StaticString = #file, line: UInt = #line) {
        // Batches tile [0, vertexCount) with no gaps or overlaps.
        var cursor: UInt32 = 0
        for batch in result.batches {
            XCTAssertEqual(batch.firstVertex, cursor, "gap or overlap", file: file, line: line)
            cursor += batch.vertexCount
        }
        XCTAssertEqual(Int(cursor), result.vertices.count, file: file, line: line)

        // Chunking at several budgets preserves every vertex and the
        // full draw coverage in order.
        for budget in [4, 17, 10_000_000] {
            let chunks = CADVertexBufferBuilder.chunkBatches(result.batches, maxVertsPerChunk: budget)
            var drawn = 0
            for chunk in chunks {
                XCTAssertLessThanOrEqual(
                    chunk.reduce(0) { $0 + Int($1.vertexCount) },
                    budget, file: file, line: line)
                var local: UInt32 = 0
                for batch in chunk {
                    XCTAssertEqual(batch.firstVertex, local, file: file, line: line)
                    local += batch.vertexCount
                    drawn += Int(batch.vertexCount)
                }
            }
            XCTAssertEqual(drawn, result.vertices.count, file: file, line: line)
        }
    }

    func testRealOutputTilesAndRoundTrips() {
        for hairlines in [false, true] {
            guard let result = tessellate(nastyInputs(), hairlines: hairlines) else {
                XCTFail("tessellate returned nil (cancelled?) hairlines=\(hairlines)")
                continue
            }
            XCTAssertFalse(result.batches.isEmpty)
            assertTilesAndRoundTrips(result)
        }
    }

    func testNaNSegmentsAreSkipped() {
        // Non-finite endpoints are undefined behavior for the GPU and have
        // removed devices: they must never reach a vertex buffer, while
        // neighboring finite geometry tessellates normally.
        let nan = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: Float.nan, y: 1)],
            rects: [], corners: [],
            color: (255, 255, 255, 255), lineWeight: 0.25, geomWidth: 0.0,
            entityIndex: 1)
        let sane = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 7, y: 0)],
            rects: [], corners: [],
            color: (255, 255, 255, 255), lineWeight: 0.25, geomWidth: 0.0,
            entityIndex: 2)
        guard let mixed = tessellate([nan, sane], hairlines: false) else {
            XCTFail("tessellate returned nil")
            return
        }
        // The NaN input contributes no vertices; the sane one does.
        XCTAssertEqual(mixed.vertices.count, 2)
        XCTAssertFalse(mixed.vertices.contains { !$0.x.isFinite || !$0.y.isFinite })
    }

    func testChunkedUploadCoversEveryVertexOnce() {
        // End-to-end shape of applyVertexBuild's slicing: walk chunks the
        // way the uploader does and prove the union is exactly the buffer.
        guard let result = tessellate(nastyInputs(), hairlines: true) else {
            XCTFail("tessellate returned nil")
            return
        }
        let chunks = CADVertexBufferBuilder.chunkBatches(result.batches, maxVertsPerChunk: 9)
        XCTAssertGreaterThan(chunks.count, 1)
        var globalOffset = 0
        var covered = 0
        for chunk in chunks {
            let count = chunk.reduce(0) { $0 + Int($1.vertexCount) }
            XCTAssertGreaterThan(count, 0)
            // Slice bounds must stay inside the vertex buffer.
            XCTAssertLessThanOrEqual(globalOffset + count, result.vertices.count)
            globalOffset += count
            covered += count
        }
        XCTAssertEqual(covered, result.vertices.count)
        XCTAssertEqual(globalOffset, result.vertices.count)
    }
}
