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

            if let array = entity.arrayData, array.kind == .rectangular {
                results.append(contentsOf: rectangularArrayGrips(
                    for: handle, entity: entity, array: array, cam: cam))
                continue
            }

            guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { continue }

            // ── Dimension entities: generate dimension-specific control grips
            //     from metadata instead of individual block primitive grips.
            if let dimBox = entity.dimensionMetadata {
                results.append(contentsOf: dimensionGrips(
                    for: handle, metadata: dimBox.value,
                    entity: entity, cam: cam))
                continue
            }

            let containsAnalyticHatchBoundary = geometry.contains { primitive in
                switch primitive {
                case .polyline(let path, _):
                    return path.isHatchBoundaryCarrier && !path.hatchEdges.isEmpty
                case .hatchPath(let path, _, _, _, _, _, _):
                    return !path.hatchEdges.isEmpty
                default:
                    return false
                }
            }
            if simplifyComplexBlocks && geometry.count > 50 && !containsAnalyticHatchBoundary { continue }

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
                    if !path.hatchEdges.isEmpty {
                        let localGripPoints = analyticHatchGripPoints(path)
                        for (index, localPoint) in localGripPoints.enumerated() {
                            let point = entity.transform.transformPoint(localPoint)
                            let screen = EngineCameraManager.worldToScreen(
                                worldX: point.x, worldY: point.y, cam: cam)
                            results.append(CADSelectionManager.CadGripInfo(
                                handle: handle,
                                grip: .vertex(entity: handle, index: globalIdx + index),
                                screenPos: screen,
                                worldPos: point))
                        }
                        globalIdx += localGripPoints.count
                        continue
                    }

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

                if case .hatchPath(let boundary, _, _, _, _, _, _) = prim {
                    if hasEditableBoundary {
                        globalIdx += boundary.hatchEdges.isEmpty
                            ? boundary.vertices.count
                            : analyticHatchGripPoints(boundary).count
                        continue
                    }
                    if !boundary.hatchEdges.isEmpty {
                        let localGripPoints = analyticHatchGripPoints(boundary)
                        for (index, localPoint) in localGripPoints.enumerated() {
                            let point = entity.transform.transformPoint(localPoint)
                            let screen = EngineCameraManager.worldToScreen(
                                worldX: point.x, worldY: point.y, cam: cam)
                            results.append(CADSelectionManager.CadGripInfo(
                                handle: handle,
                                grip: .vertex(entity: handle, index: globalIdx + index),
                                screenPos: screen,
                                worldPos: point))
                        }
                        globalIdx += localGripPoints.count
                        continue
                    }
                    let worldVertices = boundary.vertices.map {
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
                    for segment in 0..<boundary.segmentCount {
                        let midpoint = entity.transform.transformPoint(
                            boundary.segmentMidpoint(segment))
                        let screen = EngineCameraManager.worldToScreen(
                            worldX: midpoint.x, worldY: midpoint.y, cam: cam)
                        results.append(CADSelectionManager.CadGripInfo(
                            handle: handle,
                            grip: .midpoint(
                                entity: handle,
                                betweenA: globalIdx + segment,
                                andB: globalIdx + boundary.endVertexIndex(forSegment: segment)),
                            screenPos: screen,
                            worldPos: midpoint))
                    }
                    globalIdx += boundary.vertices.count
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
            } else if case .hatchPath(let boundary, _, _, _, _, _, _) = prim {
                pts = boundary.tessellatedPoints().map {
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

    public struct LengthenConstraint: Sendable {
        public let anchor: Vector3
        public let axis: Vector3

        public init(anchor: Vector3, axis: Vector3) {
            self.anchor = anchor
            self.axis = axis
        }
    }

    public static func lengthenConstraint(
        for handle: UUID,
        vertexIndex: Int,
        document: CADDocument
    ) -> LengthenConstraint? {
        guard let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity),
              vertexIndex >= 0
        else { return nil }

        var globalIndex = 0

        func makeConstraint(dragged: Vector3, anchor: Vector3) -> LengthenConstraint? {
            let dx = dragged.x - anchor.x
            let dy = dragged.y - anchor.y
            let length = hypot(dx, dy)
            guard length > 1e-12 else { return nil }
            return LengthenConstraint(
                anchor: anchor,
                axis: Vector3(x: dx / length, y: dy / length, z: 0))
        }

        for primitive in geometry {
            switch primitive {
            case .polyline(let path, _):
                let gripCount = path.hatchEdges.isEmpty
                    ? path.vertices.count
                    : analyticHatchGripPoints(path).count
                let localIndex = vertexIndex - globalIndex
                globalIndex += gripCount

                guard localIndex >= 0, localIndex < gripCount else { continue }
                guard path.hatchEdges.isEmpty,
                      !path.isClosed,
                      path.vertices.count >= 2,
                      localIndex == 0 || localIndex == path.vertices.count - 1
                else { return nil }

                let neighborIndex: Int
                let segmentIndex: Int
                if localIndex == 0 {
                    neighborIndex = 1
                    segmentIndex = 0
                } else {
                    neighborIndex = path.vertices.count - 2
                    segmentIndex = neighborIndex
                }

                guard abs(path.vertices[segmentIndex].bulge) <= 1e-12 else { return nil }

                let dragged = entity.transform.transformPoint(
                    path.vertices[localIndex].position)
                let anchor = entity.transform.transformPoint(
                    path.vertices[neighborIndex].position)
                return makeConstraint(dragged: dragged, anchor: anchor)

            case .hatchPath(let boundary, _, _, _, _, _, _):
                let gripCount = boundary.hatchEdges.isEmpty
                    ? boundary.vertices.count
                    : analyticHatchGripPoints(boundary).count
                let localIndex = vertexIndex - globalIndex
                globalIndex += gripCount
                if localIndex >= 0, localIndex < gripCount { return nil }

            default:
                let points = CADGeometryMath.worldPointsForPrimitive(
                    primitive, transform: entity.transform)
                let localIndex = vertexIndex - globalIndex
                globalIndex += points.count

                guard localIndex >= 0, localIndex < points.count else { continue }
                guard case .line = primitive, points.count >= 2, localIndex < 2 else {
                    return nil
                }
                return makeConstraint(
                    dragged: points[localIndex],
                    anchor: points[localIndex == 0 ? 1 : 0])
            }
        }

        return nil
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

    // MARK: - Dimension Grips

    /// Generate dimension-specific control grips from metadata instead of
    /// individual block primitive grips. This gives the user grips at the
    /// meaningful control points: text position, dimension line position,
    /// and extension line origins.
    private static func dimensionGrips(
        for handle: UUID,
        metadata: CADDimensionMetadata,
        entity: CADEntity,
        cam: CameraTransform
    ) -> [CADSelectionManager.CadGripInfo] {
        var grips: [CADSelectionManager.CadGripInfo] = []

        func addGrip(_ type: CADSelectionManager.GripType, localPos: Vector3) {
            let worldPos = entity.transform.transformPoint(localPos)
            let sp = EngineCameraManager.worldToScreen(
                worldX: worldPos.x, worldY: worldPos.y, cam: cam)
            grips.append(CADSelectionManager.CadGripInfo(
                handle: handle, grip: type, screenPos: sp, worldPos: worldPos))
        }

        addGrip(.center, localPos: metadata.textMidpoint)

        // For radius: defPoint = center (fixed), defPoint2 = arcPoint (movable along circle)
        // For diameter: defPoint & defPoint2 = endpoints of diameter line
        // For linear/aligned: defPoint = dim line position, defPoint2/3 = extension origins
        if metadata.type == .radius {
            // Only arcPoint grip (center is fixed to the arc/circle)
            addGrip(.vertex(entity: handle, index: 1001), localPos: metadata.defPoint2)
        } else if metadata.type == .arcLength {
            // Only dimPos grip to move the dimension arc in/out
            addGrip(.vertex(entity: handle, index: 1000), localPos: metadata.defPoint)
        } else {
            // Dimension line position / first point grip
            addGrip(.vertex(entity: handle, index: 1000), localPos: metadata.defPoint)
            // Second point grip
            addGrip(.vertex(entity: handle, index: 1001), localPos: metadata.defPoint2)
            // Third point grip (if present, for linear/aligned/angular)
            if let p3 = metadata.defPoint3 {
                addGrip(.vertex(entity: handle, index: 1002), localPos: p3)
            }
        }

        return grips
    }

    private static func rectangularArrayGrips(
        for handle: UUID,
        entity: CADEntity,
        array: CADArrayData,
        cam: CameraTransform
    ) -> [CADSelectionManager.CadGripInfo] {
        let c = cos(array.axisAngle)
        let s = sin(array.axisAngle)
        let columnUnit = Vector3(x: c, y: s, z: 0)
        let rowUnit = Vector3(x: -s, y: c, z: 0)
        var grips: [CADSelectionManager.CadGripInfo] = []

        func addGrip(
            _ type: CADSelectionManager.GripType,
            localPosition: Vector3,
            localDirection: Vector3? = nil
        ) {
            let worldPosition = entity.transform.transformPoint(localPosition)
            let screenPosition = EngineCameraManager.worldToScreen(
                worldX: worldPosition.x, worldY: worldPosition.y, cam: cam)
            var screenDirection: SDL_FPoint? = nil
            if let localDirection {
                let directionPoint = entity.transform.transformPoint(localPosition + localDirection)
                let directionScreen = EngineCameraManager.worldToScreen(
                    worldX: directionPoint.x, worldY: directionPoint.y, cam: cam)
                screenDirection = SDL_FPoint(
                    x: directionScreen.x - screenPosition.x,
                    y: directionScreen.y - screenPosition.y)
            }
            grips.append(CADSelectionManager.CadGripInfo(
                handle: handle,
                grip: type,
                screenPos: screenPosition,
                worldPos: worldPosition,
                screenDirection: screenDirection))
        }

        addGrip(.arrayBase, localPosition: .zero)

        let columns = max(1, array.columns)
        let rows = max(1, array.rows)
        let columnDirection = columnUnit * (array.columnSpacing < 0 ? -1 : 1)
        let rowDirection = rowUnit * (array.rowSpacing < 0 ? -1 : 1)
        let columnSpacing = columnUnit * array.columnSpacing
        let rowSpacing = rowUnit * array.rowSpacing

        func overlapSeparation(along unit: Vector3, spacing: Double) -> Double {
            let origin = entity.transform.transformPoint(.zero)
            let axisPoint = entity.transform.transformPoint(unit)
            let worldPerLocalUnit = max(
                1e-9,
                hypot(axisPoint.x - origin.x, axisPoint.y - origin.y))
            let desiredLocalDistance = 18.0 / max(1e-9, cam.camZoom * worldPerLocalUnit)
            guard abs(spacing) > 1e-9 else { return desiredLocalDistance }
            return min(desiredLocalDistance, abs(spacing) * 0.4)
        }

        if abs(array.columnSpacing) > 1e-9 {
            addGrip(
                .arraySpacing(axis: 0),
                localPosition: columnSpacing,
                localDirection: columnDirection)

            var countPosition = columnSpacing * Double(max(1, columns - 1))
            if columns <= 2 {
                countPosition = countPosition + columnDirection * overlapSeparation(
                    along: columnDirection, spacing: array.columnSpacing)
            }
            addGrip(
                .arrayCount(axis: 0),
                localPosition: countPosition,
                localDirection: columnDirection)
        }

        if abs(array.rowSpacing) > 1e-9 {
            addGrip(
                .arraySpacing(axis: 1),
                localPosition: rowSpacing,
                localDirection: rowDirection)

            var countPosition = rowSpacing * Double(max(1, rows - 1))
            if rows <= 2 {
                countPosition = countPosition + rowDirection * overlapSeparation(
                    along: rowDirection, spacing: array.rowSpacing)
            }
            addGrip(
                .arrayCount(axis: 1),
                localPosition: countPosition,
                localDirection: rowDirection)
        }

        return grips
    }

    private static func analyticHatchGripPoints(_ path: CADPolyline) -> [Vector3] {
        var points: [Vector3] = []
        for edge in path.hatchEdges {
            for point in edge.gripPoints {
                if points.contains(where: { $0.distance(to: point) <= 1e-9 }) { continue }
                points.append(point)
            }
        }
        return points
    }

    // MARK: - Primitive Classification Helpers

    /// Returns true if the primitive is an invisible edit boundary (polygon
    /// with alpha == 0). These are used internally for block-editing boundaries
    /// and should not produce visible grips.
    public static func isInvisibleEditBoundary(_ prim: CADPrimitive) -> Bool {
        if case .polygon(_, let color) = prim, let color, color.a == 0 {
            return true
        }
        if case .polyline(let path, let color) = prim,
           path.isHatchBoundaryCarrier,
           color?.a == 0 {
            return true
        }
        return false
    }

    /// Returns true if the given primitive type supports midpoint grips.
    /// Midpoint grips are created for line-based primitives but not for
    /// points, circles, arcs, splines, text, or ellipses.
    public static func shouldCreateMidpointGrips(for prim: CADPrimitive) -> Bool {
        switch prim {
        case .table: return false
        case .line, .rect, .polygon, .polyline, .fillRect, .fillPolygon,
             .fillComplexPolygon, .gradient, .hatch, .hatchPath, .ray:
            return true
        case .point, .circle, .arc, .spline, .text, .ellipse, .image:
            return false
        }
    }
}
