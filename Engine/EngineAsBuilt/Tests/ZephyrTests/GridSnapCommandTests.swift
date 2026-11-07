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
        XCTAssertEqual(AppTheme.allPresets.count, 7)
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
