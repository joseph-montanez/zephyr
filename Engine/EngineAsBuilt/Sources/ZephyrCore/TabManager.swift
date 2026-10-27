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
                doc.groups = Dictionary(
                    uniqueKeysWithValues: imported.groups.map { ($0.name, $0) })
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
            doc.groups = Dictionary(
                uniqueKeysWithValues: imported.groups.map { ($0.name, $0) })
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
        if index == tabs[activeIndex].activeViewIndex { return true }
        if let capture = captureCameraState {
            tabs[activeIndex].cameraState = capture()
        }
        if let capture = captureSelectionState {
            tabs[activeIndex].selectionState = capture()
        }
        tabs[activeIndex].activeViewIndex = index
        applyCameraState?(tabs[activeIndex].cameraState)
        applySelectionState?(tabs[activeIndex].selectionState)
        onActiveTabChanged?()
        return true
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
    public func enterBlockEditor(blockID: UUID) {
        guard var tab = activeTab else { return }
        guard tab.editingBlockID == nil else { return }
        guard let block = tab.document.block(for: blockID) else { return }
        guard !block.isXref else {
            print("[Xref] '\(block.name)' is an external reference — open the source file to edit it, or Bind it first.")
            return
        }

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

        let tempEntities = block.geometry.enumerated().map { index, primitive in
            makeBlockEditorEntity(
                primitive: primitive,
                primitiveStyle: block.primitiveStyles[index],
                primitiveXData: block.primitiveXData[index] ?? [:],
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

        if saveChanges {
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

            try DXFExporter.export(views: tab.drawingViews, to: tempDXF, dxfVersion: dxfVersion)
            try ODADWGConverter.convertSync(input: tempDXF, output: url, toFormat: "DWG")
        } else {
            try DXFExporter.export(views: tab.drawingViews, to: url, dxfVersion: dxfVersion)
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
