import XCTest
@testable import ZephyrCore

/// Per-view selection must survive tab switches (capture on depart,
/// apply on arrive), mirroring camera state — previously selection was
/// cleared on every switch. (View switches share the same code path in
/// TabManager; multi-view tabs can't be injected via public API here.)
@MainActor
final class SelectionPersistenceTests: XCTestCase {

    private func makeManager(tabCount: Int) -> TabManager {
        let manager = TabManager()
        for _ in 0..<tabCount { _ = manager.newTab() }
        return manager
    }

    func testSelectionSavedAndRestoredAcrossTabSwitch() {
        let manager = makeManager(tabCount: 2) // active = tab 1 after newTab churn
        let startIdx = manager.activeIndex
        let otherIdx = startIdx == 0 ? 1 : 0
        let handleA = UUID()
        let handleB = UUID()
        var live = SelectionState(selectedHandles: [handleA], lastSelectedHandle: handleA)
        manager.captureSelectionState = { live }
        manager.applySelectionState = { live = $0 }

        manager.switchToTab(at: otherIdx)
        XCTAssertEqual(manager.tabs[startIdx].selectionState.selectedHandles, [handleA],
                       "departing tab must keep its selection")
        XCTAssertEqual(live, .empty, "incoming tab starts with its own (empty) selection")

        live = SelectionState(selectedHandles: [handleB])
        manager.switchToTab(at: startIdx)
        XCTAssertEqual(manager.tabs[otherIdx].selectionState.selectedHandles, [handleB])
        XCTAssertEqual(live.selectedHandles, [handleA], "returning restores the first tab's selection")
        XCTAssertEqual(live.lastSelectedHandle, handleA)
    }

    func testClosingActiveTabAppliesSurvivorSelection() {
        let manager = makeManager(tabCount: 2)
        let survivorIdx = manager.activeIndex
        let closingIdx = survivorIdx == 0 ? 1 : 0
        let survivorHandle = UUID()
        var live = SelectionState(selectedHandles: [survivorHandle])
        manager.captureSelectionState = { live }
        manager.applySelectionState = { live = $0 }
        // Departing the survivor tab stores its selection; the closing tab
        // becomes active with its own (empty) selection.
        manager.switchToTab(at: closingIdx)
        XCTAssertEqual(manager.tabs[survivorIdx].selectionState.selectedHandles, [survivorHandle])
        _ = manager.closeTab(at: closingIdx)
        XCTAssertEqual(live.selectedHandles, [survivorHandle],
                       "closing the active tab restores the survivor's selection")
    }
}
