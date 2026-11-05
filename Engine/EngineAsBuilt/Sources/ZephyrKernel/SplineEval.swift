import Foundation

// =========================================================================
// MARK: - SplineEval
//
// Planar NURBS evaluation for the kernel (De Boor / Piegl & Tiller).
// Same mathematics as ZephyrCore.NURBSEvaluator, operating on Point2d so
// ZephyrKernel keeps zero dependencies. Agreement between the two is
// pinned by differential tests (see ZephyrTests KernelAgreementTests and
// the bench `kernel` cases).

public enum SplineEval: Sendable {

    /// Domain of the spline: [knots[degree], knots[count]].
    @inlinable
    public static func domain(of spline: Spline2d) -> (Double, Double)? {
        guard spline.isValid else { return nil }
        let n = spline.controlPoints.count
        return (spline.knots[spline.degree], spline.knots[n])
    }

    /// Evaluate at knot value u via De Boor. Returns nil outside domain.
    public static func evaluate(_ spline: Spline2d, at u: Double) -> Point2d? {
        guard spline.isValid else { return nil }
        let n = spline.controlPoints.count
        let p = spline.degree
        let knots = spline.knots
        let uMin = knots[p]
        let uMax = knots[n]
        guard u >= uMin - 1e-12 && u <= uMax + 1e-12 else { return nil }
        let uu = min(max(u, uMin), uMax)

        // Find span: largest i with knots[i] <= uu.
        var span = p
        if uu >= uMax {
            span = n - 1
        } else {
            var low = p
            var high = n
            while high - low > 1 {
                let mid = (low + high) / 2
                if uu >= knots[mid] { low = mid } else { high = mid }
            }
            span = low
        }

        let weights = spline.weights
        var d: [(x: Double, y: Double, w: Double)] = []
        d.reserveCapacity(p + 1)
        for j in 0...p {
            let cp = spline.controlPoints[span - p + j]
            d.append((cp.x, cp.y, weights?[span - p + j] ?? 1.0))
        }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let i = span - p + j
                let denom = knots[i + p - r + 1] - knots[i]
                let alpha = denom != 0 ? (uu - knots[i]) / denom : 0.0
                d[j] = (
                    (1.0 - alpha) * d[j - 1].0 + alpha * d[j].0,
                    (1.0 - alpha) * d[j - 1].1 + alpha * d[j].1,
                    (1.0 - alpha) * d[j - 1].2 + alpha * d[j].2)
            }
        }
        let w = d[p].2
        guard abs(w) > 1e-300 else { return nil }
        return Point2d(x: d[p].0 / w, y: d[p].1 / w)
    }

    /// Uniform samples (count+1 points) across the domain.
    public static func sample(_ spline: Spline2d, count: Int) -> [Point2d] {
        guard let (u0, u1) = domain(of: spline), count > 0 else { return [] }
        var pts: [Point2d] = []
        pts.reserveCapacity(count + 1)
        for i in 0...count {
            let u = u0 + (u1 - u0) * Double(i) / Double(count)
            if let p = evaluate(spline, at: u) { pts.append(p) }
        }
        return pts
    }

    /// Control-polygon bounding box (conservative bound of the curve).
    public static func controlBounds(_ spline: Spline2d) -> BoundingBox2d? {
        guard let first = spline.controlPoints.first else { return nil }
        var box = BoundingBox2d(point: first)
        for p in spline.controlPoints.dropFirst() { box.include(p) }
        return box
    }

    /// Whether the rational weights are safe for convex-hull reasoning. Missing
    /// weights are implicitly all positive.
    public static func hasPositiveWeights(_ spline: Spline2d) -> Bool {
        guard let weights = spline.weights else { return true }
        return weights.count == spline.controlPoints.count && weights.allSatisfy { $0 > 0 }
    }

    /// Conservative bound of the active Bézier-style control polygon at `u`.
    /// This is the correct hull for broad-phase culling, unlike a chord box.
    public static func activeControlBounds(_ spline: Spline2d, at u: Double) -> BoundingBox2d? {
        guard spline.isValid, hasPositiveWeights(spline),
              let (_, _) = domain(of: spline) else { return nil }
        let knots = spline.knots
        let p = spline.degree
        let n = spline.controlPoints.count - 1
        let clamped = min(max(u, knots[p]), knots[n])
        var low = p
        var high = n
        if clamped >= knots[n] {
            low = spline.controlPoints.count - 1
        } else {
            while high - low > 1 {
                let mid = (low + high) / 2
                if clamped >= knots[mid] { low = mid } else { high = mid }
            }
        }
        let start = max(0, low - p)
        let end = min(n, low)
        guard start <= end else { return nil }
        var box = BoundingBox2d(point: spline.controlPoints[start])
        for i in (start + 1)...end { box.include(spline.controlPoints[i]) }
        return box
    }

    /// Nonzero knot interval containing `u`, in knot units. This keeps Newton-style
    /// refinement inside one smooth span instead of stepping across a knot whose
    /// multiplicity can reduce continuity or change the active control points.
    public static func nonzeroKnotSpanBounds(_ spline: Spline2d, containing u: Double) -> (Double, Double)? {
        guard spline.isValid, let (u0, u1) = domain(of: spline) else { return nil }
        let knots = spline.knots
        let p = spline.degree
        let spanEpsilon = max(1e-12, (u1 - u0) * 1e-12)
        // Knot spans run from knots[p] through knots[n], where n is the last
        // control-point index. Search by index so repeated interior knots are
        // handled explicitly rather than by numeric proximity alone.
        for i in p..<(knots.count - p - 1) {
            let lower = knots[i]
            let upper = knots[i + 1]
            guard upper - lower > spanEpsilon else { continue }
            let clippedLower = max(lower, u0)
            let clippedUpper = min(upper, u1)
            guard clippedUpper - clippedLower > spanEpsilon else { continue }
            if u >= clippedLower - spanEpsilon && u <= clippedUpper + spanEpsilon {
                return (clippedLower, clippedUpper)
            }
        }
        return nil
    }

    /// Split at knot u via Boehm insertion. Returns (left, right) halves.
    public static func split(_ spline: Spline2d, at u: Double) -> (Spline2d, Spline2d)? {
        guard spline.isValid, let (u0, u1) = domain(of: spline) else { return nil }
        guard u > u0 + 1e-12 && u < u1 - 1e-12 else { return nil }
        var knots = spline.knots
        var cps = spline.controlPoints
        var ws = spline.weights ?? Array(repeating: 1.0, count: cps.count)
        let p = spline.degree

        // Insert u until multiplicity p.
        var mult = 0
        for k in knots where abs(k - u) <= 1e-12 { mult += 1 }
        var insertCount = p - mult
        while insertCount > 0 {
            // Find span for u.
            var span = p
            let n = cps.count - 1
            var low = p
            var high = n + 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if u >= knots[mid] { low = mid } else { high = mid }
            }
            span = low
            var newCPs = cps
            var newWs = ws
            var newKnots = knots
            newKnots.insert(u, at: span + 1)
            for j in stride(from: span, through: span - p + 1, by: -1) {
                let denom = knots[j + p] - knots[j]
                let alpha = denom != 0 ? (u - knots[j]) / denom : 0.0
                let px = (1.0 - alpha) * cps[j - 1].x + alpha * cps[j].x
                let py = (1.0 - alpha) * cps[j - 1].y + alpha * cps[j].y
                let pw = (1.0 - alpha) * ws[j - 1] + alpha * ws[j]
                newCPs[j] = Point2d(x: px, y: py)
                newWs[j] = pw
            }
            cps = newCPs; ws = newWs; knots = newKnots
            insertCount -= 1
        }

        // After insertion, u has multiplicity p. Find first knot index k with knots[k]==u;
        // the curve splits at control index a = k - p.
        var k = 0
        for (i, kv) in knots.enumerated() where abs(kv - u) <= 1e-9 { k = i; break }
        let a = k - p
        guard a >= 1 && a < cps.count else { return nil }
        let lpts = Array(cps[0...a])
        let rpts = Array(cps[a...])
        let lw = Array(ws[0...a])
        let rw = Array(ws[a...])
        // Left knots: knots[0 ..< a+p+1] but last p+1 entries forced to u.
        var lk = Array(knots[0..<(a + p + 1)])
        for i in (lk.count - p - 1)..<lk.count { lk[i] = u }
        // Right knots: first p+1 entries forced to u, rest from knots[a+p+1...].
        let rkFull: [Double] = Array(repeating: u, count: p + 1) + Array(knots[(a + p + 1)...])
        guard lpts.count + p + 1 == lk.count, rpts.count + p + 1 == rkFull.count else { return nil }
        return (Spline2d(controlPoints: lpts, knots: lk, degree: p, weights: lw),
                Spline2d(controlPoints: rpts, knots: rkFull, degree: p, weights: rw))
    }
}
