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
// MARK: - DocumentTab
// =========================================================================

/// A single drawing tab — owns a `CADDocument` and associated file metadata.
public struct DrawingView {
    public var name: String
    public var kind: DXFDrawingViewKind
    public var document: CADDocument
    public var cameraState: CameraState

    public init(
        name: String,
        kind: DXFDrawingViewKind,
        document: CADDocument,
        cameraState: CameraState = .default
    ) {
        self.name = name
        self.kind = kind
        self.document = document
        self.cameraState = cameraState
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
        set { drawingViews[activeViewIndex].document = newValue }
    }
    /// The file this document was opened from / last saved to. Nil for unsaved "Untitled" docs.
    public var fileURL: URL?
    /// Display name shown in the tab bar.
    public var displayName: String
    /// Per-tab camera state (zoom, pan, rotation). Preserved across tab switches.
    public var cameraState: CameraState {
        get { drawingViews[activeViewIndex].cameraState }
        set { drawingViews[activeViewIndex].cameraState = newValue }
    }

    /// If this tab is currently in block editing mode, the ID of the block being edited.
    public var editingBlockID: UUID?
    /// The original document before entering block edit mode.
    public var parentDocument: CADDocument?

    public init(document: CADDocument = CADDocument(),
                fileURL: URL? = nil,
                displayName: String = "Untitled",
                editingBlockID: UUID? = nil,
                parentDocument: CADDocument? = nil,
                cameraState: CameraState = .default,
                drawingViews: [DrawingView]? = nil) {
        self.drawingViews = drawingViews ?? [
            DrawingView(name: "Model", kind: .model, document: document, cameraState: cameraState)
        ]
        self.fileURL = fileURL
        self.displayName = displayName
        self.editingBlockID = editingBlockID
        self.parentDocument = parentDocument
    }
}

// =========================================================================
// MARK: - TabManager
// =========================================================================

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

    /// Callback invoked to get the viewport's background color for exports.
    public var getBackgroundColor: (() -> ColorRGBA)? = nil

    /// Callback that captures the engine's current camera state.
    /// Used by `switchToTab` to save camera state to the departing tab.
    public var captureCameraState: (() -> CameraState)?
    /// Callback that applies a camera state to the engine.
    /// Used by `switchToTab` to restore camera state from the incoming tab.
    public var applyCameraState: ((CameraState) -> Void)?

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

    public var availableViews: [(name: String, kind: DXFDrawingViewKind)] {
        guard let tab = activeTab else { return [] }
        return tab.drawingViews.map { ($0.name, $0.kind) }
    }

    /// Whether the active tab has unsaved changes.
    public var activeIsDirty: Bool {
        guard let tab = activeTab else { return false }
        return tab.document.isDirty
    }

    // MARK: - Tab Lifecycle

    /// Create a new blank (untitled) tab and switch to it.
    /// - Returns: The index of the newly created tab.
    @discardableResult
    public func newTab() -> Int {
        let doc = CADDocument()
        // Bulk-import a single "0" layer (single undo snapshot, not per-layer)
        doc.importLayersBlocksEntities(
            layers: [Layer(name: "0", color: .white)],
            blocks: [],
            entities: []
        )
        doc.isDirty = false  // blank docs aren't dirty until modified

        let tab = DocumentTab(document: doc, fileURL: nil, displayName: "Untitled")
        tabs.append(tab)
        let idx = tabs.count - 1
        switchToTab(at: idx)
        return idx
    }

    /// Open a DXF or EAB file in a new tab (auto-detects format from extension).
    /// - Parameter url: The file URL to import.
    /// - Throws: `DXFImportError` or `EABError` if parsing fails.
    @discardableResult
    public func openTab(url: URL) throws -> Int {
        if url.pathExtension.lowercased() == "eab" {
            return try openEAB(url: url)
        }
        let imported = try DXFImporter.importDXFViews(filePath: url.path)

        for font in Set(imported.textStyleFonts.values) {
            CADFontManager.debugFontLookup(font)
        }

        let drawingViews = imported.views.map { view -> DrawingView in
            let doc = CADDocument()
            doc.importLayersBlocksEntities(
                layers: imported.layers,
                blocks: imported.blocks,
                entities: view.entities
            )
            doc.textStyleFonts = imported.textStyleFonts
            doc.linetypePatterns = imported.linetypePatterns
            doc.isDirty = false
            return DrawingView(name: view.name, kind: view.kind, document: doc)
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
        let idx = tabs.count - 1
        switchToTab(at: idx)
        return idx
    }

    /// Close the tab at the given index.
    /// - Returns: True if the tab was closed.
    @discardableResult
    public func closeTab(at index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        guard tabs.count > 1 else {
            // Don't close the last tab — clear it instead
            return false
        }

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
            onActiveTabChanged?()
        } else if index < activeIndex {
            activeIndex -= 1
        }

        onTabClosed?(index)
        return true
    }

    /// Close the active tab.
    @discardableResult
    public func closeActiveTab() -> Bool {
        closeTab(at: activeIndex)
    }

    /// Switch to the tab at the given index.
    /// Saves the engine's current camera state to the departing tab, then restores
    /// the incoming tab's camera state before firing `onActiveTabChanged`.
    public func switchToTab(at index: Int) {
        guard index >= 0, index < tabs.count, index != activeIndex else { return }
        // Save camera state to departing tab
        if let capture = captureCameraState, activeIndex < tabs.count {
            tabs[activeIndex].cameraState = capture()
        }
        activeIndex = index
        // Restore camera state from incoming tab
        if let apply = applyCameraState {
            apply(tabs[activeIndex].cameraState)
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
        tabs[activeIndex].activeViewIndex = index
        applyCameraState?(tabs[activeIndex].cameraState)
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

    // MARK: - Block Editor Operations

    /// Enters block editor mode for the given block ID.
    public func enterBlockEditor(blockID: UUID) {
        guard var tab = activeTab else { return }
        guard tab.editingBlockID == nil else { return } // Already editing a block
        guard let block = tab.document.block(for: blockID) else { return }

        // Create a temporary document for the block's content
        let tempDoc = CADDocument()

        // Ensure active layer is the same
        tempDoc.activeLayerID = tab.document.activeLayerID

        // Convert the block's primitives into entities in the temporary document
        var tempEntities: [CADEntity] = []
        let layerID = tempDoc.activeLayerID ?? tab.document.layersView.first?.handle ?? UUID()
        if block.geometry.count > 1000 {
            let entity = CADEntity(
                handle: UUID(),
                layerID: layerID,
                blockID: nil,
                localGeometry: block.geometry,
                transform: .identity
            )
            tempEntities.append(entity)
        } else {
            for prim in block.geometry {
                let entity = CADEntity(
                    handle: UUID(),
                    layerID: layerID,
                    blockID: nil,
                    localGeometry: [prim],
                    transform: .identity
                )
                tempEntities.append(entity)
            }
        }
        
        // Copy layers, blocks, and the converted block entities in one bulk call
        tempDoc.importLayersBlocksEntities(
            layers: tab.document.allLayers,
            blocks: tab.document.allBlocks,
            entities: tempEntities
        )

        tempDoc.isDirty = false
        
        tab.parentDocument = tab.document
        tab.document = tempDoc
        tab.editingBlockID = blockID
        tabs[activeIndex] = tab

        onActiveTabChanged?() // Forces a refresh of the scene
    }

    /// Exits block editor mode.
    public func exitBlockEditor(saveChanges: Bool) {
        guard var tab = activeTab else { return }
        guard let blockID = tab.editingBlockID, let parentDoc = tab.parentDocument else { return }

        if saveChanges {
            var newPrimitives: [CADPrimitive] = []
            // Collect all primitives from the temp document
            for entity in tab.document.entitiesView {
                if let geom = entity.resolvedGeometry(in: tab.document) {
                    // Apply the entity's transform to its primitives
                    let t = entity.transform
                    if t == .identity {
                        newPrimitives.append(contentsOf: geom)
                    } else {
                        let transformed = CADGeometryMath.transformPrimitives(geom, by: t)
                        newPrimitives.append(contentsOf: transformed)
                    }
                }
            }
            parentDoc.pushUndo()
            parentDoc.updateBlockGeometryLive(handle: blockID, geometry: newPrimitives)
            parentDoc.invalidateEntityGrid()
        }

        tab.document = parentDoc
        tab.parentDocument = nil
        tab.editingBlockID = nil
        tabs[activeIndex] = tab

        onActiveTabChanged?() // Forces a refresh of the scene
    }


    // MARK: - Save Operations

    /// Save the active tab to its associated file. If the tab has no file URL,
    /// this is a no-op — the caller should use `saveActiveTabAs(url:)` instead.
    /// - Throws: `DXFExportError` if writing fails.
    public func saveActiveTab() throws {
        guard let tab = activeTab else { throw TabError.noActiveTab }
        if tab.editingBlockID != nil {
            throw TabError.cannotSaveWhileInBlockEditor
        }
        guard let fileURL = tab.fileURL else {
            throw TabError.noFileURL
        }
        try saveActiveTabAs(url: fileURL)
    }

    /// Save the active tab to a new file URL.
    /// Auto-detects format from file extension (.eab → binary, .dxf → DXF).
    /// Updates the tab's fileURL and displayName on success.
    /// - Throws: `DXFExportError` or `EABError` if writing fails.
    public func saveActiveTabAs(url: URL) throws {
        guard var tab = activeTab else { throw TabError.noActiveTab }
        if tab.editingBlockID != nil {
            throw TabError.cannotSaveWhileInBlockEditor
        }
        if url.pathExtension.lowercased() == "eab" {
            try EABWriter.write(views: tab.drawingViews, to: url)
        } else if url.pathExtension.lowercased() == "pdf" {
            let bg = getBackgroundColor?()
            try PDFExporter.export(document: tab.document, to: url, backgroundColor: bg)
        } else {
            try DXFExporter.export(document: tab.document, to: url)
        }
        tab.fileURL = url
        tab.displayName = url.lastPathComponent
        tab.document.isDirty = false
        tabs[activeIndex] = tab
    }

    /// Open an EAB (Zephyr Binary) file in a new tab and switch to it.
    /// - Parameter url: The .eab file URL.
    /// - Throws: `EABError` if parsing fails.
    @discardableResult
    public func openEAB(url: URL) throws -> Int {
        let views = try EABReader.readViews(from: url)
        
        let displayName = url.lastPathComponent
        // DocumentTab will use the first view as active, but holds all views.
        let tab = DocumentTab(
            document: views.first?.document ?? CADDocument(),
            fileURL: url,
            displayName: displayName,
            drawingViews: views
        )
        tabs.append(tab)
        let newIndex = tabs.count - 1
        switchToTab(at: newIndex)
        return newIndex
    }

    /// Mark the active tab as dirty.
    public func markActiveDirty() {
        guard let tab = activeTab else { return }
        tab.document.isDirty = true
    }

    // MARK: - Error Types

    public enum TabError: Error {
        case noFileURL
        case noActiveTab
        case cannotSaveWhileInBlockEditor
    }
}
