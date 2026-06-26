import Foundation

// =========================================================================
// MARK: - CADRectSelect
//
// Rectangle (window/crossing) selection for the CAD selection manager.
// Handles both the live preview (handlesInRect) and the final selection
// commit (selectInRect), including narrow-phase geometry intersection tests.
//
// All methods are static and take explicit `document:` / `selectionManager:`
// parameters. The selection manager calls these and then updates its own
// `selectedHandles` set based on the results.
// =========================================================================

@MainActor
public enum CADRectSelect {

    // MARK: - Public API

    /// Returns the set of handles that fall inside the given rectangle,
    /// without modifying the current selection. Used for live preview
    /// during two-click rect select.
    public static func handlesInRect(
        worldX: Double, worldY: Double,
        worldW: Double, worldH: Double,
        document: CADDocument,
        style: CADSelectionManager.RectSelectStyle
    ) -> Set<UUID> {
        let (rx, ry, rw, rh) = (worldX, worldY, worldW, worldH)
        var result = Set<UUID>()

        forEachCandidate(in: document, rectMinX: rx, rectMinY: ry, rectMaxX: rx + rw, rectMaxY: ry + rh) { entity in
            if isEntityInRect(entity, rx: rx, ry: ry, rw: rw, rh: rh, document: document, style: style) {
                result.insert(entity.handle)
            }
        }

        return result
    }

    /// Modifies the selection set based on a rectangle selection. The caller
    /// is responsible for clearing the selection beforehand for `.replace` mode.
    public static func selectInRect(
        worldX: Double, worldY: Double,
        worldW: Double, worldH: Double,
        document: CADDocument,
        mode: CADSelectionManager.RectSelectMode,
        style: CADSelectionManager.RectSelectStyle,
        into selection: inout Set<UUID>
    ) {
        let (rx, ry, rw, rh) = (worldX, worldY, worldW, worldH)

        forEachCandidate(in: document, rectMinX: rx, rectMinY: ry, rectMaxX: rx + rw, rectMaxY: ry + rh) { entity in
            guard isEntityInRect(entity, rx: rx, ry: ry, rw: rw, rh: rh, document: document, style: style) else { return }

            switch mode {
            case .replace, .add:
                selection.insert(entity.handle)
            case .subtract:
                selection.remove(entity.handle)
            }
        }
    }

    // MARK: - Geometry Intersection Tests

    /// Tests whether a single entity intersects (or is fully enclosed by) a
    /// selection rectangle.
    public static func entityIntersectsRect(
        _ entity: CADEntity, rectMin: Vector3, rectMax: Vector3, document: CADDocument
    ) -> Bool {
        // Fast accept: if bounding box is entirely inside the rect, the
        // geometry is definitely selected.
        if let bb = entity.worldBoundingBox {
            if bb.min.x >= rectMin.x && bb.max.x <= rectMax.x &&
               bb.min.y >= rectMin.y && bb.max.y <= rectMax.y {
                return true
            }
        }

        guard let geometry = document.resolvedGeometry(for: entity), !geometry.isEmpty else { return false }

        for prim in geometry {
            if primitiveIntersectsRect(prim, transform: entity.transform,
                                       rectMin: rectMin, rectMax: rectMax) {
                return true
            }
        }
        return false
    }

    /// Tests whether a single primitive intersects a selection rectangle.
    /// Handles outline primitives (only edges count) vs fill primitives
    /// (interior containment counts).
    public static func primitiveIntersectsRect(
        _ prim: CADPrimitive, transform: Transform3D,
        rectMin: Vector3, rectMax: Vector3
    ) -> Bool {
        switch prim {
        case .point(let pos, _):
            let p = transform.transformPoint(pos)
            return p.x >= rectMin.x && p.x <= rectMax.x &&
                   p.y >= rectMin.y && p.y <= rectMax.y

        case .line(let start, let end, _):
            let p1 = transform.transformPoint(start)
            let p2 = transform.transformPoint(end)
            return segmentIntersectsRect(p1: p1, p2: p2, rectMin: rectMin, rectMax: rectMax)

        case .rect(let origin, let size, _): // OUTLINE
            let corners = buildCorners(origin, size, transform)
            for i in 0..<4 {
                if segmentIntersectsRect(p1: corners[i], p2: corners[(i + 1) % 4],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .fillRect(let origin, let size, _): // FILL
            let corners = buildCorners(origin, size, transform)
            for i in 0..<4 {
                if segmentIntersectsRect(p1: corners[i], p2: corners[(i + 1) % 4],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            let center = Vector3(x: (rectMin.x + rectMax.x) / 2,
                                 y: (rectMin.y + rectMax.y) / 2, z: 0)
            return isPointInPolygon(center, polygon: corners)

        case .polygon(let pts, _): // OUTLINE
            let wpts = pts.map { transform.transformPoint($0) }
            for i in 0..<wpts.count {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[(i + 1) % wpts.count],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .polyline(let path, _):
            let wpts = path.tessellatedPoints().map { transform.transformPoint($0) }
            for i in 0..<(wpts.count - 1) {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[i + 1],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .fillPolygon(let pts, _),
             .fillComplexPolygon(let pts, _, _),
             .gradient(let pts, _, _, _, _, _): // FILL
            let wpts = pts.map { transform.transformPoint($0) }
            for i in 0..<wpts.count {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[(i + 1) % wpts.count],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            let center = Vector3(x: (rectMin.x + rectMax.x) / 2,
                                 y: (rectMin.y + rectMax.y) / 2, z: 0)
            return isPointInPolygon(center, polygon: wpts)

        case .circle(let center, let radius, _): // OUTLINE
            let segs = 32
            var wpts: [Vector3] = []
            for i in 0..<segs {
                let a = Double(i) * 2.0 * .pi / Double(segs)
                let p = Vector3(x: center.x + cos(a) * radius,
                                y: center.y + sin(a) * radius, z: center.z)
                wpts.append(transform.transformPoint(p))
            }
            for i in 0..<wpts.count {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[(i + 1) % wpts.count],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let segs = 32
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * .pi }
            var wpts: [Vector3] = []
            for i in 0...segs {
                let a = startAngle + span * Double(i) / Double(segs)
                let p = Vector3(x: center.x + cos(a) * radius,
                                y: center.y + sin(a) * radius, z: center.z)
                wpts.append(transform.transformPoint(p))
            }
            for i in 0..<(wpts.count - 1) {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[i + 1],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluate(
                degree: degree, knots: knots,
                controlPoints: controlPoints, weights: w, segments: 24)
            guard evaluated.count >= 2 else { return false }
            for i in 0..<(evaluated.count - 1) {
                let p1 = transform.transformPoint(evaluated[i])
                let p2 = transform.transformPoint(evaluated[i + 1])
                if segmentIntersectsRect(p1: p1, p2: p2,
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

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

            let c1 = localToWorld.transformPoint(Vector3(x: bounds.minX, y: bounds.minY, z: 0))
            let c2 = localToWorld.transformPoint(Vector3(x: bounds.maxX, y: bounds.minY, z: 0))
            let c3 = localToWorld.transformPoint(Vector3(x: bounds.maxX, y: bounds.maxY, z: 0))
            let c4 = localToWorld.transformPoint(Vector3(x: bounds.minX, y: bounds.maxY, z: 0))

            // Check if any corner is inside the selection rect
            for pt in [c1, c2, c3, c4] {
                if pt.x >= rectMin.x && pt.x <= rectMax.x &&
                   pt.y >= rectMin.y && pt.y <= rectMax.y { return true }
            }

            // Check if any edge intersects the selection rect
            if segmentIntersectsRect(p1: c1, p2: c2, rectMin: rectMin, rectMax: rectMax) { return true }
            if segmentIntersectsRect(p1: c2, p2: c3, rectMin: rectMin, rectMax: rectMax) { return true }
            if segmentIntersectsRect(p1: c3, p2: c4, rectMin: rectMin, rectMax: rectMax) { return true }
            if segmentIntersectsRect(p1: c4, p2: c1, rectMin: rectMin, rectMax: rectMax) { return true }
            return false

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let segs = 32
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let rot = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(rot)
            let sinRot = sin(rot)
            var wpts: [Vector3] = []
            for i in 0..<segs {
                let t = Double(i) * 2.0 * .pi / Double(segs)
                let px = majorLen * cos(t)
                let py = minorLen * sin(t)
                let rx = px * cosRot - py * sinRot + center.x
                let ry = px * sinRot + py * cosRot + center.y
                let local = Vector3(x: rx, y: ry, z: center.z)
                wpts.append(transform.transformPoint(local))
            }
            for i in 0..<wpts.count {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[(i + 1) % wpts.count],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            return false

        case .hatch(let boundary, _, _, _, _):
            let wpts = boundary.map { transform.transformPoint($0) }
            guard wpts.count >= 3 else { return false }
            for i in 0..<wpts.count {
                if segmentIntersectsRect(p1: wpts[i], p2: wpts[(i + 1) % wpts.count],
                                         rectMin: rectMin, rectMax: rectMax) { return true }
            }
            let center = Vector3(x: (rectMin.x + rectMax.x) / 2,
                                 y: (rectMin.y + rectMax.y) / 2, z: 0)
            return isPointInPolygon(center, polygon: wpts)

        case .ray(let start, let direction, _):
            let ws = transform.transformPoint(start)
            let dirNorm = direction.magnitude
            guard dirNorm > 1e-12 else { return false }
            let unitDir = Vector3(x: direction.x / dirNorm, y: direction.y / dirNorm, z: 0)
            let rot = transform.rotation
            let cosR = cos(rot)
            let sinR = sin(rot)
            let wdx = unitDir.x * cosR - unitDir.y * sinR
            let wdy = unitDir.x * sinR + unitDir.y * cosR
            let farEnd = Vector3(x: ws.x + wdx * 100_000, y: ws.y + wdy * 100_000, z: ws.z)
            return segmentIntersectsRect(p1: ws, p2: farEnd, rectMin: rectMin, rectMax: rectMax)
        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let c0 = transform.transformPoint(insertion)
            let c1 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
            let c2 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
            let c3 = transform.transformPoint(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            let corners = [c0, c1, c2, c3]
            // Bounding-box intersection check
            let bbMin = Vector3(x: corners.map(\.x).min() ?? 0, y: corners.map(\.y).min() ?? 0, z: 0)
            let bbMax = Vector3(x: corners.map(\.x).max() ?? 0, y: corners.map(\.y).max() ?? 0, z: 0)
            if bbMax.x < rectMin.x || bbMin.x > rectMax.x
                || bbMax.y < rectMin.y || bbMin.y > rectMax.y { return false }
            return true
        }
    }

    // MARK: - Geometry Utilities

    /// Returns true if the segment [p1, p2] intersects the axis-aligned
    /// rectangle [rectMin, rectMax].
    public static func segmentIntersectsRect(
        p1: Vector3, p2: Vector3, rectMin: Vector3, rectMax: Vector3
    ) -> Bool {
        // 1. One of the segment ends is enclosed in the box
        if p1.x >= rectMin.x && p1.x <= rectMax.x &&
           p1.y >= rectMin.y && p1.y <= rectMax.y { return true }
        if p2.x >= rectMin.x && p2.x <= rectMax.x &&
           p2.y >= rectMin.y && p2.y <= rectMax.y { return true }

        // 2. The segment crosses one of the box edges
        let r1 = Vector3(x: rectMin.x, y: rectMin.y, z: 0)
        let r2 = Vector3(x: rectMax.x, y: rectMin.y, z: 0)
        let r3 = Vector3(x: rectMax.x, y: rectMax.y, z: 0)
        let r4 = Vector3(x: rectMin.x, y: rectMax.y, z: 0)

        if segmentsIntersect(p1, p2, r1, r2) { return true }
        if segmentsIntersect(p1, p2, r2, r3) { return true }
        if segmentsIntersect(p1, p2, r3, r4) { return true }
        if segmentsIntersect(p1, p2, r4, r1) { return true }

        return false
    }

    /// Returns true if two line segments [p1,p2] and [p3,p4] intersect.
    public static func segmentsIntersect(
        _ p1: Vector3, _ p2: Vector3, _ p3: Vector3, _ p4: Vector3
    ) -> Bool {
        func ccw(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Double {
            return (c.y - a.y) * (b.x - a.x) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = ccw(p1, p3, p4)
        let d2 = ccw(p2, p3, p4)
        let d3 = ccw(p1, p2, p3)
        let d4 = ccw(p1, p2, p4)

        // Standard intersection
        if d1 * d2 < 0 && d3 * d4 < 0 { return true }

        // Touch / collinear edge cases
        if d1 == 0 && onSegment(p1, a: p3, b: p4) { return true }
        if d2 == 0 && onSegment(p2, a: p3, b: p4) { return true }
        if d3 == 0 && onSegment(p3, a: p1, b: p2) { return true }
        if d4 == 0 && onSegment(p4, a: p1, b: p2) { return true }

        return false
    }

    /// Returns true if point `p` lies on the segment [a, b] (collinear test).
    public static func onSegment(_ p: Vector3, a: Vector3, b: Vector3) -> Bool {
        return p.x <= max(a.x, b.x) && p.x >= min(a.x, b.x) &&
               p.y <= max(a.y, b.y) && p.y >= min(a.y, b.y)
    }

    /// Ray-casting point-in-polygon test. Returns true if `p` lies inside
    /// the given polygon (works for both convex and concave polygons).
    public static func isPointInPolygon(_ p: Vector3, polygon: [Vector3]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.y > p.y) != (pj.y > p.y)) &&
                (p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Private Helpers

    /// Iterates candidate entities whose world bounding box overlaps the
    /// selection rectangle, using the spatial grid when available.
    private static func forEachCandidate(
        in document: CADDocument,
        rectMinX: Double, rectMinY: Double,
        rectMaxX: Double, rectMaxY: Double,
        body: (CADEntity) -> Void
    ) {
        if let handles = document.entityHandlesInWorldRect(
            minX: rectMinX, minY: rectMinY, maxX: rectMaxX, maxY: rectMaxY)
        {
            for handle in handles {
                guard let entity = document.entity(for: handle) else { continue }
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                body(entity)
            }
        } else {
            if document.entityCount > 1 && !document.entityGridBuilt {
                document.rebuildEntityGrid()
            }
            for entity in document.entitiesView {
                guard let layer = document.layer(for: entity.layerID), layer.isVisible else { continue }
                body(entity)
            }
        }
    }

    /// Determines whether an entity is considered "inside" the selection
    /// rectangle based on the style (window vs crossing).
    private static func isEntityInRect(
        _ entity: CADEntity,
        rx: Double, ry: Double, rw: Double, rh: Double,
        document: CADDocument,
        style: CADSelectionManager.RectSelectStyle
    ) -> Bool {
        guard let bb = entity.worldBoundingBox else { return false }

        switch style {
        case .window:
            return bb.min.x >= rx && bb.min.y >= ry &&
                   bb.max.x <= rx + rw && bb.max.y <= ry + rh
        case .crossing:
            let broadPhase = bb.min.x <= rx + rw && bb.max.x >= rx &&
                             bb.min.y <= ry + rh && bb.max.y >= ry
            guard broadPhase else { return false }
            let rectMin = Vector3(x: rx, y: ry, z: 0)
            let rectMax = Vector3(x: rx + rw, y: ry + rh, z: 0)
            return entityIntersectsRect(entity, rectMin: rectMin, rectMax: rectMax,
                                        document: document)
        }
    }

    /// Builds the 4 world-space corners for a rect primitive.
    private static func buildCorners(
        _ origin: Vector3, _ size: Vector3, _ transform: Transform3D
    ) -> [Vector3] {
        return [
            transform.transformPoint(origin),
            transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: 0)),
            transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: 0)),
            transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: 0))
        ]
    }
}
