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

    // MARK: - Shared pick ordering

    /// Shared pick ordering: higher draw order wins; ties break by smaller
    /// area (1e-3 tolerance), then by exact distance. Both `hitTest` and
    /// `allHitsAt` use this so row 1 always equals `hitTest`.
    static func isBetterHit(
        order: Int, area: Double, dist: Double,
        bestOrder: Int, bestArea: Double, bestDist: Double
    ) -> Bool {
        if order != bestOrder { return order > bestOrder }
        if abs(area - bestArea) > 1e-3 { return area < bestArea }
        return dist < bestDist
    }

    /// Squared distance from the point to an entity's geometry, or nil when
    /// outside threshold. Mirrors the `hitTest` per-entity computation so the
    /// Selection list never offers what a click could not pick.
    private static func hitDistance(
        for entity: CADEntity,
        geometry: [CADPrimitive],
        point: Vector3,
        threshold: Double,
        document: CADDocument,
        layersByName: [String: Layer],
        simplifyComplexBlocks: Bool
    ) -> Double? {
        let t2 = threshold * threshold
        let frameDistance = CADClipFrameSettings.isVisible(for: entity)
            ? CADClipMetadata.boundaryDistanceSquared(worldPoint: point, entity: entity)
            : nil
        guard CADClipMetadata.accepts(worldPoint: point, entity: entity)
                || frameDistance.map({ $0 <= t2 }) == true else { return nil }
        var hitDist: Double? = frameDistance.flatMap { $0 <= t2 ? $0 : nil }
        let transforms = instanceTransforms(for: entity, document: document)
        let primStyles = document.primitiveStyles(for: entity)
        let isXrefEntity = entity.blockID.map { document.block(for: $0)?.isXref == true } ?? false
        if simplifyComplexBlocks && geometry.count > 50 && !isXrefEntity {
            guard document.anyPrimitiveVisible(for: entity, layersByName: layersByName)
                    || hitDist != nil else { return nil }
            var minDist = Double.infinity
            let sourceBox = entity.blockID.flatMap { document.block(for: $0)?.localBoundingBox }
                ?? entity.localBoundingBox
            if let sourceBox {
                for transform in transforms {
                    let box = BoundingBox3D(transforming: sourceBox, by: transform)
                    if let d = boundingBoxDistSq(point, box: box, threshold: threshold) {
                        minDist = min(minDist, d)
                    }
                }
            }
            if minDist <= t2 { hitDist = min(hitDist ?? .infinity, minDist) }
            if hitDist == nil, isInsideFill(point: point, geometry: geometry, transforms: transforms, primStyles: primStyles, layersByName: layersByName) {
                hitDist = 0
            }
        } else {
            var minDist: Double = .infinity
            let grid = entity.blockID.flatMap { document.spatialGrid(forBlock: $0) }
            for transform in transforms {
                let candidates = gridCandidates(
                    grid: grid, geometryCount: geometry.count,
                    point: point, transform: transform, radius: threshold)
                for primIndex in candidates {
                    guard CADPrimitiveVisibility.isVisible(
                        style: primStyles[primIndex], layersByName: layersByName) else { continue }
                    if let d = distanceSqToPrimitive(geometry[primIndex], point: point, transform: transform, t2: t2, textContext: document.textBoundsContext(for: entity), textIndex: primIndex) {
                        if d < minDist { minDist = d }
                    }
                }
            }
            if minDist <= t2 { hitDist = min(hitDist ?? .infinity, minDist) }
        }
        return hitDist
    }

    /// True when the point lies inside any fill-like primitive (hatch,
    /// solid fill, image/table rect). Used by the complex-block shortcut
    /// so interior clicks still hit even when far from bbox edges.
    private static func isInsideFill(
        point: Vector3,
        geometry: [CADPrimitive],
        transforms: [Transform3D],
        primStyles: [Int: CADPrimitiveStyle],
        layersByName: [String: Layer]
    ) -> Bool {
        for (index, prim) in geometry.enumerated() {
            guard CADPrimitiveVisibility.isVisible(style: primStyles[index], layersByName: layersByName) else { continue }
            for transform in transforms {
                switch prim {
                case .hatch(let boundary, _, _, _, _, _):
                    if pointInPolygon(point, boundary.map { transform.transformPoint($0) }) { return true }
                case .hatchPath(let boundary, let holes, _, _, _, _, _):
                    let outer = boundary.tessellatedPoints().map { transform.transformPoint($0) }
                    guard pointInPolygon(point, outer) else { continue }
                    var inHole = false
                    for hole in holes {
                        if pointInPolygon(point, hole.tessellatedPoints().map { transform.transformPoint($0) }) { inHole = true; break }
                    }
                    if !inHole { return true }
                case .fillPolygon(let pts, _):
                    if pointInPolygon(point, pts.map { transform.transformPoint($0) }) { return true }
                case .fillRect(let origin, let size, _):
                    let corners = [
                        transform.transformPoint(origin),
                        transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)),
                        transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)),
                        transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)),
                    ]
                    if pointInPolygon(point, corners) { return true }
                case .fillComplexPolygon(let outer, let holes, _),
                     .gradient(let outer, let holes, _, _, _, _):
                    let oc = outer.map { transform.transformPoint($0) }
                    guard pointInPolygon(point, oc) else { continue }
                    var inHole = false
                    for hole in holes {
                        if pointInPolygon(point, hole.map { transform.transformPoint($0) }) { inHole = true; break }
                    }
                    if !inHole { return true }
                case .image(let insertion, let uAxis, let vAxis, _, _, _):
                    let c0 = transform.transformPoint(insertion)
                    let c1 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
                    let c2 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
                    let c3 = transform.transformPoint(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
                    if pointInPolygon(point, [c0, c1, c2, c3]) { return true }
                case .table(let data, let origin, _):
                    let size = DataTableTessellator.computeSize(data: data)
                    let c0 = transform.transformPoint(origin)
                    let c1 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y, z: origin.z))
                    let c2 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y + size.height, z: origin.z))
                    let c3 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.height, z: origin.z))
                    if pointInPolygon(point, [c0, c1, c2, c3]) { return true }
                default:
                    continue
                }
            }
        }
        return false
    }

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
        let layersByName = document.layersByUppercasedName()

        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            let frameDistance = CADClipFrameSettings.isVisible(for: entity)
                ? CADClipMetadata.boundaryDistanceSquared(worldPoint: point, entity: entity)
                : nil
            guard CADClipMetadata.accepts(worldPoint: point, entity: entity)
                    || frameDistance.map({ $0 <= t2 }) == true else { return }
            var hitDist: Double? = frameDistance.flatMap { $0 <= t2 ? $0 : nil }
            
            let transforms = instanceTransforms(for: entity, document: document)
            let primStyles = document.primitiveStyles(for: entity)
            let isXrefEntity = entity.blockID.map { document.block(for: $0)?.isXref == true } ?? false
            if simplifyComplexBlocks && geometry.count > 50 && !isXrefEntity {
                guard document.anyPrimitiveVisible(for: entity, layersByName: layersByName)
                        || hitDist != nil else { return }
                var minDist = Double.infinity
                let sourceBox = entity.blockID.flatMap { document.block(for: $0)?.localBoundingBox }
                    ?? entity.localBoundingBox
                if let sourceBox {
                    for transform in transforms {
                        let box = BoundingBox3D(transforming: sourceBox, by: transform)
                        if let d = boundingBoxDistSq(point, box: box, threshold: threshold) {
                            minDist = min(minDist, d)
                        }
                    }
                }
                if minDist <= t2 { hitDist = min(hitDist ?? .infinity, minDist) }
                if hitDist == nil, isInsideFill(point: point, geometry: geometry, transforms: transforms, primStyles: primStyles, layersByName: layersByName) {
                    hitDist = 0
                }
            } else {
                var minDist: Double = .infinity
                let grid = entity.blockID.flatMap { document.spatialGrid(forBlock: $0) }
                for transform in transforms {
                    let candidates = gridCandidates(
                        grid: grid, geometryCount: geometry.count,
                        point: point, transform: transform, radius: threshold)
                    for primIndex in candidates {
                        guard CADPrimitiveVisibility.isVisible(
                            style: primStyles[primIndex], layersByName: layersByName) else { continue }
                        if let d = distanceSqToPrimitive(geometry[primIndex], point: point, transform: transform, t2: t2, textContext: document.textBoundsContext(for: entity), textIndex: primIndex) {
                            if d < minDist { minDist = d }
                        }
                    }
                }
                if minDist <= t2 { hitDist = min(hitDist ?? .infinity, minDist) }
            }
            
            if let d = hitDist {
                let area = entity.worldBoundingBox?.area ?? 0.0
                let order = entity.drawOrder
                
                let replace = isBetterHit(
                    order: order, area: area, dist: d,
                    bestOrder: bestDrawOrder, bestArea: bestArea, bestDist: bestDist)
                
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

    /// Returns all entities whose geometry is within threshold of the point,
    /// sorted topmost-first with the shared pick ordering (row 1 always
    /// equals `hitTest`). Used for the Selection Cycling list when entities
    /// overlap at the click point.
    public static func allHitsAt(
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> [(handle: UUID, label: String)] {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        let layersByName = document.layersByUppercasedName()
        var scored: [(handle: UUID, order: Int, area: Double, dist: Double)] = []

        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            guard let d = hitDistance(
                for: entity, geometry: geometry, point: point,
                threshold: threshold, document: document,
                layersByName: layersByName,
                simplifyComplexBlocks: simplifyComplexBlocks
            ) else { return }
            scored.append((
                handle: entity.handle, order: entity.drawOrder,
                area: entity.worldBoundingBox?.area ?? 0.0, dist: d))
        }

        scored.sort {
            isBetterHit(
                order: $0.order, area: $0.area, dist: $0.dist,
                bestOrder: $1.order, bestArea: $1.area, bestDist: $1.dist)
        }

        // Suffix the short handle only when sibling rows would otherwise
        // read identically (e.g. two lines on the same layer).
        var baseCounts: [String: Int] = [:]
        var bases: [(UUID, String)] = []
        bases.reserveCapacity(scored.count)
        for hit in scored {
            guard let entity = document.entity(for: hit.handle) else { continue }
            let layerName = document.layer(for: entity.layerID)?.name ?? "0"
            var base = "\(CADSelectionCyclingLabels.displayType(for: entity, document: document)) - \(layerName)"
            if CADSelectionCyclingLabels.isLocked(entity, document: document) {
                base += " [locked]"
            }
            baseCounts[base, default: 0] += 1
            bases.append((hit.handle, base))
        }
        return bases.map { (handle, base) in
            let label = (baseCounts[base] ?? 0) > 1
                ? "\(base) (#\(handle.uuidString.prefix(8)))"
                : base
            return (handle, label)
        }
    }

    /// True when two or more DISTINCT top-level entities are within threshold
    /// of the point. Exits on the second distinct handle, so hovering a
    /// single polyline vertex or a multi-primitive block never self-triggers.
    /// Deduplication happens inside the walk (not as a post-pass).
    public static func hasMultipleHitsAt(
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        simplifyComplexBlocks: Bool = true
    ) -> Bool {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        var seen: [UUID] = []
        var found = false
        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            guard !found else { return }
            guard hitEntity(entity, point: point, threshold: threshold,
                             document: document, simplifyComplexBlocks: simplifyComplexBlocks,
                             geometry: geometry) else { return }
            if !seen.contains(entity.handle) {
                seen.append(entity.handle)
                if seen.count >= 2 { found = true }
            }
        }
        return found
    }

    /// A single nested pick: the closest block-member primitive under the
    /// point, with the insert instance transform that carries it to world
    /// space. Powers NCOPY (copy nested geometry out of blocks/xrefs).
    public struct NestedHit: Sendable {
        public var entity: CADEntity
        public var primitiveIndex: Int
        public var transform: Transform3D
        public var distanceSquared: Double
    }

    /// Returns the closest nested (block-member) primitive under the point,
    /// or nil. Loose entities are reported with their own transform and
    /// their local-geometry index; `excluding` skips freshly copied
    /// entities so NCOPY picks never hit their own output.
    /// Closest primitive of one entity under the point, or nil. Shared
    /// by the global nested pick and per-row Selection list annotation
    /// (each block row must be judged by its own members, not by
    /// whichever pile member happens to be globally closest).
    private static func bestNestedHit(
        for entity: CADEntity,
        geometry: [CADPrimitive],
        point: Vector3,
        threshold: Double,
        document: CADDocument,
        layersByName: [String: Layer]
    ) -> NestedHit? {
        let t2 = threshold * threshold
        var best: NestedHit?
        let primStyles = document.primitiveStyles(for: entity)
        for transform in instanceTransforms(for: entity, document: document) {
            let candidates = gridCandidates(
                grid: entity.blockID.flatMap { document.spatialGrid(forBlock: $0) },
                geometryCount: geometry.count,
                point: point, transform: transform, radius: threshold)
            for primIndex in candidates {
                guard CADPrimitiveVisibility.isVisible(
                    style: primStyles[primIndex],
                    layersByName: layersByName) else { continue }
                guard let dist = distanceSqToPrimitive(
                    geometry[primIndex], point: point,
                    transform: transform, t2: t2, textContext: document.textBoundsContext(for: entity), textIndex: primIndex) else { continue }
                if dist < (best?.distanceSquared ?? .infinity) {
                    best = NestedHit(
                        entity: entity, primitiveIndex: primIndex,
                        transform: transform, distanceSquared: dist)
                }
            }
        }
        return best
    }

    /// Per-entity nested pick: the closest member primitive of `entity`
    /// under the point, ignoring every other entity in the pile.
    public static func nestedHit(
        for entity: CADEntity,
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0
    ) -> NestedHit? {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        guard CADClipMetadata.accepts(worldPoint: point, entity: entity),
              let geometry = document.resolvedGeometry(for: entity),
              !geometry.isEmpty else { return nil }
        return bestNestedHit(
            for: entity, geometry: geometry, point: point,
            threshold: threshold, document: document,
            layersByName: document.layersByUppercasedName())
    }

    public static func nestedHitTest(
        worldX: Double, worldY: Double,
        document: CADDocument,
        threshold: Double = 3.0,
        excluding: Set<UUID> = []
    ) -> NestedHit? {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        var best: NestedHit?
        let layersByName = document.layersByUppercasedName()
        forEachCandidate(in: document, near: point, threshold: threshold) { entity, geometry in
            guard !excluding.contains(entity.handle) else { return }
            guard CADClipMetadata.accepts(worldPoint: point, entity: entity) else { return }
            guard let candidate = bestNestedHit(
                for: entity, geometry: geometry, point: point,
                threshold: threshold, document: document,
                layersByName: layersByName) else { return }
            if candidate.distanceSquared < (best?.distanceSquared ?? .infinity) {
                best = candidate
            }
        }
        return best
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
        let frameDistance = CADClipFrameSettings.isVisible(for: entity)
            ? CADClipMetadata.boundaryDistanceSquared(worldPoint: point, entity: entity)
            : nil
        if frameDistance.map({ $0 <= threshold * threshold }) == true { return true }
        guard CADClipMetadata.accepts(worldPoint: point, entity: entity) else { return false }
        guard let wbb = entity.worldBoundingBox else { return false }
        let expanded = wbb.expanded(by: threshold)
        guard expanded.contains(point) else { return false }

        let geom = geometry ?? document.resolvedGeometry(for: entity)
        guard let geom, !geom.isEmpty else { return false }

        let t2 = threshold * threshold

        let transforms = instanceTransforms(for: entity, document: document)
        let layersByName = document.layersByUppercasedName()
        let primStyles = document.primitiveStyles(for: entity)
        let isXrefEntity = entity.blockID.map { document.block(for: $0)?.isXref == true } ?? false
        if simplifyComplexBlocks && geom.count > 50 && !isXrefEntity {
            guard document.anyPrimitiveVisible(for: entity, layersByName: layersByName) else {
                return false
            }
            let sourceBox = entity.blockID.flatMap { document.block(for: $0)?.localBoundingBox }
                ?? entity.localBoundingBox
            if let sourceBox {
                for transform in transforms {
                    let box = BoundingBox3D(transforming: sourceBox, by: transform)
                    if boundingBoxDistSq(point, box: box, threshold: threshold) != nil { return true }
                }
            }
            if isInsideFill(point: point, geometry: geom, transforms: transforms, primStyles: primStyles, layersByName: layersByName) { return true }
            return false
        }

        let grid = entity.blockID.flatMap { document.spatialGrid(forBlock: $0) }
        for transform in transforms {
            let candidates = gridCandidates(
                grid: grid, geometryCount: geom.count,
                point: point, transform: transform, radius: threshold)
            for primIndex in candidates {
                guard CADPrimitiveVisibility.isVisible(
                    style: primStyles[primIndex], layersByName: layersByName) else { continue }
                if distanceSqToPrimitive(geom[primIndex], point: point, transform: transform, t2: t2, textContext: document.textBoundsContext(for: entity), textIndex: primIndex) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Distance to Primitive

    /// Returns squared distance from a point to the primitive if within
    /// threshold, nil otherwise.
    /// Grid candidate indices near a world point, or all indices when
    /// the block has no grid.
    private static func gridCandidates(
        grid: CADBlockSpatialGrid?, geometryCount: Int,
        point: Vector3, transform: Transform3D, radius: Double
    ) -> [Int] {
        guard let grid else { return Array(0..<geometryCount) }
        let local = transform.inverse().transformPoint(point)
        let scale = transform.scale
        let minScale = max(min(abs(scale.x), abs(scale.y)), 1e-9)
        return grid.candidateIndices(near: local, radius: radius / minScale)
    }

    public static func distanceSqToPrimitive(
        _ prim: CADPrimitive, point: Vector3, transform: Transform3D, t2: Double,
        textContext: CADTextBoundsContext? = nil, textIndex: Int? = nil
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
            if pointInPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .polygon(let pts, _):
            let corners = pts.map { transform.transformPoint($0) }
            return minEdgeDistSq(point, corners)

        case .polyline(let path, _):
            let corners = path.tessellatedPoints().map { transform.transformPoint($0) }
            return minEdgeDistSqOpen(point, corners)

        case .fillPolygon(let pts, _):
            let corners = pts.map { transform.transformPoint($0) }
            if pointInPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .fillComplexPolygon(let outer, let holes, _),
             .gradient(let outer, let holes, _, _, _, _):
            let outerCorners = outer.map { transform.transformPoint($0) }
            let insideOuter = pointInPolygon(point, outerCorners)
            var insideHole = false
            for hole in holes {
                if pointInPolygon(point, hole.map { transform.transformPoint($0) }) {
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

        case .penStroke(let vertices, _, _):
            // AABB early exit — skip expensive segment iteration if the world BB
            // doesn't intersect the search radius.
            guard vertices.count >= 2 else { return nil }
            var best: Double = .infinity
            for i in 0..<(vertices.count - 1) {
                let ws = transform.transformPoint(vertices[i].position)
                let we = transform.transformPoint(vertices[i + 1].position)
                let d = CADGeometryMath.pointToSegmentDistSq(point, ws, we)
                if d < best { best = d }
            }
            return best <= t2 ? best : nil

        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
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
                mtextWidth: mtextWidth,
                style: style,
                context: textContext,
                primitiveIndex: textIndex)

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
            if pointInPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners)

        case .hatchPath(let boundary, let holes, _, _, _, _, _):
            let corners = boundary.tessellatedPoints().map { transform.transformPoint($0) }
            let holeRings = holes.map { $0.tessellatedPoints().map(transform.transformPoint) }
            let inHole = holeRings.contains { pointInPolygon(point, $0) }
            if pointInPolygon(point, corners) && !inHole { return 0 }
            var best = minEdgeDistSq(point, corners) ?? .infinity
            for ring in holeRings {
                best = min(best, minEdgeDistSq(point, ring) ?? .infinity)
            }
            return best <= t2 ? best : nil

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
        case .xline(let point, let direction, _):
            let ws = transform.transformPoint(point)
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
            let backEnd = Vector3(x: ws.x - wdx * 100_000, y: ws.y - wdy * 100_000, z: ws.z)
            let d = CADGeometryMath.pointToSegmentDistSq(point, backEnd, farEnd)
            return d <= t2 ? d : nil
        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let c0 = transform.transformPoint(insertion)
            let c1 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
            let c2 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
            let c3 = transform.transformPoint(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            let corners = [c0, c1, c2, c3]
            if pointInPolygon(point, corners) { return 0 }
            return minEdgeDistSq(point, corners).flatMap { $0 <= t2 ? $0 : nil }
        case .table(let data, let origin, _):
            // Hit test: check against table's derived bounding rect
            let size = DataTableTessellator.computeSize(data: data)
            let c0 = transform.transformPoint(origin)
            let c1 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y, z: origin.z))
            let c2 = transform.transformPoint(Vector3(x: origin.x + size.width, y: origin.y + size.height, z: origin.z))
            let c3 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.height, z: origin.z))
            let corners = [c0, c1, c2, c3]
            if pointInPolygon(point, corners) { return 0 }
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
                // Derived paper-space projections are render-only.
                guard !entity.isViewportProjected else { continue }
                guard let layer = document.layer(for: entity.layerID), LayerAccess.isPickable(layer) else { continue }
                guard !document.isIsolatedHidden(entity.handle) else { continue }
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
                // Derived paper-space projections are render-only.
                guard !entity.isViewportProjected else { continue }
                guard let layer = document.layer(for: entity.layerID), LayerAccess.isPickable(layer) else { continue }
                guard !document.isIsolatedHidden(entity.handle) else { continue }
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

    private static func instanceTransforms(
        for entity: CADEntity,
        document: CADDocument
    ) -> [Transform3D] {
        guard let array = entity.arrayData else { return [entity.transform] }
        let path = CADArrayPathResolver.points(
            for: array,
            containerTransform: entity.transform,
            document: document)
        return array.evaluatedInstances(pathPoints: path).map {
            entity.transform.multiplying(by: $0.transform)
        }
    }

    private static func boundingBoxDistSq(
        _ point: Vector3,
        box: BoundingBox3D,
        threshold: Double
    ) -> Double? {
        let corners = [
            Vector3(x: box.min.x, y: box.min.y, z: 0),
            Vector3(x: box.max.x, y: box.min.y, z: 0),
            Vector3(x: box.max.x, y: box.max.y, z: 0),
            Vector3(x: box.min.x, y: box.max.y, z: 0)
        ]
        var best = Double.infinity
        for index in 0..<4 {
            best = min(best, CADGeometryMath.pointToSegmentDistSq(
                point, corners[index], corners[(index + 1) % 4]))
        }
        return best <= threshold * threshold ? best : nil
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

    /// Returns true if the 2D point lies inside a polygon of any shape
    /// (even-odd ray cast). Replaces the old convex-only sign test, which
    /// rejected interiors of concave boundaries such as L-shaped hatches.
    private static func pointInPolygon(_ p: Vector3, _ poly: [Vector3]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let pi = poly[i]
            let pj = poly[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}