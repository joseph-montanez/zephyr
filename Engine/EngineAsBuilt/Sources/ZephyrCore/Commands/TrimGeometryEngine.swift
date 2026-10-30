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
    public static func explode(primitive: CADPrimitive, t: Transform3D) -> [(Vector3, Vector3)] {
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
    public static func normAngle(_ v: Double) -> Double {
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
    public struct TrimCuttingEdges: Sendable {
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

    public static func collectCuttingSegments(
        document: CADDocument,
        cuttingHandles: Set<UUID>?,
        excludedHandle: UUID? = nil
    ) -> (cuttingSegments: [(Vector3, Vector3)], exactLineCuttingSegments: [(Vector3, Vector3)], exactCurves: [Curve2d]) {
        let edges = collectCuttingEdges(
            document: document, cuttingHandles: cuttingHandles, excludedHandle: excludedHandle)
        return (edges.segments, edges.exactLines, edges.exactCurves)
    }

    public static func collectCuttingEdges(
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
            guard let layer = document.layer(for: otherEntity.layerID), layer.isVisible else { continue }
            guard otherEntity.blockID == nil else { continue }
            guard let geom = document.resolvedGeometry(for: otherEntity) else { continue }

            let segStart = edges.segments.count
            let lineStart = edges.exactLines.count
            let curveStart = edges.exactCurves.count
            for prim in geom {
                if case .line(let start, let end, _) = prim {
                    let segment = (otherEntity.transform.transformPoint(start), otherEntity.transform.transformPoint(end))
                    edges.segments.append(segment)
                    edges.exactLines.append(segment)
                } else {
                    // Exact world-space cutter curves (no chord error) for the
                    // analytical solvers. Lines are covered by the segment
                    // path, so only non-line curves are added here. When an
                    // exact curve exists its exploded chords are NOT also
                    // added: chord hits duplicate exact hits at chord-error
                    // offsets and made cuts land off-curve (approximate).
                    let exact = exactWorldCurves(for: prim, transform: otherEntity.transform)
                    edges.exactCurves.append(contentsOf: exact)
                    if exact.isEmpty {
                        edges.segments.append(contentsOf: explode(primitive: prim, t: otherEntity.transform))
                    }
                }
            }
            edges.rangesByHandle[otherEntity.handle] = (
                segments: segStart..<edges.segments.count,
                exactLines: lineStart..<edges.exactLines.count,
                exactCurves: curveStart..<edges.exactCurves.count)
        }

        return edges
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

    // MARK: - Primitive Trimming Solvers

    /// Trims an entire entity against cutting edges using the provided criterion.
    public static func trimEntity(
        entity: CADEntity,
        document: CADDocument,
        criterion: TrimCriterion,
        cuttingSegments: [(Vector3, Vector3)],
        exactLines: [(Vector3, Vector3)],
        zoom: Double,
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
                zoom: zoom,
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
                    zoom: zoom,
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
        zoom: Double,
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
                exactLines: exactLines, zoom: zoom, exactCurves: exactCurves
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
        let targetLine = LineSeg2d(start: ws.point2d, end: we.point2d)
        for edge in cuttingSegments {
            let cutter = LineSeg2d(start: edge.0.point2d, end: edge.1.point2d)
            let res = Intersector2D.intersectLineLine(
                targetLine, cutter, extendA: false, extendB: false)
            for hit in res { collect(hit.paramA) }
        }
        // Exact cutter curves (arcs/splines/ellipses/bulges): line cutters
        // are already covered by the segment path, so skip those.
        let targetCurve = Curve2d.line(targetLine)
        for exact in exactCurves {
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
        for edge in cuttingSegments {
            let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
            for pt in pts {
                let a = atan2(pt.y - wc.y, pt.x - wc.x)
                if CADGeometryMath.angleIsOnCCWSweep(angle: a, start: wsa, end: wsa + span) {
                    collectArc(normAngle(a - wsa))
                }
            }
        }
        // Exact cutter curves: world arc vs analytical cutter.
        let worldArc = Arc2d(center: wc.point2d, radius: wr, startAngle: wsa, sweep: span)
        for exact in exactCurves {
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
        for edge in cuttingSegments {
            let pts = intersectSegmentCircle(segmentA: edge.0, segmentB: edge.1, circleCenter: wc, radius: wr)
            for pt in pts {
                collectCircle(normAngle(atan2(pt.y - wc.y, pt.x - wc.x)))
            }
        }
        let worldCircle = Circle2d(center: wc.point2d, radius: wr)
        for exact in exactCurves {
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
        zoom: Double,
        exactCurves: [Curve2d] = []
    ) -> (result: [CADPrimitive]?, modified: Bool, errorMsg: String?) {
        let invTransform = transform.inverse()
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let minT = knots[p]
        let maxT = knots[controlPoints.count]
        let parameterDuplicateTolerance = max(1e-6, (maxT - minT) * 1e-7)
        let scale = max(abs(transform.scale.x), abs(transform.scale.y), 1e-9)
        let localTolerance = max(1e-7, (4.0 / zoom) / scale)
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

        for edge in cuttingSegments { findHitsKernel(on: edge) }
        for exact in exactCurves { findHitsKernelCurve(exact) }
        for edge in localExactLineEdges {
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
        for edge in cuttingSegments {
            let cutter = Curve2d.line(LineSeg2d(start: edge.0.point2d, end: edge.1.point2d))
            for (i, seg) in worldSegs.enumerated() {
                let results = Intersector2D.intersect(.polySegment(seg), cutter)
                for h in results {
                    let segL = segLen(seg)
                    guard segL > 1e-12 else { continue }
                    collectPline((cumLen[i] + h.paramA * segL) / totalLen)
                }
            }
        }
        // Exact cutter curves (skip lines: covered above).
        for exact in exactCurves {
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

        for edge in cuttingSegments {
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
        if !exactCurves.isEmpty {
            for exact in exactCurves {
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
}
