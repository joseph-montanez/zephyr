import Foundation

// MARK: - UserSettings
//
// Persistable user preferences that survive app restarts.
// Stored as JSON in ~/Library/Application Support/Zephyr/settings.json (macOS)
// or %APPDATA%/Zephyr/settings.json (Windows).
//
// Settings already persisted elsewhere:
//   - UIFontLanguageProfile → UserDefaults ("Zephyr.UIFontLanguageProfile")
//   - Array associativity / type → UserDefaults
//   - ODA converter path → UserDefaults
// These are intentionally NOT duplicated here.

public struct UserSettings: Codable, Sendable {
    // MARK: - Theme
    public var isDarkTheme: Bool

    // MARK: - Panel Visibility
    public var layersPanelVisible: Bool
    public var drawPaletteVisible: Bool
    public var blockPanelVisible: Bool
    public var dataTablePanelVisible: Bool
    public var showPropertiesPanel: Bool

    // MARK: - Misc UI
    public var showFPS: Bool
    public var toolbarVisible: Bool
    public var radialNavVisible: Bool

    // MARK: - Default instance
    public static let `default` = UserSettings(
        isDarkTheme: true,
        layersPanelVisible: false,
        drawPaletteVisible: false,
        blockPanelVisible: false,
        dataTablePanelVisible: false,
        showPropertiesPanel: false,
        showFPS: false,
        toolbarVisible: true,
        radialNavVisible: false
    )

    // MARK: - Persistence

    /// Directory where settings and other app data live.
    public static func appSupportDirectory() -> URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return dir.appendingPathComponent("Zephyr", isDirectory: true)
    }

    /// Path to the JSON settings file.
    public static func settingsURL() -> URL? {
        appSupportDirectory()?.appendingPathComponent("settings.json")
    }

    /// Path to the ImGui docking ini file.
    public static func imguiIniURL() -> URL? {
        appSupportDirectory()?.appendingPathComponent("imgui.ini")
    }

    /// Load settings from disk, returning the default if no file exists.
    public static func load() -> UserSettings {
        guard let url = settingsURL(),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(UserSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    /// Write settings to disk. Creates the directory if needed.
    public func save() {
        guard let dir = Self.appSupportDirectory(),
              let url = Self.settingsURL() else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
