import XCTest
@testable import ZephyrCore

/// Grid/snap command parity (AutoCAD SNAP/GRID): exact snap spacing with
/// Aspect (independent X/Y), zoom-independent snap interval, adaptive display
/// spacing that preserves aspect, pending-session entry points, persisted
/// defaults, and visible per-theme grid colors.
@MainActor
final class GridSnapCommandTests: XCTestCase {

    // MARK: - Aspect snap math

    func testNearestGridSnapUsesIndependentXYSpacing() {
        // 2 x 5 grid from the origin: cursor near (2, 5) snaps exactly there,
        // which a single 2-unit spacing would miss on Y.
        let hit = SnapEngine.nearestGridSnap(
            worldX: 2.1, worldY: 4.9,
            originX: 0, originY: 0,
            spacing: 2, spacingY: 5, threshold: 5)
        XCTAssertEqual(hit?.worldPos.x, 2)
        XCTAssertEqual(hit?.worldPos.y, 5)
    }

    func testNearestGridSnapFallsBackToUniformSpacing() {
        let hit = SnapEngine.nearestGridSnap(
            worldX: 9.9, worldY: 10.1,
            originX: 0, originY: 0,
            spacing: 10, threshold: 5)
        XCTAssertEqual(hit?.worldPos.x, 10)
        XCTAssertEqual(hit?.worldPos.y, 10)
    }

    func testNearestGridSnapRejectsNonPositiveSpacing() {
        XCTAssertNil(SnapEngine.nearestGridSnap(
            worldX: 1, worldY: 1, originX: 0, originY: 0,
            spacing: 0, threshold: 5))
        XCTAssertNil(SnapEngine.nearestGridSnap(
            worldX: 1, worldY: 1, originX: 0, originY: 0,
            spacing: 2, spacingY: 0, threshold: 5))
    }

    // MARK: - Display spacing preserves aspect

    func testEffectiveGridSpacingPreservesAspect() {
        let snap = EngineSnapManager()
        snap.gridSpacingX = 2
        snap.gridSpacingY = 5
        // Zoomed out: one common multiplier scales both axes together.
        let wide = snap.effectiveGridSpacingXY(windowWidth: 2500, cameraZoom: 1)
        XCTAssertEqual(wide.x / wide.y, 2.0 / 5.0, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(wide.x, 2)
        // Zoomed in past the floor: the exact configured pair.
        let close = snap.effectiveGridSpacingXY(windowWidth: 100, cameraZoom: 10)
        XCTAssertEqual(close.x, 2)
        XCTAssertEqual(close.y, 5)
    }

    // MARK: - Command entry points

    func testBareSnapAndGridCommandsOpenPendingSessions() {
        for (bare, canonical) in [
            ("SNAP", "SNAP"), ("GRIDSNAP", "SNAP"), ("SNAPUNIT", "SNAP"),
            ("GRIDMAJOR", "GRIDMAJOR"),
            ("GRIDSPACING", "GRIDSPACING"), ("GRIDUNIT", "GRIDSPACING"),
        ] {
            let processor = CADCommandProcessor()
            processor.executeCommand(bare)
            XCTAssertEqual(
                processor.pendingPromptCommand, canonical,
                "bare \(bare) must open a \(canonical) session")
            XCTAssertTrue(processor.commandLineActive)
        }
    }

    func testSnapResolvesThroughAutocomplete() {
        let processor = CADCommandProcessor()
        for input in ["SNAP", "GRIDSNAP", "SNAPUNIT"] {
            let top = processor.matchCommands(input: input)
                .prefix(3).map { $0.descriptor.canonicalName }
            XCTAssertTrue(
                top.contains("SNAP"),
                "'\(input)' should resolve to SNAP; top-3 was \(top)")
        }
    }

    // MARK: - Escape cancels the pending session

    func testCancellingPendingPromptClearsSession() {
        // Regression: Escape used to hide only the command line, leaving the
        // SNAP session behind — its prompt pill reappeared and the next
        // keystroke dropped back into the stuck session, so only Space/Enter
        // could get out. The cascade now runs this same cancel path.
        let processor = CADCommandProcessor()
        processor.executeCommand("SNAP")
        XCTAssertEqual(processor.pendingPromptCommand, "SNAP")
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandPrompt = nil
        processor.finishPendingPrompt()
        XCTAssertNil(processor.pendingPromptCommand)
        XCTAssertTrue(processor.pendingPromptCollected.isEmpty)
        XCTAssertEqual(processor.pendingPromptPhaseIndex, 0)
        XCTAssertNil(processor.commandPrompt)
        // A later submit starts a fresh command, never the stale session.
        processor.executeCommand("GRID")
        XCTAssertNil(processor.pendingPromptCommand)
    }

    func testEmptySubmitWithNoSessionRunsNothing() {
        // Regression: empty Enter ran palette row zero (+PUBLISH). The
        // palette only runs a match for non-empty input now; empty input
        // reaches the processor as a no-op that opens no session.
        let processor = CADCommandProcessor()
        processor.executeCommand("")
        XCTAssertNil(processor.pendingPromptCommand)
    }

    // MARK: - Pending option lists

    func testSnapPromptListsToggleOptions() {
        let processor = CADCommandProcessor()
        processor.executeCommand("SNAP")
        XCTAssertEqual(
            processor.pendingPromptOptions(for: "").map { $0.value },
            ["ON", "OFF", "Aspect"])
    }

    func testSnapPromptOptionsFilterByInput() {
        let processor = CADCommandProcessor()
        processor.executeCommand("SNAP")
        XCTAssertEqual(
            processor.pendingPromptOptions(for: "off").map { $0.value },
            ["OFF"])
        XCTAssertTrue(processor.pendingPromptOptions(for: "5").isEmpty)
    }

    func testGridSpacingPromptListsAspectAndSnap() {
        let processor = CADCommandProcessor()
        processor.executeCommand("GRIDSPACING")
        XCTAssertEqual(
            processor.pendingPromptOptions(for: "").map { $0.value },
            ["Aspect", "Snap"])
    }

    func testNumericPhasesAndIdleListNoOptions() {
        let processor = CADCommandProcessor()
        XCTAssertTrue(processor.pendingPromptOptions(for: "").isEmpty)
        processor.pendingPromptCommand = "SNAP"
        processor.pendingPromptPhaseIndex = 1
        XCTAssertTrue(processor.pendingPromptOptions(for: "").isEmpty)
        processor.pendingPromptCommand = "GRIDORIGIN"
        processor.pendingPromptPhaseIndex = 0
        XCTAssertTrue(processor.pendingPromptOptions(for: "").isEmpty)
    }

    func testUnitsPromptListsUnits() {
        let processor = CADCommandProcessor()
        processor.executeCommand("UNITS")
        let options = processor.pendingPromptOptions(for: "")
        XCTAssertEqual(options.map { $0.value }, ["mm", "cm", "m", "in", "ft", "yd"])
        XCTAssertFalse(options.contains { $0.isActive })
    }

    func testRibbonModePromptListsModes() {
        let processor = CADCommandProcessor()
        processor.pendingPromptCommand = "RIBBONMODE"
        let options = processor.pendingPromptOptions(for: "")
        XCTAssertEqual(options.map { $0.value }, ["menu", "labels", "full"])
        XCTAssertFalse(options.contains { $0.isActive })
    }

    func testSetUiScaleAndDxfVersionAndVportsLists() {
        let processor = CADCommandProcessor()
        processor.pendingPromptCommand = "SETUISCALE"
        XCTAssertEqual(processor.pendingPromptOptions(for: "").map { $0.value }, ["AUTO"])
        processor.pendingPromptCommand = "DXFVERSION"
        XCTAssertEqual(
            processor.pendingPromptOptions(for: "").map { $0.value },
            ["2018", "2013", "2010", "2007", "2004", "2000", "R14", "R13", "R12", "R10"])
        processor.pendingPromptCommand = "VPORTS"
        XCTAssertEqual(
            processor.pendingPromptOptions(for: "").map { $0.value },
            ["2V", "2H", "Single", "Join", "Toggle"])
    }

    func testLayerSortListsKeysAndDirections() {
        let saved = LayerSortSettings.load()
        defer { saved.save() }
        LayerSortSettings(key: .color, ascending: false).save()
        let processor = CADCommandProcessor()
        processor.pendingPromptCommand = "LAYERSORT"
        let options = processor.pendingPromptOptions(for: "")
        XCTAssertTrue(options.contains { $0.value == "COLOR" && $0.isActive })
        XCTAssertTrue(options.contains { $0.value == "DESC" && $0.isActive })
        processor.pendingPromptPhaseIndex = 1
        let directions = processor.pendingPromptOptions(for: "")
        XCTAssertEqual(directions.map { $0.value }, ["ASC", "DESC", "Reverse"])
        XCTAssertTrue(directions.contains { $0.value == "DESC" && $0.isActive })
    }

    func testDefaultActiveOptionValuesEmpty() {
        let processor = CADCommandProcessor()
        processor.pendingPromptCommand = "SETUISCALE"
        XCTAssertFalse(processor.pendingPromptOptions(for: "").contains { $0.isActive })
    }

    // MARK: - Persistence defaults

    func testLegacySettingsDecodeWithGridDefaults() throws {
        let settings = try JSONDecoder().decode(
            UserSettings.self, from: Data(#"{"isDarkTheme": true}"#.utf8))
        XCTAssertFalse(settings.gridVisible)
        XCTAssertFalse(settings.gridSnapEnabled)
        XCTAssertEqual(settings.gridSpacingX, 10)
        XCTAssertEqual(settings.snapSpacingY, 10)
        XCTAssertEqual(settings.gridMajor, 5)
    }

    // MARK: - Theme grid colors

    func testGridLineAlphaVisibleInEveryTheme() {
        XCTAssertEqual(AppTheme.allPresets.count, 8)
        for preset in AppTheme.allPresets {
            XCTAssertGreaterThan(
                preset.theme.gridMinor.w, 0.3,
                "\(preset.id) minor grid line too subtle")
            XCTAssertGreaterThan(
                preset.theme.gridMajor.w, preset.theme.gridMinor.w,
                "\(preset.id) major grid line must beat minor")
        }
    }
}
