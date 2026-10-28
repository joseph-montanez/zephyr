import XCTest
@testable import ZephyrCore

/// P7 (selection cursor lag): ImGui transfer buffers are reused across
/// frames instead of created/released per frame. This pins the growth
/// policy so a future edit cannot reintroduce per-frame churn.
@MainActor
final class ImGuiTransferCapacityTests: XCTestCase {

    func testEmptyNeedReturnsNil() {
        XCTAssertNil(EngineRenderer.grownImGuiTransferCapacity(neededBytes: 0, existingBytes: 0))
        XCTAssertNil(EngineRenderer.grownImGuiTransferCapacity(neededBytes: -8, existingBytes: 1024))
    }

    func testFittingBufferIsReused() {
        XCTAssertEqual(
            EngineRenderer.grownImGuiTransferCapacity(neededBytes: 100, existingBytes: 100),
            100)
        XCTAssertEqual(
            EngineRenderer.grownImGuiTransferCapacity(neededBytes: 100, existingBytes: 4096),
            4096)
    }

    func testGrowthAddsHeadroom() {
        let grown = EngineRenderer.grownImGuiTransferCapacity(neededBytes: 10_000, existingBytes: 0)
        XCTAssertNotNil(grown)
        XCTAssertGreaterThanOrEqual(grown!, 10_000 + 4096)
        // Growth is amortized: the grown buffer covers modest follow-ups.
        XCTAssertEqual(
            EngineRenderer.grownImGuiTransferCapacity(neededBytes: 10_001, existingBytes: grown!),
            grown)
    }
}
