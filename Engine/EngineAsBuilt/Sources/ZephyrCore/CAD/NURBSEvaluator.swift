import Foundation

// =========================================================================
// MARK: - NURBSEvaluator
//
// Standalone utility for evaluating Non-Uniform Rational B-Spline (NURBS)
// curves. Uses the Piegl & Tiller (De Boor) bottom-up algorithm for stable
// basis-function computation.
//
// This is a pure math utility extracted from DXFImporter so it can be shared
// by the DXF import pipeline, CAD rendering, selection hit-testing, snapping,
// measurement tools, and PDF export — all without coupling to DXF-specific
// types.
//
// Added: Single-point evaluation, curve-against-segment intersection finding,
// and Boehm knot-insertion subdivision for spline trimming.
// =========================================================================

// =========================================================================
// MARK: - SplineComponents
// =========================================================================

/// The three arrays that fully define a NURBS curve.
/// Returned by `subdivide()` for each half of the split.
public struct SplineComponents: Sendable {
    public let controlPoints: [Vector3]
    public let knots: [Double]
    public let weights: [Double]

    public init(controlPoints: [Vector3], knots: [Double], weights: [Double]) {
        self.controlPoints = controlPoints
        self.knots = knots
        self.weights = weights
    }
}

// =========================================================================
// MARK: - NURBSCurveComponents
// =========================================================================

/// Full NURBS curve definition including degree and rationality tracking.
/// Used by `joinSameDegree()` for spline concatenation.
/// Differs from `SplineComponents` by carrying `degree` and `isRational`.
public struct NURBSCurveComponents: Sendable {
    public let controlPoints: [Vector3]
    public let knots: [Double]
    public let degree: Int
    public let weights: [Double]
    public let isRational: Bool

    public init(controlPoints: [Vector3], knots: [Double], degree: Int, weights: [Double], isRational: Bool) {
        self.controlPoints = controlPoints
        self.knots = knots
        self.degree = degree
        self.weights = weights
        self.isRational = isRational
    }
}

// =========================================================================
// MARK: - NURBSEvaluator
// =========================================================================

public enum NURBSEvaluator {

    // =====================================================================
    // MARK: - Multi-point evaluation
    // =====================================================================

    /// Evaluates a NURBS curve using the Piegl & Tiller (De Boor) bottom-up
    /// algorithm.
    ///
    /// - Parameters:
    ///   - degree: The degree `p` of the B-spline basis functions.
    ///   - knots: The full knot vector (length = `m + 1` where `m = n + p`).
    ///   - controlPoints: The control point array.
    ///   - weights: Optional weight array for rational (NURBS) evaluation.
    ///              Defaults to all 1.0 (non-rational B-spline).
    ///   - segments: Number of evaluation segments. More segments = smoother
    ///               curve but higher vertex count.
    /// - Returns: Array of evaluated points along the curve.
    public static func evaluate(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        segments: Int = 48
    ) -> [Vector3] {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let n = controlPoints.count - 1

        // A degree-p NURBS with n+1 control points requires n+p+2 knots.
        // Reject malformed DXF splines before any indexed access.
        guard segments > 0,
              p >= 1,
              n >= p,
              knots.count == n + p + 2
        else { return [] }

        // Determine valid evaluation domain [tMin, tMax]
        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard tMax > tMin else { return [] }

        var curvePoints: [Vector3] = []

        for i in 0...segments {
            let t = tMin + (tMax - tMin) * Double(i) / Double(segments)

            guard let pt = evaluateAtInternal(
                degree: p, knots: knots,
                controlPoints: controlPoints, weights: w, at: t
            ) else { continue }

            curvePoints.append(pt)
        }

        return curvePoints
    }

    /// Knot-aware evaluation that guarantees a sample at every distinct knot
    /// boundary, including high-multiplicity internal knots (e.g. at a join
    /// point). Each knot span is subdivided into `segmentsPerSpan` steps.
    ///
    /// This prevents the renderer / hit-test / snap systems from drawing or
    /// measuring a chord across a sharp corner introduced by a join.
    ///
    /// - Parameters:
    ///   - degree: The degree `p`.
    ///   - knots: The full knot vector.
    ///   - controlPoints: The control point array.
    ///   - weights: Optional weights.
    ///   - segmentsPerSpan: Subdivisions per knot interval.
    /// - Returns: Array of evaluated points along the curve.
    public static func evaluateByKnotSpans(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        segmentsPerSpan: Int = 12
    ) -> [Vector3] {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let n = controlPoints.count - 1

        guard p >= 1,
              n >= p,
              knots.count == n + p + 2,
              w.count == controlPoints.count
        else { return [] }

        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard tMax > tMin else { return [] }

        let eps = max(1e-12, abs(tMax - tMin) * 1e-12)

        // Collect distinct knot values within the valid domain
        var breaks: [Double] = []
        for k in knots {
            if k < tMin - eps || k > tMax + eps { continue }
            let clamped = min(max(k, tMin), tMax)
            if breaks.last.map({ abs($0 - clamped) > eps }) ?? true {
                breaks.append(clamped)
            }
        }

        if breaks.isEmpty || abs(breaks[0] - tMin) > eps {
            breaks.insert(tMin, at: 0)
        }
        if abs((breaks.last ?? tMin) - tMax) > eps {
            breaks.append(tMax)
        }

        var out: [Vector3] = []
        let perSpan = max(2, segmentsPerSpan)

        for i in 0..<(breaks.count - 1) {
            let a = breaks[i]
            let b = breaks[i + 1]
            if b - a <= eps { continue }

            for j in 0...perSpan {
                if !out.isEmpty && j == 0 { continue }  // skip duplicate at span boundary
                let t = a + (b - a) * Double(j) / Double(perSpan)
                guard let pt = evaluateAtInternal(
                    degree: p,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: w,
                    at: t
                ) else { continue }

                if let last = out.last, (last - pt).magnitudeSquared < 1e-18 {
                    continue
                }

                out.append(pt)
            }
        }

        return out
    }


    /// Adaptively evaluates a NURBS curve by knot span, adding samples only
    /// where the curve is not flat enough. This avoids long spline spans being
    /// rendered as visibly polygonal fixed-parameter chords.
    public static func evaluateAdaptiveByKnotSpans(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        chordTolerance: Double = 0.01,
        maxDepth: Int = 10,
        maxSegments: Int = 4096
    ) -> [Vector3] {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let n = controlPoints.count - 1

        guard p >= 1,
              n >= p,
              knots.count == n + p + 2,
              w.count == controlPoints.count,
              maxSegments > 0
        else { return [] }

        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard tMax > tMin else { return [] }

        let eps = max(1e-12, abs(tMax - tMin) * 1e-12)
        let toleranceSq = max(chordTolerance, 1e-9) * max(chordTolerance, 1e-9)
        let depthLimit = max(1, maxDepth)
        let segmentLimit = max(2, maxSegments)

        var breaks: [Double] = []
        for k in knots {
            if k < tMin - eps || k > tMax + eps { continue }
            let clamped = min(max(k, tMin), tMax)
            if breaks.last.map({ abs($0 - clamped) > eps }) ?? true {
                breaks.append(clamped)
            }
        }
        if breaks.isEmpty || abs(breaks[0] - tMin) > eps {
            breaks.insert(tMin, at: 0)
        }
        if abs((breaks.last ?? tMin) - tMax) > eps {
            breaks.append(tMax)
        }

        func distanceSquaredFromPointToSegment(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
            let ab = b - a
            let lenSq = ab.magnitudeSquared
            guard lenSq > 1e-24 else { return (p - a).magnitudeSquared }
            let t = max(0.0, min(1.0, (p - a).dot(ab) / lenSq))
            let q = a + ab * t
            return (p - q).magnitudeSquared
        }

        var out: [Vector3] = []
        out.reserveCapacity(min(segmentLimit + 1, max(16, breaks.count * 8)))

        func appendPoint(_ pt: Vector3) {
            if let last = out.last, (last - pt).magnitudeSquared < 1e-18 { return }
            out.append(pt)
        }

        func subdivide(t0: Double, p0: Vector3, t1: Double, p1: Vector3, depth: Int) {
            if out.count >= segmentLimit {
                appendPoint(p1)
                return
            }

            let tq1 = t0 + (t1 - t0) * 0.25
            let tm = t0 + (t1 - t0) * 0.5
            let tq3 = t0 + (t1 - t0) * 0.75

            guard let q1 = evaluateAtInternal(degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tq1),
                  let mid = evaluateAtInternal(degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tm),
                  let q3 = evaluateAtInternal(degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: tq3)
            else {
                appendPoint(p1)
                return
            }

            let flatnessSq = max(
                distanceSquaredFromPointToSegment(q1, p0, p1),
                distanceSquaredFromPointToSegment(mid, p0, p1),
                distanceSquaredFromPointToSegment(q3, p0, p1)
            )

            if flatnessSq <= toleranceSq || depth >= depthLimit {
                appendPoint(p1)
                return
            }

            subdivide(t0: t0, p0: p0, t1: tm, p1: mid, depth: depth + 1)
            subdivide(t0: tm, p0: mid, t1: t1, p1: p1, depth: depth + 1)
        }

        for i in 0..<(breaks.count - 1) {
            let a = breaks[i]
            let b = breaks[i + 1]
            if b - a <= eps { continue }

            guard let p0 = evaluateAtInternal(degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: a),
                  let p1 = evaluateAtInternal(degree: p, knots: knots, controlPoints: controlPoints, weights: w, at: b)
            else { continue }

            if out.isEmpty { appendPoint(p0) }
            subdivide(t0: a, p0: p0, t1: b, p1: p1, depth: 0)

            if out.count >= segmentLimit { break }
        }

        return out
    }

    // =====================================================================
    // MARK: - Single-point evaluation
    // =====================================================================

    /// Evaluates a NURBS curve at a single parameter `t`.
    ///
    /// - Parameters:
    ///   - degree: The degree `p`.
    ///   - knots: The full knot vector.
    ///   - controlPoints: The control point array.
    ///   - weights: Optional weights.
    ///   - at: The parameter `t` to evaluate at.
    /// - Returns: The evaluated point, or nil if the curve is invalid.
    public static func evaluateAt(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        at t: Double
    ) -> Vector3? {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let n = controlPoints.count - 1

        guard p >= 1,
              n >= p,
              knots.count == n + p + 2
        else { return nil }

        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard t >= tMin && t <= tMax else { return nil }

        return evaluateAtInternal(
            degree: p, knots: knots,
            controlPoints: controlPoints, weights: w, at: t)
    }

    /// Internal single-point evaluation (assumes caller validated inputs).
    private static func evaluateAtInternal(
        degree p: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights w: [Double],
        at t: Double
    ) -> Vector3? {
        let n = controlPoints.count - 1

        // 1. Find knot span
        // At the closed upper endpoint, the span is the final control-point
        // span n. The previous <= loop advanced to n+1 and then indexed
        // controlPoints[n+1], crashing every spline sampled at its endpoint.
        let span: Int
        if t >= knots[n + 1] {
            span = n
        } else {
            var candidate = p
            while candidate < n && knots[candidate + 1] <= t {
                candidate += 1
            }
            span = candidate
        }

        // 2. Basis functions (Stable bottom-up algorithm)
        var N = [Double](repeating: 0.0, count: p + 1)
        N[0] = 1.0
        var left = [Double](repeating: 0.0, count: p + 1)
        var right = [Double](repeating: 0.0, count: p + 1)

        for j in 1...p {
            left[j] = t - knots[span + 1 - j]
            right[j] = knots[span + j] - t
            var saved = 0.0
            for r in 0..<j {
                let denom = right[r + 1] + left[j - r]
                let temp = (denom > 1e-12) ? N[r] / denom : 0.0
                N[r] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            N[j] = saved
        }

        // 3. Multiply with control points and weights
        var pt = Vector3(x: 0, y: 0, z: 0)
        var wSum = 0.0

        for j in 0...p {
            let cpIdx = span - p + j
            let weight = cpIdx < w.count ? w[cpIdx] : 1.0
            let basis = N[j] * weight

            pt.x += controlPoints[cpIdx].x * basis
            pt.y += controlPoints[cpIdx].y * basis
            pt.z += controlPoints[cpIdx].z * basis
            wSum += basis
        }

        if wSum > 1e-10 {
            return Vector3(x: pt.x / wSum, y: pt.y / wSum, z: pt.z / wSum)
        }
        return nil
    }

    // =====================================================================
    // MARK: - Intersection finding
    // =====================================================================

    /// Finds the NURBS parameter `t` where the curve intersects a finite line
    /// segment.
    ///
    /// Algorithm:
    ///   1. Evaluate the curve into a polyline (coarse search).
    ///   2. Find segments that intersect the cutting segment.
    ///   3. Refine each candidate with Newton's method (numerical derivative).
    ///   4. Return the refined parameter and point.
    ///
    /// - Parameters:
    ///   - degree: The degree `p`.
    ///   - knots: The full knot vector.
    ///   - controlPoints: The control point array.
    ///   - weights: Optional weights.
    ///   - segmentA, segmentB: Endpoints of the cutting segment (in curve's local space).
    ///   - searchSegments: Number of polyline segments for coarse search (default 48).
    ///   - refinementSteps: Maximum Newton iterations (default 8).
    /// - Returns: The intersection parameter `t` and world-space point, or nil.
    public static func findIntersectionParameters(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]?,
        segmentA: Vector3,
        segmentB: Vector3,
        searchSegments: Int = 48,
        refinementSteps: Int = 20
    ) -> [(t: Double, point: Vector3)] {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let p = degree
        let n = controlPoints.count - 1
        guard p >= 1, n >= p else { return [] }

        let m = knots.count - 1
        let tMin = knots[p]
        let tMax = knots[m - p]
        guard tMax > tMin else { return [] }

        let segDX = segmentB.x - segmentA.x
        let segDY = segmentB.y - segmentA.y
        let segLenSq = segDX * segDX + segDY * segDY
        guard segLenSq > 1e-18 else { return [] }

        // Unit normal to the infinite line (perpendicular)
        let nx = -segDY
        let ny = segDX
        let nLen = sqrt(nx * nx + ny * ny)
        let unx = nx / nLen
        let uny = ny / nLen
        let domain = tMax - tMin

        // Signed distance from a point to the infinite line through the segment
        func signedDist(_ pt: Vector3) -> Double {
            (pt.x - segmentA.x) * unx + (pt.y - segmentA.y) * uny
        }

        // Check if point lies within the finite segment bounds
        func isOnSegment(_ pt: Vector3) -> Bool {
            let projT = ((pt.x - segmentA.x) * segDX + (pt.y - segmentA.y) * segDY) / segLenSq
            return projT >= -1e-4 && projT <= 1.0 + 1e-4
        }

        // Evaluate polyline for coarse search (knot-aware to catch corners)
        let evaluated = evaluateByKnotSpans(
            degree: p, knots: knots,
            controlPoints: controlPoints, weights: w,
            segmentsPerSpan: max(2, searchSegments / 4))
        guard evaluated.count >= 2 else { return [] }
        
        var results: [(t: Double, point: Vector3)] = []

        // Coarse search: find segments that intersect
        for i in 0..<(evaluated.count - 1) {
            guard let res = CADGeometryMath.segmentSegmentIntersection(
                a: evaluated[i], b: evaluated[i + 1],
                c: segmentA, d: segmentB
            ) else { continue }

            var t = tMin + (tMax - tMin) * (Double(i) + res.t) / Double(searchSegments)
            t = max(tMin + 1e-12, min(tMax - 1e-12, t))

            // Newton refinement: find root of signedDist(C(t))
            for _ in 0..<refinementSteps {
                guard let pt = evaluateAtInternal(
                    degree: p, knots: knots,
                    controlPoints: controlPoints, weights: w, at: t
                ) else { break }

                let dist = signedDist(pt)

                // Early convergence
                if abs(dist) < 1e-12 { break }

                // Numerical derivative of signed distance
                let h = max(1e-10, 1e-6 * domain)
                let tp = min(tMax - 1e-12, t + h)
                let tm = max(tMin + 1e-12, t - h)

                guard let ptp = evaluateAtInternal(
                    degree: p, knots: knots,
                    controlPoints: controlPoints, weights: w, at: tp),
                      let ptm = evaluateAtInternal(
                    degree: p, knots: knots,
                    controlPoints: controlPoints, weights: w, at: tm)
                else { break }

                let dDist = (signedDist(ptp) - signedDist(ptm)) / (tp - tm)
                guard abs(dDist) > 1e-12 else { break }

                let dt = -dist / dDist
                // Clamp step to avoid jumping across the whole domain
                t += max(-0.5 * domain, min(0.5 * domain, dt))
                t = max(tMin + 1e-12, min(tMax - 1e-12, t))
            }

            // Verify the final point is on the segment
            guard let finalPt = evaluateAtInternal(
                degree: p, knots: knots,
                controlPoints: controlPoints, weights: w, at: t
            ) else { continue }

            if isOnSegment(finalPt) {
                // Check if we already found an intersection very close to this t
                if !results.contains(where: { abs($0.t - t) < 1e-6 }) {
                    results.append((t, finalPt))
                }
            }
        }

        return results
    }

    /// Finds the NURBS parameter `t` closest to a given point, using the
    /// polyline approximation. Used to determine which side of a cut the
    /// user clicked on.
    ///
    /// - Returns: The approximate parameter `t` in [tMin, tMax].
    public static func findClosestParameter(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]?,
        to point: Vector3,
        segments: Int = 48
    ) -> Double {
        let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        let evaluated = evaluateByKnotSpans(
            degree: degree, knots: knots,
            controlPoints: controlPoints, weights: w,
            segmentsPerSpan: max(2, segments / 4))
        guard evaluated.count >= 2 else { return knots[degree] }

        let p = degree
        let m = knots.count - 1
        let tMin = knots[p]
        let tMax = knots[m - p]

        var bestI = 0
        var bestDistSq = Double.infinity

        for (i, pt) in evaluated.enumerated() {
            let dx = pt.x - point.x
            let dy = pt.y - point.y
            let dSq = dx * dx + dy * dy
            if dSq < bestDistSq {
                bestDistSq = dSq
                bestI = i
            }
        }

        return tMin + (tMax - tMin) * Double(bestI) / Double(segments)
    }

    // =====================================================================
    // MARK: - Single knot insertion (Boehm)
    // =====================================================================

    /// Inserts a single knot at parameter `t` using one step of Boehm's algorithm.
    /// This adds exactly one control point and one knot while preserving the exact
    /// curve shape (no splitting).
    ///
    /// The algorithm converts to homogeneous coordinates, blends control points
    /// across the affected span `k-p+1 ... k`, inserts `t` into the knot vector,
    /// and converts back to Cartesian.
    ///
    /// A **knot multiplicity guard** prevents insertion when `t` already appears
    /// `p+1` or more times — inserting beyond degree multiplicity would create a
    /// C⁻¹ discontinuity (sharp kink).
    ///
    /// - Parameters:
    ///   - degree: The degree `p`.
    ///   - knots: The full knot vector (length `n + p + 2`).
    ///   - controlPoints: The control point array.
    ///   - weights: The weight array (same length as controlPoints).
    ///   - at: The insertion parameter `t`. Must be strictly inside (tMin, tMax).
    /// - Returns: A tuple `(controlPoints, knots, weights)` with one extra element
    ///   in each array, or nil on error / multiplicity limit exceeded.
    public static func insertKnot(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double],
        at t: Double
    ) -> (controlPoints: [Vector3], knots: [Double], weights: [Double])? {
        let p = degree
        let n = controlPoints.count - 1  // n+1 control points total

        guard p >= 1, n >= p,
              knots.count == n + p + 2,
              weights.count == controlPoints.count
        else { return nil }

        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard t > tMin && t < tMax else { return nil }

        // ── Knot multiplicity guard ──
        // Count how many existing knots equal t (within epsilon).
        // If multiplicity is already ≥ p+1, inserting another would violate
        // C⁻¹ continuity and create a sharp corner.
        let existingCount = knots.reduce(0) { $0 + (abs($1 - t) < 1e-12 ? 1 : 0) }
        guard existingCount < p + 1 else { return nil }

        // ── Convert to homogeneous coordinates ──
        // Pw[i] = (w_i * P_i.x, w_i * P_i.y, w_i * P_i.z, w_i)
        var Qw: [(x: Double, y: Double, z: Double, w: Double)] = []
        Qw.reserveCapacity(controlPoints.count)
        for i in 0..<controlPoints.count {
            let wi = weights[i]
            Qw.append((
                x: controlPoints[i].x * wi,
                y: controlPoints[i].y * wi,
                z: controlPoints[i].z * wi,
                w: wi
            ))
        }

        var Uk = knots  // mutable copy of the knot vector

        // ── Find knot span ──
        // We need k such that Uk[k] ≤ t < Uk[k+1].
        // Special case: if t equals Uk[k+1], use k+1 to avoid division by zero.
        var k = p
        while k < Uk.count - 1 - p && Uk[k + 1] < t {
            k += 1
        }
        // If t equals Uk[k+1], bump to next span
        while k < Uk.count - 1 - p && abs(Uk[k + 1] - t) < 1e-12 {
            k += 1
        }

        // ── One Boehm insertion step ──
        guard k < Uk.count - 1 - p else { return nil }

        var newQw: [(Double, Double, Double, Double)] = []
        newQw.reserveCapacity(Qw.count + 1)

        for i in 0...k {
            if i <= k - p {
                // Unchanged CPs (before the affected span)
                newQw.append(Qw[i])
            } else {
                // Compute alpha = (t - U[i]) / (U[i+p] - U[i])
                let denom = Uk[i + p] - Uk[i]
                guard denom > 1e-15 else { return nil }

                let alpha = (t - Uk[i]) / denom
                let r1 = 1.0 - alpha
                newQw.append((
                    x: Qw[i - 1].x * r1 + Qw[i].x * alpha,
                    y: Qw[i - 1].y * r1 + Qw[i].y * alpha,
                    z: Qw[i - 1].z * r1 + Qw[i].z * alpha,
                    w: Qw[i - 1].w * r1 + Qw[i].w * alpha
                ))
            }
        }

        // Shift remaining CPs (after the affected span)
        for i in k..<Qw.count {
            newQw.append(Qw[i])
        }

        Qw = newQw
        Uk.insert(t, at: k + 1)

        // ── Convert back from homogeneous to Cartesian ──
        var newCPs: [Vector3] = []
        var newWeights: [Double] = []
        for i in 0..<Qw.count {
            let wi = Qw[i].w
            guard wi > 1e-15 else { return nil }
            newCPs.append(Vector3(
                x: Qw[i].x / wi,
                y: Qw[i].y / wi,
                z: Qw[i].z / wi
            ))
            newWeights.append(wi)
        }

        // ── Validate result ──
        let newN = newCPs.count - 1
        guard newCPs.count == controlPoints.count + 1,
              Uk.count == knots.count + 1,
              Uk.count == newN + p + 2
        else { return nil }

        return (controlPoints: newCPs, knots: Uk, weights: newWeights)
    }

    // =====================================================================
    // MARK: - Curve subdivision (Boehm knot insertion)
    // =====================================================================

    /// Subdivides a NURBS curve at parameter `t` using Boehm's knot insertion
    /// algorithm. Returns two complete spline definitions representing the
    /// portions [tMin, t] and [t, tMax].
    ///
    /// The algorithm inserts `t` into the knot vector `p` times (where `p` is
    /// the degree), which creates a point of C⁰ continuity at `t`. The control
    /// polygon is then split at the control point that lies on the curve at `t`.
    ///
    /// - Parameters:
    ///   - degree: The degree `p`.
    ///   - knots: The full knot vector (length `n + p + 2`).
    ///   - controlPoints: The control point array.
    ///   - weights: The weight array (same length as controlPoints).
    ///   - at: The split parameter `t`. Must be strictly inside (tMin, tMax).
    /// - Returns: Two `SplineComponents` for left and right halves, or nil on error.
    public static func subdivide(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double],
        at t: Double
    ) -> (left: SplineComponents, right: SplineComponents)? {
        let p = degree
        let n = controlPoints.count - 1  // n+1 control points total

        guard p >= 1, n >= p,
              knots.count == n + p + 2,
              weights.count == controlPoints.count
        else { return nil }

        let tMin = knots[p]
        let tMax = knots[n + 1]
        guard t > tMin && t < tMax else { return nil }

        // ── Convert to homogeneous coordinates ──
        // Pw[i] = (w_i * P_i.x, w_i * P_i.y, w_i * P_i.z, w_i)
        var Qw: [(x: Double, y: Double, z: Double, w: Double)] = []
        Qw.reserveCapacity(controlPoints.count)
        for i in 0..<controlPoints.count {
            let wi = weights[i]
            Qw.append((
                x: controlPoints[i].x * wi,
                y: controlPoints[i].y * wi,
                z: controlPoints[i].z * wi,
                w: wi
            ))
        }

        var Uk = knots  // mutable copy of the knot vector

        // ── Find initial knot span ──
        // We need k such that Uk[k] ≤ t < Uk[k+1].
        // Special case: if t equals Uk[k+1], use k+1 to avoid division by zero.
        var k = p
        while k < Uk.count - 1 - p && Uk[k + 1] < t {
            k += 1
        }
        // If t equals Uk[k+1], bump to next span
        while k < Uk.count - 1 - p && abs(Uk[k + 1] - t) < 1e-12 {
            k += 1
        }

        // ── Insert knot t p times (Boehm) ──
        for _ in 0..<p {
            // Guard against degenerate spans
            guard k < Uk.count - 1 - p else { return nil }

            var newQw: [(Double, Double, Double, Double)] = []
            newQw.reserveCapacity(Qw.count + 1)

            for i in 0...k {
                if i <= k - p {
                    // Unchanged CPs
                    newQw.append(Qw[i])
                } else {
                    // Compute alpha = (t - U[i]) / (U[i+p] - U[i])
                    let denom = Uk[i + p] - Uk[i]
                    guard denom > 1e-15 else { return nil }

                    let alpha = (t - Uk[i]) / denom
                    let r1 = 1.0 - alpha
                    newQw.append((
                        x: Qw[i - 1].x * r1 + Qw[i].x * alpha,
                        y: Qw[i - 1].y * r1 + Qw[i].y * alpha,
                        z: Qw[i - 1].z * r1 + Qw[i].z * alpha,
                        w: Qw[i - 1].w * r1 + Qw[i].w * alpha
                    ))
                }
            }

            // Shift remaining CPs
            for i in k..<Qw.count {
                newQw.append(Qw[i])
            }

            Qw = newQw
            Uk.insert(t, at: k + 1)
            k += 1
        }

        // ── Find split point ──
        // After p insertions, t appears p times in Uk.
        // Find the first occurrence of t.
        var firstT = 0
        while firstT < Uk.count && abs(Uk[firstT] - t) > 1e-12 {
            firstT += 1
        }
        let lastT = firstT + p - 1

        // The control point at index (firstT - 1) lies on the curve at t.
        // We split the control polygon at that index: left gets [0..splitIdx],
        // right gets [splitIdx..end] where splitIdx = firstT - 1.
        let splitIdx = firstT - 1

        // ── Build left curve ──
        // CPs: Qw[0...splitIdx]
        // Knots: Uk[0...splitIdx] + (p+1) copies of t
        var leftCPs: [Vector3] = []
        var leftWeights: [Double] = []
        for i in 0...splitIdx {
            let wi = Qw[i].w
            guard wi > 1e-15 else { return nil }
            leftCPs.append(Vector3(x: Qw[i].x / wi,
                                    y: Qw[i].y / wi,
                                    z: Qw[i].z / wi))
            leftWeights.append(wi)
        }

        var leftKnots = Array(Uk[0...splitIdx])
        // Append p+1 copies of t so the curve terminates at t with C⁻¹ continuity
        for _ in 0...(p) {
            leftKnots.append(t)
        }

        // ── Build right curve ──
        // CPs: Qw[splitIdx...end]
        // Knots: (p+1) copies of t + Uk[lastT...end]
        var rightCPs: [Vector3] = []
        var rightWeights: [Double] = []
        for i in splitIdx..<Qw.count {
            let wi = Qw[i].w
            guard wi > 1e-15 else { return nil }
            rightCPs.append(Vector3(x: Qw[i].x / wi,
                                     y: Qw[i].y / wi,
                                     z: Qw[i].z / wi))
            rightWeights.append(wi)
        }

        var rightKnots: [Double] = []
        // Prepend p+1 copies of t
        for _ in 0...(p) {
            rightKnots.append(t)
        }
        // Append remaining knots AFTER the last copy of t.
        // We skip Uk[lastT] because it equals t — the p+1 prepended
        // copies already provide the required leading knot multiplicity.
        let tailStart = lastT + 1
        if tailStart < Uk.count {
            rightKnots.append(contentsOf: Uk[tailStart...])
        }

        // ── Validate knot vector lengths ──
        let leftN = leftCPs.count - 1
        let rightN = rightCPs.count - 1
        guard leftKnots.count == leftN + p + 2,
              rightKnots.count == rightN + p + 2
        else { return nil }

        return (
            left: SplineComponents(
                controlPoints: leftCPs,
                knots: leftKnots,
                weights: leftWeights),
            right: SplineComponents(
                controlPoints: rightCPs,
                knots: rightKnots,
                weights: rightWeights)
        )
    }

    // =====================================================================
    // MARK: - Spline Join (same-degree concatenation)
    // =====================================================================

    /// Error cases for `joinSameDegree`.
    public enum NURBSJoinError: Error, CustomStringConvertible {
        case invalidCurveA(String)
        case invalidCurveB(String)
        case differentDegrees(Int, Int)
        case noMatchingEndpoints
        case invalidWeights
        case invalidResult(String)
        case tooLarge(Int)

        public var description: String {
            switch self {
            case .invalidCurveA(let msg): return "Curve A invalid: \(msg)"
            case .invalidCurveB(let msg): return "Curve B invalid: \(msg)"
            case .differentDegrees(let da, let db): return "Cannot join splines with different degrees (\(da) vs \(db))."
            case .noMatchingEndpoints: return "No matching endpoints found."
            case .invalidWeights: return "Invalid weights (must be finite and > 0)."
            case .invalidResult(let msg): return "Join produced invalid result: \(msg)"
            case .tooLarge(let count): return "Result would have \(count) control points — too large."
            }
        }
    }

    /// Maximum allowed combined control point + knot count (sanity check for corrupted inputs).
    public static let maxJoinControlPoints = 100_000

    // MARK: Curve validation

    /// Returns `nil` on success or a `NURBSJoinError` describing the problem.
    public static func validateCurve(_ curve: NURBSCurveComponents) -> NURBSJoinError? {
        let p = curve.degree
        let cps = curve.controlPoints
        let kts = curve.knots
        let ws = curve.weights
        let n = cps.count - 1

        guard p >= 1 else {
            return .invalidCurveA("degree must be >= 1, got \(p)")
        }
        guard n >= p else {
            return .invalidCurveA("controlPoints.count (\(cps.count)) must be >= degree+1 (\(p+1))")
        }
        guard kts.count == n + p + 2 else {
            return .invalidCurveA("knots.count (\(kts.count)) != controlPoints.count + degree + 1 (\(n + p + 2))")
        }

        // Monotonicity
        for i in 0..<(kts.count - 1) {
            if kts[i] > kts[i + 1] {
                return .invalidCurveA("knots[\(i)] (\(kts[i])) > knots[\(i+1)] (\(kts[i+1]))")
            }
        }

        // Non-zero domain
        let tMin = kts[p]
        let tMax = kts[n + 1]
        guard tMax > tMin else {
            return .invalidCurveA("knot domain is zero or negative: [\(tMin), \(tMax)]")
        }

        // Clamped: first knot repeated p+1 times
        let firstKnot = kts[0]
        for i in 0...p {
            guard abs(kts[i] - firstKnot) < 1e-12 else {
                return .invalidCurveA("not clamped: knots[\(i)] = \(kts[i]) != \(firstKnot)")
            }
        }
        // Clamped: last knot repeated p+1 times
        let lastKnot = kts[kts.count - 1]
        for i in (kts.count - p - 1)..<kts.count {
            guard abs(kts[i] - lastKnot) < 1e-12 else {
                return .invalidCurveA("not clamped at end: knots[\(i)] = \(kts[i]) != \(lastKnot)")
            }
        }

        // Weights
        guard ws.count == cps.count else {
            return .invalidCurveA("weights.count (\(ws.count)) != controlPoints.count (\(cps.count))")
        }
        for (_, w) in ws.enumerated() {
            guard w.isFinite, w > 0 else {
                return .invalidWeights
            }
        }

        return nil
    }

    // MARK: Knot normalization

    /// Linearly rescale a knot vector so the domain [knots[degree], knots[cpCount]] maps to [0, 1].
    public static func normalizeKnots(_ knots: [Double], degree: Int) -> [Double] {
        let cpCount = knots.count - degree - 1
        let tMin = knots[degree]
        let tMax = knots[cpCount]
        let range = tMax - tMin
        guard range > 1e-15 else { return knots }
        return knots.map { ($0 - tMin) / range }
    }

    // MARK: Curve reversal

    /// Return a reversed copy of `curve`.
    /// Control points and weights are reversed; knots are reversed and mirrored
    /// (`maxKnot + minKnot - knotValue`) to keep monotonicity.
    public static func reversedCurve(_ curve: NURBSCurveComponents) -> NURBSCurveComponents {
        let revCPs = Array(curve.controlPoints.reversed())
        let revWeights = Array(curve.weights.reversed())
        let minKnot = curve.knots.first ?? 0
        let maxKnot = curve.knots.last ?? 1
        let revKnots = curve.knots.reversed().map { minKnot + maxKnot - $0 }
        return NURBSCurveComponents(
            controlPoints: revCPs,
            knots: revKnots,
            degree: curve.degree,
            weights: revWeights,
            isRational: curve.isRational
        )
    }

    // MARK: Weight scaling

    /// Multiply all weights by a positive scalar. Geometry is preserved because
    /// the curve is projective-invariant under uniform weight scaling.
    public static func scaledWeights(_ weights: [Double], by factor: Double) -> [Double] {
        return weights.map { $0 * factor }
    }


    // MARK: Targeted degree elevation

    /// Exact degree elevation for a single-span linear Bezier curve to degree 2.
    /// This handles the common JOIN case where an imported straight spline
    /// (degree 1, 2 CPs) needs to join a quadratic spline.
    ///
    /// Rational curves are elevated in homogeneous coordinates so the geometry
    /// is preserved exactly.
    public static func elevateLinearBezierToQuadratic(
        _ curve: NURBSCurveComponents
    ) -> NURBSCurveComponents? {
        guard curve.degree == 1,
              curve.controlPoints.count == 2,
              curve.weights.count == 2
        else { return nil }

        let p0 = curve.controlPoints[0]
        let p1 = curve.controlPoints[1]
        let w0 = curve.weights[0]
        let w1 = curve.weights[1]

        guard w0.isFinite, w1.isFinite, w0 > 0, w1 > 0 else {
            return nil
        }

        let midWeight = 0.5 * (w0 + w1)
        guard midWeight > 0, midWeight.isFinite else { return nil }

        let mid = Vector3(
            x: ((p0.x * w0) + (p1.x * w1)) * 0.5 / midWeight,
            y: ((p0.y * w0) + (p1.y * w1)) * 0.5 / midWeight,
            z: ((p0.z * w0) + (p1.z * w1)) * 0.5 / midWeight
        )

        return NURBSCurveComponents(
            controlPoints: [p0, mid, p1],
            knots: [0, 0, 0, 1, 1, 1],
            degree: 2,
            weights: [w0, midWeight, w1],
            isRational: curve.isRational
        )
    }

    public static func elevateBezierChainByOneDegree(
        _ curve: NURBSCurveComponents
    ) -> NURBSCurveComponents? {
        guard validateCurve(curve) == nil else { return nil }

        let p = curve.degree
        let q = p + 1
        let cps = curve.controlPoints
        let weights = curve.weights

        guard p >= 1, cps.count == weights.count else { return nil }

        let tMin = curve.knots[p]
        let tMax = curve.knots[cps.count]
        guard tMax > tMin else { return nil }

        var internalBreaks: [Double] = []
        var i = p + 1
        let end = curve.knots.count - p - 1
        while i < end {
            let value = curve.knots[i]
            var multiplicity = 1
            var j = i + 1
            while j < end && abs(curve.knots[j] - value) < 1e-12 {
                multiplicity += 1
                j += 1
            }

            guard value > tMin + 1e-12, value < tMax - 1e-12 else {
                i = j
                continue
            }

            guard multiplicity == p else { return nil }
            internalBreaks.append(value)
            i = j
        }

        let spanCount = internalBreaks.count + 1
        guard cps.count == spanCount * p + 1 else { return nil }

        var outCPs: [Vector3] = []
        var outWeights: [Double] = []
        outCPs.reserveCapacity(spanCount * q + 1)
        outWeights.reserveCapacity(spanCount * q + 1)

        for span in 0..<spanCount {
            let start = span * p
            var hp: [(x: Double, y: Double, z: Double, w: Double)] = []
            hp.reserveCapacity(p + 1)

            for local in 0...p {
                let idx = start + local
                let w = weights[idx]
                guard w.isFinite, w > 0 else { return nil }
                let pt = cps[idx]
                hp.append((pt.x * w, pt.y * w, pt.z * w, w))
            }

            var elevated: [(x: Double, y: Double, z: Double, w: Double)] = []
            elevated.reserveCapacity(q + 1)
            elevated.append(hp[0])

            if p >= 1 {
                for k in 1...p {
                    let alpha = Double(k) / Double(q)
                    let beta = 1.0 - alpha
                    let a = hp[k - 1]
                    let b = hp[k]
                    elevated.append((
                        a.x * alpha + b.x * beta,
                        a.y * alpha + b.y * beta,
                        a.z * alpha + b.z * beta,
                        a.w * alpha + b.w * beta
                    ))
                }
            }

            elevated.append(hp[p])

            let firstLocal = span == 0 ? 0 : 1
            for local in firstLocal..<elevated.count {
                let h = elevated[local]
                guard h.w.isFinite, h.w > 0 else { return nil }
                outCPs.append(Vector3(x: h.x / h.w, y: h.y / h.w, z: h.z / h.w))
                outWeights.append(h.w)
            }
        }

        var knots: [Double] = []
        knots.reserveCapacity(outCPs.count + q + 1)
        for _ in 0...q { knots.append(0.0) }
        if spanCount > 1 {
            for span in 1..<spanCount {
                for _ in 0..<q { knots.append(Double(span)) }
            }
        }
        for _ in 0...q { knots.append(Double(spanCount)) }

        let elevated = NURBSCurveComponents(
            controlPoints: outCPs,
            knots: normalizeKnots(knots, degree: q),
            degree: q,
            weights: outWeights,
            isRational: curve.isRational
        )

        guard validateCurve(elevated) == nil else { return nil }
        return elevated
    }

    public static func elevateBezierChain(
        _ curve: NURBSCurveComponents,
        toDegree targetDegree: Int
    ) -> NURBSCurveComponents? {
        guard targetDegree >= curve.degree else { return nil }
        if targetDegree == curve.degree { return curve }

        var work = curve
        while work.degree < targetDegree {
            guard let elevated = elevateBezierChainByOneDegree(work) else { return nil }
            work = elevated
        }
        return work
    }

    // MARK: Same-degree join

    /// Join two clamped NURBS curves at their closest pair of endpoints.
    /// Same-degree curves are concatenated directly. Degree-1 and degree-2
    /// Bezier-chain curves can be elevated exactly up to degree 3 so lines and
    /// circular arcs can join cubic splines without refitting.
    ///
    /// - Parameters:
    ///   - a: First curve.
    ///   - b: Second curve.
    ///   - matchTolerance: Maximum world-space distance to consider two endpoints "matching".
    ///   - snapTolerance: If endpoints are within this distance, snap them to exact equality.
    /// - Returns: `.success(curve)` or `.failure(error)`.
    public static func joinSameDegree(
        _ a: NURBSCurveComponents,
        _ b: NURBSCurveComponents,
        matchTolerance: Double = 0.001,
        snapTolerance: Double = 1e-9
    ) -> Result<NURBSCurveComponents, NURBSJoinError> {

        // ── Validate ──
        if let err = validateCurve(a) { return .failure(err) }
        if let err = validateCurve(b) { return .failure(err) }

        var aWork = a
        var bWork = b

        if aWork.degree != bWork.degree {
            let targetDegree = max(aWork.degree, bWork.degree)

            guard targetDegree <= 3,
                  let elevatedA = elevateBezierChain(aWork, toDegree: targetDegree),
                  let elevatedB = elevateBezierChain(bWork, toDegree: targetDegree)
            else {
                return .failure(.differentDegrees(a.degree, b.degree))
            }

            aWork = elevatedA
            bWork = elevatedB

            if let err = validateCurve(aWork) { return .failure(err) }
            if let err = validateCurve(bWork) { return .failure(err) }
        }

        guard aWork.degree == bWork.degree else {
            return .failure(.differentDegrees(a.degree, b.degree))
        }

        let p = aWork.degree
        let sA = aWork.controlPoints.first!
        let eA = aWork.controlPoints.last!
        let sB = bWork.controlPoints.first!
        let eB = bWork.controlPoints.last!

        // ── All 4 endpoint pair distances ──
        let pairs: [(dist: Double, aEnd: Int, bEnd: Int)] = [
            (eA.distance(to: sB), 1, 0),  // A.end → B.start
            (eA.distance(to: eB), 1, 1),  // A.end → B.end
            (sA.distance(to: eB), 0, 1),  // A.start → B.end
            (sA.distance(to: sB), 0, 0),  // A.start → B.start
        ]

        guard let best = pairs.min(by: { $0.dist < $1.dist }),
              best.dist <= matchTolerance else {
            return .failure(.noMatchingEndpoints)
        }

        // ── Apply reversal / order swap ──
        var first: NURBSCurveComponents
        var second: NURBSCurveComponents

        switch (best.aEnd, best.bEnd) {
        case (1, 0):  // A.end → B.start
            first = aWork; second = bWork
        case (1, 1):  // A.end → B.end → reverse B
            first = aWork; second = reversedCurve(bWork)
        case (0, 1):  // A.start → B.end → B + A
            first = bWork; second = aWork
        case (0, 0):  // A.start → B.start → reverse A + B
            first = reversedCurve(aWork); second = bWork
        default:
            return .failure(.noMatchingEndpoints)
        }

        // ── Snap join point ──
        _ = snapTolerance
        var sCPs = second.controlPoints
        sCPs[0] = first.controlPoints.last!
        second = NURBSCurveComponents(
            controlPoints: sCPs, knots: second.knots,
            degree: second.degree, weights: second.weights,
            isRational: second.isRational
        )

        // ── Scale second curve's weights so join weight matches ──
        let wFirstEnd = first.weights.last!
        let wSecondStart = second.weights.first!
        guard wSecondStart.isFinite, wSecondStart > 0 else {
            return .failure(.invalidWeights)
        }
        var secondWeights = second.weights
        if abs(wFirstEnd - wSecondStart) > 1e-12 {
            let scale = wFirstEnd / wSecondStart
            secondWeights = scaledWeights(secondWeights, by: scale)
        }

        // ── Normalize both knot vectors to [0, 1] ──
        let firstKnotsNorm = normalizeKnots(first.knots, degree: p)
        let secondKnotsNorm = normalizeKnots(second.knots, degree: p)

        // ── Merge control points ──
        var mergedCPs = first.controlPoints
        mergedCPs.append(contentsOf: second.controlPoints.dropFirst())

        // ── Merge weights ──
        var mergedWeights = first.weights
        mergedWeights.append(contentsOf: secondWeights.dropFirst())

        // ── Merge knot vectors (C0: p copies at join) ──
        // A clamped: [0(×p+1), a₁…aₖ, 1(×p+1)]  — strip the final p+1 ones
        // B clamped: [0(×p+1), b₁…bₘ, 1(×p+1)]  — strip the first p+1 zeros, add 1
        var mergedKnots: [Double] = []

        // Take firstKnotsNorm except the final (p+1) which are all 1.0
        let firstKeep = firstKnotsNorm.count - (p + 1)
        mergedKnots.append(contentsOf: firstKnotsNorm.prefix(firstKeep))

        for _ in 0..<p {
            mergedKnots.append(1.0)
        }

        // Take secondKnotsNorm except the first (p+1) which are all 0.0 (now 1.0 after shift)
        let secondKnotsShifted = secondKnotsNorm.map { $0 + 1.0 }
        let secondStart = p + 1  // skip (p+1) copies of what was 0.0, now 1.0
        mergedKnots.append(contentsOf: secondKnotsShifted[secondStart...])

        // ── Normalize merged knots back to [0, 1] ──
        let finalKnots = normalizeKnots(mergedKnots, degree: p)

        // ── Construct joined curve ──
        let joinedIsRational = first.isRational || second.isRational
        let joined = NURBSCurveComponents(
            controlPoints: mergedCPs,
            knots: finalKnots,
            degree: p,
            weights: mergedWeights,
            isRational: joinedIsRational
        )

        // ── Validate result ──
        if let err = validateCurve(joined) { return .failure(err) }

        let totalCPs = mergedCPs.count
        if totalCPs > maxJoinControlPoints {
            return .failure(.tooLarge(totalCPs))
        }

        // ── Debug verification (debug builds only) ──
        #if DEBUG
        verifyJoin(first, second, joined, degree: p)
        #endif

        return .success(joined)
    }

    #if DEBUG
    /// Sample both originals against the joined curve halves.
    /// Asserts that the joined curve is geometrically identical to A followed by B.
    private static func verifyJoin(
        _ a: NURBSCurveComponents,
        _ b: NURBSCurveComponents,
        _ joined: NURBSCurveComponents,
        degree p: Int
    ) {
        let samples = 12
        let aPts = evaluateByKnotSpans(degree: p, knots: a.knots, controlPoints: a.controlPoints, weights: a.weights, segmentsPerSpan: samples)
        let bPts = evaluateByKnotSpans(degree: p, knots: b.knots, controlPoints: b.controlPoints, weights: b.weights, segmentsPerSpan: samples)
        _ = evaluateByKnotSpans(degree: p, knots: joined.knots, controlPoints: joined.controlPoints, weights: joined.weights, segmentsPerSpan: samples)  // jPts not needed; sampling per-half below

        // Compute bounding box diagonal from control points
        var minPt = joined.controlPoints[0]
        var maxPt = joined.controlPoints[0]
        for pt in joined.controlPoints {
            minPt.x = min(minPt.x, pt.x); minPt.y = min(minPt.y, pt.y); minPt.z = min(minPt.z, pt.z)
            maxPt.x = max(maxPt.x, pt.x); maxPt.y = max(maxPt.y, pt.y); maxPt.z = max(maxPt.z, pt.z)
        }
        let diag = (maxPt - minPt).magnitude
        let tol = max(1e-8, diag * 1e-10)

        // First half of joined should match A
        for i in 0...samples {
            let t = Double(i) / Double(samples) * 0.5
            guard let jp = evaluateAtInternal(degree: p, knots: joined.knots, controlPoints: joined.controlPoints, weights: joined.weights, at: t) else { continue }
            let ap = aPts[min(i, aPts.count - 1)]
            let dist = jp.distance(to: ap)
            if dist > tol {
                print("[NURBSJoin] WARNING: debug verify A mismatch at i=\(i), dist=\(dist) > tol=\(tol)")
            }
        }

        // Second half of joined should match B
        for i in 0...samples {
            let t = 0.5 + Double(i) / Double(samples) * 0.5
            guard let jp = evaluateAtInternal(degree: p, knots: joined.knots, controlPoints: joined.controlPoints, weights: joined.weights, at: t) else { continue }
            let bp = bPts[min(i, bPts.count - 1)]
            let dist = jp.distance(to: bp)
            if dist > tol {
                print("[NURBSJoin] WARNING: debug verify B mismatch at i=\(i), dist=\(dist) > tol=\(tol)")
            }
        }
    }
    #endif
}
