import Foundation
import SwiftSDL

// =========================================================================
// MARK: - CADHitTesting
//
// World-space hit testing for the CAD selection manager. Provides point-click
// hit testing, closest-entity queries (for hover highlighting), multi-hit
// enumeration (for overlapping entity popups), and per-primitive distance
// computation.
//
// All methods take explicit `document:` and `selectionManager:` parameters
// rather than capturing `self`, so they can be called from both the selection
// manager and the render loop.
// =========================================================================

@MainActor
public enum CADHitTesting {

    // MARK: - Point Hit Test

    /// Returns the handle of the entity CLOSEST to the click point (by distance
    /// to geometry).
    ///
    /// - Parameters:
    ///   - worldX: World X coordinate of the click point.
    ///   - worldY: World Y coordinate of the click point.
    ///   - document: The CAD document to search.
    ///   - threshold: World-space pickbox radius (screen pixels / zoom).
    ///   - simplifyComplexBlocks: When true, complex blocks (>50 primitives)
    ///     are approximated by their bounding box for faster hit testing.
    /// - Returns: The UUID of the closest entity, or nil.
    public static func hitTest(
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> UUID? {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        let t2 = threshold * threshold
        
        var bestHandle: UUID? = nil
        var bestDrawOrder: Int = .min
        var bestArea: Double = .infinity
        var bestDist: Double = .infinity

        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            var hitDist: Double? = nil
            
            if simplifyComplexBlocks && geometry.count > 50 {
                if let d = boundingBoxDistSq(point, entity: entity, threshold: threshold), d <= t2 {
                    hitDist = d
                }
            } else {
                var minDist: Double = .infinity
                for prim in geometry {
                    if let d = distanceSqToPrimitive(prim, point: point, transform: entity.transform, t2: t2) {
                        if d < minDist { minDist = d }
                    }
                }
                if minDist <= t2 { hitDist = minDist }
            }
            
            if let d = hitDist {
                let area = entity.worldBoundingBox?.area ?? 0.0
                let order = entity.drawOrder
                
                var replace = false
                if order > bestDrawOrder {
                    replace = true
                } else if order == bestDrawOrder {
                    // Tie-break by area (smaller area wins). Tolerance of 1e-3 to avoid floating point jitter.
                    if area < bestArea - 1e-3 {
                        replace = true
                    } else if abs(area - bestArea) <= 1e-3 {
                        // Tie-break by exact distance to geometry
                        if d < bestDist {
                            replace = true
                        }
                    }
                }
                
                if replace {
                    bestDrawOrder = order
                    bestArea = area
                    bestDist = d
                    bestHandle = entity.handle
                }
            }
        }

        return bestHandle
    }

    /// Returns the entity closest to the given world point (for hover
    /// highlighting). Returns nil if no geometry is within threshold.
    public static func closestEntity(
        at worldX: Double, _ worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> UUID? {
        // closestEntity shares the exact same logic as hitTest
        return hitTest(
            worldX: worldX, worldY: worldY,
            document: document,
            threshold: threshold,
            simplifyComplexBlocks: simplifyComplexBlocks
        )
    }

    /// Returns all entities whose geometry is within threshold of the point.
    /// Used for the multi-hit popup when entities overlap at the click point.
    public static func allHitsAt(
        worldX: Double, worldY: Double,
        document: CADDocument,
        simplifyComplexBlocks: Bool = true
    ) -> [(handle: UUID, label: String)] {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        let threshold: Double = 3.0
        var results: [(UUID, String)] = []

        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            if hitEntity(entity, point: point, threshold: threshold,
                         document: document, simplifyComplexBlocks: simplifyComplexBlocks,
                         geometry: geometry)
            {
                let label: String
                if let bid = entity.blockID, let block = document.block(for: bid) {
                    label = "\(block.name) #\(entity.handle.uuidString.prefix(8))"
                } else {
                    label = "Entity #\(entity.handle.uuidString.prefix(8))"
                }
                results.append((entity.handle, label))
            }
        }

        return results
    }

    /// Returns true if the entity's geometry is within threshold of the point.
    public static func hitEntity(
        _ entity: CADEntity,
        point: Vector3,
        threshold: Double,
        document: CADDocument,
        simplifyComplexBlocks: Bool = true,
        geometry: [CADPrimitive]? = nil
    ) -> Bool {
        guard let wbb = entity.worldBoundingBox else { return false }
        let expanded = wbb.expanded(by: threshold)
        guard expanded.contains(point) else { return false }

        let geom = geometry ?? document.resolvedGeometry(for: entity)
        guard let geom, !geom.isEmpty else { return false }

        let t2 = threshold * threshold

        if simplifyComplexBlocks && geom.count > 50 {
            let corners: [Vector3] = [
                Vector3(x: wbb.min.x, y: wbb.min.y, z: 0),
                Vector3(x: wbb.max.x, y: wbb.min.y, z: 0),
                Vector3(x: wbb.max.x, y: wbb.max.y, z: 0),
                Vector3(x: wbb.min.x, y: wbb.max.y, z: 0)
            ]
            for i in 0..<4 {
                let d = CADGeometryMath.pointToSegmentDistSq(point, corners[i], corners[(i + 1) % 4])
                if d <= t2 { return true }
            }
            return false
        }

        for prim in geom {
            if distanceSqToPrimitive(prim, point: point, transform: entity.transform, t2: t2) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Distance to Primitive

    /// Returns squared distance from a point to the primitive if within
    /// threshold, nil otherwise.
    public static func distanceSqToPrimitive(
        _ prim: CADPrimitive, point: Vector3, transform: Transform3D, t2: Double
    ) -> Double? {
        switch prim {
        case .point(let pos, _):
            let wp = transform.transformPoint(pos)
            let dx = wp.x - point.x
            let dy = wp.y - point.y
            let d = dx * dx + dy * dy
            return d <= t2 ? d : nil

        case .line(let start, let end, _):
            let ws = transform.transformPoint(start)
            let we = transform.transformPoint(end)
            let d = CADGeometryMath.pointToSegmentDistSq(point, ws, we)
            return d <= t2 ? d : nil

        case .rect(let origin, let size, _):
            let corners: [Vector3] = [
                transform.transformPoint(origin),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)),
            ]
            return minEdgeDistSq(point, corners)

        case .fillRect(let origin, let size, _):
            let corners: [Vector3] = [
                transform.transformPoint(origin),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)),
            ]
            if pointInConvexPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .polygon(let pts, _):
            let corners = pts.map { transform.transformPoint($0) }
            return minEdgeDistSq(point, corners)

        case .polyline(let path, _):
            let corners = path.tessellatedPoints().map { transform.transformPoint($0) }
            return minEdgeDistSqOpen(point, corners)

        case .fillPolygon(let pts, _):
            let corners = pts.map { transform.transformPoint($0) }
            if pointInConvexPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .fillComplexPolygon(let outer, let holes, _),
             .gradient(let outer, let holes, _, _, _, _):
            let outerCorners = outer.map { transform.transformPoint($0) }
            let insideOuter = pointInConvexPolygon(point, outerCorners)
            var insideHole = false
            for hole in holes {
                if pointInConvexPolygon(point, hole.map { transform.transformPoint($0) }) {
                    insideHole = true; break
                }
            }
            if insideOuter && !insideHole { return 0 }
            var best: Double = .infinity
            for i in 0..<outerCorners.count {
                let d = CADGeometryMath.pointToSegmentDistSq(point, outerCorners[i], outerCorners[(i + 1) % outerCorners.count])
                if d < best { best = d }
            }
            for hole in holes {
                let hc = hole.map { transform.transformPoint($0) }
                for i in 0..<hc.count {
                    let d = CADGeometryMath.pointToSegmentDistSq(point, hc[i], hc[(i + 1) % hc.count])
                    if d < best { best = d }
                }
            }
            return best <= t2 ? best : nil

        case .circle(let center, let radius, _):
            let wc = transform.transformPoint(center)
            let dx = wc.x - point.x
            let dy = wc.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            let d = abs(dist - radius)
            return d * d <= t2 ? d * d : nil

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let wc = transform.transformPoint(center)
            let dx = point.x - wc.x
            let dy = point.y - wc.y
            let dist = sqrt(dx * dx + dy * dy)
            let d = abs(dist - radius)
            guard d * d <= t2 else { return nil }
            var angle = atan2(dy, dx)
            let sa = startAngle.truncatingRemainder(dividingBy: 2 * .pi)
            var ea = endAngle.truncatingRemainder(dividingBy: 2 * .pi)
            if ea < sa { ea += 2 * .pi }
            if angle < sa { angle += 2 * .pi }
            return angle >= sa && angle <= ea ? d * d : nil

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segmentsPerSpan: 6)
            guard evaluated.count >= 2 else { return nil }
            var best: Double = .infinity
            for i in 0..<(evaluated.count - 1) {
                let ws = transform.transformPoint(evaluated[i])
                let we = transform.transformPoint(evaluated[i + 1])
                let d = CADGeometryMath.pointToSegmentDistSq(point, ws, we)
                if d < best { best = d }
            }
            return best <= t2 ? best : nil

        case .text(let pos, let text, let height, let rotation, _, let alignH, let alignV, let mtextWidth, _):
            var localToWorld = transform
            if rotation != 0 {
                localToWorld = localToWorld.multiplying(by: .rotated(by: rotation))
            }
            if pos != .zero {
                localToWorld = localToWorld.multiplying(by: .translated(by: pos))
            }

            let worldToLocal = localToWorld.inverse()
            let localPoint = worldToLocal.transformPoint(point)

            let bounds = CADEntity.estimateTextLocalBounds(
                text: text, height: height,
                alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth)

            let th = sqrt(t2)
            if localPoint.x >= bounds.minX - th && localPoint.x <= bounds.maxX + th &&
               localPoint.y >= bounds.minY - th && localPoint.y <= bounds.maxY + th {
                return 0.0
            }
            return nil

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let segs = 32
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let rot = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(rot)
            let sinRot = sin(rot)
            var best: Double = .infinity
            for i in 0..<segs {
                let t1 = Double(i) * 2.0 * .pi / Double(segs)
                let t2a = Double((i + 1) % segs) * 2.0 * .pi / Double(segs)
                let px1 = majorLen * cos(t1)
                let py1 = minorLen * sin(t1)
                let px2 = majorLen * cos(t2a)
                let py2 = minorLen * sin(t2a)
                let rx1 = px1 * cosRot - py1 * sinRot + center.x
                let ry1 = px1 * sinRot + py1 * cosRot + center.y
                let rx2 = px2 * cosRot - py2 * sinRot + center.x
                let ry2 = px2 * sinRot + py2 * cosRot + center.y
                let lp1 = Vector3(x: rx1, y: ry1, z: center.z)
                let lp2 = Vector3(x: rx2, y: ry2, z: center.z)
                let wp1 = transform.transformPoint(lp1)
                let wp2 = transform.transformPoint(lp2)
                let d = CADGeometryMath.pointToSegmentDistSq(point, wp1, wp2)
                if d < best { best = d }
            }
            return best <= t2 ? best : nil

        case .hatch(let boundary, _, _, _, _, _):
            let corners = boundary.map { transform.transformPoint($0) }
            if pointInConvexPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .ray(let start, let direction, _):
            let ws = transform.transformPoint(start)
            let dx = direction.x
            let dy = direction.y
            let dirNorm = sqrt(dx * dx + dy * dy)
            guard dirNorm > 1e-12 else { return nil }
            let unitDir = Vector3(x: dx / dirNorm, y: dy / dirNorm, z: 0)
            let rot = transform.rotation
            let cosR = cos(rot)
            let sinR = sin(rot)
            let wdx = unitDir.x * cosR - unitDir.y * sinR
            let wdy = unitDir.x * sinR + unitDir.y * cosR
            let farEnd = Vector3(x: ws.x + wdx * 100_000, y: ws.y + wdy * 100_000, z: ws.z)
            let d = CADGeometryMath.pointToSegmentDistSq(point, ws, farEnd)
            return d <= t2 ? d : nil
        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let c0 = transform.transformPoint(insertion)
            let c1 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
            let c2 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
            let c3 = transform.transformPoint(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            let corners = [c0, c1, c2, c3]
            if pointInConvexPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners).flatMap { $0 <= t2 ? $0 : nil }
        case .table(let data, let origin, _):
            // Hit test: check against table's derived bounding rect
            let size = DataTableTessellator.computeSize(data: data)
            let c0 = transform.transformPoint(origin)
            let c1 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y, z: origin.z))
            let c2 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y + size.height, z: origin.z))
            let c3 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.height, z: origin.z))
            let corners = [c0, c1, c2, c3]
            if pointInConvexPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners).flatMap { $0 <= t2 ? $0 : nil }
        }
    }

    // MARK: - Private Helpers

    /// Iterates over candidate entities near a point using the spatial grid
    /// when available, falling back to linear scan with lazy grid build.
    private static func forEachCandidate(
        in document: CADDocument,
        near point: Vector3,
        threshold: Double,
        body: (CADEntity, [CADPrimitive]) -> Void
    ) {
        if let handles = document.entityHandlesInWorldRect(
            minX: point.x - threshold, minY: point.y - threshold,
            maxX: point.x + threshold, maxY: point.y + threshold)
        {
            for handle in handles {
                guard let entity = document.entity(for: handle) else { continue }
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard let wbb = entity.worldBoundingBox else { continue }
                let expanded = wbb.expanded(by: threshold)
                guard expanded.contains(point) else { continue }
                guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { continue }
                body(entity, geometry)
            }
        } else {
            // Grid not built — build lazily then fall back to full iteration
            if document.entityCount > 1 && !document.entityGridBuilt {
                document.rebuildEntityGrid()
            }
            for entity in document.entitiesView {
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard let wbb = entity.worldBoundingBox else { continue }
                let expanded = wbb.expanded(by: threshold)
                guard expanded.contains(point) else { continue }
                guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { continue }
                body(entity, geometry)
            }
        }
    }

    /// Returns the minimum squared distance from a point to any edge of a
    /// polygon, or nil if all distances exceed t2.
    private static func minEdgeDistSq(_ point: Vector3, _ corners: [Vector3]) -> Double? {
        let t2 = Double.greatestFiniteMagnitude
        var best: Double = .infinity
        for i in 0..<corners.count {
            let d = CADGeometryMath.pointToSegmentDistSq(point, corners[i], corners[(i + 1) % corners.count])
            if d < best { best = d }
        }
        return best <= t2 ? best : nil
    }

    /// Like minEdgeDistSq but does NOT wrap around (open polyline).
    private static func minEdgeDistSqOpen(_ point: Vector3, _ corners: [Vector3]) -> Double? {
        let t2 = Double.greatestFiniteMagnitude
        var best: Double = .infinity
        for i in 0..<(corners.count - 1) {
            let d = CADGeometryMath.pointToSegmentDistSq(point, corners[i], corners[i + 1])
            if d < best { best = d }
        }
        return best <= t2 ? best : nil
    }

    /// Returns the minimum squared distance from a point to the bounding box
    /// edges of an entity, or nil if outside threshold.
    private static func boundingBoxDistSq(
        _ point: Vector3, entity: CADEntity, threshold: Double
    ) -> Double? {
        guard let wbb = entity.worldBoundingBox else { return nil }
        let corners: [Vector3] = [
            Vector3(x: wbb.min.x, y: wbb.min.y, z: 0),
            Vector3(x: wbb.max.x, y: wbb.min.y, z: 0),
            Vector3(x: wbb.max.x, y: wbb.max.y, z: 0),
            Vector3(x: wbb.min.x, y: wbb.max.y, z: 0)
        ]
        var bestDist: Double = .infinity
        for i in 0..<4 {
            let d = CADGeometryMath.pointToSegmentDistSq(point, corners[i], corners[(i + 1) % 4])
            if d < bestDist { bestDist = d }
        }
        let t2 = threshold * threshold
        return bestDist <= t2 ? bestDist : nil
    }

    /// Returns true if the 2D point lies inside a convex polygon (winding
    /// number test via cross-product sign consistency).
    private static func pointInConvexPolygon(_ p: Vector3, _ quad: [Vector3]) -> Bool {
        guard quad.count >= 3 else { return false }
        let n = quad.count
        var sign = 0
        for i in 0..<n {
            let a = quad[i]
            let b = quad[(i + 1) % n]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross > 0 {
                if sign == -1 { return false }
                sign = 1
            } else if cross < 0 {
                if sign == 1 { return false }
                sign = -1
            }
        }
        return true
    }
}
