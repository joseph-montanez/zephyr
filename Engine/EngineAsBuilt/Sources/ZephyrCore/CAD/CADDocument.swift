import Foundation

// =========================================================================
// MARK: - CADDocument
//
// The core CAD document model. Owns all layers, blocks, entities,
// constraints, and undo history for a single drawing.
//
// Supports:
//   - Layer management (add, remove, rename, reorder)
//   - Block definitions with geometry storage
//   - Entity CRUD with transform tracking
//   - Undo/Redo via snapshot-based history
//   - Snapshot capture for async regeneration
//   - Coordination with the dedicated entity spatial index
//   - Entity-level XData (extended data) overrides
//   - Collapsed text-spacing tracking (MText justification)

// =========================================================================
// MARK: - CADDocumentSnapshot
// =========================================================================

/// A Sendable, value-type snapshot of the full document state.
public struct CADDocumentSnapshot: Sendable {
    public let layers: [UUID: Layer]
    public let blocks: [UUID: CADBlock]
    public let entities: [UUID: CADEntity]
    public let constraints: [UUID: CADConstraint]
    public let solvedTransforms: [UUID: Transform3D]
    public let activeLayerID: UUID?
    public let unit: CADUnit
    public let textStyles: [String: CADTextStyle]
    public var textStyleFonts: [String: String] {
        Dictionary(textStyles.values.map { ($0.name, $0.fontFile) }, uniquingKeysWith: { first, _ in first })
    }
    public let dimensionStyles: [String: CADDimensionStyle]
    public let leaderStyles: [String: CADLeaderStyle]
    public let currentLeaderStyleName: String
    public let linetypePatterns: [String: [Double]]
    public let globalLineTypeScale: Double
    public let autoContrastTrueColor: Bool
    public let dxfRoundTripPayload: DXFRoundTripPayload?
    /// Names of image assets currently referenced by entities (not the raw Data blobs).
    /// The actual `imageStore` lives on `CADDocument` and persists across undo/redo.
    public let imageAssetNames: Set<String>
    /// Xref fade percent at snapshot time (render-only).
    public let xrefFadePercent: Int
    /// Referenced media definitions (ATTACH).
    public let imageDefinitions: [String: CADImageDefinition]
    public let pdfDefinitions: [String: CADPdfDefinition]
    /// Image asset names with pixels actually available at snapshot
    /// time (embedded store ∪ loaded media references). Names not in
    /// this set render as placeholder frames.
    public let availableImageAssetNames: Set<String>
    public let layoutSettings: CADLayoutSettings?

    public init(
        layers: [UUID: Layer],
        blocks: [UUID: CADBlock],
        entities: [UUID: CADEntity],
        constraints: [UUID: CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        activeLayerID: UUID?,
        unit: CADUnit,
        textStyles: [String: CADTextStyle],
        dimensionStyles: [String: CADDimensionStyle] = [:],
        leaderStyles: [String: CADLeaderStyle] = ["Standard": .standard],
        currentLeaderStyleName: String = "Standard",
        linetypePatterns: [String: [Double]] = [:],
        globalLineTypeScale: Double = 1.0,
        autoContrastTrueColor: Bool = true,
        dxfRoundTripPayload: DXFRoundTripPayload? = nil,
        imageAssetNames: Set<String> = [],
        xrefFadePercent: Int = 50,
        imageDefinitions: [String: CADImageDefinition] = [:],
        pdfDefinitions: [String: CADPdfDefinition] = [:],
        availableImageAssetNames: Set<String> = [],
        layoutSettings: CADLayoutSettings? = nil
    ) {
        self.layoutSettings = layoutSettings
        self.xrefFadePercent = xrefFadePercent
        self.imageDefinitions = imageDefinitions
        self.pdfDefinitions = pdfDefinitions
        self.availableImageAssetNames = availableImageAssetNames
        self.layers = layers
        self.blocks = blocks
        self.entities = entities
        self.constraints = constraints
        self.solvedTransforms = solvedTransforms
        self.activeLayerID = activeLayerID
        self.unit = unit
        self.textStyles = textStyles
        self.dimensionStyles = dimensionStyles
        self.leaderStyles = leaderStyles.isEmpty ? ["Standard": .standard] : leaderStyles
        self.currentLeaderStyleName = currentLeaderStyleName
        self.linetypePatterns = linetypePatterns
        self.globalLineTypeScale = globalLineTypeScale
        self.autoContrastTrueColor = autoContrastTrueColor
        self.dxfRoundTripPayload = dxfRoundTripPayload
        self.imageAssetNames = imageAssetNames
    }

    public init(
        layers: [UUID: Layer],
        blocks: [UUID: CADBlock],
        entities: [UUID: CADEntity],
        constraints: [UUID: CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        activeLayerID: UUID?,
        unit: CADUnit,
        textStyleFonts: [String: String],
        dimensionStyles: [String: CADDimensionStyle] = [:],
        leaderStyles: [String: CADLeaderStyle] = ["Standard": .standard],
        currentLeaderStyleName: String = "Standard",
        linetypePatterns: [String: [Double]] = [:],
        globalLineTypeScale: Double = 1.0,
        autoContrastTrueColor: Bool = true,
        dxfRoundTripPayload: DXFRoundTripPayload? = nil,
        imageAssetNames: Set<String> = [],
        layoutSettings: CADLayoutSettings? = nil
    ) {
        let styles = Dictionary(uniqueKeysWithValues: textStyleFonts.map { name, font in
            (name, CADTextStyle(name: name, fontFile: font).normalized)
        })
        self.init(
            layers: layers,
            blocks: blocks,
            entities: entities,
            constraints: constraints,
            solvedTransforms: solvedTransforms,
            activeLayerID: activeLayerID,
            unit: unit,
            textStyles: styles.isEmpty ? ["Standard": .standard] : styles,
            dimensionStyles: dimensionStyles,
            leaderStyles: leaderStyles,
            currentLeaderStyleName: currentLeaderStyleName,
            linetypePatterns: linetypePatterns,
            globalLineTypeScale: globalLineTypeScale,
            autoContrastTrueColor: autoContrastTrueColor,
            dxfRoundTripPayload: dxfRoundTripPayload,
            imageAssetNames: imageAssetNames,
            layoutSettings: layoutSettings)
    }
}

// =========================================================================
// MARK: - CADLayoutSettings
// =========================================================================

public struct CADLayoutSettings: Sendable, Equatable {
    public var paperName: String?
    public var paperWidthMM: Double
    public var paperHeightMM: Double
    public var marginLM: Double
    public var marginBM: Double
    public var marginRM: Double
    public var marginTM: Double
    public var plotPaperUnits: Int // 0 = inches, 1 = mm, 2 = pixels
    public var plotRotation: Int

    public init(
        paperName: String? = nil,
        paperWidthMM: Double,
        paperHeightMM: Double,
        marginLM: Double = 0,
        marginBM: Double = 0,
        marginRM: Double = 0,
        marginTM: Double = 0,
        plotPaperUnits: Int = 0,
        plotRotation: Int = 0
    ) {
        self.paperName = paperName
        self.paperWidthMM = paperWidthMM
        self.paperHeightMM = paperHeightMM
        self.marginLM = marginLM
        self.marginBM = marginBM
        self.marginRM = marginRM
        self.marginTM = marginTM
        self.plotPaperUnits = plotPaperUnits
        self.plotRotation = plotRotation
    }
}

// =========================================================================
// MARK: - SaveDocumentSnapshot
// =========================================================================

/// A Sendable snapshot of a single drawing view for background save.
/// Includes the CADDocumentSnapshot plus referenced image assets (raw Data).
public struct SaveDocumentSnapshot: Sendable {
    public let viewName: String
    public let viewKind: DXFDrawingViewKind
    public let cameraState: CameraState
    public let docSnapshot: CADDocumentSnapshot
    public let imageAssets: [String: CADImageAsset]
    /// Folder of the document's file at snapshot time (xref resolution
    /// fallback stored in EAB; nil for never-saved documents).
    public let sourceFolderPath: String?
    /// Xref blocks unloaded at snapshot time (EAB persistence).
    public let unloadedXrefHandles: Set<UUID>

    public init(viewName: String, viewKind: DXFDrawingViewKind,
                cameraState: CameraState, docSnapshot: CADDocumentSnapshot,
                imageAssets: [String: CADImageAsset],
                sourceFolderPath: String? = nil,
                unloadedXrefHandles: Set<UUID> = []) {
        self.viewName = viewName
        self.viewKind = viewKind
        self.cameraState = cameraState
        self.docSnapshot = docSnapshot
        self.imageAssets = imageAssets
        self.sourceFolderPath = sourceFolderPath
        self.unloadedXrefHandles = unloadedXrefHandles
    }
}

/// A Sendable snapshot of an entire tab for background save.
/// Captured synchronously on MainActor, then passed to a detached task.
public struct SaveTabSnapshot: Sendable {
    public let tabID: UUID
    public let drawingViews: [SaveDocumentSnapshot]
    public let fileURL: URL?
    public let displayName: String
    /// The active view's editRevision at the moment the snapshot was taken.
    /// Kept for compatibility with single-view callers.
    public let editRevision: UInt64
    /// Each drawing view's editRevision at the moment the snapshot was taken.
    /// Used to avoid clearing edits made while a background save is in flight.
    public let viewEditRevisions: [UInt64]
    /// File format version for the exporter to embed in output.
    public let formatVersion: UInt32
    /// Application version string.
    public let appVersion: String
    public let activeViewIndex: Int

    public init(tabID: UUID, drawingViews: [SaveDocumentSnapshot], fileURL: URL?,
                displayName: String, editRevision: UInt64,
                viewEditRevisions: [UInt64] = [],
                formatVersion: UInt32, appVersion: String,
                activeViewIndex: Int = 0) {
        self.tabID = tabID
        self.drawingViews = drawingViews
        self.fileURL = fileURL
        self.displayName = displayName
        self.editRevision = editRevision
        self.viewEditRevisions = viewEditRevisions
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.activeViewIndex = activeViewIndex
    }
}

// =========================================================================
// MARK: - UndoManager
// =========================================================================

public final class UndoManager {
    private var undoStack: [CADDocumentSnapshot] = []
    private var redoStack: [CADDocumentSnapshot] = []

    // UNDO Begin/End group state (see LispUndoGroups.swift). Depth > 0
    // means pushes coalesce; the pending snapshot is the pre-group state.
    var _undoGroupDepth: Int = 0
    var _pendingGroupSnapshot: CADDocumentSnapshot?

    /// Serializes all stack/group state. Recursive: group methods nest
    /// (end → push, backTo → end/pop). Needed because Lisp evaluation
    /// runs off the main thread while the UI reads depth and the user
    /// can undo concurrently.
    let undoLock = NSRecursiveLock()

    public var maxDepth: Int = 256

    public init() {}

    public func pushUndo(_ snapshot: CADDocumentSnapshot) {
        undoLock.withLock {
            undoStack.append(snapshot)
            if maxDepth > 0, undoStack.count > maxDepth {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
        }
    }

    public func popUndo(currentSnapshot: CADDocumentSnapshot) -> CADDocumentSnapshot? {
        undoLock.withLock {
            guard !undoStack.isEmpty else { return nil }
            redoStack.append(currentSnapshot)
            return undoStack.removeLast()
        }
    }

    public func popRedo(currentSnapshot: CADDocumentSnapshot) -> CADDocumentSnapshot? {
        undoLock.withLock {
            guard !redoStack.isEmpty else { return nil }
            undoStack.append(currentSnapshot)
            return redoStack.removeLast()
        }
    }

    public var canUndo: Bool { undoLock.withLock { !undoStack.isEmpty } }
    public var canRedo: Bool { undoLock.withLock { !redoStack.isEmpty } }

    public var undoDepth: Int { undoLock.withLock { undoStack.count } }
    public var redoDepth: Int { undoLock.withLock { redoStack.count } }
}

// =========================================================================
// MARK: - CADDocument
// =========================================================================

private struct CADRenderBoundsAccumulator {
    var minX = Double.infinity
    var minY = Double.infinity
    var minZ = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    var maxZ = -Double.infinity
    var hasPoints = false

    mutating func include(_ point: Vector3) {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
        hasPoints = true
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        minZ = min(minZ, point.z)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
        maxZ = max(maxZ, point.z)
    }

    mutating func include(contentsOf points: [Vector3]) {
        for point in points { include(point) }
    }

    var boundingBox: BoundingBox3D? {
        guard hasPoints else { return nil }
        return BoundingBox3D(
            min: Vector3(x: minX, y: minY, z: minZ),
            max: Vector3(x: maxX, y: maxY, z: maxZ))
    }
}

public final class CADDocument {
    /// Recursive lock to serialize document mutations and snapshot/render reads
    /// across background evaluation tasks and the main render loop.
    public let documentLock = NSRecursiveLock()

    // MARK: Tables

    private var layerTable: [UUID: Layer] = [:]
    private var blockTable: [UUID: CADBlock] = [:]
    private var entityRegistry: [UUID: CADEntity] = [:]
    private var constraintTable: [UUID: CADConstraint] = [:]

    public var activeLayerID: UUID?

    /// Drawing base unit. Saved/loaded in EAB; used by DXF exporter for $INSUNITS.
    public var unit: CADUnit = .millimeter

    /// Solved transforms from the constraint solver (nil = not yet solved).
    /// Keyed by entity handle. These are world-space transforms produced by the solver.
    public var solvedTransforms: [UUID: Transform3D] = [:]

    /// Text styles keyed by their drawing-visible names.
    public var textStyles: [String: CADTextStyle] = ["Standard": .standard]

    /// Compatibility bridge for existing font-resolution and export code.
    public var textStyleFonts: [String: String] {
        get {
            Dictionary(textStyles.values.map { ($0.name, $0.fontFile) }, uniquingKeysWith: { first, _ in first })
        }
        set {
            var rebuilt: [String: CADTextStyle] = [:]
            for (name, font) in newValue {
                let existing = textStyle(named: name)
                var style = existing ?? CADTextStyle(name: name)
                style.name = name
                style.fontFile = font
                let normalized = style.normalized
                if !normalized.name.isEmpty { rebuilt[normalized.name] = normalized }
            }
            if rebuilt.keys.contains(where: { $0.caseInsensitiveCompare("Standard") == .orderedSame }) == false {
                rebuilt["Standard"] = .standard
            }
            textStyles = rebuilt
        }
    }
    
    /// Map of dimension style name -> CADDimensionStyle
    public var dimensionStyles: [String: CADDimensionStyle] = [:]

    /// Referenced image definitions (DXF IMAGEDEF), keyed by name.
    /// Document data: part of undo snapshots and saves; decoded
    /// pixels live in the per-tab MediaReferenceStore.
    public var imageDefinitions: [String: CADImageDefinition] = [:]

    /// Referenced PDF-page definitions (DXF PDFDEFINITION), keyed by name.
    public var pdfDefinitions: [String: CADPdfDefinition] = [:]

    /// Named multileader styles and the active style used by new leaders.
    public var leaderStyles: [String: CADLeaderStyle] = ["Standard": .standard]
    public var currentLeaderStyleName: String = "Standard"

    /// DXF linetype dash pattern definitions (e.g. "DASHED" -> [10.0, 5.0]).
    /// Key is the uppercased linetype name. Saved/loaded in EAB for accurate round-trip.
    public var linetypePatterns: [String: [Double]] = [:]

    /// Global linetype scale factor (AutoCAD LTSCALE sysvar). Multiplies all entity linetype scales.
    public var globalLineTypeScale: Double = 1.0 {
        didSet { markNeedsRegeneration() }
    }

    /// When true (default), true colors (gradients, explicit 24-bit RGB values) are adjusted
    /// by the viewport auto-contrast guard just like ACI colors.
    /// When false, true colors render in their exact RGB values without auto-contrast clamp,
    /// while AutoCAD Color Index (ACI) colors retain auto-contrast.
    public var autoContrastTrueColor: Bool = true {
        didSet { markNeedsRegeneration() }
    }

    /// Raw DXF classes/objects retained for lossless round-trip of native entities.
    public var dxfRoundTripPayload: DXFRoundTripPayload?
    public var layoutSettings: CADLayoutSettings? = nil

    /// Folder of the file this document was loaded from, as recorded in
    /// the EAB xrefs section — a resolution fallback for relative xref
    /// paths when the live file location is unknown (autosave recovery).
    public var xrefSourceFolder: String?

    /// Xref block handles that were unloaded when the EAB file was
    /// written; consumed by the runtime store on document open.
    public var eabUnloadedXrefHandles: Set<UUID> = []

    /// Per-tab xref runtime store (load status + shadow geometry),
    /// assigned by TabManager so all view documents in a tab share one.
    /// Never snapshotted.
    public var xrefRuntimeStore: XrefRuntimeStore?

    /// Per-tab referenced-media runtime state (set by TabManager).
    public var mediaRuntimeStore: MediaReferenceStore?

    /// Embedded assets plus loaded referenced-media assets — what the
    /// renderer may draw. Runtime assets never enter `imageStore`,
    /// so saves and undo stay free of referenced pixels.
    public var effectiveImageStore: [String: CADImageAsset] {
        guard let mediaRuntimeStore else { return imageStore }
        let loaded = mediaRuntimeStore.loadedAssets()
        guard !loaded.isEmpty else { return imageStore }
        return imageStore.merging(loaded) { _, runtime in runtime }
    }

    /// Xref display fade percent (XDWGFADECTL): 0 = off, 90 = max.
    /// Display only; carried into render snapshots.
    public var xrefFadePercent: Int = 50 {
        didSet { xrefFadePercent = max(0, min(90, xrefFadePercent)) }
    }

    /// Display precision for inquiry output (LUPREC/AUPREC sysvars, live
    /// through LispVarStore like LTSCALE). Session state, not snapshotted:
    /// precision changes are never undoable, matching AutoCAD.
    public var lengthPrecision: Int = 4 {
        didSet { lengthPrecision = max(0, min(8, lengthPrecision)) }
    }
    public var anglePrecision: Int = 0 {
        didSet { anglePrecision = max(0, min(8, anglePrecision)) }
    }

    /// Last inquiry results (AREA/PERIMETER/LASTPOINT sysvars, live reads).
    /// Written by DIST/AREA/ID; session state, not snapshotted.
    public var lastArea: Double = 0
    public var lastPerimeter: Double = 0
    public var lastPoint: Vector3?

    /// Bumped whenever rendering must refresh, including non-dirty
    /// changes (xref load/unload/reload, fade). Secondary render
    /// contexts (floated windows, split panes) compare against this —
    /// `editRevision` alone misses non-edit invalidation.
    public private(set) var renderRevision: UInt64 = 0

    /// Image asset store keyed by sha256 hex name. Multiple entities can reference
    /// the same asset. Persists across undo/redo boundaries (snapshots only store
    /// `imageAssetNames: Set<String>`, not the raw data blobs).
    public var imageStore: [String: CADImageAsset] = [:]

    /// Add or overwrite an image asset. No-op if the asset already exists.
    /// Returns the asset name (sha256) for use in primitives.
    @discardableResult
    public func addImageAsset(_ asset: CADImageAsset) -> String {
        if imageStore[asset.name] == nil {
            imageStore[asset.name] = asset
        }
        return asset.name
    }

    /// Prune image assets that are no longer referenced by any entity.
    /// Called after restore(from:) to clean up GC'd references.
    public func pruneUnreferencedImageAssets() {
        guard !imageStore.isEmpty else { return }
        var referenced = Set<String>()
        for entity in entityRegistry.values {
            if let geom = entity.localGeometry {
                for prim in geom {
                    if case .image(_, _, _, let name, _, _) = prim {
                        referenced.insert(name)
                    }
                }
            }
            // Also check block definitions that reference images
            if let bid = entity.blockID, let block = blockTable[bid] {
                for prim in block.geometry {
                    if case .image(_, _, _, let name, _, _) = prim {
                        referenced.insert(name)
                    }
                }
            }
        }
        // Check all block definitions even if not referenced by entities
        for block in blockTable.values {
            for prim in block.geometry {
                if case .image(_, _, _, let name, _, _) = prim {
                    referenced.insert(name)
                }
            }
        }
        imageStore = imageStore.filter { referenced.contains($0.key) }
    }

    // MARK: Entity Spatial Index

    /// Derived broad-phase cache used by hit testing and ray casting.
    ///
    /// The document remains responsible for deciding when geometry changes
    /// invalidate the cache; `CADEntitySpatialIndex` owns the grid mechanics.
    private let entitySpatialIndex = CADEntitySpatialIndex()

    /// Whether the broad-phase entity index currently represents this document.
    public var entityGridBuilt: Bool { entitySpatialIndex.isBuilt }

    /// Invalidate the entity spatial grid. Call after any entity transform mutation,
    /// undo/redo, or bulk import. The grid will be rebuilt on the next hit-test demand.
    ///
    /// IMPORTANT: this is deliberately decoupled from `isDirty`. Marking the document dirty
    /// for a non-geometric reason (xdata, layer assignment, visibility) must NOT throw away
    /// the grid — otherwise the next hover pays for a full 153k rebuild + full scan.
    public func invalidateEntityGrid() {
        entitySpatialIndex.invalidate()
    }

    /// Rebuild the entity spatial grid from current entity world bounding boxes.
    /// Uses the same cell-size heuristic as GeometryManager.
    public func rebuildEntityGrid() {
        entitySpatialIndex.rebuild(from: entityRegistry.values)
    }

    /// Returns entity handles potentially visible in the given world-space AABB.
    /// Uses the spatial grid if built; returns nil to signal caller to fall back to full scan.
    public func entityHandlesInWorldRect(
        minX: Double, minY: Double,
        maxX: Double, maxY: Double
    ) -> [UUID]? {
        entitySpatialIndex.handles(
            inWorldRectMinX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY)
    }

    /// Returns entity handles along a ray using DDA grid traversal (broad-phase for raycasting).
    /// Walks the uniform spatial grid along the ray direction, collecting unique handles from
    /// every cell the ray passes through up to `maxDistance` world units.
    /// - Parameters:
    ///   - rayOrigin: World-space starting point.
    ///   - rayDir: Direction vector (normalized internally, safe to pass unnormalized).
    ///   - maxDistance: Maximum traversal distance in world units.
    /// - Returns: Deduplicated list of candidate entity handles, or nil if the grid is not built.
    ///   Callers should fall back to a full scan when nil is returned.
    public func entityHandlesAlongRay(
        rayOrigin: Vector3, rayDir: Vector3, maxDistance: Double = 100_000
    ) -> [UUID]? {
        if !entityGridBuilt {
            if entityRegistry.count > 1 {
                rebuildEntityGrid()
            }
            guard entityGridBuilt else { return nil }
        }
        return entitySpatialIndex.handles(
            alongRayFrom: rayOrigin,
            direction: rayDir,
            maxDistance: maxDistance)
    }

    // MARK: Undo

    public let undoManager = UndoManager()

    // MARK: - Revision Tracking (replaces `isDirty`)

    /// Monotonically incremented on every state mutation that should be persisted.
    public internal(set) var editRevision: UInt64 = 0
    /// Set to `editRevision` on successful manual save.
    public internal(set) var savedRevision: UInt64 = 0
    /// True when geometry/visual state needs regeneration.
    public internal(set) var needsRegeneration: Bool = false

    /// True when the document has unsaved changes (tab asterisk, autosave trigger).
    public var hasUnsavedChanges: Bool { editRevision != savedRevision }

    /// Call whenever the document changes in a way that should be persisted.
    /// - Parameter regenerate: If true (default), also marks the document for regeneration.
    public func markEdited(regenerate: Bool = true) {
        editRevision &+= 1
        renderRevision &+= 1
        if regenerate { needsRegeneration = true }
    }

    /// Call for render/cache-only invalidation (palette change, theme toggle).
    public func markNeedsRegeneration() {
        renderRevision &+= 1
        needsRegeneration = true
    }

    /// Call on successful manual save, passing the revision captured in the save snapshot.
    /// - Parameter revision: The `editRevision` value from the snapshot, NOT the live value.
    public func markSaved(upTo revision: UInt64) {
        savedRevision = revision
    }

    public init() {
        textStyles = ["Standard": .standard]
    }

    // MARK: - Text Style Operations

    // MARK: - Referenced media definitions (ATTACH)

    public func imageDefinition(named name: String) -> CADImageDefinition? {
        if let exact = imageDefinitions[name] { return exact }
        return imageDefinitions.values.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    public func pdfDefinition(named name: String) -> CADPdfDefinition? {
        if let exact = pdfDefinitions[name] { return exact }
        return pdfDefinitions.values.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// True when `name` is a referenced-media definition (image or PDF),
    /// as opposed to an embedded image asset in `imageStore`.
    public func isMediaReferenceName(_ name: String) -> Bool {
        imageDefinition(named: name) != nil || pdfDefinition(named: name) != nil
    }

    public func importMediaDefinitions(
        image: [CADImageDefinition], pdf: [CADPdfDefinition]
    ) {
        for def in image where !def.name.isEmpty { imageDefinitions[def.name] = def }
        for def in pdf where !def.name.isEmpty { pdfDefinitions[def.name] = def }
    }

    /// Count entities (model space, incl. block contents one level) whose
    /// image primitives reference `name`.
    public func mediaInstanceCount(forName name: String) -> Int {
        var count = 0
        func scan(_ geometry: [CADPrimitive]?) {
            guard let geometry else { return }
            for prim in geometry where prim.imageReferenceName == name { count += 1 }
        }
        for entity in allEntities { scan(entity.localGeometry) }
        return count
    }

    public func textStyle(named name: String?) -> CADTextStyle? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = textStyles[trimmed] { return exact }
        return textStyles.values.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public func resolvedTextStyleName(_ name: String?) -> String {
        if let style = textStyle(named: name) { return style.name }
        return textStyle(named: "Standard")?.name ?? "Standard"
    }

    public func effectiveTextHeight(styleName: String?, localHeight: Double) -> Double {
        let style = textStyle(named: styleName) ?? textStyle(named: "Standard") ?? .standard
        return style.fixedHeight > 0 ? style.fixedHeight : localHeight
    }

    public func applyTextStyle(_ style: CADTextStyle, replacing oldName: String? = nil) -> Bool {
        let normalized = style.normalized
        guard !normalized.name.isEmpty else { return false }
        if let oldName,
           oldName.caseInsensitiveCompare("Standard") == .orderedSame,
           normalized.name.caseInsensitiveCompare("Standard") != .orderedSame {
            return false
        }
        if textStyles.values.contains(where: {
            $0.name.caseInsensitiveCompare(normalized.name) == .orderedSame
                && $0.name.caseInsensitiveCompare(oldName ?? normalized.name) != .orderedSame
        }) {
            return false
        }

        let previousName = oldName.flatMap { textStyle(named: $0)?.name }
        pushUndo()
        if let previousName, previousName.caseInsensitiveCompare(normalized.name) != .orderedSame {
            textStyles.removeValue(forKey: previousName)
            rewriteTextStyleReferences(from: previousName, to: normalized.name)
        }
        textStyles[normalized.name] = normalized
        markEdited(regenerate: true)
        invalidateEntityGrid()
        return true
    }

    public func deleteTextStyle(named name: String) -> Bool {
        guard let existing = textStyle(named: name),
              existing.name.caseInsensitiveCompare("Standard") != .orderedSame else { return false }
        pushUndo()
        textStyles.removeValue(forKey: existing.name)
        rewriteTextStyleReferences(from: existing.name, to: resolvedTextStyleName("Standard"))
        markEdited(regenerate: true)
        invalidateEntityGrid()
        return true
    }

    private func rewriteTextStyleReferences(from oldName: String, to newName: String) {
        for handle in Array(entityRegistry.keys) {
            guard var entity = entityRegistry[handle] else { continue }
            if case .string(let value) = entity.xdata["dxf.textStyle"],
               value.caseInsensitiveCompare(oldName) == .orderedSame {
                entity.xdata["dxf.textStyle"] = .string(newName)
            }
            if let geometry = entity.localGeometry {
                entity.localGeometry = geometry.map { replacingTextStyle(in: $0, from: oldName, to: newName) }
            }
            entityRegistry[handle] = entity
        }
        for handle in Array(blockTable.keys) {
            guard var block = blockTable[handle] else { continue }
            block.geometry = block.geometry.map { replacingTextStyle(in: $0, from: oldName, to: newName) }
            blockTable[handle] = block
        }
    }

    private func replacingTextStyle(in primitive: CADPrimitive, from oldName: String, to newName: String) -> CADPrimitive {
        guard case .text(let position, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color) = primitive,
              let style, style.caseInsensitiveCompare(oldName) == .orderedSame else { return primitive }
        return .text(position: position, text: text, height: height, rotation: rotation, style: newName, alignH: alignH, alignV: alignV, mtextWidth: mtextWidth, color: color)
    }

    // MARK: - Layer Operations

    public func addLayer(_ layer: Layer) {
        pushUndo()
        layerTable[layer.handle] = layer
        if activeLayerID == nil { activeLayerID = layer.handle }
        markEdited(regenerate: true)
    }

    public func removeLayer(handle: UUID) {
        if let layer = layerTable[handle], isXrefDependentLayer(layer) {
            print("[Xref] Layer '\(layer.name)' is xref-dependent and cannot be deleted (Detach the xref).")
            return
        }
        pushUndo()
        layerTable.removeValue(forKey: handle)
        if activeLayerID == handle { activeLayerID = layerTable.keys.first }
        markEdited(regenerate: true)
    }

    public func layer(for handle: UUID) -> Layer? {
        layerTable[handle]
    }

    // Legacy Array copy (Avoid using in performance loops)
    public var allLayers: [Layer] { Array(layerTable.values) }

    // Fast O(1) properties for UI and Rendering
    public var layerCount: Int { layerTable.count }
    public var layersView: Dictionary<UUID, Layer>.Values { layerTable.values }

    public func setLayerVisible(_ handle: UUID, visible: Bool) {
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.isVisible = visible
        layerTable[handle] = layer
        markEdited(regenerate: true)
        // Visibility is filtered at query time; the grid still holds all handles. No invalidation.
    }

    public func renameLayer(handle: UUID, name: String) {
        if let layer = layerTable[handle], isXrefDependentLayer(layer) {
            print("[Xref] Layer '\(layer.name)' is xref-dependent and cannot be renamed.")
            return
        }
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.name = name
        layerTable[handle] = layer
        markEdited(regenerate: true)
    }

    public func setLayerOpacity(_ handle: UUID, opacity: Double) {
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.opacity = max(0.0, min(1.0, opacity))
        layerTable[handle] = layer
        markEdited(regenerate: true)
    }

    public func setLayerColor(_ handle: UUID, color: ColorRGBA) {
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.color = color
        layerTable[handle] = layer
        markEdited(regenerate: true)
    }

    public func setLayerLineWeight(_ handle: UUID, lineWeight: Double) {
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.lineWeight = lineWeight
        layerTable[handle] = layer
        markEdited(regenerate: true)
    }

    public func setLayerLineType(_ handle: UUID, lineType: String) {
        pushUndo()
        guard var layer = layerTable[handle] else { return }
        layer.lineType = lineType
        layerTable[handle] = layer
        markEdited(regenerate: true)
    }

    /// Find a layer by name (first match, case-sensitive).
    public func findLayer(named name: String) -> Layer? {
        layerTable.values.first { $0.name == name }
    }

    /// Generate a unique layer name by appending a counter.
    public func uniqueLayerName(base: String = "Layer") -> String {
        var counter = 1
        var candidate = base
        while findLayer(named: candidate) != nil {
            counter += 1
            candidate = "\(base) \(counter)"
        }
        return candidate
    }

    private func preparedEntityForStorage(_ entity: CADEntity) -> CADEntity {
        var result = entity
        if let blockID = result.blockID, let block = effectiveBlock(for: blockID) {
            if var array = result.arrayData {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: result.transform,
                    document: self)
                if array.kind == .path, path.count >= 2 {
                    array.cachedPath = path
                    result.arrayData = array
                }
                result.updateArrayCache(
                    sourceBoundingBox: block.localBoundingBox,
                    pathPoints: path)
            } else if blockTable[blockID]?.isXref == true && block.geometry.isEmpty {
                // Unresolved xref: placeholder bounds/anchors.
                let placeholder = CADRendererBridge.unresolvedXrefPlaceholder(
                    blockName: block.name)
                result.localBoundingBox = CADBlock.computeBoundingBox(from: placeholder)
                result.updateAnchorCache(from: placeholder)
            } else {
                result.localBoundingBox = block.localBoundingBox
                result.updateAnchorCache(from: block.geometry)
            }
        } else if result.arrayData == nil {
            // Migrate legacy/raw pen samples to the current stabilized fit-point
            // representation the next time the entity is stored or loaded.
            var penStabilization = PenStrokeStabilizationSettings.from(xdata: result.xdata)
            if penStabilization.useSpline,
               !penStabilization.fitPointsStored,
               let geometry = result.localGeometry {
                var updatedGeometry = geometry
                var migrated = false
                for index in updatedGeometry.indices {
                    guard case .penStroke(let vertices, let baseLineWeight, let color) = updatedGeometry[index],
                          let fit = PenStrokeSplineFitter.fit(
                            vertices: vertices,
                            settings: penStabilization,
                            simplifyInput: true)
                    else { continue }
                    updatedGeometry[index] = .penStroke(
                        vertices: fit.fitVertices,
                        baseLineWeight: baseLineWeight,
                        color: color)
                    migrated = true
                }
                if migrated {
                    result.localGeometry = updatedGeometry
                    penStabilization.fitPointsStored = true
                    penStabilization.apply(to: &result)
                }
            }

            result.localBoundingBox = CADEntity.computeLocalBoundingBox(
                blockID: result.blockID,
                localGeometry: result.localGeometry) ?? result.localBoundingBox

            // A pen stroke stores sparse on-curve fit points. Its solved NURBS
            // controls can extend outside that fit-point box, so include them in
            // the cached AABB to keep spatial queries conservative.
            if let geometry = result.localGeometry {
                let stabilization = PenStrokeStabilizationSettings.from(xdata: result.xdata)
                var penControlPoints: [Vector3] = []
                for primitive in geometry {
                    guard case .penStroke(let vertices, _, _) = primitive else { continue }
                    if stabilization.useSpline,
                       let fit = PenStrokeSplineFitter.fit(
                        vertices: vertices,
                        settings: stabilization) {
                        penControlPoints.append(contentsOf: fit.controlVertices.map(\.position))
                    } else {
                        penControlPoints.append(contentsOf: vertices.map(\.position))
                    }
                }
                if !penControlPoints.isEmpty {
                    let penBox = BoundingBox3D(from: penControlPoints)
                    if var box = result.localBoundingBox {
                        box.min.x = min(box.min.x, penBox.min.x)
                        box.min.y = min(box.min.y, penBox.min.y)
                        box.min.z = min(box.min.z, penBox.min.z)
                        box.max.x = max(box.max.x, penBox.max.x)
                        box.max.y = max(box.max.y, penBox.max.y)
                        box.max.z = max(box.max.z, penBox.max.z)
                        result.localBoundingBox = box
                    } else {
                        result.localBoundingBox = penBox
                    }
                }
            }
            result.updateAnchorCache()
        }
        return result
    }

    private func refreshPathArrays(dependingOn pathHandle: UUID? = nil) {
        let handles = entityRegistry.values.compactMap { entity -> UUID? in
            guard let array = entity.arrayData, array.kind == .path else { return nil }
            if let pathHandle, array.pathEntityHandle != pathHandle { return nil }
            return entity.handle
        }
        for handle in handles {
            guard let entity = entityRegistry[handle] else { continue }
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
    }

    // MARK: - Block Operations

    public func addBlock(_ block: CADBlock) {
        pushUndo()
        blockTable[block.handle] = block
        markEdited(regenerate: true)
    }

    /// Insert a block definition without undo/dirty side effects
    /// (xref attach fan-out into non-active view documents).
    public func insertBlockSilently(_ block: CADBlock) {
        blockTable[block.handle] = block
    }

    /// Update the descriptor of an xref definition in place (repath).
    public func updateXrefDescriptor(blockHandle: UUID, descriptor: CADXrefDescriptor) {
        guard var block = blockTable[blockHandle], block.isXref else { return }
        block.xrefDescriptor = descriptor
        blockTable[blockHandle] = block
    }

    /// Detach an xref: remove the definition, every instance, and any
    /// dependent layers no remaining geometry references. One undo step.
    /// Returns (instances removed, layers purged).
    @discardableResult
    public func detachXref(blockHandle: UUID, pushUndoBefore: Bool = true) -> (instances: Int, layersPurged: [String]) {
        guard let block = blockTable[blockHandle], block.isXref else { return (0, []) }
        if pushUndoBefore { pushUndo() }
        let instanceHandles = entityRegistry.values
            .filter { $0.blockID == blockHandle }.map(\.handle)
        for handle in instanceHandles { entityRegistry.removeValue(forKey: handle) }
        blockTable.removeValue(forKey: blockHandle)

        // Purge dependent layers owned by this xref that nothing else uses.
        let prefix = block.name.uppercased() + "|"
        let dependentLayers = layerTable.values.filter {
            $0.name.uppercased().hasPrefix(prefix)
        }
        var purged: [String] = []
        for layer in dependentLayers
        where !isLayerStillReferenced(layer, excludingShadowOf: blockHandle) {
            layerTable.removeValue(forKey: layer.handle)
            purged.append(layer.name)
        }
        invalidateEntityGrid()
        markEdited(regenerate: true)
        return (instanceHandles.count, purged)
    }

    /// True when any entity sits on the layer or any block primitive
    /// (including loaded xref shadows) styles against it by name.
    public func isLayerStillReferenced(
        _ layer: Layer, excludingShadowOf excludedBlock: UUID? = nil
    ) -> Bool {
        if entityRegistry.values.contains(where: { $0.layerID == layer.handle }) {
            return true
        }
        let upper = layer.name.uppercased()
        func stylesUse(_ styles: [Int: CADPrimitiveStyle]) -> Bool {
            styles.values.contains { $0.effectiveLayerName?.uppercased() == upper }
        }
        if blockTable.values.contains(where: { stylesUse($0.primitiveStyles) }) {
            return true
        }
        if let store = xrefRuntimeStore {
            for (handle, entry) in store.allEntries() where handle != excludedBlock {
                if let shadow = entry.shadow, stylesUse(shadow.primitiveStyles) {
                    return true
                }
            }
        }
        return false
    }

    /// Dependent-symbol rename for a bind: mode 0 turns `Owner|Name`
    /// into `Owner$0$Name` (incrementing `$n$` on collision with
    /// `existingUpperNames`); mode 1 strips the prefix (merge).
    public static func boundSymbolName(
        _ name: String, bindType: Int, existingUpperNames: Set<String>
    ) -> String? {
        guard let sep = name.firstIndex(of: "|") else { return nil }
        let owner = String(name[..<sep])
        let leaf = String(name[name.index(after: sep)...])
        if bindType == 1 { return leaf }
        var n = 0
        var candidate = "\(owner)$\(n)$\(leaf)"
        while existingUpperNames.contains(candidate.uppercased()) {
            n += 1
            candidate = "\(owner)$\(n)$\(leaf)"
        }
        return candidate
    }

    /// Bind one xref into this document using its loaded shadow block:
    /// materializes geometry, renames/merges dependent symbols per
    /// BINDTYPE, and clears the descriptor. One undo step when asked.
    @discardableResult
    public func bindXref(
        blockHandle: UUID, shadow: CADBlock, bindType: Int, pushUndoBefore: Bool = true
    ) -> Bool {
        guard var block = blockTable[blockHandle], block.isXref else { return false }
        if pushUndoBefore { pushUndo() }

        // Scope: only dependent symbols this xref (and its nested
        // children, baked into the shadow) actually brought in.
        var owners: Set<String> = [block.name.uppercased()]
        for style in shadow.primitiveStyles.values {
            if let name = style.effectiveLayerName,
               let sep = name.firstIndex(of: "|") {
                owners.insert(String(name[..<sep]).uppercased())
            }
        }
        func owned(_ name: String) -> Bool {
            guard let sep = name.firstIndex(of: "|") else { return false }
            return owners.contains(String(name[..<sep]).uppercased())
        }

        // Rename maps are derived per symbol table from live names.
        let layerNames = { Set(self.layerTable.values.map { $0.name.uppercased() }) }
        var layerRemap: [String: String] = [:]  // uppercased old -> new
        for layer in layerTable.values where owned(layer.name) {
            if let newName = Self.boundSymbolName(
                layer.name, bindType: bindType, existingUpperNames: layerNames()) {
                layerRemap[layer.name.uppercased()] = newName
            }
        }
        func remapDict<V>(_ map: [String: String], _ dict: inout [String: V], rename: (inout V, String) -> Void) {
            var result: [String: V] = [:]
            for (key, var value) in dict {
                if let newKey = map[key.uppercased()] {
                    if bindType == 1, dict[newKey] != nil || result[newKey] != nil {
                        continue  // merge: host definition wins
                    }
                    rename(&value, newKey)
                    result[newKey] = value
                } else {
                    result[key] = value
                }
            }
            dict = result
        }
        func symbolRemap<V>(_ dict: [String: V]) -> [String: String] {
            var map: [String: String] = [:]
            let existing = Set(dict.keys.map { $0.uppercased() })
            for key in dict.keys where owned(key) {
                if let newKey = Self.boundSymbolName(key, bindType: bindType, existingUpperNames: existing) {
                    map[key.uppercased()] = newKey
                }
            }
            return map
        }
        let textStyleRemap = symbolRemap(textStyles)
        let linetypeRemap = symbolRemap(linetypePatterns)

        // Remap shadow styles/xdata into host names.
        func remapStyles(
            _ styles: [Int: CADPrimitiveStyle]
        ) -> [Int: CADPrimitiveStyle] {
            var out = styles
            for (index, var style) in out {
                if let name = style.layerName, let mapped = layerRemap[name.uppercased()] {
                    style.layerName = mapped
                }
                if let name = style.lineType, let mapped = linetypeRemap[name.uppercased()] {
                    style.lineType = mapped
                }
                out[index] = style
            }
            return out
        }
        func remapXData(
            _ xdata: [Int: [String: XDataValue]]
        ) -> [Int: [String: XDataValue]] {
            var out = xdata
            for (index, var entry) in out {
                if case .string(let name) = entry["dxf.textStyle"],
                   let mapped = textStyleRemap[name.uppercased()] {
                    entry["dxf.textStyle"] = .string(mapped)
                }
                if case .string(let name) = entry["dxf.lineType"],
                   let mapped = linetypeRemap[name.uppercased()] {
                    entry["dxf.lineType"] = .string(mapped)
                }
                out[index] = entry
            }
            return out
        }

        // Rename/merge the symbol tables themselves.
        var handleByUpperName: [String: UUID] = [:]
        for layer in layerTable.values { handleByUpperName[layer.name.uppercased()] = layer.handle }
        for (upper, newName) in layerRemap {
            guard let handle = handleByUpperName[upper] else { continue }
            if bindType == 1, handleByUpperName[newName.uppercased()] != nil {
                layerTable.removeValue(forKey: handle)
            } else if var layer = layerTable[handle] {
                layer.name = newName
                layerTable[handle] = layer
            }
        }
        remapDict(textStyleRemap, &textStyles) { $0.name = $1 }
        remapDict(symbolRemap(dimensionStyles), &dimensionStyles) { _, _ in }
        remapDict(symbolRemap(leaderStyles), &leaderStyles) { $0.name = $1 }
        remapDict(linetypeRemap, &linetypePatterns) { _, _ in }

        // Host blocks that styled against dependent names follow along.
        for (handle, var other) in blockTable where handle != blockHandle {
            let remapped = remapStyles(other.primitiveStyles)
            if remapped != other.primitiveStyles {
                other.primitiveStyles = remapped
                other.primitiveXData = remapXData(other.primitiveXData)
                blockTable[handle] = other
            }
        }

        block.geometry = shadow.geometry
        block.primitiveStyles = remapStyles(shadow.primitiveStyles)
        block.primitiveXData = remapXData(shadow.primitiveXData)
        block.xrefDescriptor = nil
        block.dxfFlags &= ~(CADXrefDescriptor.Flags.xref | CADXrefDescriptor.Flags.xrefOverlay)
        block.updateBoundingBox()
        blockTable[blockHandle] = block
        blockGridCache.removeValue(forKey: blockHandle)

        for (handle, entity) in entityRegistry where entity.blockID == blockHandle {
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        invalidateEntityGrid()
        markEdited(regenerate: true)
        return true
    }

    /// XBIND one dependent layer: rename (bind mode 0) or merge into
    /// the host layer of the same leaf name (mode 1), rewriting
    /// references in host blocks. Returns the resulting layer name.
    @discardableResult
    public func xbindLayer(named dependentName: String, bindType: Int) -> String? {
        guard let layer = allLayers.first(where: {
            $0.name.caseInsensitiveCompare(dependentName) == .orderedSame
        }), isXrefDependentLayer(layer) else { return nil }
        let existing = Set(layerTable.values.map { $0.name.uppercased() })
        guard let newName = Self.boundSymbolName(
            layer.name, bindType: bindType, existingUpperNames: existing) else { return nil }
        pushUndo()
        let upper = layer.name.uppercased()
        if bindType == 1, existing.contains(newName.uppercased()) {
            layerTable.removeValue(forKey: layer.handle)
        } else {
            var copy = layer
            copy.name = newName
            layerTable[layer.handle] = copy
        }
        for (handle, var block) in blockTable {
            var changed = false
            for (index, var style) in block.primitiveStyles
            where style.effectiveLayerName?.uppercased() == upper {
                style.layerName = newName
                block.primitiveStyles[index] = style
                changed = true
            }
            if changed { blockTable[handle] = block }
        }
        // Loaded shadows referencing the old name follow along.
        if let store = xrefRuntimeStore {
            for (handle, entry) in store.allEntries() {
                guard var shadow = entry.shadow else { continue }
                var changed = false
                for (index, var style) in shadow.primitiveStyles
                where style.effectiveLayerName?.uppercased() == upper {
                    style.layerName = newName
                    shadow.primitiveStyles[index] = style
                    changed = true
                }
                if changed {
                    let updated = shadow
                    store.updateEntry(for: handle) { $0.shadow = updated }
                }
            }
        }
        markEdited(regenerate: true)
        return newName
    }

    public func removeBlock(handle: UUID) {
        pushUndo()
        blockTable.removeValue(forKey: handle)
        markEdited(regenerate: true)
    }

    public func block(for handle: UUID) -> CADBlock? {
        blockTable[handle]
    }

    // Legacy Array copy
    public var allBlocks: [CADBlock] { Array(blockTable.values) }

    // Fast O(1) properties for UI and Rendering
    public var blockCount: Int { blockTable.count }
    public var blocksView: Dictionary<UUID, CADBlock>.Values { blockTable.values }

    public func updateBlockGeometry(handle: UUID, geometry: [CADPrimitive]) {
        guard blockTable[handle]?.isXref != true else {
            print("[Xref] Block geometry of an external reference cannot be edited (Bind it first).")
            return
        }
        pushUndo()
        guard var block = blockTable[handle] else { return }
        block.geometry = geometry
        block.primitiveStyles.removeAll(keepingCapacity: false)
        block.primitiveXData.removeAll(keepingCapacity: false)
        block.updateBoundingBox()
        blockTable[handle] = block
        blockGridCache.removeValue(forKey: handle)
        let affectedHandles = entityRegistry.values
            .filter { $0.blockID == handle }
            .map(\.handle)
        for entityHandle in affectedHandles {
            if let entity = entityRegistry[entityHandle] {
                entityRegistry[entityHandle] = preparedEntityForStorage(entity)
            }
        }
        for entityHandle in affectedHandles { refreshPathArrays(dependingOn: entityHandle) }
        markEdited(regenerate: true)
        invalidateEntityGrid()   // instance world boxes changed
    }

    // MARK: - Entity Operations

    public func addEntity(_ entity: CADEntity) {
        documentLock.withLock {
            pushUndo()
            let e = preparedEntityForStorage(entity)
            entityRegistry[e.handle] = e
            markEdited(regenerate: true)
            invalidateEntityGrid()
        }
    }

    /// Batch-insert multiple entities under a single undo snapshot.
    /// Use this when creating multi-segment lines, exploded blocks, etc.
    /// to avoid pushing one snapshot per entity.
    public func addEntities(_ entities: [CADEntity]) {
        guard !entities.isEmpty else { return }
        documentLock.withLock {
            pushUndo()
            for entity in entities {
                let prepared = preparedEntityForStorage(entity)
                entityRegistry[prepared.handle] = prepared
            }
            markEdited(regenerate: true)
            invalidateEntityGrid()
        }
    }

    public func removeEntity(handle: UUID) {
        documentLock.withLock {
            pushUndo()
            entityRegistry.removeValue(forKey: handle)
            markEdited(regenerate: true)
            invalidateEntityGrid()
        }
    }

    /// Remove an entity without pushing undo or invalidating the spatial grid.
    /// Intended for an interactive edit that captures one undo snapshot up front
    /// and deliberately keeps the old grid as a conservative broad-phase until
    /// the gesture ends.
    public func removeEntityLive(handle: UUID) {
        guard entityRegistry.removeValue(forKey: handle) != nil else { return }
        refreshPathArrays(dependingOn: handle)
        markEdited(regenerate: true)
    }

    /// Batch live geometry edits under one regeneration. Interactive tools such
    /// as the pen eraser may touch several entities during one motion event; doing
    /// one `markEdited(regenerate:)` here avoids rebuilding render state once per
    /// entity while the spatial index deliberately remains a conservative snapshot.
    public func applyLiveEntityEdits(
        removing handles: Set<UUID>,
        updating entities: [CADEntity]
    ) {
        var changedHandles = Set<UUID>()

        for handle in handles {
            if entityRegistry.removeValue(forKey: handle) != nil {
                changedHandles.insert(handle)
            }
        }

        for entity in entities {
            guard entityRegistry[entity.handle] != nil else { continue }
            let updated = preparedEntityForStorage(entity)
            entityRegistry[updated.handle] = updated
            changedHandles.insert(updated.handle)
        }

        guard !changedHandles.isEmpty else { return }
        for handle in changedHandles { refreshPathArrays(dependingOn: handle) }
        markEdited(regenerate: true)
    }

    // MARK: - Entity Duplication (for COPY / PASTE commands)

    /// Deep-copy a set of entities, generating new UUIDs for each entity.
    /// Named block definitions are **shared** (copies keep the same
    /// `blockID`, like AutoCAD COPY); only anonymous blocks (`*…`, whose
    /// geometry is per-instance — dimensions and friends) are cloned, with
    /// all fields preserved. Returns the duplicated entities ready to be
    /// added via `addEntity(_:)`, plus any cloned blocks for `addBlock(_:)`.
    ///
    /// - Parameters:
    ///   - handles: The entity handles to duplicate.
    ///   - offset: A translation applied to each duplicated entity's transform
    ///     (e.g., to offset from original for COPY, or from base-point for PASTECLIP).
    /// - Returns: Duplicated entities, the anonymous-block remap
    ///   (original → clone handle), and the cloned block definitions.
    public func duplicateEntities(
        handles: Set<UUID>,
        offset: Vector3 = .zero
    ) -> (entities: [CADEntity], blockRemap: [UUID: UUID], clonedBlocks: [CADBlock]) {
        var newEntities: [CADEntity] = []
        var blockRemap: [UUID: UUID] = [:]
        var clonedBlocks: [CADBlock] = []

        // First pass: collect all referenced block IDs so we can remap them.
        var referencedBlockIDs = Set<UUID>()
        for handle in handles {
            guard let entity = entityRegistry[handle] else { continue }
            if let bid = entity.blockID {
                referencedBlockIDs.insert(bid)
            }
        }

        // Clone only anonymous blocks; named definitions are shared so a
        // copied INSERT keeps referencing the same definition (and, for
        // xrefs, the same runtime-store entry keyed by block handle).
        for origBlockID in referencedBlockIDs {
            guard let orig = blockTable[origBlockID], orig.name.hasPrefix("*") else { continue }
            let newBlockID = UUID()
            blockRemap[origBlockID] = newBlockID
            clonedBlocks.append(CADBlock(
                handle: newBlockID,
                name: orig.name,
                geometry: orig.geometry,
                primitiveStyles: orig.primitiveStyles,
                primitiveXData: orig.primitiveXData,
                dxfFlags: orig.dxfFlags,
                isInternalTableDisplayBlock: orig.isInternalTableDisplayBlock))
        }

        // Second pass: duplicate each entity.
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }

            // New handle
            entity = CADEntity(
                handle: UUID(),
                layerID: entity.layerID,
                blockID: entity.blockID.flatMap { blockRemap[$0] ?? $0 },
                localGeometry: entity.localGeometry,
                dimensionMetadata: entity.dimensionMetadata,
                leaderData: entity.leaderData,
                arrayData: entity.arrayData,
                transform: entity.transform,
                xdata: entity.xdata,
                drawOrder: entity.drawOrder
            )

            // Apply offset
            var t = entity.transform
            t.position = Vector3(
                x: t.position.x + offset.x,
                y: t.position.y + offset.y,
                z: t.position.z + offset.z
            )
            entity.transform = t

            newEntities.append(entity)
        }

        return (newEntities, blockRemap, clonedBlocks)
    }

    public func entity(for handle: UUID) -> CADEntity? {
        documentLock.withLock { entityRegistry[handle] }
    }

    // Legacy Array copy (Avoid using in performance loops)
    public var allEntities: [CADEntity] {
        documentLock.withLock { Array(entityRegistry.values) }
    }

    // Fast O(1) properties for UI and Rendering
    public var entityCount: Int { entityRegistry.count }
    public var entitiesView: Dictionary<UUID, CADEntity>.Values { entityRegistry.values }

    /// World-space bounds of geometry that can actually be drawn in the current document.
    /// This walks the renderable primitives instead of trusting cached entity boxes so rotated
    /// text, SHX glyphs, dimension blocks, arcs, ellipses, and splines match what is displayed.
    public func renderableWorldBoundingBox(visibleLayersOnly: Bool = true) -> BoundingBox3D? {
        documentLock.withLock {
            var bounds = CADRenderBoundsAccumulator()
        let layersByName = visibleLayersOnly ? layersByUppercasedName() : [:]
        // Rasters that never loaded render nothing; keep them out of extents.
        let drawableImageNames = Set(effectiveImageStore.keys)

        for entity in entityRegistry.values {
            guard let layer = layerTable[entity.layerID] else { continue }
            if visibleLayersOnly && !layer.isVisible { continue }

            let entityBackgroundScale: Double?
            if let value = entity.xdata["dxf.mtextBackgroundScale"],
               case .double(let scale) = value {
                entityBackgroundScale = scale
            } else {
                entityBackgroundScale = nil
            }
            let entityBackgroundUsesViewportColor: Bool
            if let value = entity.xdata["dxf.mtextBackgroundUsesViewportColor"],
               case .int(let flag) = value {
                entityBackgroundUsesViewportColor = flag != 0
            } else {
                entityBackgroundUsesViewportColor = false
            }
            let entityHasBackgroundColor: Bool
            if let value = entity.xdata["dxf.mtextBackgroundColor"],
               case .string(let hex) = value {
                entityHasBackgroundColor = ColorRGBA(hex: hex) != nil
            } else {
                entityHasBackgroundColor = false
            }

            if let value = entity.xdata["dxf.text"],
               case .string(let rawText) = value,
               !rawText.isEmpty {
                let displayText: String
                if let formattedValue = entity.xdata["dxf.formattedText"],
                   case .string(let json) = formattedValue,
                   let data = json.data(using: .utf8),
                   let formatted = try? JSONDecoder().decode(FormattedText.self, from: data) {
                    displayText = formatted.toPlainText()
                } else {
                    displayText = rawText
                }

                let height: Double
                if let heightValue = entity.xdata["dxf.textHeight"],
                   case .double(let value) = heightValue {
                    height = value
                } else {
                    height = 2.5
                }
                let style: String?
                if let styleValue = entity.xdata["dxf.textStyle"],
                   case .string(let value) = styleValue {
                    style = value
                } else {
                    style = nil
                }
                let alignH: Int
                if let alignValue = entity.xdata["dxf.alignH"],
                   case .int(let value) = alignValue {
                    alignH = value
                } else {
                    alignH = 0
                }
                let alignV: Int
                if let alignValue = entity.xdata["dxf.alignV"],
                   case .int(let value) = alignValue {
                    alignV = value
                } else {
                    alignV = 0
                }
                let width: Double?
                if let widthValue = entity.xdata["dxf.mtextWidth"],
                   case .double(let value) = widthValue {
                    width = value
                } else {
                    width = nil
                }

                includeRenderedTextBounds(
                    text: displayText,
                    position: .zero,
                    height: height,
                    rotation: 0,
                    style: style,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: width,
                    transform: entity.transform,
                    textXData: entity.xdata,
                    backgroundScale: entityBackgroundScale,
                    hasVisibleBackground: entityBackgroundUsesViewportColor || entityHasBackgroundColor,
                    into: &bounds)
                continue
            }

            let geometry: [CADPrimitive]
            let primitiveStyles: [Int: CADPrimitiveStyle]
            let primitiveXData: [Int: [String: XDataValue]]
            if let blockID = entity.blockID {
                guard let definedBlock = blockTable[blockID],
                      !definedBlock.isInternalTableDisplayBlock else { continue }
                // Xref fast path: cached shadow box instead of walking
                // potentially millions of primitives on the main thread.
                // Falls through to the walk only when visibility filtering
                // could shrink the box.
                if definedBlock.isXref, entity.arrayData == nil,
                   let effective = effectiveBlock(for: blockID) {
                    let needsWalk = visibleLayersOnly && effective.primitiveStyles.values.contains {
                        !CADPrimitiveVisibility.isVisible(style: $0, layersByName: layersByName)
                    }
                    if !needsWalk {
                        let localBox = effective.geometry.isEmpty
                            ? CADBlock.computeBoundingBox(
                                from: CADRendererBridge.unresolvedXrefPlaceholder(
                                    blockName: effective.name))
                            : effective.localBoundingBox
                        let worldBox = BoundingBox3D(
                            transforming: localBox, by: entity.transform)
                        bounds.include(worldBox.min)
                        bounds.include(worldBox.max)
                        continue
                    }
                }
                guard let block = effectiveBlock(for: blockID),
                      !block.geometry.isEmpty else { continue }
                geometry = block.geometry
                primitiveStyles = block.primitiveStyles
                primitiveXData = block.primitiveXData
            } else {
                guard let localGeometry = entity.localGeometry,
                      !localGeometry.isEmpty else { continue }
                geometry = localGeometry
                primitiveStyles = [:]
                primitiveXData = [:]
            }

            let transforms: [Transform3D]
            if let array = entity.arrayData {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: self)
                transforms = array.evaluatedInstances(pathPoints: path).map {
                    entity.transform.multiplying(by: $0.transform)
                }
            } else {
                transforms = [entity.transform]
            }

            for transform in transforms {
                for (index, primitive) in geometry.enumerated() {
                    if visibleLayersOnly,
                       !CADPrimitiveVisibility.isVisible(
                           style: primitiveStyles[index], layersByName: layersByName) {
                        continue
                    }
                    let primitiveStyle = primitiveStyles[index]
                    let backgroundScale = primitiveStyle?.textBackgroundScale
                        ?? entityBackgroundScale
                    let hasVisibleBackground =
                        primitiveStyle?.textBackgroundUsesViewportColor == true
                        || primitiveStyle?.textBackgroundColor != nil
                        || entityBackgroundUsesViewportColor
                        || entityHasBackgroundColor
                    includePrimitiveRenderBounds(
                        primitive,
                        transform: transform,
                        textXData: entity.blockID == nil
                            ? entity.xdata
                            : (primitiveXData[index] ?? [:]),
                        backgroundScale: backgroundScale,
                        hasVisibleBackground: hasVisibleBackground,
                        drawableImageNames: drawableImageNames,
                        into: &bounds)
                }
            }
        }

        return bounds.boundingBox
        }
    }

    private func includePrimitiveRenderBounds(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        textXData: [String: XDataValue],
        backgroundScale: Double?,
        hasVisibleBackground: Bool,
        drawableImageNames: Set<String> = [],
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        func includeTransformed(_ points: [Vector3]) {
            for point in points {
                bounds.include(transform.transformPoint(point))
            }
        }

        switch primitive {
        case .point(let position, _):
            bounds.include(transform.transformPoint(position))

        case .line(let start, let end, _):
            bounds.include(transform.transformPoint(start))
            bounds.include(transform.transformPoint(end))

        case .rect(let origin, let size, _),
             .fillRect(let origin, let size, _):
            includeTransformed([
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ])

        case .polygon(let points, _),
             .fillPolygon(let points, _):
            includeTransformed(points)

        case .polyline(let path, _):
            guard !path.isHatchBoundaryCarrier else { return }
            let hasCurves = !path.hatchEdges.isEmpty
                || path.vertices.contains { abs($0.bulge) > 1e-12 }
            let points = hasCurves
                ? path.tessellatedPoints(segmentsPerRadian: 16.0)
                : path.vertices.map { $0.position }
            includeTransformed(points)

        case .fillComplexPolygon(let outer, let holes, _),
             .gradient(let outer, let holes, _, _, _, _):
            includeTransformed(outer)
            for hole in holes { includeTransformed(hole) }

        case .circle(let center, let radius, _):
            includeConicBounds(
                center: center,
                axisX: Vector3(x: radius, y: 0, z: 0),
                axisY: Vector3(x: 0, y: radius, z: 0),
                transform: transform,
                into: &bounds)

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            includeArcBounds(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                transform: transform,
                into: &bounds)

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            guard !controlPoints.isEmpty else { return }
            let worldControlPoints = controlPoints.map { transform.transformPoint($0) }
            guard worldControlPoints.count >= 2 else {
                bounds.include(contentsOf: worldControlPoints)
                return
            }
            var minPoint = worldControlPoints[0]
            var maxPoint = worldControlPoints[0]
            for point in worldControlPoints.dropFirst() {
                minPoint.x = min(minPoint.x, point.x)
                minPoint.y = min(minPoint.y, point.y)
                minPoint.z = min(minPoint.z, point.z)
                maxPoint.x = max(maxPoint.x, point.x)
                maxPoint.y = max(maxPoint.y, point.y)
                maxPoint.z = max(maxPoint.z, point.z)
            }
            let diagonal = max((maxPoint - minPoint).magnitude, 1.0)
            let evaluated = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: worldControlPoints,
                weights: weights ?? Array(repeating: 1.0, count: worldControlPoints.count),
                chordTolerance: max(0.001, diagonal / 5000.0),
                maxDepth: 10,
                maxSegments: 4096)
            bounds.include(contentsOf: evaluated.isEmpty ? worldControlPoints : evaluated)

        case .penStroke(let vertices, _, _):
            let stabilization = PenStrokeStabilizationSettings.from(xdata: textXData)
            if stabilization.useSpline,
               let fit = PenStrokeSplineFitter.fit(
                vertices: vertices,
                settings: stabilization) {
                let worldControls = fit.controlVertices.map {
                    transform.transformPoint($0.position)
                }
                bounds.include(contentsOf: worldControls)
            } else {
                let worldPoints = vertices.map { transform.transformPoint($0.position) }
                bounds.include(contentsOf: worldPoints)
            }

        case .text(
            let position, let text, let height, let rotation, let style,
            let alignH, let alignV, let mtextWidth, _
        ):
            includeRenderedTextBounds(
                text: text,
                position: position,
                height: height,
                rotation: rotation,
                style: style,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: mtextWidth,
                transform: transform,
                textXData: textXData,
                backgroundScale: backgroundScale,
                hasVisibleBackground: hasVisibleBackground,
                into: &bounds)

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let minorAxis = Vector3(
                x: -majorAxis.y * minorRatio,
                y: majorAxis.x * minorRatio,
                z: 0)
            includeConicBounds(
                center: center,
                axisX: majorAxis,
                axisY: minorAxis,
                transform: transform,
                into: &bounds)

        case .hatch(let boundary, _, _, _, _, _):
            includeTransformed(boundary)

        case .hatchPath(let boundary, let holes, _, _, _, _, _):
            includeTransformed(boundary.tessellatedPoints(segmentsPerRadian: 16.0))
            for hole in holes {
                includeTransformed(hole.tessellatedPoints(segmentsPerRadian: 16.0))
            }

        case .ray(let start, _, _):
            bounds.include(transform.transformPoint(start))

        case .image(let insertion, let uAxis, let vAxis, let imageName, let clipBoundary, _):
            // Unresolved raster (missing file) renders nothing, so it must
            // not stretch zoom extents either. Repair via the xref palette.
            guard drawableImageNames.contains(imageName) else { break }
            if let clipBoundary, clipBoundary.count >= 2 {
                includeTransformed(clipBoundary)
            } else {
                includeTransformed([
                    insertion,
                    insertion + uAxis,
                    insertion + uAxis + vAxis,
                    insertion + vAxis,
                ])
            }

        case .table(let data, let origin, _):
            let size = DataTableTessellator.computeSize(data: data)
            includeTransformed([
                origin,
                Vector3(x: origin.x + size.width, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.width, y: origin.y + size.height, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.height, z: origin.z),
            ])
        }
    }

    private func includeConicBounds(
        center: Vector3,
        axisX: Vector3,
        axisY: Vector3,
        transform: Transform3D,
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        let worldCenter = transform.transformPoint(center)
        let worldAxisX = transform.transformPoint(center + axisX) - worldCenter
        let worldAxisY = transform.transformPoint(center + axisY) - worldCenter
        let extentX = hypot(worldAxisX.x, worldAxisY.x)
        let extentY = hypot(worldAxisX.y, worldAxisY.y)
        let extentZ = hypot(worldAxisX.z, worldAxisY.z)
        bounds.include(Vector3(
            x: worldCenter.x - extentX,
            y: worldCenter.y - extentY,
            z: worldCenter.z - extentZ))
        bounds.include(Vector3(
            x: worldCenter.x + extentX,
            y: worldCenter.y + extentY,
            z: worldCenter.z + extentZ))
    }

    private func includeArcBounds(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        transform: Transform3D,
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        guard center.x.isFinite, center.y.isFinite, radius.isFinite,
              startAngle.isFinite, endAngle.isFinite, radius > 0 else { return }

        let twoPi = 2.0 * Double.pi
        let rawSweep = endAngle - startAngle
        if abs(rawSweep) >= twoPi - 1e-12 {
            includeConicBounds(
                center: center,
                axisX: Vector3(x: radius, y: 0, z: 0),
                axisY: Vector3(x: 0, y: radius, z: 0),
                transform: transform,
                into: &bounds)
            return
        }

        var sweep = rawSweep
        if sweep < 0 { sweep += twoPi }
        let worldCenter = transform.transformPoint(center)
        let worldAxisX = transform.transformPoint(
            Vector3(x: center.x + radius, y: center.y, z: center.z)) - worldCenter
        let worldAxisY = transform.transformPoint(
            Vector3(x: center.x, y: center.y + radius, z: center.z)) - worldCenter

        func positiveRemainder(_ value: Double) -> Double {
            let remainder = value.truncatingRemainder(dividingBy: twoPi)
            return remainder < 0 ? remainder + twoPi : remainder
        }
        func isOnSweep(_ angle: Double) -> Bool {
            positiveRemainder(angle - startAngle) <= sweep + 1e-12
        }
        func worldPoint(at angle: Double) -> Vector3 {
            worldCenter
                + worldAxisX * cos(angle)
                + worldAxisY * sin(angle)
        }

        var candidates = [startAngle, startAngle + sweep]
        let xExtremum = atan2(worldAxisY.x, worldAxisX.x)
        let yExtremum = atan2(worldAxisY.y, worldAxisX.y)
        let zExtremum = atan2(worldAxisY.z, worldAxisX.z)
        candidates.append(contentsOf: [
            xExtremum, xExtremum + Double.pi,
            yExtremum, yExtremum + Double.pi,
            zExtremum, zExtremum + Double.pi,
        ])
        for angle in candidates where isOnSweep(angle) {
            bounds.include(worldPoint(at: angle))
        }
    }

    private func includeRenderedTextBounds(
        text: String,
        position: Vector3,
        height: Double,
        rotation: Double,
        style: String?,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?,
        transform: Transform3D,
        textXData: [String: XDataValue],
        backgroundScale: Double?,
        hasVisibleBackground: Bool,
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        let textStyle = CADTextStyle.resolve(style, in: textStyles)

        let heightOverride: Bool
        if let value = textXData["dxf.textHeightOverride"],
           case .int(let flag) = value {
            heightOverride = flag != 0
        } else {
            heightOverride = textXData["dxf.textEntityType"] != nil
        }
        let effectiveHeight =
            heightOverride || textStyle.fixedHeight <= 0
            ? height
            : textStyle.fixedHeight

        let isMText: Bool
        if let value = textXData["dxf.textEntityType"],
           case .string(let entityType) = value {
            isMText = entityType.uppercased() == "MTEXT"
        } else {
            isMText = mtextWidth != nil
        }

        let entityWidthFactor: Double
        if !isMText,
           let value = textXData["dxf.textWidthScale"],
           case .double(let width) = value,
           width > 0 {
            entityWidthFactor = width
        } else {
            entityWidthFactor = 1.0
        }
        let widthFactorOverride: Bool
        if !isMText,
           let value = textXData["dxf.textWidthScaleOverride"],
           case .int(let flag) = value {
            widthFactorOverride = flag != 0
        } else {
            widthFactorOverride = !isMText && abs(entityWidthFactor - 1.0) > 1e-12
        }
        let effectiveWidthFactor = widthFactorOverride
            ? entityWidthFactor
            : textStyle.widthFactor

        let entityOblique: Double
        if !isMText,
           let value = textXData["dxf.textOblique"],
           case .double(let angle) = value {
            entityOblique = angle
        } else {
            entityOblique = 0
        }
        let obliqueOverride: Bool
        if !isMText,
           let value = textXData["dxf.textObliqueOverride"],
           case .int(let flag) = value {
            obliqueOverride = flag != 0
        } else {
            obliqueOverride = !isMText && abs(entityOblique) > 1e-12
        }
        let effectiveOblique = obliqueOverride
            ? entityOblique
            : textStyle.obliqueAngle

        guard !text.isEmpty, effectiveHeight.isFinite, effectiveHeight > 0,
              rotation.isFinite else { return }

        let origin = transform.transformPoint(position)
        let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
        let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
        let worldX = transform.transformPoint(position + localX) - origin
        let worldY = transform.transformPoint(position + localY) - origin
        let worldHeight = effectiveHeight * max(worldY.magnitude, 1e-12)
        let worldWidth = mtextWidth.map { $0 * max(worldX.magnitude, 1e-12) }
        let worldRotation = atan2(worldX.y, worldX.x)
        let fontFile = CADFontManager.resolveTextStyleFont(
            styleName: style,
            textStyleFonts: textStyleFonts)

        if let font = CADFontManager.getOrLoadSHXFont(filename: fontFile) {
            let primitives = font.renderText(
                text,
                origin: origin,
                height: worldHeight,
                rotation: worldRotation,
                alignH: alignH,
                alignV: alignV,
                widthFactor: effectiveWidthFactor,
                obliqueAngle: effectiveOblique,
                maxWidth: worldWidth)
            for primitive in primitives {
                if case .line(let start, let end, _) = primitive {
                    bounds.include(start)
                    bounds.include(end)
                }
            }
        } else {
            includeEstimatedTextRectangle(
                text: text,
                origin: origin,
                height: worldHeight,
                rotation: worldRotation,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: worldWidth,
                margin: 0,
                into: &bounds)
        }

        if let scale = backgroundScale,
           scale >= 1.0,
           hasVisibleBackground {
            includeEstimatedTextRectangle(
                text: text,
                origin: origin,
                height: worldHeight,
                rotation: worldRotation,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: worldWidth,
                margin: max(0.0, (scale - 1.0) * worldHeight * 0.5),
                into: &bounds)
        }
    }

    private func includeEstimatedTextRectangle(
        text: String,
        origin: Vector3,
        height: Double,
        rotation: Double,
        alignH: Int,
        alignV: Int,
        mtextWidth: Double?,
        margin: Double,
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        let textBounds = CADEntity.estimateTextLocalBounds(
            text: text,
            height: height,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth)
        let cosRotation = cos(rotation)
        let sinRotation = sin(rotation)
        let corners = [
            (textBounds.minX - margin, textBounds.minY - margin),
            (textBounds.maxX + margin, textBounds.minY - margin),
            (textBounds.maxX + margin, textBounds.maxY + margin),
            (textBounds.minX - margin, textBounds.maxY + margin),
        ]
        for corner in corners {
            bounds.include(Vector3(
                x: origin.x + corner.0 * cosRotation - corner.1 * sinRotation,
                y: origin.y + corner.0 * sinRotation + corner.1 * cosRotation,
                z: origin.z))
        }
    }

    public func updateTransform(for handle: UUID, to newTransform: Transform3D) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.transform = newTransform
        entityRegistry[handle] = preparedEntityForStorage(entity)
        refreshPathArrays(dependingOn: handle)
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func updateTransformLive(for handle: UUID, to newTransform: Transform3D) {
        guard var entity = entityRegistry[handle] else { return }
        entity.transform = newTransform
        entityRegistry[handle] = preparedEntityForStorage(entity)
        refreshPathArrays(dependingOn: handle)
        markEdited(regenerate: true)
    }

    public func moveEntity(handle: UUID, by delta: Vector3) {
        guard let entity = entityRegistry[handle] else { return }
        var newTransform = entity.transform
        newTransform.position = Vector3(
            x: entity.transform.position.x + delta.x,
            y: entity.transform.position.y + delta.y,
            z: entity.transform.position.z + delta.z
        )
        updateTransform(for: handle, to: newTransform)   // invalidates grid
    }

    /// Replaces a stored entity (same handle) under a single undo snapshot.
    /// Used by entmod and scripted commands that rewrite entity data.
    public func replaceEntity(_ entity: CADEntity) {
        documentLock.withLock {
            pushUndo()
            entityRegistry[entity.handle] = preparedEntityForStorage(entity)
            markEdited(regenerate: true)
            invalidateEntityGrid()
        }
    }

    public func updateLayer(for handle: UUID, to layerID: UUID) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.layerID = layerID
        entityRegistry[handle] = entity
        markEdited(regenerate: true)
        // Layer reassignment does not change geometry/position; no grid invalidation.
    }

    /// Bulk layer reassignment — pushes a single undo entry for all entities.
    public func reassignEntities(handles: Set<UUID>, to layerID: UUID) {
        guard !handles.isEmpty else { return }
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            entity.layerID = layerID
            entityRegistry[handle] = entity
        }
        markEdited(regenerate: true)
        // Layer reassignment does not change geometry/position; no grid invalidation.
    }

    /// Update an entity's local geometry (for vertex drag finalization).
    public func updateEntityGeometry(for handle: UUID, geometry: [CADPrimitive]) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.localGeometry = geometry
        entity.localBoundingBox = CADEntity.computeLocalBoundingBox(
            blockID: entity.blockID, localGeometry: geometry)
        entity.updateAnchorCache()   // anchors live in local space; geometry changed
        entityRegistry[handle] = entity
        refreshPathArrays(dependingOn: handle)
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    /// Update entity without pushing undo — for live property editing.
    public func updateEntityLive(_ entity: CADEntity) {
        guard entityRegistry[entity.handle] != nil else { return }
        let updated = preparedEntityForStorage(entity)
        entityRegistry[updated.handle] = updated
        refreshPathArrays(dependingOn: updated.handle)
        // Don't invalidate grid or push undo.
        markEdited(regenerate: true)
    }

    /// Update entity with undo.
    public func updateEntity(_ entity: CADEntity) {
        pushUndo()
        guard entityRegistry[entity.handle] != nil else { return }
        let updated = preparedEntityForStorage(entity)
        entityRegistry[updated.handle] = updated
        refreshPathArrays(dependingOn: updated.handle)
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func updateEntities(_ entities: [CADEntity]) {
        let existing = entities.filter { entityRegistry[$0.handle] != nil }
        guard !existing.isEmpty else { return }
        pushUndo()
        for entity in existing {
            let updated = preparedEntityForStorage(entity)
            entityRegistry[updated.handle] = updated
            refreshPathArrays(dependingOn: updated.handle)
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    /// Update entity geometry without pushing undo — for live grip editing.
    /// The caller (finalizeVertexDrag) will push a single undo entry on mouse-up.
    public func updateEntityGeometryLive(for handle: UUID, geometry: [CADPrimitive]) {
        guard var entity = entityRegistry[handle] else { return }
        entity.localGeometry = geometry
        entity.localBoundingBox = CADEntity.computeLocalBoundingBox(
            blockID: entity.blockID, localGeometry: geometry)
        // Refresh anchors here too: arcs/circles/splines never go through the
        // finalize path (gripEditedGeometryNeedsFinalize excludes them), so the
        // live write is the ONLY place their anchors can be kept in sync.
        entity.updateAnchorCache()
        entityRegistry[handle] = entity
        refreshPathArrays(dependingOn: handle)
        // Don't invalidate entity grid during live drag — only on finalize
    }

    /// Update block geometry without pushing undo — for live grip editing.
    public func updateBlockGeometryLive(
        handle: UUID,
        geometry: [CADPrimitive],
        primitiveStyles: [Int: CADPrimitiveStyle]? = nil,
        primitiveXData: [Int: [String: XDataValue]]? = nil
    ) {
        guard blockTable[handle]?.isXref != true else { return }
        guard var block = blockTable[handle] else { return }
        block.geometry = geometry
        block.primitiveStyles = (primitiveStyles ?? block.primitiveStyles).filter {
            $0.key >= 0 && $0.key < geometry.count
        }
        block.primitiveXData = (primitiveXData ?? block.primitiveXData).filter {
            $0.key >= 0 && $0.key < geometry.count && !$0.value.isEmpty
        }
        block.updateBoundingBox()
        blockTable[handle] = block
        blockGridCache.removeValue(forKey: handle)
        let affectedHandles = entityRegistry.values
            .filter { $0.blockID == handle }
            .map(\.handle)
        for entityHandle in affectedHandles {
            if let entity = entityRegistry[entityHandle] {
                entityRegistry[entityHandle] = preparedEntityForStorage(entity)
            }
        }
        for entityHandle in affectedHandles { refreshPathArrays(dependingOn: entityHandle) }
        invalidateEntityGrid()
    }

    public func setXData(for handle: UUID, key: String, value: XDataValue) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.xdata[key] = value
        entityRegistry[handle] = entity
        markEdited(regenerate: false)
        // xdata does not affect bounds; no grid invalidation.
    }

    /// Remove an XData key from an entity (reverting to layer default).
    public func removeXData(for handle: UUID, key: String) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.xdata.removeValue(forKey: key)
        entityRegistry[handle] = entity
        markEdited(regenerate: false)
    }

    /// Set the draw order for an entity. Pushes undo, marks dirty.
    /// Does not invalidate the spatial grid (draw order does not affect geometry).
    public func setDrawOrder(for handle: UUID, to drawOrder: Int) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.drawOrder = drawOrder
        entityRegistry[handle] = entity
        markEdited(regenerate: true)
    }

    // MARK: - Bulk XData Setters

    /// Set an XData key-value pair on all given entities in a single undo step.
    public func setXDataForAll(handles: Set<UUID>, key: String, value: XDataValue) {
        guard !handles.isEmpty else { return }
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            entity.xdata[key] = value
            entityRegistry[handle] = entity
        }
        markEdited(regenerate: false)
    }

    /// Remove an XData key from all given entities in a single undo step.
    public func removeXDataForAll(handles: Set<UUID>, key: String) {
        guard !handles.isEmpty else { return }
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            entity.xdata.removeValue(forKey: key)
            entityRegistry[handle] = entity
        }
        markEdited(regenerate: false)
    }

    /// Set the draw order on all given entities in a single undo step.
    public func setDrawOrderForAll(handles: Set<UUID>, to drawOrder: Int) {
        guard !handles.isEmpty else { return }
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            entity.drawOrder = drawOrder
            entityRegistry[handle] = entity
        }
        markEdited(regenerate: true)
    }

    /// Apply a full set of matchable properties to a single entity in one undo step.
    /// Used by MATCHPROP to copy all visual properties atomically.
    /// - Parameters:
    ///   - handle: The destination entity handle.
    ///   - layerID: Layer to assign.
    ///   - colorXData: If non-nil, sets dxf.color XData. If nil, removes dxf.color.
    ///   - lineWeightXData: If non-nil, sets dxf.lineWeight XData. If nil, removes dxf.lineWeight.
    ///   - lineTypeXData: If non-nil, sets dxf.lineType XData. If nil, removes dxf.lineType.
    ///   - drawOrder: Draw order value to set.
    public func applyMatchProperties(
        to handle: UUID,
        layerID: UUID,
        colorXData: XDataValue?,
        lineWeightXData: XDataValue?,
        lineTypeXData: XDataValue?,
        drawOrder: Int
    ) {
        guard var entity = entityRegistry[handle] else { return }
        pushUndo()
        entity.layerID = layerID
        if let cv = colorXData {
            entity.xdata["dxf.color"] = cv
        } else {
            entity.xdata.removeValue(forKey: "dxf.color")
        }
        if let lw = lineWeightXData {
            entity.xdata["dxf.lineWeight"] = lw
        } else {
            entity.xdata.removeValue(forKey: "dxf.lineWeight")
        }
        if let lt = lineTypeXData {
            entity.xdata["dxf.lineType"] = lt
        } else {
            entity.xdata.removeValue(forKey: "dxf.lineType")
        }
        entity.drawOrder = drawOrder
        entityRegistry[handle] = entity
        markEdited(regenerate: true)
    }

    // MARK: - Bulk Transforms

    public func moveEntities(handles: Set<UUID>, by delta: Vector3) {
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            var t = entity.transform
            t.position = Vector3(
                x: t.position.x + delta.x,
                y: t.position.y + delta.y,
                z: t.position.z + delta.z
            )
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func moveEntitiesLive(handles: Set<UUID>, by delta: Vector3) {
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            var t = entity.transform
            t.position = Vector3(
                x: t.position.x + delta.x,
                y: t.position.y + delta.y,
                z: t.position.z + delta.z
            )
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
        // Do not push undo or set isDirty. Handled on mouse-up.
    }

    public func rotateEntities(
        handles: Set<UUID>, around center: Vector3, angleDeltaRadians: Double
    ) {
        pushUndo()
        let cosR = cos(angleDeltaRadians)
        let sinR = sin(angleDeltaRadians)
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            let pos = entity.transform.position
            let dx = pos.x - center.x
            let dy = pos.y - center.y
            var t = entity.transform
            t.position = Vector3(
                x: center.x + dx * cosR - dy * sinR,
                y: center.y + dx * sinR + dy * cosR,
                z: pos.z
            )
            t.rotation = entity.transform.rotation + angleDeltaRadians
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func rotateEntitiesLive(
        handles: Set<UUID>, around center: Vector3, angleDeltaRadians: Double
    ) {
        let cosR = cos(angleDeltaRadians)
        let sinR = sin(angleDeltaRadians)
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            let pos = entity.transform.position
            let dx = pos.x - center.x
            let dy = pos.y - center.y
            var t = entity.transform
            t.position = Vector3(
                x: center.x + dx * cosR - dy * sinR,
                y: center.y + dx * sinR + dy * cosR,
                z: pos.z
            )
            t.rotation = entity.transform.rotation + angleDeltaRadians
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
    }

    public func scaleEntities(handles: Set<UUID>, around center: Vector3, factor: Double) {
        guard factor > 0 else { return }
        pushUndo()
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            let pos = entity.transform.position
            let dx = pos.x - center.x
            let dy = pos.y - center.y
            var t = entity.transform
            t.position = Vector3(
                x: center.x + dx * factor,
                y: center.y + dy * factor,
                z: pos.z
            )
            t.scale = Vector3(
                x: t.scale.x * factor,
                y: t.scale.y * factor,
                z: t.scale.z * factor
            )
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func scaleEntitiesLive(handles: Set<UUID>, around center: Vector3, factor: Double) {
        guard factor > 0 else { return }
        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            let pos = entity.transform.position
            let dx = pos.x - center.x
            let dy = pos.y - center.y
            var t = entity.transform
            t.position = Vector3(
                x: center.x + dx * factor,
                y: center.y + dy * factor,
                z: pos.z
            )
            t.scale = Vector3(
                x: t.scale.x * factor,
                y: t.scale.y * factor,
                z: t.scale.z * factor
            )
            entity.transform = t
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
    }

    // MARK: - ALIGN Command Support

    /// Apply a combined similarity transform (translate + rotate + optionally scale)
    /// to all selected entities in one undo step.
    ///
    /// Computes the 2D similarity transform from two source/destination point pairs
    /// and applies it to each entity's `Transform3D` via `multiplying(by:)`.
    ///
    /// - Parameters:
    ///   - handles: The set of entity handles to transform.
    ///   - s1: First source point (before transform).
    ///   - s2: Second source point (before transform).
    ///   - d1: First destination point (after transform).
    ///   - d2: Second destination point (after transform).
    ///   - scaleObjects: If `true`, scale proportionally based on source/dest length ratio.
    ///                   If `false`, only rotate (scale factor = 1).
    public func alignEntities(
        handles: Set<UUID>,
        sourcePoint1 s1: Vector3,
        sourcePoint2 s2: Vector3,
        destPoint1 d1: Vector3,
        destPoint2 d2: Vector3,
        scaleObjects: Bool
    ) {
        pushUndo()

        let sv = Vector3(x: s2.x - s1.x, y: s2.y - s1.y, z: 0)
        let dv = Vector3(x: d2.x - d1.x, y: d2.y - d1.y, z: 0)
        let ls = sqrt(sv.x * sv.x + sv.y * sv.y)
        let ld = sqrt(dv.x * dv.x + dv.y * dv.y)

        // Handle edge cases
        if ls < 1e-9 {
            // Source points coincident — cannot compute rotation or scale.
            // Fall back to pure translation from S1→D1.
            let translation = Transform3D.translated(by: Vector3(x: d1.x - s1.x, y: d1.y - s1.y, z: 0))
            for handle in handles {
                guard var entity = entityRegistry[handle] else { continue }
                entity.transform = translation.multiplying(by: entity.transform)
                entityRegistry[handle] = preparedEntityForStorage(entity)
            }
            for handle in handles { refreshPathArrays(dependingOn: handle) }
            markEdited(regenerate: true)
            invalidateEntityGrid()
            return
        }

        if ld < 1e-9 {
            // Destination points coincident — pure move only.
            let translation = Transform3D.translated(by: Vector3(x: d1.x - s1.x, y: d1.y - s1.y, z: 0))
            for handle in handles {
                guard var entity = entityRegistry[handle] else { continue }
                entity.transform = translation.multiplying(by: entity.transform)
                entityRegistry[handle] = preparedEntityForStorage(entity)
            }
            for handle in handles { refreshPathArrays(dependingOn: handle) }
            markEdited(regenerate: true)
            invalidateEntityGrid()
            return
        }

        // Compute the combined transform: T = Translation(D1) × Scale × Rotation × Translation(-S1)
        let alpha = atan2(sv.y, sv.x)
        let beta = atan2(dv.y, dv.x)
        let theta = beta - alpha
        let sf = scaleObjects ? ld / ls : 1.0

        let s1ToOrigin = Transform3D.translated(by: Vector3(x: -s1.x, y: -s1.y, z: 0))
        let rotation = Transform3D.rotated(by: theta)
        let scaleMatrix = Transform3D.scaled(by: Vector3(x: sf, y: sf, z: 1))
        let originToD1 = Transform3D.translated(by: Vector3(x: d1.x, y: d1.y, z: 0))
        let finalTransform = originToD1.multiplying(by: scaleMatrix.multiplying(by: rotation.multiplying(by: s1ToOrigin)))

        for handle in handles {
            guard var entity = entityRegistry[handle] else { continue }
            entity.transform = finalTransform.multiplying(by: entity.transform)
            entityRegistry[handle] = preparedEntityForStorage(entity)
        }
        for handle in handles { refreshPathArrays(dependingOn: handle) }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    /// Atomically remove a set of entities and insert replacements in one undo step.
    /// Used by JOIN and similar commands that merge multiple entities into one.
    public func replaceWithAssociativeArray(
        sourceBlock: CADBlock,
        removing handles: Set<UUID>,
        arrayEntity: CADEntity
    ) {
        guard !handles.isEmpty else { return }
        pushUndo()
        blockTable[sourceBlock.handle] = sourceBlock
        for handle in handles { entityRegistry.removeValue(forKey: handle) }
        let prepared = preparedEntityForStorage(arrayEntity)
        entityRegistry[prepared.handle] = prepared
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    @discardableResult
    public func replaceWithNonAssociativeArray(
        sourceBlock: CADBlock,
        removing handles: Set<UUID>,
        arrayEntity: CADEntity
    ) -> [UUID] {
        guard !handles.isEmpty,
              let array = arrayEntity.arrayData else { return [] }
        let path = CADArrayPathResolver.points(
            for: array,
            containerTransform: arrayEntity.transform,
            document: self)
        let instances = array.evaluatedInstances(pathPoints: path)
        guard !instances.isEmpty else { return [] }

        pushUndo()
        blockTable[sourceBlock.handle] = sourceBlock
        for handle in handles { entityRegistry.removeValue(forKey: handle) }

        var newHandles: [UUID] = []
        newHandles.reserveCapacity(instances.count)
        for instance in instances {
            var copy = CADEntity(
                layerID: arrayEntity.layerID,
                blockID: sourceBlock.handle,
                transform: arrayEntity.transform.multiplying(by: instance.transform),
                xdata: arrayEntity.xdata,
                drawOrder: arrayEntity.drawOrder)
            copy = preparedEntityForStorage(copy)
            entityRegistry[copy.handle] = copy
            newHandles.append(copy.handle)
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
        return newHandles
    }

    @discardableResult
    public func explodeAssociativeArray(handle: UUID) -> [UUID] {
        explodeEntities(handles: [handle])
    }

    @discardableResult
    public func explodeAssociativeArrays(handles sourceHandles: Set<UUID>) -> [UUID] {
        explodeEntities(handles: sourceHandles)
    }

    /// Explodes compound objects (rectangles, polylines, associative arrays, block references,
    /// dimensions, leaders, tables, and multi-primitive entities) into their component elements.
    @discardableResult
    public func explodeEntities(handles sourceHandles: Set<UUID>) -> [UUID] {
        guard !sourceHandles.isEmpty else { return [] }

        var handlesToRemove = Set<UUID>()
        var entitiesToAdd: [CADEntity] = []

        for handle in sourceHandles {
            guard let entity = entityRegistry[handle] else { continue }

            // 1. Associative Array
            if let array = entity.arrayData,
               let blockID = entity.blockID,
               blockTable[blockID] != nil {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: self)
                let instances = array.evaluatedInstances(pathPoints: path)
                if !instances.isEmpty {
                    handlesToRemove.insert(entity.handle)
                    for instance in instances {
                        var copy = CADEntity(
                            layerID: entity.layerID,
                            blockID: blockID,
                            transform: entity.transform.multiplying(by: instance.transform),
                            xdata: entity.xdata,
                            drawOrder: entity.drawOrder)
                        copy.xdata.removeValue(forKey: "dxf.handle")
                        entitiesToAdd.append(copy)
                    }
                }
                continue
            }

            // 2. Block Reference (non-array)
            if let blockID = entity.blockID, entity.arrayData == nil {
                if blockTable[blockID]?.isXref == true { continue }
                guard let block = effectiveBlock(for: blockID), !block.geometry.isEmpty else { continue }

                handlesToRemove.insert(entity.handle)
                for (index, prim) in block.geometry.enumerated() {
                    var layerID = entity.layerID
                    if let style = block.primitiveStyles[index],
                       let l = layersView.first(where: { $0.name == style.layerName }) {
                        layerID = l.handle
                    }
                    let transformed = CADGeometryMath.transformPrimitives([prim], by: entity.transform)
                    var xd = block.primitiveXData[index] ?? entity.xdata
                    xd.removeValue(forKey: "dxf.handle")
                    for tp in transformed {
                        let loose = CADEntity(
                            layerID: layerID,
                            localGeometry: [tp],
                            transform: .identity,
                            xdata: xd,
                            drawOrder: entity.drawOrder
                        )
                        entitiesToAdd.append(loose)
                    }
                }
                continue
            }

            // 3. Loose Geometry / Compound Entities
            if let geometry = entity.localGeometry, !geometry.isEmpty {
                var decomposedPrimitives: [CADPrimitive] = []
                var canExplode = false

                if entity.dimensionMetadata != nil || entity.leaderData != nil {
                    canExplode = true
                }
                if geometry.count > 1 {
                    canExplode = true
                }

                for prim in geometry {
                    if let sub = CADDocument.explodePrimitive(prim, transform: entity.transform) {
                        decomposedPrimitives.append(contentsOf: sub)
                        canExplode = true
                    } else {
                        let transformed = CADGeometryMath.transformPrimitives([prim], by: entity.transform)
                        decomposedPrimitives.append(contentsOf: transformed)
                    }
                }

                if canExplode, !decomposedPrimitives.isEmpty {
                    handlesToRemove.insert(entity.handle)
                    var xd = entity.xdata
                    xd.removeValue(forKey: "dxf.handle")
                    xd.removeValue(forKey: "dxf.closed")

                    for prim in decomposedPrimitives {
                        let newEntity = CADEntity(
                            layerID: entity.layerID,
                            localGeometry: [prim],
                            transform: .identity,
                            xdata: xd,
                            drawOrder: entity.drawOrder
                        )
                        entitiesToAdd.append(newEntity)
                    }
                }
                continue
            }
        }

        guard !handlesToRemove.isEmpty, !entitiesToAdd.isEmpty else { return [] }

        pushUndo()
        for handle in handlesToRemove {
            entityRegistry.removeValue(forKey: handle)
        }
        var newHandles: [UUID] = []
        newHandles.reserveCapacity(entitiesToAdd.count)
        for entity in entitiesToAdd {
            let prepared = preparedEntityForStorage(entity)
            entityRegistry[prepared.handle] = prepared
            newHandles.append(prepared.handle)
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
        return newHandles
    }

    /// Decomposes a compound CADPrimitive into simpler primitives in world space, or nil if atomic.
    public static func explodePrimitive(
        _ prim: CADPrimitive,
        transform: Transform3D
    ) -> [CADPrimitive]? {
        switch prim {
        case .rect(let origin, let size, let color),
             .fillRect(let origin, let size, let color):
            let p0 = transform.transformPoint(origin)
            let p1 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
            let p2 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
            let p3 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            return [
                .line(start: p0, end: p1, color: color),
                .line(start: p1, end: p2, color: color),
                .line(start: p2, end: p3, color: color),
                .line(start: p3, end: p0, color: color)
            ]

        case .polygon(let points, let color),
             .fillPolygon(let points, let color):
            guard points.count >= 2 else { return nil }
            if points.count == 2 {
                let p0 = transform.transformPoint(points[0])
                let p1 = transform.transformPoint(points[1])
                return [.line(start: p0, end: p1, color: color)]
            }
            var lines: [CADPrimitive] = []
            lines.reserveCapacity(points.count)
            for i in 0..<points.count {
                let pA = transform.transformPoint(points[i])
                let pB = transform.transformPoint(points[(i + 1) % points.count])
                lines.append(.line(start: pA, end: pB, color: color))
            }
            return lines

        case .fillComplexPolygon(let outer, let holes, let color):
            var lines: [CADPrimitive] = []
            func addRing(_ ring: [Vector3]) {
                guard ring.count >= 2 else { return }
                for i in 0..<ring.count {
                    let pA = transform.transformPoint(ring[i])
                    let pB = transform.transformPoint(ring[(i + 1) % ring.count])
                    lines.append(.line(start: pA, end: pB, color: color))
                }
            }
            addRing(outer)
            for hole in holes { addRing(hole) }
            return lines.isEmpty ? nil : lines

        case .polyline(let path, let color):
            if !path.hatchEdges.isEmpty {
                var edgePrims: [CADPrimitive] = []
                for edge in path.hatchEdges {
                    let tEdge = edge.transformed(by: transform)
                    switch tEdge {
                    case .line(let s, let e):
                        edgePrims.append(.line(start: s, end: e, color: color))
                    case .circularArc(let c, let r, let sa, let sw):
                        let sA: Double
                        let eA: Double
                        if sw >= 0 {
                            sA = sa
                            eA = sa + sw
                        } else {
                            sA = sa + sw
                            eA = sa
                        }
                        edgePrims.append(.arc(center: c, radius: r, startAngle: sA, endAngle: eA, color: color))
                    case .ellipticalArc(let c, let u, let v, _, _):
                        let majorLen = u.magnitude
                        let minorRatio = majorLen > 1e-9 ? v.magnitude / majorLen : 1.0
                        edgePrims.append(.ellipse(center: c, majorAxis: u, minorRatio: minorRatio, color: color))
                    case .spline(let d):
                        edgePrims.append(.spline(controlPoints: d.controlPoints, knots: d.knots, degree: d.degree, weights: d.weights, color: color))
                    }
                }
                return edgePrims.isEmpty ? nil : edgePrims
            }

            guard path.segmentCount > 0 else { return nil }
            let tPath = path.transformed(by: transform)
            var segPrims: [CADPrimitive] = []
            for seg in 0..<tPath.segmentCount {
                if let arc = tPath.arcParameters(forSegment: seg) {
                    let sA: Double
                    let eA: Double
                    if arc.sweep >= 0 {
                        sA = arc.startAngle
                        eA = arc.startAngle + arc.sweep
                    } else {
                        sA = arc.startAngle + arc.sweep
                        eA = arc.startAngle
                    }
                    segPrims.append(.arc(center: arc.center, radius: arc.radius, startAngle: sA, endAngle: eA, color: color))
                } else {
                    let p1 = tPath.vertices[seg].position
                    let p2 = tPath.vertices[tPath.endVertexIndex(forSegment: seg)].position
                    segPrims.append(.line(start: p1, end: p2, color: color))
                }
            }
            return segPrims.isEmpty ? nil : segPrims

        case .table(let data, let origin, _):
            let tessellated = DataTableTessellator.explodeForDXF(data: data, origin: origin, transform: transform)
            return tessellated.isEmpty ? nil : tessellated

        case .hatch(let boundary, let pattern, let scale, let angle, let color, _):
            guard boundary.count >= 3 else { return nil }
            let adaptiveMinimumSpacing = DXFHatchGenerator.adaptiveMinimumSpacing(for: boundary)
            let nominalSpacing = DXFHatchGenerator.effectiveSpacing(patternName: pattern, scale: scale)
            let hatchLines = DXFHatchGenerator.generatePatternHatch(
                polygon: boundary,
                patternName: pattern,
                scale: scale,
                angleDegrees: angle * 180.0 / .pi,
                minimumSpacing: max(adaptiveMinimumSpacing, nominalSpacing))
            let colored = color != nil ? hatchLines.map { prim in
                if case .line(let s, let e, _) = prim { return CADPrimitive.line(start: s, end: e, color: color) }
                return prim
            } : hatchLines
            let transformed = CADGeometryMath.transformPrimitives(colored, by: transform)
            return transformed.isEmpty ? nil : transformed

        case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, _):
            let outerPts = boundary.tessellatedPoints()
            guard outerPts.count >= 3 else { return nil }
            let holePts = holes.map { $0.tessellatedPoints() }
            let patternPolygon = holePts.isEmpty ? outerPts : DXFHatchGenerator.connectHoles(outer: outerPts, holes: holePts)
            let adaptiveMinimumSpacing = DXFHatchGenerator.adaptiveMinimumSpacing(for: patternPolygon)
            let nominalSpacing = DXFHatchGenerator.effectiveSpacing(patternName: pattern, scale: scale)
            let hatchLines = DXFHatchGenerator.generatePatternHatch(
                polygon: patternPolygon,
                patternName: pattern,
                scale: scale,
                angleDegrees: angle * 180.0 / .pi,
                minimumSpacing: max(adaptiveMinimumSpacing, nominalSpacing))
            let colored = color != nil ? hatchLines.map { prim in
                if case .line(let s, let e, _) = prim { return CADPrimitive.line(start: s, end: e, color: color) }
                return prim
            } : hatchLines
            let transformed = CADGeometryMath.transformPrimitives(colored, by: transform)
            return transformed.isEmpty ? nil : transformed

        default:
            return nil
        }
    }

    public func replaceEntities(remove handles: Set<UUID>, add newEntities: [CADEntity]) {
        guard !handles.isEmpty || !newEntities.isEmpty else { return }
        pushUndo()
        for handle in handles {
            entityRegistry.removeValue(forKey: handle)
        }
        for entity in newEntities {
            let prepared = preparedEntityForStorage(entity)
            entityRegistry[prepared.handle] = prepared
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func removeEntities(handles: Set<UUID>) {
        pushUndo()
        for handle in handles {
            entityRegistry.removeValue(forKey: handle)
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    // MARK: - Block Creation from Selected Entities

    /// Create a new block definition from the selected entities.
    /// Replaces the original entities with a single block instance at the collective center.
    /// - Returns: The newly created block, or nil if creation failed.
    @discardableResult
    public func createBlockFromEntities(handles: Set<UUID>, name: String) -> CADBlock? {
        guard !handles.isEmpty else { return nil }
        // Block geometry cannot contain a nested INSERT, so an xref in
        // the selection would be baked into the host file. Refuse.
        if handles.contains(where: { handle in
            guard let bid = entityRegistry[handle]?.blockID else { return false }
            return blockTable[bid]?.isXref == true
        }) {
            print("[Xref] Selection contains an external reference — Bind it before creating a block.")
            return nil
        }
        guard let center = collectiveCenter(for: handles) else { return nil }

        pushUndo()

        // Bake the selection into block-local space (relative to the
        // collective center), preserving per-primitive styles/xdata.
        let selected = handles.compactMap { entityRegistry[$0] }
        let baked = CADModelSpaceBaker.bake(
            entities: selected,
            layers: allLayers,
            blocks: allBlocks,
            basePoint: center)
        guard !baked.geometry.isEmpty else {
            // Pop the undo entry we just pushed and bail out
            _ = undoManager.popUndo(currentSnapshot: snapshot())
            return nil
        }

        // Create the block definition
        var block = CADBlock(
            name: name, geometry: baked.geometry,
            primitiveStyles: baked.primitiveStyles,
            primitiveXData: baked.primitiveXData)
        block.updateBoundingBox()
        blockTable[block.handle] = block

        // Remove the original entities
        for handle in handles {
            entityRegistry.removeValue(forKey: handle)
        }

        // Create a single block instance at the collective center
        // Use the first entity's layer, or the active layer
        let layerID = activeLayerID ?? layersView.first?.handle ?? UUID()
        let instance = CADEntity(
            layerID: layerID,
            blockID: block.handle,
            localGeometry: nil,
            transform: Transform3D.translated(by: center)
        )
        entityRegistry[instance.handle] = instance

        markEdited(regenerate: true)
        invalidateEntityGrid()
        return block
    }

    /// Lazily built local spatial grids for large internal blocks
    /// (xref shadows carry their own, built off-thread by the loader).
    private var blockGridCache: [UUID: CADBlockSpatialGrid] = [:]

    /// Spatial grid for hit/snap/rect queries over a block's effective
    /// geometry, or nil when the block is small enough to scan.
    public func spatialGrid(forBlock blockHandle: UUID) -> CADBlockSpatialGrid? {
        if let grid = xrefRuntimeStore?.spatialGrid(for: blockHandle) {
            return grid
        }
        if let cached = blockGridCache[blockHandle] { return cached }
        guard let block = effectiveBlock(for: blockHandle),
              block.geometry.count > CADBlockSpatialGrid.buildThreshold else { return nil }
        let grid = CADBlockSpatialGrid(primitives: block.geometry)
        blockGridCache[blockHandle] = grid
        return grid
    }

    public func spatialGrid(for entity: CADEntity) -> CADBlockSpatialGrid? {
        guard let bid = entity.blockID else { return nil }
        return spatialGrid(forBlock: bid)
    }

    /// Display-side block resolution: a loaded xref's shadow block when
    /// available, otherwise the document's own definition. Edit-side
    /// code (BEDIT, explode, geometry update) must use `block(for:)`.
    public func effectiveBlock(for handle: UUID) -> CADBlock? {
        if let shadow = xrefRuntimeStore?.shadowBlock(for: handle) {
            return shadow
        }
        return blockTable[handle]
    }

    public func resolvedGeometry(for entity: CADEntity) -> [CADPrimitive]? {
        if let bid = entity.blockID, let block = effectiveBlock(for: bid) {
            return block.geometry
        }
        return entity.localGeometry
    }

    /// Per-primitive styles aligned with `resolvedGeometry(for:)`
    /// (block styles for instances, empty for loose geometry).
    public func primitiveStyles(for entity: CADEntity) -> [Int: CADPrimitiveStyle] {
        if let bid = entity.blockID, let block = effectiveBlock(for: bid) {
            return block.primitiveStyles
        }
        return [:]
    }

    public func layersByUppercasedName() -> [String: Layer] {
        CADPrimitiveVisibility.layersByUppercasedName(layerTable.values)
    }

    /// Per-primitive visibility aligned with `resolvedGeometry(for:)`, or
    /// nil when every primitive is trivially visible (no styled layers).
    public func primitiveVisibility(for entity: CADEntity) -> [Bool]? {
        guard let geometry = resolvedGeometry(for: entity), !geometry.isEmpty else { return nil }
        let styles = primitiveStyles(for: entity)
        guard styles.values.contains(where: { $0.effectiveLayerName != nil }) else { return nil }
        let layersByName = layersByUppercasedName()
        return geometry.indices.map {
            CADPrimitiveVisibility.isVisible(style: styles[$0], layersByName: layersByName)
        }
    }

    /// Re-derive bounds/anchors for xref instances from current
    /// effective (shadow or placeholder) geometry. Called after xref
    /// load/unload/reload, undo restore, paste, and viewport projection.
    public func resyncXrefInstanceBounds(forBlock blockHandle: UUID? = nil) {
        var changed = false
        for (handle, entity) in entityRegistry {
            guard let bid = entity.blockID,
                  blockHandle == nil || bid == blockHandle,
                  blockTable[bid]?.isXref == true,
                  entity.arrayData == nil else { continue }
            var copy = entity
            if let block = effectiveBlock(for: bid), !block.geometry.isEmpty {
                copy.localBoundingBox = block.localBoundingBox
                copy.updateAnchorCache(from: block.geometry)
            } else {
                let placeholder = CADRendererBridge.unresolvedXrefPlaceholder(
                    blockName: blockTable[bid]?.name ?? "")
                copy.localBoundingBox = CADBlock.computeBoundingBox(from: placeholder)
                copy.updateAnchorCache(from: placeholder)
            }
            entityRegistry[handle] = copy
            changed = true
        }
        if changed { invalidateEntityGrid() }
    }

    /// After a media reference loads, sync instance geometry with the
    /// real file: PDF axes scale from placeholder to true page size,
    /// definition pixel sizes refresh. Runtime sync only — no undo
    /// entry, no dirty flag (mirrors resyncXrefInstanceBounds).
    public func resyncMediaInstanceBounds(forName name: String? = nil) {
        guard let store = mediaRuntimeStore else { return }
        var changed = false
        for (handle, entity) in entityRegistry {
            guard var geometry = entity.localGeometry else { continue }
            var entityChanged = false
            for index in geometry.indices {
                guard case .image(_, let uAxis, let vAxis, let imageName, _, _) = geometry[index],
                      name == nil || imageName == name,
                      let entry = store.entry(forName: imageName),
                      entry.status.hasShadowGeometry else { continue }
                if entry.kind == .pdf,
                   var params = CADPdfUnderlayMetadata.value(from: entity),
                   let pageW = entry.pageWidthPoints, let pageH = entry.pageHeightPoints,
                   params.pageWidthPoints > 0, params.pageHeightPoints > 0,
                   abs(pageW - params.pageWidthPoints) > 1e-9
                    || abs(pageH - params.pageHeightPoints) > 1e-9 {
                    let uRatio = pageW / params.pageWidthPoints
                    let vRatio = pageH / params.pageHeightPoints
                    geometry[index] = geometry[index].withImageAxes(
                        uAxis: uAxis * uRatio, vAxis: vAxis * vRatio)
                    params.pageWidthPoints = pageW
                    params.pageHeightPoints = pageH
                    var copy = entity
                    CADPdfUnderlayMetadata.set(params, on: &copy)
                    entityRegistry[handle] = copy
                    entityChanged = true
                }
                if entry.kind == .image, let asset = entry.asset,
                   var def = imageDefinitions[imageName],
                   def.pixelWidth != asset.pixelWidth || def.pixelHeight != asset.pixelHeight {
                    def.pixelWidth = asset.pixelWidth
                    def.pixelHeight = asset.pixelHeight
                    imageDefinitions[imageName] = def
                }
            }
            if entityChanged, var copy = entityRegistry[handle] {
                copy.localGeometry = geometry
                copy.localBoundingBox = CADBlock.computeBoundingBox(from: geometry)
                copy.updateAnchorCache(from: geometry)
                entityRegistry[handle] = copy
                changed = true
            }
        }
        if changed { invalidateEntityGrid() }
    }

    /// Merge dependent symbols from a loaded xref. Default VISRETAIN=1
    /// semantics: only missing symbols are added, host overrides survive
    /// reloads. With `resetExisting` (VISRETAIN=0), dependent layer
    /// properties are reset from the source file. Does not push undo or
    /// mark the document edited.
    public func mergeXrefDependentSymbols(
        layers: [Layer],
        textStyles: [String: CADTextStyle],
        dimensionStyles: [String: CADDimensionStyle],
        leaderStyles: [String: CADLeaderStyle],
        linetypePatterns: [String: [Double]],
        resetExisting: Bool = false
    ) {
        let existingNames = Set(layerTable.values.map { $0.name.uppercased() })
        for layer in layers {
            if !existingNames.contains(layer.name.uppercased()) {
                layerTable[layer.handle] = layer
            } else if resetExisting,
                      let existing = allLayers.first(where: {
                          $0.name.caseInsensitiveCompare(layer.name) == .orderedSame
                      }) {
                var copy = layer
                // Preserve host identity handle; adopt source properties.
                copy = Layer(
                    handle: existing.handle, name: existing.name,
                    isVisible: layer.isVisible, lineWeight: layer.lineWeight,
                    color: layer.color, lineType: layer.lineType,
                    isPlottable: layer.isPlottable,
                    plotStyleHandle: layer.plotStyleHandle, opacity: layer.opacity)
                layerTable[existing.handle] = copy
            }
        }
        for (key, value) in textStyles where self.textStyles[key] == nil {
            self.textStyles[key] = value
        }
        for (key, value) in dimensionStyles where self.dimensionStyles[key] == nil {
            self.dimensionStyles[key] = value
        }
        for (key, value) in leaderStyles where self.leaderStyles[key] == nil {
            self.leaderStyles[key] = value
        }
        for (key, value) in linetypePatterns where self.linetypePatterns[key] == nil {
            self.linetypePatterns[key] = value
        }
    }

    /// Owning xref block name for a dependent layer name
    /// ("SitePlan|Walls" → "SitePlan"), or nil when not dependent.
    public func xrefOwnerBlockName(forLayerName name: String) -> String? {
        guard let sep = name.firstIndex(of: "|") else { return nil }
        let prefix = String(name[..<sep])
        guard blockTable.values.contains(where: {
            $0.isXref && $0.name.caseInsensitiveCompare(prefix) == .orderedSame
        }) else { return nil }
        return prefix
    }

    public func isXrefDependentLayer(_ layer: Layer) -> Bool {
        xrefOwnerBlockName(forLayerName: layer.name) != nil
    }

    public func anyPrimitiveVisible(for entity: CADEntity, layersByName: [String: Layer]) -> Bool {
        guard let geometry = resolvedGeometry(for: entity), !geometry.isEmpty else { return false }
        let styles = primitiveStyles(for: entity)
        guard styles.values.contains(where: { $0.effectiveLayerName != nil }) else { return true }
        return geometry.indices.contains {
            CADPrimitiveVisibility.isVisible(style: styles[$0], layersByName: layersByName)
        }
    }

    public func collectiveCenter(for handles: Set<UUID>) -> Vector3? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for handle in handles {
            guard let entity = entityRegistry[handle],
                let bb = entity.worldBoundingBox
            else { continue }
            minX = min(minX, bb.min.x)
            minY = min(minY, bb.min.y)
            maxX = max(maxX, bb.max.x)
            maxY = max(maxY, bb.max.y)
            any = true
        }
        return any
            ? Vector3(x: (minX + maxX) / 2.0, y: (minY + maxY) / 2.0, z: 0) : nil
    }

    // MARK: - DXF Import

    // MARK: - Constraint Operations

    public func addConstraint(_ constraint: CADConstraint) {
        pushUndo()
        constraintTable[constraint.handle] = constraint
        markEdited(regenerate: true)
    }

    public func removeConstraint(handle: UUID) {
        pushUndo()
        constraintTable.removeValue(forKey: handle)
        markEdited(regenerate: true)
    }

    public func constraint(for handle: UUID) -> CADConstraint? {
        constraintTable[handle]
    }

    public var allConstraints: [CADConstraint] { Array(constraintTable.values) }
    public var constraintCount: Int { constraintTable.count }
    public var constraintsView: Dictionary<UUID, CADConstraint>.Values { constraintTable.values }

    // MARK: - Solved Transforms

    /// Store the result of a constraint solve.
    public func setSolvedTransform(for handle: UUID, transform: Transform3D) {
        solvedTransforms[handle] = transform
    }

    /// Clear all solved transforms (e.g. after editing constraints).
    public func clearSolvedTransforms() {
        solvedTransforms.removeAll()
        markEdited(regenerate: false)
    }

    /// Bulk import layers, blocks, and entities without per-item undo snapshots.
    /// Used by the tab manager to load a DXF file cleanly.
    public func importLayersBlocksEntities(layers: [Layer], blocks: [CADBlock], entities: [CADEntity]) {
        // Guard against potentially corrupted data from DXF import
        guard layers.count < 100_000 else {
            print("[CADDocument] ERROR: refusing to import \(layers.count) layers (limit 100k)")
            return
        }
        guard blocks.count < 500_000 else {
            print("[CADDocument] ERROR: refusing to import \(blocks.count) blocks (limit 500k)")
            return
        }
        guard entities.count < 10_000_000 else {
            print("[CADDocument] ERROR: refusing to import \(entities.count) entities (limit 10M)")
            return
        }
        print("[CADDocument] importLayersBlocksEntities: \(layers.count) layers, \(blocks.count) blocks, \(entities.count) entities")

        // Pre-validate entity handles: duplicate handles can cause dictionary corruption
        var seenHandles = Set<UUID>()
        seenHandles.reserveCapacity(entities.count)
        for entity in entities {
            guard seenHandles.insert(entity.handle).inserted else {
                print("[CADDocument] WARNING: duplicate entity handle \(entity.handle), skipping")
                continue
            }
        }
        seenHandles.removeAll(keepingCapacity: true)

        entityRegistry.reserveCapacity(entities.count)
        for layer in layers { layerTable[layer.handle] = layer }
        if activeLayerID == nil, let first = layers.first { activeLayerID = first.handle }
        for block in blocks { blockTable[block.handle] = block }
        for entity in entities {
            let e = preparedEntityForStorage(entity)
            entityRegistry[e.handle] = e
        }
        print("[CADDocument] import complete: registry has \(entityRegistry.count) entities")
        markEdited(regenerate: true)
        rebuildEntityGrid()   // build eagerly so the first hover doesn't pay for it
    }

    @MainActor
    public func importDXF(url: URL) throws {
        let imported = try DXFImporter.importDXFViews(filePath: url.path)

        for font in Set(imported.textStyles.values.map(\.fontFile)) {
            CADFontManager.debugFontLookup(font)
        }

        self.textStyles = imported.textStyles.isEmpty ? ["Standard": .standard] : imported.textStyles
        self.linetypePatterns = imported.linetypePatterns
        self.dimensionStyles = imported.dimensionStyles
        self.dxfRoundTripPayload = imported.roundTripPayload
        for layer in imported.layers { layerTable[layer.handle] = layer }
        if activeLayerID == nil, let first = imported.layers.first { activeLayerID = first.handle }
        for block in imported.blocks { blockTable[block.handle] = block }
        for entity in imported.entities {
            let prepared = preparedEntityForStorage(entity)
            entityRegistry[prepared.handle] = prepared
        }
        markEdited(regenerate: true)
        rebuildEntityGrid()
    }

    @MainActor
    public func importDXF(data: Data) throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("import_\(UUID().uuidString).dxf")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        try importDXF(url: tmpFile)
    }

    @MainActor
    public func importDWG(url: URL) throws {
        // Convert DWG → DXF via ODA FileConverter, then import DXF.
        guard ODADWGConverter.isAvailable else {
            throw ODADWGConvertError.converterNotFound
        }
        let tempDXF = FileManager.default.temporaryDirectory
            .appendingPathComponent("dwg-import-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempDXF) }

        try ODADWGConverter.convertSync(input: url, output: tempDXF, toFormat: "DXF")
        try importDXF(url: tempDXF)
    }

    @MainActor
    public func importDWG(data: Data) throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("import_\(UUID().uuidString).dwg")
        try data.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        try importDWG(url: tmpFile)
    }

    /// Bulk import with full EAB metadata: layers, blocks, entities, constraints, solved transforms, and unit.
    /// Loads data without creating an undo entry (undo stack starts empty after file open).
    public func importEAB(
        layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
        constraints: [CADConstraint] = [],
        solvedTransforms: [UUID: Transform3D] = [:],
        unit: CADUnit = .millimeter,
        textStyles: [String: CADTextStyle] = ["Standard": .standard],
        dimensionStyles: [String: CADDimensionStyle] = [:],
        leaderStyles: [String: CADLeaderStyle] = ["Standard": .standard],
        currentLeaderStyleName: String = "Standard",
        linetypePatterns: [String: [Double]] = [:],
        globalLineTypeScale: Double = 1.0,
        autoContrastTrueColor: Bool = true,
        activeLayerID: UUID? = nil,
        imageStore: [String: CADImageAsset] = [:],
        xrefHostFolder: String? = nil,
        unloadedXrefs: Set<UUID> = [],
        imageDefinitions: [CADImageDefinition] = [],
        pdfDefinitions: [CADPdfDefinition] = []
    ) {
        self.unit = unit
        self.xrefSourceFolder = xrefHostFolder
        self.eabUnloadedXrefHandles = unloadedXrefs
        self.textStyles = textStyles.isEmpty ? ["Standard": .standard] : textStyles
        self.dimensionStyles = dimensionStyles
        self.leaderStyles = leaderStyles.isEmpty ? ["Standard": .standard] : leaderStyles
        self.currentLeaderStyleName = self.leaderStyles.keys.first(where: { $0.caseInsensitiveCompare(currentLeaderStyleName) == .orderedSame }) ?? "Standard"
        self.linetypePatterns = linetypePatterns
        self.globalLineTypeScale = globalLineTypeScale
        self.autoContrastTrueColor = autoContrastTrueColor
        self.imageStore = imageStore
        importMediaDefinitions(image: imageDefinitions, pdf: pdfDefinitions)
        for layer in layers { layerTable[layer.handle] = layer }
        if let activeID = activeLayerID {
            self.activeLayerID = activeID
        } else if self.activeLayerID == nil, let first = layers.first {
            self.activeLayerID = first.handle
        }
        for block in blocks { blockTable[block.handle] = block }
        for constraint in constraints { constraintTable[constraint.handle] = constraint }
        self.solvedTransforms = solvedTransforms
        for entity in entities {
            var e = entity
            if let bid = e.blockID, let block = blockTable[bid] {
                e.localBoundingBox = block.localBoundingBox
                e.updateAnchorCache(from: block.geometry)
            }
            entityRegistry[e.handle] = e
        }
        savedRevision = editRevision  // freshly loaded — not dirty
        needsRegeneration = true
        rebuildEntityGrid()
    }

    public func importEAB(
        layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
        constraints: [CADConstraint] = [],
        solvedTransforms: [UUID: Transform3D] = [:],
        unit: CADUnit = .millimeter,
        textStyleFonts: [String: String],
        dimensionStyles: [String: CADDimensionStyle] = [:],
        leaderStyles: [String: CADLeaderStyle] = ["Standard": .standard],
        currentLeaderStyleName: String = "Standard",
        linetypePatterns: [String: [Double]] = [:],
        globalLineTypeScale: Double = 1.0,
        autoContrastTrueColor: Bool = true,
        activeLayerID: UUID? = nil,
        imageStore: [String: CADImageAsset] = [:]
    ) {
        let styles = Dictionary(uniqueKeysWithValues: textStyleFonts.map { name, font in
            (name, CADTextStyle(name: name, fontFile: font).normalized)
        })
        importEAB(
            layers: layers,
            blocks: blocks,
            entities: entities,
            constraints: constraints,
            solvedTransforms: solvedTransforms,
            unit: unit,
            textStyles: styles.isEmpty ? ["Standard": .standard] : styles,
            dimensionStyles: dimensionStyles,
            leaderStyles: leaderStyles,
            currentLeaderStyleName: currentLeaderStyleName,
            linetypePatterns: linetypePatterns,
            globalLineTypeScale: globalLineTypeScale,
            autoContrastTrueColor: autoContrastTrueColor,
            activeLayerID: activeLayerID,
            imageStore: imageStore)
    }

    // MARK: - Snapshot / Restore

    public func snapshot(
        dxfRoundTripPayloadFallback: DXFRoundTripPayload? = nil
    ) -> CADDocumentSnapshot {
        // Validate internal dictionaries haven't been corrupted
        let entityCount = entityRegistry.count
        let layerCount = layerTable.count
        _ = blockTable.count
        guard entityCount < 10_000_000 else {
            print("[CADDocument] FATAL: entityRegistry.count = \(entityCount) — possible memory corruption, refusing snapshot")
            return CADDocumentSnapshot(
                layers: [:], blocks: [:], entities: [:], constraints: [:],
                solvedTransforms: [:], activeLayerID: nil, unit: unit,
                textStyles: ["Standard": .standard], dimensionStyles: [:],
                leaderStyles: ["Standard": .standard], currentLeaderStyleName: "Standard", linetypePatterns: [:],
                imageAssetNames: [])
        }
        guard layerCount < 100_000 else {
            print("[CADDocument] FATAL: layerTable.count = \(layerCount) — possible memory corruption")
            return CADDocumentSnapshot(
                layers: [:], blocks: [:], entities: [:], constraints: [:],
                solvedTransforms: [:], activeLayerID: nil, unit: unit,
                textStyles: ["Standard": .standard], dimensionStyles: [:],
                leaderStyles: ["Standard": .standard], currentLeaderStyleName: "Standard", linetypePatterns: [:],
                imageAssetNames: [])
        }

        // Collect asset names from all entities and blocks
        var names = Set<String>()
        for entity in entityRegistry.values {
            if let geom = entity.localGeometry {
                for prim in geom {
                    if case .image(_, _, _, let name, _, _) = prim {
                        names.insert(name)
                    }
                }
            }
        }
        for block in blockTable.values {
            for prim in block.geometry {
                if case .image(_, _, _, let name, _, _) = prim {
                    names.insert(name)
                }
            }
        }
        return CADDocumentSnapshot(
            layers: layerTable, blocks: blockTable,
            entities: entityRegistry, constraints: constraintTable,
            solvedTransforms: solvedTransforms,
            activeLayerID: activeLayerID, unit: unit,
            textStyles: textStyles,
            dimensionStyles: dimensionStyles,
            leaderStyles: leaderStyles,
            currentLeaderStyleName: currentLeaderStyleName,
            linetypePatterns: linetypePatterns,
            globalLineTypeScale: globalLineTypeScale,
            autoContrastTrueColor: autoContrastTrueColor,
            dxfRoundTripPayload: dxfRoundTripPayload ?? dxfRoundTripPayloadFallback,
            imageAssetNames: names,
            xrefFadePercent: xrefFadePercent,
            imageDefinitions: imageDefinitions,
            pdfDefinitions: pdfDefinitions,
            availableImageAssetNames: Set(imageStore.keys),
            layoutSettings: layoutSettings
        )
    }

    /// Snapshot for rendering / PDF / save: loaded xref shadow blocks
    /// replace their (empty) descriptor blocks. Undo must use the pure
    /// `snapshot()` — shadow geometry is runtime state, and the DXF/EAB
    /// writers skip descriptor-block bodies regardless.
    public func renderSnapshot(
        dxfRoundTripPayloadFallback: DXFRoundTripPayload? = nil
    ) -> CADDocumentSnapshot {
        documentLock.withLock {
            let base = snapshot(dxfRoundTripPayloadFallback: dxfRoundTripPayloadFallback)
        var blocks = base.blocks
        var merged = false
        if let store = xrefRuntimeStore {
            for (handle, block) in blocks where block.isXref {
                if let shadow = store.shadowBlock(for: handle) {
                    blocks[handle] = shadow
                    merged = true
                }
            }
        }
        var available = base.availableImageAssetNames
        if let mediaRuntimeStore {
            let loadedNames = Set(mediaRuntimeStore.loadedAssets().keys)
            if !loadedNames.isSubset(of: available) {
                available.formUnion(loadedNames)
                merged = true
            }
        }
        guard merged else { return base }
        return CADDocumentSnapshot(
            layers: base.layers, blocks: blocks, entities: base.entities,
            constraints: base.constraints, solvedTransforms: base.solvedTransforms,
            activeLayerID: base.activeLayerID, unit: base.unit,
            textStyles: base.textStyles, dimensionStyles: base.dimensionStyles,
            leaderStyles: base.leaderStyles,
            currentLeaderStyleName: base.currentLeaderStyleName,
            linetypePatterns: base.linetypePatterns,
            globalLineTypeScale: base.globalLineTypeScale,
            autoContrastTrueColor: base.autoContrastTrueColor,
            dxfRoundTripPayload: base.dxfRoundTripPayload,
            imageAssetNames: base.imageAssetNames,
            xrefFadePercent: base.xrefFadePercent,
            imageDefinitions: base.imageDefinitions,
            pdfDefinitions: base.pdfDefinitions,
            availableImageAssetNames: available,
            layoutSettings: base.layoutSettings)
        }
    }

    /// Build a save-specific snapshot that includes referenced image assets.
    /// Image names are collected from all entities AND all blocks (including nested).
    public func buildSaveSnapshot(
        viewName: String,
        viewKind: DXFDrawingViewKind,
        cameraState: CameraState,
        dxfRoundTripPayloadFallback: DXFRoundTripPayload? = nil,
        sourceFolderPath: String? = nil,
        unloadedXrefHandles: Set<UUID> = []
    ) -> SaveDocumentSnapshot {
        let docSnap = renderSnapshot(
            dxfRoundTripPayloadFallback: dxfRoundTripPayloadFallback)
        // Collect referenced image names from entities and blocks
        var referencedNames = docSnap.imageAssetNames
        for block in blockTable.values {
            for prim in block.geometry {
                if case .image(_, _, _, let name, _, _) = prim { referencedNames.insert(name) }
            }
        }
        let imageAssets = imageStore.filter { referencedNames.contains($0.key) }
        return SaveDocumentSnapshot(
            viewName: viewName, viewKind: viewKind,
            cameraState: cameraState, docSnapshot: docSnap,
            imageAssets: imageAssets,
            sourceFolderPath: sourceFolderPath ?? xrefSourceFolder,
            unloadedXrefHandles: unloadedXrefHandles
        )
    }

    public func restore(from snapshot: CADDocumentSnapshot) {
        blockGridCache.removeAll()
        layerTable = snapshot.layers
        blockTable = snapshot.blocks
        entityRegistry = snapshot.entities
        constraintTable = snapshot.constraints
        solvedTransforms = snapshot.solvedTransforms
        activeLayerID = snapshot.activeLayerID
        unit = snapshot.unit
        textStyles = snapshot.textStyles
        dimensionStyles = snapshot.dimensionStyles
        leaderStyles = snapshot.leaderStyles
        currentLeaderStyleName = snapshot.currentLeaderStyleName
        linetypePatterns = snapshot.linetypePatterns
        globalLineTypeScale = snapshot.globalLineTypeScale
        autoContrastTrueColor = snapshot.autoContrastTrueColor
        dxfRoundTripPayload = snapshot.dxfRoundTripPayload
        imageDefinitions = snapshot.imageDefinitions
        pdfDefinitions = snapshot.pdfDefinitions
        layoutSettings = snapshot.layoutSettings
        // Prune image assets no longer referenced by any entity after restore
        pruneUnreferencedImageAssets()
        resyncXrefInstanceBounds()
        resyncMediaInstanceBounds()
        markEdited(regenerate: true)
        invalidateEntityGrid()   // entity set changed wholesale; rebuild lazily on next hit-test
    }

    public func undo() {
        let currentSnapshot = snapshot()
        guard let prev = undoManager.popUndo(currentSnapshot: currentSnapshot) else { return }
        restore(from: prev)
    }

    public func redo() {
        let currentSnapshot = snapshot()
        guard let next = undoManager.popRedo(currentSnapshot: currentSnapshot) else { return }
        restore(from: next)
    }
    public func pushUndo() { undoManager.pushUndoGrouped(snapshot()) }

    /// Records a snapshot captured before an interactive live edit.
    public func pushUndo(_ snapshot: CADDocumentSnapshot) {
        undoManager.pushUndoGrouped(snapshot)
    }
}