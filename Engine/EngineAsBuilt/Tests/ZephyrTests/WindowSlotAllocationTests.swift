import XCTest
@testable import ZephyrCore

/// Slot allocation for per-window panel layouts: aux windows take the
/// lowest free float number, freed numbers are reused, main is never freed.
@MainActor
final class WindowSlotAllocationTests: XCTestCase {
    private func handle(_ n: UInt) -> OpaquePointer {
        OpaquePointer(bitPattern: n)!
    }

    func testMainKeepsMainSlot() {
        let manager = EngineWindowManager()
        let main = manager.register(handle: handle(0x1000), id: 1, isMain: true)
        XCTAssertEqual(main.slotID, .main)
    }

    func testAuxTakesLowestFreeSlotAndReusesFreed() {
        let manager = EngineWindowManager()
        _ = manager.register(handle: handle(0x1000), id: 1, isMain: true)
        let a = manager.register(handle: handle(0x2000), id: 2, isMain: false)
        let b = manager.register(handle: handle(0x3000), id: 3, isMain: false)
        XCTAssertEqual(a.slotID, .float(1))
        XCTAssertEqual(b.slotID, .float(2))
        manager.unregister(id: 2)
        let c = manager.register(handle: handle(0x4000), id: 4, isMain: false)
        XCTAssertEqual(c.slotID, .float(1))
    }

    func testUnregisterNeverRemovesMain() {
        let manager = EngineWindowManager()
        _ = manager.register(handle: handle(0x1000), id: 1, isMain: true)
        manager.unregister(id: 1)
        XCTAssertNotNil(manager.mainWindow)
    }

    func testDuplicateRegistrationReturnsExisting() {
        let manager = EngineWindowManager()
        let a = manager.register(handle: handle(0x2000), id: 2, isMain: false)
        let b = manager.register(handle: handle(0x2000), id: 2, isMain: false)
        XCTAssertTrue(a === b)
        XCTAssertEqual(b.slotID, .float(1))
    }
}
