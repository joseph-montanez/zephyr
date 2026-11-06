import Foundation
import SwiftSDL
import ZephyrKernel

// =========================================================================
// MARK: - TrimCriterion
// =========================================================================

/// Criteria used to determine which portion/interval of an entity to trim.
public enum TrimCriterion: Sendable {
    /// Single point click in world coordinates.
    case click(point: Vector3)
    /// Fence segment in world coordinates.
    case fence(p1: Vector3, p2: Vector3)
    /// Selection box in world coordinates (min, max, crossing vs window).
    case rect(min: Vector3, max: Vector3, isCrossing: Bool)
}

// =========================================================================
// MARK: - TrimGeometryEngine
// =========================================================================

/// Pure geometric engine for computing intersections and trimming CAD primitives.
@MainActor
public enum TrimGeometryEngine {

    // MARK: - Geometry Decomposition

    /// Explodes a primitive into a list of world-space line segments using the given transform.
    nonisolated public static func explode(primitive: CADPrimitive, t: Transform3D) -> [(Vector3, Vector3)] {
        func curvedSegmentCount(radius: Double, span: Double = 2.0 * .pi) -> Int {
            guard radius > 1e-12, span > 0 else { return 2 }
            let relativeChordError = 1e-7
            let maxStep = 2.0 * acos(max(-1.0, min(1.0, 1.0 - relativeChordError)))
            guard maxStep.isFinite, maxStep > 0 else { return 4096 }
            return max(2, min(4096, Int(ceil(span / maxStep))))
        }

        var segs: [(Vector3, Vector3)] = []
        switch primitive {
        case .line(let ls, let le, _):
            segs.append((t.transformPoint(ls), t.transformPoint(le)))
        case .polygon(let pts, _), .fillPolygon(let pts, _), .fillComplexPolygon(let pts, _, _), .gradient(let pts, _, _, _, _, _):
            guard pts.count >= 2 else { return [] }
            for i in 0..<(pts.count - 1) { segs.append((t.transformPoint(pts[i]), t.transformPoint(pts[i+1]))) }
            segs.append((t.transformPoint(pts.last!), t.transformPoint(pts.first!)))
        case .polyline(let path, _):
            let pts = path.tessellatedPoints(segmentsPerRadian: 48)
            guard pts.count >= 2 else { return [] }
            for i in 0..<(pts.count - 1) { segs.append((t.transformPoint(pts[i]), t.transformPoint(pts[i+1]))) }
        case .circle(let center, let radius, _):
            let seg = curvedSegmentCount(radius: radius)
            var pts: [Vector3] = []
            for i in 0..<seg {
                let a = 2.0 * Double.pi * Double(i) / Double(seg)
                pts.append(t.transformPoint(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)))
            }
            for i in 0..<(pts.count - 1) { segs.append((pts[i], pts[i+1])) }
            segs.append((pts.last!, pts.first!))
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * Double.pi }
            let seg = curvedSegmentCount(radius: radius, span: span)
            var pts: [Vector3] = []
            for i in 0...seg {
                let a = startAngle + span * Double(i) / Double(seg)
                pts.append(t.transformPoint(Vector3(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius, z: center.z)))
            }
            for i in 0..<(pts.count - 1) { segs.append((pts[i], pts[i+1])) }
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            let segsCount = curvedSegmentCount(radius: max(majorLen, abs(minorLen)))
            let rot = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(rot); let sinRot = sin(rot)
            for i in 0..<segsCount {
                let t1 = Double(i) * 2.0 * .pi / Double(segsCount)
                let t2a = Double((i + 1) % segsCount) * 2.0 * .pi / Double(segsCount)
                let p1 = Vector3(
                    x: majorLen * cos(t1) * cosRot - minorLen * sin(t1) * sinRot + center.x,
                    y: majorLen * cos(t1) * sinRot + minorLen * sin(t1) * cosRot + center.y,
                    z: center.z)
                let p2 = Vector3(
                    x: majorLen * cos(t2a) * cosRot - minorLen * sin(t2a) * sinRot + center.x,
                    y: majorLen * cos(t2a) * sinRot + minorLen * sin(t2a) * cosRot + center.y,
                    z: center.z)
                segs.append((t.transformPoint(p1), t.transformPoint(p2)))
            }
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let segmentCount = min(4096, max(512, controlPoints.count * 128))
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: w,
                segmentsPerSpan: max(4, segmentCount / 8))
            if evaluated.count >= 2 {
                for i in 0..<(evaluated.count - 1) {
                    segs.append((t.transformPoint(evaluated[i]), t.transformPoint(evaluated[i+1])))
                }
            }
        case .penStroke(let vertices, _, _):
            guard vertices.count >= 2 else { break }
            for i in 0..<(vertices.count - 1) {
                segs.append((t.transformPoint(vertices[i].position), t.transformPoint(vertices[i+1].position)))
            }
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ]
            for i in 0..<4 {
                segs.append((t.transformPoint(corners[i]), t.transformPoint(corners[(i+1)%4])))
            }
        default: break
        }
        return segs
    }

    /// Computes intersection points between a finite line segment and a circle.
    public static func intersectSegmentCircle(
        segmentA: Vector3, segmentB: Vector3,
        circleCenter: Vector3, radius: Double
    ) -> [Vector3] {
        // Canonical solver: ZephyrKernel line-arc intersection in a
        // locally shifted frame (robust at state-plane magnitudes).
        // Semantics preserved: t filtered to [-1e-9, 1+1e-9], z carried.
        let line = LineSeg2d(start: segmentA.point2d, end: segmentB.point2d)
        let arc = Arc2d(center: circleCenter.point2d, radius: radius,
                         startAngle: 0, sweep: 2.0 * .pi)
        let hits = Intersector2D.intersectLineArc(
            line, arc, extendLine: true, extendArc: false)
        let dx = segmentB.x - segmentA.x
        let dy = segmentB.y - segmentA.y
        var result: [Vector3] = []
        result.reserveCapacity(hits.count)
        for h in hits {
            let t = h.paramA
            guard t >= -1e-9 && t <= 1.0 + 1e-9 else { continue }
            if let last = result.last {
                let px = segmentA.x + t * dx, py = segmentA.y + t * dy
                let ddx = px - last.x, ddy = py - last.y
                if ddx * ddx + ddy * ddy <= 1e-24 { continue }
            }
            result.append(Vector3(x: segmentA.x + t * dx, y: segmentA.y + t * dy, z: segmentA.z))
        }
        return result
    }

    /// Extracts the color from a primitive, if it carries one.
    public static func colorForPrimitive(_ p: CADPrimitive) -> ColorRGBA? {
        switch p {
        case .line(_, _, let c): return c
        case .arc(_, _, _, _, let c): return c
        case .circle(_, _, let c): return c
        case .ellipse(_, _, _, let c): return c
        case .spline(_, _, _, _, let c): return c
        case .penStroke(_, _, let c): return c
        case .polygon(_, let c): return c
        case .polyline(_, let c): return c
        case .rect(_, _, let c): return c
        case .fillPolygon(_, let c): return c
        case .fillRect(_, _, let c): return c
        default: return nil
        }
    }

    /// Normalizes angle to [0, 2pi).
    nonisolated public static func normAngle(_ v: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var r = v.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r
    }

    // MARK: - Cutting Edge Collection

    /// Collects cutting segments in world space from the document.
    /// - If `cuttingHandles` is non-nil and not empty: collects only from those entities.
    /// - If `cuttingHandles` is nil or empty: collects from all visible entities in the document.
    /// Compiled cutting edges with per-source-entity provenance ranges.
    /// Quick/select-all mode includes the trim target itself in the cutter
    /// set; `excluding(_:)` removes a target's own edges so a curve can
    /// never cut itself (its exploded chords intersect it everywhere).
    nonisolated public struct TrimCuttingEdges: Sendable {
        public var segments: [(Vector3, Vector3)]
        public var exactLines: [(Vector3, Vector3)]
        public var exactCurves: [Curve2d]
        /// Index ranges contributed by each source entity handle.
        public var rangesByHandle: [UUID: (segments: Range<Int>, exactLines: Range<Int>, exactCurves: Range<Int>)]

        public init(
            segments: [(Vector3, Vector3)] = [],
            exactLines: [(Vector3, Vector3)] = [],
            exactCurves: [Curve2d] = [],
            rangesByHandle: [UUID: (segments: Range<Int>, exactLines: Range<Int>, exactCurves: Range<Int>)] = [:]
        ) {
            self.segments = segments
            self.exactLines = exactLines
            self.exactCurves = exactCurves
            self.rangesByHandle = rangesByHandle
        }

        public static let empty = TrimCuttingEdges()

        public var isEmpty: Bool { segments.isEmpty && exactCurves.isEmpty }

        /// Copy with one source entity's edges removed (provenance dropped).
        public func excluding(_ handle: UUID) -> TrimCuttingEdges {
            guard let r = rangesByHandle[handle] else { return self }
            func cut<T>(_ array: [T], _ range: Range<Int>) -> [T] {
                guard !range.isEmpty else { return array }
                var copy = array
                copy.removeSubrange(range)
                return copy
            }
            return TrimCuttingEdges(
                segments: cut(segments, r.segments),
                exactLines: cut(exactLines, r.exactLines),
                exactCurves: cut(exactCurves, r.exactCurves))
        }
    }

    nonisolated public static func collectCuttingSegments(
        document: CADDocument,
        cuttingHandles: Set<UUID>?,
        excludedHandle: UUID? = nil
    ) -> (cuttingSegments: [(Vector3, Vector3)], exactLineCuttingSegments: [(Vector3, Vector3)], exactCurves: [Curve2d]) {
        let edges = collectCuttingEdges(
            document: document, cuttingHandles: cuttingHandles, excludedHandle: excludedHandle)
        return (edges.segments, edges.exactLines, edges.exactCurves)
    }

    nonisolated public static func collectCuttingEdges(
        document: CADDocument,
        cuttingHandles: Set<UUID>?,
        excludedHandle: UUID? = nil
    ) -> TrimCuttingEdges {
        var edges = TrimCuttingEdges()

        let entities: [CADEntity]
        if let handles = cuttingHandles, !handles.isEmpty {
            entities = handles.compactMap { document.entity(for: $0) }
        } else {
            entities = Array(document.entitiesView)
        }

        for otherEntity in entities {
            if let excluded = excludedHandle, otherEntity.handle == excluded { continue }
            guard let contribution = contribution(of: otherEntity, document: document) else { continue }

            let segStart = edges.segments.count
            let lineStart = edges.exactLines.count
            let curveStart = edges.exactCurves.count
            edges.segments.append(contentsOf: contribution.segments)
            edges.exactLines.append(contentsOf: contribution.exactLines)
            edges.exactCurves.append(contentsOf: contribution.exactCurves)
            edges.rangesByHandle[otherEntity.handle] = (
                segments: segStart..<edges.segments.count,
                exactLines: lineStart..<edges.exactLines.count,
                exactCurves: curveStart..<edges.exactCurves.count)
        }

        return edges
    }

    /// One entity's cutter contribution, or nil when the entity must not cut
    /// (hidden layer, block reference, no resolvable geometry). Shared by the
    /// full compile and the incremental per-entity refresh below so both
    /// paths build identical edges.
    nonisolated static func contribution(
        of entity: CADEntity,
        document: CADDocument
    ) -> (segments: [(Vector3, Vector3)], exactLines: [(Vector3, Vector3)], exactCurves: [Curve2d])? {
        guard let layer = document.layer(for: entity.layerID), layer.isVisible else { return nil }
        guard entity.blockID == nil else { return nil }
        guard let geom = document.resolvedGeometry(for: entity) else { return nil }

        var segments: [(Vector3, Vector3)] = []
        var exactLines: [(Vector3, Vector3)] = []
        var exactCurves: [Curve2d] = []
        for prim in geom {
            if case .line(let start, let end, _) = prim {
                let segment = (entity.transform.transformPoint(start), entity.transform.transformPoint(end))
                segments.append(segment)
                exactLines.append(segment)
            } else {
                // Exact world-space cutter curves (no chord error) for the
                // analytical solvers. Lines are covered by the segment
                // path, so only non-line curves are added here. When an
                // exact curve exists its exploded chords are NOT also
                // added: chord hits duplicate exact hits at chord-error
                // offsets and made cuts land off-curve (approximate).
                let exact = exactWorldCurves(for: prim, transform: entity.transform)
                exactCurves.append(contentsOf: exact)
                if exact.isEmpty {
                    segments.append(contentsOf: explode(primitive: prim, t: entity.transform))
                }
            }
        }
        return (segments, exactLines, exactCurves)
    }

    /// Splice helper: replace one entity's range in a cutter array, shifting
    /// every later contributor's range so provenance stays exact. The
    /// owner's own range is re-pointed at the freshly spliced elements.
    private nonisolated static func spliceContribution<T>(
        _ array: inout [T],
        ranges: inout [UUID: (segments: Range<Int>, exactLines: Range<Int>, exactCurves: Range<Int>)],
        owner: UUID,
        keyPath: WritableKeyPath<(segments: Range<Int>, exactLines: Range<Int>, exactCurves: Range<Int>), Range<Int>>,
        oldRange: Range<Int>,
        newElements: [T]
    ) {
        let delta = newElements.count - oldRange.count
        array.replaceSubrange(oldRange, with: newElements)
        let newRange = oldRange.lowerBound..<(oldRange.lowerBound + newElements.count)
        if var entry = ranges[owner] {
            entry[keyPath: keyPath] = newRange
            ranges[owner] = entry
        }
        guard delta != 0 else { return }
        for handle in ranges.keys {
            if handle == owner { continue }
            var entry = ranges[handle]!
            let range = entry[keyPath: keyPath]
            if range.lowerBound >= oldRange.upperBound {
                entry[keyPath: keyPath] = (range.lowerBound + delta)..<(range.upperBound + delta)
                ranges[handle] = entry
            }
        }
    }

    /// Refresh one entity's cutter contribution in place after a trim/extend
    /// rewrites its geometry. O(entity geometry + contributors), not O(full
    /// drawing): the alternative — recompiling every cutter per click —
    /// explodes curves drawing-wide on every single trim.
    nonisolated public static func updateCuttingEdges(
        _ edges: inout TrimCuttingEdges,
        for handle: UUID,
        document: CADDocument
    ) {
        guard let old = edges.rangesByHandle[handle] else {
            // Not previously a contributor (or compiled with an explicit
            // handle set that excluded it): append when it now contributes.
            guard let entity = document.entity(for: handle),
                  let c = contribution(of: entity, document: document) else { return }
            let segStart = edges.segments.count
            let lineStart = edges.exactLines.count
            let curveStart = edges.exactCurves.count
            edges.segments.append(contentsOf: c.segments)
            edges.exactLines.append(contentsOf: c.exactLines)
            edges.exactCurves.append(contentsOf: c.exactCurves)
            edges.rangesByHandle[handle] = (
                segments: segStart..<edges.segments.count,
                exactLines: lineStart..<edges.exactLines.count,
                exactCurves: curveStart..<edges.exactCurves.count)
            return
        }
        let fresh = document.entity(for: handle).flatMap { contribution(of: $0, document: document) }
        spliceContribution(
            &edges.segments, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.segments,
            oldRange: old.segments, newElements: fresh?.segments ?? [])
        // The owner's other ranges are untouched by the segments splice
        // (separate arrays); re-read them for the next splice.
        let mid = edges.rangesByHandle[handle]!
        spliceContribution(
            &edges.exactLines, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.exactLines,
            oldRange: mid.exactLines, newElements: fresh?.exactLines ?? [])
        let afterLines = edges.rangesByHandle[handle]!
        spliceContribution(
            &edges.exactCurves, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.exactCurves,
            oldRange: afterLines.exactCurves, newElements: fresh?.exactCurves ?? [])
    }

    /// Drop one entity's cutter contribution in place (entity deleted by a
    /// trim). Same complexity story as `updateCuttingEdges`.
    nonisolated public static func removeCuttingEdges(
        _ edges: inout TrimCuttingEdges,
        for handle: UUID
    ) {
        guard let old = edges.rangesByHandle[handle] else { return }
        spliceContribution(
            &edges.segments, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.segments,
            oldRange: old.segments, newElements: [])
        let mid = edges.rangesByHandle[handle]!
        spliceContribution(
            &edges.exactLines, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.exactLines,
            oldRange: mid.exactLines, newElements: [])
        let afterLines = edges.rangesByHandle[handle]!
        spliceContribution(
            &edges.exactCurves, ranges: &edges.rangesByHandle, owner: handle, keyPath: \.exactCurves,
            oldRange: afterLines.exactCurves, newElements: [])
        edges.rangesByHandle.removeValue(forKey: handle)
    }

    /// World-space analytical curves for a cutter primitive. Arcs, circles,
    /// ellipses, and bulged polylines require a similarity transform to
    /// survive as their own kind; splines are affine-invariant and always
    /// exact. Anything else returns [] (exploded chords cover it).
    /// Pure value math, hence nonisolated: SnapEngine reuses it off the main actor.
    nonisolated static func exactWorldCurves(for prim: CADPrimitive, transform: Transform3D) -> [Curve2d] {
        switch prim {
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            guard transform.isSimilarity2D else { return [] }
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * 0.5 * (abs(s.x) + abs(s.y))
            let mirror = transform.reversesOrientation2D
            let rot = transform.rotation
            // Image of the local start point fixes the world start angle;
            // mirror flips the sweep handedness.
            let wsPt = transform.transformPoint(Vector3(
                x: center.x + radius * cos(startAngle),
                y: center.y + radius * sin(startAngle), z: center.z))
            let wStart = atan2(wsPt.y - wc.y, wsPt.x - wc.x)
            let rawSweep = endAngle - startAngle
            let sweep = mirror ? -rawSweep : rawSweep
            _ = rot
            return [.arc(Arc2d(center: wc.point2d, radius: wr, startAngle: wStart, sweep: sweep))]
        case .circle(let center, let radius, _):
            guard transform.isSimilarity2D else { return [] }
            let s = transform.scale
            let wr = radius * 0.5 * (abs(s.x) + abs(s.y))
            return [.circle(Circle2d(center: transform.transformPoint(center).point2d, radius: wr))]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            guard transform.isSimilarity2D else { return [] }
            let wc = transform.transformPoint(center)
            let wTip = transform.transformPoint(center + majorAxis)
            let wMajor = Vec2d(x: wTip.x - wc.x, y: wTip.y - wc.y)
            guard wMajor.length > KernelTolerance.linear else { return [] }
            return [.ellipse(Ellipse2d(center: wc.point2d, majorAxis: wMajor, minorRatio: minorRatio))]
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let wps = controlPoints.map { transform.transformPoint($0).point2d }
            let s = Spline2d(controlPoints: wps, knots: knots, degree: degree, weights: weights)
            guard s.isValid else { return [] }
            return [.spline(s)]
        case .polyline(let path, _):
            guard transform.isSimilarity2D else { return [] }
            // transformed(by:) flips bulge handedness under mirror and
            // scales widths, so world segments are authoritative.
            let world = path.transformed(by: transform)
            return world.toKernelSegments().map { .polySegment($0) }
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let p0 = transform.transformPoint(origin).point2d
            let p1 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)).point2d
            let p2 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)).point2d
            let p3 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)).point2d
            return [.line(LineSeg2d(start: p0, end: p1)), .line(LineSeg2d(start: p1, end: p2)),
                    .line(LineSeg2d(start: p2, end: p3)), .line(LineSeg2d(start: p3, end: p0))]
        default:
            return []
        }
    }

    // MARK: - Cutter Broad Phase

    /// World-space bbox filter for cutter segments: a cutter that does not
    /// touch the target's bbox cannot intersect the target, so it is dropped
    /// before any kernel solve runs. Bbox math is O(1); the kernel solves it
    /// replaces (line-spline subdivision + Newton polish, and the N×M loops
    /// in the polyline/exploded solvers) are orders of magnitude more
    /// expensive. Touching boxes count as overlapping (kernel-tolerance slop
    /// in `intersects`), so exact endpoint touches are never filtered out.
    nonisolated static func broadPhaseSegments(
        _ segments: [(Vector3, Vector3)],
        intersecting target: BoundingBox2d
    ) -> [(Vector3, Vector3)] {
        segments.filter { seg in
            BoundingBox2d(
                min: Point2d(x: min(seg.0.x, seg.1.x), y: min(seg.0.y, seg.1.y)),
                max: Point2d(x: max(seg.0.x, seg.1.x), y: max(seg.0.y, seg.1.y))
            ).intersects(target)
        }
    }

    /// Same filter for analytical cutter curves. Unbounded cutters (rays,
    /// xlines) and curves without computable bounds are always kept.
    nonisolated static func broadPhaseCurves(
        _ curves: [Curve2d],
        intersecting target: BoundingBox2d
    ) -> [Curve2d] {
        curves.filter { curve in
            switch curve {
            case .ray, .xline:
                return true
            default:
                break
            }
            guard let bb = CurveEval.boundingBox(curve) else { return true }
            return bb.intersects(target)
        }
    }

    // MARK: - Primitive Trimming Solvers

    /// Trims an entire entity against cutting edges using the provided criterion.
    public static func trimEntity(
        entity: CADEntity,
        document: CADDocument,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactLines: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (newGeometry: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        guard let localGeom = entity.localGeometry, !localGeom.isEmpty else {
            return (nil, false, "Entity has no local geometry.")
        }

        let transform = entity.transform

        switch criterion {
        case .click(let rawClick):
            // Single click: find the closest primitive to the click point
            var bestPrimIndex: Int? = nil
            var bestPrimDistSq: Double = .infinity

            for (i, prim) in localGeom.enumerated() {
                if let d = CADHitTesting.distanceSqToPrimitive(prim, point: rawClick, transform: transform, t2: .infinity) {
                    if d < bestPrimDistSq {
                        bestPrimDistSq = d
                        bestPrimIndex = i
                    }
                }
            }

            guard let primIndex = bestPrimIndex else {
                return (nil, false, "No primitive found near click.")
            }

            let targetPrim = localGeom[primIndex]
            let (newPrims, modified, errorMsg) = trimPrimitive(
                primitive: targetPrim,
                transform: transform,
                criterion: criterion,
                cuttingSegments: cuttingSegments,
                exactLines: exactLines,
                exactCurves: exactCurves
            )

            if let errorMsg {
                return (nil, false, errorMsg)
            }
            guard modified else {
                return (nil, false, nil)
            }

            var updatedGeom = localGeom
            updatedGeom.remove(at: primIndex)
            if let replacements = newPrims {
                updatedGeom.insert(contentsOf: replacements, at: primIndex)
            }
            return (updatedGeom, true, nil)

        case .fence, .rect:
            // Batch trim: evaluate each primitive against the criterion
            var updatedGeom: [CADPrimitive] = []
            var anyModified = false

            for prim in localGeom {
                let (newPrims, modified, _) = trimPrimitive(
                    primitive: prim,
                    transform: transform,
                    criterion: criterion,
                    cuttingSegments: cuttingSegments,
                    exactLines: exactLines,
                    exactCurves: exactCurves
                )

                if modified {
                    anyModified = true
                    if let replacements = newPrims {
                        updatedGeom.append(contentsOf: replacements)
                    }
                } else {
                    updatedGeom.append(prim)
                }
            }

            guard anyModified else {
                return (nil, false, nil)
            }
            return (updatedGeom, true, nil)
        }
    }

    /// Trims a single primitive. Returns the replacement primitives (or empty array if fully trimmed),
    /// whether it was modified, and an optional error message.
    public static func trimPrimitive(
        primitive: CADPrimitive,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactLines: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        switch primitive {
        case .line(let ls, let le, let color):
            return trimLine(
                ls: ls, le: le, color: color,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )

        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            return trimArc(
                center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, color: color,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )

        case .circle(let center, let radius, let color):
            return trimCircle(
                center: center, radius: radius, color: color,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )

        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            return trimSpline(
                controlPoints: controlPoints, knots: knots, degree: degree, weights: weights, color: color,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactLines: exactLines, exactCurves: exactCurves
            )

        case .polyline(let path, let color):
            return trimPolylineExact(
                path: path, color: color,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )

        default:
            return trimExploded(
                primitive: primitive,
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )
        }
    }

    // MARK: - Line Solver

    private static func trimLine(
        ls: Vector3, le: Vector3, color: ColorRGBA?,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let ws = transform.transformPoint(ls)
        let we = transform.transformPoint(le)
        let segDX = we.x - ws.x; let segDY = we.y - ws.y
        let segLenSq = segDX * segDX + segDY * segDY
        if segLenSq <= 1e-18 {
            return ([], true, nil)
        }

        // Find intersections with cutting segments in world space.
        // Canonical kernel solver (local-frame shifted line-line).
        var hitsT: [Double] = []
        func collect(_ t: Double) {
            if t > 1e-9 && t < 1.0 - 1e-9 {
                if !hitsT.contains(where: { abs($0 - t) < 1e-6 }) {
                    hitsT.append(t)
                }
            }
        }
        // Broad phase: only cutters touching the target's bbox can hit it.
        let targetBox = BoundingBox2d(min: ws.point2d, max: we.point2d)
        let nearSegments = broadPhaseSegments(cuttingSegments, intersecting: targetBox)
        let nearCurves = broadPhaseCurves(exactCurves, intersecting: targetBox)
        let targetLine = LineSeg2d(start: ws.point2d, end: we.point2d)
        for edge in nearSegments {
            let cutter = LineSeg2d(start: edge.0.point2d, end: edge.1.point2d)
            let res = Intersector2D.intersectLineLine(
                targetLine, cutter, extendA: false, extendB: false)
            for hit in res { collect(hit.paramA) }
        }
        // Exact cutter curves (arcs/splines/ellipses/bulges): line cutters
        // are already covered by the segment path, so skip those.
        let targetCurve = Curve2d.line(targetLine)
        for exact in nearCurves {
            if case .line(_) = exact { continue }
            for hit in Intersector2D.intersect(targetCurve, exact, extendA: false, extendB: false) {
                collect(hit.paramA)
            }
        }

        guard !hitsT.isEmpty else {
            return (nil, false, nil)
        }

        hitsT.sort()
        let tPoints = [0.0] + hitsT + [1.0]

        // Evaluate intervals
        var keptSpans: [(Double, Double)] = []
        var anyTrimmed = false

        for k in 0..<(tPoints.count - 1) {
            let tA = tPoints[k]
            let tB = tPoints[k + 1]
            let pA = Vector3(x: ws.x + tA * segDX, y: ws.y + tA * segDY, z: ws.z)
            let pB = Vector3(x: ws.x + tB * segDX, y: ws.y + tB * segDY, z: ws.z)
            let mid = Vector3(x: (pA.x + pB.x) * 0.5, y: (pA.y + pB.y) * 0.5, z: ws.z)

            var shouldTrim = false
            switch criterion {
            case .click(let rawClick):
                let dpX = rawClick.x - ws.x
                let dpY = rawClick.y - ws.y
                let dot = dpX * segDX + dpY * segDY
                let tClick = max(0.0, min(1.0, dot / segLenSq))
                if tClick >= tA - 1e-9 && tClick <= tB + 1e-9 {
                    shouldTrim = true
                }

            case .fence(let fp1, let fp2):
                if CADRectSelect.segmentsIntersect(pA, pB, fp1, fp2) {
                    shouldTrim = true
                }

            case .rect(let bMin, let bMax, let isCrossing):
                if isCrossing {
                    if (mid.x >= bMin.x && mid.x <= bMax.x && mid.y >= bMin.y && mid.y <= bMax.y)
                        || CADRectSelect.segmentIntersectsRect(p1: pA, p2: pB, rectMin: bMin, rectMax: bMax) {
                        shouldTrim = true
                    }
                } else {
                    if pA.x >= bMin.x && pA.x <= bMax.x && pA.y >= bMin.y && pA.y <= bMax.y &&
                       pB.x >= bMin.x && pB.x <= bMax.x && pB.y >= bMin.y && pB.y <= bMax.y {
                        shouldTrim = true
                    }
                }
            }

            if shouldTrim {
                anyTrimmed = true
            } else {
                if let last = keptSpans.last, abs(last.1 - tA) < 1e-8 {
                    keptSpans[keptSpans.count - 1].1 = tB
                } else {
                    keptSpans.append((tA, tB))
                }
            }
        }

        guard anyTrimmed else {
            return (nil, false, nil)
        }

        var newPrims: [CADPrimitive] = []
        for span in keptSpans {
            let locA = Vector3(x: ls.x + span.0 * (le.x - ls.x), y: ls.y + span.0 * (le.y - ls.y), z: ls.z)
            let locB = Vector3(x: ls.x + span.1 * (le.x - ls.x), y: ls.y + span.1 * (le.y - ls.y), z: ls.z)
            newPrims.append(.line(start: locA, end: locB, color: color))
        }

        return (newPrims, true, nil)
    }

    // MARK: - Arc Solver

    private static func trimArc(
        center: Vector3, radius: Double, startAngle: Double, endAngle: Double, color: ColorRGBA?,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let wc = transform.transformPoint(center)
        let s = transform.scale
        let wr = radius * max(abs(s.x), abs(s.y))
        let wsa = startAngle + transform.rotation
        let wea = endAngle + transform.rotation
        var span = wea - wsa
        if span < 0 { span += 2.0 * .pi }

        var hitOffsets: [Double] = []
        func collectArc(_ off: Double) {
            if off > 1e-5 && off < span - 1e-5 {
                if !hitOffsets.contains(where: { abs($0 - off) < 1e-5 }) {
                    hitOffsets.append(off)
                }
            }
        }
        // Exact cutter curves: world arc vs analytical cutter.
        let worldArc = Arc2d(center: wc.point2d, radius: wr, startAngle: wsa, sweep: span)
        // Broad phase: only cutters touching the target's bbox can hit it.
        let arcBox = CurveEval.boundingBox(.arc(worldArc))
        let nearArcSegments: [(Vector3, Vector3)]
        let nearArcCurves: [Curve2d]
        if let arcBox {
            nearArcSegments = broadPhaseSegments(cuttingSegments, intersecting: arcBox)
            nearArcCurves = broadPhaseCurves(exactCurves, intersecting: arcBox)
        } else {
            nearArcSegments = cuttingSegments
            nearArcCurves = exactCurves
        }
        for edge in nearArcSegments {
            let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
            for pt in pts {
                let a = atan2(pt.y - wc.y, pt.x - wc.x)
                if CADGeometryMath.angleIsOnCCWSweep(angle: a, start: wsa, end: wsa + span) {
                    collectArc(normAngle(a - wsa))
                }
            }
        }
        for exact in nearArcCurves {
            if case .line(_) = exact { continue }
            for hit in Intersector2D.intersect(.arc(worldArc), exact, extendA: false, extendB: false) {
                collectArc(hit.paramA * span)
            }
        }

        guard !hitOffsets.isEmpty else {
            return (nil, false, nil)
        }

        hitOffsets.sort()
        let arcPoints = [0.0] + hitOffsets + [span]

        var keptSpans: [(Double, Double)] = []
        var anyTrimmed = false

        for k in 0..<(arcPoints.count - 1) {
            let offA = arcPoints[k]
            let offB = arcPoints[k + 1]
            let midOff = (offA + offB) * 0.5
            let midA = wsa + midOff
            let midP = Vector3(x: wc.x + cos(midA) * wr, y: wc.y + sin(midA) * wr, z: wc.z)
            let pA = Vector3(x: wc.x + cos(wsa + offA) * wr, y: wc.y + sin(wsa + offA) * wr, z: wc.z)
            let pB = Vector3(x: wc.x + cos(wsa + offB) * wr, y: wc.y + sin(wsa + offB) * wr, z: wc.z)

            var shouldTrim = false
            switch criterion {
            case .click(let rawClick):
                let rawAngle = atan2(rawClick.y - wc.y, rawClick.x - wc.x)
                let clickT = normAngle(rawAngle - wsa)
                if clickT >= offA - 1e-5 && clickT <= offB + 1e-5 {
                    shouldTrim = true
                }

            case .fence(let fp1, let fp2):
                let pts = intersectSegmentCircle(segmentA: fp1, segmentB: fp2, circleCenter: wc, radius: wr)
                for p in pts {
                    let a = atan2(p.y - wc.y, p.x - wc.x)
                    let off = normAngle(a - wsa)
                    if off >= offA - 1e-5 && off <= offB + 1e-5 {
                        shouldTrim = true
                    }
                }

            case .rect(let bMin, let bMax, let isCrossing):
                if isCrossing {
                    if (midP.x >= bMin.x && midP.x <= bMax.x && midP.y >= bMin.y && midP.y <= bMax.y)
                        || CADRectSelect.segmentIntersectsRect(p1: pA, p2: pB, rectMin: bMin, rectMax: bMax) {
                        shouldTrim = true
                    }
                } else {
                    if midP.x >= bMin.x && midP.x <= bMax.x && midP.y >= bMin.y && midP.y <= bMax.y &&
                       pA.x >= bMin.x && pA.x <= bMax.x && pA.y >= bMin.y && pA.y <= bMax.y &&
                       pB.x >= bMin.x && pB.x <= bMax.x && pB.y >= bMin.y && pB.y <= bMax.y {
                        shouldTrim = true
                    }
                }
            }

            if shouldTrim {
                anyTrimmed = true
            } else {
                if let last = keptSpans.last, abs(last.1 - offA) < 1e-8 {
                    keptSpans[keptSpans.count - 1].1 = offB
                } else {
                    keptSpans.append((offA, offB))
                }
            }
        }

        guard anyTrimmed else {
            return (nil, false, nil)
        }

        var newPrims: [CADPrimitive] = []
        for span in keptSpans {
            let locStart = startAngle + span.0
            let locEnd = startAngle + span.1
            newPrims.append(.arc(center: center, radius: radius, startAngle: locStart, endAngle: locEnd, color: color))
        }

        return (newPrims, true, nil)
    }

    // MARK: - Circle Solver

    private static func trimCircle(
        center: Vector3, radius: Double, color: ColorRGBA?,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let wc = transform.transformPoint(center)
        let s = transform.scale
        let wr = radius * max(abs(s.x), abs(s.y))

        var hitsAngle: [Double] = []
        func collectCircle(_ a: Double) {
            if !hitsAngle.contains(where: { abs($0 - a) < 1e-5 || abs($0 - a) > (2.0 * .pi - 1e-5) }) {
                hitsAngle.append(a)
            }
        }
        // Broad phase: only cutters touching the target's bbox can hit it.
        let circleBox = BoundingBox2d(
            min: Point2d(x: wc.x - wr, y: wc.y - wr),
            max: Point2d(x: wc.x + wr, y: wc.y + wr))
        let nearCircleSegments = broadPhaseSegments(cuttingSegments, intersecting: circleBox)
        let nearCircleCurves = broadPhaseCurves(exactCurves, intersecting: circleBox)
        for edge in nearCircleSegments {
            let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
            for pt in pts {
                collectCircle(normAngle(atan2(pt.y - wc.y, pt.x - wc.x)))
            }
        }
        let worldCircle = Circle2d(center: wc.point2d, radius: wr)
        for exact in nearCircleCurves {
            if case .line(_) = exact { continue }
            for hit in Intersector2D.intersect(.circle(worldCircle), exact, extendA: false, extendB: false) {
                collectCircle(normAngle(hit.paramA * 2.0 * .pi))
            }
        }

        guard hitsAngle.count >= 2 else {
            return (nil, false, hitsAngle.isEmpty ? nil : "Circle needs at least 2 distinct intersections to trim.")
        }

        hitsAngle.sort()
        let count = hitsAngle.count

        var keptSectors: [(Double, Double)] = []
        var anyTrimmed = false

        for i in 0..<count {
            let startW = hitsAngle[i]
            let endW = hitsAngle[(i + 1) % count]
            var span = endW - startW
            if span < 0 { span += 2.0 * .pi }

            let midA = normAngle(startW + span * 0.5)
            let midP = Vector3(x: wc.x + cos(midA) * wr, y: wc.y + sin(midA) * wr, z: wc.z)
            let pA = Vector3(x: wc.x + cos(startW) * wr, y: wc.y + sin(startW) * wr, z: wc.z)
            let pB = Vector3(x: wc.x + cos(endW) * wr, y: wc.y + sin(endW) * wr, z: wc.z)

            var shouldTrim = false
            switch criterion {
            case .click(let rawClick):
                let cAngle = normAngle(atan2(rawClick.y - wc.y, rawClick.x - wc.x))
                let rel = normAngle(cAngle - startW)
                if rel >= 0 && rel <= span {
                    shouldTrim = true
                }

            case .fence(let fp1, let fp2):
                let pts = intersectSegmentCircle(segmentA: fp1, segmentB: fp2, circleCenter: wc, radius: wr)
                for p in pts {
                    let a = normAngle(atan2(p.y - wc.y, p.x - wc.x))
                    let rel = normAngle(a - startW)
                    if rel >= 0 && rel <= span {
                        shouldTrim = true
                    }
                }

            case .rect(let bMin, let bMax, let isCrossing):
                if isCrossing {
                    if (midP.x >= bMin.x && midP.x <= bMax.x && midP.y >= bMin.y && midP.y <= bMax.y)
                        || CADRectSelect.segmentIntersectsRect(p1: pA, p2: pB, rectMin: bMin, rectMax: bMax) {
                        shouldTrim = true
                    }
                } else {
                    if midP.x >= bMin.x && midP.x <= bMax.x && midP.y >= bMin.y && midP.y <= bMax.y &&
                       pA.x >= bMin.x && pA.x <= bMax.x && pA.y >= bMin.y && pA.y <= bMax.y &&
                       pB.x >= bMin.x && pB.x <= bMax.x && pB.y >= bMin.y && pB.y <= bMax.y {
                        shouldTrim = true
                    }
                }
            }

            if shouldTrim {
                anyTrimmed = true
            } else {
                keptSectors.append((startW, endW))
            }
        }

        guard anyTrimmed else {
            return (nil, false, nil)
        }

        var newPrims: [CADPrimitive] = []
        for sector in keptSectors {
            let localStart = sector.0 - transform.rotation
            let localEnd = sector.1 - transform.rotation
            newPrims.append(.arc(center: center, radius: radius, startAngle: localStart, endAngle: localEnd, color: color))
        }

        return (newPrims, true, nil)
    }

    // MARK: - Spline Solver

    private static func trimSpline(
        controlPoints: [Vector3], knots: [Double], degree: Int, weights: [Double]?, color: ColorRGBA?,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactLines: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let invTransform = transform.inverse()
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let minT = knots[p]
        let maxT = knots[controlPoints.count]
        let parameterDuplicateTolerance = max(1e-6, (maxT - minT) * 1e-7)
        // Zoom-independent geometric fallback tolerance. Exact kernel hits do
        // not use this; it only extends legacy sampled cutters and tests
        // endpoint contact for malformed splines.
        var localMin = controlPoints[0]
        var localMax = controlPoints[0]
        for point in controlPoints.dropFirst() {
            localMin.x = min(localMin.x, point.x)
            localMin.y = min(localMin.y, point.y)
            localMin.z = min(localMin.z, point.z)
            localMax.x = max(localMax.x, point.x)
            localMax.y = max(localMax.y, point.y)
            localMax.z = max(localMax.z, point.z)
        }
        let localDiagonal = (localMax - localMin).magnitude
        let localTolerance = max(KernelTolerance.linear, localDiagonal * 1e-9)
        let localToleranceSq = localTolerance * localTolerance

        let localExactLineEdges: [(Vector3, Vector3)] = exactLines.map {
            (invTransform.transformPoint($0.0), invTransform.transformPoint($0.1))
        }

        struct SplineHit { let t: Double; let point: Vector3 }
        var hits: [SplineHit] = []

        func appendHit(t: Double, point: Vector3) {
            guard t > minT + 1e-8, t < maxT - 1e-8 else { return }
            if !hits.contains(where: { abs($0.t - t) < parameterDuplicateTolerance }) {
                hits.append(SplineHit(t: t, point: point))
            }
        }

        func extendedEdge(_ edge: (Vector3, Vector3), by amount: Double) -> (Vector3, Vector3) {
            let dx = edge.1.x - edge.0.x
            let dy = edge.1.y - edge.0.y
            let len = hypot(dx, dy)
            guard len > 1e-12 else { return edge }
            let ux = dx / len; let uy = dy / len
            return (
                Vector3(x: edge.0.x - ux * amount, y: edge.0.y - uy * amount, z: edge.0.z),
                Vector3(x: edge.1.x + ux * amount, y: edge.1.y + uy * amount, z: edge.1.z)
            )
        }

        func addEndpointTouchHit(_ endpoint: Vector3) {
            let t = NURBSEvaluator.findClosestParameter(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, to: endpoint, segments: 256
            )
            guard let point = NURBSEvaluator.evaluateAt(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: t
            ) else { return }
            let dx = point.x - endpoint.x
            let dy = point.y - endpoint.y
            if dx * dx + dy * dy <= localToleranceSq {
                appendHit(t: t, point: point)
            }
        }

        func findHits(on edge: (Vector3, Vector3), searchSegments: Int) {
            let results = NURBSEvaluator.findIntersectionParameters(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w,
                segmentA: edge.0, segmentB: edge.1, searchSegments: searchSegments
            )
            for res in results { appendHit(t: res.t, point: res.point) }
        }

        // Kernel hit-finding for plain cutter edges: the world-space spline
        // is affine-exact (NURBS survive any affine map), so solve directly
        // in world space and map the normalized hit back to knot space.
        // This replaces chord-approximation misses with exact crossings.
        let worldCPs = controlPoints.map { transform.transformPoint($0) }
        let worldSpline = Spline2d(
            controlPoints: worldCPs.map { $0.point2d },
            knots: knots, degree: p, weights: w)
        let worldSplineValid = worldSpline.isValid
        func findHitsKernel(on edge: (Vector3, Vector3)) {
            guard worldSplineValid else {
                findHits(on: (invTransform.transformPoint(edge.0),
                               invTransform.transformPoint(edge.1)), searchSegments: 96)
                return
            }
            let line = LineSeg2d(start: edge.0.point2d, end: edge.1.point2d)
            let results = Intersector2D.intersect(.line(line), .spline(worldSpline))
            for res in results {
                let u = minT + res.paramB * (maxT - minT)
                if let pt = NURBSEvaluator.evaluateAt(
                    degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: u) {
                    appendHit(t: u, point: pt)
                }
            }
        }
        // Exact cutter curves in world space (arcs/splines/ellipses/bulged
        // polylines): line cutters are covered by the segment path above.
        func findHitsKernelCurve(_ exact: Curve2d) {
            guard worldSplineValid else { return }
            let cutter: Curve2d
            switch exact {
            case .line: return
            case .polySegment(let seg):
                switch seg.geometry {
                case .line(let l): cutter = .line(l)
                case .arc(let a): cutter = .arc(a)
                }
            default: cutter = exact
            }
            for res in Intersector2D.intersect(.spline(worldSpline), cutter,
                                               extendA: false, extendB: false) {
                let u = minT + res.paramA * (maxT - minT)
                if let pt = NURBSEvaluator.evaluateAt(
                    degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: u) {
                    appendHit(t: u, point: pt)
                }
            }
        }

        // Broad phase: the spline lies inside its control hull, so cutters
        // missing the world control bbox cannot hit it. Local line edges
        // filter against the local control bbox instead.
        var worldMin = worldCPs[0].point2d
        var worldMax = worldCPs[0].point2d
        for wcp in worldCPs.dropFirst() {
            let p = wcp.point2d
            worldMin = Point2d(x: min(worldMin.x, p.x), y: min(worldMin.y, p.y))
            worldMax = Point2d(x: max(worldMax.x, p.x), y: max(worldMax.y, p.y))
        }
        let splineWorldBox = BoundingBox2d(min: worldMin, max: worldMax)
        let splineLocalBox = BoundingBox2d(min: localMin.point2d, max: localMax.point2d)
        let nearSplineSegments = broadPhaseSegments(cuttingSegments, intersecting: splineWorldBox)
        let nearSplineCurves = broadPhaseCurves(exactCurves, intersecting: splineWorldBox)
        let nearLocalLineEdges = broadPhaseSegments(localExactLineEdges, intersecting: splineLocalBox)
        for edge in nearSplineSegments { findHitsKernel(on: edge) }
        for exact in nearSplineCurves { findHitsKernelCurve(exact) }
        for edge in nearLocalLineEdges {
            findHits(on: extendedEdge(edge, by: localTolerance), searchSegments: 256)
            addEndpointTouchHit(edge.0)
            addEndpointTouchHit(edge.1)
        }

        guard !hits.isEmpty else {
            return (nil, false, nil)
        }

        // Determine click parameter based on criterion
        let tClick: Double
        switch criterion {
        case .click(let rawClick):
            let invClick = invTransform.transformPoint(rawClick)
            tClick = NURBSEvaluator.findClosestParameter(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, to: invClick, segments: 96
            )

        case .fence(let fp1, let fp2):
            let lfp1 = invTransform.transformPoint(fp1)
            let lfp2 = invTransform.transformPoint(fp2)
            let fenceIntersections = NURBSEvaluator.findIntersectionParameters(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w,
                segmentA: lfp1, segmentB: lfp2, searchSegments: 128
            )
            guard let firstHit = fenceIntersections.first else { return (nil, false, nil) }
            tClick = firstHit.t

        case .rect(let bMin, let bMax, _):
            // Center of rect converted to local space
            let center = Vector3(x: (bMin.x + bMax.x) * 0.5, y: (bMin.y + bMax.y) * 0.5, z: 0)
            let lCenter = invTransform.transformPoint(center)
            tClick = NURBSEvaluator.findClosestParameter(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, to: lCenter, segments: 96
            )
        }

        var tBefore = minT
        var tAfter = maxT
        for h in hits {
            if h.t < tClick && h.t > tBefore { tBefore = h.t }
            if h.t > tClick && h.t < tAfter { tAfter = h.t }
        }

        var newPrims: [CADPrimitive] = []
        var subdivisionFailed = false

        if tBefore > minT + 1e-6 {
            if let split = NURBSEvaluator.subdivide(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tBefore
            ) {
                newPrims.append(.spline(
                    controlPoints: split.left.controlPoints, knots: split.left.knots,
                    degree: p, weights: split.left.weights, color: color
                ))
            } else {
                subdivisionFailed = true
            }
        }

        if tAfter < maxT - 1e-6 {
            if let split = NURBSEvaluator.subdivide(
                degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tAfter
            ) {
                newPrims.append(.spline(
                    controlPoints: split.right.controlPoints, knots: split.right.knots,
                    degree: p, weights: split.right.weights, color: color
                ))
            } else {
                subdivisionFailed = true
            }
        }

        if subdivisionFailed {
            // Fallback to exploded polyline trim
            return trimExploded(
                primitive: .spline(controlPoints: controlPoints, knots: knots, degree: degree, weights: weights, color: color),
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves
            )
        }

        return (newPrims, true, nil)
    }

    // MARK: - Exact Polyline Solver (bulge-preserving)

    /// Trims a polyline without tessellating bulged edges: hit-finding
    /// runs on exact world-space kernel segments, and kept spans rebuild
    /// via CurveEval.splitAt (bulge + width interpolation preserved).
    /// Non-similarity transforms fall back to trimExploded (bulges do not
    /// survive non-uniform scale as arcs).
    private static func trimPolylineExact(
        path: CADPolyline,
        color: ColorRGBA?,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        guard transform.isSimilarity2D else {
            return trimExploded(
                primitive: .polyline(path: path, color: color),
                transform: transform, criterion: criterion, cuttingSegments: cuttingSegments,
                exactCurves: exactCurves)
        }
        let mirror = transform.reversesOrientation2D
        let s = transform.scale
        let widthScale = max(0.5 * (abs(s.x) + abs(s.y)), 1e-12)

        // World-space kernel segments (positions transformed, bulge handedness
        // flipped under mirror, widths scaled).
        let localVerts = path.vertices
        guard localVerts.count >= 2 else { return ([], true, nil) }
        let edgeCount = path.isClosed ? localVerts.count : (localVerts.count - 1)
        var worldSegs: [PolySegment2d] = []
        worldSegs.reserveCapacity(edgeCount)
        for i in 0..<edgeCount {
            let v0 = localVerts[i]
            let v1 = localVerts[(i + 1) % localVerts.count]
            let w0 = transform.transformPoint(v0.position)
            let w1 = transform.transformPoint(v1.position)
            worldSegs.append(PolySegment2d(
                index: i,
                start: w0.point2d, end: w1.point2d,
                bulge: mirror ? -v0.bulge : v0.bulge,
                startWidth: v0.startWidth * widthScale,
                endWidth: v0.endWidth * widthScale))
        }
        func segLen(_ seg: PolySegment2d) -> Double {
            switch seg.geometry {
            case .line(let l): return l.length
            case .arc(let a): return a.radius * abs(a.sweep)
            }
        }
        var cumLen: [Double] = [0]
        for seg in worldSegs { cumLen.append(cumLen.last! + segLen(seg)) }
        let totalLen = cumLen.last!
        guard totalLen > 1e-9 else { return ([], true, nil) }

        // Hits in world space against cutter edges.
        struct PlineHit { let t: Double }
        var hits: [PlineHit] = []
        func collectPline(_ globalT: Double) {
            if globalT > 1e-9 && globalT < 1.0 - 1e-9 {
                if !hits.contains(where: { abs($0.t - globalT) < 1e-6 }) {
                    hits.append(PlineHit(t: globalT))
                }
            }
        }
        // Broad phase, two levels: coarse whole-target filter on the cutter
        // sets, then a per-edge bbox reject inside the N×M loop so each
        // kernel solve only runs for cutters near that edge.
        var plineMin = worldSegs[0].startPoint
        var plineMax = worldSegs[0].startPoint
        func expandPlineBox(_ p: Point2d) {
            plineMin = Point2d(x: min(plineMin.x, p.x), y: min(plineMin.y, p.y))
            plineMax = Point2d(x: max(plineMax.x, p.x), y: max(plineMax.y, p.y))
        }
        for seg in worldSegs {
            switch seg.geometry {
            case .line(let l): expandPlineBox(l.start); expandPlineBox(l.end)
            case .arc(let a):
                if let bb = CurveEval.boundingBox(.arc(a)) {
                    expandPlineBox(bb.min); expandPlineBox(bb.max)
                }
            }
        }
        let plineBox = BoundingBox2d(min: plineMin, max: plineMax)
        let nearPlineSegments = broadPhaseSegments(cuttingSegments, intersecting: plineBox)
        let nearPlineCurves = broadPhaseCurves(exactCurves, intersecting: plineBox)
        let segBoxes: [BoundingBox2d] = worldSegs.map { seg in
            switch seg.geometry {
            case .line(let l): return BoundingBox2d(min: l.start, max: l.end)
            case .arc(let a):
                return CurveEval.boundingBox(.arc(a))
                    ?? BoundingBox2d(point: a.center).expanded(by: a.radius)
            }
        }
        for edge in nearPlineSegments {
            let cutterBox = BoundingBox2d(min: edge.0.point2d, max: edge.1.point2d)
            let cutter = Curve2d.line(LineSeg2d(start: edge.0.point2d, end: edge.1.point2d))
            for (i, seg) in worldSegs.enumerated() {
                guard segBoxes[i].intersects(cutterBox) else { continue }
                let results = Intersector2D.intersect(.polySegment(seg), cutter)
                for h in results {
                    let segL = segLen(seg)
                    guard segL > 1e-12 else { continue }
                    collectPline((cumLen[i] + h.paramA * segL) / totalLen)
                }
            }
        }
        // Exact cutter curves (skip lines: covered above).
        for exact in nearPlineCurves {
            if case .line(_) = exact { continue }
            for (i, seg) in worldSegs.enumerated() {
                for h in Intersector2D.intersect(.polySegment(seg), exact) {
                    let segL = segLen(seg)
                    guard segL > 1e-12 else { continue }
                    collectPline((cumLen[i] + h.paramA * segL) / totalLen)
                }
            }
        }
        guard !hits.isEmpty else { return (nil, false, nil) }

        // Click parameter: nearest world point on the exact segments.
        func nearestGlobalT(to query: Vector3) -> Double {
            var bestD = Double.infinity
            var bestT = 0.0
            for (i, seg) in worldSegs.enumerated() {
                let proj = Projector2D.closestPointOnCurve(.polySegment(seg), to: query.point2d)
                if proj.distance < bestD {
                    bestD = proj.distance
                    let segL = segLen(seg)
                    bestT = segL > 1e-12 ? (cumLen[i] + proj.param * segL) / totalLen : cumLen[i] / totalLen
                }
            }
            return bestT
        }
        let tClick: Double
        switch criterion {
        case .click(let rawClick):
            tClick = nearestGlobalT(to: rawClick)
        case .fence(let fp1, let fp2):
            let fence = Curve2d.line(LineSeg2d(start: fp1.point2d, end: fp2.point2d))
            var foundT: Double? = nil
            for (i, seg) in worldSegs.enumerated() {
                if let h = Intersector2D.intersect(.polySegment(seg), fence).first {
                    let segL = segLen(seg)
                    foundT = (cumLen[i] + h.paramA * segL) / totalLen
                    break
                }
            }
            guard let fT = foundT else { return (nil, false, nil) }
            tClick = fT
        case .rect(let bMin, let bMax, _):
            let center = Vector3(x: (bMin.x + bMax.x) * 0.5, y: (bMin.y + bMax.y) * 0.5, z: 0)
            tClick = nearestGlobalT(to: center)
        }

        var tBefore = 0.0
        var tAfter = 1.0
        for h in hits {
            if h.t < tClick && h.t > tBefore { tBefore = h.t }
            if h.t > tClick && h.t < tAfter { tAfter = h.t }
        }
        // Kept global intervals.
        var kept: [(Double, Double)] = []
        if tBefore > 1e-9 { kept.append((0.0, tBefore)) }
        if tAfter < 1.0 - 1e-9 { kept.append((tAfter, 1.0)) }
        guard !kept.isEmpty else { return ([], true, nil) }

        // Rebuild kept spans exactly, mapping world sub-segments back to local.
        // Fractions lt0/lt1 locate each piece on its parent edge, so z and
        // widths interpolate exactly; bulge flips back under mirror.
        let inv = transform.inverse()
        var worldZ: [(Double, Double)] = []
        worldZ.reserveCapacity(worldSegs.count)
        for i in 0..<edgeCount {
            let v0 = localVerts[i]
            let v1 = localVerts[(i + 1) % localVerts.count]
            let w0 = transform.transformPoint(v0.position)
            let w1 = transform.transformPoint(v1.position)
            worldZ.append((w0.z, w1.z))
        }
        var verts: [CADPolylineVertex] = []
        var droppedEdge = false
        for (i, seg) in worldSegs.enumerated() {
            let e0 = cumLen[i] / totalLen
            let e1 = cumLen[i + 1] / totalLen
            var keptAny = false
            for (k0, k1) in kept {
                if k1 <= e0 + 1e-12 || k0 >= e1 - 1e-12 { continue }
                let lt0 = min(max((k0 - e0) / max(e1 - e0, 1e-15), 0.0), 1.0)
                let lt1 = min(max((k1 - e0) / max(e1 - e0, 1e-15), 0.0), 1.0)
                if lt1 - lt0 <= 1e-9 { continue }
                if case .polySegment(let sub)? = CurveEval.splitAt(.polySegment(seg), t1: lt0, t2: lt1) {
                    let (wz0, wz1) = worldZ[i]
                    let zA = wz0 + (wz1 - wz0) * lt0
                    let zB = wz0 + (wz1 - wz0) * lt1
                    let lA = inv.transformPoint(Vector3(x: sub.startPoint.x, y: sub.startPoint.y, z: zA))
                    let lB = inv.transformPoint(Vector3(x: sub.endPoint.x, y: sub.endPoint.y, z: zB))
                    let bA = mirror ? -sub.bulge : sub.bulge
                    let wA = sub.startWidth / widthScale
                    let wB = sub.endWidth / widthScale
                    verts.append(CADPolylineVertex(position: lA, bulge: bA, startWidth: wA, endWidth: wA))
                    // Stash the piece end; the loop appends each piece start,
                    // and the final end is appended after the loop. Consecutive
                    // pieces share endpoints exactly (same split fractions).
                    verts.append(CADPolylineVertex(position: lB, bulge: 0, startWidth: wB, endWidth: wB))
                    keptAny = true
                }
            }
            if !keptAny { droppedEdge = true }
        }
        guard !verts.isEmpty else { return ([], true, nil) }
        // Collapse consecutive duplicates (piece joints), keeping the later
        // vertex: it carries the outgoing edge's bulge.
        var clean: [CADPolylineVertex] = []
        clean.reserveCapacity(verts.count)
        for v in verts {
            if let last = clean.last,
               (last.position - v.position).magnitudeSquared < 1e-18 {
                clean[clean.count - 1] = v
                continue
            }
            clean.append(v)
        }
        var rebuilt = path
        rebuilt.vertices = clean
        rebuilt.isClosed = path.isClosed && !droppedEdge
        if rebuilt.isClosed, clean.count > 1,
           (clean.first!.position - clean.last!.position).magnitudeSquared < 1e-18 {
            // Closed loop: drop the duplicated seam vertex.
            rebuilt.vertices = Array(clean.dropLast())
        } else if !rebuilt.isClosed {
            // Open chain: the last vertex must not carry a bulge.
            rebuilt.vertices[rebuilt.vertices.count - 1].bulge = 0
        }
        return ([.polyline(path: rebuilt, color: color)], true, nil)
    }

    // MARK: - Exploded Polyline Fallback

    private static func trimExploded(
        primitive: CADPrimitive,
        transform: Transform3D,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let invTransform = transform.inverse()
        let targetSegs = explode(primitive: primitive, t: .identity)
        guard !targetSegs.isEmpty else { return ([], true, nil) }

        // Broad phase: world bbox of the exploded target (local bbox corners
        // mapped through the transform — conservative for any affine map).
        // Cutters missing it cannot hit any target segment.
        var localBoxMin = targetSegs[0].0
        var localBoxMax = targetSegs[0].0
        for s in targetSegs {
            for p in [s.0, s.1] {
                localBoxMin = Vector3(
                    x: min(localBoxMin.x, p.x), y: min(localBoxMin.y, p.y), z: min(localBoxMin.z, p.z))
                localBoxMax = Vector3(
                    x: max(localBoxMax.x, p.x), y: max(localBoxMax.y, p.y), z: max(localBoxMax.z, p.z))
            }
        }
        var explodedWorldBox: BoundingBox2d? = nil
        for corner in [
            Vector3(x: localBoxMin.x, y: localBoxMin.y, z: localBoxMin.z),
            Vector3(x: localBoxMax.x, y: localBoxMin.y, z: localBoxMin.z),
            Vector3(x: localBoxMin.x, y: localBoxMax.y, z: localBoxMin.z),
            Vector3(x: localBoxMax.x, y: localBoxMax.y, z: localBoxMin.z),
        ] {
            let w = transform.transformPoint(corner).point2d
            if let box = explodedWorldBox {
                var grown = box
                grown.include(w)
                explodedWorldBox = grown
            } else {
                explodedWorldBox = BoundingBox2d(point: w)
            }
        }
        let nearExplodedSegments: [(Vector3, Vector3)]
        let nearExplodedCurves: [Curve2d]
        if let explodedWorldBox {
            nearExplodedSegments = broadPhaseSegments(cuttingSegments, intersecting: explodedWorldBox)
            nearExplodedCurves = broadPhaseCurves(exactCurves, intersecting: explodedWorldBox)
        } else {
            nearExplodedSegments = cuttingSegments
            nearExplodedCurves = exactCurves
        }

        var cumLen: [Double] = [0]
        for s in targetSegs {
            let dx = s.1.x - s.0.x
            let dy = s.1.y - s.0.y
            cumLen.append(cumLen.last! + sqrt(dx * dx + dy * dy))
        }
        let totalLen = cumLen.last!
        guard totalLen > 1e-9 else { return ([], true, nil) }

        // Local cutting edges
        struct Hit { let localPoint: Vector3; let t: Double }
        var hits: [Hit] = []

        for edge in nearExplodedSegments {
            let localEdge0 = invTransform.transformPoint(edge.0)
            let localEdge1 = invTransform.transformPoint(edge.1)

            for (i, s) in targetSegs.enumerated() {
                // Canonical kernel solver (local-frame shifted).
                let target = LineSeg2d(start: s.0.point2d, end: s.1.point2d)
                let cutter = LineSeg2d(start: localEdge0.point2d, end: localEdge1.point2d)
                let results = Intersector2D.intersectLineLine(
                    target, cutter, extendA: false, extendB: false)
                for res in results {
                    let t = res.paramA
                    if t >= -1e-9 && t <= 1.0 + 1e-9 {
                        let segLen = cumLen[i+1] - cumLen[i]
                        let globalT = (cumLen[i] + t * segLen) / totalLen
                        if globalT > 1e-9 && globalT < 1.0 - 1e-9 {
                            hits.append(Hit(localPoint: Vector3(res.point), t: globalT))
                        }
                    }
                }
            }
        }

        // Exact cutter curves (world space): intersect each exploded
        // target segment analytically so curve cutters whose chords were
        // omitted from cuttingSegments still cut here.
        if !nearExplodedCurves.isEmpty {
            for exact in nearExplodedCurves {
                if case .line(_) = exact { continue }
                for (i, s) in targetSegs.enumerated() {
                    let w0 = transform.transformPoint(s.0)
                    let w1 = transform.transformPoint(s.1)
                    let target = Curve2d.line(LineSeg2d(start: w0.point2d, end: w1.point2d))
                    for res in Intersector2D.intersect(target, exact, extendA: false, extendB: false) {
                        let t = res.paramA
                        if t >= -1e-9 && t <= 1.0 + 1e-9 {
                            let segLen = cumLen[i+1] - cumLen[i]
                            let globalT = (cumLen[i] + t * segLen) / totalLen
                            if globalT > 1e-9 && globalT < 1.0 - 1e-9 {
                                hits.append(Hit(localPoint: invTransform.transformPoint(Vector3(res.point)), t: globalT))
                            }
                        }
                    }
                }
            }
        }

        guard !hits.isEmpty else {
            return (nil, false, nil)
        }

        // Determine click parameter along polyline
        let tClick: Double
        switch criterion {
        case .click(let rawClick):
            let invClick = invTransform.transformPoint(rawClick)
            var bestDistSq = Double.infinity
            var bestIdx = 0
            var bestSegT = 0.0

            for (i, s) in targetSegs.enumerated() {
                let dx = s.1.x - s.0.x; let dy = s.1.y - s.0.y
                let ls = dx * dx + dy * dy
                var t = 0.0
                if ls > 1e-18 {
                    t = max(0.0, min(1.0, ((invClick.x - s.0.x) * dx + (invClick.y - s.0.y) * dy) / ls))
                }
                let qx = s.0.x + t * dx; let qy = s.0.y + t * dy
                let dSq = (invClick.x - qx) * (invClick.x - qx) + (invClick.y - qy) * (invClick.y - qy)
                if dSq < bestDistSq {
                    bestDistSq = dSq; bestIdx = i; bestSegT = t
                }
            }
            tClick = (cumLen[bestIdx] + bestSegT * (cumLen[bestIdx+1] - cumLen[bestIdx])) / totalLen

        case .fence(let fp1, let fp2):
            let lfp0 = invTransform.transformPoint(fp1)
            let lfp1 = invTransform.transformPoint(fp2)
            var foundT: Double? = nil
            let fenceLine = LineSeg2d(start: lfp0.point2d, end: lfp1.point2d)
            for (i, s) in targetSegs.enumerated() {
                let target = LineSeg2d(start: s.0.point2d, end: s.1.point2d)
                if let res = Intersector2D.intersectLineLine(
                    target, fenceLine, extendA: false, extendB: false).first {
                    let segLen = cumLen[i+1] - cumLen[i]
                    foundT = (cumLen[i] + res.paramA * segLen) / totalLen
                    break
                }
            }
            guard let fT = foundT else { return (nil, false, nil) }
            tClick = fT

        case .rect(let bMin, let bMax, _):
            let center = Vector3(x: (bMin.x + bMax.x) * 0.5, y: (bMin.y + bMax.y) * 0.5, z: 0)
            let invCenter = invTransform.transformPoint(center)
            var bestDistSq = Double.infinity
            var bestIdx = 0
            var bestSegT = 0.0
            for (i, s) in targetSegs.enumerated() {
                let dx = s.1.x - s.0.x; let dy = s.1.y - s.0.y
                let ls = dx * dx + dy * dy
                var t = 0.0
                if ls > 1e-18 {
                    t = max(0.0, min(1.0, ((invCenter.x - s.0.x) * dx + (invCenter.y - s.0.y) * dy) / ls))
                }
                let qx = s.0.x + t * dx; let qy = s.0.y + t * dy
                let dSq = (invCenter.x - qx) * (invCenter.x - qx) + (invCenter.y - qy) * (invCenter.y - qy)
                if dSq < bestDistSq {
                    bestDistSq = dSq; bestIdx = i; bestSegT = t
                }
            }
            tClick = (cumLen[bestIdx] + bestSegT * (cumLen[bestIdx+1] - cumLen[bestIdx])) / totalLen
        }

        var tBefore = 0.0
        var tAfter = 1.0
        for h in hits {
            if h.t < tClick && h.t > tBefore { tBefore = h.t }
            if h.t > tClick && h.t < tAfter { tAfter = h.t }
        }

        var newPrims: [CADPrimitive] = []
        let color = colorForPrimitive(primitive)

        func buildLines(fromT startT: Double, toT endT: Double) {
            guard endT > startT else { return }
            for (i, s) in targetSegs.enumerated() {
                let segStartT = cumLen[i] / totalLen
                let segEndT = cumLen[i+1] / totalLen
                if segEndT <= startT + 1e-9 { continue }
                if segStartT >= endT - 1e-9 { continue }

                let startDiff = startT - segStartT
                let endDiff = endT - segStartT
                let segDiff = segEndT - segStartT
                let localStartFraction = max(0.0, startDiff / segDiff)
                let localEndFraction = min(1.0, endDiff / segDiff)

                let dx = s.1.x - s.0.x; let dy = s.1.y - s.0.y
                let pA = Vector3(x: s.0.x + localStartFraction * dx, y: s.0.y + localStartFraction * dy, z: s.0.z)
                let pB = Vector3(x: s.0.x + localEndFraction * dx, y: s.0.y + localEndFraction * dy, z: s.0.z)

                let diffX = pB.x - pA.x; let diffY = pB.y - pA.y
                if diffX * diffX + diffY * diffY > 1e-9 {
                    newPrims.append(.line(start: pA, end: pB, color: color))
                }
            }
        }

        if tBefore > 1e-9 { buildLines(fromT: 0.0, toT: tBefore) }
        if tAfter < 1.0 - 1e-9 { buildLines(fromT: tAfter, toT: 1.0) }

        if newPrims.isEmpty {
            return ([], true, nil)
        } else {
            return (newPrims, true, nil)
        }
    }

// MARK: - Extend Solvers (PR4 EXTEND)
    //
    // Pure geometric solvers that lengthen one open target along its natural
    // path to the nearest boundary edge: lines run straight, arcs and bulged
    // polyline end-segments continue along their parent circle, and splines
    // extend by moving the picked end control point onto the boundary hit
    // (the end-tangent ray must land cleanly, otherwise a cannot-extend
    // message is returned). Closed targets report no end; rays, construction
    // lines, and design-content kinds (text/hatch/image/table) are invalid.
    //
    // The end extended is the one nearest the pick. Boundary hits are found
    // with the kernel `Intersector2D` extend flags: EDGEMODE=0 intersects the
    // target's natural path against boundary geometry as built
    // (`extendB: false`); EDGEMODE=1 lets boundaries extend along their own
    // natural path (`extendB: true`).
    //
    // All entry points are nonisolated (pure value math over parameters the
    // caller passes in) so the scripted `(command "EXTEND" ...)` path — which
    // never hops to the main actor — shares them verbatim with the
    // interactive command. Boundary compilation reuses
    // `collectCuttingEdges` / `TrimCuttingEdges.excluding` verbatim; the
    // target's own edges are always excluded by the caller so a curve can
    // never extend to itself.
    //
    // Projection (PROJMODE None/UCS/View) needs no math here: in 2D parity
    // every intersection already resolves in the UCS XY plane (z carried),
    // so the option only records the sysvar.

    /// Which open end of a target extends (the one nearest the pick).
    nonisolated public enum ExtendEnd: Sendable {
        case start
        case end
    }

    /// Message for targets that are closed loops with no end to extend.
    nonisolated public static var extendClosedMessage: String {
        "The object is closed and has no end to extend."
    }

    /// Message for targets whose kind can never extend.
    nonisolated public static func extendInvalidMessage(for primitive: CADPrimitive) -> String {
        switch primitive {
        case .text:
            return "Text cannot be extended."
        case .hatch, .hatchPath:
            return "Hatches cannot be extended."
        case .image:
            return "Images cannot be extended."
        case .table:
            return "Tables cannot be extended."
        case .point:
            return "Points cannot be extended."
        case .penStroke:
            return "Pen strokes cannot be extended."
        case .ray:
            return "Rays cannot be extended."
        case .xline:
            return "Construction lines cannot be extended."
        default:
            return "That object cannot be extended."
        }
    }

    /// Extends one entity's nearest primitive to the pick along its natural
    /// path to the nearest boundary. Returns the full replacement geometry
    /// (spliced, like `trimEntity`), whether anything changed, and a message
    /// for invalid targets. Plain misses (no boundary in reach) return
    /// `(nil, false, nil)` so callers can stay in the command with their own
    /// prompt; only invalid kinds and clean-miss splines carry `errorMsg`.
    nonisolated public static func extendEntity(
        entity: CADEntity,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        edgeMode: Int
    ) -> (newGeometry: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        guard let localGeom = entity.localGeometry, !localGeom.isEmpty else {
            return (nil, false, "The object has no geometry to extend.")
        }
        let transform = entity.transform
        var bestIndex: Int? = nil
        var bestDistSq = Double.infinity
        for (i, prim) in localGeom.enumerated() {
            if let d = extendDistanceSqToPrimitive(prim, transform: transform, point: pickWorld),
               d < bestDistSq {
                bestDistSq = d
                bestIndex = i
            }
        }
        guard let primIndex = bestIndex else {
            return (nil, false, extendInvalidMessage(for: localGeom[0]))
        }
        let (newPrims, modified, errorMsg) = extendPrimitive(
            primitive: localGeom[primIndex], transform: transform,
            pickWorld: pickWorld, boundaries: boundaries, edgeMode: edgeMode)
        if let errorMsg {
            return (nil, false, errorMsg)
        }
        guard modified, let replacements = newPrims else {
            return (nil, false, nil)
        }
        var updated = localGeom
        updated.remove(at: primIndex)
        updated.insert(contentsOf: replacements, at: primIndex)
        return (updated, true, nil)
    }

    /// Extends one primitive (the caller picks the nearest one) to the
    /// nearest boundary along its natural path for the end nearest the pick.
    nonisolated public static func extendPrimitive(
        primitive: CADPrimitive,
        transform: Transform3D,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        edgeMode: Int
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let allowBoundaryExtension = (edgeMode == 1)
        switch primitive {
        case .line(let ls, let le, let color):
            return extendLineEnd(
                ls: ls, le: le, color: color, transform: transform,
                pickWorld: pickWorld, boundaries: boundaries,
                allowBoundaryExtension: allowBoundaryExtension)
        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            return extendArcEnd(
                center: center, radius: radius, startAngle: startAngle, endAngle: endAngle,
                color: color, transform: transform, pickWorld: pickWorld,
                boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        case .polyline(let path, let color):
            guard !path.isClosed else {
                return (nil, false, extendClosedMessage)
            }
            return extendPolylineEnd(
                path: path, color: color, transform: transform, pickWorld: pickWorld,
                boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            return extendSplineEnd(
                controlPoints: controlPoints, knots: knots, degree: degree, weights: weights,
                color: color, transform: transform, pickWorld: pickWorld,
                boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        case .circle, .ellipse, .polygon, .rect, .fillRect,
             .fillPolygon, .fillComplexPolygon, .gradient:
            return (nil, false, extendClosedMessage)
        default:
            return (nil, false, extendInvalidMessage(for: primitive))
        }
    }
    /// Squared world-space distance from a point to a primitive (nearest-end
    /// selection for extend). Nil for kinds that can never extend. Sampling
    /// (arcs, bulges, ellipses) and local-space NURBS search (splines) keep
    /// this off the main actor; the heuristic only picks a primitive, the
    /// solvers below decide exact hits.
    nonisolated public static func extendDistanceSqToPrimitive(
        _ prim: CADPrimitive, transform: Transform3D, point: Vector3
    ) -> Double? {
        switch prim {
        case .line(let ls, let le, _):
            return pointSegDistSq(
                point, transform.transformPoint(ls), transform.transformPoint(le))
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span <= 0 { span += 2.0 * .pi }
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * 0.5 * (abs(s.x) + abs(s.y))
            var best = Double.infinity
            let n = 24
            for i in 0...n {
                let a = startAngle + span * Double(i) / Double(n)
                let p = Vector3(
                    x: wc.x + cos(a) * wr, y: wc.y + sin(a) * wr, z: wc.z)
                let d = (p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y)
                if d < best { best = d }
            }
            return best
        case .circle(let center, let radius, _):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * 0.5 * (abs(s.x) + abs(s.y))
            let d = hypot(point.x - wc.x, point.y - wc.y) - wr
            return d * d
        case .polyline(let path, _):
            let verts = path.vertices
            guard verts.count >= 2 else { return nil }
            var best = Double.infinity
            for i in 0..<path.segmentCount {
                let v0 = verts[i]
                let v1 = verts[path.endVertexIndex(forSegment: i)]
                if abs(v0.bulge) > 1e-12, let arc = path.arcParameters(forSegment: i) {
                    for k in 0...16 {
                        let t = Double(k) / 16.0
                        let a = arc.startAngle + arc.sweep * t
                        let lp = Vector3(
                            x: arc.center.x + cos(a) * arc.radius,
                            y: arc.center.y + sin(a) * arc.radius, z: v0.position.z)
                        let wp = transform.transformPoint(lp)
                        let d = (wp.x - point.x) * (wp.x - point.x) + (wp.y - point.y) * (wp.y - point.y)
                        if d < best { best = d }
                    }
                } else {
                    let d = pointSegDistSq(
                        point, transform.transformPoint(v0.position),
                        transform.transformPoint(v1.position))
                    if d < best { best = d }
                }
            }
            return best
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let inv = transform.inverse()
            let local = inv.transformPoint(point)
            let t = NURBSEvaluator.findClosestParameter(
                degree: degree, knots: knots, controlPoints: controlPoints, weights: w,
                to: local, segments: 64)
            guard let p = NURBSEvaluator.evaluateAt(
                degree: degree, knots: knots, controlPoints: controlPoints, weights: w, at: t)
            else { return nil }
            let s = transform.scale
            let k = 0.5 * (abs(s.x) + abs(s.y))
            let dx = (p.x - local.x) * k, dy = (p.y - local.y) * k
            return dx * dx + dy * dy
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let wc = transform.transformPoint(center)
            let tip = transform.transformPoint(center + majorAxis)
            let ux = tip.x - wc.x, uy = tip.y - wc.y
            let majorLen = hypot(ux, uy)
            let minorLen = majorLen * minorRatio
            guard majorLen > 1e-12 else { return nil }
            let rot = atan2(uy, ux)
            var best = Double.infinity
            for i in 0..<32 {
                let a = 2.0 * Double.pi * Double(i) / 32.0
                let ex = majorLen * cos(a), ey = minorLen * sin(a)
                let px = wc.x + ex * cos(rot) - ey * sin(rot)
                let py = wc.y + ex * sin(rot) + ey * cos(rot)
                let d = (px - point.x) * (px - point.x) + (py - point.y) * (py - point.y)
                if d < best { best = d }
            }
            return best
        default:
            return nil
        }
    }

    // MARK: - Extend Line Solver

    nonisolated static func extendLineEnd(
        ls: Vector3, le: Vector3, color: ColorRGBA?,
        transform: Transform3D,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let ws = transform.transformPoint(ls)
        let we = transform.transformPoint(le)
        var ux = we.x - ws.x, uy = we.y - ws.y
        let segLen = hypot(ux, uy)
        guard segLen > 1e-12 else {
            return (nil, false, "The line has no length to extend.")
        }
        ux /= segLen; uy /= segLen
        let dStart = (pickWorld.x - ws.x) * (pickWorld.x - ws.x)
            + (pickWorld.y - ws.y) * (pickWorld.y - ws.y)
        let dEnd = (pickWorld.x - we.x) * (pickWorld.x - we.x)
            + (pickWorld.y - we.y) * (pickWorld.y - we.y)
        let extendingEnd: ExtendEnd = (dEnd <= dStart) ? .end : .start
        let origin = (extendingEnd == .end) ? we : ws
        let dirX = (extendingEnd == .end) ? ux : -ux
        let dirY = (extendingEnd == .end) ? uy : -uy
        guard let hit = nearestRayBoundaryHit(
            origin: origin, directionX: dirX, directionY: dirY,
            boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        else {
            return (nil, false, nil)
        }
        let hLocal = transform.inverse().transformPoint(hit)
        if extendingEnd == .end {
            let moved = Vector3(x: hLocal.x, y: hLocal.y, z: le.z)
            return ([.line(start: ls, end: moved, color: color)], true, nil)
        } else {
            let moved = Vector3(x: hLocal.x, y: hLocal.y, z: ls.z)
            return ([.line(start: moved, end: le, color: color)], true, nil)
        }
    }

    // MARK: - Extend Arc Solver

    nonisolated static func extendArcEnd(
        center: Vector3, radius: Double, startAngle: Double, endAngle: Double, color: ColorRGBA?,
        transform: Transform3D,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        guard radius > 1e-12 else {
            return (nil, false, "The arc has no radius to extend.")
        }
        var span = endAngle - startAngle
        while span <= 0 { span += 2.0 * .pi }
        while span > 2.0 * .pi { span -= 2.0 * .pi }
        guard span < 2.0 * .pi - 1e-9 else {
            return (nil, false, extendClosedMessage)
        }
        guard transform.isSimilarity2D else {
            return (nil, false, "The arc cannot be extended under its transform.")
        }
        let mirror = transform.reversesOrientation2D
        let s = transform.scale
        let wr = radius * 0.5 * (abs(s.x) + abs(s.y))
        guard wr > 1e-12 else {
            return (nil, false, "The arc has no radius to extend.")
        }
        let wc = transform.transformPoint(center)
        let startPt = transform.transformPoint(Vector3(
            x: center.x + radius * cos(startAngle),
            y: center.y + radius * sin(startAngle), z: center.z))
        let wStart = atan2(startPt.y - wc.y, startPt.x - wc.x)
        let worldSweep = mirror ? -span : span
        let wEnd = wStart + worldSweep
        let wStartPt = Vector3(
            x: wc.x + cos(wStart) * wr, y: wc.y + sin(wStart) * wr, z: wc.z)
        let wEndPt = Vector3(
            x: wc.x + cos(wEnd) * wr, y: wc.y + sin(wEnd) * wr, z: wc.z)
        let dStart = (pickWorld.x - wStartPt.x) * (pickWorld.x - wStartPt.x)
            + (pickWorld.y - wStartPt.y) * (pickWorld.y - wStartPt.y)
        let dEnd = (pickWorld.x - wEndPt.x) * (pickWorld.x - wEndPt.x)
            + (pickWorld.y - wEndPt.y) * (pickWorld.y - wEndPt.y)
        let extendingEnd: ExtendEnd = (dEnd <= dStart) ? .end : .start
        // Extension runs away from the span: forward from the end, backward
        // from the start.
        let refAngle: Double
        let forwardSign: Double
        if extendingEnd == .end {
            refAngle = wEnd
            forwardSign = (worldSweep >= 0) ? 1.0 : -1.0
        } else {
            refAngle = wStart
            forwardSign = (worldSweep >= 0) ? -1.0 : 1.0
        }
        guard let hit = nearestCircleBoundaryHit(
            centerX: wc.x, centerY: wc.y, radius: wr, endZ: wc.z,
            refAngle: refAngle, forwardSign: forwardSign,
            boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        else {
            return (nil, false, nil)
        }
        let hLocal = transform.inverse().transformPoint(hit.point)
        let aLocal = atan2(hLocal.y - center.y, hLocal.x - center.x)
        if extendingEnd == .end {
            let newSweep = normAngle(aLocal - startAngle)
            guard newSweep > 1e-9 && newSweep < 2.0 * .pi - 1e-9 else {
                return (nil, false, nil)
            }
            return ([.arc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: startAngle + newSweep,
                color: color)], true, nil)
        } else {
            let backSweep = normAngle(startAngle - aLocal)
            guard backSweep > 1e-9 && backSweep < 2.0 * .pi - 1e-9 else {
                return (nil, false, nil)
            }
            return ([.arc(
                center: center, radius: radius,
                startAngle: startAngle - backSweep, endAngle: endAngle,
                color: color)], true, nil)
        }
    }
    // MARK: - Extend Open-Polyline Solver

    nonisolated static func extendPolylineEnd(
        path: CADPolyline, color: ColorRGBA?,
        transform: Transform3D,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let verts = path.vertices
        guard verts.count >= 2 else {
            return (nil, false, "The polyline has no segments to extend.")
        }
        func world(_ p: Vector3) -> Vector3 { transform.transformPoint(p) }
        let wFirst = world(verts[0].position)
        let wLast = world(verts[verts.count - 1].position)
        let dFirst = (pickWorld.x - wFirst.x) * (pickWorld.x - wFirst.x)
            + (pickWorld.y - wFirst.y) * (pickWorld.y - wFirst.y)
        let dLast = (pickWorld.x - wLast.x) * (pickWorld.x - wLast.x)
            + (pickWorld.y - wLast.y) * (pickWorld.y - wLast.y)
        let extendingEnd: ExtendEnd = (dLast <= dFirst) ? .end : .start
        var newVerts = verts
        let inv = transform.inverse()
        if extendingEnd == .end {
            let i = verts.count - 1
            let prevWorld = world(verts[i - 1].position)
            if abs(verts[i - 1].bulge) <= 1e-12 {
                var ux = wLast.x - prevWorld.x, uy = wLast.y - prevWorld.y
                let segLen = hypot(ux, uy)
                guard segLen > 1e-12 else {
                    return (nil, false, "The polyline end segment has no length to extend.")
                }
                ux /= segLen; uy /= segLen
                guard let hit = nearestRayBoundaryHit(
                    origin: wLast, directionX: ux, directionY: uy,
                    boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
                else {
                    return (nil, false, nil)
                }
                let h = inv.transformPoint(hit)
                newVerts[i].position = Vector3(x: h.x, y: h.y, z: verts[i].position.z)
            } else {
                guard transform.isSimilarity2D,
                      let params = path.arcParameters(forSegment: i - 1)
                else {
                    return (nil, false, "The polyline end arc cannot be extended under its transform.")
                }
                guard let hit = extendBulgeEndHit(
                    params: params, transform: transform, fromStart: false,
                    boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
                else {
                    return (nil, false, nil)
                }
                let h = inv.transformPoint(hit.point)
                let aLocal = atan2(h.y - params.center.y, h.x - params.center.x)
                let signedSweep: Double
                if params.sweep >= 0 {
                    signedSweep = normAngle(aLocal - params.startAngle)
                } else {
                    signedSweep = -normAngle(params.startAngle - aLocal)
                }
                guard abs(signedSweep) > 1e-9 && abs(signedSweep) < 2.0 * .pi - 1e-9 else {
                    return (nil, false, nil)
                }
                newVerts[i].position = Vector3(x: h.x, y: h.y, z: verts[i].position.z)
                newVerts[i - 1].bulge = tan(signedSweep / 4.0)
            }
        } else {
            let nextWorld = world(verts[1].position)
            if abs(verts[0].bulge) <= 1e-12 {
                var ux = wFirst.x - nextWorld.x, uy = wFirst.y - nextWorld.y
                let segLen = hypot(ux, uy)
                guard segLen > 1e-12 else {
                    return (nil, false, "The polyline end segment has no length to extend.")
                }
                ux /= segLen; uy /= segLen
                guard let hit = nearestRayBoundaryHit(
                    origin: wFirst, directionX: ux, directionY: uy,
                    boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
                else {
                    return (nil, false, nil)
                }
                let h = inv.transformPoint(hit)
                newVerts[0].position = Vector3(x: h.x, y: h.y, z: verts[0].position.z)
            } else {
                guard transform.isSimilarity2D,
                      let params = path.arcParameters(forSegment: 0)
                else {
                    return (nil, false, "The polyline end arc cannot be extended under its transform.")
                }
                guard let hit = extendBulgeEndHit(
                    params: params, transform: transform, fromStart: true,
                    boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
                else {
                    return (nil, false, nil)
                }
                let h = inv.transformPoint(hit.point)
                let aLocal = atan2(h.y - params.center.y, h.x - params.center.x)
                let signedSweep: Double
                if params.sweep >= 0 {
                    signedSweep = normAngle(aLocal - params.startAngle)
                } else {
                    signedSweep = -normAngle(params.startAngle - aLocal)
                }
                guard abs(signedSweep) > 1e-9 && abs(signedSweep) < 2.0 * .pi - 1e-9 else {
                    return (nil, false, nil)
                }
                newVerts[0].position = Vector3(x: h.x, y: h.y, z: verts[0].position.z)
                newVerts[0].bulge = tan(signedSweep / 4.0)
            }
        }
        var newPath = path
        newPath.vertices = newVerts
        return ([.polyline(path: newPath, color: color)], true, nil)
    }

    /// World-space hit for extending a bulged polyline end-segment along its
    /// parent circle. `fromStart` extends the segment start backward,
    /// otherwise the segment end forward.
    nonisolated static func extendBulgeEndHit(
        params: (center: Vector3, radius: Double, startAngle: Double, sweep: Double),
        transform: Transform3D,
        fromStart: Bool,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (point: Vector3, offset: Double)? {
        let mirror = transform.reversesOrientation2D
        let s = transform.scale
        let wr = params.radius * 0.5 * (abs(s.x) + abs(s.y))
        guard wr > 1e-12 else { return nil }
        let wc = transform.transformPoint(params.center)
        let segStartPt = transform.transformPoint(Vector3(
            x: params.center.x + params.radius * cos(params.startAngle),
            y: params.center.y + params.radius * sin(params.startAngle),
            z: params.center.z))
        let wStart = atan2(segStartPt.y - wc.y, segStartPt.x - wc.x)
        let wSweep = mirror ? -params.sweep : params.sweep
        let wEnd = wStart + wSweep
        let refAngle = fromStart ? wStart : wEnd
        let forwardSign: Double
        if fromStart {
            forwardSign = (wSweep >= 0) ? -1.0 : 1.0
        } else {
            forwardSign = (wSweep >= 0) ? 1.0 : -1.0
        }
        return nearestCircleBoundaryHit(
            centerX: wc.x, centerY: wc.y, radius: wr, endZ: wc.z,
            refAngle: refAngle, forwardSign: forwardSign,
            boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
    }
    // MARK: - Extend Spline Solver

    /// Extends a spline only when its end-tangent ray lands cleanly on a
    /// boundary: the picked end control point moves onto the hit (clamped
    /// ends interpolate their end control points exactly, so the extended
    /// curve lands on the boundary). Anything else — no hit, degenerate
    /// tangent, unclamped end — reports a clear cannot-extend message.
    nonisolated static func extendSplineEnd(
        controlPoints: [Vector3], knots: [Double], degree: Int, weights: [Double]?,
        color: ColorRGBA?,
        transform: Transform3D,
        pickWorld: Vector3,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        guard controlPoints.count >= 2,
              knots.count == controlPoints.count + degree + 1
        else {
            return (nil, false, "That spline cannot be extended.")
        }
        let minT = knots[degree]
        let maxT = knots[controlPoints.count]
        guard maxT > minT else {
            return (nil, false, "That spline cannot be extended.")
        }
        // Only clamped ends interpolate the end control point exactly, which
        // is what makes the moved point land on the boundary.
        func endMultiplicity(_ knot: Double, fromStart: Bool) -> Int {
            let vals = fromStart ? knots.prefix(degree + 1) : knots.suffix(degree + 1)
            return vals.filter { abs($0 - knot) <= 1e-9 }.count
        }
        guard let pStartLocal = NURBSEvaluator.evaluateAt(
            degree: degree, knots: knots, controlPoints: controlPoints, weights: w, at: minT),
              let pEndLocal = NURBSEvaluator.evaluateAt(
                  degree: degree, knots: knots, controlPoints: controlPoints, weights: w, at: maxT)
        else {
            return (nil, false, "That spline cannot be extended.")
        }
        let wStart = transform.transformPoint(pStartLocal)
        let wEnd = transform.transformPoint(pEndLocal)
        let dStart = (pickWorld.x - wStart.x) * (pickWorld.x - wStart.x)
            + (pickWorld.y - wStart.y) * (pickWorld.y - wStart.y)
        let dEnd = (pickWorld.x - wEnd.x) * (pickWorld.x - wEnd.x)
            + (pickWorld.y - wEnd.y) * (pickWorld.y - wEnd.y)
        let extendingEnd: ExtendEnd = (dEnd <= dStart) ? .end : .start
        guard endMultiplicity(extendingEnd == .end ? maxT : minT,
                             fromStart: extendingEnd == .start) == degree + 1
        else {
            return (nil, false, "That spline cannot be extended.")
        }
        let eps = max(1e-6, (maxT - minT) * 1e-4)
        let tRef = (extendingEnd == .end) ? maxT : minT
        let tIn = (extendingEnd == .end) ? maxT - eps : minT + eps
        guard let pRefLocal = NURBSEvaluator.evaluateAt(
            degree: degree, knots: knots, controlPoints: controlPoints, weights: w, at: tRef),
              let pInLocal = NURBSEvaluator.evaluateAt(
                  degree: degree, knots: knots, controlPoints: controlPoints, weights: w, at: tIn)
        else {
            return (nil, false, "That spline cannot be extended.")
        }
        var dx = pRefLocal.x - pInLocal.x
        var dy = pRefLocal.y - pInLocal.y
        let localLen = hypot(dx, dy)
        guard localLen > 1e-12 else {
            return (nil, false, "The spline has no usable end tangent.")
        }
        dx /= localLen; dy /= localLen
        let wRef = transform.transformPoint(pRefLocal)
        let wAhead = transform.transformPoint(Vector3(
            x: pRefLocal.x + dx, y: pRefLocal.y + dy, z: pRefLocal.z))
        var wdx = wAhead.x - wRef.x, wdy = wAhead.y - wRef.y
        let worldLen = hypot(wdx, wdy)
        guard worldLen > 1e-12 else {
            return (nil, false, "The spline has no usable end tangent.")
        }
        wdx /= worldLen; wdy /= worldLen
        guard let hit = nearestRayBoundaryHit(
            origin: wRef, directionX: wdx, directionY: wdy,
            boundaries: boundaries, allowBoundaryExtension: allowBoundaryExtension)
        else {
            return (nil, false, "The spline has no clean boundary hit along its end tangent.")
        }
        var newCPs = controlPoints
        let h = transform.inverse().transformPoint(hit)
        if extendingEnd == .end {
            newCPs[newCPs.count - 1] = Vector3(
                x: h.x, y: h.y, z: newCPs[newCPs.count - 1].z)
        } else {
            newCPs[0] = Vector3(x: h.x, y: h.y, z: newCPs[0].z)
        }
        return ([.spline(
            controlPoints: newCPs, knots: knots, degree: degree, weights: weights,
            color: color)], true, nil)
    }

    // MARK: - Extend Hit Search

    /// Nearest boundary hit along a world-space ray (the target's natural
    /// path), or nil when nothing is in reach. `allowBoundaryExtension`
    /// (EDGEMODE=1) lets each boundary cutter extend along its own natural
    /// path; otherwise only built geometry counts.
    nonisolated static func nearestRayBoundaryHit(
        origin: Vector3,
        directionX: Double, directionY: Double,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> Vector3? {
        let ray = Curve2d.ray(Ray2d(
            origin: Point2d(x: origin.x, y: origin.y),
            direction: Vec2d(x: directionX, y: directionY)))
        var best: Vector3? = nil
        var bestDist = Double.infinity
        func consider(_ pt: Point2d) {
            let dx = pt.x - origin.x, dy = pt.y - origin.y
            let forward = dx * directionX + dy * directionY
            guard forward > 1e-9 else { return }
            let dist = hypot(dx, dy)
            if dist < bestDist {
                bestDist = dist
                best = Vector3(x: pt.x, y: pt.y, z: origin.z)
            }
        }
        for seg in boundaries.segments {
            let cutter = Curve2d.line(LineSeg2d(
                start: Point2d(x: seg.0.x, y: seg.0.y),
                end: Point2d(x: seg.1.x, y: seg.1.y)))
            for hit in Intersector2D.intersect(
                ray, cutter, extendA: false, extendB: allowBoundaryExtension) {
                consider(hit.point)
            }
        }
        for exact in boundaries.exactCurves {
            for hit in Intersector2D.intersect(
                ray, exact, extendA: false, extendB: allowBoundaryExtension) {
                consider(hit.point)
            }
        }
        return best
    }

    /// Nearest boundary hit on a world-space circle past `refAngle` along
    /// `forwardSign` (+1 CCW, -1 CW), with its angular offset. The full
    /// circle is intersected and hits on the existing span are filtered by
    /// the offset, so extension continues exactly along the target's arc.
    nonisolated static func nearestCircleBoundaryHit(
        centerX: Double, centerY: Double, radius: Double, endZ: Double,
        refAngle: Double, forwardSign: Double,
        boundaries: TrimCuttingEdges,
        allowBoundaryExtension: Bool
    ) -> (point: Vector3, offset: Double)? {
        let circle = Curve2d.circle(Circle2d(
            center: Point2d(x: centerX, y: centerY), radius: radius))
        var best: (point: Vector3, offset: Double)? = nil
        func consider(_ pt: Point2d) {
            let a = atan2(pt.y - centerY, pt.x - centerX)
            let offset: Double
            if forwardSign >= 0 {
                offset = normAngle(a - refAngle)
            } else {
                offset = normAngle(refAngle - a)
            }
            guard offset > 1e-7 && offset < 2.0 * .pi - 1e-7 else { return }
            guard offset * radius > 1e-9 else { return }
            if best == nil || offset < best!.offset {
                best = (Vector3(x: pt.x, y: pt.y, z: endZ), offset)
            }
        }
        for seg in boundaries.segments {
            let cutter = Curve2d.line(LineSeg2d(
                start: Point2d(x: seg.0.x, y: seg.0.y),
                end: Point2d(x: seg.1.x, y: seg.1.y)))
            for hit in Intersector2D.intersect(
                circle, cutter, extendA: false, extendB: allowBoundaryExtension) {
                consider(hit.point)
            }
        }
        for exact in boundaries.exactCurves {
            for hit in Intersector2D.intersect(
                circle, exact, extendA: false, extendB: allowBoundaryExtension) {
                consider(hit.point)
            }
        }
        return best
    }

    /// Squared world distance from a point to a segment (nearest-end helper).
    nonisolated static func pointSegDistSq(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-24 else {
            let ex = p.x - a.x, ey = p.y - a.y
            return ex * ex + ey * ey
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = max(0.0, min(1.0, t))
        let qx = a.x + t * dx, qy = a.y + t * dy
        let ex = p.x - qx, ey = p.y - qy
        return ex * ex + ey * ey
    }

    /// World-space tessellation of one primitive for extend ghosts and fence
    /// crossing tests (StretchCommand ghost idiom, off the main actor).
    nonisolated public static func extendWorldStrips(
        _ primitive: CADPrimitive, transform: Transform3D
    ) -> [[Vector3]] {
        func world(_ points: [Vector3]) -> [Vector3] {
            points.map { transform.transformPoint($0) }
        }
        switch primitive {
        case .line(let start, let end, _):
            return [world([start, end])]
        case .polyline(let path, _):
            let pts = path.tessellatedPoints()
            return pts.count >= 2 ? [world(pts)] : []
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: w, segmentsPerSpan: 8)
            return [world(evaluated.isEmpty ? controlPoints : evaluated)]
        case .circle(let center, let radius, _):
            let points = (0...64).map { index -> Vector3 in
                let angle = 2.0 * Double.pi * Double(index) / 64.0
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z)
            }
            return [world(points)]
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * Double.pi }
            let divisions = max(8, Int(ceil(span * 32.0 / Double.pi)))
            let points = (0...divisions).map { index -> Vector3 in
                let angle = startAngle + span * Double(index) / Double(divisions)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z)
            }
            return [world(points)]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let minor = Vector3(x: -majorAxis.y * minorRatio, y: majorAxis.x * minorRatio, z: 0)
            let points = (0...64).map { index -> Vector3 in
                let t = 2.0 * Double.pi * Double(index) / 64.0
                return center + majorAxis * cos(t) + minor * sin(t)
            }
            return [world(points)]
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                origin,
            ]
            return [world(corners)]
        case .polygon(let points, _), .fillPolygon(let points, _):
            guard points.count >= 2 else { return [] }
            var loop = points
            if let first = loop.first { loop.append(first) }
            return [world(loop)]
        default:
            return []
        }
    }

    /// First fence-segment midpoint crossing an entity's world geometry, or
    /// nil when no fence segment touches it. The midpoint acts as the pick
    /// for end disambiguation (the end nearest the fence extends).
    nonisolated public static func fenceCrossingPick(
        entity: CADEntity, fence: [(Vector3, Vector3)]
    ) -> Vector3? {
        guard let geom = entity.localGeometry else { return nil }
        let strips = geom.flatMap { extendWorldStrips($0, transform: entity.transform) }
        guard strips.contains(where: { $0.count >= 2 }) else { return nil }
        for (f1, f2) in fence {
            for strip in strips {
                guard strip.count >= 2 else { continue }
                for i in 0..<(strip.count - 1) {
                    if CADRectSelect.segmentsIntersect(strip[i], strip[i + 1], f1, f2) {
                        return Vector3(
                            x: 0.5 * (f1.x + f2.x),
                            y: 0.5 * (f1.y + f2.y),
                            z: 0.5 * (f1.z + f2.z))
                    }
                }
            }
        }
        return nil
    }
}