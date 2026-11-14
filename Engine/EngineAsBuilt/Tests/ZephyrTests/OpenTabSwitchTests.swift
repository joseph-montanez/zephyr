import XCTest
@testable import ZephyrCore

/// Pins the public file-open funnel headlessly: `TabManager.openTab`
/// (the same entry point the Open dialog, drag-drop, and RECOVER use)
/// must make the imported drawing the active document with
/// `needsRegeneration` set, so the lazy loop renders it hands-off.
@MainActor
final class OpenTabSwitchTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: "Tests/ZephyrTests/Fixtures/dim-linear.dxf")
    }

    func testOpenTabMakesImportedDrawingActiveWithRegenPending() throws {
        let manager = TabManager()
        _ = manager.newTab()
        let oldDocument = manager.activeDocument
        let oldRevision = oldDocument.renderRevision

        let index = try manager.openTab(url: fixtureURL)

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeIndex, index)
        let active = manager.activeDocument
        XCTAssertFalse(active === oldDocument)
        XCTAssertEqual(active.allEntities.count, 1)
        XCTAssertTrue(
            active.needsRegeneration,
            "imported document must request regeneration for the hands-off loop")
        XCTAssertGreaterThan(active.renderRevision, oldRevision)
        XCTAssertEqual(manager.activeTab?.displayName, "dim-linear.dxf")
    }
}
