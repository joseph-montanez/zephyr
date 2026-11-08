import XCTest
@testable import ZephyrCore

@MainActor
final class TabManagerFloatTests: XCTestCase {

    private func makeManager(tabCount: Int) -> TabManager {
        let manager = TabManager()
        for _ in 0..<tabCount {
            _ = manager.newTab()
        }
        return manager
    }

    func testSetAndQueryFloated() {
        let manager = makeManager(tabCount: 2)
        let firstID = manager.tabs[0].id

        XCTAssertFalse(manager.isFloated(id: firstID))
        XCTAssertTrue(manager.setFloated(id: firstID, true))
        XCTAssertTrue(manager.isFloated(id: firstID))
        XCTAssertTrue(manager.setFloated(id: firstID, false))
        XCTAssertFalse(manager.isFloated(id: firstID))
    }

    func testFloatStateRejectsUnknownID() {
        let manager = makeManager(tabCount: 1)

        XCTAssertFalse(manager.isFloated(id: UUID()))
        XCTAssertFalse(manager.setFloated(id: UUID(), true))
        XCTAssertNil(manager.tab(for: UUID()))
    }

    func testTabForIDReturnsTab() {
        let manager = makeManager(tabCount: 2)
        let secondID = manager.tabs[1].id

        XCTAssertEqual(manager.tab(for: secondID)?.id, secondID)
    }

    func testFloatedTabIDsInBarOrder() {
        let manager = makeManager(tabCount: 3)
        let ids = manager.tabs.map(\.id)

        manager.setFloated(id: ids[2], true)
        manager.setFloated(id: ids[0], true)

        XCTAssertEqual(manager.floatedTabIDs, [ids[0], ids[2]])
    }

    func testFloatPreservesBarOrderForDockBack() {
        let manager = makeManager(tabCount: 3)
        let ids = manager.tabs.map(\.id)

        manager.setFloated(id: ids[1], true)
        // Model order is untouched; only the flag flips.
        XCTAssertEqual(manager.tabs.map(\.id), ids)

        manager.setFloated(id: ids[1], false)
        XCTAssertEqual(manager.tabs.map(\.id), ids)
        XCTAssertTrue(manager.floatedTabIDs.isEmpty)
    }

    func testNearestDockedReplacementForLastFloatedTabIsPreviousTab() {
        let manager = makeManager(tabCount: 3)
        let ids = manager.tabs.map(\.id)

        manager.setFloated(id: ids[2], true)

        XCTAssertEqual(manager.nearestDockedTabID(replacing: ids[2]), ids[1])
    }

    func testNearestDockedReplacementPrefersTabSlidingIntoPlace() {
        let manager = makeManager(tabCount: 4)
        let ids = manager.tabs.map(\.id)

        manager.setFloated(id: ids[1], true)
        XCTAssertEqual(manager.nearestDockedTabID(replacing: ids[1]), ids[2])

        manager.setFloated(id: ids[2], true)
        XCTAssertEqual(manager.nearestDockedTabID(replacing: ids[1]), ids[3])
        XCTAssertEqual(manager.nearestDockedTabID(replacing: ids[3]), ids[0])
    }

    func testNearestDockedReplacementIsNilWhenEveryTabFloats() {
        let manager = makeManager(tabCount: 2)
        let ids = manager.tabs.map(\.id)

        manager.setFloated(id: ids[0], true)
        manager.setFloated(id: ids[1], true)

        XCTAssertNil(manager.nearestDockedTabID(replacing: ids[1]))
    }

    func testCloseTabFiresIDHook() {
        let manager = makeManager(tabCount: 2)
        let closedID = manager.tabs[0].id
        var firedID: UUID? = nil
        manager.onTabClosedID = { firedID = $0 }

        XCTAssertTrue(manager.closeTab(at: 0))
        XCTAssertEqual(firedID, closedID)
    }

    func testCloseLastTabFiresIDHookWithRemovedID() {
        let manager = makeManager(tabCount: 1)
        let closedID = manager.tabs[0].id
        var firedID: UUID? = nil
        manager.onTabClosedID = { firedID = $0 }

        XCTAssertTrue(manager.closeTab(at: 0))
        // The replacement untitled tab has a fresh ID; the hook reports the removed one.
        XCTAssertEqual(firedID, closedID)
        XCTAssertNotEqual(manager.tabs[0].id, closedID)
    }
}
