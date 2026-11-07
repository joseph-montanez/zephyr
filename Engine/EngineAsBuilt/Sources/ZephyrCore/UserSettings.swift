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
    public var themeName: String

    // MARK: - Panel Visibility
    public var layersPanelVisible: Bool
    public var drawPaletteVisible: Bool
    public var blockPanelVisible: Bool
    public var dataTablePanelVisible: Bool
    public var showPropertiesPanel: Bool

    // MARK: - Misc UI
    public var showFPS: Bool
    public var radialNavVisible: Bool

    // MARK: - Ribbon
    /// Whether the ribbon window is open (`RIBBON`).
    public var ribbonVisible: Bool
    /// Persisted `RibbonDisplayMode` raw value (menu / labels / full).
    public var ribbonMode: String
    /// Title of the active ribbon tab; nil until the user picks one.
    public var activeRibbonTab: String?

    // MARK: - First-run setup
    /// Whether the welcome/setup popup was completed. Pre-flag settings
    /// files decode this as false, so upgrading users see the popup once.
    public var hasCompletedSetup: Bool

    // MARK: - External references (xrefs)
    public var xrefPanelVisible: Bool
    public var sheetSetManagerActive: Bool
    /// REFPATHTYPE: 0 = full path, 1 = relative (default), 2 = no path.
    public var xrefRefPathType: Int
    public var xrefSearchPaths: [String]
    public var xrefMaxLoaded: Int
    public var xrefMaxDepth: Int
    public var xrefMaxPrimitives: Int
    /// XDWGFADECTL display fade percent (0 = off).
    public var xrefFadePercent: Int
    /// BINDTYPE: 0 = Bind ($0$ names), 1 = Insert (merge).
    public var xrefBindType: Int

    // MARK: - Plot registry (PLOTOFFSET / PAPERUPDATE / PLOTROTMODE /
    // PLOTTRANSPARENCYOVERRIDE). Registry-type sysvars that survive restarts.
    public var plotOffset: Int
    public var paperUpdate: Int
    public var plotRotMode: Int
    public var plotTransparencyOverride: Int
    /// Page Setup Manager "Display when creating a new layout" checkbox.
    public var displayPageSetupForNewLayouts: Bool

    // MARK: - Blocks palette
    public var blockRecent: [BlockLibraryRef]
    public var blockFavorites: [BlockLibraryRef]
    public var blockLibraryFolders: [String]
    public var blockInsertExplode: Bool
    public var blockInsertRepeat: Bool
    public var blockInsertPromptAttributes: Bool

    // MARK: - Trim/Extend registry (TRIMEXTENDMODE / PICKFIRST).
    // Registry-type sysvars that survive restarts (current AutoCAD defaults
    // to Quick mode with noun/verb selection on).
    public var trimExtendMode: Int
    public var pickFirst: Int

    // MARK: - Grid / Snap (GRIDMODE / SNAPMODE / GRIDUNIT / SNAPUNIT / GRIDMAJOR).
    // App-global drafting aids that survive restarts.
    public var gridVisible: Bool
    public var gridSnapEnabled: Bool
    public var gridSpacingX: Double
    public var gridSpacingY: Double
    public var snapSpacingX: Double
    public var snapSpacingY: Double
    public var gridOriginX: Double
    public var gridOriginY: Double
    public var gridMajor: Int

    // MARK: - Initialization

    /// Memberwise initializer (explicit: the custom Decodable init
    /// below suppresses the synthesized one).
    public init(
        isDarkTheme: Bool,
        themeName: String? = nil,
        layersPanelVisible: Bool,
        drawPaletteVisible: Bool,
        blockPanelVisible: Bool,
        dataTablePanelVisible: Bool,
        showPropertiesPanel: Bool,
        showFPS: Bool,
        radialNavVisible: Bool,
        hasCompletedSetup: Bool,
        ribbonVisible: Bool = true,
        ribbonMode: String = "full",
        activeRibbonTab: String? = nil,
        xrefPanelVisible: Bool = false,
        sheetSetManagerActive: Bool = false,
        xrefRefPathType: Int = 1,
        xrefSearchPaths: [String] = [],
        xrefMaxLoaded: Int = 32,
        xrefMaxDepth: Int = 16,
        xrefMaxPrimitives: Int = 5_000_000,
        xrefFadePercent: Int = 50,
        xrefBindType: Int = 0,
        plotOffset: Int = 0,
        paperUpdate: Int = 0,
        plotRotMode: Int = 1,
        plotTransparencyOverride: Int = 1,
        displayPageSetupForNewLayouts: Bool = false,
        trimExtendMode: Int = 1,
        pickFirst: Int = 1,
        gridVisible: Bool = false,
        gridSnapEnabled: Bool = false,
        gridSpacingX: Double = 10,
        gridSpacingY: Double = 10,
        snapSpacingX: Double = 10,
        snapSpacingY: Double = 10,
        gridOriginX: Double = 0,
        gridOriginY: Double = 0,
        gridMajor: Int = 5,
        blockRecent: [BlockLibraryRef] = [],
        blockFavorites: [BlockLibraryRef] = [],
        blockLibraryFolders: [String] = [],
        blockInsertExplode: Bool = false,
        blockInsertRepeat: Bool = false,
        blockInsertPromptAttributes: Bool = false
    ) {
        self.isDarkTheme = isDarkTheme
        self.themeName = themeName ?? (isDarkTheme ? "dark" : "light")
        self.layersPanelVisible = layersPanelVisible
        self.drawPaletteVisible = drawPaletteVisible
        self.blockPanelVisible = blockPanelVisible
        self.dataTablePanelVisible = dataTablePanelVisible
        self.showPropertiesPanel = showPropertiesPanel
        self.showFPS = showFPS
        self.radialNavVisible = radialNavVisible
        self.hasCompletedSetup = hasCompletedSetup
        self.ribbonVisible = ribbonVisible
        self.ribbonMode = ribbonMode
        self.activeRibbonTab = activeRibbonTab
        self.xrefPanelVisible = xrefPanelVisible
        self.sheetSetManagerActive = sheetSetManagerActive
        self.xrefRefPathType = xrefRefPathType
        self.xrefSearchPaths = xrefSearchPaths
        self.xrefMaxLoaded = xrefMaxLoaded
        self.xrefMaxDepth = xrefMaxDepth
        self.xrefMaxPrimitives = xrefMaxPrimitives
        self.xrefFadePercent = xrefFadePercent
        self.xrefBindType = xrefBindType
        self.plotOffset = plotOffset
        self.paperUpdate = paperUpdate
        self.plotRotMode = plotRotMode
        self.plotTransparencyOverride = plotTransparencyOverride
        self.displayPageSetupForNewLayouts = displayPageSetupForNewLayouts
        self.blockRecent = blockRecent
        self.blockFavorites = blockFavorites
        self.blockLibraryFolders = blockLibraryFolders
        self.blockInsertExplode = blockInsertExplode
        self.blockInsertRepeat = blockInsertRepeat
        self.blockInsertPromptAttributes = blockInsertPromptAttributes
        self.trimExtendMode = (trimExtendMode == 0) ? 0 : 1
        self.pickFirst = (pickFirst == 0) ? 0 : 1
        self.gridVisible = gridVisible
        self.gridSnapEnabled = gridSnapEnabled
        self.gridSpacingX = gridSpacingX > 0 ? gridSpacingX : 10
        self.gridSpacingY = gridSpacingY > 0 ? gridSpacingY : 10
        self.snapSpacingX = snapSpacingX > 0 ? snapSpacingX : 10
        self.snapSpacingY = snapSpacingY > 0 ? snapSpacingY : 10
        self.gridOriginX = gridOriginX
        self.gridOriginY = gridOriginY
        self.gridMajor = (1...100).contains(gridMajor) ? gridMajor : 5
    }

    // MARK: - Default instance
    public static let `default` = UserSettings(
        isDarkTheme: true,
        themeName: "dark",
        layersPanelVisible: false,
        drawPaletteVisible: false,
        blockPanelVisible: false,
        dataTablePanelVisible: false,
        showPropertiesPanel: false,
        showFPS: false,
        radialNavVisible: false,
        hasCompletedSetup: false
    )

    /// Decodes leniently so settings files written before a field
    /// existed still load (missing keys fall back to defaults rather
    /// than resetting the whole file to `.default`).
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        isDarkTheme = try box.decodeIfPresent(Bool.self, forKey: .isDarkTheme)
            ?? fallback.isDarkTheme
        themeName = try box.decodeIfPresent(String.self, forKey: .themeName)
            ?? (isDarkTheme ? "dark" : "light")
        layersPanelVisible = try box.decodeIfPresent(Bool.self, forKey: .layersPanelVisible)
            ?? fallback.layersPanelVisible
        drawPaletteVisible = try box.decodeIfPresent(Bool.self, forKey: .drawPaletteVisible)
            ?? fallback.drawPaletteVisible
        blockPanelVisible = try box.decodeIfPresent(Bool.self, forKey: .blockPanelVisible)
            ?? fallback.blockPanelVisible
        dataTablePanelVisible = try box.decodeIfPresent(
            Bool.self, forKey: .dataTablePanelVisible) ?? fallback.dataTablePanelVisible
        showPropertiesPanel = try box.decodeIfPresent(Bool.self, forKey: .showPropertiesPanel)
            ?? fallback.showPropertiesPanel
        showFPS = try box.decodeIfPresent(Bool.self, forKey: .showFPS)
            ?? fallback.showFPS
        radialNavVisible = try box.decodeIfPresent(Bool.self, forKey: .radialNavVisible)
            ?? fallback.radialNavVisible
        hasCompletedSetup = try box.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup)
            ?? fallback.hasCompletedSetup
        ribbonVisible = try box.decodeIfPresent(Bool.self, forKey: .ribbonVisible)
            ?? fallback.ribbonVisible
        ribbonMode = try box.decodeIfPresent(String.self, forKey: .ribbonMode)
            ?? fallback.ribbonMode
        activeRibbonTab = try box.decodeIfPresent(String.self, forKey: .activeRibbonTab)
        xrefPanelVisible = try box.decodeIfPresent(Bool.self, forKey: .xrefPanelVisible)
            ?? fallback.xrefPanelVisible
        sheetSetManagerActive = try box.decodeIfPresent(Bool.self, forKey: .sheetSetManagerActive)
            ?? fallback.sheetSetManagerActive
        xrefRefPathType = try box.decodeIfPresent(Int.self, forKey: .xrefRefPathType)
            ?? fallback.xrefRefPathType
        xrefSearchPaths = try box.decodeIfPresent([String].self, forKey: .xrefSearchPaths)
            ?? fallback.xrefSearchPaths
        xrefMaxLoaded = try box.decodeIfPresent(Int.self, forKey: .xrefMaxLoaded)
            ?? fallback.xrefMaxLoaded
        xrefMaxDepth = try box.decodeIfPresent(Int.self, forKey: .xrefMaxDepth)
            ?? fallback.xrefMaxDepth
        xrefMaxPrimitives = try box.decodeIfPresent(Int.self, forKey: .xrefMaxPrimitives)
            ?? fallback.xrefMaxPrimitives
        xrefFadePercent = try box.decodeIfPresent(Int.self, forKey: .xrefFadePercent)
            ?? fallback.xrefFadePercent
        xrefBindType = try box.decodeIfPresent(Int.self, forKey: .xrefBindType)
            ?? fallback.xrefBindType
        plotOffset = try box.decodeIfPresent(Int.self, forKey: .plotOffset)
            ?? fallback.plotOffset
        paperUpdate = try box.decodeIfPresent(Int.self, forKey: .paperUpdate)
            ?? fallback.paperUpdate
        plotRotMode = try box.decodeIfPresent(Int.self, forKey: .plotRotMode)
            ?? fallback.plotRotMode
        plotTransparencyOverride = try box.decodeIfPresent(Int.self, forKey: .plotTransparencyOverride)
            ?? fallback.plotTransparencyOverride
        displayPageSetupForNewLayouts = try box.decodeIfPresent(Bool.self, forKey: .displayPageSetupForNewLayouts)
            ?? fallback.displayPageSetupForNewLayouts
        trimExtendMode = try box.decodeIfPresent(Int.self, forKey: .trimExtendMode)
            ?? fallback.trimExtendMode
        blockRecent = try box.decodeIfPresent([BlockLibraryRef].self, forKey: .blockRecent)
            ?? fallback.blockRecent
        blockFavorites = try box.decodeIfPresent([BlockLibraryRef].self, forKey: .blockFavorites)
            ?? fallback.blockFavorites
        blockLibraryFolders = try box.decodeIfPresent([String].self, forKey: .blockLibraryFolders)
            ?? fallback.blockLibraryFolders
        blockInsertExplode = try box.decodeIfPresent(Bool.self, forKey: .blockInsertExplode)
            ?? fallback.blockInsertExplode
        blockInsertRepeat = try box.decodeIfPresent(Bool.self, forKey: .blockInsertRepeat)
            ?? fallback.blockInsertRepeat
        blockInsertPromptAttributes = try box.decodeIfPresent(Bool.self, forKey: .blockInsertPromptAttributes)
            ?? fallback.blockInsertPromptAttributes
        gridVisible = try box.decodeIfPresent(Bool.self, forKey: .gridVisible)
            ?? fallback.gridVisible
        gridSnapEnabled = try box.decodeIfPresent(Bool.self, forKey: .gridSnapEnabled)
            ?? fallback.gridSnapEnabled
        gridSpacingX = try box.decodeIfPresent(Double.self, forKey: .gridSpacingX)
            ?? fallback.gridSpacingX
        gridSpacingY = try box.decodeIfPresent(Double.self, forKey: .gridSpacingY)
            ?? fallback.gridSpacingY
        snapSpacingX = try box.decodeIfPresent(Double.self, forKey: .snapSpacingX)
            ?? fallback.snapSpacingX
        snapSpacingY = try box.decodeIfPresent(Double.self, forKey: .snapSpacingY)
            ?? fallback.snapSpacingY
        gridOriginX = try box.decodeIfPresent(Double.self, forKey: .gridOriginX)
            ?? fallback.gridOriginX
        gridOriginY = try box.decodeIfPresent(Double.self, forKey: .gridOriginY)
            ?? fallback.gridOriginY
        gridMajor = try box.decodeIfPresent(Int.self, forKey: .gridMajor)
            ?? fallback.gridMajor
        pickFirst = try box.decodeIfPresent(Int.self, forKey: .pickFirst)
            ?? fallback.pickFirst
    }

    /// Snapshots the live UI state into persistable settings. Single
    /// source of truth for shutdown saves and setup completion.
    /// Pass the live plot registry values so they persist across restarts.
    /// TRIMEXTENDMODE/PICKFIRST default to the live statics so callers that
    /// only pass UI state still persist the current sysvar values.
    @MainActor
    public static func capture(ui: EngineUIManager,
                               plotOffset: Int = 0,
                               paperUpdate: Int = 0,
                               plotRotMode: Int = 1,
                               plotTransparencyOverride: Int = 1,
                               trimExtendMode: Int = TrimSettings.trimExtendMode,
                               pickFirst: Int = PickFirstSettings.pickFirst,
                               snap: EngineSnapManager? = nil) -> UserSettings {
        UserSettings(
            isDarkTheme: ui.isDarkTheme,
            themeName: ui.theme.id,
            layersPanelVisible: ui.layersPanelVisible,
            drawPaletteVisible: ui.drawPaletteVisible,
            blockPanelVisible: ui.blockPanelVisible,
            dataTablePanelVisible: ui.dataTablePanelVisible,
            showPropertiesPanel: ui.showPropertiesPanel,
            showFPS: ui.showFPS,
            radialNavVisible: ui.radialNavVisible,
            hasCompletedSetup: ui.hasCompletedSetup,
            ribbonVisible: ui.ribbonVisible,
            ribbonMode: ui.ribbonMode.rawValue,
            activeRibbonTab: ui.activeRibbonTab,
            xrefPanelVisible: ui.xrefPanelVisible,
            sheetSetManagerActive: ui.sheetSetManagerActive,
            xrefRefPathType: ui.xrefRefPathType,
            xrefSearchPaths: ui.xrefSearchPaths,
            xrefMaxLoaded: ui.xrefMaxLoaded,
            xrefMaxDepth: ui.xrefMaxDepth,
            xrefMaxPrimitives: ui.xrefMaxPrimitives,
            xrefFadePercent: ui.xrefFadePercent,
            xrefBindType: ui.xrefBindType,
            plotOffset: plotOffset,
            paperUpdate: paperUpdate,
            plotRotMode: plotRotMode,
            plotTransparencyOverride: plotTransparencyOverride,
            trimExtendMode: trimExtendMode,
            pickFirst: pickFirst,
            gridVisible: snap?.gridVisible ?? false,
            gridSnapEnabled: snap?.gridSnapEnabled ?? false,
            gridSpacingX: snap?.gridSpacingX ?? 10,
            gridSpacingY: snap?.gridSpacingY ?? 10,
            snapSpacingX: snap?.snapSpacingX ?? 10,
            snapSpacingY: snap?.snapSpacingY ?? 10,
            gridOriginX: snap?.gridOriginX ?? 0,
            gridOriginY: snap?.gridOriginY ?? 0,
            gridMajor: snap?.gridMajor ?? 5,
            blockRecent: ui.blockRecent,
            blockFavorites: ui.blockFavorites,
            blockLibraryFolders: ui.blockLibraryFolders,
            blockInsertExplode: ui.blockInsertExplode,
            blockInsertRepeat: ui.blockInsertRepeat,
            blockInsertPromptAttributes: ui.blockInsertPromptAttributes
        )
    }

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
