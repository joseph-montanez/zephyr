import Foundation

// =========================================================================
// MARK: - CurveScreenTessellation
//
// Screen-space curve tessellation policy. The renderer converts camera zoom
// and pixel scale into world tolerance at the promotion zoom of the active
// 2x zoom band, so rendered sagitta cannot exceed the pixel budget anywhere
// inside that band. Curve-specific subdivision lives with the curve helpers;
// this type owns only the zoom, tolerance, hysteresis, and segment-count math.
// =========================================================================

public enum CurveScreenTessellation: Sendable {
    /// Rendered sagitta budget at the design zoom, in pixels.
    public static let targetPixelError = 0.25
    /// Off-screen curve spans may use this multiple of the in-viewport budget.
    public static let offscreenToleranceMultiplier = 16.0
    /// Zoom-band hysteresis. Promotion is immediate at a band boundary while
    /// demotion waits until zoom falls this far below the lower edge.
    public static let bandHysteresis = 1.15
    /// Default per-curve in-viewport subdivision budget.
    public static let defaultMaximumSegments = 65_536
    /// Default working-set budget shared by all curve primitives in one LOD
    /// refresh. Per-curve budgets are derived from this total so a drawing
    /// with many curves cannot turn one zoom-band change into unbounded work.
    public static let defaultTotalMaximumSegments = 262_144

    /// 2x zoom band containing a finite positive pixels-per-unit value.
    public static func zoomBand(for pixelsPerUnit: Double, referencePixelsPerUnit: Double = 1.0) -> Int {
        guard pixelsPerUnit.isFinite, referencePixelsPerUnit.isFinite,
              pixelsPerUnit > 0, referencePixelsPerUnit > 0 else { return 0 }
        return Int(floor(log2(pixelsPerUnit / referencePixelsPerUnit)))
    }

    /// Promotion zoom served by a band. Using the upper bound keeps the pixel
    /// budget valid for every smaller zoom in the same band.
    public static func designZoom(
        for band: Int,
        referencePixelsPerUnit: Double = 1.0
    ) -> Double {
        referencePixelsPerUnit * pow(2.0, Double(band + 1))
    }

    /// Sticky band selection. A finer band is selected immediately at the
    /// promotion zoom; a coarser band waits for the hysteresis margin.
    public static func zoomBand(
        for pixelsPerUnit: Double,
        currentBand: Int,
        referencePixelsPerUnit: Double = 1.0
    ) -> Int {
        let nominal = zoomBand(for: pixelsPerUnit, referencePixelsPerUnit: referencePixelsPerUnit)
        if nominal > currentBand { return nominal }
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return currentBand }
        let lowerEdge = referencePixelsPerUnit * pow(2.0, Double(currentBand))
        if pixelsPerUnit * bandHysteresis <= lowerEdge { return nominal }
        return currentBand
    }

    /// World-space sagitta budget for a pixels-per-unit value.
    public static func worldTolerance(
        pixelsPerUnit: Double,
        targetPixels: Double = targetPixelError,
        referencePixelsPerUnit: Double = 1.0
    ) -> Double {
        let band = zoomBand(for: pixelsPerUnit, referencePixelsPerUnit: referencePixelsPerUnit)
        let design = designZoom(for: band, referencePixelsPerUnit: referencePixelsPerUnit)
        guard design.isFinite, design > 0 else { return max(0.001, targetPixels) }
        return max(1e-9, targetPixels / design)
    }

    /// Minimum uniform segments for a circular span of radius and sweep.
    public static func circularSegmentCount(
        radius: Double,
        sweep: Double,
        tolerance: Double
    ) -> Int {
        guard radius.isFinite, sweep.isFinite, tolerance.isFinite,
              radius > 0, sweep != 0, tolerance > 0 else { return 0 }
        guard tolerance < 2.0 * radius else { return 2 }
        let relative = tolerance / radius
        guard relative > 1e-12 else { return 8_000_000 }
        let step = 2.0 * acos(max(-1.0, min(1.0, 1.0 - relative)))
        guard step > 0 else { return 8_000_000 }
        let needed = abs(sweep) / step
        guard needed.isFinite else { return 8_000_000 }
        if needed >= 8_000_000 { return 8_000_000 }
        return max(2, Int(ceil(needed)))
    }

    /// Minimum uniform segments for a full circle.
    public static func circleSegmentCount(radius: Double, tolerance: Double) -> Int {
        circularSegmentCount(radius: radius, sweep: 2.0 * .pi, tolerance: tolerance)
    }

    /// Conservative uniform count for an ellipse parameter sweep. The major
    /// radius is used until the Bezier-span subdivider replaces this estimate.
    public static func ellipseSegmentCount(
        majorRadius: Double,
        sweep: Double,
        tolerance: Double
    ) -> Int {
        circularSegmentCount(radius: majorRadius, sweep: sweep, tolerance: tolerance)
    }
}

// =========================================================================
// MARK: - Curve LOD context
// =========================================================================

/// Screen-space level-of-detail inputs shared by every analytic curve
/// tessellator. The renderer selects one sticky 2x zoom band; `designZoom`
/// is that band's promotion zoom, so the world tolerance is valid for every
/// smaller zoom inside the band.
public struct CurveScreenTessellationContext: Sendable, Hashable {
    public let pixelsPerUnit: Double
    public let band: Int
    public let designZoom: Double
    public let viewport: ScreenTessellationViewport?
    public let maximumSegments: Int
    public let maximumDepth: Int
    public let totalMaximumSegments: Int

    public init(
        pixelsPerUnit: Double,
        band: Int,
        designZoom: Double,
        viewport: ScreenTessellationViewport? = nil,
        maximumSegments: Int = CurveScreenTessellation.defaultMaximumSegments,
        maximumDepth: Int = 32,
        totalMaximumSegments: Int = CurveScreenTessellation.defaultTotalMaximumSegments
    ) {
        self.pixelsPerUnit = pixelsPerUnit
        self.band = band
        self.designZoom = designZoom
        self.viewport = viewport
        self.maximumSegments = max(1, maximumSegments)
        self.maximumDepth = max(1, maximumDepth)
        self.totalMaximumSegments = max(64, totalMaximumSegments)
    }

    /// Build a context from live pixels-per-unit, applying zoom-band
    /// hysteresis when the caller supplies the previously applied band.
    public static func forPixelsPerUnit(
        _ pixelsPerUnit: Double,
        currentBand: Int? = nil,
        referencePixelsPerUnit: Double = 1.0,
        viewport: ScreenTessellationViewport? = nil,
        maximumSegments: Int = CurveScreenTessellation.defaultMaximumSegments,
        maximumDepth: Int = 32,
        totalMaximumSegments: Int = CurveScreenTessellation.defaultTotalMaximumSegments
    ) -> CurveScreenTessellationContext? {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return nil }
        let nominal = CurveScreenTessellation.zoomBand(
            for: pixelsPerUnit, referencePixelsPerUnit: referencePixelsPerUnit)
        let band: Int
        if let currentBand {
            band = CurveScreenTessellation.zoomBand(
                for: pixelsPerUnit,
                currentBand: currentBand,
                referencePixelsPerUnit: referencePixelsPerUnit)
        } else {
            band = nominal
        }
        let designZoom = CurveScreenTessellation.designZoom(
            for: band, referencePixelsPerUnit: referencePixelsPerUnit)
        return CurveScreenTessellationContext(
            pixelsPerUnit: pixelsPerUnit,
            band: band,
            designZoom: designZoom,
            viewport: viewport,
            maximumSegments: maximumSegments,
            maximumDepth: maximumDepth,
            totalMaximumSegments: totalMaximumSegments)
    }

    /// World-space sagitta budget served by this band's promotion zoom.
    public func worldTolerance(
        targetPixels: Double = CurveScreenTessellation.targetPixelError
    ) -> Double {
        guard designZoom.isFinite, designZoom > 0 else {
            return max(1e-9, targetPixels)
        }
        return max(1e-9, targetPixels / designZoom)
    }

    /// Per-curve segment budget derived from the shared refresh budget.
    /// A small curve set keeps the full per-curve maximum; a large curve set
    /// shares the total instead of permitting unbounded tessellation.
    public func budgetedMaximumSegments(curveCount: Int) -> Int {
        guard curveCount > 0 else { return maximumSegments }
        let share = totalMaximumSegments / max(1, curveCount)
        return max(64, min(maximumSegments, share))
    }
}

// =========================================================================
// MARK: - Screen-space spline subdivision
// =========================================================================

/// World-space rectangle used for padded viewport culling.
public struct ScreenTessellationViewport: Sendable, Hashable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxX = max(minX, maxX)
        self.maxY = max(minY, maxY)
    }

    public func intersects(minX: Double, minY: Double, maxX: Double, maxY: Double) -> Bool {
        !(maxX < self.minX || minX > self.maxX || maxY < self.minY || minY > self.maxY)
    }

    public func contains(_ other: ScreenTessellationViewport) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }
}

/// Screen-space tessellation output for one analytic curve interval.
public struct ScreenTessellatedCurve: Sendable {
    public let points: [Vector3]
    public let didHitMaximumSegments: Bool
    public let usedCoarseTolerance: Bool
    public let requestedSegments: Int

    public init(
        points: [Vector3],
        didHitMaximumSegments: Bool,
        usedCoarseTolerance: Bool = false,
        requestedSegments: Int? = nil
    ) {
        self.points = points
        self.didHitMaximumSegments = didHitMaximumSegments
        self.usedCoarseTolerance = usedCoarseTolerance
        self.requestedSegments = requestedSegments ?? max(0, points.count - 1)
    }
}

public typealias SplineScreenTessellation = ScreenTessellatedCurve

/// Accumulated tessellation accounting for one LOD refresh.
public struct CurveTessellationDiagnostics: Sendable {
    public private(set) var curves: Int = 0
    public private(set) var clampedCurves: Int = 0
    public private(set) var requestedSegments: Int = 0
    public private(set) var emittedSegments: Int = 0

    public init() {}

    public mutating func recordCurve(
        requestedSegments: Int,
        emittedSegments: Int,
        didHitMaximumSegments: Bool
    ) {
        curves += 1
        self.requestedSegments += max(0, requestedSegments)
        self.emittedSegments += max(0, emittedSegments)
        if didHitMaximumSegments { clampedCurves += 1 }
    }

    public mutating func merge(_ other: CurveTessellationDiagnostics) {
        curves += other.curves
        requestedSegments += other.requestedSegments
        emittedSegments += other.emittedSegments
        clampedCurves += other.clampedCurves
    }
}

extension CurveScreenTessellation {
    static func splineControlHull(
        controlPoints: [Vector3],
        knots: [Double],
        degree: Int,
        at knot: Double
    ) -> [Vector3]? {
        let p = degree
        let n = controlPoints.count - 1
        guard p >= 1, n >= p, knots.count == n + p + 2 else { return nil }
        let lower = knots[p]
        let upper = knots[n + 1]
        guard upper > lower else { return nil }
        let clamped = min(max(knot, lower), upper)
        let span: Int
        if clamped >= upper {
            span = n
        } else {
            var candidate = p
            while candidate < n && knots[candidate + 1] <= clamped {
                candidate += 1
            }
            span = candidate
        }
        let first = max(0, span - p)
        let last = min(n, span)
        guard first <= last else { return nil }
        return Array(controlPoints[first...last])
    }

    static func splineIntervalHull(
        controlPoints: [Vector3],
        knots: [Double],
        degree: Int,
        from lower: Double,
        to upper: Double
    ) -> [Vector3]? {
        let p = degree
        let n = controlPoints.count - 1
        guard p >= 1, n >= p, knots.count == n + p + 2, upper > lower else { return nil }
        let domainLower = knots[p]
        let domainUpper = knots[n + 1]
        var samples = [lower, 0.5 * (lower + upper), upper]
        for knot in knots where knot > lower && knot < upper {
            samples.append(min(max(knot, domainLower), domainUpper))
        }
        var hull: [Vector3] = []
        for sample in samples {
            guard let active = splineControlHull(
                controlPoints: controlPoints,
                knots: knots,
                degree: p,
                at: sample) else { return nil }
            hull.append(contentsOf: active)
        }
        return hull
    }

    static func segmentDeviation(_ point: Vector3, _ start: Vector3, _ end: Vector3) -> Double {
        let chord = end - start
        let lengthSquared = chord.magnitudeSquared
        guard lengthSquared > 1e-24 else { return (point - start).magnitude }
        let projection = max(0.0, min(1.0, (point - start).dot(chord) / lengthSquared))
        return (point - (start + chord * projection)).magnitude
    }

    struct HomogeneousControlPoint: Sendable {
        var x: Double
        var y: Double
        var z: Double
        var w: Double
    }

    /// Bézier control polygon for one nonzero knot span. Euclidean points are
    /// a conservative hull when all weights are positive.
    struct RationalBezierSpan: Sendable {
        var points: [HomogeneousControlPoint]
    }

    /// Decompose clamped NURBS spans into Bézier control polygons. Repeated
    /// knot insertion preserves the curve exactly while giving each recursive
    /// subdivision a hull that shrinks with the accepted interval.
    static func bezierSpans(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]
    ) -> [RationalBezierSpan]? {
        let p = degree
        let n = controlPoints.count - 1
        guard p >= 1, n >= p, knots.count == n + p + 2,
              weights.count == controlPoints.count,
              weights.allSatisfy({ $0 > 0 }) else { return nil }
        let domainLower = knots[p]
        let domainUpper = knots[n + 1]
        guard domainUpper > domainLower else { return nil }
        var currentKnots = knots
        var currentPoints = controlPoints
        var currentWeights = weights
        let knotTolerance = max(1e-12, (domainUpper - domainLower) * 1e-12)
        var interior: [Double] = []
        for knot in currentKnots where knot > domainLower + knotTolerance && knot < domainUpper - knotTolerance {
            if interior.last.map({ abs($0 - knot) > knotTolerance }) ?? true {
                interior.append(knot)
            }
        }
        for knot in interior {
            var multiplicity = currentKnots.reduce(0) { $0 + (abs($1 - knot) < knotTolerance ? 1 : 0) }
            var needed = p - multiplicity
            while needed > 0 {
                guard let inserted = NURBSEvaluator.insertKnot(
                    degree: p,
                    knots: currentKnots,
                    controlPoints: currentPoints,
                    weights: currentWeights,
                    at: knot) else { return nil }
                currentKnots = inserted.knots
                currentPoints = inserted.controlPoints
                currentWeights = inserted.weights
                needed -= 1
                multiplicity += 1
            }
        }
        var spans: [RationalBezierSpan] = []
        var pointIndex = 0
        for i in p..<(currentKnots.count - p - 1) {
            guard currentKnots[i + 1] - currentKnots[i] > knotTolerance else { continue }
            guard pointIndex + p < currentPoints.count else { return nil }
            var spanPoints: [HomogeneousControlPoint] = []
            spanPoints.reserveCapacity(p + 1)
            for j in 0...p {
                let point = currentPoints[pointIndex + j]
                let weight = currentWeights[pointIndex + j]
                spanPoints.append(HomogeneousControlPoint(
                    x: point.x * weight,
                    y: point.y * weight,
                    z: point.z * weight,
                    w: weight))
            }
            spans.append(RationalBezierSpan(points: spanPoints))
            pointIndex += p
        }
        guard !spans.isEmpty, pointIndex == currentPoints.count - 1 else { return nil }
        return spans
    }

    static func deCasteljauSplit(_ span: RationalBezierSpan) -> (left: RationalBezierSpan, right: RationalBezierSpan) {
        var levels: [[HomogeneousControlPoint]] = [span.points]
        while levels.last!.count > 1 {
            let previous = levels.last!
            var next: [HomogeneousControlPoint] = []
            next.reserveCapacity(previous.count - 1)
            for i in 0..<(previous.count - 1) {
                next.append(HomogeneousControlPoint(
                    x: 0.5 * (previous[i].x + previous[i + 1].x),
                    y: 0.5 * (previous[i].y + previous[i + 1].y),
                    z: 0.5 * (previous[i].z + previous[i + 1].z),
                    w: 0.5 * (previous[i].w + previous[i + 1].w)))
            }
            levels.append(next)
        }
        let left = RationalBezierSpan(points: levels.map { $0.first! })
        let right = RationalBezierSpan(points: levels.reversed().map { $0.last! })
        return (left, right)
    }

    static func euclideanBezierPoints(_ span: RationalBezierSpan) -> [Vector3]? {
        var points: [Vector3] = []
        points.reserveCapacity(span.points.count)
        for point in span.points {
            guard point.w > 0 else { return nil }
            points.append(Vector3(x: point.x / point.w, y: point.y / point.w, z: point.z / point.w))
        }
        return points
    }

    public static func tessellateSpline(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        pixelsPerUnit: Double,
        targetPixels: Double = targetPixelError,
        viewport: ScreenTessellationViewport? = nil,
        maximumSegments: Int = defaultMaximumSegments,
        maximumDepth: Int = 32
    ) -> SplineScreenTessellation {
        let band = zoomBand(for: pixelsPerUnit)
        let context = CurveScreenTessellationContext(
            pixelsPerUnit: pixelsPerUnit,
            band: band,
            designZoom: designZoom(for: band),
            viewport: viewport,
            maximumSegments: maximumSegments,
            maximumDepth: maximumDepth)
        return tessellateSpline(
            degree: degree,
            knots: knots,
            controlPoints: controlPoints,
            weights: weights,
            targetPixels: targetPixels,
            context: context)
    }

    public static func tessellateSpline(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double]? = nil,
        targetPixels: Double = targetPixelError,
        context: CurveScreenTessellationContext
    ) -> SplineScreenTessellation {
        let p = max(1, degree)
        guard controlPoints.count > p,
              knots.count == controlPoints.count + p + 1,
              context.maximumSegments > 0 else {
            return SplineScreenTessellation(points: [], didHitMaximumSegments: true)
        }
        var normalizedWeights = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        if normalizedWeights.count != controlPoints.count {
            normalizedWeights = Array(repeating: 1.0, count: controlPoints.count)
        }
        let tolerance = context.worldTolerance(targetPixels: targetPixels)
        let coarseTolerance = tolerance * offscreenToleranceMultiplier
        let segmentLimit = context.maximumSegments
        let depthLimit = context.maximumDepth
        let viewport = context.viewport

        // Bézier extraction can fail for unclamped or otherwise malformed
        // input. Keep legacy sampled display output in that fallback rather
        // than hiding the curve.
        guard normalizedWeights.allSatisfy({ $0 > 0 }),
              let spans = bezierSpans(
                degree: p, knots: knots,
                controlPoints: controlPoints,
                weights: normalizedWeights) else {
            var onScreen = true
            if let viewport, normalizedWeights.allSatisfy({ $0 > 0 }) {
                var minX = Double.infinity
                var minY = Double.infinity
                var maxX = -Double.infinity
                var maxY = -Double.infinity
                for point in controlPoints {
                    minX = min(minX, point.x)
                    minY = min(minY, point.y)
                    maxX = max(maxX, point.x)
                    maxY = max(maxY, point.y)
                }
                onScreen = viewport.intersects(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            }
            let points = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: p,
                knots: knots,
                controlPoints: controlPoints,
                weights: normalizedWeights,
                chordTolerance: onScreen ? tolerance : coarseTolerance,
                maxDepth: depthLimit,
                maxSegments: segmentLimit)
            return SplineScreenTessellation(
                points: points,
                didHitMaximumSegments: max(0, points.count - 1) >= segmentLimit,
                usedCoarseTolerance: !onScreen)
        }

        var points: [Vector3] = []
        points.reserveCapacity(min(segmentLimit + 1, 1025))
        var emittedSegments = 0
        var didHitMaximum = false
        var usedCoarseTolerance = false

        func appendEndpoint(_ point: Vector3) {
            if points.last != point { points.append(point) }
            emittedSegments += 1
        }

        func emit(span: RationalBezierSpan, depth: Int) {
            guard let euclidean = euclideanBezierPoints(span),
                  let start = euclidean.first,
                  let end = euclidean.last else { return }
            if emittedSegments >= segmentLimit {
                didHitMaximum = true
                appendEndpoint(end)
                return
            }
            if points.isEmpty { appendEndpoint(start) }
            var hullMinX = Double.infinity
            var hullMinY = Double.infinity
            var hullMaxX = -Double.infinity
            var hullMaxY = -Double.infinity
            var hullDeviation = 0.0
            for controlPoint in euclidean {
                hullMinX = min(hullMinX, controlPoint.x)
                hullMinY = min(hullMinY, controlPoint.y)
                hullMaxX = max(hullMaxX, controlPoint.x)
                hullMaxY = max(hullMaxY, controlPoint.y)
                hullDeviation = max(hullDeviation, segmentDeviation(controlPoint, start, end))
            }
            let onScreen = viewport?.intersects(
                minX: hullMinX, minY: hullMinY, maxX: hullMaxX, maxY: hullMaxY) ?? true
            if !onScreen { usedCoarseTolerance = true }
            let effectiveTolerance = onScreen ? tolerance : coarseTolerance
            if hullDeviation <= effectiveTolerance || depth >= depthLimit {
                appendEndpoint(end)
                return
            }
            let (left, right) = deCasteljauSplit(span)
            emit(span: left, depth: depth + 1)
            emit(span: right, depth: depth + 1)
        }

        for span in spans {
            emit(span: span, depth: 0)
            if didHitMaximum { break }
        }
        return SplineScreenTessellation(
            points: points,
            didHitMaximumSegments: didHitMaximum,
            usedCoarseTolerance: usedCoarseTolerance)
    }

    // MARK: - Conic and bulged-polyline subdivision

    /// Maximum planar stretch of an affine map: the largest singular value of
    /// its 2x2 xy block. Conservative for tessellation density because no
    /// local direction can grow more than this factor in world space.
    static func maximumPlanarScale(_ transform: Transform3D) -> Double {
        let a = transform.at(0, 0)
        let b = transform.at(0, 1)
        let c = transform.at(1, 0)
        let d = transform.at(1, 1)
        let frobeniusSquared = a * a + b * b + c * c + d * d
        guard frobeniusSquared.isFinite, frobeniusSquared > 0 else { return 0 }
        let determinant = a * d - b * c
        let discriminant = max(
            0,
            frobeniusSquared * frobeniusSquared - 4 * determinant * determinant)
        return sqrt(0.5 * (frobeniusSquared + sqrt(discriminant)))
    }

    static func angleIsOnSweep(angle: Double, start: Double, span: Double) -> Bool {
        let twoPi = 2.0 * Double.pi
        guard span >= 0, span <= twoPi else { return true }
        var relative = (angle - start).truncatingRemainder(dividingBy: twoPi)
        if relative < 0 { relative += twoPi }
        return relative <= span + 1e-12
    }

    /// Conservative local bounds for a circular sector. Endpoints and every
    /// swept quadrant extremum are included, so the result contains the arc
    /// even when the chord box does not.
    static func arcSectorBounds(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        sweep: Double
    ) -> ScreenTessellationViewport? {
        guard radius.isFinite, radius > 0,
              startAngle.isFinite, sweep.isFinite, sweep != 0 else { return nil }
        let twoPi = 2.0 * Double.pi
        var span = sweep.truncatingRemainder(dividingBy: twoPi)
        if span < 0 { span += twoPi }
        if abs(sweep) >= twoPi - 1e-12 || span >= twoPi - 1e-12 {
            return ScreenTessellationViewport(
                minX: center.x - radius,
                minY: center.y - radius,
                maxX: center.x + radius,
                maxY: center.y + radius)
        }
        func point(at angle: Double) -> (Double, Double) {
            (center.x + cos(angle) * radius, center.y + sin(angle) * radius)
        }
        let first = point(at: startAngle)
        let last = point(at: startAngle + sweep)
        var minX = min(first.0, last.0)
        var minY = min(first.1, last.1)
        var maxX = max(first.0, last.0)
        var maxY = max(first.1, last.1)
        for quadrant in 0..<4 {
            let angle = Double(quadrant) * Double.pi / 2.0
            if angleIsOnSweep(angle: angle, start: startAngle, span: span) {
                let extremum = point(at: angle)
                minX = min(minX, extremum.0)
                minY = min(minY, extremum.1)
                maxX = max(maxX, extremum.0)
                maxY = max(maxY, extremum.1)
            }
        }
        return ScreenTessellationViewport(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    static func worldArcSectorBounds(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        sweep: Double,
        transform: Transform3D
    ) -> ScreenTessellationViewport? {
        guard let local = arcSectorBounds(
            center: center, radius: radius, startAngle: startAngle, sweep: sweep) else {
            return nil
        }
        let corners = [
            Vector3(x: local.minX, y: local.minY, z: center.z),
            Vector3(x: local.minX, y: local.maxY, z: center.z),
            Vector3(x: local.maxX, y: local.minY, z: center.z),
            Vector3(x: local.maxX, y: local.maxY, z: center.z),
        ].map(transform.transformPoint)
        return ScreenTessellationViewport(
            minX: corners.map(\.x).min() ?? local.minX,
            minY: corners.map(\.y).min() ?? local.minY,
            maxX: corners.map(\.x).max() ?? local.maxX,
            maxY: corners.map(\.y).max() ?? local.maxY)
    }

    static func worldEllipseBounds(
        center: Vector3,
        majorAxis: Vector3,
        minorRatio: Double,
        transform: Transform3D
    ) -> ScreenTessellationViewport? {
        let majorLength = majorAxis.magnitude
        let minorLength = majorLength * abs(minorRatio)
        guard majorLength.isFinite, minorLength.isFinite,
              majorLength > 1e-12, minorLength > 1e-12 else { return nil }
        let rotation = atan2(majorAxis.y, majorAxis.x)
        let cosRotation = cos(rotation)
        let sinRotation = sin(rotation)
        let extentX = sqrt(
            majorLength * majorLength * cosRotation * cosRotation +
            minorLength * minorLength * sinRotation * sinRotation)
        let extentY = sqrt(
            majorLength * majorLength * sinRotation * sinRotation +
            minorLength * minorLength * cosRotation * cosRotation)
        let corners = [
            Vector3(x: center.x - extentX, y: center.y - extentY, z: center.z),
            Vector3(x: center.x - extentX, y: center.y + extentY, z: center.z),
            Vector3(x: center.x + extentX, y: center.y - extentY, z: center.z),
            Vector3(x: center.x + extentX, y: center.y + extentY, z: center.z),
        ].map(transform.transformPoint)
        return ScreenTessellationViewport(
            minX: corners.map(\.x).min() ?? center.x,
            minY: corners.map(\.y).min() ?? center.y,
            maxX: corners.map(\.x).max() ?? center.x,
            maxY: corners.map(\.y).max() ?? center.y)
    }

    static func worldPolylineSegmentBounds(
        path: CADPolyline,
        segment: Int,
        transform: Transform3D
    ) -> ScreenTessellationViewport? {
        guard segment >= 0, segment < path.segmentCount else { return nil }
        let start = path.vertices[segment]
        let end = path.vertices[path.endVertexIndex(forSegment: segment)]
        guard abs(start.bulge) > 1e-12,
              let arc = path.arcParameters(forSegment: segment) else {
            let worldStart = transform.transformPoint(start.position)
            let worldEnd = transform.transformPoint(end.position)
            return ScreenTessellationViewport(
                minX: min(worldStart.x, worldEnd.x),
                minY: min(worldStart.y, worldEnd.y),
                maxX: max(worldStart.x, worldEnd.x),
                maxY: max(worldStart.y, worldEnd.y))
        }
        return worldArcSectorBounds(
            center: arc.center,
            radius: arc.radius,
            startAngle: arc.startAngle,
            sweep: arc.sweep,
            transform: transform)
    }

    static func adaptiveWorldSamples(
        parameters: [Double],
        evaluate: (Double) -> Vector3?,
        tolerance: Double,
        maximumSegments: Int,
        maximumDepth: Int
    ) -> (points: [Vector3], didHitMaximum: Bool) {
        guard let firstParameter = parameters.first,
              let firstPoint = evaluate(firstParameter) else {
            return ([], true)
        }
        var points = [firstPoint]
        points.reserveCapacity(min(maximumSegments + 1, parameters.count))
        var didHitMaximum = false
        func refine(lowerParameter: Double, lowerPoint: Vector3, upperParameter: Double, upperPoint: Vector3, depth: Int) {
            if points.count > maximumSegments {
                didHitMaximum = true
                return
            }
            let middleParameter = 0.5 * (lowerParameter + upperParameter)
            guard let middlePoint = evaluate(middleParameter) else {
                points.append(upperPoint)
                return
            }
            if segmentDeviation(middlePoint, lowerPoint, upperPoint) <= tolerance || depth >= maximumDepth {
                points.append(upperPoint)
                return
            }
            refine(lowerParameter: lowerParameter, lowerPoint: lowerPoint, upperParameter: middleParameter, upperPoint: middlePoint, depth: depth + 1)
            refine(lowerParameter: middleParameter, lowerPoint: middlePoint, upperParameter: upperParameter, upperPoint: upperPoint, depth: depth + 1)
        }
        for index in 1..<parameters.count {
            if points.count > maximumSegments {
                didHitMaximum = true
                break
            }
            let lowerParameter = parameters[index - 1]
            let upperParameter = parameters[index]
            guard let upperPoint = evaluate(upperParameter),
                  let lowerPoint = points.last else {
                didHitMaximum = true
                break
            }
            refine(lowerParameter: lowerParameter, lowerPoint: lowerPoint, upperParameter: upperParameter, upperPoint: upperPoint, depth: 0)
        }
        return (points, didHitMaximum)
    }

    /// Screen-space circular arc subdivision with exact endpoints. Off-screen
    /// sectors use the coarse viewport tolerance; on-screen sectors use the
    /// band's world tolerance.
    public static func tessellateCircularArc(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        sweep: Double,
        transform: Transform3D = .identity,
        targetPixels: Double = targetPixelError,
        context: CurveScreenTessellationContext
    ) -> ScreenTessellatedCurve {
        guard radius.isFinite, radius > 0,
              startAngle.isFinite, sweep.isFinite, sweep != 0 else {
            return ScreenTessellatedCurve(points: [], didHitMaximumSegments: true)
        }
        let tolerance = context.worldTolerance(targetPixels: targetPixels)
        let coarseTolerance = tolerance * offscreenToleranceMultiplier
        let bounds = worldArcSectorBounds(
            center: center, radius: radius,
            startAngle: startAngle, sweep: sweep, transform: transform)
        let onScreen = context.viewport.flatMap { viewport in
            bounds.map { viewport.intersects(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) }
        } ?? true
        let effectiveTolerance = onScreen ? tolerance : coarseTolerance
        let needed = circularSegmentCount(
            radius: radius * max(maximumPlanarScale(transform), 1e-12),
            sweep: abs(sweep),
            tolerance: effectiveTolerance)
        let limit = context.maximumSegments
        let segments = min(max(needed, sweep == 2.0 * Double.pi ? 8 : 2), limit)
        let didHitMaximum = needed > limit
        let parameters = (0...segments).map { index in
            Double(index) / Double(segments)
        }
        let result = adaptiveWorldSamples(
            parameters: parameters,
            evaluate: { t in
                let angle = startAngle + sweep * t
                return transform.transformPoint(Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z))
            },
            tolerance: effectiveTolerance,
            maximumSegments: limit,
            maximumDepth: context.maximumDepth)
        return ScreenTessellatedCurve(
            points: result.points,
            didHitMaximumSegments: didHitMaximum || result.didHitMaximum,
            usedCoarseTolerance: !onScreen,
            requestedSegments: max(needed, max(0, result.points.count - 1)))
    }

    /// Screen-space ellipse subdivision. The uniform estimate uses the world
    /// major radius; adaptive world-space refinement guarantees the band
    /// tolerance under shear and non-uniform scale.
    public static func tessellateEllipse(
        center: Vector3,
        majorAxis: Vector3,
        minorRatio: Double,
        transform: Transform3D = .identity,
        targetPixels: Double = targetPixelError,
        context: CurveScreenTessellationContext
    ) -> ScreenTessellatedCurve {
        let majorLength = majorAxis.magnitude
        let minorLength = majorLength * abs(minorRatio)
        guard majorLength.isFinite, minorLength.isFinite,
              majorLength > 1e-12, minorLength > 1e-12 else {
            return ScreenTessellatedCurve(points: [], didHitMaximumSegments: true)
        }
        let tolerance = context.worldTolerance(targetPixels: targetPixels)
        let coarseTolerance = tolerance * offscreenToleranceMultiplier
        let bounds = worldEllipseBounds(
            center: center, majorAxis: majorAxis,
            minorRatio: minorRatio, transform: transform)
        let onScreen = context.viewport.flatMap { viewport in
            bounds.map { viewport.intersects(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) }
        } ?? true
        let effectiveTolerance = onScreen ? tolerance : coarseTolerance
        let worldMajor = (transform.transformPoint(center + majorAxis) - transform.transformPoint(center)).magnitude
        let needed = circularSegmentCount(
            radius: max(worldMajor, 1e-12),
            sweep: 2.0 * Double.pi,
            tolerance: effectiveTolerance)
        let limit = context.maximumSegments
        let segments = min(max(needed, 8), limit)
        let didHitMaximum = needed > limit
        let parameters = (0...segments).map { Double($0) / Double(segments) }
        let rotation = atan2(majorAxis.y, majorAxis.x)
        let result = adaptiveWorldSamples(
            parameters: parameters,
            evaluate: { t in
                let angle = t * 2.0 * Double.pi
                let local = Vector3(
                    x: center.x + majorLength * cos(angle) * cos(rotation) - minorLength * sin(angle) * sin(rotation),
                    y: center.y + majorLength * cos(angle) * sin(rotation) + minorLength * sin(angle) * cos(rotation),
                    z: center.z)
                return transform.transformPoint(local)
            },
            tolerance: effectiveTolerance,
            maximumSegments: limit,
            maximumDepth: context.maximumDepth)
        return ScreenTessellatedCurve(
            points: result.points,
            didHitMaximumSegments: didHitMaximum || result.didHitMaximum,
            usedCoarseTolerance: !onScreen,
            requestedSegments: max(needed, max(0, result.points.count - 1)))
    }

    public struct ScreenPolylineSample: Sendable {
        public var point: Vector3
        public var segment: Int
        public var localT: Double
    }

    /// Screen-space polyline subdivision. Straight spans stay exact; bulged
    /// spans are estimated from world radius and refined against the true
    /// world-space curve. Samples retain segment-local parameters for width
    /// interpolation.
    public static func tessellatePolyline(
        path: CADPolyline,
        transform: Transform3D = .identity,
        targetPixels: Double = targetPixelError,
        context: CurveScreenTessellationContext
    ) -> (samples: [ScreenPolylineSample], segments: [[ScreenPolylineSample]], curve: ScreenTessellatedCurve) {
        guard path.segmentCount > 0, path.vertices.first != nil else {
            return ([], [], ScreenTessellatedCurve(points: [], didHitMaximumSegments: true))
        }
        let tolerance = context.worldTolerance(targetPixels: targetPixels)
        let coarseTolerance = tolerance * offscreenToleranceMultiplier
        let limit = context.maximumSegments
        let planarScale = maximumPlanarScale(transform)
        var samples: [ScreenPolylineSample] = []
        samples.reserveCapacity(path.segmentCount + 1)
        var segmentSamples: [[ScreenPolylineSample]] = []
        segmentSamples.reserveCapacity(path.segmentCount)
        var requested = 0
        var didHitMaximum = false
        var usedCoarseTolerance = false
        for segment in 0..<path.segmentCount {
            let startVertex = path.vertices[segment]
            var current: [ScreenPolylineSample] = [
                ScreenPolylineSample(
                    point: transform.transformPoint(startVertex.position),
                    segment: segment,
                    localT: 0)
            ]
            guard abs(startVertex.bulge) > 1e-12,
                  let arc = path.arcParameters(forSegment: segment) else {
                let endPosition = path.vertices[path.endVertexIndex(forSegment: segment)].position
                current.append(ScreenPolylineSample(
                    point: transform.transformPoint(endPosition),
                    segment: segment,
                    localT: 1))
                segmentSamples.append(current)
                samples.append(contentsOf: current.dropFirst(samples.isEmpty ? 0 : 1))
                continue
            }
            let bounds = worldPolylineSegmentBounds(path: path, segment: segment, transform: transform)
            let onScreen = context.viewport.flatMap { viewport in
                bounds.map { viewport.intersects(minX: $0.minX, minY: $0.minY, maxX: $0.maxX, maxY: $0.maxY) }
            } ?? true
            if !onScreen { usedCoarseTolerance = true }
            let effectiveTolerance = onScreen ? tolerance : coarseTolerance
            let worldRadius = arc.radius * max(planarScale, 1e-12)
            let needed = circularSegmentCount(
                radius: worldRadius,
                sweep: abs(arc.sweep),
                tolerance: effectiveTolerance)
            requested += needed
            let segments = min(max(needed, 4), limit)
            if needed > limit { didHitMaximum = true }
            let parameters = (0...segments).map { Double($0) / Double(segments) }
            let result = adaptiveWorldSamples(
                parameters: parameters,
                evaluate: { t in
                    transform.transformPoint(path.point(onSegment: segment, t: t))
                },
                tolerance: effectiveTolerance,
                maximumSegments: limit,
                maximumDepth: context.maximumDepth)
            if result.didHitMaximum { didHitMaximum = true }
            for index in 1..<parameters.count {
                guard index < result.points.count else { break }
                current.append(ScreenPolylineSample(
                    point: result.points[index],
                    segment: segment,
                    localT: parameters[index]))
            }
            segmentSamples.append(current)
            samples.append(contentsOf: current.dropFirst(samples.isEmpty ? 0 : 1))
        }
        if path.isClosed, let firstPoint = samples.first?.point {
            samples.append(ScreenPolylineSample(
                point: firstPoint,
                segment: max(0, path.segmentCount - 1),
                localT: 1))
        }
        let curve = ScreenTessellatedCurve(
            points: samples.map(\.point),
            didHitMaximumSegments: didHitMaximum,
            usedCoarseTolerance: usedCoarseTolerance,
            requestedSegments: requested)
        return (samples, segmentSamples, curve)
    }
}
