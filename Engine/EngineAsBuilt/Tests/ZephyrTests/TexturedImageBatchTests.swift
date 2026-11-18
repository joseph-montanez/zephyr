import XCTest
@testable import ZephyrCore
import SwiftSDL

/// Raster images must composite in draw order with vector geometry: image
/// inputs become `.textured` batches interleaved with vector batches by
/// `sortZ`, merge only with the same asset, and survive vertex-chunk splits
/// with their asset tag intact. All headless (pure tessellation + merge).
@MainActor
final class TexturedImageBatchTests: XCTestCase {

    private func imageInput(
        name: String = "img1",
        origin: Float = 0,
        size: Float = 10,
        sortZ: Double = 500,
        entityIndex: UInt32 = 7
    ) -> TessInput {
        TessInput(
            type: .fillRects,
            points: [],
            rects: [],
            corners: [
                SDL_FPoint(x: origin, y: origin),
                SDL_FPoint(x: origin + size, y: origin),
                SDL_FPoint(x: origin + size, y: origin + size),
                SDL_FPoint(x: origin, y: origin + size),
            ],
            color: (255, 255, 255, 255),
            lineWeight: 0,
            geomWidth: 0,
            entityIndex: entityIndex,
            sortZ: sortZ,
            imageName: name)
    }

    private func lineInput(sortZ: Double = 0, entityIndex: UInt32 = 1) -> TessInput {
        TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 10, y: 0)],
            rects: [],
            corners: [],
            color: (255, 0, 0, 255),
            lineWeight: 1.0,
            geomWidth: 0.0,
            entityIndex: entityIndex,
            sortZ: sortZ)
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

    /// One image input emits one 6-vertex textured batch carrying the asset
    /// tag and entity index, with sprite-matching corner→UV mapping.
    func testImageEmitsTexturedBatch() {
        let result = tessellate([imageInput()])
        XCTAssertEqual(result?.batches.count, 1)
        let batch = result?.batches.first
        XCTAssertEqual(batch?.pipelineType, .textured)
        XCTAssertEqual(batch?.vertexCount, 6)
        XCTAssertEqual(batch?.imageName, "img1")
        XCTAssertEqual(batch?.entityIndex, 7)
        let verts = result?.vertices ?? []
        XCTAssertEqual(verts.count, 6)
        // c0→(0,0), c1→(1,0), c2→(1,1): first triangle.
        XCTAssertEqual(verts[0].u, 0); XCTAssertEqual(verts[0].v, 0)
        XCTAssertEqual(verts[1].u, 1); XCTAssertEqual(verts[1].v, 0)
        XCTAssertEqual(verts[2].u, 1); XCTAssertEqual(verts[2].v, 1)
        XCTAssertEqual(verts[0].entityIndex, 7)
    }

    /// Pre-sorted inputs keep their order through tessellation: a vector
    /// batch, a textured batch, then a vector batch — the screen stacking
    /// the bug report asked for.
    func testImageInterleavesWithVectorsInDrawOrder() {
        let result = tessellate([
            lineInput(sortZ: 0, entityIndex: 1),
            imageInput(sortZ: 500000, entityIndex: 2),
            lineInput(sortZ: 1000000, entityIndex: 3),
        ])
        // Wide lines tessellate to the triangle pipeline: 3 batches total.
        XCTAssertEqual(result?.batches.map(\.pipelineType),
                       [.triangle, .textured, .triangle])
        XCTAssertEqual(result?.batches[1].imageName, "img1")
    }

    /// Adjacent quads of the same image merge into one draw; different
    /// assets never merge (one texture bind per batch).
    func testSameImageMergesDifferentImagesSplit() {
        let merged = tessellate([imageInput(name: "a"), imageInput(name: "a")])
        XCTAssertEqual(merged?.batches.count, 1)
        XCTAssertEqual(merged?.batches.first?.vertexCount, 12)
        let split = tessellate([imageInput(name: "a"), imageInput(name: "b")])
        XCTAssertEqual(split?.batches.count, 2)
        XCTAssertEqual(split?.batches.map(\.imageName), ["a", "b"])
    }

    /// Chunk splits preserve the asset tag, entity index, and triangle
    /// granularity so a split quad never tears.
    func testChunkSplitCarriesImageTag() {
        let result = tessellate([imageInput()])
        let batches = result?.batches ?? []
        XCTAssertEqual(batches.count, 1)
        // Force a mid-quad split: cap below one 6-vertex quad.
        let chunks = CADVertexBufferBuilder.chunkBatches(batches, maxVertsPerChunk: 4)
        XCTAssertEqual(chunks.flatMap({ $0 }).count, 2)
        for batch in chunks.flatMap({ $0 }) {
            XCTAssertEqual(batch.pipelineType, .textured)
            XCTAssertEqual(batch.imageName, "img1")
            XCTAssertEqual(batch.entityIndex, 7)
            XCTAssertEqual(batch.vertexCount % 3, 0)
        }
        XCTAssertEqual(chunks.flatMap({ $0 }).reduce(0) { $0 + Int($1.vertexCount) }, 6)
    }

    /// The gather merge sorts images among vectors by draw-order key and
    /// culls quads outside the region.
    func testMergeSortsImagesAmongVectorsAndCullsRegion() {
        let bridge = CADRendererBridge()
        bridge.imageTessInputs = [
            imageInput(name: "behind", origin: 0, sortZ: 50),
            imageInput(name: "front", origin: 0, sortZ: 150),
            imageInput(name: "far", origin: 1000, sortZ: 250),
        ]
        let vectors = [lineInput(sortZ: 0), lineInput(sortZ: 100), lineInput(sortZ: 200)]
        let region = (minX: -100.0, minY: -100.0, maxX: 100.0, maxY: 100.0)
        let merged = EngineRenderer.mergeImageInputs(
            vectors, region: region, bridge: bridge, origin: .zero)
        // "far" (origin 1000) is culled; the rest interleave by sortZ.
        XCTAssertEqual(merged.map(\.sortZ), [0, 50, 100, 150, 200])
        XCTAssertEqual(merged.compactMap(\.imageName), ["behind", "front"])
    }
}
