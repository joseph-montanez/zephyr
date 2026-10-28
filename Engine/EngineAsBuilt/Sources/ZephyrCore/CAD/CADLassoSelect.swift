import Foundation

// =========================================================================
// MARK: - CADLassoSelect
//
// Freeform lasso (press-and-drag) selection for the CAD selection manager.
// Mirrors `CADRectSelect`, but tests geometry against an arbitrary polygon
// (the cursor path) instead of an axis-aligned rectangle.
//
// Direction rule (same as rectangular selection):
//   - Lasso drawn left-to-right  (end X >= start X) â†’ window:   only entities
//     fully enclosed by the lasso polygon are selected.
//   - Lasso drawn right-to-left (end X < start X)   â†’ crossing: entities
//     enclosed by OR touched by the lasso boundary are selected.
// =========================================================================

/// Freeform lasso selection tests. See file header.
@MainActor
public enum CADLassoSelect {

    // MARK: - Public API

    /// Returns the set of handles selected by the given lasso polygon,
    /// without modifying the current selection. Used for live preview
    /// while the cursor is being dragged.
    public static func handlesInPolygon(
        worldPoints: [Vector3],
        document: CADDocument,
        style: CADSelectionManager.RectSelectStyle
    ) -> Set<UUID> {
        guard worldPoints.count >= 3 else { return [] }
        let (minX, minY, maxX, maxY) = boundingBox(worldPoints)
        var result = Set<UUID>()

        forEachCandidate(in: document, minX: minX, minY: minY, maxX: maxX, maxY: maxY) { entity in
            let hit: Bool
            switch style {
            case .window:
                hit = entityEnclosedByPolygon(entity, polygon: worldPoints, document: document)
            case .crossing:
                hit = entityIntersectsPolygon(entity, polygon: worldPoints, document: document)
            }
            if hit { result.insert(entity.handle) }
        }

        return result
    }

    /// Modifies the selection set based on a lasso polygon. The caller
    /// is responsible for clearing the selection beforehand for `.replace` mode.
    public static func selectInPolygon(
        worldPoints: [Vector3],
        document: CADDocument,
        mode: CADSelectionManager.RectSelectMode,
        style: CADSelectionManager.RectSelectStyle,
        into selection: inout Set<UUID>
    ) {
        guard worldPoints.count >= 3 else { return }
        let (minX, minY, maxX, maxY) = boundingBox(worldPoints)

        forEachCandidate(in: document, minX: minX, minY: minY, maxX: maxX, maxY: maxY) { entity in
            let hit: Bool
            switch style {
            case .window:
                hit = entityEnclosedByPolygon(entity, polygon: worldPoints, document: document)
            case .crossing:
                hit = entityIntersectsPolygon(entity, polygon: worldPoints, document: document)
            }
            guard hit else { return }

            switch mode {
            case .replace, .add:
                selection.insert(entity.handle)
            case .subtract:
                selection.remove(entity.handle)
            }
        }
    }

    // MARK: - Entity Tests

    /// Crossing test: true when any part of the entity lies inside the lasso
    /// polygon or touches its boundary.
    public static func entityIntersectsPolygon(
        _ entity: CADEntity, polygon: [Vector3], document: CADDocument
    ) -> Bool {
        guard let bb = entity.worldBoundingBox else { return false }
        let (minX, minY, maxX, maxY) = boundingBox(polygon)
        guard bb.max.x >= minX && bb.min.x <= maxX &&
              bb.max.y >= minY && bb.min.y <= maxY else { return false }

        guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { return false }

        for prim in geometry {
            if primitiveIntersectsPolygon(prim, transform: entity.transform, polygon: polygon) {
                return true
            }
        }
        return false
    }

    /// Window test: true only when the entity is fully enclosed by the lasso
    /// polygon (no geometry outside, no boundary contact).
    public static func entityEnclosedByPolygon(
        _ entity: CADEntity, polygon: [Vector3], document: CADDocument
    ) -> Bool {
        guard let bb = entity.worldBoundingBox else { return false }
        let (minX, minY, maxX, maxY) = boundingBox(polygon)
        guard bb.min.x >= minX && bb.max.x <= maxX &&
              bb.min.y >= minY && bb.max.y <= maxY else { return false }

        guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { return false }

        for prim in geometry {
            if !primitiveEnclosedByPolygon(prim, transform: entity.transform, polygon: polygon) {
                return false
            }
        }
        return true
    }

    /// Crossing test for a single primitive against a lasso polygon.
    public static func primitiveIntersectsPolygon(
        _ prim: CADPrimitive, transform: Transform3D, polygon: [Vector3]
    ) -> Bool {
        // Infinite rays/xlines use long finite segments for intersection tests.
        if case .ray(let start, let direction, _) = prim {
            let ws = transform.transformPoint(start)
            let farEnd = infiniteLineEnd(origin: ws, direction: direction, transform: transform, back: false)
            guard let farEnd else { return false }
            if CADRectSelect.isPointInPolygon(ws, polygon: polygon) { return true }
            return segmentIntersectsPolygon(p1: ws, p2: farEnd, polygon: polygon)
        }
        if case .xline(let point, let direction, _) = prim {
            let ws = transform.transformPoint(point)
            guard let farEnd = infiniteLineEnd(origin: ws, direction: direction, transform: transform, back: false),
                  let backEnd = infiniteLineEnd(origin: ws, direction: direction, transform: transform, back: true)
            else { return false }
            if CADRectSelect.isPointInPolygon(ws, polygon: polygon) { return true }
            return segmentIntersectsPolygon(p1: backEnd, p2: farEnd, polygon: polygon)
        }
        // Tables have no outline (outlinePoints returns empty); CROSSING
        // treats them like rect-select does: the entity bounds already
        // overlapped the lasso bbox, which is the accepted approximation.
        if case .table = prim { return true }

        let outline = outlinePoints(for: prim, transform: transform)
        guard !outline.points.isEmpty else { return false }

        // Any geometry point inside the lasso.
        for pt in outline.points {
            if CADRectSelect.isPointInPolygon(pt, polygon: polygon) { return true }
        }
        // Any geometry edge crossing the lasso boundary.
        if segmentsCrossPolygon(points: outline.points, closed: outline.closed, polygon: polygon) {
            return true
        }
        // Filled primitives also count when the lasso lies entirely inside
        // them (mirrors the rect-select "selection inside a fill" rule).
        if outline.filled {
            for vertex in polygon {
                if CADRectSelect.isPointInPolygon(vertex, polygon: outline.points) { return true }
            }
        }
        return false
    }

    /// Window test for a single primitive: every point inside the lasso and
    /// no edge touching its boundary. Infinite rays/xlines are never enclosed.
    public static func primitiveEnclosedByPolygon(
        _ prim: CADPrimitive, transform: Transform3D, polygon: [Vector3]
    ) -> Bool {
        if case .ray = prim { return false }
        if case .xline = prim { return false }
        if case .table = prim { return false }  // no outline without entity bounds
        let outline = outlinePoints(for: prim, transform: transform)
        guard !outline.points.isEmpty else { return false }
        for pt in outline.points {
            if !CADRectSelect.isPointInPolygon(pt, polygon: polygon) { return false }
        }
        return !segmentsCrossPolygon(points: outline.points, closed: outline.closed, polygon: polygon)
    }

    // MARK: - Geometry Utilities

    /// Axis-aligned bounding box of a polygon.
    public static func boundingBox(
        _ polygon: [Vector3]
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for pt in polygon {
            minX = min(minX, pt.x); minY = min(minY, pt.y)
            maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
        }
        return (minX, minY, maxX, maxY)
    }

    /// Returns true if the segment [p1, p2] touches or crosses the boundary
    /// of the given (implicitly closed) polygon.
    public static func segmentIntersectsPolygon(
        p1: Vector3, p2: Vector3, polygon: [Vector3]
    ) -> Bool {
        guard polygon.count >= 2 else { return false }
        for i in 0..<polygon.count {
            let q1 = polygon[i]
            let q2 = polygon[(i + 1) % polygon.count]
            if CADRectSelect.segmentsIntersect(p1, p2, q1, q2) { return true }
        }
        return false
    }

    /// One far end of an infinite line through `origin` (already world-space),
    /// 100k units along the (rotated, normalized) direction. `back` reverses it.
    private static func infiniteLineEnd(
        origin ws: Vector3, direction: Vector3, transform: Transform3D, back: Bool
    ) -> Vector3? {
        let dirNorm = direction.magnitude
        guard dirNorm > 1e-12 else { return nil }
        let unitDir = Vector3(x: direction.x / dirNorm, y: direction.y / dirNorm, z: 0)
        let rot = transform.rotation
        let cosR = cos(rot)
        let sinR = sin(rot)
        let sign = back ? -100_000.0 : 100_000.0
        return Vector3(
            x: ws.x + (unitDir.x * cosR - unitDir.y * sinR) * sign,
            y: ws.y + (unitDir.x * sinR + unitDir.y * cosR) * sign, z: ws.z)
    }

    /// World-space outline of a primitive: tessellated boundary points, whether
    /// the boundary is closed, and whether the primitive covers an area (fill).
    public static func outlinePoints(
        for prim: CADPrimitive, transform: Transform3D
    ) -> (points: [Vector3], closed: Bool, filled: Bool) {
        switch prim {
        case .point(let pos, _):
            return ([transform.transformPoint(pos)], false, false)

        case .line(let start, let end, _):
            return ([transform.transformPoint(start), transform.transformPoint(end)], false, false)

        case .rect(let origin, let size, _):
            return (rectCorners(origin, size, transform), true, false)

        case .fillRect(let origin, let size, _):
            return (rectCorners(origin, size, transform), true, true)

        case .polygon(let pts, _):
            return (pts.map { transform.transformPoint($0) }, true, false)

        case .polyline(let path, _):
            return (path.tessellatedPoints().map { transform.transformPoint($0) }, path.isClosed, false)

        case .penStroke(let vertices, _, _):
            return (vertices.map { transform.transformPoint($0.position) }, false, false)

        case .fillPolygon(let pts, _):
            return (pts.map { transform.transformPoint($0) }, true, true)

        case .fillComplexPolygon(let outer, _, _),
             .gradient(let outer, _, _, _, _, _):
            return (outer.map { transform.transformPoint($0) }, true, true)

        case .circle(let center, let radius, _):
            return (circlePoints(center: center, radius: radius, transform: transform), true, false)

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * .pi }
            var pts: [Vector3] = []
            for i in 0...32 {
                let a = startAngle + span * Double(i) / 32.0
                pts.append(transform.transformPoint(Vector3(
                    x: center.x + cos(a) * radius,
                    y: center.y + sin(a) * radius, z: center.z)))
            }
            return (pts, false, false)

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segmentsPerSpan: 6)
            return (evaluated.map { transform.transformPoint($0) }, false, false)

        case .text(let pos, let text, let height, let rotation, _, let alignH, let alignV, let mtextWidth, _):
            var localToWorld = transform
            if rotation != 0 {
                localToWorld = localToWorld.multiplying(by: .rotated(by: rotation))
            }
            if pos != .zero {
                localToWorld = localToWorld.multiplying(by: .translated(by: pos))
            }
            let bounds = CADEntity.estimateTextLocalBounds(
                text: text, height: height,
                alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth)
            let corners = [
                localToWorld.transformPoint(Vector3(x: bounds.minX, y: bounds.minY, z: 0)),
                localToWorld.transformPoint(Vector3(x: bounds.maxX, y: bounds.minY, z: 0)),
                localToWorld.transformPoint(Vector3(x: bounds.maxX, y: bounds.maxY, z: 0)),
                localToWorld.transformPoint(Vector3(x: bounds.minX, y: bounds.maxY, z: 0)),
            ]
            return (corners, true, true)

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let rot = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(rot)
            let sinRot = sin(rot)
            var pts: [Vector3] = []
            for i in 0..<32 {
                let t = Double(i) * 2.0 * .pi / 32.0
                let px = majorLen * cos(t)
                let py = minorLen * sin(t)
                let local = Vector3(
                    x: px * cosRot - py * sinRot + center.x,
                    y: px * sinRot + py * cosRot + center.y, z: center.z)
                pts.append(transform.transformPoint(local))
            }
            return (pts, true, false)

        case .hatch(let boundary, _, _, _, _, _):
            let pts = boundary.map { transform.transformPoint($0) }
            return (pts, true, true)

        case .hatchPath(let boundary, _, _, _, _, _, _):
            let pts = boundary.tessellatedPoints().map { transform.transformPoint($0) }
            return (pts, true, true)

        case .ray, .xline:
            // Handled by the callers; rays/xlines have no finite outline.
            return ([], false, false)

        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let c0 = transform.transformPoint(insertion)
            let c1 = transform.transformPoint(Vector3(
                x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
            let c2 = transform.transformPoint(Vector3(
                x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y,
                z: insertion.z + uAxis.z + vAxis.z))
            let c3 = transform.transformPoint(Vector3(
                x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            return ([c0, c1, c2, c3], true, true)

        case .table:
            // Handled by the callers; a table's outline needs its entity bounds.
            return ([], false, false)
        }
    }

    // MARK: - Private Helpers

    /// Iterates candidate entities whose world bounding box overlaps the
    /// lasso's bounding box, using the spatial grid when available.
    /// Mirrors `CADRectSelect.forEachCandidate`.
    private static func forEachCandidate(
        in document: CADDocument,
        minX: Double, minY: Double,
        maxX: Double, maxY: Double,
        body: (CADEntity) -> Void
    ) {
        if let handles = document.entityHandlesInWorldRect(
            minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        {
            for handle in handles {
                guard let entity = document.entity(for: handle) else { continue }
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard !document.isIsolatedHidden(entity.handle) else { continue }
                body(entity)
            }
        } else {
            if document.entityCount > 1 && !document.entityGridBuilt {
                document.rebuildEntityGrid()
            }
            for entity in document.entitiesView {
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                guard !document.isIsolatedHidden(entity.handle) else { continue }
                body(entity)
            }
        }
    }

    /// Returns true when any edge of the (open or closed) point path touches
    /// or crosses the polygon boundary. Endpoints lying exactly on the
    /// boundary count as contact (consistent with window exclusion).
    private static func segmentsCrossPolygon(
        points: [Vector3], closed: Bool, polygon: [Vector3]
    ) -> Bool {
        guard points.count >= 2, polygon.count >= 3 else { return false }
        let edgeCount = closed ? points.count : points.count - 1
        guard edgeCount > 0 else { return false }
        for i in 0..<edgeCount {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]
            if segmentIntersectsPolygon(p1: p1, p2: p2, polygon: polygon) { return true }
        }
        return false
    }

    private static func rectCorners(
        _ origin: Vector3, _ size: Vector3, _ transform: Transform3D
    ) -> [Vector3] {
        return [
            transform.transformPoint(origin),
            transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: 0)),
            transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: 0)),
            transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: 0)),
        ]
    }

    private static func circlePoints(
        center: Vector3, radius: Double, transform: Transform3D
    ) -> [Vector3] {
        var pts: [Vector3] = []
        pts.reserveCapacity(32)
        for i in 0..<32 {
            let a = Double(i) * 2.0 * .pi / 32.0
            pts.append(transform.transformPoint(Vector3(
                x: center.x + cos(a) * radius,
                y: center.y + sin(a) * radius, z: center.z)))
        }
        return pts
    }
}
