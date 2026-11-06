import XCTest
@testable import ZephyrCore

/// UserSettings Codable compatibility: files written before a field
/// existed must decode with defaults (never reset the whole file),
/// and capture() must snapshot the live UI state.
@MainActor
final class UserSettingsTests: XCTestCase {

    /// Pre-setup-flag settings payload (all keys except hasCompletedSetup).
    private let legacyJSON = """
        {
            "isDarkTheme": false,
            "layersPanelVisible": true,
            "drawPaletteVisible": false,
            "blockPanelVisible": false,
            "dataTablePanelVisible": false,
            "showPropertiesPanel": true,
            "showFPS": false,
            "radialNavVisible": false
        }
        """

    func testLegacyFileDecodesWithSetupIncomplete() throws {
        let settings = try JSONDecoder().decode(
            UserSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(settings.isDarkTheme)
        XCTAssertTrue(settings.layersPanelVisible)
        XCTAssertTrue(settings.showPropertiesPanel)
        XCTAssertFalse(settings.hasCompletedSetup)
    }

    func testRoundTripPreservesSetupFlag() throws {
        var settings = UserSettings.default
        settings.hasCompletedSetup = true
        settings.isDarkTheme = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertTrue(decoded.hasCompletedSetup)
        XCTAssertFalse(decoded.isDarkTheme)
    }

    func testCaptureSnapshotsUIState() {
        let ui = EngineUIManager()
        ui.isDarkTheme = false
        ui.layersPanelVisible = true
        ui.hasCompletedSetup = true
        let captured = UserSettings.capture(ui: ui)
        XCTAssertFalse(captured.isDarkTheme)
        XCTAssertTrue(captured.layersPanelVisible)
        XCTAssertTrue(captured.hasCompletedSetup)
    }

    /// Pre-registry settings files decode the Quick + PICKFIRST defaults.
    func testLegacyFileDecodesTrimRegistryDefaults() throws {
        let settings = try JSONDecoder().decode(
            UserSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(settings.trimExtendMode, 1)
        XCTAssertEqual(settings.pickFirst, 1)
    }

    func testTrimRegistryRoundTrip() throws {
        var settings = UserSettings.default
        settings.trimExtendMode = 0
        settings.pickFirst = 0
        let decoded = try JSONDecoder().decode(
            UserSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.trimExtendMode, 0)
        XCTAssertEqual(decoded.pickFirst, 0)
    }

    /// capture() without explicit registry args snapshots the live statics.
    func testCaptureDefaultsToLiveTrimRegistry() {
        let savedMode = TrimSettings.trimExtendMode
        let savedPick = PickFirstSettings.pickFirst
        defer {
            TrimSettings.trimExtendMode = savedMode
            PickFirstSettings.pickFirst = savedPick
        }
        TrimSettings.trimExtendMode = 0
        PickFirstSettings.pickFirst = 0
        let ui = EngineUIManager()
        let captured = UserSettings.capture(ui: ui)
        XCTAssertEqual(captured.trimExtendMode, 0)
        XCTAssertEqual(captured.pickFirst, 0)
    }
}
