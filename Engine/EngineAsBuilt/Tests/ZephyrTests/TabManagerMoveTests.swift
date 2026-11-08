import XCTest
@testable import ZephyrCore

@MainActor
final class TabManagerMoveTests: XCTestCase {

    private func makeManager(tabCount: Int) -> TabManager {
        let manager = TabManager()
        for _ in 0..<tabCount {
            _ = manager.newTab()
        }
        return manager
    }

    private func tabIDs(_ manager: TabManager) -> [UUID] {
        manager.tabs.map(\.id)
    }

    // MARK: - moveTab

    func testMoveTabReordersAndKeepsSameTabActive() {
        let manager = makeManager(tabCount: 3)
        let ids = tabIDs(manager)
        manager.switchToTab(at: 1)
        XCTAssertEqual(manager.activeTab?.id, ids[1])

        XCTAssertTrue(manager.moveTab(from: 0, to: 2))

        XCTAssertEqual(tabIDs(manager), [ids[1], ids[2], ids[0]])
        // The same tab (ids[1]) stays active, now at index 0.
        XCTAssertEqual(manager.activeIndex, 0)
        XCTAssertEqual(manager.activeTab?.id, ids[1])
    }

    func testMoveTabClampsDestination() {
        let manager = makeManager(tabCount: 3)
        let ids = tabIDs(manager)

        XCTAssertTrue(manager.moveTab(from: 2, to: -99))
        XCTAssertEqual(tabIDs(manager), [ids[2], ids[0], ids[1]])

        XCTAssertTrue(manager.moveTab(from: 0, to: 99))
        XCTAssertEqual(tabIDs(manager), [ids[0], ids[1], ids[2]])
    }

    func testMoveTabRejectsOutOfRangeSource() {
        let manager = makeManager(tabCount: 2)
        let ids = tabIDs(manager)

        XCTAssertFalse(manager.moveTab(from: -1, to: 0))
        XCTAssertFalse(manager.moveTab(from: 2, to: 0))
        XCTAssertEqual(tabIDs(manager), ids)
    }

    func testMoveTabToSamePositionIsNoOp() {
        let manager = makeManager(tabCount: 2)
        let ids = tabIDs(manager)

        XCTAssertTrue(manager.moveTab(from: 1, to: 1))
        XCTAssertEqual(tabIDs(manager), ids)
    }

    // MARK: - moveActiveTabLeft / moveActiveTabRight

    func testMoveActiveTabLeftAndRight() {
        let manager = makeManager(tabCount: 3)
        let ids = tabIDs(manager)
        manager.switchToTab(at: 1)

        XCTAssertTrue(manager.moveActiveTabLeft())
        XCTAssertEqual(tabIDs(manager), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(manager.activeIndex, 0)

        XCTAssertTrue(manager.moveActiveTabRight())
        XCTAssertEqual(tabIDs(manager), [ids[0], ids[1], ids[2]])
        XCTAssertEqual(manager.activeIndex, 1)
    }

    func testMoveActiveTabAtEdgesFails() {
        let manager = makeManager(tabCount: 2)
        manager.switchToTab(at: 0)
        XCTAssertFalse(manager.moveActiveTabLeft())
        XCTAssertEqual(manager.activeIndex, 0)

        manager.switchToTab(at: 1)
        XCTAssertFalse(manager.moveActiveTabRight())
        XCTAssertEqual(manager.activeIndex, 1)
    }

    func testMoveActiveTabSingleTabFails() {
        let manager = makeManager(tabCount: 1)
        XCTAssertFalse(manager.moveActiveTabLeft())
        XCTAssertFalse(manager.moveActiveTabRight())
    }

    // MARK: - cycleTab

    func testCycleTabWrapsAround() {
        let manager = makeManager(tabCount: 3)
        manager.switchToTab(at: 2)

        XCTAssertTrue(manager.cycleTab(direction: 1))
        XCTAssertEqual(manager.activeIndex, 0)

        XCTAssertTrue(manager.cycleTab(direction: -1))
        XCTAssertEqual(manager.activeIndex, 2)
    }

    func testCycleTabDefaultsForward() {
        let manager = makeManager(tabCount: 2)
        manager.switchToTab(at: 0)

        XCTAssertTrue(manager.cycleTab())
        XCTAssertEqual(manager.activeIndex, 1)
    }
}

extension TabManagerMoveTests {

    // MARK: - tabOrderGeneration (tab-bar visual sync)

    func testOrderGenerationBumpsOnlyOnRealReorder() {
        let manager = makeManager(tabCount: 3)
        let base = manager.tabOrderGeneration

        XCTAssertTrue(manager.moveTab(from: 0, to: 0), "no-op move succeeds")
        XCTAssertEqual(manager.tabOrderGeneration, base, "no-op must not bump")

        XCTAssertFalse(manager.moveTab(from: -1, to: 0))
        XCTAssertEqual(manager.tabOrderGeneration, base, "rejected move must not bump")

        XCTAssertTrue(manager.moveTab(from: 0, to: 2))
        XCTAssertEqual(manager.tabOrderGeneration, base + 1)

        // Drive the active tab to the end; each successful step bumps,
        // the refused step at the boundary does not.
        while manager.moveActiveTabRight() {}
        let atEnd = manager.tabOrderGeneration
        XCTAssertFalse(manager.moveActiveTabRight(), "already last")
        XCTAssertEqual(manager.tabOrderGeneration, atEnd)
        XCTAssertTrue(manager.moveActiveTabLeft())
        XCTAssertEqual(manager.tabOrderGeneration, atEnd + 1)
    }
}
