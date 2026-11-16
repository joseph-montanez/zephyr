import XCTest
@testable import ZephyrCore

/// Pins the background document-load funnel: `startLoad` must return
/// immediately with a gated placeholder tab (never editable/savable), the
/// detached ODA/parse/assembly must commit the real drawing, failures must
/// stay gated (never vanish), and concurrent loads must serialize
/// (concurrency 1) without corrupting each other.
@MainActor
final class BackgroundLoadTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: "Tests/ZephyrTests/Fixtures/dim-linear.dxf")
    }

    private var secondFixtureURL: URL {
        URL(fileURLWithPath: "Tests/ZephyrTests/Fixtures/dim-aligned.dxf")
    }

    /// Drain the poll queue the main loop normally drains, until every load
    /// reaches a terminal state (committed/failed states clear the entry;
    /// `.failed` lingers by design, so stop on it too) or the timeout expires.
    private func drainLoads(of manager: TabManager, timeoutSeconds: Double = 60) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while manager.loadStateByTabID.values.contains(where: { $0.status == .loading }),
              Date() < deadline {
            _ = manager.applyPendingLoadUpdates()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = manager.applyPendingLoadUpdates()
        XCTAssertLessThan(
            Date(), deadline,
            "background load did not settle within \(timeoutSeconds)s")
    }

    // MARK: - Placeholder gating

    func testStartLoadCreatesGatedPlaceholderTab() {
        let manager = TabManager()
        _ = manager.newTab()

        let tabID = manager.startLoad(url: fixtureURL)

        // Always a new tab, immediately active, with gated placeholder content.
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeTab?.id, tabID)
        XCTAssertEqual(manager.activeTab?.displayName, "dim-linear.dxf")
        XCTAssertTrue(manager.activeTab?.isDocumentLoading ?? false)
        XCTAssertTrue(manager.isLoadingTab(id: tabID))
        XCTAssertTrue(manager.isActiveTabLoading)
        XCTAssertEqual(manager.loadStateByTabID[tabID]?.fileKind, "DXF")
        XCTAssertEqual(manager.activeDocument.entityCount, 0)

        // A loading placeholder owns no real content: saves and edits refuse.
        manager.startSaveActiveTab()
        XCTAssertTrue(
            manager.saveStateByTabID.isEmpty,
            "starting a save on a loading tab must not create save state")
        manager.markActiveDirty()
        XCTAssertFalse(
            manager.activeTab?.hasUnsavedChanges ?? true,
            "a loading placeholder must stay clean so close never prompts")

        // Closing the loading tab cancels the load instead of stranding it.
        XCTAssertTrue(manager.closeTab(at: manager.activeIndex))
        XCTAssertTrue(manager.loadStateByTabID.isEmpty)
    }

    // MARK: - Commit and auto-switch

    func testBackgroundLoadCommitsAndAutoSwitches() async {
        let manager = TabManager()
        _ = manager.newTab()
        let tabID = manager.startLoad(url: fixtureURL)

        // Go do other work on the first tab while the load runs.
        manager.switchToTab(at: 0)
        XCTAssertEqual(manager.activeIndex, 0)

        await drainLoads(of: manager)
        XCTAssertTrue(
            manager.loadStateByTabID.isEmpty,
            "load state must clear after commit")

        // Auto-switch when loaded (idle predicate unwired in tests).
        guard let loadedIndex = manager.tabs.firstIndex(where: { $0.id == tabID }) else {
            XCTFail("loaded tab vanished")
            return
        }
        XCTAssertEqual(manager.activeIndex, loadedIndex)
        let loaded = manager.tabs[loadedIndex]
        XCTAssertFalse(loaded.isDocumentLoading)
        XCTAssertEqual(loaded.displayName, "dim-linear.dxf")
        // Same content the synchronous funnel produces (see OpenTabSwitchTests).
        XCTAssertEqual(loaded.document.allEntities.count, 1)
        XCTAssertTrue(
            loaded.document.needsRegeneration,
            "imported document must request regeneration for the hands-off loop")
    }

    // MARK: - Failure stays gated

    func testFailedLoadKeepsGatedPlaceholder() async {
        let manager = TabManager()
        _ = manager.newTab()
        let missing = URL(fileURLWithPath: "/nonexistent/missing-drawing.dxf")
        let tabID = manager.startLoad(url: missing)

        await drainLoads(of: manager)

        // The tab stays, still gated, instead of silently vanishing.
        guard manager.tabs.contains(where: { $0.id == tabID }) else {
            XCTFail("failed load must keep its placeholder tab")
            return
        }
        XCTAssertTrue(manager.isLoadingTab(id: tabID))
        if case .failed = manager.loadStateByTabID[tabID]?.status {
            // Expected.
        } else {
            XCTFail("missing file must surface a failed load status")
        }
        manager.startSaveActiveTab()
        XCTAssertTrue(
            manager.saveStateByTabID.isEmpty,
            "a failed load must never let a save persist the empty placeholder")

        // The failed tab still closes cleanly without a save prompt.
        guard let index = manager.tabs.firstIndex(where: { $0.id == tabID }) else {
            XCTFail("failed tab vanished before close")
            return
        }
        XCTAssertTrue(manager.closeTab(at: index))
        XCTAssertNil(manager.loadStateByTabID[tabID])
    }

    // MARK: - Concurrency 1

    func testConcurrentLoadsSerializeAndLand() async {
        let manager = TabManager()
        _ = manager.newTab()
        let firstID = manager.startLoad(url: fixtureURL)
        let secondID = manager.startLoad(url: secondFixtureURL)
        XCTAssertNotEqual(firstID, secondID, "every open lands in its own new tab")

        await drainLoads(of: manager, timeoutSeconds: 120)
        XCTAssertTrue(manager.loadStateByTabID.isEmpty)

        // Both drawings commit intact: no shared mutable import state leaked
        // across the serialized loads.
        XCTAssertEqual(manager.tabs.count, 3)
        for id in [firstID, secondID] {
            guard let tab = manager.tabs.first(where: { $0.id == id }) else {
                XCTFail("loaded tab \(id) vanished")
                continue
            }
            XCTAssertFalse(tab.isDocumentLoading)
            XCTAssertGreaterThan(
                tab.document.allEntities.count, 0,
                "loaded tab \(tab.displayName) must hold its drawing")
        }
    }

    // MARK: - Shared import-state locking

    func testHatchRegistryConcurrentAccess() async {
        // Unique names: the pattern library and stray imports share this
        // registry, so round-trip our own generated keys, never an absolute
        // count. Registration returns the lookup key (the importer stores the
        // key, not the raw name, on the primitive).
        let prefix = "BGLOAD" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let line = DXFHatchPatternLine(
            angleDegrees: 45,
            base: Vector3(x: 0, y: 0, z: 0),
            offset: Vector3(x: 1, y: 1, z: 0))
        final class FailureBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ i: Int) { lock.withLock { values.append(i) } }
            var all: [Int] { lock.withLock { values } }
        }
        let failures = FailureBox()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let key = DXFHatchGenerator.registerImportedPatternDefinition(
                        name: "\(prefix)\(i)", lines: [line])
                    if DXFHatchGenerator.patternDefinition(for: key) == nil {
                        failures.append(i)
                    }
                }
                group.addTask {
                    _ = DXFHatchGenerator.patternDefinition(for: "ANSI31")
                }
            }
        }
        XCTAssertTrue(
            failures.all.isEmpty,
            "concurrent register/read lost definitions for indices \(failures.all)")
    }
}
