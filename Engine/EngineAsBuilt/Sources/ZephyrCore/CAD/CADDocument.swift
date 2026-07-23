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
    public let linetypePatterns: [String: [Double]]
    /// Names of image assets currently referenced by entities (not the raw Data blobs).
    /// The actual `imageStore` lives on `CADDocument` and persists across undo/redo.
    public let imageAssetNames: Set<String>

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
        linetypePatterns: [String: [Double]] = [:],
        imageAssetNames: Set<String> = []
    ) {
        self.layers = layers
        self.blocks = blocks
        self.entities = entities
        self.constraints = constraints
        self.solvedTransforms = solvedTransforms
        self.activeLayerID = activeLayerID
        self.unit = unit
        self.textStyles = textStyles
        self.dimensionStyles = dimensionStyles
        self.linetypePatterns = linetypePatterns
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
        linetypePatterns: [String: [Double]] = [:],
        imageAssetNames: Set<String> = []
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
            linetypePatterns: linetypePatterns,
            imageAssetNames: imageAssetNames)
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

    public init(viewName: String, viewKind: DXFDrawingViewKind,
                cameraState: CameraState, docSnapshot: CADDocumentSnapshot,
                imageAssets: [String: CADImageAsset]) {
        self.viewName = viewName
        self.viewKind = viewKind
        self.cameraState = cameraState
        self.docSnapshot = docSnapshot
        self.imageAssets = imageAssets
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

    public init(tabID: UUID, drawingViews: [SaveDocumentSnapshot], fileURL: URL?,
                displayName: String, editRevision: UInt64,
                viewEditRevisions: [UInt64] = [],
                formatVersion: UInt32, appVersion: String) {
        self.tabID = tabID
        self.drawingViews = drawingViews
        self.fileURL = fileURL
        self.displayName = displayName
        self.editRevision = editRevision
        self.viewEditRevisions = viewEditRevisions
        self.formatVersion = formatVersion
        self.appVersion = appVersion
    }
}

// =========================================================================
// MARK: - UndoManager
// =========================================================================

public final class UndoManager {
    private var undoStack: [CADDocumentSnapshot] = []
    private var redoStack: [CADDocumentSnapshot] = []

    public var maxDepth: Int = 256

    public init() {}

    public func pushUndo(_ snapshot: CADDocumentSnapshot) {
        undoStack.append(snapshot)
        if maxDepth > 0, undoStack.count > maxDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func popUndo(currentSnapshot: CADDocumentSnapshot) -> CADDocumentSnapshot? {
        guard !undoStack.isEmpty else { return nil }
        redoStack.append(currentSnapshot)
        return undoStack.removeLast()
    }

    public func popRedo(currentSnapshot: CADDocumentSnapshot) -> CADDocumentSnapshot? {
        guard !redoStack.isEmpty else { return nil }
        undoStack.append(currentSnapshot)
        return redoStack.removeLast()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var undoDepth: Int { undoStack.count }
    public var redoDepth: Int { redoStack.count }
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

    /// DXF linetype dash pattern definitions (e.g. "DASHED" -> [10.0, 5.0]).
    /// Key is the uppercased linetype name. Saved/loaded in EAB for accurate round-trip.
    public var linetypePatterns: [String: [Double]] = [:]

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
        if regenerate { needsRegeneration = true }
    }

    /// Call for render/cache-only invalidation (palette change, theme toggle).
    public func markNeedsRegeneration() {
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
        if let blockID = result.blockID, let block = blockTable[blockID] {
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
            } else {
                result.localBoundingBox = block.localBoundingBox
                result.updateAnchorCache(from: block.geometry)
            }
        } else if result.arrayData == nil {
            result.localBoundingBox = CADEntity.computeLocalBoundingBox(
                blockID: result.blockID,
                localGeometry: result.localGeometry) ?? result.localBoundingBox
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
        pushUndo()
        guard var block = blockTable[handle] else { return }
        block.geometry = geometry
        block.primitiveStyles.removeAll(keepingCapacity: false)
        block.primitiveXData.removeAll(keepingCapacity: false)
        block.updateBoundingBox()
        blockTable[handle] = block
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
        pushUndo()
        let e = preparedEntityForStorage(entity)
        entityRegistry[e.handle] = e
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    /// Batch-insert multiple entities under a single undo snapshot.
    /// Use this when creating multi-segment lines, exploded blocks, etc.
    /// to avoid pushing one snapshot per entity.
    public func addEntities(_ entities: [CADEntity]) {
        guard !entities.isEmpty else { return }
        pushUndo()
        for entity in entities {
            let prepared = preparedEntityForStorage(entity)
            entityRegistry[prepared.handle] = prepared
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func removeEntity(handle: UUID) {
        pushUndo()
        entityRegistry.removeValue(forKey: handle)
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    // MARK: - Entity Duplication (for COPY / PASTE commands)

    /// Deep-copy a set of entities, generating new UUIDs for each entity and
    /// their referenced blocks. Returns the duplicated entities ready to be
    /// added to the document via `addEntity(_:)`.
    ///
    /// - Parameters:
    ///   - handles: The entity handles to duplicate.
    ///   - offset: A translation applied to each duplicated entity's transform
    ///     (e.g., to offset from original for COPY, or from base-point for PASTECLIP).
    /// - Returns: The duplicated entities with fresh UUID handles and optional
    ///   block remapping. Caller is responsible for adding entities and blocks
    ///   to the document.
    public func duplicateEntities(
        handles: Set<UUID>,
        offset: Vector3 = .zero
    ) -> (entities: [CADEntity], blockRemap: [UUID: UUID]) {
        var newEntities: [CADEntity] = []
        var blockRemap: [UUID: UUID] = [:]

        // First pass: collect all referenced block IDs so we can remap them.
        var referencedBlockIDs = Set<UUID>()
        for handle in handles {
            guard let entity = entityRegistry[handle] else { continue }
            if let bid = entity.blockID {
                referencedBlockIDs.insert(bid)
            }
        }

        // Remap block UUIDs by copying the block definitions with new handles.
        // (The caller is expected to add these new blocks to the document.)
        for origBlockID in referencedBlockIDs {
            if blockTable[origBlockID] != nil {
                let newBlockID = UUID()
                blockRemap[origBlockID] = newBlockID
            }
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

        return (newEntities, blockRemap)
    }

    public func entity(for handle: UUID) -> CADEntity? {
        entityRegistry[handle]
    }

    // Legacy Array copy (Avoid using in performance loops)
    public var allEntities: [CADEntity] { Array(entityRegistry.values) }

    // Fast O(1) properties for UI and Rendering
    public var entityCount: Int { entityRegistry.count }
    public var entitiesView: Dictionary<UUID, CADEntity>.Values { entityRegistry.values }

    /// World-space bounds of geometry that can actually be drawn in the current document.
    /// This walks the renderable primitives instead of trusting cached entity boxes so rotated
    /// text, SHX glyphs, dimension blocks, arcs, ellipses, and splines match what is displayed.
    public func renderableWorldBoundingBox(visibleLayersOnly: Bool = true) -> BoundingBox3D? {
        var bounds = CADRenderBoundsAccumulator()

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
                    backgroundScale: entityBackgroundScale,
                    hasVisibleBackground: entityBackgroundUsesViewportColor || entityHasBackgroundColor,
                    into: &bounds)
                continue
            }

            let geometry: [CADPrimitive]
            let primitiveStyles: [Int: CADPrimitiveStyle]
            if let blockID = entity.blockID {
                guard let block = blockTable[blockID],
                      !block.isInternalTableDisplayBlock,
                      !block.geometry.isEmpty else { continue }
                geometry = block.geometry
                primitiveStyles = block.primitiveStyles
            } else {
                guard let localGeometry = entity.localGeometry,
                      !localGeometry.isEmpty else { continue }
                geometry = localGeometry
                primitiveStyles = [:]
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
                        backgroundScale: backgroundScale,
                        hasVisibleBackground: hasVisibleBackground,
                        into: &bounds)
                }
            }
        }

        return bounds.boundingBox
    }

    private func includePrimitiveRenderBounds(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        backgroundScale: Double?,
        hasVisibleBackground: Bool,
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

        case .image(let insertion, let uAxis, let vAxis, _, let clipBoundary, _):
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
        backgroundScale: Double?,
        hasVisibleBackground: Bool,
        into bounds: inout CADRenderBoundsAccumulator
    ) {
        let textStyle = CADTextStyle.resolve(style, in: textStyles)
        let effectiveHeight = textStyle.fixedHeight > 0 ? textStyle.fixedHeight : height
        guard !text.isEmpty, effectiveHeight.isFinite, effectiveHeight > 0, rotation.isFinite else { return }

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
                widthFactor: textStyle.widthFactor,
                obliqueAngle: textStyle.obliqueAngle,
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
        explodeAssociativeArrays(handles: [handle])
    }

    @discardableResult
    public func explodeAssociativeArrays(handles sourceHandles: Set<UUID>) -> [UUID] {
        var work: [(entity: CADEntity, blockID: UUID, instances: [CADArrayInstance])] = []
        for handle in sourceHandles {
            guard let entity = entityRegistry[handle],
                  let array = entity.arrayData,
                  let blockID = entity.blockID,
                  blockTable[blockID] != nil
            else { continue }
            let path = CADArrayPathResolver.points(
                for: array,
                containerTransform: entity.transform,
                document: self)
            let instances = array.evaluatedInstances(pathPoints: path)
            if !instances.isEmpty { work.append((entity, blockID, instances)) }
        }
        guard !work.isEmpty else { return [] }

        pushUndo()
        var newHandles: [UUID] = []
        newHandles.reserveCapacity(work.reduce(0) { $0 + $1.instances.count })
        for item in work {
            entityRegistry.removeValue(forKey: item.entity.handle)
            for instance in item.instances {
                var copy = CADEntity(
                    layerID: item.entity.layerID,
                    blockID: item.blockID,
                    transform: item.entity.transform.multiplying(by: instance.transform),
                    xdata: item.entity.xdata,
                    drawOrder: item.entity.drawOrder)
                copy = preparedEntityForStorage(copy)
                entityRegistry[copy.handle] = copy
                newHandles.append(copy.handle)
            }
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()
        return newHandles
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
        guard let center = collectiveCenter(for: handles) else { return nil }

        pushUndo()

        // Collect world-space geometry from all selected entities
        var worldGeom: [CADPrimitive] = []
        for handle in handles {
            guard let entity = entityRegistry[handle] else { continue }
            if let geom = resolvedGeometry(for: entity) {
                let transformed = CADGeometryMath.transformPrimitives(geom, by: entity.transform)
                worldGeom.append(contentsOf: transformed)
            }
        }
        guard !worldGeom.isEmpty else {
            // Pop the undo entry we just pushed and bail out
            _ = undoManager.popUndo(currentSnapshot: snapshot())
            return nil
        }

        // Transform all world-space geometry to block-local space (relative to center)
        let invTransform = Transform3D.translated(by: Vector3(x: -center.x, y: -center.y, z: -center.z))
        let localGeom = CADGeometryMath.transformPrimitives(worldGeom, by: invTransform)

        // Create the block definition
        var block = CADBlock(name: name, geometry: localGeom)
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

    public func resolvedGeometry(for entity: CADEntity) -> [CADPrimitive]? {
        if let bid = entity.blockID, let block = blockTable[bid] {
            return block.geometry
        }
        return entity.localGeometry
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
        linetypePatterns: [String: [Double]] = [:],
        activeLayerID: UUID? = nil,
        imageStore: [String: CADImageAsset] = [:]
    ) {
        self.unit = unit
        self.textStyles = textStyles.isEmpty ? ["Standard": .standard] : textStyles
        self.dimensionStyles = dimensionStyles
        self.linetypePatterns = linetypePatterns
        self.imageStore = imageStore
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
        linetypePatterns: [String: [Double]] = [:],
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
            linetypePatterns: linetypePatterns,
            activeLayerID: activeLayerID,
            imageStore: imageStore)
    }

    // MARK: - Snapshot / Restore

    public func snapshot() -> CADDocumentSnapshot {
        // Validate internal dictionaries haven't been corrupted
        let entityCount = entityRegistry.count
        let layerCount = layerTable.count
        _ = blockTable.count
        guard entityCount < 10_000_000 else {
            print("[CADDocument] FATAL: entityRegistry.count = \(entityCount) — possible memory corruption, refusing snapshot")
            return CADDocumentSnapshot(
                layers: [:], blocks: [:], entities: [:], constraints: [:],
                solvedTransforms: [:], activeLayerID: nil, unit: unit,
                textStyles: ["Standard": .standard], dimensionStyles: [:], linetypePatterns: [:],
                imageAssetNames: [])
        }
        guard layerCount < 100_000 else {
            print("[CADDocument] FATAL: layerTable.count = \(layerCount) — possible memory corruption")
            return CADDocumentSnapshot(
                layers: [:], blocks: [:], entities: [:], constraints: [:],
                solvedTransforms: [:], activeLayerID: nil, unit: unit,
                textStyles: ["Standard": .standard], dimensionStyles: [:], linetypePatterns: [:],
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
            linetypePatterns: linetypePatterns,
            imageAssetNames: names
        )
    }

    /// Build a save-specific snapshot that includes referenced image assets.
    /// Image names are collected from all entities AND all blocks (including nested).
    public func buildSaveSnapshot(viewName: String, viewKind: DXFDrawingViewKind,
                                   cameraState: CameraState) -> SaveDocumentSnapshot {
        let docSnap = snapshot()
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
            imageAssets: imageAssets
        )
    }

    public func restore(from snapshot: CADDocumentSnapshot) {
        layerTable = snapshot.layers
        blockTable = snapshot.blocks
        entityRegistry = snapshot.entities
        constraintTable = snapshot.constraints
        solvedTransforms = snapshot.solvedTransforms
        activeLayerID = snapshot.activeLayerID
        unit = snapshot.unit
        textStyles = snapshot.textStyles
        dimensionStyles = snapshot.dimensionStyles
        linetypePatterns = snapshot.linetypePatterns
        // Prune image assets no longer referenced by any entity after restore
        pruneUnreferencedImageAssets()
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
    public func pushUndo() { undoManager.pushUndo(snapshot()) }

    /// Records a snapshot captured before an interactive live edit.
    public func pushUndo(_ snapshot: CADDocumentSnapshot) {
        undoManager.pushUndo(snapshot)
    }
}
