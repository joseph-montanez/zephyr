import Foundation

// =========================================================================
// MARK: - Intersector2D
//
// One canonical solver for all 2D curve-curve intersections.
// Precision strategy (PLAN-kernel-perf.md R3, user requirement: absolute
// precision preserved): tolerance stays absolute (linear = 1e-9), and
// robustness at large coordinates comes from LOCAL-FRAME SHIFTING — every
// analytic solver translates its inputs near the origin before forming
// quadratics/determinants, then translates results back. This removes the
// catastrophic cancellation that breaks naive solvers at state-plane
// magnitudes (~2.4e6, where 1 ULP ≈ 4.7e-10).

@frozen
public struct CurveIntersection2d: Hashable, Sendable {
    public var point: Point2d
    /// Normalized parameter on curve A ([0, 1] when strictly on span).
    public var paramA: Double
    /// Normalized parameter on curve B ([0, 1] when strictly on span).
    public var paramB: Double

    public init(point: Point2d, paramA: Double, paramB: Double) {
        self.point = point
        self.paramA = paramA
        self.paramB = paramB
    }
}

public enum Intersector2D: Sendable {

    // MARK: - Local-frame shifting

    /// Reference origin for a pair of curves: midpoint of their bounding-box
    /// centers. Solving relative to this point keeps intermediate magnitudes
    /// small even for state-plane coordinates.
    @inlinable
    static func referenceOrigin(_ a: Curve2d, _ b: Curve2d) -> Point2d {
        func center(of c: Curve2d) -> Point2d {
            switch c {
            case .line(let s): return Point2d(x: 0.5 * (s.start.x + s.end.x), y: 0.5 * (s.start.y + s.end.y))
            case .ray(let r): return r.origin
            case .xline(let x): return x.origin
            case .arc(let a): return a.center
            case .circle(let c): return c.center
            case .ellipse(let e): return e.center
            case .spline(let s):
                guard let box = SplineEval.controlBounds(s) else { return .zero }
                return Point2d(x: 0.5 * (box.min.x + box.max.x), y: 0.5 * (box.min.y + box.max.y))
            case .polySegment(let seg): return center(of: .line(LineSeg2d(start: seg.startPoint, end: seg.endPoint)))
            }
        }
        let ca = center(of: a), cb = center(of: b)
        return Point2d(x: 0.5 * (ca.x + cb.x), y: 0.5 * (ca.y + cb.y))
    }

    // MARK: - Shifted seed-consistent refinement

    /// Translate a curve exactly by moving its positional data. Directions and
    /// knot vectors are unchanged. Callers keep the same curve parameters, so
    /// only points move into a local frame.
    static func translatedCurve(_ curve: Curve2d, by origin: Point2d) -> Curve2d {
        let shift = Vec2d(x: -origin.x, y: -origin.y)
        func shifted(_ point: Point2d) -> Point2d { point.translated(by: shift) }
        switch curve {
        case .line(let seg):
            return .line(LineSeg2d(start: shifted(seg.start), end: shifted(seg.end)))
        case .ray(let r):
            return .ray(Ray2d(origin: shifted(r.origin), direction: r.direction))
        case .xline(let x):
            return .xline(XLine2d(origin: shifted(x.origin), direction: x.direction))
        case .arc(let a):
            return .arc(Arc2d(center: shifted(a.center), radius: a.radius,
                              startAngle: a.startAngle, sweep: a.sweep))
        case .circle(let c):
            return .circle(Circle2d(center: shifted(c.center), radius: c.radius))
        case .ellipse(let e):
            return .ellipse(Ellipse2d(center: shifted(e.center), majorAxis: e.majorAxis,
                                      minorRatio: e.minorRatio, startAngle: e.startAngle,
                                      sweep: e.sweep))
        case .spline(let s):
            return .spline(Spline2d(controlPoints: s.controlPoints.map(shifted),
                                    knots: s.knots, degree: s.degree, weights: s.weights))
        case .polySegment(let seg):
            switch seg.geometry {
            case .line(let l):
                return .line(LineSeg2d(start: shifted(l.start), end: shifted(l.end)))
            case .arc(let a):
                return .arc(Arc2d(center: shifted(a.center), radius: a.radius,
                                  startAngle: a.startAngle, sweep: a.sweep))
            }
        }
    }

    /// Exact bounding box for an arc sector. Endpoints plus every cardinal point
    /// inside the directed sweep are sufficient; chord boxes are not used for
    /// culling because a chord box can miss a sector that arches past it.
    static func exactArcSectorBounds(_ arc: Arc2d, from t0: Double, to t1: Double) -> BoundingBox2d {
        let theta0 = arc.startAngle + arc.sweep * t0
        let theta1 = arc.startAngle + arc.sweep * t1
        func point(_ theta: Double) -> Point2d {
            Point2d(x: arc.center.x + arc.radius * cos(theta),
                    y: arc.center.y + arc.radius * sin(theta))
        }
        var box = BoundingBox2d(min: point(theta0), max: point(theta0))
        box.include(point(theta1))
        func contains(_ theta: Double) -> Bool {
            if abs(arc.sweep) <= KernelTolerance.parametric { return theta == theta0 }
            let twoPi = 2.0 * .pi
            if arc.sweep > 0 {
                var delta = (theta - theta0).truncatingRemainder(dividingBy: twoPi)
                if delta < 0 { delta += twoPi }
                return delta <= arc.sweep + 1e-9
            } else {
                var delta = (theta0 - theta).truncatingRemainder(dividingBy: twoPi)
                if delta < 0 { delta += twoPi }
                return delta <= -arc.sweep + 1e-9
            }
        }
        for quadrant in 0..<4 {
            let candidate = Double(quadrant) * .pi / 2.0
            // Shift the cardinal direction by whole revolutions so the containment
            // test sees the copy adjacent to this sector.
            let twoPi = 2.0 * .pi
            let center = 0.5 * (theta0 + theta1)
            let shifted = candidate + twoPi * round((center - candidate) / twoPi)
            if contains(shifted) { box.include(point(shifted)) }
        }
        return box
    }

    /// Exact bounding box for an ellipse sector. Endpoints plus every axis-aligned
    /// extremum inside the directed sweep are sufficient; 64-sample approximations
    /// are not used here because broad-phase boxes must never under-bound.
    static func exactEllipseSectorBounds(_ ellipse: Ellipse2d, from t0: Double, to t1: Double) -> BoundingBox2d {
        let theta0 = ellipse.startAngle + ellipse.sweep * t0
        let theta1 = ellipse.startAngle + ellipse.sweep * t1
        func point(_ theta: Double) -> Point2d {
            let c = cos(theta), s = sin(theta)
            let minor = ellipse.minorAxis
            return Point2d(
                x: ellipse.center.x + ellipse.majorAxis.x * c + minor.x * s,
                y: ellipse.center.y + ellipse.majorAxis.y * c + minor.y * s)
        }
        var box = BoundingBox2d(min: point(theta0), max: point(theta0))
        box.include(point(theta1))
        func contains(_ theta: Double) -> Bool {
            if abs(ellipse.sweep) <= KernelTolerance.parametric { return theta == theta0 }
            let twoPi = 2.0 * .pi
            if ellipse.sweep > 0 {
                var delta = (theta - theta0).truncatingRemainder(dividingBy: twoPi)
                if delta < 0 { delta += twoPi }
                return delta <= ellipse.sweep + 1e-9
            } else {
                var delta = (theta0 - theta).truncatingRemainder(dividingBy: twoPi)
                if delta < 0 { delta += twoPi }
                return delta <= -ellipse.sweep + 1e-9
            }
        }
        let minor = ellipse.minorAxis
        for amplitudes in [(ellipse.majorAxis.x, minor.x), (ellipse.majorAxis.y, minor.y)] {
            guard hypot(amplitudes.0, amplitudes.1) > KernelTolerance.linear else { continue }
            let base = atan2(amplitudes.1, amplitudes.0)
            let center = 0.5 * (theta0 + theta1)
            let middle = Int(round((center - base) / .pi))
            for k in (middle - 2)...(middle + 2) {
                let candidate = base + Double(k) * .pi
                if contains(candidate) { box.include(point(candidate)) }
            }
        }
        return box
    }

    /// Conservative broad-phase bounds. Splines use their control hull and
    /// ellipses use the exact sector box, so viewport and overlap tests cannot
    /// miss because of tessellation or sampling density.
    static func conservativeBounds(_ curve: Curve2d) -> BoundingBox2d? {
        switch curve {
        case .arc(let a):
            return exactArcSectorBounds(a, from: 0, to: 1)
        case .circle(let c):
            return BoundingBox2d(
                min: Point2d(x: c.center.x - c.radius, y: c.center.y - c.radius),
                max: Point2d(x: c.center.x + c.radius, y: c.center.y + c.radius))
        case .ellipse(let e):
            return exactEllipseSectorBounds(e, from: 0, to: 1)
        default:
            return CurveEval.boundingBox(curve)
        }
    }

    /// Broad origin at the center of the curves' conservative overlap when one
    /// exists. For large world coordinates this keeps both operands small during
    /// the coarse chord stage; disjoint operands keep the midpoint behavior.
    static func broadSeedOrigin(_ a: Curve2d, _ b: Curve2d) -> Point2d {
        guard let boxA = conservativeBounds(a), let boxB = conservativeBounds(b) else {
            return referenceOrigin(a, b)
        }
        let lower = Point2d(x: max(boxA.min.x, boxB.min.x), y: max(boxA.min.y, boxB.min.y))
        let upper = Point2d(x: min(boxA.max.x, boxB.max.x), y: min(boxA.max.y, boxB.max.y))
        guard lower.x <= upper.x && lower.y <= upper.y else { return referenceOrigin(a, b) }
        return Point2d(x: 0.5 * (lower.x + upper.x), y: 0.5 * (lower.y + upper.y))
    }

    /// Conservative bound for one spline parameter interval. Seeds are generated
    /// from chords, but culling is done on active control polygons so a span
    /// that arches past its chord cannot be false-rejected before refinement.
    static func splineIntervalConservativeBounds(
        _ spline: Spline2d, from t0: Double, to t1: Double
    ) -> BoundingBox2d? {
        guard let (u0, u1) = SplineEval.domain(of: spline), u1 > u0,
              SplineEval.hasPositiveWeights(spline) else { return nil }
        let lower = min(t0, t1)
        let upper = max(t0, t1)
        var box: BoundingBox2d?
        for knotT in [lower, upper, 0.5 * (lower + upper)] {
            let u = u0 + (u1 - u0) * knotT
            guard let span = SplineEval.activeControlBounds(spline, at: u) else { return nil }
            if var current = box {
                current.include(span.min)
                current.include(span.max)
                box = current
            } else {
                box = span
            }
        }
        return box
    }

    /// Conservative bound for one analytic parameter interval. Circular and
    /// elliptical sectors use exact sector boxes instead of chord boxes.
    static func analyticIntervalConservativeBounds(
        _ curve: Curve2d, from t0: Double, to t1: Double
    ) -> BoundingBox2d? {
        switch curve {
        case .line(let seg):
            var box = BoundingBox2d(min: seg.start, max: seg.end)
            box.include(CurveEval.pointAt(.line(seg), t: t0))
            box.include(CurveEval.pointAt(.line(seg), t: t1))
            return box
        case .arc(let arc):
            return exactArcSectorBounds(arc, from: t0, to: t1)
        case .ellipse(let e):
            return exactEllipseSectorBounds(e, from: t0, to: t1)
        default:
            return nil
        }
    }

    /// Global-parameter interval searched around one chord seed. Splines stay
    /// inside the nonzero knot span containing the seed; bounded analytic
    /// curves stay inside their chord segment (and their curve domain unless
    /// the caller explicitly extends them).
    static func activeSeedInterval(
        for curve: Curve2d,
        seedT: Double,
        chunk: (Double, Double)?,
        extend: Bool
    ) -> (Double, Double)? {
        switch curve {
        case .spline(let s):
            guard let (u0, u1) = SplineEval.domain(of: s), u1 > u0,
                  let knot = SplineEval.nonzeroKnotSpanBounds(s, containing: u0 + (u1 - u0) * seedT) else {
                return nil
            }
            var lower = chunk?.0 ?? 0.0
            var upper = chunk?.1 ?? 1.0
            lower = max(lower, (knot.0 - u0) / (u1 - u0))
            upper = min(upper, (knot.1 - u0) / (u1 - u0))
            if !extend {
                lower = max(lower, 0.0)
                upper = min(upper, 1.0)
            }
            guard upper - lower > KernelTolerance.parametric else { return nil }
            return (lower, upper)
        case .line, .arc, .circle, .ellipse:
            if extend { return (-.infinity, .infinity) }
            var lower = chunk?.0 ?? 0.0
            var upper = chunk?.1 ?? 1.0
            lower = max(lower, 0.0)
            upper = min(upper, 1.0)
            guard upper - lower > KernelTolerance.parametric else { return nil }
            return (lower, upper)
        case .ray:
            if extend { return (-.infinity, .infinity) }
            guard let chunk, chunk.1 > chunk.0 else { return nil }
            return (max(chunk.0, 0.0), chunk.1)
        case .xline:
            return (-.infinity, .infinity)
        case .polySegment(let seg):
            switch seg.geometry {
            case .line(let l):
                return activeSeedInterval(for: .line(l), seedT: seedT, chunk: chunk, extend: extend)
            case .arc(let a):
                return activeSeedInterval(for: .arc(a), seedT: seedT, chunk: chunk, extend: extend)
            }
        }
    }

    /// Local Newton field for one chord seed. Both operands are translated by
    /// the seed point and normalized by the active-interval size, so residual
    /// evaluation is independent of world offset and entity extent.
    struct NormalizedSeedField {
        let curveA: Curve2d
        let curveB: Curve2d
        let origin: Point2d
        let scale: Double
    }

    static func normalizedSeedField(
        curveA: Curve2d,
        intervalA: (Double, Double),
        seedTA: Double,
        curveB: Curve2d,
        intervalB: (Double, Double),
        seedTB: Double,
        seedPoint: Point2d
    ) -> NormalizedSeedField? {
        let localA = translatedCurve(curveA, by: seedPoint)
        let localB = translatedCurve(curveB, by: seedPoint)
        func representativeExtent(_ curve: Curve2d, seedT: Double, bounds: (Double, Double)) -> Double? {
            if bounds.0.isFinite && bounds.1.isFinite {
                let extent = CurveEval.pointAt(curve, t: bounds.1).distance(to: CurveEval.pointAt(curve, t: bounds.0))
                return extent.isFinite ? extent : nil
            }
            // Unbounded extended targets still need a finite scale. Sample the
            // seed neighborhood rather than an infinite interval.
            let neighborhood = 1e-3
            let extent = CurveEval.pointAt(curve, t: seedT + neighborhood)
                .distance(to: CurveEval.pointAt(curve, t: seedT - neighborhood))
            return extent.isFinite ? extent : nil
        }
        guard let extentA = representativeExtent(localA, seedT: seedTA, bounds: intervalA),
              let extentB = representativeExtent(localB, seedT: seedTB, bounds: intervalB) else { return nil }
        return NormalizedSeedField(curveA: localA, curveB: localB, origin: seedPoint,
                                   scale: max(1.0, extentA, extentB))
    }

    static func normalizedSeedPoint(_ field: NormalizedSeedField, curveIsA: Bool, t: Double) -> Vec2d {
        let point = CurveEval.pointAt(curveIsA ? field.curveA : field.curveB, t: t)
        return Vec2d(x: (point.x - field.origin.x) / field.scale,
                     y: (point.y - field.origin.y) / field.scale)
    }

    static func normalizedSeedDerivative(
        _ field: NormalizedSeedField,
        curveIsA: Bool,
        t: Double,
        bounds: (Double, Double)
    ) -> Vec2d? {
        // Central difference in seed-normalized coordinates. The active extent
        // normalization keeps this accurate for both tiny and huge operands.
        let h = 1e-5
        let lower = bounds.0.isFinite ? max(bounds.0, t - h) : t - h
        let upper = bounds.1.isFinite ? min(bounds.1, t + h) : t + h
        guard upper > lower else { return nil }
        let delta = normalizedSeedPoint(field, curveIsA: curveIsA, t: upper) -
            normalizedSeedPoint(field, curveIsA: curveIsA, t: lower)
        return delta * (1.0 / (upper - lower))
    }

    /// Coupled Gauss-Newton polish for one chord seed. Acceptance is on the
    /// seed-frame spatial residual, never on parameter motion, and singular or
    /// shallow-angle configurations fall back to damped Cauchy steps.
    static func polishSeedHit(
        curveA: Curve2d,
        intervalA: (Double, Double),
        seedTA: Double,
        curveB: Curve2d,
        intervalB: (Double, Double),
        seedTB: Double,
        seedPoint: Point2d,
        tolerance: Double
    ) -> (tA: Double, tB: Double, residual: Double)? {
        guard let field = normalizedSeedField(curveA: curveA, intervalA: intervalA, seedTA: seedTA,
                                              curveB: curveB, intervalB: intervalB, seedTB: seedTB,
                                              seedPoint: seedPoint) else { return nil }
        let normalizedTolerance = tolerance / field.scale
        var tA = min(max(seedTA, intervalA.0.isFinite ? intervalA.0 : seedTA),
                     intervalA.1.isFinite ? intervalA.1 : seedTA)
        var tB = min(max(seedTB, intervalB.0.isFinite ? intervalB.0 : seedTB),
                     intervalB.1.isFinite ? intervalB.1 : seedTB)
        for _ in 0..<64 {
            let pA = normalizedSeedPoint(field, curveIsA: true, t: tA)
            let pB = normalizedSeedPoint(field, curveIsA: false, t: tB)
            let residualVector = pA - pB
            let residual = residualVector.length
            if residual <= normalizedTolerance {
                return (tA, tB, residual * field.scale)
            }
            guard let jA = normalizedSeedDerivative(field, curveIsA: true, t: tA, bounds: intervalA),
                  let jB = normalizedSeedDerivative(field, curveIsA: false, t: tB, bounds: intervalB),
                  jA.length.isFinite, jB.length.isFinite else { return nil }
            let j2 = Vec2d(x: -jB.x, y: -jB.y)
            let determinant = jA.x * j2.y - jA.y * j2.x
            let sine = abs(determinant) / max(jA.length * jB.length, Double.leastNonzeroMagnitude)
            var step: Vec2d?
            if sine > 1e-6 {
                let rhs = Vec2d(x: -residualVector.x, y: -residualVector.y)
                step = Vec2d(
                    x: (rhs.x * j2.y - rhs.y * j2.x) / determinant,
                    y: (jA.x * rhs.y - jA.y * rhs.x) / determinant)
            } else {
                // Damped Cauchy step for singular/tangent configurations.
                let gradient = Vec2d(x: jA.dot(residualVector), y: j2.dot(residualVector))
                let gradientNormSquared = gradient.lengthSquared
                guard gradientNormSquared > 0 else { return nil }
                let curvature = jA.lengthSquared * gradient.x * gradient.x +
                    2.0 * jA.dot(j2) * gradient.x * gradient.y +
                    j2.lengthSquared * gradient.y * gradient.y
                guard curvature > 0 else { return nil }
                let alpha = gradientNormSquared / curvature
                step = Vec2d(x: -gradient.x * alpha, y: -gradient.y * alpha)
            }
            func search(_ proposed: Vec2d, fromA: Double, fromB: Double, residual: Double) -> (Double, Double)? {
                guard proposed.x.isFinite, proposed.y.isFinite else { return nil }
                var scaled = proposed
                let maxStep = 0.5 * max(
                    intervalA.1.isFinite && intervalA.0.isFinite ? intervalA.1 - intervalA.0 : 1.0,
                    intervalB.1.isFinite && intervalB.0.isFinite ? intervalB.1 - intervalB.0 : 1.0,
                    1e-9)
                let stepLength = scaled.length
                if stepLength > maxStep { scaled = scaled * (maxStep / stepLength) }
                var alpha = 1.0
                for _ in 0..<32 {
                    var nextA = fromA + scaled.x * alpha
                    var nextB = fromB + scaled.y * alpha
                    if intervalA.0.isFinite { nextA = max(nextA, intervalA.0) }
                    if intervalA.1.isFinite { nextA = min(nextA, intervalA.1) }
                    if intervalB.0.isFinite { nextB = max(nextB, intervalB.0) }
                    if intervalB.1.isFinite { nextB = min(nextB, intervalB.1) }
                    let nextAPoint = normalizedSeedPoint(field, curveIsA: true, t: nextA)
                    let nextBPoint = normalizedSeedPoint(field, curveIsA: false, t: nextB)
                    let nextResidual = (nextAPoint - nextBPoint).length
                    if nextResidual < residual * (1.0 - 1e-4 * alpha) { return (nextA, nextB) }
                    alpha *= 0.5
                    if alpha < 1e-8 { break }
                }
                return nil
            }
            var accepted: (Double, Double)?
            if let newton = step { accepted = search(newton, fromA: tA, fromB: tB, residual: residual) }
            if accepted == nil {
                let gradient = Vec2d(x: jA.dot(residualVector), y: j2.dot(residualVector))
                let gradientNormSquared = gradient.lengthSquared
                if gradientNormSquared > 0 {
                    let curvature = jA.lengthSquared * gradient.x * gradient.x +
                        2.0 * jA.dot(j2) * gradient.x * gradient.y +
                        j2.lengthSquared * gradient.y * gradient.y
                    if curvature > 0 {
                        let alpha = gradientNormSquared / curvature
                        accepted = search(Vec2d(x: -gradient.x * alpha, y: -gradient.y * alpha),
                                          fromA: tA, fromB: tB, residual: residual)
                    }
                }
            }
            guard let (nextA, nextB) = accepted else { return nil }
            tA = nextA
            tB = nextB
        }
        return nil
    }

    // MARK: - Entry point

    /// Unified intersection of any two curves.
    /// extendA/extendB allow the solution off the bounded span (used by
    /// FILLET/EXTEND); otherwise hits are clamped to [0, 1] within tolerance.
    public static func intersect(
        _ curveA: Curve2d,
        _ curveB: Curve2d,
        extendA: Bool = false,
        extendB: Bool = false,
        tolerance: Double = KernelTolerance.linear
    ) -> [CurveIntersection2d] {
        // Unwrap polyline segments to their exact analytical primitive.
        if case .polySegment(let segA) = curveA {
            let innerA: Curve2d = {
                switch segA.geometry {
                case .line(let l): return .line(l)
                case .arc(let a): return .arc(a)
                }
            }()
            return intersect(innerA, curveB, extendA: extendA, extendB: extendB, tolerance: tolerance)
        }
        if case .polySegment(let segB) = curveB {
            let innerB: Curve2d = {
                switch segB.geometry {
                case .line(let l): return .line(l)
                case .arc(let a): return .arc(a)
                }
            }()
            return intersect(curveA, innerB, extendA: extendA, extendB: extendB, tolerance: tolerance)
        }

        // Circles are full-sweep arcs; paramAtPoint on a full circle always
        // lands in [0, 1], so span clamping passes naturally.
        if case .circle(let cA) = curveA {
            return intersect(.arc(cA.toArc2d()), curveB, extendA: false, extendB: extendB, tolerance: tolerance)
        }
        if case .circle(let cB) = curveB {
            return intersect(curveA, .arc(cB.toArc2d()), extendA: extendA, extendB: false, tolerance: tolerance)
        }

        switch (curveA, curveB) {
        case (.line(let lA), .line(let lB)):
            return intersectLineLine(lA, lB, extendA: extendA, extendB: extendB, tolerance: tolerance)
        case (.line(let l), .ray(let r)):
            return intersectLineLikeLine(l.start, l.end, lineDomain: .segment(extend: extendA),
                                         r.origin, r.origin + (r.direction * 1.0), lineDomain: .ray(extend: extendB),
                                         tolerance: tolerance, refOrigin: referenceOrigin(curveA, curveB))
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramA, paramB: $0.paramB) }
        case (.ray, .line):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.line(let l), .xline(let x)):
            return intersectLineLikeLine(l.start, l.end, lineDomain: .segment(extend: extendA),
                                         x.origin, x.origin + (x.direction * 1.0), lineDomain: .infinite,
                                         tolerance: tolerance, refOrigin: referenceOrigin(curveA, curveB))
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramA, paramB: $0.paramB) }
        case (.xline, .line):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ray(let rA), .ray(let rB)):
            return intersectLineLikeLine(rA.origin, rA.origin + (rA.direction * 1.0), lineDomain: .ray(extend: extendA),
                                         rB.origin, rB.origin + (rB.direction * 1.0), lineDomain: .ray(extend: extendB),
                                         tolerance: tolerance, refOrigin: referenceOrigin(curveA, curveB))
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramA, paramB: $0.paramB) }
        case (.xline(let xA), .xline(let xB)):
            return intersectLineLikeLine(xA.origin, xA.origin + (xA.direction * 1.0), lineDomain: .infinite,
                                         xB.origin, xB.origin + (xB.direction * 1.0), lineDomain: .infinite,
                                         tolerance: tolerance, refOrigin: referenceOrigin(curveA, curveB))
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramA, paramB: $0.paramB) }
        case (.ray(let r), .xline(let x)):
            return intersectLineLikeLine(r.origin, r.origin + (r.direction * 1.0), lineDomain: .ray(extend: extendA),
                                         x.origin, x.origin + (x.direction * 1.0), lineDomain: .infinite,
                                         tolerance: tolerance, refOrigin: referenceOrigin(curveA, curveB))
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramA, paramB: $0.paramB) }
        case (.xline, .ray):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }

        case (.line(let line), .arc(let arc)):
            return intersectLineArc(line, arc, extendLine: extendA, extendArc: extendB, tolerance: tolerance)
        case (.arc(let arc), .line(let line)):
            return intersectLineArc(line, arc, extendLine: extendB, extendArc: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ray(let r), .arc(let arc)):
            return intersectRayArc(ray: r, arc: arc, extendRay: extendA, extendArc: extendB, tolerance: tolerance)
        case (.arc(let arc), .ray(let r)):
            return intersectRayArc(ray: r, arc: arc, extendRay: extendB, extendArc: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.xline(let x), .arc(let arc)):
            return intersectRayArc(ray: Ray2d(origin: x.origin, direction: x.direction), arc: arc,
                                   extendRay: true, extendArc: extendB, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.arc, .xline):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }

        case (.arc(let arcA), .arc(let arcB)):
            return intersectArcArc(arcA, arcB, extendA: extendA, extendB: extendB, tolerance: tolerance)

        case (.line(let line), .ellipse(let e)):
            return intersectLineEllipse(line: line, extendLine: extendA, ellipse: e, extendEllipse: extendB, tolerance: tolerance)
        case (.ellipse(let e), .line(let line)):
            return intersectLineEllipse(line: line, extendLine: extendB, ellipse: e, extendEllipse: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ellipse(let eA), .ellipse(let eB)):
            return intersectEllipseEllipse(eA, eB, extendA: extendA, extendB: extendB, tolerance: tolerance)
        case (.arc(let arc), .ellipse(let e)):
            return intersectArcEllipse(arc: arc, extendArc: extendA, ellipse: e, extendEllipse: extendB, tolerance: tolerance)
        case (.ellipse(let e), .arc(let arc)):
            return intersectArcEllipse(arc: arc, extendArc: extendB, ellipse: e, extendEllipse: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ray(let r), .ellipse(let e)):
            return intersectRayEllipse(ray: r, extendRay: extendA, ellipse: e, extendEllipse: extendB, tolerance: tolerance)
        case (.ellipse(let e), .ray(let r)):
            return intersectRayEllipse(ray: r, extendRay: extendB, ellipse: e, extendEllipse: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.xline(let x), .ellipse(let e)):
            return intersectRayEllipse(ray: Ray2d(origin: x.origin, direction: x.direction), extendRay: true, ellipse: e, extendEllipse: extendB, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ellipse, .xline):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }

        case (.line(let line), .spline(let s)):
            return intersectLineSpline(line: line, extendLine: extendA, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
        case (.spline(let s), .line(let line)):
            return intersectLineSpline(line: line, extendLine: extendB, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ray(let r), .spline(let s)):
            return intersectRaySpline(ray: r, extendRay: extendA, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
        case (.spline(let s), .ray(let r)):
            return intersectRaySpline(ray: r, extendRay: extendB, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.xline(let x), .spline(let s)):
            return intersectRaySpline(ray: Ray2d(origin: x.origin, direction: x.direction), extendRay: true, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.spline, .xline):
            return intersect(curveB, curveA, extendA: extendB, extendB: extendA, tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.arc(let arc), .spline(let s)):
            return intersectAnalyticSpline(analytic: .arc(arc), extendAnalytic: extendA, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
        case (.spline(let s), .arc(let arc)):
            return intersectAnalyticSpline(analytic: .arc(arc), extendAnalytic: extendB, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.ellipse(let e), .spline(let s)):
            return intersectAnalyticSpline(analytic: .ellipse(e), extendAnalytic: extendA, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
        case (.spline(let s), .ellipse(let e)):
            return intersectAnalyticSpline(analytic: .ellipse(e), extendAnalytic: extendB, spline: s, refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)
                .map { CurveIntersection2d(point: $0.point, paramA: $0.paramB, paramB: $0.paramA) }
        case (.spline(let sA), .spline(let sB)):
            return intersectSplineSpline(sA, sB, extendA: extendA, extendB: extendB,
                                         refOrigin: broadSeedOrigin(curveA, curveB), tolerance: tolerance)

        default:
            return []
        }
    }

    // MARK: - Line-like domains

    enum LineDomain {
        case segment(extend: Bool)
        case ray(extend: Bool)
        case infinite

        func isValid(_ t: Double, tolerance: Double, scale: Double) -> Bool {
            let tol = tolerance / max(scale, tolerance)
            switch self {
            case .segment(let extend): return extend || (t >= -tol && t <= 1.0 + tol)
            case .ray(let extend): return extend || t >= -tol
            case .infinite: return true
            }
        }

        func clamped(_ t: Double) -> Double {
            switch self {
            case .segment(let extend): return extend ? t : min(max(t, 0.0), 1.0)
            case .ray(let extend): return extend ? t : max(t, 0.0)
            case .infinite: return t
            }
        }
    }

    static func intersectLineLikeLine(
        _ a0: Point2d, _ a1: Point2d, lineDomain domA: LineDomain,
        _ b0: Point2d, _ b1: Point2d, lineDomain domB: LineDomain,
        tolerance: Double, refOrigin: Point2d
    ) -> [CurveIntersection2d] {
        // Shift to local frame.
        let A0 = a0 - refOrigin, A1 = a1 - refOrigin
        let B0 = b0 - refOrigin, B1 = b1 - refOrigin
        let r = A1 - A0
        let s = B1 - B0
        let denom = r.cross(s)
        let rLen = r.length, sLen = s.length
        guard rLen > tolerance, sLen > tolerance else { return [] }
        guard abs(denom) > KernelTolerance.parametric * rLen * sLen else { return [] }
        let qp = B0 - A0
        let t = qp.cross(s) / denom
        let u = qp.cross(r) / denom
        guard domA.isValid(t, tolerance: tolerance, scale: rLen),
              domB.isValid(u, tolerance: tolerance, scale: sLen) else { return [] }
        let cA = domA.clamped(t), cB = domB.clamped(u)
        let pt = a0 + ((a1 - a0) * cA)
        return [CurveIntersection2d(point: pt, paramA: cA, paramB: cB)]
    }

    // MARK: - Analytical Line-Line solver (local-frame shifted)

    public static func intersectLineLine(
        _ a: LineSeg2d,
        _ b: LineSeg2d,
        extendA: Bool,
        extendB: Bool,
        tolerance: Double = KernelTolerance.linear
    ) -> [CurveIntersection2d] {
        let ref = Point2d(x: 0.25 * (a.start.x + a.end.x + b.start.x + b.end.x),
                          y: 0.25 * (a.start.y + a.end.y + b.start.y + b.end.y))
        return intersectLineLikeLine(a.start, a.end, lineDomain: .segment(extend: extendA),
                                     b.start, b.end, lineDomain: .segment(extend: extendB),
                                     tolerance: tolerance, refOrigin: ref)
    }

    // MARK: - Analytical Line-Arc solver (local-frame shifted)

    public static func intersectLineArc(
        _ line: LineSeg2d,
        _ arc: Arc2d,
        extendLine: Bool,
        extendArc: Bool,
        tolerance: Double = KernelTolerance.linear
    ) -> [CurveIntersection2d] {
        // Local frame at arc center: eliminates cancellation for large coords.
        let ox = arc.center.x, oy = arc.center.y
        let sx = line.start.x - ox, sy = line.start.y - oy
        let ex = line.end.x - ox, ey = line.end.y - oy
        let dx = ex - sx, dy = ey - sy
        let lenSq = dx * dx + dy * dy
        let len = sqrt(lenSq)
        guard len > tolerance, arc.radius > tolerance else { return [] }

        let aCoeff = lenSq
        let bCoeff = 2.0 * (sx * dx + sy * dy)
        let cCoeff = sx * sx + sy * sy - arc.radius * arc.radius

        // Compensated discriminant: tiny negatives within tolerance snap to
        // tangent (single root) instead of missing.
        var disc = bCoeff * bCoeff - 4.0 * aCoeff * cCoeff
        let discTol = 4.0 * aCoeff * tolerance * arc.radius
        if disc < -discTol { return [] }
        if disc < 0 { disc = 0 }

        let sqrtDisc = sqrt(disc)
        let tCandidates: [Double]
        if sqrtDisc <= KernelTolerance.parametric * len {
            tCandidates = [-bCoeff / (2.0 * aCoeff)]
        } else {
            tCandidates = [(-bCoeff - sqrtDisc) / (2.0 * aCoeff),
                           (-bCoeff + sqrtDisc) / (2.0 * aCoeff)]
        }

        let tTol = tolerance / len
        let arcLen = max(arc.radius * abs(arc.sweep), tolerance)
        let uTol = tolerance / arcLen
        var results: [CurveIntersection2d] = []
        for t in tCandidates {
            if !extendLine && (t < -tTol || t > 1.0 + tTol) { continue }
            let finalT = extendLine ? t : min(max(t, 0.0), 1.0)
            let px = line.start.x + (line.end.x - line.start.x) * finalT
            let py = line.start.y + (line.end.y - line.start.y) * finalT
            let pt = Point2d(x: px, y: py)
            let u = CurveEval.paramAtPoint(.arc(arc), point: pt)
            if !extendArc && (u < -uTol || u > 1.0 + uTol) { continue }
            let finalU = extendArc ? u : min(max(u, 0.0), 1.0)
            results.append(CurveIntersection2d(point: pt, paramA: finalT, paramB: finalU))
        }
        return results
    }

    static func intersectRayArc(
        ray: Ray2d, arc: Arc2d, extendRay: Bool, extendArc: Bool, tolerance: Double
    ) -> [CurveIntersection2d] {
        // Long-segment proxy: ray parameter t maps to segment t in [0,1]
        // over length L = 2 * (|origin-center| + radius + 1).
        let distOC = ray.origin.distance(to: arc.center)
        let L = 2.0 * (distOC + arc.radius + 1.0)
        let seg = LineSeg2d(start: ray.origin, end: ray.origin + (ray.direction * L))
        let hits = intersectLineArc(seg, arc, extendLine: false, extendArc: extendArc, tolerance: tolerance)
        return hits.compactMap { h in
            let tRay = h.paramA * L
            if !extendRay && tRay < -tolerance { return nil }
            let clamped = extendRay ? tRay : max(tRay, 0.0)
            let pt = CurveEval.pointAt(.ray(ray), t: clamped)
            // Re-derive arc param at the true ray point for clamping accuracy.
            let u = CurveEval.paramAtPoint(.arc(arc), point: pt)
            let arcLen = max(arc.radius * abs(arc.sweep), tolerance)
            let uTol = tolerance / arcLen
            if !extendArc && (u < -uTol || u > 1.0 + uTol) { return nil }
            return CurveIntersection2d(point: pt, paramA: clamped, paramB: extendArc ? u : min(max(u, 0.0), 1.0))
        }
    }

    // MARK: - Analytical Arc-Arc solver (local-frame shifted)

    public static func intersectArcArc(
        _ arcA: Arc2d,
        _ arcB: Arc2d,
        extendA: Bool,
        extendB: Bool,
        tolerance: Double = KernelTolerance.linear
    ) -> [CurveIntersection2d] {
        // Work in the frame of arcA's center.
        let cx = arcB.center.x - arcA.center.x
        let cy = arcB.center.y - arcA.center.y
        let d = hypot(cx, cy)
        let r1 = arcA.radius, r2 = arcB.radius
        guard d > tolerance,
              d <= r1 + r2 + tolerance,
              d >= abs(r1 - r2) - tolerance else { return [] }

        let a = (r1 * r1 - r2 * r2 + d * d) / (2.0 * d)
        let hSq = max(0.0, r1 * r1 - a * a)
        let h = sqrt(hSq)

        let ux = cx / d, uy = cy / d
        // Mid point in arcA-centered frame; translate back at the end.
        let mx = ux * a, my = uy * a
        let candLocal: [(Double, Double)]
        if h <= tolerance {
            candLocal = [(mx, my)]
        } else {
            candLocal = [(mx + (-uy) * h, my + ux * h),
                         (mx - (-uy) * h, my - ux * h)]
        }

        let tolA = tolerance / max(r1 * abs(arcA.sweep), tolerance)
        let tolB = tolerance / max(r2 * abs(arcB.sweep), tolerance)
        var results: [CurveIntersection2d] = []
        for (lx, ly) in candLocal {
            let pt = Point2d(x: arcA.center.x + lx, y: arcA.center.y + ly)
            let tA = CurveEval.paramAtPoint(.arc(arcA), point: pt)
            let tB = CurveEval.paramAtPoint(.arc(arcB), point: pt)
            if !extendA && (tA < -tolA || tA > 1.0 + tolA) { continue }
            if !extendB && (tB < -tolB || tB > 1.0 + tolB) { continue }
            results.append(CurveIntersection2d(
                point: pt,
                paramA: extendA ? tA : min(max(tA, 0.0), 1.0),
                paramB: extendB ? tB : min(max(tB, 0.0), 1.0)))
        }
        return results
    }

    // MARK: - Ellipse solvers

    static func intersectLineEllipse(
        line: LineSeg2d, extendLine: Bool, ellipse e: Ellipse2d, extendEllipse: Bool, tolerance: Double
    ) -> [CurveIntersection2d] {
        let a = e.majorAxis.length
        guard a > tolerance else { return [] }
        let b = a * e.minorRatio
        let ux = e.majorAxis.normalized
        let uy = ux.perpCCW
        if b <= tolerance {
            // Degenerate: major-axis segment.
            let seg = LineSeg2d(start: e.center + (ux * -a), end: e.center + (ux * a))
            return intersectLineLine(line, seg, extendA: extendLine, extendB: extendEllipse, tolerance: tolerance)
        }
        // Local ellipse frame: origin at center, x along major, y along minor.
        func toLocal(_ p: Point2d) -> (Double, Double) {
            let r = p - e.center
            return (r.dot(ux), r.dot(uy))
        }
        let (x0, y0) = toLocal(line.start)
        let (x1, y1) = toLocal(line.end)
        let dx = x1 - x0, dy = y1 - y0
        let A = (dx * dx) / (a * a) + (dy * dy) / (b * b)
        let B = 2.0 * ((x0 * dx) / (a * a) + (y0 * dy) / (b * b))
        let C = (x0 * x0) / (a * a) + (y0 * y0) / (b * b) - 1.0
        guard abs(A) > 1e-24 else { return [] }
        var disc = B * B - 4.0 * A * C
        if disc < 0 {
            // Tolerance-scaled tangent snap.
            let scale = max(a, b)
            if disc < -tolerance * 4.0 * abs(A) * scale { return [] }
            disc = 0
        }
        let sq = sqrt(disc)
        let ts = disc <= 0 ? [-B / (2.0 * A)] : [(-B - sq) / (2.0 * A), (-B + sq) / (2.0 * A)]
        let len = line.length
        let tTol = tolerance / max(len, tolerance)
        let ellLen = max(.pi * (3.0 * (a + b) - sqrt((3.0 * a + b) * (a + 3.0 * b))), tolerance)
        let uTol = tolerance / ellLen
        var out: [CurveIntersection2d] = []
        for t in ts {
            if !extendLine && (t < -tTol || t > 1.0 + tTol) { continue }
            let ft = extendLine ? t : min(max(t, 0.0), 1.0)
            let pt = CurveEval.pointAt(.line(line), t: ft)
            let u = CurveEval.paramAtPoint(.ellipse(e), point: pt)
            if !extendEllipse && (u < -uTol || u > 1.0 + uTol) { continue }
            out.append(CurveIntersection2d(point: pt, paramA: ft,
                                           paramB: extendEllipse ? u : min(max(u, 0.0), 1.0)))
        }
        return out
    }

    static func intersectRayEllipse(
        ray: Ray2d, extendRay: Bool, ellipse e: Ellipse2d, extendEllipse: Bool, tolerance: Double
    ) -> [CurveIntersection2d] {
        let d = ray.origin.distance(to: e.center)
        let L = 2.0 * (d + e.majorAxis.length + 1.0)
        let seg = LineSeg2d(start: ray.origin, end: ray.origin + (ray.direction * L))
        return intersectLineEllipse(line: seg, extendLine: false, ellipse: e, extendEllipse: extendEllipse, tolerance: tolerance)
            .compactMap { h in
                let tRay = h.paramA * L
                if !extendRay && tRay < -tolerance { return nil }
                let c = extendRay ? tRay : max(tRay, 0.0)
                let pt = CurveEval.pointAt(.ray(ray), t: c)
                return CurveIntersection2d(point: pt, paramA: c, paramB: h.paramB)
            }
    }

    /// Ellipse-ellipse and arc-ellipse: subdivide the second curve to
    /// chord segments (bounded count, tolerance-scaled) and test each
    /// analytically. Deterministic; chord error ≤ 1e-7 relative.
    /// Spline subdivision scales with control-polygon length so chord
    /// error stays ~1e-6 relative: a crossing of the true curve always
    /// lies in a segment whose bbox overlaps the query strip, so
    /// bbox-gated segment tests cannot miss.
    static func splineSegments(_ s: Spline2d, maxSegments: Int = 1024) -> [LineSeg2d] {
        guard s.isValid, let (u0, u1) = SplineEval.domain(of: s) else { return [] }
        var ctrlLen = 0.0
        for i in 1..<s.controlPoints.count {
            ctrlLen += s.controlPoints[i - 1].distance(to: s.controlPoints[i])
        }
        guard ctrlLen > 1e-12 else { return [] }
        let target = max(1e-6 * ctrlLen, 1e-9)
        let n = min(maxSegments, max(32, Int(ceil(ctrlLen / target))))
        var segs: [LineSeg2d] = []
        segs.reserveCapacity(n)
        var prev = SplineEval.evaluate(s, at: u0) ?? .zero
        for i in 1...n {
            let p = SplineEval.evaluate(s, at: u0 + (u1 - u0) * Double(i) / Double(n)) ?? .zero
            segs.append(LineSeg2d(start: prev, end: p))
            prev = p
        }
        return segs
    }

    static func subdividedSegments(of curve: Curve2d, maxSegments: Int = 256) -> [LineSeg2d] {
        switch curve {
        case .ellipse(let e):
            let sweepLen = abs(e.sweep)
            let n = min(maxSegments, max(16, Int(ceil(sweepLen * 48.0))))
            var segs: [LineSeg2d] = []
            segs.reserveCapacity(n)
            var prev = CurveEval.pointAt(curve, t: 0)
            for i in 1...n {
                let p = CurveEval.pointAt(curve, t: Double(i) / Double(n))
                segs.append(LineSeg2d(start: prev, end: p))
                prev = p
            }
            return segs
        case .spline(let s):
            return splineSegments(s, maxSegments: maxSegments)
        case .arc(let a):
            let n = min(maxSegments, max(8, Int(ceil(abs(a.sweep) * 48.0))))
            var segs: [LineSeg2d] = []
            var prev = CurveEval.pointAt(curve, t: 0)
            for i in 1...n {
                let p = CurveEval.pointAt(curve, t: Double(i) / Double(n))
                segs.append(LineSeg2d(start: prev, end: p))
                prev = p
            }
            return segs
        default:
            return []
        }
    }

    static func intersectEllipseEllipse(
        _ eA: Ellipse2d, _ eB: Ellipse2d, extendA: Bool, extendB: Bool, tolerance: Double
    ) -> [CurveIntersection2d] {
        let segsB = subdividedSegments(of: .ellipse(eB))
        var out: [CurveIntersection2d] = []
        for (i, seg) in segsB.enumerated() {
            let tB = (Double(i) + 0.5) / Double(segsB.count)
            _ = tB
            let hits = intersectLineEllipse(line: seg, extendLine: true, ellipse: eA, extendEllipse: extendA, tolerance: tolerance)
            for h in hits {
                // h.paramA is on the sub-segment; map to ellipse-B param.
                let uB = (Double(i) + h.paramA) / Double(segsB.count)
                if !extendB {
                    let ellLen = max(eB.majorAxis.length * abs(eB.sweep), tolerance)
                    let tolB = tolerance / ellLen
                    if uB < -tolB || uB > 1.0 + tolB { continue }
                }
                let ptB = CurveEval.pointAt(.ellipse(eB), t: min(max(uB, 0.0), 1.0))
                // Snap point to ellipse A exactly (removes chord error on A side).
                let uA = CurveEval.paramAtPoint(.ellipse(eA), point: h.point)
                out.append(CurveIntersection2d(point: h.point, paramA: extendA ? uA : min(max(uA, 0.0), 1.0),
                                               paramB: extendB ? uB : min(max(uB, 0.0), 1.0)))
                _ = ptB
            }
        }
        return dedupe(out, tolerance: tolerance)
    }

    static func intersectArcEllipse(
        arc: Arc2d, extendArc: Bool, ellipse e: Ellipse2d, extendEllipse: Bool, tolerance: Double
    ) -> [CurveIntersection2d] {
        let segs = subdividedSegments(of: .arc(arc))
        var out: [CurveIntersection2d] = []
        for (i, seg) in segs.enumerated() {
            let hits = intersectLineEllipse(line: seg, extendLine: true, ellipse: e, extendEllipse: extendEllipse, tolerance: tolerance)
            for h in hits {
                let uA = (Double(i) + h.paramA) / Double(segs.count)
                let arcLen = max(arc.radius * abs(arc.sweep), tolerance)
                if !extendArc && (uA < -tolerance / arcLen || uA > 1.0 + tolerance / arcLen) { continue }
                let uArc = CurveEval.paramAtPoint(.arc(arc), point: h.point)
                out.append(CurveIntersection2d(point: h.point,
                                               paramA: extendArc ? uArc : min(max(uArc, 0.0), 1.0),
                                               paramB: h.paramB))
            }
        }
        return dedupe(out, tolerance: tolerance)
    }

    // MARK: - Spline intersections (recursive subdivision, AABB-rejected)

    static func intersectLineSpline(
        line: LineSeg2d, extendLine: Bool, spline s: Spline2d, refOrigin: Point2d, tolerance: Double
    ) -> [CurveIntersection2d] {
        guard s.isValid, let (u0, u1) = SplineEval.domain(of: s), u1 > u0 else { return [] }
        let lineDelta = line.end - line.start
        let lineLength = lineDelta.length
        guard lineLength > tolerance else { return [] }
        // Coarse local frame. Chord sampling and the conservative span checks
        // below use it; the final polish translates every seed separately.
        let localLine = translatedCurve(.line(line), by: refOrigin)
        let localSpline = translatedCurve(.spline(s), by: refOrigin)
        guard case let .line(lineLocal) = localLine,
              case let .spline(splineLocal) = localSpline else { return [] }
        if let controlBox = SplineEval.controlBounds(splineLocal) {
            let lineBox = BoundingBox2d(min: lineLocal.start, max: lineLocal.end)
            if !extendLine && !controlBox.expanded(by: tolerance).intersects(lineBox.expanded(by: tolerance)) {
                return []
            }
        }
        let segs = splineSegments(splineLocal)
        guard !segs.isEmpty else { return [] }
        let lineBox = BoundingBox2d(min: lineLocal.start, max: lineLocal.end)
        var out: [CurveIntersection2d] = []
        out.reserveCapacity(4)
        for (i, chord) in segs.enumerated() {
            let chunk = (Double(i) / Double(segs.count), Double(i + 1) / Double(segs.count))
            let chunkBox = splineIntervalConservativeBounds(splineLocal, from: chunk.0, to: chunk.1)
                ?? BoundingBox2d(min: chord.start, max: chord.end)
            if !extendLine && !chunkBox.expanded(by: tolerance).intersects(lineBox.expanded(by: tolerance)) {
                continue
            }
            // Chord intersections are seeds only. Endpoint validity comes from
            // the polished spline interval, not this chord box.
            let hits = intersectLineLine(lineLocal, chord, extendA: true, extendB: true, tolerance: tolerance)
            for h in hits {
                let seedSpline = (Double(i) + h.paramB) / Double(segs.count)
                guard let intervalLine = activeSeedInterval(
                    for: .line(lineLocal), seedT: h.paramA,
                    chunk: extendLine ? nil : (0.0, 1.0), extend: extendLine),
                      let intervalSpline = activeSeedInterval(
                        for: .spline(s), seedT: seedSpline, chunk: chunk, extend: false) else {
                    continue
                }
                let seedGlobal = Point2d(x: h.point.x + refOrigin.x, y: h.point.y + refOrigin.y)
                guard let polished = polishSeedHit(
                    curveA: .line(line), intervalA: intervalLine, seedTA: h.paramA,
                    curveB: .spline(s), intervalB: intervalSpline, seedTB: seedSpline,
                    seedPoint: seedGlobal, tolerance: tolerance),
                      polished.residual <= tolerance else { continue }
                if !extendLine {
                    let parameterTolerance = tolerance / max(lineLength, tolerance)
                    guard polished.tA >= -parameterTolerance && polished.tA <= 1.0 + parameterTolerance else {
                        continue
                    }
                }
                let tLine = extendLine ? polished.tA : min(max(polished.tA, 0.0), 1.0)
                let tSpline = min(max(polished.tB, 0.0), 1.0)
                let point = CurveEval.pointAt(.line(line), t: tLine)
                out.append(CurveIntersection2d(point: point, paramA: tLine, paramB: tSpline))
            }
        }
        return dedupe(out, tolerance: tolerance)
    }

    static func intersectRaySpline(
        ray: Ray2d, extendRay: Bool, spline s: Spline2d, refOrigin: Point2d, tolerance: Double
    ) -> [CurveIntersection2d] {
        guard let box = SplineEval.controlBounds(s) else { return [] }
        let d = ray.origin.distance(to: Point2d(x: 0.5 * (box.min.x + box.max.x), y: 0.5 * (box.min.y + box.max.y)))
        let L = 2.0 * (d + 1.0)
        let seg = LineSeg2d(start: ray.origin, end: ray.origin + (ray.direction * L))
        return intersectLineSpline(line: seg, extendLine: false, spline: s, refOrigin: refOrigin, tolerance: tolerance)
            .compactMap { h in
                let tRay = h.paramA * L
                if !extendRay && tRay < -tolerance { return nil }
                let c = extendRay ? tRay : max(tRay, 0.0)
                return CurveIntersection2d(point: CurveEval.pointAt(.ray(ray), t: c), paramA: c, paramB: h.paramB)
            }
    }

    /// Analytic curve (arc/ellipse) vs spline: subdivide spline to segments,
    /// test each against the exact analytic curve, then polish the survivors.
    /// Outputs are always ordered analytic-first and spline-second.
    static func intersectAnalyticSpline(
        analytic: Curve2d, extendAnalytic: Bool, spline s: Spline2d, refOrigin: Point2d, tolerance: Double
    ) -> [CurveIntersection2d] {
        guard s.isValid, SplineEval.domain(of: s) != nil else { return [] }
        let localAnalytic = translatedCurve(analytic, by: refOrigin)
        let localSpline = translatedCurve(.spline(s), by: refOrigin)
        guard case let .spline(splineLocal) = localSpline else { return [] }
        if let controlBox = SplineEval.controlBounds(splineLocal),
           let analyticBox = conservativeBounds(localAnalytic)?.expanded(by: tolerance),
           !extendAnalytic,
           !controlBox.expanded(by: tolerance).intersects(analyticBox) { return [] }
        let segs = splineSegments(splineLocal)
        let analyticChunks = subdividedSegments(of: localAnalytic)
        guard !segs.isEmpty else { return [] }
        let analyticCount = max(analyticChunks.count, 1)
        var out: [CurveIntersection2d] = []
        for (i, chord) in segs.enumerated() {
            let splineChunk = (Double(i) / Double(segs.count), Double(i + 1) / Double(segs.count))
            let splineBox = splineIntervalConservativeBounds(splineLocal, from: splineChunk.0, to: splineChunk.1)
                ?? BoundingBox2d(min: chord.start, max: chord.end)
            if !extendAnalytic {
                guard let analyticBox = conservativeBounds(localAnalytic),
                      splineBox.expanded(by: tolerance).intersects(analyticBox.expanded(by: tolerance)) else {
                    continue
                }
            }
            let hits = intersect(.line(chord), localAnalytic, extendA: true, extendB: extendAnalytic, tolerance: tolerance)
            for h in hits {
                let seedSpline = (Double(i) + h.paramA) / Double(segs.count)
                let chunkIndex = min(max(Int(floor(h.paramB * Double(analyticCount))), 0), analyticCount - 1)
                let analyticChunk = (Double(chunkIndex) / Double(analyticCount),
                                     Double(chunkIndex + 1) / Double(analyticCount))
                guard let intervalAnalytic = activeSeedInterval(
                    for: localAnalytic, seedT: h.paramB,
                    chunk: extendAnalytic ? nil : analyticChunk, extend: extendAnalytic),
                      let intervalSpline = activeSeedInterval(
                        for: .spline(s), seedT: seedSpline, chunk: splineChunk, extend: false) else {
                    continue
                }
                let seedGlobal = Point2d(x: h.point.x + refOrigin.x, y: h.point.y + refOrigin.y)
                guard let polished = polishSeedHit(
                    curveA: analytic, intervalA: intervalAnalytic, seedTA: h.paramB,
                    curveB: .spline(s), intervalB: intervalSpline, seedTB: seedSpline,
                    seedPoint: seedGlobal, tolerance: tolerance),
                      polished.residual <= tolerance else { continue }
                let point = CurveEval.pointAt(analytic, t: polished.tA)
                out.append(CurveIntersection2d(point: point, paramA: polished.tA, paramB: polished.tB))
            }
        }
        return dedupe(out, tolerance: tolerance)
    }

    static func intersectSplineSpline(
        _ sA: Spline2d, _ sB: Spline2d, extendA: Bool, extendB: Bool, refOrigin: Point2d, tolerance: Double
    ) -> [CurveIntersection2d] {
        guard sA.isValid, sB.isValid else { return [] }
        let localA = translatedCurve(.spline(sA), by: refOrigin)
        let localB = translatedCurve(.spline(sB), by: refOrigin)
        guard case let .spline(splineA) = localA, case let .spline(splineB) = localB else { return [] }
        if let boxA = SplineEval.controlBounds(splineA), let boxB = SplineEval.controlBounds(splineB),
           !boxA.expanded(by: tolerance).intersects(boxB.expanded(by: tolerance)) { return [] }
        // Flatten both once in the coarse frame; span-hull culling keeps the
        // seed search conservative while the final polish is exact.
        let segsA = splineSegments(splineA)
        let segsB = splineSegments(splineB)
        guard !segsA.isEmpty, !segsB.isEmpty else { return [] }
        var boxesB: [BoundingBox2d] = []
        boxesB.reserveCapacity(segsB.count)
        for (j, chordB) in segsB.enumerated() {
            let chunk = (Double(j) / Double(segsB.count), Double(j + 1) / Double(segsB.count))
            boxesB.append(splineIntervalConservativeBounds(splineB, from: chunk.0, to: chunk.1)
                ?? BoundingBox2d(min: chordB.start, max: chordB.end))
        }
        var out: [CurveIntersection2d] = []
        for (i, segA) in segsA.enumerated() {
            let chunkA = (Double(i) / Double(segsA.count), Double(i + 1) / Double(segsA.count))
            let boxA = splineIntervalConservativeBounds(splineA, from: chunkA.0, to: chunkA.1)
                ?? BoundingBox2d(min: segA.start, max: segA.end)
            for (j, segB) in segsB.enumerated() {
                if !boxA.expanded(by: tolerance).intersects(boxesB[j].expanded(by: tolerance)) { continue }
                // Bounded chords generate seeds only from true chord crossings.
                // Extending every one of the N x M chord pairs produced false
                // seeds and made per-seed Newton polish pathological.
                let hits = intersectLineLine(segA, segB, extendA: extendA, extendB: extendB, tolerance: tolerance)
                for h in hits {
                    let seedA = (Double(i) + h.paramA) / Double(segsA.count)
                    let seedB = (Double(j) + h.paramB) / Double(segsB.count)
                    let chunkB = (Double(j) / Double(segsB.count), Double(j + 1) / Double(segsB.count))
                    guard let intervalA = activeSeedInterval(
                        for: .spline(sA), seedT: seedA, chunk: chunkA, extend: extendA),
                          let intervalB = activeSeedInterval(
                            for: .spline(sB), seedT: seedB, chunk: chunkB, extend: extendB) else {
                        continue
                    }
                    let seedGlobal = Point2d(x: h.point.x + refOrigin.x, y: h.point.y + refOrigin.y)
                    guard let polished = polishSeedHit(
                        curveA: .spline(sA), intervalA: intervalA, seedTA: seedA,
                        curveB: .spline(sB), intervalB: intervalB, seedTB: seedB,
                        seedPoint: seedGlobal, tolerance: tolerance),
                          polished.residual <= tolerance else { continue }
                    let point = CurveEval.pointAt(.spline(sA), t: polished.tA)
                    out.append(CurveIntersection2d(point: point, paramA: polished.tA, paramB: polished.tB))
                }
            }
        }
        return dedupe(out, tolerance: tolerance)
    }

    /// Merge hits closer than tolerance (subdivision seams produce doubles).
    static func dedupe(_ hits: [CurveIntersection2d], tolerance: Double) -> [CurveIntersection2d] {
        guard hits.count > 1 else { return hits }
        let sorted = hits.sorted { $0.paramA < $1.paramA }
        var out: [CurveIntersection2d] = []
        for h in sorted {
            if let last = out.last,
               last.point.distanceSquared(to: h.point) <= tolerance * tolerance * 4 {
                continue
            }
            out.append(h)
        }
        return out
    }
}
