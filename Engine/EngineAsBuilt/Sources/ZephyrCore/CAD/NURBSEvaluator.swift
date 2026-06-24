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

        // Evaluate polyline for coarse search
        let evaluated = evaluate(
            degree: p, knots: knots,
            controlPoints: controlPoints, weights: w,
            segments: searchSegments)
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
        let evaluated = evaluate(
            degree: degree, knots: knots,
            controlPoints: controlPoints, weights: w,
            segments: segments)
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
}
