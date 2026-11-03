import Foundation

// =========================================================================
// MARK: - Publish metadata inspector (Phase 3, core only — no UI)
// -------------------------------------------------------------------------
// Generalizes `DXFPlotSettingsImport` (see PlotCliCommands.swift) from a
// named-setup list into drawing metadata for the PUBLISH sheet list:
// tab names + spaces + native setup associations, plus the named setups.
//
// Sources:
// - DXF / DWT directly via `DXFImporter.importDXFViews`.
// - DWG through the existing ODA temporary-DXF path, with a clear
//   converter-missing error when no ODA FileConverter is installed.
// - EAB through `EABReader` (views + `plotSetups` section union).
// - Open tabs live from `TabManager` (no disk re-read).
// =========================================================================

/// One layout tab as seen by the Publish sheet list.
public struct PublishDrawingTabMetadata: Sendable, Equatable {
    public var name: String
    public var space: PublishSpace
    /// Native setup name from the tab's own drawing (`""` = `<None>`).
    public var defaultSetupName: String
    /// Native settings from the tab's own drawing (nil = `<None>`).
    public var defaultSetup: CADPlotSettings?

    public init(
        name: String,
        space: PublishSpace,
        defaultSetupName: String = "",
        defaultSetup: CADPlotSettings? = nil
    ) {
        self.name = name
        self.space = space
        self.defaultSetupName = defaultSetupName
        self.defaultSetup = defaultSetup
    }
}

/// Metadata for one drawing loaded into the Publish sheet list.
public struct PublishDrawingMetadata: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// On-disk path (`""` for never-saved open tabs).
    public var sourcePath: String
    public var displayName: String
    public var tabs: [PublishDrawingTabMetadata]
    public var namedSetups: [CADNamedPageSetup]

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        displayName: String,
        tabs: [PublishDrawingTabMetadata] = [],
        namedSetups: [CADNamedPageSetup] = []
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.displayName = displayName
        self.tabs = tabs
        self.namedSetups = namedSetups
    }

    /// Named setups scoped to `space` (Model vs. Layout enforcement).
    public func setups(matching space: PublishSpace) -> [CADNamedPageSetup] {
        let wantModel = space == .model
        return namedSetups.filter { $0.isModelType == wantModel }
    }

    public func tab(named name: String) -> PublishDrawingTabMetadata? {
        tabs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Drawing metadata reader for PUBLISH. Errors reuse
/// `DXFPlotSettingsImport.ImportError` so `-PSETUPIN` and PUBLISH report
/// the same converter-missing / unsupported-format messages; corrupt DXF
/// or EAB content propagates the underlying importer error.
@MainActor
public enum PublishMetadataInspector {

    /// Read metadata for one file (`.dxf` / `.dwt` / `.dwg` / `.eab`).
    public static func readFile(atPath path: String) throws -> PublishDrawingMetadata {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DXFPlotSettingsImport.ImportError.missingFile(path)
        }
        switch url.pathExtension.lowercased() {
        case "dxf", "dwt":
            let imported = try DXFImporter.importDXFViews(filePath: url.path)
            return PublishDrawingMetadata(
                sourcePath: url.path,
                displayName: url.lastPathComponent,
                tabs: imported.views.map {
                    PublishDrawingTabMetadata(
                        name: $0.name,
                        space: PublishSpace(kind: $0.kind),
                        defaultSetupName: $0.plotSettings?.pageSetupName ?? "",
                        defaultSetup: $0.plotSettings)
                },
                namedSetups: imported.namedPageSetups)
        case "dwg":
            guard ODADWGConverter.isAvailable else {
                throw DXFPlotSettingsImport.ImportError.noConverter("no ODA converter found")
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("publish-inspect-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try ODADWGConverter.convertSync(input: url, output: tmp, toFormat: "DXF")
            let imported = try DXFImporter.importDXFViews(filePath: tmp.path)
            return PublishDrawingMetadata(
                sourcePath: url.path,
                displayName: url.lastPathComponent,
                tabs: imported.views.map {
                    PublishDrawingTabMetadata(
                        name: $0.name,
                        space: PublishSpace(kind: $0.kind),
                        defaultSetupName: $0.plotSettings?.pageSetupName ?? "",
                        defaultSetup: $0.plotSettings)
                },
                namedSetups: imported.namedPageSetups)
        case "eab":
            let data = try Data(contentsOf: url)
            let views = try EABReader.readViews(from: data)
            let setups = try EABReader.readNamedPageSetups(from: data)
            return PublishDrawingMetadata(
                sourcePath: url.path,
                displayName: url.lastPathComponent,
                tabs: views.map {
                    PublishDrawingTabMetadata(
                        name: $0.name,
                        space: PublishSpace(kind: $0.kind),
                        defaultSetupName: $0.document.plotSettings?.pageSetupName ?? "",
                        defaultSetup: $0.document.plotSettings)
                },
                namedSetups: setups)
        default:
            let ext = url.pathExtension
            throw DXFPlotSettingsImport.ImportError.unsupportedFormat(
                ext.isEmpty ? "(none)" : ".\(ext)")
        }
    }

    /// Snapshot the currently open tabs (live documents, no disk re-read).
    /// Unsaved tabs report `sourcePath == ""`; callers fall back to the
    /// display name for sheet naming.
    public static func readOpenTabs(from manager: TabManager) -> [PublishDrawingMetadata] {
        manager.tabs.map { tab in
            PublishDrawingMetadata(
                sourcePath: tab.fileURL?.path ?? "",
                displayName: tab.displayName,
                tabs: tab.drawingViews.map { view in
                    PublishDrawingTabMetadata(
                        name: view.name,
                        space: PublishSpace(kind: view.kind),
                        defaultSetupName: view.document.plotSettings?.pageSetupName ?? "",
                        defaultSetup: view.document.plotSettings)
                },
                namedSetups: tab.namedPageSetups)
        }
    }
}

// MARK: - DXFPlotSettingsImport generalization

@MainActor
public extension DXFPlotSettingsImport {
    /// Read full drawing metadata (tabs + named setups) for any supported
    /// Publish source file. `readNamedSetups` remains the named-setup-only
    /// entry point for `-PSETUPIN`.
    static func readMetadata(filePath: String) throws -> PublishDrawingMetadata {
        try PublishMetadataInspector.readFile(atPath: filePath)
    }

    /// Snapshot the open tabs for the Publish sheet list.
    static func readOpenTabs(from manager: TabManager) -> [PublishDrawingMetadata] {
        PublishMetadataInspector.readOpenTabs(from: manager)
    }
}
