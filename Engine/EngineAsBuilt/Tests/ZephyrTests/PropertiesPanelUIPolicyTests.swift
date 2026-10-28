import XCTest
@testable import ZephyrCore

final class PropertiesPanelUIPolicyTests: XCTestCase {
    func testHiddenWhenPanelToggledOff() {
        XCTAssertEqual(
            PropertiesPanelUIPolicy.content(isVisible: false, hasSelectedEntity: false),
            .hidden)
        XCTAssertEqual(
            PropertiesPanelUIPolicy.content(isVisible: false, hasSelectedEntity: true),
            .hidden)
    }

    /// Regression: the panel used to auto-close as soon as the selection
    /// emptied, forcing the user to reopen it for every inspection. An
    /// open panel with no selection must stay open on an empty state.
    func testOpenPanelWithNoSelectionShowsEmptyStateNotHidden() {
        XCTAssertEqual(
            PropertiesPanelUIPolicy.content(isVisible: true, hasSelectedEntity: false),
            .empty)
    }

    func testOpenPanelWithSelectionShowsEntity() {
        XCTAssertEqual(
            PropertiesPanelUIPolicy.content(isVisible: true, hasSelectedEntity: true),
            .entity)
    }

    // MARK: - Inspected target (multi-select All / single picker)

    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    func testInspectedHandleResolvesOnlyWhileSelected() {
        let ordered = [a, b]
        XCTAssertNil(PropertiesPanelUIPolicy.resolvedInspectedHandle(
            nil, orderedSelectedHandles: ordered))
        XCTAssertEqual(PropertiesPanelUIPolicy.resolvedInspectedHandle(
            b, orderedSelectedHandles: ordered), b)
        // Stale pick from a previous selection falls back to All.
        XCTAssertNil(PropertiesPanelUIPolicy.resolvedInspectedHandle(
            c, orderedSelectedHandles: ordered))
        XCTAssertNil(PropertiesPanelUIPolicy.resolvedInspectedHandle(
            a, orderedSelectedHandles: []))
    }

    func testEditHandlesFollowInspectedTarget() {
        let ordered = [a, b]
        // All: edits apply to every selected entity (previous behavior).
        XCTAssertEqual(PropertiesPanelUIPolicy.editHandles(
            orderedSelectedHandles: ordered, inspectedHandle: nil), [a, b])
        // Single: edits apply only to the inspected entity.
        XCTAssertEqual(PropertiesPanelUIPolicy.editHandles(
            orderedSelectedHandles: ordered, inspectedHandle: b), [b])
        // Stale single pick must not silently narrow edits to a deselected entity.
        XCTAssertEqual(PropertiesPanelUIPolicy.editHandles(
            orderedSelectedHandles: ordered, inspectedHandle: c), [a, b])
    }

    func testDisplayedHandlePrefersInspectedThenLastSelectedThenFirst() {
        let ordered = [a, b]
        XCTAssertEqual(PropertiesPanelUIPolicy.displayedHandle(
            orderedSelectedHandles: ordered, inspectedHandle: b, lastSelectedHandle: a), b)
        XCTAssertEqual(PropertiesPanelUIPolicy.displayedHandle(
            orderedSelectedHandles: ordered, inspectedHandle: nil, lastSelectedHandle: b), b)
        // No last-clicked entity (e.g. toggled off): fall back to the first
        // selected entity so All mode still shows something.
        XCTAssertEqual(PropertiesPanelUIPolicy.displayedHandle(
            orderedSelectedHandles: ordered, inspectedHandle: nil, lastSelectedHandle: nil), a)
        XCTAssertEqual(PropertiesPanelUIPolicy.displayedHandle(
            orderedSelectedHandles: ordered, inspectedHandle: nil, lastSelectedHandle: c), a)
        XCTAssertNil(PropertiesPanelUIPolicy.displayedHandle(
            orderedSelectedHandles: [], inspectedHandle: nil, lastSelectedHandle: a))
    }

    // MARK: - Picker cache (selection perf)

    /// The picker list is a function of (selection, document contents).
    /// It must rebuild only when one of those moves, never per frame --
    /// otherwise a large selection pays entity copies + label building +
    /// an allocating sort on the render path.
    func testPickerCacheFreshWhenNothingChanged() {
        let doc = ObjectIdentifier(NSString(string: "doc"))
        XCTAssertFalse(PropertiesPanelUIPolicy.pickerCacheStale(
            cachedDocument: doc, document: doc,
            cachedSelectionGeneration: 3, selectionGeneration: 3,
            cachedRevision: 9, revision: 9,
            cachedCount: 4, selectionCount: 4))
    }

    func testPickerCacheStaleOnAnyKeyChange() {
        let doc = ObjectIdentifier(NSString(string: "doc"))
        let other = ObjectIdentifier(NSString(string: "other"))
        // Tab/document switch.
        XCTAssertTrue(PropertiesPanelUIPolicy.pickerCacheStale(
            cachedDocument: doc, document: other,
            cachedSelectionGeneration: 3, selectionGeneration: 3,
            cachedRevision: 9, revision: 9,
            cachedCount: 4, selectionCount: 4))
        // Selection changed (even same size).
        XCTAssertTrue(PropertiesPanelUIPolicy.pickerCacheStale(
            cachedDocument: doc, document: doc,
            cachedSelectionGeneration: 3, selectionGeneration: 4,
            cachedRevision: 9, revision: 9,
            cachedCount: 4, selectionCount: 4))
        // Document edited (labels may change: block rename, geometry edits).
        XCTAssertTrue(PropertiesPanelUIPolicy.pickerCacheStale(
            cachedDocument: doc, document: doc,
            cachedSelectionGeneration: 3, selectionGeneration: 3,
            cachedRevision: 9, revision: 10,
            cachedCount: 4, selectionCount: 4))
        // Cold cache (nothing cached yet).
        XCTAssertTrue(PropertiesPanelUIPolicy.pickerCacheStale(
            cachedDocument: nil, document: doc,
            cachedSelectionGeneration: 0, selectionGeneration: 3,
            cachedRevision: 0, revision: 9,
            cachedCount: 0, selectionCount: 4))
    }
}
