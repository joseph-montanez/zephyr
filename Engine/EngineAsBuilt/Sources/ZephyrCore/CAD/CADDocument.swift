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
    public let textStyleFonts: [String: String]
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
        textStyleFonts: [String: String],
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
        self.textStyleFonts = textStyleFonts
        self.linetypePatterns = linetypePatterns
        self.imageAssetNames = imageAssetNames
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
    /// The editRevision at the moment the snapshot was taken.
    /// Used by markSaved(upTo:) to avoid clearing dirty if user edited during save.
    public let editRevision: UInt64
    /// File format version for the exporter to embed in output.
    public let formatVersion: UInt32
    /// Application version string.
    public let appVersion: String

    public init(tabID: UUID, drawingViews: [SaveDocumentSnapshot], fileURL: URL?,
                displayName: String, editRevision: UInt64,
                formatVersion: UInt32, appVersion: String) {
        self.tabID = tabID
        self.drawingViews = drawingViews
        self.fileURL = fileURL
        self.displayName = displayName
        self.editRevision = editRevision
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

    /// Maps DXF text style names to their primary font file names (e.g. "Standard" -> "txt.shx").
    public var textStyleFonts: [String: String] = [:]

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

    public init() {}

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
        block.updateBoundingBox()
        blockTable[handle] = block
        for (entityHandle, var entity) in entityRegistry where entity.blockID == handle {
            entity.localBoundingBox = block.localBoundingBox
            entity.updateAnchorCache(from: geometry)
            entityRegistry[entityHandle] = entity
        }
        markEdited(regenerate: true)
        invalidateEntityGrid()   // instance world boxes changed
    }

    // MARK: - Entity Operations

    public func addEntity(_ entity: CADEntity) {
        pushUndo()
        var e = entity
        if let bid = e.blockID, let block = blockTable[bid] {
            e.localBoundingBox = block.localBoundingBox
            e.updateAnchorCache(from: block.geometry)
        }
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
        for var entity in entities {
            if let bid = entity.blockID, let block = blockTable[bid] {
                entity.localBoundingBox = block.localBoundingBox
                entity.updateAnchorCache(from: block.geometry)
            }
            entityRegistry[entity.handle] = entity
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
            if let block = blockTable[origBlockID] {
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

    public func updateTransform(for handle: UUID, to newTransform: Transform3D) {
        pushUndo()
        guard var entity = entityRegistry[handle] else { return }
        entity.transform = newTransform
        entityRegistry[handle] = entity
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    public func updateTransformLive(for handle: UUID, to newTransform: Transform3D) {
        guard var entity = entityRegistry[handle] else { return }
        entity.transform = newTransform
        entityRegistry[handle] = entity
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
        markEdited(regenerate: true)
        invalidateEntityGrid()
    }

    /// Update entity without pushing undo — for live property editing.
    public func updateEntityLive(_ entity: CADEntity) {
        guard entityRegistry[entity.handle] != nil else { return }
        var updated = entity
        updated.localBoundingBox = CADEntity.computeLocalBoundingBox(blockID: updated.blockID, localGeometry: updated.localGeometry)
        updated.updateAnchorCache()
        entityRegistry[updated.handle] = updated
        // Don't invalidate grid or push undo.
        markEdited(regenerate: true)
    }

    /// Update entity with undo.
    public func updateEntity(_ entity: CADEntity) {
        pushUndo()
        guard entityRegistry[entity.handle] != nil else { return }
        var updated = entity
        updated.localBoundingBox = CADEntity.computeLocalBoundingBox(blockID: updated.blockID, localGeometry: updated.localGeometry)
        updated.updateAnchorCache()
        entityRegistry[updated.handle] = updated
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
        // Don't invalidate entity grid during live drag — only on finalize
    }

    /// Update block geometry without pushing undo — for live grip editing.
    public func updateBlockGeometryLive(handle: UUID, geometry: [CADPrimitive]) {
        guard var block = blockTable[handle] else { return }
        block.geometry = geometry
        block.updateBoundingBox()
        blockTable[handle] = block
        for (entityHandle, var entity) in entityRegistry where entity.blockID == handle {
            entity.localBoundingBox = block.localBoundingBox
            entity.updateAnchorCache(from: geometry)
            entityRegistry[entityHandle] = entity
        }
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
            entityRegistry[handle] = entity
        }
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
            entityRegistry[handle] = entity
        }
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
            entityRegistry[handle] = entity
        }
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
            entityRegistry[handle] = entity
        }
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
            entityRegistry[handle] = entity
        }
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
            entityRegistry[handle] = entity
        }
    }

    /// Atomically remove a set of entities and insert replacements in one undo step.
    /// Used by JOIN and similar commands that merge multiple entities into one.
    public func replaceEntities(remove handles: Set<UUID>, add newEntities: [CADEntity]) {
        guard !handles.isEmpty || !newEntities.isEmpty else { return }
        pushUndo()
        for handle in handles {
            entityRegistry.removeValue(forKey: handle)
        }
        for var entity in newEntities {
            if let bid = entity.blockID, let block = blockTable[bid] {
                entity.localBoundingBox = block.localBoundingBox
                entity.updateAnchorCache(from: block.geometry)
            }
            entityRegistry[entity.handle] = entity
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
        for layer in layers { layerTable[layer.handle] = layer }
        if activeLayerID == nil, let first = layers.first { activeLayerID = first.handle }
        for block in blocks { blockTable[block.handle] = block }
        for entity in entities {
            var e = entity
            if let bid = e.blockID, let block = blockTable[bid] {
                e.localBoundingBox = block.localBoundingBox
                e.updateAnchorCache(from: block.geometry)
            }
            entityRegistry[e.handle] = e
        }
        markEdited(regenerate: true)
        rebuildEntityGrid()   // build eagerly so the first hover doesn't pay for it
    }

    @MainActor
    public func importDXF(url: URL) throws {
        let (layers, blocks, entities, textStyleFonts, linetypePatterns) = try DXFImporter.importDXF(filePath: url.path)

        for font in Set(textStyleFonts.values) {
            CADFontManager.debugFontLookup(font)
        }

        self.textStyleFonts = textStyleFonts
        self.linetypePatterns = linetypePatterns
        for layer in layers { layerTable[layer.handle] = layer }
        if activeLayerID == nil, let first = layers.first { activeLayerID = first.handle }
        for block in blocks { blockTable[block.handle] = block }
        for entity in entities { entityRegistry[entity.handle] = entity }
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

    /// Bulk import with full EAB metadata: layers, blocks, entities, constraints, solved transforms, and unit.
    /// Loads data without creating an undo entry (undo stack starts empty after file open).
    public func importEAB(
        layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
        constraints: [CADConstraint] = [],
        solvedTransforms: [UUID: Transform3D] = [:],
        unit: CADUnit = .millimeter,
        textStyleFonts: [String: String] = [:],
        linetypePatterns: [String: [Double]] = [:],
        activeLayerID: UUID? = nil,
        imageStore: [String: CADImageAsset] = [:]
    ) {
        self.unit = unit
        self.textStyleFonts = textStyleFonts
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

    // MARK: - Snapshot / Restore

    public func snapshot() -> CADDocumentSnapshot {
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
            textStyleFonts: textStyleFonts,
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
        textStyleFonts = snapshot.textStyleFonts
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
