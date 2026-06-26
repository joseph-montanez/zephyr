import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADGripSystem
//
// Grip generation and hit-testing for the CAD selection manager. Produces
// per-entity vertex grips, midpoint grips, center grips, corner grips, and
// rotation grips. Grips are the small squares that appear on selected entities
// for direct-manipulation editing (move, scale, rotate, vertex drag).
//
// All methods are static and take explicit `document:`, `cam:`, and
// `selectionManager:` parameters so they can be called from both the selection
// manager and the render loop.
// =========================================================================

@MainActor
public enum CADGripSystem {

    // MARK: - Grip Hit Testing

    /// Returns the grip (if any) at the given screen position within a
    /// 10-pixel radius.
    public static func gripHitTest(
        screenX: Float, screenY: Float,
        document: CADDocument,
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true,
        selectedHandles: Set<UUID>? = nil
    ) -> CADSelectionManager.CadGripInfo? {
        let grips = getAllGrips(
            document: document, cam: cam,
            simplifyComplexBlocks: simplifyComplexBlocks,
            selectedHandles: selectedHandles)
        let threshold: Float = 10.0
        var bestDist: Float = threshold * 2
        var best: CADSelectionManager.CadGripInfo? = nil
        for g in grips {
            let dx = Double(g.screenPos.x - screenX)
            let dy = Double(g.screenPos.y - screenY)
            let dist = Float(sqrt(Double(dx * dx + dy * dy)))
            if dist < bestDist {
                bestDist = dist
                best = g
            }
        }
        return best
    }

    // MARK: - Grip Generation

    /// Generates all grips for the currently selected entities.
    /// Returns an array of `CadGripInfo` with screen-space positions computed
    /// from the current camera transform.
    public static func getAllGrips(
        document: CADDocument,
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true,
        selectedHandles: Set<UUID>? = nil
    ) -> [CADSelectionManager.CadGripInfo] {
        let handles = selectedHandles ?? []
        guard !handles.isEmpty else { return [] }

        var results: [CADSelectionManager.CadGripInfo] = []

        for handle in handles {
            guard let entity = document.entity(for: handle) else { continue }
            guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
            guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { continue }

            if simplifyComplexBlocks && geometry.count > 50 { continue }

            // ── Image entities: generate entity-level grips (center + 4 corners)
            //     from the oriented bounding box, for move/scale support.
            if geometry.contains(where: { if case .image = $0 { return true }; return false }) {
                if let corners = getOrientedCorners(handle, document: document) {
                    let center = Vector3(
                        x: corners.map(\.x).reduce(0, +) / Double(corners.count),
                        y: corners.map(\.y).reduce(0, +) / Double(corners.count),
                        z: 0)
                    let sp = EngineCameraManager.worldToScreen(worldX: center.x, worldY: center.y, cam: cam)
                    results.append(CADSelectionManager.CadGripInfo(
                        handle: handle,
                        grip: .center,
                        screenPos: sp, worldPos: center))
                    for (i, pt) in corners.enumerated() {
                        let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .corner(index: i),
                            screenPos: sp, worldPos: pt))
                    }
                }
                continue
            }

            let hasEditableBoundary = geometry.contains { isInvisibleEditBoundary($0) }
            var globalIdx = 0

            for prim in geometry {
                if case .polyline(let path, _) = prim {
                    let worldVertices = path.vertices.map {
                        entity.transform.transformPoint($0.position)
                    }
                    for (index, point) in worldVertices.enumerated() {
                        let screen = EngineCameraManager.worldToScreen(
                            worldX: point.x, worldY: point.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .vertex(entity: handle, index: globalIdx + index),
                            screenPos: screen,
                            worldPos: point))
                    }
                    for segment in 0..<path.segmentCount {
                        let midpoint = entity.transform.transformPoint(
                            path.segmentMidpoint(segment))
                        let screen = EngineCameraManager.worldToScreen(
                            worldX: midpoint.x, worldY: midpoint.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .midpoint(
                                entity: handle,
                                betweenA: globalIdx + segment,
                                andB: globalIdx + path.endVertexIndex(forSegment: segment)),
                            screenPos: screen,
                            worldPos: midpoint))
                    }
                    globalIdx += path.vertices.count
                    continue
                }

                let pts = CADGeometryMath.worldPointsForPrimitive(prim, transform: entity.transform)
                defer { globalIdx += pts.count }
                if hasEditableBoundary && !isInvisibleEditBoundary(prim) { continue }
                guard !pts.isEmpty else { continue }

                for (i, pt) in pts.enumerated() {
                    let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                    results.append(CADSelectionManager.CadGripInfo(
                        handle: handle,
                        grip: .vertex(entity: handle, index: globalIdx + i),
                        screenPos: sp, worldPos: pt))
                }

                if shouldCreateMidpointGrips(for: prim) && pts.count >= 2 {
                    for i in 0..<(pts.count - 1) {
                        let a = pts[i]
                        let b = pts[i + 1]
                        let mid = Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: 0)
                        let sp = EngineCameraManager.worldToScreen(worldX: mid.x, worldY: mid.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .midpoint(entity: handle, betweenA: globalIdx + i,
                                            andB: globalIdx + i + 1),
                            screenPos: sp, worldPos: mid))
                    }
                }
            }
        }

        return results
    }

    /// Same as `getAllGrips` but uses pre-computed world-space points from
    /// render primitives (so grip positions stay in sync after vertex drags).
    ///
    /// - Parameter entityPoints: Array of `(handle, [pointArrays per primitive])`.
    public static func getAllGripsFromPoints(
        entityPoints: [(handle: UUID, pointGroups: [[Vector3]])],
        cam: CameraTransform,
        simplifyComplexBlocks: Bool = true
    ) -> [CADSelectionManager.CadGripInfo] {
        var results: [CADSelectionManager.CadGripInfo] = []
        for (handle, groups) in entityPoints {
            if simplifyComplexBlocks && groups.count > 50 { continue }
            var globalIdx = 0
            for pts in groups {
                guard !pts.isEmpty else { globalIdx += pts.count; continue }
                for (i, pt) in pts.enumerated() {
                    let sp = EngineCameraManager.worldToScreen(worldX: pt.x, worldY: pt.y, cam: cam)
                    results.append(CADSelectionManager.CadGripInfo(
                        handle: handle,
                        grip: .vertex(entity: handle, index: globalIdx + i),
                        screenPos: sp, worldPos: pt))
                }
                if pts.count >= 2 {
                    for i in 0..<(pts.count - 1) {
                        let a = pts[i]
                        let b = pts[i + 1]
                        let mid = Vector3(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: 0)
                        let sp = EngineCameraManager.worldToScreen(worldX: mid.x, worldY: mid.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .midpoint(entity: handle, betweenA: globalIdx + i,
                                            andB: globalIdx + i + 1),
                            screenPos: sp, worldPos: mid))
                    }
                }
                globalIdx += pts.count
            }
        }
        return results
    }

    // MARK: - World Geometry Extraction

    /// Returns world-space vertex arrays for an entity's geometry. Each inner
    /// array is a contiguous polyline/line-loop to draw (used for hover
    /// outlines and ghost previews).
    public static func worldGeometryPoints(
        for handle: UUID, document: CADDocument
    ) -> [[Vector3]] {
        guard let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty
        else { return [] }

        let hasEditableBoundary = geometry.contains { isInvisibleEditBoundary($0) }

        var result: [[Vector3]] = []
        for prim in geometry {
            if hasEditableBoundary && !isInvisibleEditBoundary(prim) { continue }
            let pts: [Vector3]
            if case .polyline(let path, _) = prim {
                pts = path.tessellatedPoints().map {
                    entity.transform.transformPoint($0)
                }
            } else {
                pts = CADGeometryMath.worldPointsForPrimitive(
                    prim, transform: entity.transform)
            }
            if pts.count >= 2 {
                result.append(pts)
            }
        }
        return result
    }

    /// Returns the 4 oriented world-space corners of an entity's bounding box.
    /// If the entity has no rotation, returns the axis-aligned corners.
    /// Otherwise transforms the local bounding box corners into world space.
    public static func getOrientedCorners(
        _ handle: UUID, document: CADDocument
    ) -> [Vector3]? {
        guard let entity = document.entity(for: handle),
              let local = entity.localBoundingBox
        else { return nil }

        if abs(entity.transform.rotation) < 1e-6 {
            return entity.worldBoundingBox.map { bb in
                [
                    bb.min,
                    Vector3(x: bb.max.x, y: bb.min.y, z: bb.min.z),
                    bb.max,
                    Vector3(x: bb.min.x, y: bb.max.y, z: bb.min.z),
                ]
            }
        }
        let corners = local.corners.prefix(4)
        return corners.map { entity.transform.transformPoint($0) }
    }

    // MARK: - Primitive Classification Helpers

    /// Returns true if the primitive is an invisible edit boundary (polygon
    /// with alpha == 0). These are used internally for block-editing boundaries
    /// and should not produce visible grips.
    public static func isInvisibleEditBoundary(_ prim: CADPrimitive) -> Bool {
        if case .polygon(_, let color) = prim, let color, color.a == 0 {
            return true
        }
        return false
    }

    /// Returns true if the given primitive type supports midpoint grips.
    /// Midpoint grips are created for line-based primitives but not for
    /// points, circles, arcs, splines, text, or ellipses.
    public static func shouldCreateMidpointGrips(for prim: CADPrimitive) -> Bool {
        switch prim {
        case .line, .rect, .polygon, .polyline, .fillRect, .fillPolygon,
             .fillComplexPolygon, .gradient, .hatch, .ray:
            return true
        case .point, .circle, .arc, .spline, .text, .ellipse, .image:
            return false
        }
    }
}
