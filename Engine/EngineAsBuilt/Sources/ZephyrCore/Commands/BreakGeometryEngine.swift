// Sources/ZephyrCore/Commands/BreakGeometryEngine.swift
import Foundation
import ZephyrKernel

// =========================================================================
// MARK: - BreakGeometryEngine
//
// Pure geometry for the AutoCAD-style BREAK / BREAKATPOINT commands.
//
// All decisions run in the entity's LOCAL space: both world break points
// are mapped through the inverse entity transform, the kernel solves run
// on `toKernelCurves()` / `toKernelSegments()` values, and rebuilt
// primitives stay local (the document re-applies the untouched entity
// transform). Local-space solving is exact under similarity transforms
// (rotation/translation/uniform scale, including mirrors); under
// non-uniform scale or shear the closest-point projection is approximate.
//
// Per-type rules:
//   * Open line/arc/polyline/spline + two params (t1 <= t2): the span
//     [t1, t2] is erased, keeping [0, t1] on the original handle and
//     [t2, 1] on a new entity. Either side may vanish (a point at/beyond
//     an end removes that end); both vanishing deletes the object.
//   * Equal params (typed `@`, repeated pick, or BREAKATPOINT's single
//     point) split with no gap: [0, t] and [t, 1].
//   * Circle: the CCW span first-to-second is removed, leaving one arc
//     (start = second, sweep = remainder). Equal params leave a full
//     360-degree arc starting at that point.
//   * Closed polyline: the span is removed along path order (wrapping),
//     leaving ONE open polyline; widths and bulges are interpolated at
//     the cuts by `CurveEval.splitAt`.
//   * Everything else (text, points, blocks, xrefs, hatches, images,
//     tables, ellipses, rays, xlines, fills, dimensions, leaders,
//     associative arrays, compound entities) is rejected with a message.
// =========================================================================

public enum BreakGeometryEngine {

    /// Outcome of splitting one entity.
    public enum Result: Sendable {
        /// Degenerate split (at an endpoint): keep the geometry as-is.
        case unchanged
        /// One surviving piece; the caller replaces the entity geometry.
        case singlePiece([CADPrimitive])
        /// Two surviving pieces; the caller keeps `first` on the original
        /// handle and creates a new entity for `second`.
        case twoPieces(first: [CADPrimitive], second: [CADPrimitive])
        /// The span covered the whole object; the caller deletes it.
        case removeObject
        /// The entity kind cannot be broken; the message names it.
        case reject(String)
    }

    /// Parametric tolerance for "same point" (matches
    /// `KernelTolerance.parametric`, the `splitAt` degenerate guard).
    public static let equalTolerance: Double = 1e-9

    // MARK: - First-point projection

    /// Project a world pick point onto the entity's breakable geometry
    /// (world space). Nil when the entity kind cannot be broken.
    public static func projectedPoint(
        entity: CADEntity, worldPick: Vector3
    ) -> Vector3? {
        guard breakableKind(of: entity) else { return nil }
        guard let prim = singlePrimitive(of: entity) else { return nil }
        let inv = entity.transform.inverse()
        let local = inv.transformPoint(worldPick)
        var best: (point: Point2d, dist: Double)?
        for curve in prim.toKernelCurves() {
            let proj = Projector2D.closestPointOnCurve(
                curve, to: local.point2d, clamped: true)
            if best == nil || proj.distance < best!.dist {
                best = (proj.point, proj.distance)
            }
        }
        guard let hit = best else { return nil }
        return entity.transform.transformPoint(Vector3(hit.point))
    }

    // MARK: - Split

    /// Split `entity` between two world points. The first point is
    /// projected onto the object (clamped); the second point is projected
    /// clamped too, so a second point beyond an end removes that end.
    public static func split(
        entity: CADEntity,
        firstWorld: Vector3,
        secondWorld: Vector3
    ) -> Result {
        if entity.blockID != nil {
            return .reject(
                "BREAK does not support block references or external references.")
        }
        if entity.dimensionMetadata != nil {
            return .reject("BREAK does not support dimensions.")
        }
        if entity.leaderData != nil {
            return .reject("BREAK does not support leaders.")
        }
        if entity.arrayData != nil {
            return .reject("BREAK does not support associative array members.")
        }
        guard let prim = singlePrimitive(of: entity) else {
            if let prims = entity.localGeometry, prims.count != 1 {
                return .reject("BREAK does not support compound entities.")
            }
            return .reject("BREAK found no geometry on that object.")
        }
        switch prim {
        case .line, .arc, .circle, .spline, .polyline:
            break
        default:
            return .reject(unsupportedMessage(for: prim))
        }

        let inv = entity.transform.inverse()
        let local1 = inv.transformPoint(firstWorld)
        let local2 = inv.transformPoint(secondWorld)

        switch prim {
        case .line:
            guard let curve = prim.toKernelCurves().first else {
                return .reject("BREAK found no geometry on that object.")
            }
            guard lineLength(curve) > 1e-12 else { return .unchanged }
            let (t1, t2) = orderedParams(
                curve: curve, local1: local1, local2: local2)
            return splitOpen(
                curve: curve, source: prim, t1: t1, t2: t2,
                convert: { convertCurve($0, source: prim) })
        case .arc:
            guard let curve = prim.toKernelCurves().first else {
                return .reject("BREAK found no geometry on that object.")
            }
            guard case .arc(let a) = curve, a.radius > 1e-12 else {
                return .unchanged
            }
            let (t1, t2) = orderedParams(
                curve: curve, local1: local1, local2: local2)
            return splitOpen(
                curve: curve, source: prim, t1: t1, t2: t2,
                convert: { convertCurve($0, source: prim) })
        case .circle:
            return splitCircle(prim: prim, local1: local1, local2: local2)
        case .spline:
            guard let curve = prim.toKernelCurves().first,
                  case .spline(let s) = curve, s.isValid else {
                return .reject("BREAK found no geometry on that object.")
            }
            let (t1, t2) = orderedParams(
                curve: curve, local1: local1, local2: local2)
            return splitSpline(source: prim, t1: t1, t2: t2)
        case .polyline(let path, _):
            return splitPolyline(
                prim: prim, path: path, local1: local1, local2: local2)
        default:
            return .reject(unsupportedMessage(for: prim))
        }
    }

    // MARK: - Open curves (line / arc / spline)

    /// Clamped params for both points on one curve, ordered (t1 <= t2).
    private static func orderedParams(
        curve: Curve2d, local1: Vector3, local2: Vector3
    ) -> (Double, Double) {
        let p1 = Projector2D.closestPointOnCurve(
            curve, to: local1.point2d, clamped: true).param
        let p2 = Projector2D.closestPointOnCurve(
            curve, to: local2.point2d, clamped: true).param
        return p1 <= p2 ? (p1, p2) : (p2, p1)
    }

    /// Erase [t1, t2] from an open curve. `convert` rebuilds caller-kind
    /// primitives (splines are not representable via `fromKernelCurve`).
    private static func splitOpen(
        curve: Curve2d,
        source: CADPrimitive,
        t1: Double,
        t2: Double,
        convert: (Curve2d) -> CADPrimitive?
    ) -> Result {
        if t2 - t1 <= equalTolerance {
            // No gap: single split at t1.
            let first = t1 > equalTolerance
                ? CurveEval.splitAt(curve, t1: 0, t2: t1) : nil
            let second = t1 < 1 - equalTolerance
                ? CurveEval.splitAt(curve, t1: t1, t2: 1) : nil
            return assemble(first: first, second: second, convert: convert)
        }
        let first = t1 > equalTolerance
            ? CurveEval.splitAt(curve, t1: 0, t2: t1) : nil
        let second = t2 < 1 - equalTolerance
            ? CurveEval.splitAt(curve, t1: t2, t2: 1) : nil
        if first == nil && second == nil { return .removeObject }
        return assemble(first: first, second: second, convert: convert)
    }

    /// Lift optional curve pieces into a `Result`, dropping degenerate
    /// pieces `splitAt` refused and converting the survivors.
    private static func assemble(
        first: Curve2d?,
        second: Curve2d?,
        convert: (Curve2d) -> CADPrimitive?
    ) -> Result {
        let a = first.flatMap(convert)
        let b = second.flatMap(convert)
        switch (a, b) {
        case let (.some(x), .some(y)): return .twoPieces(first: [x], second: [y])
        case let (.some(x), nil): return .singlePiece([x])
        case let (nil, .some(y)): return .singlePiece([y])
        case (nil, nil): return .unchanged
        }
    }

    // MARK: - Circle

    /// Remove the CCW span first-to-second, leaving one arc. Equal params
    /// are a no-op: a no-gap split of a closed curve is the curve itself.
    private static func splitCircle(
        prim: CADPrimitive, local1: Vector3, local2: Vector3
    ) -> Result {
        guard case .circle(let center, let radius, _) = prim,
              radius > 1e-12 else { return .unchanged }
        guard let circle = prim.toKernelCurves().first else {
            return .reject("BREAK found no geometry on that object.")
        }
        let t1 = Projector2D.closestPointOnCurve(
            circle, to: local1.point2d, clamped: true).param
        let t2 = Projector2D.closestPointOnCurve(
            circle, to: local2.point2d, clamped: true).param
        var span = (t2 - t1).truncatingRemainder(dividingBy: 1.0)
        if span < 0 { span += 1.0 }
        if span <= equalTolerance || span >= 1 - equalTolerance {
            // No gap on a closed curve is the curve itself: keep the
            // circle (a 360-degree arc cannot round-trip the bridge's
            // sweep normalization, so inventing one would corrupt DXF).
            return .unchanged
        }
        let arc: Curve2d = .arc(Arc2d(
            center: center.point2d, radius: radius,
            startAngle: 2.0 * .pi * t2, sweep: 2.0 * .pi * (1.0 - span)))
        guard let rebuilt = convertCurve(arc, source: prim) else {
            return .reject("BREAK found no geometry on that object.")
        }
        return .singlePiece([rebuilt])
    }

    // MARK: - Spline

    /// Erase [t1, t2] (normalized params) from a spline. The split itself
    /// runs on `NURBSEvaluator.subdivide` — the Trim-trusted Core splitter —
    /// rather than `CurveEval.splitAt`: `splitAt`'s `.spline` branch bottoms
    /// out in `SplineEval.split`, whose consistency guard can never pass, so
    /// that path always returns nil. Params map onto the knot domain the
    /// same way `CurveEval` maps them.
    private static func splitSpline(
        source: CADPrimitive, t1: Double, t2: Double
    ) -> Result {
        guard case .spline(let cps, let knots, let degree, let weights, let color) = source,
              cps.count >= 2, degree >= 1,
              knots.count == cps.count + degree + 1 else {
            return .reject("BREAK found no geometry on that object.")
        }
        let u0 = knots[degree]
        let u1 = knots[cps.count]
        guard u1 > u0 else { return .unchanged }
        let lo = min(t1, t2), hi = max(t1, t2)
        let w = weights ?? Array(repeating: 1.0, count: cps.count)
        func piece(_ comps: SplineComponents) -> CADPrimitive {
            .spline(
                controlPoints: comps.controlPoints,
                knots: comps.knots, degree: degree,
                weights: weights == nil ? nil : comps.weights,
                color: color)
        }
        if hi - lo <= equalTolerance {
            // No gap: single subdivide at u.
            let u = u0 + (u1 - u0) * lo
            guard u > u0, u < u1,
                  let halves = NURBSEvaluator.subdivide(
                      degree: degree, knots: knots,
                      controlPoints: cps, weights: w, at: u) else {
                return .unchanged
            }
            return .twoPieces(first: [piece(halves.left)], second: [piece(halves.right)])
        }
        // Distinct span: split at ua, then split the right remainder at ub.
        let ua = u0 + (u1 - u0) * lo
        let ub = u0 + (u1 - u0) * hi
        var left: SplineComponents?
        var rest: (cps: [Vector3], knots: [Double], weights: [Double]) = (cps, knots, w)
        if lo > equalTolerance {
            guard ua < u1,
                  let halves = NURBSEvaluator.subdivide(
                      degree: degree, knots: rest.knots,
                      controlPoints: rest.cps, weights: rest.weights, at: ua) else {
                return .reject("BREAK found no geometry on that object.")
            }
            left = halves.left
            rest = (halves.right.controlPoints, halves.right.knots, halves.right.weights)
        }
        var right: SplineComponents?
        if hi < 1 - equalTolerance {
            let floor = rest.knots.first ?? u1
            guard ub > floor,
                  let halves = NURBSEvaluator.subdivide(
                      degree: degree, knots: rest.knots,
                      controlPoints: rest.cps, weights: rest.weights, at: ub) else {
                return .reject("BREAK found no geometry on that object.")
            }
            right = halves.right
        }
        switch (left, right) {
        case let (.some(a), .some(b)):
            return .twoPieces(first: [piece(a)], second: [piece(b)])
        case let (.some(a), nil):
            return .singlePiece([piece(a)])
        case let (nil, .some(b)):
            return .singlePiece([piece(b)])
        case (nil, nil):
            return .removeObject
        }
    }

    // MARK: - Polylines (segment-wise)

    private struct SegHit {
        var index: Int
        var param: Double
        var distance: Double
    }

    /// Best (segment, param) for a local point across all segments.
    private static func bestSegment(
        _ segments: [PolySegment2d], local: Vector3
    ) -> SegHit? {
        var best: SegHit?
        for seg in segments {
            let proj = Projector2D.closestPointOnCurve(
                .polySegment(seg), to: local.point2d, clamped: true)
            if best == nil || proj.distance < best!.distance {
                best = SegHit(
                    index: seg.index, param: proj.param,
                    distance: proj.distance)
            }
        }
        return best
    }

    private static func splitPolyline(
        prim: CADPrimitive,
        path: CADPolyline,
        local1: Vector3,
        local2: Vector3
    ) -> Result {
        let segments = path.toKernelSegments()
        guard !segments.isEmpty else {
            return .reject("BREAK found no geometry on that object.")
        }
        guard let h1 = bestSegment(segments, local: local1),
              let h2 = bestSegment(segments, local: local2) else {
            return .reject("BREAK found no geometry on that object.")
        }
        var (ia, ta) = (h1.index, h1.param)
        var (ib, tb) = (h2.index, h2.param)
        let equal = ia == ib && abs(tb - ta) <= equalTolerance
        if !equal, ib < ia || (ib == ia && tb < ta) {
            let savedIndex = ia, savedParam = ta
            (ia, ta) = (ib, tb)
            (ib, tb) = (savedIndex, savedParam)
        }
        let byIndex = Dictionary(uniqueKeysWithValues: segments.map { ($0.index, $0) })
        guard let segA = byIndex[ia], let segB = byIndex[ib] else {
            return .reject("BREAK found no geometry on that object.")
        }
        if path.isClosed {
            return splitClosedPolyline(
                prim: prim, path: path, segments: segments,
                ia: ia, ta: ta, ib: ib, tb: tb, equal: equal,
                segA: segA, segB: segB)
        }
        // Open polyline: erase (ia, ta)..(ib, tb) along path order,
        // keeping the head on the original handle. Lists stay in path
        // order (`reindexed` numbers them positionally).
        var head: [PolySegment2d] = []
        var tail: [PolySegment2d] = []
        for seg in segments where seg.index < ia { head.append(seg) }
        if let s = CurveEval.splitAt(
            .polySegment(segA), t1: 0, t2: ta),
            case .polySegment(let ps) = s { head.append(ps) }
        if equal {
            if let s = CurveEval.splitAt(
                .polySegment(segB), t1: ta, t2: 1),
                case .polySegment(let ps) = s { tail.append(ps) }
        } else if let s = CurveEval.splitAt(
            .polySegment(segB), t1: tb, t2: 1),
            case .polySegment(let ps) = s { tail.append(ps) }
        for seg in segments where seg.index > ib { tail.append(seg) }
        return assemblePolyline(
            prim: prim, path: path, head: head, tail: tail)
    }

    /// Closed polyline: erase (ia, ta)..(ib, tb) along path order and
    /// return the complement as ONE open polyline piece.
    private static func splitClosedPolyline(
        prim: CADPrimitive,
        path: CADPolyline,
        segments: [PolySegment2d],
        ia: Int, ta: Double, ib: Int, tb: Double,
        equal: Bool,
        segA: PolySegment2d, segB: PolySegment2d
    ) -> Result {
        var kept: [PolySegment2d] = []
        if equal {
            if let s = CurveEval.splitAt(.polySegment(segB), t1: ta, t2: 1),
               case .polySegment(let ps) = s { kept.append(ps) }
            for seg in segments where seg.index > ib { kept.append(seg) }
            for seg in segments where seg.index < ia { kept.append(seg) }
            if let s = CurveEval.splitAt(.polySegment(segA), t1: 0, t2: ta),
               case .polySegment(let ps) = s { kept.append(ps) }
        } else {
            if let s = CurveEval.splitAt(.polySegment(segB), t1: tb, t2: 1),
               case .polySegment(let ps) = s { kept.append(ps) }
            for seg in segments where seg.index > ib { kept.append(seg) }
            for seg in segments where seg.index < ia { kept.append(seg) }
            if let s = CurveEval.splitAt(.polySegment(segA), t1: 0, t2: ta),
               case .polySegment(let ps) = s { kept.append(ps) }
        }
        guard !kept.isEmpty else { return .removeObject }
        let rebuilt = CADPolyline.fromKernelSegments(
            reindexed(kept), isClosed: false, template: path)
        return .singlePiece([.polyline(path: rebuilt, color: polylineColor(of: prim))])
    }

    /// Lift open-polyline head/tail segment lists into a `Result`.
    private static func assemblePolyline(
        prim: CADPrimitive,
        path: CADPolyline,
        head: [PolySegment2d],
        tail: [PolySegment2d]
    ) -> Result {
        if head.isEmpty && tail.isEmpty { return .removeObject }
        let color = polylineColor(of: prim)
        switch (head.isEmpty, tail.isEmpty) {
        case (false, false):
            let first = CADPolyline.fromKernelSegments(
                reindexed(head), isClosed: false, template: path)
            let second = CADPolyline.fromKernelSegments(
                reindexed(tail), isClosed: false, template: path)
            return .twoPieces(
                first: [.polyline(path: first, color: color)],
                second: [.polyline(path: second, color: color)])
        case (false, true):
            let first = CADPolyline.fromKernelSegments(
                reindexed(head), isClosed: false, template: path)
            return .singlePiece([.polyline(path: first, color: color)])
        default:
            let second = CADPolyline.fromKernelSegments(
                reindexed(tail), isClosed: false, template: path)
            return .singlePiece([.polyline(path: second, color: color)])
        }
    }

    /// `fromKernelSegments` sorts by index; wrapped closed-polyline
    /// complements reuse indices, so renumber sequentially in path order.
    private static func reindexed(
        _ segments: [PolySegment2d]
    ) -> [PolySegment2d] {
        segments.enumerated().map { (offset, seg) in
            PolySegment2d(
                index: offset, geometry: seg.geometry,
                startWidth: seg.startWidth, endWidth: seg.endWidth)
        }
    }

    // MARK: - Primitive conversion

    /// Rebuild a line/arc/circle-derived piece, preserving color and z.
    private static func convertCurve(
        _ curve: Curve2d, source: CADPrimitive
    ) -> CADPrimitive? {
        CADPrimitive.fromKernelCurve(curve, preservingColorFrom: source)
    }

    private static func polylineColor(of prim: CADPrimitive) -> ColorRGBA? {
        if case .polyline(_, let color) = prim { return color }
        return nil
    }

    private static func lineLength(_ curve: Curve2d) -> Double {
        guard case .line(let seg) = curve else { return 1 }
        return hypot(seg.end.x - seg.start.x, seg.end.y - seg.start.y)
    }

    // MARK: - Rejection messages

    private static func singlePrimitive(of entity: CADEntity) -> CADPrimitive? {
        guard let prims = entity.localGeometry, prims.count == 1 else {
            return nil
        }
        return prims.first
    }

    private static func breakableKind(of entity: CADEntity) -> Bool {
        guard entity.blockID == nil,
              entity.dimensionMetadata == nil,
              entity.leaderData == nil,
              entity.arrayData == nil,
              let prim = singlePrimitive(of: entity) else { return false }
        switch prim {
        case .line, .arc, .circle, .spline, .polyline:
            return true
        default:
            return false
        }
    }

    private static func unsupportedMessage(for prim: CADPrimitive) -> String {
        switch prim {
        case .text:
            return "BREAK does not support text."
        case .point:
            return "BREAK does not support point entities."
        case .ellipse:
            return "BREAK does not support ellipses."
        case .ray:
            return "BREAK does not support rays."
        case .xline:
            return "BREAK does not support construction lines (xlines)."
        case .hatch, .hatchPath:
            return "BREAK does not support hatches."
        case .image:
            return "BREAK does not support images."
        case .table:
            return "BREAK does not support tables."
        case .rect, .fillRect:
            return "BREAK does not support rectangles."
        case .polygon:
            return "BREAK does not support polygons."
        case .fillPolygon, .fillComplexPolygon, .gradient:
            return "BREAK does not support filled entities."
        case .penStroke:
            return "BREAK does not support pen strokes."
        default:
            return "BREAK does not support that object type."
        }
    }
}
