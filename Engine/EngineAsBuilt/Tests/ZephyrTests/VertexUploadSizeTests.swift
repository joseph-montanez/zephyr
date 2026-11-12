import XCTest
@testable import ZephyrCore

/// Vertex upload sizing: the byte size must fit the 32-bit GPU size field
/// and the single-allocation budget. Oversized builds are refused with a
/// clear message instead of killing the GPU device (DXGI 0x887A0006).
@MainActor
final class VertexUploadSizeTests: XCTestCase {

    func testSmallBuildSizesCorrectly() {
        let expected = UInt64(100 * MemoryLayout<CADVertex>.stride)
        XCTAssertEqual(
            CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: 100),
            expected)
    }

    func testEmptyHasNoUpload() {
        XCTAssertNil(CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: 0))
    }

    func testAtBudgetBoundaryUploads() {
        let capVerts = Int(CADVertexBufferBuilder.maxSingleVertexUploadBytes)
            / MemoryLayout<CADVertex>.stride
        XCTAssertNotNil(
            CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: capVerts))
        XCTAssertNil(
            CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: capVerts + 1))
    }

    func testOverflowing32BitSizeRefused() {
        let tooMany = Int(UInt32.max) / MemoryLayout<CADVertex>.stride + 1
        XCTAssertNil(
            CADVertexBufferBuilder.vertexUploadByteSize(vertexCount: tooMany))
    }
}
