import Foundation

// =========================================================================
// MARK: - CameraState
// =========================================================================

/// Per-tab camera state — offset, zoom, and rotation.
/// Stored on each `DocumentTab` and restored on tab switch.
public struct CameraState: Sendable {
    public var offsetX: Double
    public var offsetY: Double
    public var zoom: Double
    public var rotation: Double

    public static let `default` = CameraState(offsetX: 0, offsetY: 0, zoom: 1.0, rotation: 0)

    public init(offsetX: Double, offsetY: Double, zoom: Double, rotation: Double) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.zoom = zoom
        self.rotation = rotation
    }
}

// =========================================================================
// MARK: - TabBarActivationPolicy
// =========================================================================

/// Decides whether a tab-bar item should activate its document tab.
///
/// ImGui's `BeginTabItem` returns true every frame for the item it keeps
/// selected internally. That is not, by itself, a user action when the
/// model-active tab is floated and therefore omitted from the main tab bar:
/// the last docked item can remain "visible" indefinitely. In that state only
/// an actual item click may activate a docked tab.
public enum TabBarActivationPolicy {
    public static func shouldActivateTab(
        isActive: Bool,
        tabItemClicked: Bool,
        tabItemVisible: Bool,
        activeTabIsFloated: Bool
    ) -> Bool {
        !isActive && (tabItemClicked || (tabItemVisible && !activeTabIsFloated))
    }
}

// =========================================================================
// MARK: - DocumentTab
// =========================================================================

/// Per-view selection snapshot, saved/restored across tab and view
/// switches (mirrors `CameraState`) so each document keeps its own
/// selection — including while shown passively in a float/split view.
public struct SelectionState: Equatable, Sendable {
    public var selectedHandles: Set<UUID> = []
    public var lastSelectedHandle: UUID? = nil
    public var selectedLeaderContentHandle: UUID? = nil

    public init(
        selectedHandles: Set<UUID> = [],
        lastSelectedHandle: UUID? = nil,
        selectedLeaderContentHandle: UUID? = nil
    ) {
        self.selectedHandles = selectedHandles
        self.lastSelectedHandle = lastSelectedHandle
        self.selectedLeaderContentHandle = selectedLeaderContentHandle
    }

    public static let empty = SelectionState()
}

/// Snapshot of the active drawing space (AutoCAD TILEMODE / CVPORT / CTAB).
/// Phase 1 maps the split-document model onto AutoCAD spaces: the Model
/// view is TILEMODE 1 with the single model viewport (CVPORT 2); a sheet
/// view is TILEMODE 0 in paper space (CVPORT 1). Floating model space
/// inside a sheet viewport (CVPORT 2+ while TILEMODE 0) lands in a later
/// phase. Sendable so the Lisp eval task can read it without a MainActor hop.
public struct DrawingSpaceState: Sendable, Equatable {
    public var tileMode: Int
    public var currentViewportID: Int
    public var currentLayoutName: String
    /// Paper layout names only (AutoCAD `(layoutlist)` shape; Model excluded).
    public var paperLayoutNames: [String]

    public init(
        tileMode: Int,
        currentViewportID: Int,
        currentLayoutName: String,
        paperLayoutNames: [String]
    ) {
        self.tileMode = tileMode
        self.currentViewportID = currentViewportID
        self.currentLayoutName = currentLayoutName
        self.paperLayoutNames = paperLayoutNames
    }

    /// Headless single-document default: Model space, no paper layouts.
    public static let modelOnly = DrawingSpaceState(
        tileMode: 1,
        currentViewportID: 2,
        currentLayoutName: "Model",
        paperLayoutNames: [])
}

/// A single drawing tab — owns a `CADDocument` and associated file metadata.
public struct DrawingView {
    public var name: String
    public var kind: DXFDrawingViewKind
    public var document: CADDocument
    public var cameraState: CameraState
    public var selectionState: SelectionState = .empty
    public var backgroundColor: ColorRGBA?
    public var layoutSettings: CADLayoutSettings? {
        get { document.layoutSettings }
        set { document.layoutSettings = newValue }
    }
    public var autoContrastTrueColor: Bool {
        get { document.autoContrastTrueColor }
        set { document.autoContrastTrueColor = newValue }
    }

    public init(
        name: String,
        kind: DXFDrawingViewKind,
        document: CADDocument,
        cameraState: CameraState = .default,
        backgroundColor: ColorRGBA? = nil,
        autoContrastTrueColor: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.document = document
        self.cameraState = cameraState
        self.backgroundColor = backgroundColor
        self.document.autoContrastTrueColor = autoContrastTrueColor
    }
}

public struct DocumentTab {
    /// Unique identifier for UI state tracking
    public let id: UUID = UUID()
    /// The CAD data model for this tab.
    public var drawingViews: [DrawingView]
    public var activeViewIndex: Int = 0
    public var document: CADDocument {
        get { drawingViews[activeViewIndex].document }
        set {
            drawingViews[activeViewIndex].document = newValue
            if let payload = newValue.dxfRoundTripPayload {
                dxfRoundTripPayload = payload
            }
        }
    }
    /// The file this document was opened from / last saved to. Nil for unsaved "Untitled" docs.
    public var fileURL: URL?
    /// Display name shown in the tab bar.
    public var displayName: String
    /// DXF version used for manual DXF saves. New tabs default to AutoCAD 2018.
    public var dxfVersion: DXFVersion
    /// File-level DXF records shared by model space and every layout.
    /// Kept at tab scope so switching/replacing a drawing view cannot discard them.
    public var dxfRoundTripPayload: DXFRoundTripPayload?
    /// Per-tab camera state (zoom, pan, rotation). Preserved across tab switches.
    public var cameraState: CameraState {
        get { drawingViews[activeViewIndex].cameraState }
        set { drawingViews[activeViewIndex].cameraState = newValue }
    }

    /// Per-view selection, preserved across tab/view switches.
    public var selectionState: SelectionState {
        get { drawingViews[activeViewIndex].selectionState }
        set { drawingViews[activeViewIndex].selectionState = newValue }
    }

    /// If this tab is currently in block editing mode, the ID of the block being edited.
    public var editingBlockID: UUID?
    /// The original document before entering block edit mode.
    public var parentDocument: CADDocument?
    /// True while this tab lives in its own OS window instead of the main tab bar.
    /// Runtime UI state only — never persisted to disk.
    public var isFloated: Bool = false

    /// External-reference runtime state shared by all view documents.
    public let xrefStore = XrefRuntimeStore()

    /// Referenced-media (image/PDF underlay) runtime state.
    public let mediaStore = MediaReferenceStore()

    public init(document: CADDocument = CADDocument(),
                fileURL: URL? = nil,
                displayName: String = "Untitled",
                dxfVersion: DXFVersion = .preferredExport,
                dxfRoundTripPayload: DXFRoundTripPayload? = nil,
                editingBlockID: UUID? = nil,
                parentDocument: CADDocument? = nil,
                cameraState: CameraState = .default,
                drawingViews: [DrawingView]? = nil,
                isFloated: Bool = false) {
        self.drawingViews = drawingViews ?? [
            DrawingView(name: "Model", kind: .model, document: document, cameraState: cameraState)
        ]
        self.fileURL = fileURL
        self.displayName = displayName
        let resolvedPayload = dxfRoundTripPayload
            ?? self.drawingViews.compactMap { $0.document.dxfRoundTripPayload }.first
        self.dxfRoundTripPayload = resolvedPayload
        if let rawVersion = resolvedPayload?.sourceAcadVersion,
           let sourceVersion = DXFVersion(rawValue: rawVersion),
           sourceVersion != .unknown {
            self.dxfVersion = sourceVersion
        } else {
            self.dxfVersion = dxfVersion
        }
        self.editingBlockID = editingBlockID
        self.parentDocument = parentDocument
        self.isFloated = isFloated
        for view in self.drawingViews {
            view.document.xrefRuntimeStore = xrefStore
            view.document.mediaRuntimeStore = mediaStore
        }
    }

    /// True when any model or layout view in this tab has unsaved changes.
    public var hasUnsavedChanges: Bool {
        drawingViews.contains { $0.document.hasUnsavedChanges }
    }

    /// Build an immutable snapshot for background save.
    /// Captures all drawing views, image assets, and their current edit revisions.
    public func buildSaveSnapshot(formatVersion: UInt32 = 7,
                                   appVersion: String = "Zephyr 1.0") -> SaveTabSnapshot {
        let viewEditRevisions = drawingViews.map { $0.document.editRevision }
        let payload = dxfRoundTripPayload
            ?? drawingViews.compactMap { $0.document.dxfRoundTripPayload }.first
        let viewSnapshots = drawingViews.map { view in
            view.document.buildSaveSnapshot(
                viewName: view.name,
                viewKind: view.kind,
                cameraState: view.cameraState,
                dxfRoundTripPayloadFallback: payload,
                sourceFolderPath: fileURL?.deletingLastPathComponent().path
            )
        }
        return SaveTabSnapshot(
            tabID: id,
            drawingViews: viewSnapshots,
            fileURL: fileURL,
            displayName: displayName,
            editRevision: viewEditRevisions[activeViewIndex],
            viewEditRevisions: viewEditRevisions,
            formatVersion: formatVersion,
            appVersion: appVersion,
            activeViewIndex: activeViewIndex
        )
    }
}

// =========================================================================
// MARK: - TabManager
// =========================================================================
// MARK: - SaveProgressState
// =========================================================================

public enum SaveStatus: Equatable {
    case saving
    case autosaving
    case committing
    case failed(String)
}

public struct SaveProgressState {
    public var progress: Float = 0
    public var statusText: String = ""
    public var status: SaveStatus = .saving
    public var saveID: UUID          // generation token — stale completions are dropped
    public var isAutosave: Bool = false
    public var failedAt: Date? = nil  // timestamp for error fade-out

    public init(progress: Float = 0, statusText: String = "",
                status: SaveStatus = .saving, saveID: UUID,
                isAutosave: Bool = false, failedAt: Date? = nil) {
        self.progress = progress
        self.statusText = statusText
        self.status = status
        self.saveID = saveID
        self.isAutosave = isAutosave
        self.failedAt = failedAt
    }
}

// =========================================================================

private struct PendingSaveKey: Hashable, Sendable {
    let tabID: UUID
    let saveID: UUID
}

private struct PendingSaveCompletion: Sendable {
    let tabID: UUID
    let saveID: UUID
    let snapshot: SaveTabSnapshot
    let targetURL: URL
    let isAutosave: Bool
    let dxfVersion: DXFVersion
    let success: Bool
    let errorMessage: String?
}

/// Manages a list of `DocumentTab`s and tracks which one is active.
/// The engine delegates to the active tab for all CAD operations.
@MainActor
public final class TabManager {
    /// All open tabs.
    public private(set) var tabs: [DocumentTab] = []
    /// Index of the currently active tab. Always valid when `tabs` is non-empty.
    public private(set) var activeIndex: Int = 0

    /// Callback invoked when the active tab changes (after the switch).
    /// Engine uses this to clear selection and trigger regeneration.
    public var onActiveTabChanged: (() -> Void)? = nil

    /// Callback invoked when a tab is closed.
    public var onTabClosed: ((Int) -> Void)? = nil

    /// Callback invoked with the closed tab's ID (unlike `onTabClosed`, this
    /// stays valid when the last tab is replaced by a fresh untitled tab).
    public var onTabClosedID: ((UUID) -> Void)? = nil

    /// Callback invoked when a dirty tab needs user confirmation before closing.
    public var onTabCloseConfirmationRequested: ((UUID) -> Void)? = nil

    /// Callback invoked to get the viewport's background color for exports.
    public var getBackgroundColor: (() -> ColorRGBA)? = nil

    /// Callback that captures the engine's current camera state.
    /// Used by `switchToTab` to save camera state to the departing tab.
    public var captureCameraState: (() -> CameraState)?
    /// Callback that applies a camera state to the engine.
    /// Used by `switchToTab` to restore camera state from the incoming tab.
    public var applyCameraState: ((CameraState) -> Void)?

    /// Selection counterparts of the camera callbacks: capture on the
    /// departing tab/view, apply on the incoming one.
    public var captureSelectionState: (() -> SelectionState)?
    public var applySelectionState: ((SelectionState) -> Void)?

    // MARK: - Save State (per-tab, background-save)

    /// In-flight save tasks keyed by tab ID.
    private var saveTasksByTabID: [UUID: (task: Task<Void, Never>, saveID: UUID)] = [:]
    /// Progress/status for each tab's current (or most recent) save.
    public private(set) var saveStateByTabID: [UUID: SaveProgressState] = [:]

    private nonisolated(unsafe) var pendingSaveProgress: [PendingSaveKey: Float] = [:]
    private nonisolated(unsafe) var pendingSaveCompletions: [PendingSaveCompletion] = []
    private let pendingSaveLock = NSLock()

    /// Computed — the active tab's in-flight save state, for the status bar.
    public var activeSaveState: SaveProgressState? {
        guard let id = activeTab?.id else { return nil }
        return saveStateByTabID[id]
    }

    // MARK: - Computed Properties

    /// The active tab, or nil if no tabs are open.
    public var activeTab: DocumentTab? {
        guard activeIndex >= 0, activeIndex < tabs.count else { return nil }
        return tabs[activeIndex]
    }

    /// The active tab's CAD document, or a default empty one if no tabs exist.
    public var activeDocument: CADDocument {
        get {
            guard let tab = activeTab else {
                // Should never happen — we always maintain at least one tab.
                return CADDocument()
            }
            return tab.document
        }
    }

    /// The active tab's file URL (for Save operations).
    public var activeFileURL: URL? {
        activeTab?.fileURL
    }

    public var activeViewName: String? {
        guard let tab = activeTab else { return nil }
        return tab.drawingViews[tab.activeViewIndex].name
    }

    public var activeViewBackgroundColor: ColorRGBA? {
        guard let tab = activeTab else { return nil }
        return tab.drawingViews[tab.activeViewIndex].backgroundColor
    }

    public var availableViews: [(name: String, kind: DXFDrawingViewKind)] {
        guard let tab = activeTab else { return [] }
        return tab.drawingViews.map { ($0.name, $0.kind) }
    }

    // MARK: - Drawing space (TILEMODE / CVPORT / CTAB)

    /// Kind of the active drawing view, or nil when no tab is open.
    public var activeViewKind: DXFDrawingViewKind? {
        guard let tab = activeTab else { return nil }
        return tab.drawingViews[tab.activeViewIndex].kind
    }

    /// True while a sheet (paper-space) view is active.
    public var isPaperSpace: Bool {
        activeViewKind == .sheet
    }

    /// AutoCAD TILEMODE: 1 on the Model view, 0 on a sheet view.
    public var tileMode: Int {
        isPaperSpace ? 0 : 1
    }

    /// AutoCAD CVPORT. Phase 1: 2 (the single model viewport) on the Model
    /// view, 1 (overall paper-space viewport) on a sheet view.
    public var currentViewportID: Int {
        isPaperSpace ? 1 : 2
    }

    /// Paper layout names in tab order (Model excluded, `(layoutlist)` shape).
    public var paperLayoutNames: [String] {
        availableViews.filter { $0.kind == .sheet }.map { $0.name }
    }

    /// Immutable space snapshot for off-main consumers (Lisp sysvars).
    public var spaceState: DrawingSpaceState {
        DrawingSpaceState(
            tileMode: tileMode,
            currentViewportID: currentViewportID,
            currentLayoutName: activeViewName ?? "Model",
            paperLayoutNames: paperLayoutNames)
    }

    /// Whether the active tab has unsaved changes.
    public var activeIsDirty: Bool {
        activeTab?.hasUnsavedChanges ?? false
    }

    @discardableResult
    public func setActiveDXFVersion(_ version: DXFVersion) -> Bool {
        guard activeIndex >= 0, activeIndex < tabs.count else { return false }
        tabs[activeIndex].dxfVersion = version
        DXFVersion.preferredExport = version
        return true
    }

    // MARK: - Tab Lifecycle

    /// Create a new blank (untitled) tab and switch to it.
    /// - Returns: The index of the newly created tab.
    @discardableResult
    public func addTab(_ tab: DocumentTab) -> Int {
        tabs.append(tab)
        let idx = tabs.count - 1
        switchToTab(at: idx)
        return idx
    }

    public func newTab() -> Int {
        let doc = CADDocument()
        // Bulk-import a single "0" layer (single undo snapshot, not per-layer)
        doc.importLayersBlocksEntities(
            layers: [Layer(name: "0", color: .white)],
            blocks: [],
            entities: []
        )
        doc.savedRevision = doc.editRevision  // blank docs aren't dirty until modified

        let tab = DocumentTab(document: doc, fileURL: nil, displayName: "Untitled")
        tabs.append(tab)
        kickXrefLoads(for: tab)
        let idx = tabs.count - 1
        switchToTab(at: idx)
        return idx
    }

    /// Open a DXF, DWG or EAB file in a new tab (auto-detects format from extension).
    /// - Parameter url: The file URL to import.
    /// - Throws: `DXFImportError`, `DWGImportError` or `EABError` if parsing fails.
    @discardableResult
    public func openTab(url: URL) throws -> Int {
        print("[TabManager] openTab: \(url.lastPathComponent)")
        let ext = url.pathExtension.lowercased()
        if ext == "eab" {
            return try openEAB(url: url)
        }
        if ext == "dwg" {
            // Convert DWG → DXF via ODA FileConverter, then import the DXF.
            guard ODADWGConverter.isAvailable else {
                throw ODADWGConvertError.converterNotFound
            }
            let tempDXF = FileManager.default.temporaryDirectory
                .appendingPathComponent("dwg-import-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tempDXF) }

            try ODADWGConverter.convertSync(input: url, output: tempDXF, toFormat: "DXF")
            print("[TabManager] DWG converted to DXF, importing...")

            let imported = try DXFImporter.importDXFViews(filePath: tempDXF.path)
            print("[TabManager] DWG import: \(imported.layers.count) layers, \(imported.blocks.count) blocks, \(imported.entities.count) entities")

            for font in Set(imported.textStyles.values.map(\.fontFile)) {
                CADFontManager.debugFontLookup(font)
            }

            let drawingViews = imported.views.map { view -> DrawingView in
                let doc = CADDocument()
                doc.importLayersBlocksEntities(
                    layers: imported.layers,
                    blocks: imported.blocks,
                    entities: view.entities
                )
                doc.textStyles = imported.textStyles
                doc.importMediaDefinitions(
                    image: imported.imageDefinitions, pdf: imported.pdfDefinitions)
                doc.linetypePatterns = imported.linetypePatterns
                doc.dimensionStyles = imported.dimensionStyles
                doc.leaderStyles = imported.leaderStyles
                // Model views own model-space groups; sheets own their
                // paper-space groups (projected copies never join groups).
                let viewGroups = view.kind == .sheet ? view.groups : imported.groups
                doc.groups = Dictionary(
                    uniqueKeysWithValues: viewGroups.map { ($0.name, $0) })
                doc.plotSettings = view.plotSettings
                doc.paperSpaceLinetypeScale = imported.paperSpaceLinetypeScale
                doc.insertionBase = imported.insBase
                doc.dxfRoundTripPayload = imported.roundTripPayload
                doc.currentLeaderStyleName = imported.leaderStyles["Standard"] == nil
                    ? (imported.leaderStyles.keys.sorted().first ?? "Standard")
                    : "Standard"
                if let ls = view.layoutSettings {
                    doc.layoutSettings = ls
                    doc.unit = (ls.plotPaperUnits == 0) ? .inch : .millimeter
                } else if let su = imported.sourceUnit {
                    doc.unit = su
                }
                doc.savedRevision = doc.editRevision
                return DrawingView(
                    name: view.name,
                    kind: view.kind,
                    document: doc,
                    backgroundColor: view.backgroundColor
                )
            }
            let displayName = url.lastPathComponent
            let tab = DocumentTab(
                document: drawingViews[0].document,
                fileURL: url,
                displayName: displayName,
                drawingViews: drawingViews
            )
            tabs.append(tab)
        kickXrefLoads(for: tab)
            let idx = tabs.count - 1
            switchToTab(at: idx)
            return idx
        }
        print("[TabManager] Importing DXF...")
        let imported = try DXFImporter.importDXFViews(filePath: url.path)
        print("[TabManager] DXF imported: \(imported.layers.count) layers, \(imported.blocks.count) blocks, \(imported.entities.count) entities, \(imported.views.count) views")

        for font in Set(imported.textStyles.values.map(\.fontFile)) {
            CADFontManager.debugFontLookup(font)
        }

        let drawingViews = imported.views.map { view -> DrawingView in
            let doc = CADDocument()
            doc.importLayersBlocksEntities(
                layers: imported.layers,
                blocks: imported.blocks,
                entities: view.entities
            )
            doc.textStyles = imported.textStyles
            doc.importMediaDefinitions(
                image: imported.imageDefinitions, pdf: imported.pdfDefinitions)
            doc.linetypePatterns = imported.linetypePatterns
            doc.dimensionStyles = imported.dimensionStyles
            doc.leaderStyles = imported.leaderStyles
            // Model views own model-space groups; sheets own their
            // paper-space groups (projected copies never join groups).
            let paperGroups = view.kind == .sheet ? view.groups : imported.groups
            doc.groups = Dictionary(
                uniqueKeysWithValues: paperGroups.map { ($0.name, $0) })
            doc.plotSettings = view.plotSettings
            doc.paperSpaceLinetypeScale = imported.paperSpaceLinetypeScale
            doc.insertionBase = imported.insBase
            doc.dxfRoundTripPayload = imported.roundTripPayload
            doc.currentLeaderStyleName = imported.leaderStyles["Standard"] == nil
                ? (imported.leaderStyles.keys.sorted().first ?? "Standard")
                : "Standard"
            if let ls = view.layoutSettings {
                doc.layoutSettings = ls
                doc.unit = (ls.plotPaperUnits == 0) ? .inch : .millimeter
            } else if let su = imported.sourceUnit {
                doc.unit = su
            }
            doc.savedRevision = doc.editRevision  // freshly imported
            doc.finalizeOpen(
                sourceFileName: url.lastPathComponent, layoutName: view.name)
            return DrawingView(
                name: view.name,
                kind: view.kind,
                document: doc,
                backgroundColor: view.backgroundColor
            )
        }
        let doc = drawingViews[0].document
        let displayName = url.lastPathComponent
        let tab = DocumentTab(
            document: doc,
            fileURL: url,
            displayName: displayName,
            drawingViews: drawingViews
        )
        tabs.append(tab)
        kickXrefLoads(for: tab)
        let idx = tabs.count - 1
        switchToTab(at: idx)
        return idx
    }

    public func indexOfTab(id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    /// Request closing a tab. Dirty tabs are deferred to the UI confirmation callback.
    @discardableResult
    public func requestCloseTab(at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        let tab = tabs[index]
        if tab.hasUnsavedChanges {
            onTabCloseConfirmationRequested?(tab.id)
            return false
        }
        return closeTab(at: index)
    }

    /// Request closing the active tab, respecting unsaved-change confirmation.
    @discardableResult
    public func requestCloseActiveTab() -> Bool {
        requestCloseTab(at: activeIndex)
    }

    /// Close the tab at the given index without prompting.
    /// - Returns: True if the tab was closed or replaced by a clean untitled tab.
    @discardableResult
    public func closeTab(at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }

        // Cancel any in-flight save for this tab before removing it.
        let tabID = tabs[index].id
        if tabs.count == 1 {
            cancelSave(for: tabID, reason: .close)
            let doc = CADDocument()
            doc.importLayersBlocksEntities(
                layers: [Layer(name: "0", color: .white)],
                blocks: [],
                entities: []
            )
            doc.savedRevision = doc.editRevision
            tabs[0] = DocumentTab(document: doc, fileURL: nil, displayName: "Untitled")
            activeIndex = 0
            applySelectionState?(.empty)
            onActiveTabChanged?()
            onTabClosed?(index)
            onTabClosedID?(tabID)
            return true
        }

        cancelSave(for: tabID, reason: .close)

        let wasActive = (index == activeIndex)
        tabs.remove(at: index)

        // Adjust activeIndex
        if wasActive {
            // If closing the active tab, activate the one that slid into its place
            // or the one before it if it was the last tab.
            if index >= tabs.count {
                activeIndex = tabs.count - 1
            } else {
                activeIndex = index
            }
            // Restore camera state from newly active tab (camera was already saved
            // to the departed tab on the last `switchToTab` away from it).
            if let apply = applyCameraState {
                apply(tabs[activeIndex].cameraState)
            }
            if let apply = applySelectionState {
                apply(tabs[activeIndex].selectionState)
            }
            onActiveTabChanged?()
        } else if index < activeIndex {
            activeIndex -= 1
        }

        onTabClosed?(index)
        onTabClosedID?(tabID)
        return true
    }

    // MARK: - Float State

    /// The tab with the given ID, or nil when unknown.
    public func tab(for id: UUID) -> DocumentTab? {
        guard let index = indexOfTab(id: id) else { return nil }
        return tabs[index]
    }

    /// Whether the tab with the given ID is currently floated into its own window.
    public func isFloated(id: UUID) -> Bool {
        guard let index = indexOfTab(id: id) else { return false }
        return tabs[index].isFloated
    }

    /// Mark a tab floated or docked. Order is preserved so dock-back restores
    /// the tab to its original bar position.
    /// - Returns: False when the ID is unknown.
    @discardableResult
    public func setFloated(id: UUID, _ floated: Bool) -> Bool {
        guard let index = indexOfTab(id: id) else { return false }
        tabs[index].isFloated = floated
        return true
    }

    /// IDs of all currently floated tabs, in bar order.
    public var floatedTabIDs: [UUID] {
        tabs.filter(\.isFloated).map(\.id)
    }

    /// Docked tab that should take over the main canvas (or a split pane)
    /// when `id` leaves it by floating: the next docked tab to the right —
    /// the one that visually slides into its place — else the nearest
    /// docked tab to the left. Picking the first docked tab instead made
    /// floating the last of three tabs jump the main window back to tab 1
    /// instead of staying on tab 2.
    public func nearestDockedTabID(replacing id: UUID) -> UUID? {
        guard let index = indexOfTab(id: id) else {
            return tabs.first(where: { !$0.isFloated })?.id
        }
        for candidate in tabs[(index + 1)...] where !candidate.isFloated {
            return candidate.id
        }
        for candidate in tabs[..<index].reversed() where !candidate.isFloated {
            return candidate.id
        }
        return nil
    }

    /// Close the active tab.
    @discardableResult
    public func closeActiveTab() -> Bool {
        closeTab(at: activeIndex)
    }

    /// Switch to the tab at the given index.
    /// Saves the engine's current camera state to the departing tab, then restores
    /// the incoming tab's camera state before firing `onActiveTabChanged`.
    /// Start loading any not-yet-attempted xrefs in a tab (called once
    /// when the tab is created; later switches are no-ops for these).
    public func kickXrefLoads(for tab: DocumentTab) {
        let settings = UserSettings.load()
        tab.xrefStore.apply(settings: settings)
        let documents = tab.drawingViews.map(\.document)
        for doc in documents { doc.xrefFadePercent = settings.xrefFadePercent }
        // Keep the shared store wired even if a view document was swapped.
        for doc in documents where doc.xrefRuntimeStore !== tab.xrefStore {
            doc.xrefRuntimeStore = tab.xrefStore
        }
        for doc in documents where doc.mediaRuntimeStore !== tab.mediaStore {
            doc.mediaRuntimeStore = tab.mediaStore
        }
        XrefLoader.loadAllPending(
            store: tab.xrefStore,
            documents: documents,
            hostFolder: tab.fileURL?.deletingLastPathComponent().path)
        tab.mediaStore.apply(settings: settings)
        MediaLoader.loadAllPending(
            store: tab.mediaStore,
            documents: documents,
            hostFolder: tab.fileURL?.deletingLastPathComponent().path)
    }

    public func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count, index != activeIndex else { return }
        // Save camera + selection state to departing tab
        if let capture = captureCameraState, activeIndex < tabs.count {
            tabs[activeIndex].cameraState = capture()
        }
        if let capture = captureSelectionState, activeIndex < tabs.count {
            tabs[activeIndex].selectionState = capture()
        }
        activeIndex = index
        // Restore camera + selection state from incoming tab
        if let apply = applyCameraState {
            apply(tabs[activeIndex].cameraState)
        }
        if let apply = applySelectionState {
            apply(tabs[activeIndex].selectionState)
        }
        onActiveTabChanged?()
    }

    // MARK: - Drawing Views

    @discardableResult
    public func switchToView(at index: Int) -> Bool {
        guard activeIndex >= 0, activeIndex < tabs.count,
              index >= 0, index < tabs[activeIndex].drawingViews.count else { return false }
        if index == tabs[activeIndex].activeViewIndex {
            // Same-view activation still refreshes derived geometry so a
            // scripted PSPACE after a model edit converges without a tab hop.
            refreshActiveSheetProjections()
            // Re-apply the pruned snapshot so a live selection manager
            // drops handles replaced by the refresh.
            applySelectionState?(tabs[activeIndex].selectionState)
            return true
        }
        if let capture = captureCameraState {
            tabs[activeIndex].cameraState = capture()
        }
        if let capture = captureSelectionState {
            tabs[activeIndex].selectionState = capture()
        }
        tabs[activeIndex].activeViewIndex = index
        refreshActiveSheetProjections()
        applyCameraState?(tabs[activeIndex].cameraState)
        applySelectionState?(tabs[activeIndex].selectionState)
        onActiveTabChanged?()
        return true
    }

    /// Rebuild the active sheet's derived viewport projections from the
    /// tab's current model geometry. No-op unless a sheet view is active.
    /// Undo-free and revision-free: refreshing never dirties the file.
    /// Stale derived handles are pruned from the saved selection snapshot
    /// so a restored selection cannot reference replaced copies.
    public func refreshActiveSheetProjections() {
        guard let tab = activeTab else { return }
        let activeView = tab.drawingViews[tab.activeViewIndex]
        guard activeView.kind == .sheet else { return }
        guard let modelView = tab.drawingViews.first(where: { $0.kind == .model }) else { return }
        let sheetDoc = activeView.document
        let modelDoc = modelView.document
        let cache = effectiveProjectionCache(for: sheetDoc)
        guard !cache.isEmpty else { return }
        let modelEntities = Array(modelDoc.entitiesView)
        let xrefBlockIDs = Set(modelDoc.allBlocks.filter(\.isXref).map(\.handle))
        let projected = DXFImporter.projectedEntities(
            modelEntities: modelEntities,
            cache: cache,
            xrefBlockIDs: xrefBlockIDs)
        let missingLayers = modelDoc.allLayers.filter { sheetDoc.layer(for: $0.handle) == nil }
        let missingBlocks = modelDoc.allBlocks.filter { sheetDoc.block(for: $0.handle) == nil }
        let removed = sheetDoc.replaceViewportProjectedEntities(
            with: projected,
            additionalLayers: missingLayers,
            additionalBlocks: missingBlocks)
        guard !removed.isEmpty else { return }
        var snapshot = tab.drawingViews[tab.activeViewIndex].selectionState
        snapshot.selectedHandles.subtract(removed)
        if let last = snapshot.lastSelectedHandle, removed.contains(last) {
            snapshot.lastSelectedHandle = nil
        }
        if let leader = snapshot.selectedLeaderContentHandle, removed.contains(leader) {
            snapshot.selectedLeaderContentHandle = nil
        }
        tabs[activeIndex].drawingViews[tab.activeViewIndex].selectionState = snapshot
    }

    // MARK: - Floating viewports (Phase 3)

    /// Explicit per-sheet viewport definitions. Keyed by the sheet
    /// document's identity. Once a sheet is edited (scale/center/twist/
    /// on-off) or gains an MVIEW viewport, the stored list becomes the
    /// source of truth so an OFF viewport (zero projections, no xdata
    /// trace) survives refresh. Nil means "derive from projected xdata".
    private var sheetViewportStore: [ObjectIdentifier: [DXFImporter.SheetViewport]] = [:]
    /// Viewport picked via `selectViewport(at:)` per sheet document.
    private var selectedViewportBySheet: [ObjectIdentifier: Int] = [:]

    private func sheetKey(for sheetDoc: CADDocument) -> ObjectIdentifier {
        ObjectIdentifier(sheetDoc)
    }

    /// Viewport definitions for a sheet: stored overrides when edited,
    /// otherwise derived from projected xdata. Empty when the sheet has
    /// no viewport information.
    public func sheetViewports(for sheetDoc: CADDocument) -> [DXFImporter.SheetViewport] {
        if let stored = sheetViewportStore[sheetKey(for: sheetDoc)] { return stored }
        let cache = DXFImporter.sheetProjectionCache(from: Array(sheetDoc.entitiesView))
        return cache.exactViewports
    }

    /// Viewport definitions for the active sheet, or [] when no sheet view
    /// is active.
    public func activeSheetViewports() -> [DXFImporter.SheetViewport] {
        guard let tab = activeTab else { return [] }
        let view = tab.drawingViews[tab.activeViewIndex]
        guard view.kind == .sheet else { return [] }
        return sheetViewports(for: view.document)
    }

    /// Usable (on + valid, non-system) floating viewports on the active sheet.
    public func activeUsableViewports() -> [DXFImporter.SheetViewport] {
        activeSheetViewports().filter { $0.isUsable && !$0.isSystemViewport }
    }

    // MARK: - Layout lifecycle (Phase 4)

    /// Default paper for `createLayout`: Letter landscape, stored in mm.
    public static let defaultNewLayoutSettings = CADLayoutSettings(
        paperName: "Letter",
        paperWidthMM: 279.4, paperHeightMM: 215.9,
        plotPaperUnits: 1)

    private func layoutNameTaken(_ name: String) -> Bool {
        guard let tab = activeTab else { return false }
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.drawingViews.contains {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    private func layoutIndex(named name: String) -> Int? {
        guard let tab = activeTab else { return nil }
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tab.drawingViews.firstIndex {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    private func nextLayoutName() -> String {
        var n = 1
        while layoutNameTaken("Layout\(n)") { n += 1 }
        return "Layout\(n)"
    }

    /// Create a new sheet layout with default Letter paper and one viewport
    /// fitting current model extents (when the model is non-empty). The new
    /// sheet becomes active. Returns false when the name is blank/taken.
    @discardableResult
    public func createLayout(named name: String? = nil) -> Bool {
        guard activeTab != nil else { return false }
        let resolved = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalName = resolved.isEmpty ? nextLayoutName() : resolved
        guard !finalName.isEmpty, !layoutNameTaken(finalName) else { return false }
        guard let tab = activeTab else { return false }
        let modelView = tab.drawingViews.first(where: { $0.kind == .model })
        let doc = CADDocument()
        if let modelDoc = modelView?.document {
            doc.importLayersBlocksEntities(
                layers: modelDoc.allLayers, blocks: modelDoc.allBlocks, entities: [])
            doc.textStyles = modelDoc.textStyles
            doc.linetypePatterns = modelDoc.linetypePatterns
            doc.dimensionStyles = modelDoc.dimensionStyles
            doc.leaderStyles = modelDoc.leaderStyles
            doc.paperSpaceLinetypeScale = modelDoc.paperSpaceLinetypeScale
        }
        let settings = Self.defaultNewLayoutSettings
        doc.layoutSettings = settings
        doc.unit = .millimeter
        doc.plotSettings = CADPlotSettings(
            paperName: settings.paperName,
            paperWidthMM: settings.paperWidthMM,
            paperHeightMM: settings.paperHeightMM,
            marginLM: settings.marginLM,
            marginBM: settings.marginBM,
            marginRM: settings.marginRM,
            marginTM: settings.marginTM,
            plotPaperUnits: settings.plotPaperUnits,
            plotRotation: settings.plotRotation)
        tabs[activeIndex].drawingViews.append(DrawingView(
            name: finalName, kind: .sheet, document: doc))
        doc.savedRevision = doc.editRevision
        let newIndex = tabs[activeIndex].drawingViews.count - 1
        guard switchToView(at: newIndex) else { return false }
        // Full-sheet frame in paper units (mm); fits model extents.
        createSheetViewport(
            paperX1: 0, paperY1: 0,
            paperX2: settings.paperWidthMM, paperY2: settings.paperHeightMM)
        return true
    }

    /// Rename a sheet layout. The Model view cannot be renamed and names
    /// must stay unique (case-insensitive). Returns false otherwise.
    @discardableResult
    public func renameLayout(from oldName: String, to newName: String) -> Bool {
        guard let index = layoutIndex(named: oldName) else { return false }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !layoutNameTaken(trimmed) else { return false }
        guard tabs[activeIndex].drawingViews[index].kind == .sheet else { return false }
        tabs[activeIndex].drawingViews[index].name = trimmed
        onActiveTabChanged?()
        return true
    }

    /// Delete a sheet layout. The Model view and the last remaining view
    /// cannot be deleted. The Model view becomes active when the active
    /// sheet is deleted.
    @discardableResult
    public func deleteLayout(named name: String) -> Bool {
        guard let index = layoutIndex(named: name) else { return false }
        guard tabs[activeIndex].drawingViews.count > 1 else { return false }
        let doomed = tabs[activeIndex].drawingViews[index]
        guard doomed.kind == .sheet else { return false }
        sheetViewportStore.removeValue(forKey: sheetKey(for: doomed.document))
        selectedViewportBySheet.removeValue(forKey: sheetKey(for: doomed.document))
        tabs[activeIndex].drawingViews.remove(at: index)
        var active = tabs[activeIndex].activeViewIndex
        if index < active {
            active -= 1
        } else if index == active {
            active = min(active, tabs[activeIndex].drawingViews.count - 1)
        }
        tabs[activeIndex].activeViewIndex = max(0, active)
        refreshActiveSheetProjections()
        onActiveTabChanged?()
        return true
    }

    /// Copy a sheet layout (paper geometry, viewport definitions, groups,
    /// settings) under a new name. Derived projections rebuild live from
    /// the model on activation. The copy becomes active.
    @discardableResult
    public func copyLayout(from sourceName: String, to newName: String) -> Bool {
        guard let index = layoutIndex(named: sourceName) else { return false }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !layoutNameTaken(trimmed) else { return false }
        guard tabs[activeIndex].drawingViews[index].kind == .sheet else { return false }
        let sourceDoc = tabs[activeIndex].drawingViews[index].document
        let copy = CADDocument()
        copy.restore(from: sourceDoc.snapshot())
        copy.savedRevision = copy.editRevision
        if let stored = sheetViewportStore[sheetKey(for: sourceDoc)] {
            sheetViewportStore[sheetKey(for: copy)] = stored
        }
        if let selected = selectedViewportBySheet[sheetKey(for: sourceDoc)] {
            selectedViewportBySheet[sheetKey(for: copy)] = selected
        }
        tabs[activeIndex].drawingViews.append(DrawingView(
            name: trimmed, kind: .sheet, document: copy))
        let newIndex = tabs[activeIndex].drawingViews.count - 1
        return switchToView(at: newIndex)
    }

    /// Viewport picked by the user on the active sheet (via
    /// `selectViewport(at:)`), falling back to the first usable viewport.
    /// Nil when the active sheet has no usable viewport.
    public func activeViewport() -> DXFImporter.SheetViewport? {
        let usable = activeUsableViewports()
        guard !usable.isEmpty else { return nil }
        guard let tab = activeTab else { return usable[0] }
        let key = sheetKey(for: tab.drawingViews[tab.activeViewIndex].document)
        if let selected = selectedViewportBySheet[key],
           let match = usable.first(where: { $0.id == selected }) { return match }
        return usable[0]
    }

    /// Pick the topmost floating viewport whose paper frame contains
    /// `(x, y)` (sheet coordinates). Records the pick as the sheet's
    /// selected viewport and returns it. Nil when none contains the point.
    @discardableResult
    public func selectViewport(atPaperPoint x: Double, _ y: Double) -> DXFImporter.SheetViewport? {
        guard let tab = activeTab else { return nil }
        let view = tab.drawingViews[tab.activeViewIndex]
        guard view.kind == .sheet else { return nil }
        let candidates = sheetViewports(for: view.document)
            .filter { $0.isUsable && !$0.isSystemViewport && $0.containsPaperPoint(x: x, y: y) }
            .sorted { $0.id > $1.id }
        guard let pick = candidates.first else { return nil }
        selectedViewportBySheet[sheetKey(for: view.document)] = pick.id
        return pick
    }

    /// Rewrite one viewport definition on the active sheet and re-project.
    /// Returns false when no sheet is active or the id is unknown.
    @discardableResult
    public func updateActiveSheetViewport(
        id: Int,
        status: Int? = nil,
        scale: Double? = nil,
        viewTarget: (x: Double, y: Double)? = nil,
        twistDegrees: Double? = nil
    ) -> Bool {
        guard let tab = activeTab else { return false }
        let index = tab.activeViewIndex
        let view = tab.drawingViews[index]
        guard view.kind == .sheet else { return false }
        var viewports = sheetViewports(for: view.document)
        guard let slot = viewports.firstIndex(where: { $0.id == id }) else { return false }
        var edited = viewports[slot]
        if let status { edited = edited.withStatus(status) }
        if let scale { edited = edited.withScale(scale) }
        if let target = viewTarget { edited = edited.withViewTarget(x: target.x, y: target.y) }
        if let twist = twistDegrees { edited = edited.withTwistDegrees(twist) }
        viewports[slot] = edited
        sheetViewportStore[sheetKey(for: view.document)] = viewports
        refreshActiveSheetProjections()
        return true
    }

    /// Create a rectangular floating viewport on the active sheet from two
    /// paper corners. Fits current model extents by default. Returns the
    /// new viewport id, or nil when no sheet is active or the rect is
    /// degenerate.
    @discardableResult
    public func createSheetViewport(
        paperX1: Double, paperY1: Double, paperX2: Double, paperY2: Double
    ) -> Int? {
        guard let tab = activeTab else { return nil }
        let index = tab.activeViewIndex
        let view = tab.drawingViews[index]
        guard view.kind == .sheet else { return nil }
        let paperWidth = abs(paperX2 - paperX1)
        let paperHeight = abs(paperY2 - paperY1)
        guard paperWidth > 1e-9, paperHeight > 1e-9 else { return nil }
        guard let modelView = tab.drawingViews.first(where: { $0.kind == .model }) else { return nil }
        var viewports = sheetViewports(for: view.document)
        let nextID = (viewports.map(\.id).max() ?? 1) + 1
        // Fit current model extents into the new frame.
        var modelBounds: BoundingBox3D? = nil
        for entity in modelView.document.entitiesView {
            guard !entity.isViewportProjected,
                  let box = entity.worldBoundingBox else { continue }
            modelBounds = modelBounds.map { $0.union(with: box) } ?? box
        }
        let modelCenterX: Double
        let modelCenterY: Double
        let viewHeight: Double
        if let bounds = modelBounds,
           bounds.max.x - bounds.min.x > 1e-9,
           bounds.max.y - bounds.min.y > 1e-9 {
            modelCenterX = bounds.center.x
            modelCenterY = bounds.center.y
            let modelW = bounds.max.x - bounds.min.x
            let modelH = bounds.max.y - bounds.min.y
            let fitScale = min(paperWidth / modelW, paperHeight / modelH) * 0.9
            viewHeight = paperHeight / max(fitScale, 1e-9)
        } else {
            modelCenterX = 0
            modelCenterY = 0
            viewHeight = paperHeight
        }
        let paperCenterX = (paperX1 + paperX2) / 2.0
        // Stored paperCenterY is positive-down (see modelToPaperTransform).
        let paperCenterY = -((paperY1 + paperY2) / 2.0)
        let viewport = DXFImporter.SheetViewport(
            paperCenterX: paperCenterX, paperCenterY: paperCenterY,
            paperWidth: paperWidth, paperHeight: paperHeight,
            status: nextID, id: nextID,
            viewCenterX: 0, viewCenterY: 0,
            viewTargetX: modelCenterX, viewTargetY: modelCenterY,
            viewHeight: viewHeight, twistAngle: 0,
            layerName: "MODEL")
        viewports.append(viewport)
        viewports.sort { $0.id < $1.id }
        sheetViewportStore[sheetKey(for: view.document)] = viewports
        selectedViewportBySheet[sheetKey(for: view.document)] = nextID
        refreshActiveSheetProjections()
        return nextID
    }

    /// Effective viewport definitions for `refreshActiveSheetProjections`:
    /// stored overrides when present, else derived from projected xdata.
    private func effectiveProjectionCache(
        for sheetDoc: CADDocument
    ) -> DXFImporter.SheetProjectionCache {
        if let stored = sheetViewportStore[sheetKey(for: sheetDoc)] {
            var cache = DXFImporter.SheetProjectionCache()
            cache.exactViewports = stored
            return cache
        }
        return DXFImporter.sheetProjectionCache(from: Array(sheetDoc.entitiesView))
    }

    /// Move entities between spaces through a viewport transform (CHSPACE).
    /// Paper -> Model when a sheet view is active: every non-derived paper
    /// entity in `handles` is inverse-transformed into the tab's model
    /// document. Model -> Sheet when a model view is active: moves to the
    /// tab's first sheet through its first usable viewport. Missing
    /// layers/blocks are adopted by the destination. Returns moved count.
    @discardableResult
    public func chspace(handles: Set<UUID>) -> Int {
        guard let tab = activeTab else { return 0 }
        let view = tab.drawingViews[tab.activeViewIndex]
        if view.kind == .sheet {
            guard let modelView = tab.drawingViews.first(where: { $0.kind == .model }),
                  let viewport = activeViewport() ?? activeUsableViewports().first
            else { return 0 }
            let sheetDoc = view.document
            let modelDoc = modelView.document
            let inverse = viewport.modelToPaperTransform.inverse()
            let movers = handles.compactMap { sheetDoc.entity(for: $0) }
                .filter { !$0.isViewportProjected }
            guard !movers.isEmpty else { return 0 }
            var moved: [CADEntity] = []
            moved.reserveCapacity(movers.count)
            for entity in movers {
                moved.append(CADEntity(
                    layerID: entity.layerID,
                    blockID: entity.blockID,
                    localGeometry: entity.localGeometry,
                    dimensionMetadata: entity.dimensionMetadata,
                    leaderData: entity.leaderData,
                    arrayData: entity.arrayData,
                    transform: inverse.multiplying(by: entity.transform),
                    xdata: entity.xdata,
                    drawOrder: entity.drawOrder,
                    localBoundingBox: entity.localBoundingBox,
                    anchorPoints: entity.anchorPoints))
            }
            let missingLayers = sheetDoc.allLayers.filter { modelDoc.layer(for: $0.handle) == nil }
            let missingBlocks = sheetDoc.allBlocks.filter { modelDoc.block(for: $0.handle) == nil }
            if !missingLayers.isEmpty || !missingBlocks.isEmpty {
                modelDoc.importLayersBlocksEntities(
                    layers: missingLayers, blocks: missingBlocks, entities: [])
            }
            modelDoc.addEntities(moved)
            sheetDoc.removeEntities(handles: Set(movers.map(\.handle)))
            refreshActiveSheetProjections()
            return movers.count
        } else {
            guard let sheetIndex = tab.drawingViews.firstIndex(where: { $0.kind == .sheet })
            else { return 0 }
            let modelDoc = view.document
            let sheetDoc = tab.drawingViews[sheetIndex].document
            let viewports = sheetViewports(for: sheetDoc)
                .filter { $0.isUsable && !$0.isSystemViewport }
            guard let viewport = viewports.first else { return 0 }
            let movers = handles.compactMap { modelDoc.entity(for: $0) }
                .filter { !$0.isViewportProjected }
            guard !movers.isEmpty else { return 0 }
            let forward = viewport.modelToPaperTransform
            var moved: [CADEntity] = []
            moved.reserveCapacity(movers.count)
            for entity in movers {
                moved.append(CADEntity(
                    layerID: entity.layerID,
                    blockID: entity.blockID,
                    localGeometry: entity.localGeometry,
                    dimensionMetadata: entity.dimensionMetadata,
                    leaderData: entity.leaderData,
                    arrayData: entity.arrayData,
                    transform: forward.multiplying(by: entity.transform),
                    xdata: entity.xdata,
                    drawOrder: entity.drawOrder,
                    localBoundingBox: entity.localBoundingBox,
                    anchorPoints: entity.anchorPoints))
            }
            let missingLayers = modelDoc.allLayers.filter { sheetDoc.layer(for: $0.handle) == nil }
            let missingBlocks = modelDoc.allBlocks.filter { sheetDoc.block(for: $0.handle) == nil }
            if !missingLayers.isEmpty || !missingBlocks.isEmpty {
                sheetDoc.importLayersBlocksEntities(
                    layers: missingLayers, blocks: missingBlocks, entities: [])
            }
            sheetDoc.addEntities(moved)
            modelDoc.removeEntities(handles: Set(movers.map(\.handle)))
            return movers.count
        }
    }

    @discardableResult
    public func switchToView(named name: String) -> Bool {
        guard let tab = activeTab else { return false }
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let oneBasedIndex = Int(needle),
           oneBasedIndex >= 1, oneBasedIndex <= tab.drawingViews.count {
            return switchToView(at: oneBasedIndex - 1)
        }
        guard let index = tab.drawingViews.firstIndex(where: {
            $0.name.caseInsensitiveCompare(needle) == .orderedSame
                || ($0.kind == .model
                    && ["MODEL", "2D", "2D VIEW"].contains(needle.uppercased()))
        }) else { return false }
        return switchToView(at: index)
    }

    @discardableResult
    public func cycleView(direction: Int = 1, sheetsOnly: Bool = false) -> Bool {
        guard let tab = activeTab, !tab.drawingViews.isEmpty else { return false }
        let candidates = tab.drawingViews.indices.filter {
            !sheetsOnly || tab.drawingViews[$0].kind == .sheet
        }
        guard !candidates.isEmpty else { return false }
        let currentPosition = candidates.firstIndex(of: tab.activeViewIndex)
        let nextPosition: Int
        if let currentPosition {
            nextPosition = (currentPosition + direction % candidates.count + candidates.count)
                % candidates.count
        } else {
            nextPosition = direction >= 0 ? 0 : candidates.count - 1
        }
        return switchToView(at: candidates[nextPosition])
    }

    /// Switch to the Model view (MODEL / MSPACE in Phase 1; true floating
    /// model space inside a sheet viewport lands in a later phase).
    /// Returns true when a model view is active afterwards (including when
    /// it already was); false only when the tab has no model view.
    @discardableResult
    public func switchToModelSpace() -> Bool {
        guard let tab = activeTab,
              let index = tab.drawingViews.firstIndex(where: { $0.kind == .model })
        else { return false }
        return switchToView(at: index)
    }

    /// Switch to paper space (PSPACE): stay put when a sheet is already
    /// active, otherwise activate the first sheet view. Returns false when
    /// the drawing has no sheet layouts (caller reports it honestly).
    @discardableResult
    public func switchToPaperSpace() -> Bool {
        guard let tab = activeTab else { return false }
        if tab.drawingViews[tab.activeViewIndex].kind == .sheet { return true }
        guard let index = tab.drawingViews.firstIndex(where: { $0.kind == .sheet })
        else { return false }
        return switchToView(at: index)
    }

    // MARK: - Tab Reordering

    /// Move the tab at `from` to position `to`.
    /// The destination is clamped into range; the same tab stays active
    /// (resolved by identity, since indices shift). Camera state is stored
    /// per tab, so no save/restore is needed.
    /// - Returns: False when `from` is out of range; true otherwise
    ///   (including a no-op move to the tab's own position).
    /// Bumped whenever tab order actually changes. ImGui's tab bar
    /// keeps its own visual order and only re-sorts it when a tab is
    /// added or its Reorderable flag toggles, so the UI layer watches
    /// this counter to force a re-sort after a model reorder.
    public private(set) var tabOrderGeneration: UInt64 = 0

    @discardableResult
    public func moveTab(from: Int, to: Int) -> Bool {
        guard from >= 0, from < tabs.count else { return false }
        let clampedTo = max(0, min(to, tabs.count - 1))
        guard clampedTo != from else { return true }
        let activeID = tabs[activeIndex].id
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clampedTo)
        if let newActive = tabs.firstIndex(where: { $0.id == activeID }) {
            activeIndex = newActive
        }
        tabOrderGeneration &+= 1
        return true
    }

    /// Move the active tab one position left.
    /// - Returns: False when the active tab is already first.
    @discardableResult
    public func moveActiveTabLeft() -> Bool {
        guard activeIndex > 0 else { return false }
        return moveTab(from: activeIndex, to: activeIndex - 1)
    }

    /// Move the active tab one position right.
    /// - Returns: False when the active tab is already last.
    @discardableResult
    public func moveActiveTabRight() -> Bool {
        guard activeIndex < tabs.count - 1 else { return false }
        return moveTab(from: activeIndex, to: activeIndex + 1)
    }

    // MARK: - Tab Cycling

    /// Switch to the next (direction > 0) or previous tab, wrapping around.
    /// - Returns: False when there are no tabs.
    @discardableResult
    public func cycleTab(direction: Int = 1) -> Bool {
        guard !tabs.isEmpty else { return false }
        let count = tabs.count
        let next = (activeIndex + direction % count + count) % count
        switchToTab(at: next)
        return true
    }

    // MARK: - Block Editor Operations

    private enum BlockEditorMetadata {
        static let hadPrimitiveStyle = "zephyr.blockEditor.hadPrimitiveStyle"
        static let colorByBlock = "zephyr.blockEditor.colorByBlock"
        static let lineTypeByBlock = "zephyr.blockEditor.lineTypeByBlock"
        static let lineWeightByBlock = "zephyr.blockEditor.lineWeightByBlock"
    }

    private func blockEditorHex(_ color: ColorRGBA) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    private func blockEditorFlag(_ xdata: [String: XDataValue], _ key: String) -> Bool {
        guard case .int(let value) = xdata[key] else { return false }
        return value != 0
    }

    private func makeBlockEditorEntity(
        primitive: CADPrimitive,
        primitiveStyle: CADPrimitiveStyle?,
        primitiveXData: [String: XDataValue],
        primitiveIndex: Int,
        layerIDsByName: [String: UUID],
        fallbackLayerID: UUID
    ) -> CADEntity {
        let styleLayerName = primitiveStyle?.layerName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let layerID = styleLayerName.flatMap {
            layerIDsByName[$0.uppercased()]
        } ?? fallbackLayerID

        var xdata = primitiveXData
        xdata[BlockEditorMetadata.hadPrimitiveStyle] = .int(primitiveStyle == nil ? 0 : 1)

        if let style = primitiveStyle {
            xdata[BlockEditorMetadata.colorByBlock] = .int(style.isColorByBlock ? 1 : 0)
            xdata[BlockEditorMetadata.lineTypeByBlock] = .int(style.isLineTypeByBlock ? 1 : 0)
            xdata[BlockEditorMetadata.lineWeightByBlock] = .int(style.isLineWeightByBlock ? 1 : 0)

            if let color = style.color {
                xdata["dxf.color"] = .string(blockEditorHex(color))
            }
            if let opacity = style.opacity {
                xdata["dxf.opacity"] = .double(opacity)
            }
            if let lineType = style.lineType {
                let normalized = lineType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if !normalized.isEmpty && normalized != "BYLAYER" && normalized != "BYBLOCK" {
                    xdata["dxf.lineType"] = .string(lineType)
                }
            }
            if let lineWeight = style.lineWeight {
                xdata["dxf.lineWeight"] = .double(lineWeight)
            }
            if let lineTypeScale = style.lineTypeScale {
                xdata["dxf.lineTypeScale"] = .double(lineTypeScale)
            }
            if let geomWidth = style.geomWidth {
                xdata["dxf.polylineWidth"] = .double(geomWidth)
            }
            if let plotStyleHandle = style.plotStyleHandle {
                xdata["dxf.plotStyleHandle"] = .string(plotStyleHandle)
            }
            if let backgroundScale = style.textBackgroundScale {
                xdata["dxf.mtextBackgroundScale"] = .double(backgroundScale)
            }
            xdata["dxf.mtextBackgroundUsesViewportColor"] = .int(
                style.textBackgroundUsesViewportColor ? 1 : 0)
            if let backgroundColor = style.textBackgroundColor {
                xdata["dxf.mtextBackgroundColor"] = .string(blockEditorHex(backgroundColor))
                if backgroundColor.a < 255 {
                    xdata["dxf.mtextBackgroundOpacity"] = .double(
                        Double(backgroundColor.a) / 255.0)
                }
            }
        }

        var localGeometry = [primitive]
        var transform = Transform3D.identity

        if case .text(
            let position, let text, let height, let rotation, let textStyle,
            let alignH, let alignV, let mtextWidth, let color
        ) = primitive {
            localGeometry = [.text(
                position: .zero,
                text: text,
                height: height,
                rotation: 0,
                style: textStyle,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: mtextWidth,
                color: color)]
            transform = .translated(by: position)
            if rotation != 0 {
                transform = transform.multiplying(by: .rotated(by: rotation))
            }

            if let color, xdata["dxf.color"] == nil {
                xdata["dxf.color"] = .string(blockEditorHex(color))
            }
            xdata["dxf.text"] = .string(text)
            xdata["dxf.textHeight"] = .double(height)
            if let textStyle {
                xdata["dxf.textStyle"] = .string(textStyle)
            }
            xdata["dxf.alignH"] = .int(alignH)
            xdata["dxf.alignV"] = .int(alignV)
            if let mtextWidth {
                xdata["dxf.mtextWidth"] = .double(mtextWidth)
            }
        }

        return CADEntity(
            handle: UUID(),
            layerID: layerID,
            blockID: nil,
            localGeometry: localGeometry,
            transform: transform,
            xdata: xdata,
            drawOrder: primitiveIndex)
    }

    private func blockPrimitiveStyle(
        from entity: CADEntity,
        in document: CADDocument
    ) -> CADPrimitiveStyle? {
        let hadPrimitiveStyle = blockEditorFlag(
            entity.xdata, BlockEditorMetadata.hadPrimitiveStyle)
        let layerName = document.layer(for: entity.layerID)?.name

        let color: ColorRGBA?
        if case .string(let hex) = entity.xdata["dxf.color"] {
            color = ColorRGBA(hex: hex)
        } else {
            color = nil
        }

        let lineType: String?
        if case .string(let value) = entity.xdata["dxf.lineType"] {
            lineType = value
        } else if blockEditorFlag(entity.xdata, BlockEditorMetadata.lineTypeByBlock) {
            lineType = "BYBLOCK"
        } else if hadPrimitiveStyle {
            lineType = "BYLAYER"
        } else {
            lineType = nil
        }

        let lineWeight: Double?
        if case .double(let value) = entity.xdata["dxf.lineWeight"] {
            lineWeight = value
        } else {
            lineWeight = nil
        }

        let lineTypeScale: Double?
        if case .double(let value) = entity.xdata["dxf.lineTypeScale"] {
            lineTypeScale = value
        } else {
            lineTypeScale = nil
        }

        let geomWidth: Double?
        if case .double(let value) = entity.xdata["dxf.polylineWidth"] {
            geomWidth = value
        } else {
            geomWidth = nil
        }

        let opacity: Double?
        if case .double(let value) = entity.xdata["dxf.opacity"] {
            opacity = value
        } else {
            opacity = nil
        }

        let plotStyleHandle: String?
        if case .string(let value) = entity.xdata["dxf.plotStyleHandle"] {
            plotStyleHandle = value
        } else {
            plotStyleHandle = nil
        }

        let textBackgroundScale: Double?
        if case .double(let value) = entity.xdata["dxf.mtextBackgroundScale"] {
            textBackgroundScale = value
        } else {
            textBackgroundScale = nil
        }

        var textBackgroundColor: ColorRGBA?
        if case .string(let hex) = entity.xdata["dxf.mtextBackgroundColor"],
           let parsed = ColorRGBA(hex: hex) {
            if case .double(let value) = entity.xdata["dxf.mtextBackgroundOpacity"] {
                textBackgroundColor = ColorRGBA(
                    r: parsed.r,
                    g: parsed.g,
                    b: parsed.b,
                    a: UInt8(min(255.0, max(0.0, value) * 255.0)))
            } else {
                textBackgroundColor = parsed
            }
        }

        let textBackgroundUsesViewportColor: Bool
        if case .int(let value) = entity.xdata["dxf.mtextBackgroundUsesViewportColor"] {
            textBackgroundUsesViewportColor = value != 0
        } else {
            textBackgroundUsesViewportColor = false
        }

        let hasNonZeroLayer = layerName.map {
            $0.caseInsensitiveCompare("0") != .orderedSame
        } ?? false
        let hasStyleData = hadPrimitiveStyle
            || hasNonZeroLayer
            || color != nil
            || blockEditorFlag(entity.xdata, BlockEditorMetadata.colorByBlock)
            || lineType != nil
            || lineWeight != nil
            || blockEditorFlag(entity.xdata, BlockEditorMetadata.lineWeightByBlock)
            || lineTypeScale != nil
            || geomWidth != nil
            || opacity != nil
            || plotStyleHandle != nil
            || textBackgroundScale != nil
            || textBackgroundColor != nil
            || textBackgroundUsesViewportColor

        guard hasStyleData else { return nil }

        return CADPrimitiveStyle(
            layerName: layerName,
            color: color,
            isColorByBlock: blockEditorFlag(
                entity.xdata, BlockEditorMetadata.colorByBlock),
            lineType: lineType,
            isLineTypeByBlock: blockEditorFlag(
                entity.xdata, BlockEditorMetadata.lineTypeByBlock),
            lineWeight: lineWeight,
            isLineWeightByBlock: blockEditorFlag(
                entity.xdata, BlockEditorMetadata.lineWeightByBlock),
            lineTypeScale: lineTypeScale,
            geomWidth: geomWidth,
            opacity: opacity,
            plotStyleHandle: plotStyleHandle,
            textBackgroundScale: textBackgroundScale,
            textBackgroundColor: textBackgroundColor,
            textBackgroundUsesViewportColor: textBackgroundUsesViewportColor)
    }

    private func blockPrimitiveXData(
        from entity: CADEntity,
        primitive: CADPrimitive
    ) -> [String: XDataValue] {
        var xdata = entity.xdata
        xdata.removeValue(forKey: BlockEditorMetadata.hadPrimitiveStyle)
        xdata.removeValue(forKey: BlockEditorMetadata.colorByBlock)
        xdata.removeValue(forKey: BlockEditorMetadata.lineTypeByBlock)
        xdata.removeValue(forKey: BlockEditorMetadata.lineWeightByBlock)

        if entity.transform != .identity {
            xdata.removeValue(forKey: "dxf.hatchScale")
            xdata.removeValue(forKey: "dxf.hatchAngle")
            xdata.removeValue(forKey: "dxf.hatchPatternLines")
        }

        if case .text(
            _, let text, let height, _, let style,
            let alignH, let alignV, let mtextWidth, _
        ) = primitive {
            if case .string(let raw) = xdata["dxf.mtextRaw"],
               DXFEntityConverter.cleanMTextFormatting(raw) != text {
                xdata.removeValue(forKey: "dxf.mtextRaw")
            }
            xdata["dxf.text"] = .string(text)
            xdata["dxf.textHeight"] = .double(height)
            if let style {
                xdata["dxf.textStyle"] = .string(style)
            } else {
                xdata.removeValue(forKey: "dxf.textStyle")
            }
            xdata["dxf.alignH"] = .int(alignH)
            xdata["dxf.alignV"] = .int(alignV)
            if let mtextWidth {
                xdata["dxf.mtextWidth"] = .double(mtextWidth)
            } else {
                xdata.removeValue(forKey: "dxf.mtextWidth")
            }
        }

        return xdata
    }

    public var editingArrayHandle: UUID? {
        guard let tab = activeTab,
              let blockID = tab.editingBlockID,
              let parentDocument = tab.parentDocument else { return nil }
        return parentDocument.entitiesView.first {
            $0.blockID == blockID && $0.arrayData != nil
        }?.handle
    }

    /// Enters block editor mode for the given block ID.
    /// Pass `shadow` to edit an xref in place (REFEDIT): the session
    /// materializes the loaded shadow geometry instead of the (empty)
    /// host definition, and REFCLOSE saves back to the xref file.
    public func enterBlockEditor(blockID: UUID, shadow: CADBlock? = nil) {
        guard var tab = activeTab else { return }
        guard tab.editingBlockID == nil else { return }
        guard let block = tab.document.block(for: blockID) else { return }
        guard !block.isXref || shadow != nil else {
            print("[Xref] '\(block.name)' is an external reference — open the source file to edit it, or Bind it first.")
            return
        }
        let source = shadow ?? block

        let tempDoc = CADDocument()
        let layers = tab.document.allLayers
        let layerIDsByName = Dictionary(
            layers.map { ($0.name.uppercased(), $0.handle) },
            uniquingKeysWith: { first, _ in first })
        let fallbackLayerID = layerIDsByName["0"]
            ?? tab.document.activeLayerID
            ?? layers.first?.handle
            ?? UUID()

        tempDoc.activeLayerID = tab.document.activeLayerID ?? fallbackLayerID
        tempDoc.unit = tab.document.unit
        tempDoc.textStyles = tab.document.textStyles
        tempDoc.dimensionStyles = tab.document.dimensionStyles
        tempDoc.leaderStyles = tab.document.leaderStyles
        tempDoc.currentLeaderStyleName = tab.document.currentLeaderStyleName
        tempDoc.linetypePatterns = tab.document.linetypePatterns
        tempDoc.imageStore = tab.document.imageStore

        let tempEntities = source.geometry.enumerated().map { index, primitive in
            makeBlockEditorEntity(
                primitive: primitive,
                primitiveStyle: source.primitiveStyles[index],
                primitiveXData: source.primitiveXData[index] ?? [:],
                primitiveIndex: index,
                layerIDsByName: layerIDsByName,
                fallbackLayerID: fallbackLayerID)
        }

        tempDoc.importLayersBlocksEntities(
            layers: layers,
            blocks: tab.document.allBlocks,
            entities: tempEntities)
        tempDoc.savedRevision = tempDoc.editRevision

        tab.parentDocument = tab.document
        tab.document = tempDoc
        tab.editingBlockID = blockID
        tabs[activeIndex] = tab

        onActiveTabChanged?()
    }

    /// Exits block editor mode.
    public func exitBlockEditor(saveChanges: Bool) {
        guard var tab = activeTab else { return }
        guard let blockID = tab.editingBlockID, let parentDoc = tab.parentDocument else { return }

        // Xref sessions never write back through the block table:
        // shadow geometry reaches the file only via REFCLOSE save-back.
        let isXrefSession = parentDoc.block(for: blockID)?.isXref == true
        if saveChanges, !isXrefSession {
            var newPrimitives: [CADPrimitive] = []
            var newPrimitiveStyles: [Int: CADPrimitiveStyle] = [:]
            var newPrimitiveXData: [Int: [String: XDataValue]] = [:]
            let orderedEntities = tab.document.entitiesView.sorted { lhs, rhs in
                if lhs.drawOrder != rhs.drawOrder {
                    return lhs.drawOrder < rhs.drawOrder
                }
                return lhs.handle.uuidString < rhs.handle.uuidString
            }

            for entity in orderedEntities {
                guard let geometry = entity.resolvedGeometry(in: tab.document) else { continue }
                let transformedGeometry = entity.transform == .identity
                    ? geometry
                    : CADGeometryMath.transformPrimitives(geometry, by: entity.transform)
                let primitiveStyle = blockPrimitiveStyle(from: entity, in: tab.document)

                for primitive in transformedGeometry {
                    let index = newPrimitives.count
                    newPrimitives.append(primitive)
                    if let primitiveStyle {
                        newPrimitiveStyles[index] = primitiveStyle
                    }
                    let primitiveXData = blockPrimitiveXData(
                        from: entity,
                        primitive: primitive)
                    if !primitiveXData.isEmpty {
                        newPrimitiveXData[index] = primitiveXData
                    }
                }
            }

            parentDoc.pushUndo()
            parentDoc.updateBlockGeometryLive(
                handle: blockID,
                geometry: newPrimitives,
                primitiveStyles: newPrimitiveStyles,
                primitiveXData: newPrimitiveXData)
            parentDoc.markEdited(regenerate: true)
            parentDoc.invalidateEntityGrid()
        }

        // The visible document object changes on both Save and Discard.
        // Discard does not edit the parent, but render contexts are still
        // holding the temporary block-editor document and must rebuild.
        parentDoc.markNeedsRegeneration()
        tab.document = parentDoc
        tab.parentDocument = nil
        tab.editingBlockID = nil
        tabs[activeIndex] = tab

        onActiveTabChanged?()
    }


    // MARK: - Save Operations

    /// Save the active tab to its associated file. If the tab has no file URL,
    /// this is a no-op — the caller should use `startSaveActiveTabAs(url:)` instead.
    /// - Throws: `TabError` if no file URL or block editor is active.
    public func saveActiveTab() throws {
        guard let tab = activeTab else { throw TabError.noActiveTab }
        if tab.editingBlockID != nil {
            throw TabError.cannotSaveWhileInBlockEditor
        }
        guard let fileURL = tab.fileURL else {
            throw TabError.noFileURL
        }
        try saveActiveTabAs(url: fileURL, dxfVersion: tab.dxfVersion)
    }

    /// Save the active tab to a new file URL (sync, legacy — blocks UI).
    /// Auto-detects format from file extension (.eab → binary, .dwg → DWG, .dxf → DXF).
    /// - Throws: `DXFExportError`, `DWGExportError` or `EABError` if writing fails.
    public func saveActiveTabAs(url: URL, dxfVersion: DXFVersion = .defaultExport) throws {
        guard var tab = activeTab else { throw TabError.noActiveTab }
        if tab.editingBlockID != nil {
            throw TabError.cannotSaveWhileInBlockEditor
        }
        let ext = url.pathExtension.lowercased()
        if ext == "eab" {
            try EABWriter.write(views: tab.drawingViews, to: url)
        } else if ext == "pdf" {
            let activeView = tab.drawingViews[tab.activeViewIndex]
            let bg = activeView.backgroundColor ?? getBackgroundColor?()
            try PDFExporter.export(document: tab.document, to: url, backgroundColor: bg)
        } else if ext == "dwg" {
            warnAboutDXFXrefTargets(tab: tab, url: url)
            // Save as DXF to temp, then convert to DWG via ODA FileConverter.
            guard ODADWGConverter.isAvailable else {
                throw ODADWGConvertError.converterNotFound
            }
            let tempDXF = FileManager.default.temporaryDirectory
                .appendingPathComponent("dwg-export-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tempDXF) }

            try DXFExporter.export(
                views: tab.drawingViews, to: tempDXF, dxfVersion: dxfVersion,
                tileMode: tab.drawingViews[tab.activeViewIndex].kind == .sheet ? 0 : 1,
                psltscale: tab.drawingViews[tab.activeViewIndex].document.paperSpaceLinetypeScale)
            try ODADWGConverter.convertSync(input: tempDXF, output: url, toFormat: "DWG")
        } else {
            try DXFExporter.export(
                views: tab.drawingViews, to: url, dxfVersion: dxfVersion,
                tileMode: tab.drawingViews[tab.activeViewIndex].kind == .sheet ? 0 : 1,
                psltscale: tab.drawingViews[tab.activeViewIndex].document.paperSpaceLinetypeScale)
        }
        tab.fileURL = url
        tab.displayName = url.lastPathComponent
        if ext == "dxf" { tab.dxfVersion = dxfVersion }
        tab.document.savedRevision = tab.document.editRevision  // sync save — no race
        tabs[activeIndex] = tab
    }

    // MARK: - Async Save Operations

    /// Manual save (Ctrl+S). Cancels any in-flight save for this tab and starts a new one.
    public func startSaveActiveTab() {
        guard let tab = activeTab, tab.editingBlockID == nil else { return }
        if let fileURL = tab.fileURL {
            startSave(tab: tab, to: fileURL, isAutosave: false, dxfVersion: tab.dxfVersion)
        } else {
            // No file URL — caller should open the Save As browser
        }
    }

    /// Manual save-as (Ctrl+Shift+S, file browser). Cancel-and-restart if already saving.
    public func startSaveActiveTabAs(url: URL, dxfVersion: DXFVersion = .defaultExport) {
        guard let tab = activeTab, tab.editingBlockID == nil else { return }
        startSave(tab: tab, to: url, isAutosave: false, dxfVersion: dxfVersion)
    }

    /// Autosave triggered by the timer. Does NOT update fileURL, displayName, or savedRevision.
    public func startAutosave(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[idx].editingBlockID == nil else { return }
        let tab = tabs[idx]
        guard let url = autosaveURL(for: tabID) else { return }
        startSave(tab: tab, to: url, isAutosave: true, dxfVersion: tab.dxfVersion)
    }

    /// Cancel an in-flight save for a tab.
    /// - Parameters:
    ///   - tabID: The tab whose save should be cancelled.
    ///   - reason: `.restart` replaces state immediately (no flicker); `.close` removes state entirely.
    public func cancelSave(for tabID: UUID, reason: SaveCancelReason) {
        saveTasksByTabID[tabID]?.task.cancel()
        if case .close = reason {
            saveStateByTabID.removeValue(forKey: tabID)
        }
        saveTasksByTabID.removeValue(forKey: tabID)
    }

    /// Validate saveID and mark the state as `.committing`. Returns false if saveID doesn't match.
    public func beginCommit(tabID: UUID, saveID: UUID) -> Bool {
        guard let state = saveStateByTabID[tabID], state.saveID == saveID else { return false }
        saveStateByTabID[tabID]?.status = .committing
        saveStateByTabID[tabID]?.statusText = "Finishing..."
        return true
    }

    /// Clear the save error state for the active tab (called by StatusBarUI after fade-out).
    public func clearSaveError() {
        guard let id = activeTab?.id, let state = saveStateByTabID[id],
              case .failed = state.status else { return }
        saveStateByTabID.removeValue(forKey: id)
    }

    /// Compute the autosave URL for a tab.
    public func autosaveURL(for tabID: UUID) -> URL? {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = tabs[idx]
        if let fileURL = tab.fileURL {
            return fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".autosave.eab")
        }
        // Untitled docs: save to Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let autosaveDir = appSupport.appendingPathComponent("Zephyr/Autosave")
        try? FileManager.default.createDirectory(at: autosaveDir, withIntermediateDirectories: true)
        return autosaveDir.appendingPathComponent("Untitled-\(tabID.uuidString).autosave.eab")
    }

    // MARK: - Save Implementation

    /// AutoCAD only displays DWG external references. When saving a
    /// host as DWG whose xrefs point at DXF files, warn — the
    /// references stay intact for Zephyr but will not resolve in
    /// AutoCAD until the targets are converted to DWG.
    private func warnAboutDXFXrefTargets(tab: DocumentTab, url: URL) {
        guard url.pathExtension.lowercased() == "dwg" else { return }
        var seen = Set<String>()
        var names: [String] = []
        for view in tab.drawingViews {
            for block in view.document.allBlocks {
                guard let descriptor = block.xrefDescriptor,
                      descriptor.savedPath.lowercased().hasSuffix(".dxf"),
                      seen.insert(block.name.uppercased()).inserted else { continue }
                names.append(block.name)
            }
        }
        guard !names.isEmpty else { return }
        print("[Xref] Saving as DWG: xref(s) \(names.joined(separator: ", ")) reference DXF files. AutoCAD only resolves DWG xrefs — convert the target files to DWG for AutoCAD compatibility.")
    }

    private func startSave(
        tab: DocumentTab,
        to url: URL,
        isAutosave: Bool,
        dxfVersion: DXFVersion
    ) {
        if !isAutosave { warnAboutDXFXrefTargets(tab: tab, url: url) }
        let saveID = UUID()
        cancelSave(for: tab.id, reason: .restart)
        let snapshot = tab.buildSaveSnapshot()
        let activeView = tab.drawingViews[tab.activeViewIndex]
        let backgroundColor = activeView.backgroundColor ?? getBackgroundColor?()
        let status: SaveStatus = isAutosave ? .autosaving : .saving
        let statusText = isAutosave ? "Autosaving..." : "Saving..."
        saveStateByTabID[tab.id] = SaveProgressState(
            progress: 0, statusText: statusText,
            status: status, saveID: saveID,
            isAutosave: isAutosave
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.performBackgroundSave(
                snapshot: snapshot, saveID: saveID,
                targetURL: url, isAutosave: isAutosave,
                dxfVersion: dxfVersion,
                backgroundColor: backgroundColor
            )
        }
        saveTasksByTabID[tab.id] = (task, saveID)
    }

    nonisolated private func publishSaveProgress(
        tabID: UUID,
        saveID: UUID,
        progress: Float
    ) {
        let key = PendingSaveKey(tabID: tabID, saveID: saveID)
        pendingSaveLock.withLock {
            pendingSaveProgress[key] = progress
        }
    }

    nonisolated private func publishSaveCompletion(_ completion: PendingSaveCompletion) {
        pendingSaveLock.withLock {
            pendingSaveProgress.removeValue(
                forKey: PendingSaveKey(tabID: completion.tabID, saveID: completion.saveID)
            )
            pendingSaveCompletions.append(completion)
        }
    }

    @discardableResult
    public func applyPendingSaveUpdates() -> Bool {
        let pending = pendingSaveLock.withLock { () -> (
            progress: [PendingSaveKey: Float],
            completions: [PendingSaveCompletion]
        ) in
            let result = (pendingSaveProgress, pendingSaveCompletions)
            pendingSaveProgress.removeAll(keepingCapacity: true)
            pendingSaveCompletions.removeAll(keepingCapacity: true)
            return result
        }

        var changed = false

        for (key, progress) in pending.progress {
            guard saveStateByTabID[key.tabID]?.saveID == key.saveID else { continue }
            saveStateByTabID[key.tabID]?.progress = progress
            changed = true
        }

        for completion in pending.completions {
            guard saveStateByTabID[completion.tabID]?.saveID == completion.saveID else { continue }
            if completion.success {
                _ = beginCommit(tabID: completion.tabID, saveID: completion.saveID)
            }
            finishSave(
                tabID: completion.tabID,
                saveID: completion.saveID,
                snapshot: completion.snapshot,
                targetURL: completion.targetURL,
                isAutosave: completion.isAutosave,
                dxfVersion: completion.dxfVersion,
                success: completion.success,
                errorMessage: completion.errorMessage
            )
            changed = true
        }

        return changed
    }

    nonisolated private func performBackgroundSave(
        snapshot: SaveTabSnapshot, saveID: UUID,
        targetURL: URL, isAutosave: Bool,
        dxfVersion: DXFVersion,
        backgroundColor: ColorRGBA?
    ) async {
        let ext = targetURL.pathExtension.lowercased()
        do {
            try Task.checkCancellation()

            let progressHandler: ((Float) -> Void)? = { [weak self] progress in
                self?.publishSaveProgress(
                    tabID: snapshot.tabID,
                    saveID: saveID,
                    progress: progress
                )
            }

            let snapshotTileMode: Int = {
                let i = (snapshot.activeViewIndex >= 0
                    && snapshot.activeViewIndex < snapshot.drawingViews.count)
                    ? snapshot.activeViewIndex : 0
                return snapshot.drawingViews[i].viewKind == .sheet ? 0 : 1
            }()
            let snapshotPsltscale: Int = {
                let i = (snapshot.activeViewIndex >= 0
                    && snapshot.activeViewIndex < snapshot.drawingViews.count)
                    ? snapshot.activeViewIndex : 0
                return snapshot.drawingViews[i].docSnapshot.paperSpaceLinetypeScale
            }()

            if ext == "eab" {
                try EABWriter.write(
                    snapshots: snapshot.drawingViews,
                    to: targetURL,
                    progress: progressHandler
                )
            } else if ext == "pdf" {
                let viewIndex = (snapshot.activeViewIndex >= 0 && snapshot.activeViewIndex < snapshot.drawingViews.count)
                    ? snapshot.activeViewIndex
                    : 0
                let viewSnap = snapshot.drawingViews[viewIndex]
                try PDFExporter.export(
                    snapshot: viewSnap.docSnapshot,
                    to: targetURL,
                    backgroundColor: backgroundColor,
                    progress: progressHandler
                )
            } else if ext == "dwg" {
                guard ODADWGConverter.isAvailable else {
                    throw ODADWGConvertError.converterNotFound
                }
                let tempDXF = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dwg-async-\(UUID().uuidString).dxf")
                defer { try? FileManager.default.removeItem(at: tempDXF) }

                try DXFExporter.export(
                    snapshots: snapshot.drawingViews,
                    to: tempDXF,
                    dxfVersion: dxfVersion,
                    tileMode: snapshotTileMode,
                    psltscale: snapshotPsltscale,
                    progress: progressHandler
                )
                progressHandler?(0.9)
                try await ODADWGConverter.convert(input: tempDXF, output: targetURL, toFormat: "DWG")
                progressHandler?(1.0)
            } else {
                try DXFExporter.export(
                    snapshots: snapshot.drawingViews,
                    to: targetURL,
                    dxfVersion: dxfVersion,
                    tileMode: snapshotTileMode,
                    psltscale: snapshotPsltscale,
                    progress: progressHandler
                )
            }

            try Task.checkCancellation()
            publishSaveCompletion(PendingSaveCompletion(
                tabID: snapshot.tabID,
                saveID: saveID,
                snapshot: snapshot,
                targetURL: targetURL,
                isAutosave: isAutosave,
                dxfVersion: dxfVersion,
                success: true,
                errorMessage: nil
            ))
        } catch is CancellationError {
            publishSaveCompletion(PendingSaveCompletion(
                tabID: snapshot.tabID,
                saveID: saveID,
                snapshot: snapshot,
                targetURL: targetURL,
                isAutosave: isAutosave,
                dxfVersion: dxfVersion,
                success: false,
                errorMessage: nil
            ))
        } catch {
            publishSaveCompletion(PendingSaveCompletion(
                tabID: snapshot.tabID,
                saveID: saveID,
                snapshot: snapshot,
                targetURL: targetURL,
                isAutosave: isAutosave,
                dxfVersion: dxfVersion,
                success: false,
                errorMessage: error.localizedDescription
            ))
        }
    }

    @MainActor
    private func finishSave(tabID: UUID, saveID: UUID, snapshot: SaveTabSnapshot,
                             targetURL: URL, isAutosave: Bool,
                             dxfVersion: DXFVersion, success: Bool,
                             errorMessage: String? = nil) {
        guard saveStateByTabID[tabID]?.saveID == saveID else { return }
        saveTasksByTabID.removeValue(forKey: tabID)

        if success {
            if !isAutosave {
                // Manual save: update file metadata and mark saved
                if let idx = tabs.firstIndex(where: { $0.id == tabID }) {
                    tabs[idx].fileURL = targetURL
                    tabs[idx].displayName = targetURL.lastPathComponent
                    if targetURL.pathExtension.lowercased() == "dxf" {
                        tabs[idx].dxfVersion = dxfVersion
                    }
                    for viewIndex in tabs[idx].drawingViews.indices {
                        let revision = snapshot.viewEditRevisions.indices.contains(viewIndex)
                            ? snapshot.viewEditRevisions[viewIndex]
                            : snapshot.editRevision
                        tabs[idx].drawingViews[viewIndex].document.markSaved(upTo: revision)
                        tabs[idx].drawingViews[viewIndex].document.markNeedsRegeneration()
                    }
                    // The host may have moved (SaveAs): unresolved
                    // relative xref paths get another chance.
                    XrefLoader.retryUnresolved(
                        store: tabs[idx].xrefStore,
                        documents: tabs[idx].drawingViews.map(\.document),
                        hostFolder: targetURL.deletingLastPathComponent().path)
                }
            }
            saveStateByTabID.removeValue(forKey: tabID)
        } else {
            if isAutosave {
                // Autosave failure: silent, clear state
                saveStateByTabID.removeValue(forKey: tabID)
                print("[Autosave] failed for tab \(tabID): \(errorMessage ?? "unknown")")
            } else {
                // Manual save failure: show error in status bar for ~3 seconds
                saveStateByTabID[tabID] = SaveProgressState(
                    progress: 0,
                    statusText: "Save failed: \(errorMessage ?? "unknown")",
                    status: .failed(errorMessage ?? "unknown"),
                    saveID: saveID,
                    isAutosave: false,
                    failedAt: Date()
                )
            }
        }
    }

    public enum SaveCancelReason { case restart, close }

    /// Open an EAB (Zephyr Binary) file in a new tab and switch to it.
    /// - Parameter url: The .eab file URL.
    /// - Throws: `EABError` if parsing fails.
    @discardableResult
    public func openEAB(url: URL) throws -> Int {
        let views = try EABReader.readViews(from: url)
        
        let displayName = url.lastPathComponent
        // Mark documents as clean (just loaded) and needing regeneration
        for view in views {
            view.document.savedRevision = view.document.editRevision
            view.document.needsRegeneration = true
        }
        // DocumentTab will use the first view as active, but holds all views.
        let tab = DocumentTab(
            document: views.first?.document ?? CADDocument(),
            fileURL: url,
            displayName: displayName,
            drawingViews: views
        )
        tabs.append(tab)
        kickXrefLoads(for: tab)
        let newIndex = tabs.count - 1
        switchToTab(at: newIndex)
        return newIndex
    }

    /// Mark the active tab as dirty.
    public func markActiveDirty() {
        guard let tab = activeTab else { return }
        tab.document.markEdited(regenerate: true)
    }

    // MARK: - Error Types

    public enum TabError: Error {
        case noFileURL
        case noActiveTab
        case cannotSaveWhileInBlockEditor
    }
}
