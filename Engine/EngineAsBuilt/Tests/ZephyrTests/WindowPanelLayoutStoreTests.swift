import XCTest
@testable import ZephyrCore

/// Per-window panel layouts: each OS window slot holds its own visibility
/// state; a slot with no entry is seeded once from main, then diverges.
@MainActor
final class WindowPanelLayoutStoreTests: XCTestCase {
    func testFirstAccessSeedsFromMain() {
        var store = WindowPanelLayoutStore()
        var main = store.layout(for: .main)
        main.layersPanelVisible = true
        main.showPropertiesPanel = true
        store.set(main, for: .main)

        let seeded = store.layout(for: .float(1))
        XCTAssertTrue(seeded.layersPanelVisible)
        XCTAssertTrue(seeded.showPropertiesPanel)
    }

    func testSlotsDivergeAfterSeed() {
        var store = WindowPanelLayoutStore()
        var main = store.layout(for: .main)
        main.layersPanelVisible = true
        store.set(main, for: .main)
        _ = store.layout(for: .float(1))

        store.update(slot: .float(1)) { $0.layersPanelVisible = false }
        XCTAssertTrue(store.layout(for: .main).layersPanelVisible)
        XCTAssertFalse(store.layout(for: .float(1)).layersPanelVisible)

        store.update(slot: .main) { $0.blockPanelVisible = true }
        XCTAssertFalse(store.layout(for: .float(1)).blockPanelVisible)
    }

    func testSeedHappensOnce() {
        var store = WindowPanelLayoutStore()
        _ = store.layout(for: .float(2))
        XCTAssertTrue(store.hasLayout(for: .float(2)))
        // Main changes afterwards must not retroactively move the slot.
        store.update(slot: .main) { $0.drawPaletteVisible = true }
        XCTAssertFalse(store.layout(for: .float(2)).drawPaletteVisible)
    }

    func testSlotKeyRoundTrip() {
        XCTAssertEqual(WindowSlotID.from(key: "main"), .main)
        XCTAssertEqual(WindowSlotID.from(key: "float-1"), .float(1))
        XCTAssertNil(WindowSlotID.from(key: "bogus"))
        XCTAssertEqual(WindowSlotID.float(3).key, "float-3")
    }

    func testCodableRoundTrip() throws {
        var store = WindowPanelLayoutStore()
        store.update(slot: .main) { $0.layersPanelVisible = true }
        _ = store.layout(for: .float(1))
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(WindowPanelLayoutStore.self, from: data)
        XCTAssertTrue(decoded.layouts[WindowSlotID.main.key]?.layersPanelVisible ?? false)
        XCTAssertTrue(decoded.hasLayout(for: .float(1)))
    }
}
