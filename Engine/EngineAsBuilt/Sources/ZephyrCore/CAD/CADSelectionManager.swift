import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADSelectionManager
//
// Manages entity selection state and delegates hit-testing, rect-select,
// and grip generation to companion types:
//   - CADHitTesting   — point-click hit tests, closest-entity queries
//   - CADRectSelect   — window/crossing rectangle selection + geometry tests
//   - CADGripSystem    — grip generation and grip hit-testing
//
// Key responsibilities retained here:
//   - Track selected entity handles (Set<UUID>)
//   - Selection mutation: select, toggle, add, remove, clear, selectAll
//   - Transform operations on selection: move, rotate, scale (with undo)
//   - Collective center computation
//   - Selection generation tracking (for render-cache invalidation)
// =========================================================================

@MainActor
public final class CADSelectionManager {
    // MARK: - Shared Enums

    public enum RectSelectMode { case replace, add, subtract }
    public enum RectSelectStyle { case window, crossing }
    public enum GripType: Equatable {
        case center, rotation
        case corner(index: Int)
        /// Vertex grip on a specific entity's geometry point.
        case vertex(entity: UUID, index: Int)
        /// Midpoint grip between two consecutive vertices of an entity's polyline.
        case midpoint(entity: UUID, betweenA: Int, andB: Int)
    }

    // MARK: - Selection State

    public var selectedHandles: Set<UUID> = []
    /// The most recently individually-clicked entity handle (not set by
    /// rect-select or selectAll). Used by the properties panel to determine
    /// which entity's properties to show.
    public internal(set) var lastSelectedHandle: UUID? = nil
    /// Incremented on every selection change. Used by the render loop
    /// to invalidate the cached grip geometry.
    public internal(set) var _selectionGeneration: Int = 0

    private func _markSelectionChanged() { _selectionGeneration &+= 1 }

    public init() {}

    // MARK: - Selection Mutation

    public func select(_ handle: UUID?) {
        selectedHandles.removeAll()
        if let h = handle { selectedHandles.insert(h); lastSelectedHandle = h }
        else { lastSelectedHandle = nil }
        _markSelectionChanged()
    }

    public func toggleSelect(_ handle: UUID?) {
        guard let h = handle else { return }
        if selectedHandles.contains(h) {
            selectedHandles.remove(h)
            if lastSelectedHandle == h { lastSelectedHandle = nil }
        } else {
            selectedHandles.insert(h)
            lastSelectedHandle = h
        }
        _markSelectionChanged()
    }

    /// Add a handle to the selection set (AutoCAD default click behavior).
    public func addToSelection(_ handle: UUID) {
        selectedHandles.insert(handle)
        lastSelectedHandle = handle
        _markSelectionChanged()
    }

    /// Remove a handle from the selection set (AutoCAD shift+click behavior).
    public func removeFromSelection(_ handle: UUID) {
        selectedHandles.remove(handle)
        if lastSelectedHandle == handle { lastSelectedHandle = nil }
        _markSelectionChanged()
    }

    public func isSelected(_ handle: UUID) -> Bool { selectedHandles.contains(handle) }

    public func clearSelection() {
        selectedHandles.removeAll()
        lastSelectedHandle = nil
        _markSelectionChanged()
    }

    public var hasSelection: Bool { !selectedHandles.isEmpty }
    public var selectedCount: Int { selectedHandles.count }

    /// Select all visible entities in the document.
    public func selectAll(in document: CADDocument) {
        selectedHandles.removeAll()
        lastSelectedHandle = nil
        for entity in document.entitiesView {
            guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
            selectedHandles.insert(entity.handle)
            lastSelectedHandle = entity.handle
        }
        _markSelectionChanged()
    }

    // MARK: - Hit Testing (Delegated)

    /// Returns the handle of the entity CLOSEST to the click point (by
    /// distance to geometry). Delegates to `CADHitTesting.hitTest`.
    public func hitTest(
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> UUID? {
        return CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: document,
            threshold: threshold,
            simplifyComplexBlocks: simplifyComplexBlocks)
    }

    /// Returns the entity closest to the given world point (for hover
    /// highlighting). Delegates to `CADHitTesting.closestEntity`.
    public func closestEntity(
        at worldX: Double, _ worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> UUID? {
        return CADHitTesting.closestEntity(
            at: worldX, worldY,
            document: document,
            threshold: threshold,
            simplifyComplexBlocks: simplifyComplexBlocks)
    }

    /// Returns all entities whose geometry is within threshold of the point.
    /// Used for the multi-hit popup when entities overlap.
    public func allHitsAt(
        worldX: Double, worldY: Double,
        document: CADDocument,
        simplifyComplexBlocks: Bool = true
    ) -> [(handle: UUID, label: String)] {
        return CADHitTesting.allHitsAt(
            worldX: worldX, worldY: worldY,
            document: document,
            simplifyComplexBlocks: simplifyComplexBlocks)
    }

    /// Returns true if the entity's geometry is within threshold of the point.
    public func hitEntity(
        _ entity: CADEntity,
        point: Vector3,
        threshold: Double,
        document: CADDocument,
        simplifyComplexBlocks: Bool = true
    ) -> Bool {
        return CADHitTesting.hitEntity(
            entity, point: point, threshold: threshold,
            document: document,
            simplifyComplexBlocks: simplifyComplexBlocks)
    }

    // MARK: - Rectangle Select (Delegated)

    /// Returns the set of handles that fall inside the given rectangle,
    /// without modifying the current selection.
    public func handlesInRect(
        worldX: Double, worldY: Double,
        worldW: Double, worldH: Double,
        document: CADDocument,
        style: RectSelectStyle
    ) -> Set<UUID> {
        return CADRectSelect.handlesInRect(
            worldX: worldX, worldY: worldY,
            worldW: worldW, worldH: worldH,
            document: document, style: style)
    }

    /// Modifies the selection set based on a rectangle selection.
    public func selectInRect(
        worldX: Double, worldY: Double,
        worldW: Double, worldH: Double,
        document: CADDocument,
        mode: RectSelectMode,
        style: RectSelectStyle
    ) {
        if mode == .replace {
            selectedHandles.removeAll()
            lastSelectedHandle = nil
        }
        let before = selectedHandles
        CADRectSelect.selectInRect(
            worldX: worldX, worldY: worldY,
            worldW: worldW, worldH: worldH,
            document: document,
            mode: mode, style: style,
            into: &selectedHandles)
        // Update lastSelectedHandle to one of the newly-added handles if any.
        let added = selectedHandles.subtracting(before)
        if let first = added.first {
            lastSelectedHandle = first
        }
        _markSelectionChanged()
    }

    // MARK: - Transform Operations

    public func collectiveCenter(document: CADDocument) -> Vector3? {
        return document.collectiveCenter(for: selectedHandles)
    }

    public func moveAllSelected(by delta: Vector3, document: CADDocument) {
        document.moveEntities(handles: selectedHandles, by: delta)
    }

    public func moveAllSelectedLive(by delta: Vector3, document: CADDocument) {
        document.moveEntitiesLive(handles: selectedHandles, by: delta)
    }

    public func rotateAllSelected(
        around center: Vector3, angleDeltaRadians: Double, document: CADDocument
    ) {
        document.rotateEntities(
            handles: selectedHandles, around: center, angleDeltaRadians: angleDeltaRadians)
    }

    public func rotateAllSelectedLive(
        around center: Vector3, angleDeltaRadians: Double, document: CADDocument
    ) {
        document.rotateEntitiesLive(
            handles: selectedHandles, around: center, angleDeltaRadians: angleDeltaRadians)
    }

    public func scaleAllSelected(
        around center: Vector3, factor: Double, document: CADDocument
    ) {
        document.scaleEntities(handles: selectedHandles, around: center, factor: factor)
    }

    public func scaleAllSelectedLive(
        around center: Vector3, factor: Double, document: CADDocument
    ) {
        document.scaleEntitiesLive(handles: selectedHandles, around: center, factor: factor)
    }

    public func deleteSelected(in document: CADDocument) {
        document.removeEntities(handles: selectedHandles)
        selectedHandles.removeAll()
        _markSelectionChanged()
    }

    public func boundingBox(_ handle: UUID, document: CADDocument) -> BoundingBox3D? {
        return document.entity(for: handle)?.worldBoundingBox
    }

    // MARK: - Grip System (Delegated)

    public struct CadGripInfo {
        public let handle: UUID
        public let grip: GripType
        public let screenPos: SDL_FPoint
        public var worldPos: Vector3  // var: mutated incrementally during grip drag
    }

    /// Returns the grip (if any) at the given screen position. Delegates to
    /// `CADGripSystem.gripHitTest`.
    public func gripHitTest(
        screenX: Float, screenY: Float,
        document: CADDocument,
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true
    ) -> CadGripInfo? {
        return CADGripSystem.gripHitTest(
            screenX: screenX, screenY: screenY,
            document: document, cam: cam,
            simplifyComplexBlocks: simplifyComplexBlocks,
            selectedHandles: self.selectedHandles)
    }

    /// Returns world-space vertex arrays for an entity's geometry (for hover
    /// outline drawing). Delegates to `CADGripSystem.worldGeometryPoints`.
    public func worldGeometryPoints(
        for handle: UUID, document: CADDocument
    ) -> [[Vector3]] {
        return CADGripSystem.worldGeometryPoints(for: handle, document: document)
    }

    /// Generates all grips for the currently selected entities. Delegates to
    /// `CADGripSystem.getAllGrips`.
    public func getAllGrips(
        document: CADDocument,
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true
    ) -> [CadGripInfo] {
        return CADGripSystem.getAllGrips(
            document: document, cam: cam,
            simplifyComplexBlocks: simplifyComplexBlocks,
            selectedHandles: selectedHandles)
    }

    /// Same as `getAllGrips` but uses pre-computed world-space points.
    public func getAllGripsFromPoints(
        entityPoints: [(handle: UUID, pointGroups: [[Vector3]])],
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true
    ) -> [CadGripInfo] {
        return CADGripSystem.getAllGripsFromPoints(
            entityPoints: entityPoints, cam: cam,
            simplifyComplexBlocks: simplifyComplexBlocks)
    }

    /// Returns the 4 oriented world-space corners of an entity's bounding box.
    public func getOrientedCorners(
        _ handle: UUID, document: CADDocument
    ) -> [Vector3]? {
        return CADGripSystem.getOrientedCorners(handle, document: document)
    }
}
