// Sources/ZephyrCore/Commands/StretchGeometryEngine.swift
import Foundation

// =========================================================================
// MARK: - StretchSettings
//
// Session-level STRETCH memory (OffsetSettings precedent): the last
// displacement applied, offered as the `<default>` at the base-point and
// displacement prompts. In-memory and lock-guarded (TrimSettings pattern)
// so scripted/interactive runs stay deterministic within a session.
// =========================================================================

public enum StretchSettings: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stored: Vector3?

    /// Last non-zero displacement applied, if any.
    public static var lastDisplacement: Vector3? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Test hook: clear the remembered displacement.
    public static func resetForTesting() {
        lock.withLock { stored = nil }
    }
}

// =========================================================================
// MARK: - StretchRegion
//
// The crossing selection captured during STRETCH. The command records the
// region itself (rect or polygon, world space) — not just the handles —
// because the stretch decision is per defining point, not per entity.
// =========================================================================

public enum StretchRegion: Hashable, Sendable {
    /// Axis-aligned crossing/window rect, world space (min <= max per axis).
    case rect(min: Vector3, max: Vector3)
    /// Crossing polygon, world space.
    case polygon([Vector3])

    /// Crossing containment: inside or touching the boundary.
    public func contains(_ point: Vector3) -> Bool {
        switch self {
        case .rect(let min, let max):
            let eps = 1e-9
            return point.x >= min.x - eps && point.x <= max.x + eps
                && point.y >= min.y - eps && point.y <= max.y + eps
        case .polygon(let vertices):
            if vertices.count >= 3,
               CADRectSelect.isPointInPolygon(point, polygon: vertices) {
                return true
            }
            // On-edge counts as inside (crossing touches count).
            guard vertices.count >= 2 else { return false }
            for index in vertices.indices {
                let a = vertices[index]
                let b = vertices[(index + 1) % vertices.count]
                if CADGeometryMath.pointToSegmentDistSq(point, a, b) <= 1e-12 {
                    return true
                }
            }
            return false
        }
    }
}

// =========================================================================
// MARK: - StretchGeometryEngine
//
// Pure geometry for the AutoCAD-style STRETCH command. All decisions run in
// world space: each defining point is mapped through the entity transform,
// tested against the captured crossing regions, displaced, and mapped back
// through the inverse transform (so rotated/scaled entities stretch
// correctly in local space).
//
// Per-type rules:
//   * Lines move enclosed endpoints; polylines move enclosed vertices
//     (bulges/widths preserved, closed stays closed); splines move enclosed
//     control points; arcs re-solve center/radius/angles from the moved
//     endpoints + center.
//   * Circles, ellipses, block/xref/image/table inserts never stretch:
//     they move whole only when fully enclosed (or individually picked,
//     which the caller flags via `moveWhole`).
//   * Text/points/rays/xlines move by insertion/base point.
//   * Hatch boundaries move like polyline vertices.
// =========================================================================

public enum StretchGeometryEngine {

    /// Outcome of stretching one entity.
    public enum Decision: Sendable {
        /// Shift the whole entity (compose a translation into its transform).
        case moveWhole
        /// Replace the entity's local geometry with the stretched copy.
        case stretched([CADPrimitive])
        /// No defining point moved (or nothing was stretchable).
        case unchanged
    }

    /// Stretch one entity against the captured regions.
    ///
    /// - Parameters:
    ///   - entity: The entity to stretch (never mutated).
    ///   - regions: Captured crossing regions (empty when the selection was
    ///     picks only — then only `moveWhole` picks move).
    ///   - moveWhole: True for individually picked entities (they move whole
    ///     regardless of region containment).
    ///   - delta: World-space displacement (must be non-zero; zero is a
    ///     no-op the caller filters before pushing undo).
    public static func stretch(
        entity: CADEntity,
        regions: [StretchRegion],
        moveWhole: Bool,
        by delta: Vector3
    ) -> Decision {
        guard delta.magnitude > 1e-12 else { return .unchanged }
        if moveWhole { return .moveWhole }

        // Block/xref inserts: the insertion point decides; shared block
        // geometry is never edited.
        if entity.blockID != nil {
            let insertion = entity.transform.transformPoint(.zero)
            return containsAny(regions, insertion) ? .moveWhole : .unchanged
        }

        guard let geometry = entity.localGeometry, !geometry.isEmpty else {
            // Metadata-driven entities (dimensions/leaders/arrays regenerate
            // geometry from their payload): whole-or-nothing via bounds.
            return isFullyEnclosed(entity: entity, regions: regions) ? .moveWhole : .unchanged
        }
        if entity.dimensionMetadata != nil || entity.leaderData != nil
            || entity.arrayData != nil {
            let points = geometry.flatMap {
                CADGeometryMath.worldPointsForPrimitive($0, transform: entity.transform)
            }
            let keys = points.isEmpty ? boundingCorners(of: entity) : points
            guard !regions.isEmpty, keys.allSatisfy({ containsAny(regions, $0) }) else {
                return .unchanged
            }
            return .moveWhole
        }

        // Fast path: every defining point enclosed — move whole (keeps local
        // geometry byte-identical, like the fully-enclosed AutoCAD case).
        let all = geometry.flatMap {
            definingPoints(of: $0, under: entity.transform, in: entity)
        }
        if !regions.isEmpty, !all.isEmpty,
           all.allSatisfy({ containsAny(regions, $0) }) {
            return .moveWhole
        }

        var out = geometry
        var changed = false
        for index in out.indices {
            guard let next = stretchedPrimitive(
                out[index], transform: entity.transform,
                regions: regions, by: delta)
            else { continue }
            out[index] = next
            changed = true
        }
        return changed ? .stretched(out) : .unchanged
    }

    // MARK: - Region helpers

    static func containsAny(_ regions: [StretchRegion], _ point: Vector3) -> Bool {
        regions.contains { $0.contains(point) }
    }

    /// World-space bounding-box corners (XY) used when a primitive exposes
    /// no defining points (e.g. tables).
    static func boundingCorners(of entity: CADEntity) -> [Vector3] {
        guard let box = entity.worldBoundingBox else { return [] }
        let z = box.min.z
        return [
            Vector3(x: box.min.x, y: box.min.y, z: z),
            Vector3(x: box.max.x, y: box.min.y, z: z),
            Vector3(x: box.max.x, y: box.max.y, z: z),
            Vector3(x: box.min.x, y: box.max.y, z: z),
        ]
    }

    static func isFullyEnclosed(entity: CADEntity, regions: [StretchRegion]) -> Bool {
        guard !regions.isEmpty else { return false }
        let corners = boundingCorners(of: entity)
        guard !corners.isEmpty else { return false }
        return corners.allSatisfy { containsAny(regions, $0) }
    }

    // MARK: - Defining points (world space)

    /// World-space points that decide enclosure for one primitive.
    static func definingPoints(
        of primitive: CADPrimitive,
        under transform: Transform3D,
        in entity: CADEntity
    ) -> [Vector3] {
        switch primitive {
        case .line(let start, let end, _):
            return [transform.transformPoint(start), transform.transformPoint(end)]
        case .polyline(let path, _):
            return path.vertices.map { transform.transformPoint($0.position) }
        case .spline(let controlPoints, _, _, _, _):
            return controlPoints.map { transform.transformPoint($0) }
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            return [
                transform.transformPoint(center),
                transform.transformPoint(Vector3(
                    x: center.x + cos(startAngle) * radius,
                    y: center.y + sin(startAngle) * radius, z: center.z)),
                transform.transformPoint(Vector3(
                    x: center.x + cos(endAngle) * radius,
                    y: center.y + sin(endAngle) * radius, z: center.z)),
            ]
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            return rectCorners(origin: origin, size: size).map { transform.transformPoint($0) }
        case .polygon(let points, _), .fillPolygon(let points, _):
            return points.map { transform.transformPoint($0) }
        case .fillComplexPolygon(let outer, let holes, _):
            return (outer + holes.flatMap { $0 }).map { transform.transformPoint($0) }
        case .gradient(let outer, let holes, _, _, _, _):
            return (outer + holes.flatMap { $0 }).map { transform.transformPoint($0) }
        case .hatch(let boundary, _, _, _, _, _):
            return boundary.map { transform.transformPoint($0) }
        case .hatchPath(let boundary, let holes, _, _, _, _, _):
            return (boundary.points + holes.flatMap(\.points)).map { transform.transformPoint($0) }
        case .penStroke(let vertices, _, _):
            return vertices.map { transform.transformPoint($0.position) }
        case .text(let position, _, _, _, _, _, _, _, _),
             .point(let position, _):
            return [transform.transformPoint(position)]
        case .ray(let start, _, _):
            return [transform.transformPoint(start)]
        case .xline(let point, _, _):
            return [transform.transformPoint(point)]
        case .circle, .ellipse, .image:
            return CADGeometryMath.worldPointsForPrimitive(primitive, transform: transform)
        case .table(let data, let origin, _):
            _ = data
            let points = [transform.transformPoint(origin)]
            let corners = boundingCorners(of: entity)
            return corners.isEmpty ? points : corners
        }
    }

    static func rectCorners(origin: Vector3, size: Vector3) -> [Vector3] {
        [
            origin,
            Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
            Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
            Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
        ]
    }

    // MARK: - Per-primitive stretch

    /// Stretched copy of one primitive, or nil when nothing in it moved.
    /// `transform` is the owning entity transform (world mapping runs
    /// through it and back through its inverse).
    static func stretchedPrimitive(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        regions: [StretchRegion],
        by delta: Vector3
    ) -> CADPrimitive? {
        guard !regions.isEmpty else { return nil }
        let inverse = transform.inverse()
        func enclosed(local: Vector3) -> Bool {
            containsAny(regions, transform.transformPoint(local))
        }
        func moved(local: Vector3) -> Vector3 {
            inverse.transformPoint(transform.transformPoint(local) + delta)
        }
        func shiftIfEnclosed(local: Vector3) -> Vector3 {
            enclosed(local: local) ? moved(local: local) : local
        }

        switch primitive {
        case .line(let start, let end, let color):
            guard enclosed(local: start) || enclosed(local: end) else { return nil }
            return .line(start: shiftIfEnclosed(local: start),
                         end: shiftIfEnclosed(local: end), color: color)

        case .polyline(let path, let color):
            var updated = path
            var changed = false
            for index in updated.vertices.indices {
                let position = updated.vertices[index].position
                guard enclosed(local: position) else { continue }
                updated.vertices[index].position = moved(local: position)
                changed = true
            }
            // Bulges/widths ride on their vertex records; `isClosed` is
            // untouched so a closed polyline stays closed.
            return changed ? .polyline(path: updated, color: color) : nil

        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            var updated = controlPoints
            var changed = false
            for index in updated.indices {
                guard enclosed(local: updated[index]) else { continue }
                updated[index] = moved(local: updated[index])
                changed = true
            }
            return changed
                ? .spline(controlPoints: updated, knots: knots,
                          degree: degree, weights: weights, color: color) : nil

        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            let startPoint = Vector3(
                x: center.x + cos(startAngle) * radius,
                y: center.y + sin(startAngle) * radius, z: center.z)
            let endPoint = Vector3(
                x: center.x + cos(endAngle) * radius,
                y: center.y + sin(endAngle) * radius, z: center.z)
            let moveCenter = enclosed(local: center)
            let moveStart = enclosed(local: startPoint)
            let moveEnd = enclosed(local: endPoint)
            guard moveCenter || moveStart || moveEnd else { return nil }
            // Re-solve from the moved endpoints + center: radius follows the
            // moved start point, angles follow both moved endpoints.
            let world = { (local: Vector3, move: Bool) -> Vector3 in
                let worldPoint = transform.transformPoint(local)
                return move ? worldPoint + delta : worldPoint
            }
            let newCenter = inverse.transformPoint(world(center, moveCenter))
            let newStart = inverse.transformPoint(world(startPoint, moveStart))
            let newEnd = inverse.transformPoint(world(endPoint, moveEnd))
            let newRadius = newStart.distance(to: newCenter)
            guard newRadius > 1e-9 else { return nil }
            let newStartAngle = atan2(newStart.y - newCenter.y, newStart.x - newCenter.x)
            let newEndAngle = atan2(newEnd.y - newCenter.y, newEnd.x - newCenter.x)
            return .arc(center: newCenter, radius: newRadius,
                        startAngle: newStartAngle, endAngle: newEndAngle, color: color)

        case .rect(let origin, let size, let color):
            return stretchedRect(origin: origin, size: size, color: color,
                                 make: { .rect(origin: $0, size: $1, color: $2) },
                                 enclosed: enclosed, moved: moved)
        case .fillRect(let origin, let size, let color):
            return stretchedRect(origin: origin, size: size, color: color,
                                 make: { .fillRect(origin: $0, size: $1, color: $2) },
                                 enclosed: enclosed, moved: moved)

        case .polygon(let points, let color):
            return stretchedPoints(points, enclosed: enclosed, moved: moved)
                .map { .polygon(points: $0, color: color) }
        case .fillPolygon(let points, let color):
            return stretchedPoints(points, enclosed: enclosed, moved: moved)
                .map { .fillPolygon(points: $0, color: color) }
        case .fillComplexPolygon(let outer, let holes, let color):
            guard let newOuter = stretchedPoints(outer, enclosed: enclosed, moved: moved) else {
                return stretchedHoleSet(holes, enclosed: enclosed, moved: moved)
                    .map { .fillComplexPolygon(outer: outer, holes: $0, color: color) }
            }
            let newHoles = holes.map {
                stretchedPoints($0, enclosed: enclosed, moved: moved) ?? $0
            }
            return .fillComplexPolygon(outer: newOuter, holes: newHoles, color: color)
        case .gradient(let outer, let holes, let name, let angle, let c1, let c2):
            guard let newOuter = stretchedPoints(outer, enclosed: enclosed, moved: moved) else {
                return stretchedHoleSet(holes, enclosed: enclosed, moved: moved)
                    .map { .gradient(outer: outer, holes: $0, gradientName: name,
                                     angle: angle, color1: c1, color2: c2) }
            }
            let newHoles = holes.map {
                stretchedPoints($0, enclosed: enclosed, moved: moved) ?? $0
            }
            return .gradient(outer: newOuter, holes: newHoles, gradientName: name,
                              angle: angle, color1: c1, color2: c2)
        case .hatch(let boundary, let pattern, let scale, let angle, let color, let background):
            return stretchedPoints(boundary, enclosed: enclosed, moved: moved)
                .map { .hatch(boundary: $0, pattern: pattern, scale: scale,
                              angle: angle, color: color, backgroundColor: background) }
        case .hatchPath(let boundary, let holes, let pattern, let scale,
                        let angle, let color, let background):
            var newBoundary = boundary
            var changed = false
            for index in newBoundary.vertices.indices {
                let position = newBoundary.vertices[index].position
                guard enclosed(local: position) else { continue }
                newBoundary.vertices[index].position = moved(local: position)
                changed = true
            }
            var newHoles = holes
            for hole in newHoles.indices {
                for vertex in newHoles[hole].vertices.indices {
                    let position = newHoles[hole].vertices[vertex].position
                    guard enclosed(local: position) else { continue }
                    newHoles[hole].vertices[vertex].position = moved(local: position)
                    changed = true
                }
            }
            return changed
                ? .hatchPath(boundary: newBoundary, holes: newHoles, pattern: pattern,
                             scale: scale, angle: angle, color: color,
                             backgroundColor: background) : nil

        case .penStroke(let vertices, let baseLineWeight, let color):
            var updated = vertices
            var changed = false
            for index in updated.indices {
                guard enclosed(local: updated[index].position) else { continue }
                updated[index].position = moved(local: updated[index].position)
                changed = true
            }
            return changed
                ? .penStroke(vertices: updated, baseLineWeight: baseLineWeight, color: color) : nil

        // Whole-or-nothing types: shift by the mapped displacement only when
        // every defining point is enclosed.
        case .text(let position, let text, let height, let rotation,
                   let style, let alignH, let alignV, let mtextWidth, let color):
            guard enclosed(local: position) else { return nil }
            return .text(position: moved(local: position), text: text, height: height,
                         rotation: rotation, style: style, alignH: alignH, alignV: alignV,
                         mtextWidth: mtextWidth, color: color)
        case .point(let position, let color):
            guard enclosed(local: position) else { return nil }
            return .point(position: moved(local: position), color: color)
        case .ray(let start, let direction, let color):
            guard enclosed(local: start) else { return nil }
            return .ray(start: moved(local: start), direction: direction, color: color)
        case .xline(let point, let direction, let color):
            guard enclosed(local: point) else { return nil }
            return .xline(point: moved(local: point), direction: direction, color: color)
        case .circle(let center, let radius, let color):
            guard enclosed(local: center) else { return nil }
            return .circle(center: moved(local: center), radius: radius, color: color)
        case .ellipse(let center, let majorAxis, let minorRatio, let color):
            guard enclosed(local: center) else { return nil }
            return .ellipse(center: moved(local: center), majorAxis: majorAxis,
                            minorRatio: minorRatio, color: color)
        case .image(let insertion, let uAxis, let vAxis, let name, let clip, let tint):
            guard enclosed(local: insertion) else { return nil }
            return .image(insertion: moved(local: insertion), uAxis: uAxis, vAxis: vAxis,
                          imageName: name, clipBoundary: clip, tint: tint)
        case .table(let data, let origin, let color):
            // Tables expose only their origin as a defining point; fall back
            // to bounds corners when the document has them.
            let keys = boundingCornersOfTable(origin: origin, transform: transform)
            guard !keys.isEmpty, keys.allSatisfy({ containsAny(regions, $0) }) else { return nil }
            return .table(data: data, origin: moved(local: origin), color: color)
        }
    }

    // MARK: - Small builders

    /// Moved copy of a point list, or nil when no point was enclosed.
    static func stretchedPoints(
        _ points: [Vector3],
        enclosed: (Vector3) -> Bool,
        moved: (Vector3) -> Vector3
    ) -> [Vector3]? {
        var updated = points
        var changed = false
        for index in updated.indices {
            guard enclosed(updated[index]) else { continue }
            updated[index] = moved(updated[index])
            changed = true
        }
        return changed ? updated : nil
    }

    /// Moved copy of a hole set, or nil when no hole vertex was enclosed.
    static func stretchedHoleSet(
        _ holes: [[Vector3]],
        enclosed: (Vector3) -> Bool,
        moved: (Vector3) -> Vector3
    ) -> [[Vector3]]? {
        var updated = holes
        var changed = false
        for hole in updated.indices {
            if let next = stretchedPoints(updated[hole], enclosed: enclosed, moved: moved) {
                updated[hole] = next
                changed = true
            }
        }
        return changed ? updated : nil
    }

    static func stretchedRect(
        origin: Vector3, size: Vector3, color: ColorRGBA?,
        make: (Vector3, Vector3, ColorRGBA?) -> CADPrimitive,
        enclosed: (Vector3) -> Bool,
        moved: (Vector3) -> Vector3
    ) -> CADPrimitive? {
        let corners = rectCorners(origin: origin, size: size)
        guard let movedCorners = stretchedPoints(corners, enclosed: enclosed, moved: moved) else {
            return nil
        }
        let xs = movedCorners.map(\.x), ys = movedCorners.map(\.y), zs = movedCorners.map(\.z)
        let newOrigin = Vector3(x: xs.min() ?? origin.x, y: ys.min() ?? origin.y,
                                z: zs.min() ?? origin.z)
        let newSize = Vector3(x: (xs.max() ?? 0) - newOrigin.x,
                              y: (ys.max() ?? 0) - newOrigin.y,
                              z: (zs.max() ?? 0) - newOrigin.z)
        return make(newOrigin, newSize, color)
    }

    /// World-space keys for a table primitive: bounds corners when known,
    /// else the transformed origin.
    static func boundingCornersOfTable(origin: Vector3, transform: Transform3D) -> [Vector3] {
        [transform.transformPoint(origin)]
    }
}
