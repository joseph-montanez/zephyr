import Foundation

// =========================================================================
// MARK: - CADPenStroke
//
// PenStrokeVertex: A single vertex in a pen-drawn stroke, capturing both
// geometric position and tablet pen attributes (pressure, tilt, rotation)
// from SDL3's CategoryPen API.
//
// These vertices are stored in the `.penStroke` CADPrimitive case and are
// serialized to EAB format only (DXF export falls back to a lossy spline).
// =========================================================================

/// A vertex in a pen stroke, carrying full tablet digitizer state.
///
/// All values use the SDL3 Pen API conventions:
/// - `pressure`: 0.0 (hovering) … 1.0 (full pressure)
/// - `xtilt`: -90.0 … 90.0 degrees (horizontal tilt)
/// - `ytilt`: -90.0 … 90.0 degrees (vertical tilt)
/// - `rotation`: -180.0 … 179.9 degrees (barrel rotation)
public struct PenStrokeVertex: Hashable, Sendable {
    public var position: Vector3
    public var pressure: Double
    public var xtilt: Double
    public var ytilt: Double
    public var rotation: Double

    public init(
        position: Vector3,
        pressure: Double = 1.0,
        xtilt: Double = 0.0,
        ytilt: Double = 0.0,
        rotation: Double = 0.0
    ) {
        self.position = position
        self.pressure = pressure
        self.xtilt = xtilt
        self.ytilt = ytilt
        self.rotation = rotation
    }

    /// Fallback vertex used for mouse/trackpad input (no tablet data).
    public static func mouseFallback(at position: Vector3) -> PenStrokeVertex {
        PenStrokeVertex(position: position, pressure: 1.0, xtilt: 0.0, ytilt: 0.0, rotation: 0.0)
    }
}

public struct PenStrokeBrushSettings: Hashable, Sendable {
    public var minLineWeight: Double
    public var maxLineWeight: Double
    public var tiltInfluence: Double
    public var rotationInfluence: Double

    public init(
        minLineWeight: Double,
        maxLineWeight: Double,
        tiltInfluence: Double = 0.5,
        rotationInfluence: Double = 0.0
    ) {
        let minWeight = max(0.01, minLineWeight)
        self.minLineWeight = minWeight
        self.maxLineWeight = max(minWeight, maxLineWeight)
        self.tiltInfluence = max(0.0, min(1.0, tiltInfluence))
        self.rotationInfluence = max(0.0, min(1.0, rotationInfluence))
    }

    public static func defaults(baseLineWeight: Double) -> PenStrokeBrushSettings {
        let base = max(0.05, baseLineWeight)
        return PenStrokeBrushSettings(
            minLineWeight: max(0.0, base * 0.0),
            maxLineWeight: max(3.0, base * 12.0),
            tiltInfluence: 0.5,
            rotationInfluence: 0.0)
    }

    public static func from(
        xdata: [String: XDataValue],
        fallbackBaseLineWeight: Double
    ) -> PenStrokeBrushSettings {
        let defaults = defaults(baseLineWeight: fallbackBaseLineWeight)

        func double(_ key: String, fallback: Double) -> Double {
            switch xdata[key] {
            case .double(let value)?: return value
            case .int(let value)?: return Double(value)
            default: return fallback
            }
        }

        return PenStrokeBrushSettings(
            minLineWeight: double("zephyr.penMinLineWeight", fallback: defaults.minLineWeight),
            maxLineWeight: double("zephyr.penMaxLineWeight", fallback: defaults.maxLineWeight),
            tiltInfluence: double("zephyr.penTiltInfluence", fallback: defaults.tiltInfluence),
            rotationInfluence: double("zephyr.penRotationInfluence", fallback: defaults.rotationInfluence))
    }

    public func apply(to entity: inout CADEntity) {
        entity.xdata["zephyr.penMinLineWeight"] = .double(minLineWeight)
        entity.xdata["zephyr.penMaxLineWeight"] = .double(maxLineWeight)
        entity.xdata["zephyr.penTiltInfluence"] = .double(tiltInfluence)
        entity.xdata["zephyr.penRotationInfluence"] = .double(rotationInfluence)
    }

    public func lineWeight(
        from first: PenStrokeVertex,
        to second: PenStrokeVertex,
        segmentAngle: Double
    ) -> Double {
        let pressure = clamp01((first.pressure + second.pressure) * 0.5)
        let tilt0 = min(1.0, hypot(first.xtilt, first.ytilt) / 90.0)
        let tilt1 = min(1.0, hypot(second.xtilt, second.ytilt) / 90.0)
        let tilt = (tilt0 + tilt1) * 0.5

        var normalizedWidth = pressure
        normalizedWidth += tiltInfluence * tilt * (1.0 - normalizedWidth)

        if rotationInfluence > 0.0 {
            let a0 = first.rotation * .pi / 180.0
            let a1 = second.rotation * .pi / 180.0
            let sx = sin(a0) + sin(a1)
            let cx = cos(a0) + cos(a1)
            let nibAngle = abs(sx) + abs(cx) > 1e-9 ? atan2(sx, cx) : a0
            let crossNib = abs(sin(segmentAngle - nibAngle))
            let directionalScale = 0.25 + 0.75 * crossNib
            normalizedWidth *= (1.0 - rotationInfluence) + rotationInfluence * directionalScale
        }

        let t = clamp01(normalizedWidth)
        return minLineWeight + (maxLineWeight - minLineWeight) * t
    }

    public func pixelWidth(
        from first: PenStrokeVertex,
        to second: PenStrokeVertex,
        segmentAngle: Double
    ) -> Float {
        max(1.0, Float(lineWeight(from: first, to: second, segmentAngle: segmentAngle) * (96.0 / 25.4)))
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}

public struct PenStrokeStabilizationSettings: Hashable, Sendable {
    public var amount: Double
    public var useSpline: Bool
    /// True when the `.penStroke` vertices have already been reduced to the
    /// editable on-curve fit points for this entity.
    public var fitPointsStored: Bool

    public init(
        amount: Double = 0.2,
        useSpline: Bool = true,
        fitPointsStored: Bool = false
    ) {
        self.amount = max(0.0, min(1.0, amount))
        self.useSpline = useSpline
        self.fitPointsStored = fitPointsStored
    }

    public static let defaults = PenStrokeStabilizationSettings()

    public static func from(xdata: [String: XDataValue]) -> PenStrokeStabilizationSettings {
        let amount: Double
        switch xdata["zephyr.penStabilization"] {
        case .double(let value)?: amount = value
        case .int(let value)?: amount = Double(value)
        default: amount = defaults.amount
        }

        let useSpline: Bool
        switch xdata["zephyr.penUseSpline"] {
        case .bool(let value)?: useSpline = value
        case .int(let value)?: useSpline = value != 0
        default: useSpline = defaults.useSpline
        }

        let fitPointsStored: Bool
        switch xdata["zephyr.penFitPointsStored"] {
        case .bool(let value)?: fitPointsStored = value
        case .int(let value)?: fitPointsStored = value != 0
        default: fitPointsStored = false
        }

        return PenStrokeStabilizationSettings(
            amount: amount,
            useSpline: useSpline,
            fitPointsStored: fitPointsStored)
    }

    public func apply(to entity: inout CADEntity) {
        entity.xdata["zephyr.penStabilization"] = .double(amount)
        entity.xdata["zephyr.penUseSpline"] = .bool(useSpline)
        entity.xdata["zephyr.penFitPointsStored"] = .bool(fitPointsStored)
    }

    public var inputAlpha: Double {
        max(0.15, 1.0 - 1.2 * amount)
    }

    public var inputThresholdPixels: Double {
        1.0 + 6.0 * amount
    }
}

public struct PenStrokeSplineFit: Hashable, Sendable {
    /// Simplified points that lie on the intended stroke. These are the editable
    /// fit points and are deliberately much fewer than the raw tablet samples.
    public var fitVertices: [PenStrokeVertex]

    /// Actual NURBS control vertices. The fitter builds a local piecewise-cubic
    /// spline through `fitVertices`; this avoids the global interpolation overshoot
    /// that can create loops on fast zig-zag pen motion.
    public var controlVertices: [PenStrokeVertex]
    public var degree: Int
    public var knots: [Double]
    public var weights: [Double]

    public init(
        fitVertices: [PenStrokeVertex],
        controlVertices: [PenStrokeVertex],
        degree: Int,
        knots: [Double],
        weights: [Double]
    ) {
        self.fitVertices = fitVertices
        self.controlVertices = controlVertices
        self.degree = degree
        self.knots = knots
        self.weights = weights
    }
}

public enum PenStrokeSplineFitter {
    public static func fit(
        vertices: [PenStrokeVertex],
        settings: PenStrokeStabilizationSettings,
        simplifyInput: Bool? = nil
    ) -> PenStrokeSplineFit? {
        guard vertices.count >= 2 else { return nil }
        let shouldSimplify = simplifyInput ?? !settings.fitPointsStored
        let simplified = settings.useSpline && shouldSimplify
            ? simplify(vertices: vertices, amount: settings.amount)
            : vertices
        let fitVertices = removeConsecutiveDuplicates(simplified)
        guard fitVertices.count >= 2 else { return nil }

        // A two-point stroke is exactly a line. Do not inflate it into a cubic.
        if fitVertices.count == 2 {
            return PenStrokeSplineFit(
                fitVertices: fitVertices,
                controlVertices: fitVertices,
                degree: 1,
                knots: [0.0, 0.0, 1.0, 1.0],
                weights: [1.0, 1.0])
        }

        // Do not use a single global interpolation solve here. A sparse global
        // cubic can develop huge control vectors when the user reverses direction
        // quickly, which is exactly how zig-zags turn into loops. Instead build a
        // chain of local centripetal Catmull-Rom segments and encode each segment
        // as a cubic Bezier span in one degree-3 NURBS. Each span only depends on
        // neighboring fit points, so a sharp turn cannot destabilize the rest of
        // the stroke.
        let segmentCount = fitVertices.count - 1
        var controls: [PenStrokeVertex] = []
        controls.reserveCapacity(segmentCount * 3 + 1)
        controls.append(fitVertices[0])

        for segment in 0..<segmentCount {
            let start = fitVertices[segment]
            let end = fitVertices[segment + 1]
            let bezier = shapePreservingBezierControls(
                vertices: fitVertices,
                segment: segment)

            controls.append(interpolatedControlVertex(
                from: start, to: end, t: 1.0 / 3.0, position: bezier.0))
            controls.append(interpolatedControlVertex(
                from: start, to: end, t: 2.0 / 3.0, position: bezier.1))
            controls.append(end)
        }

        var knots = [Double](repeating: 0.0, count: 4)
        if segmentCount > 1 {
            for boundary in 1..<segmentCount {
                let value = Double(boundary) / Double(segmentCount)
                knots.append(contentsOf: [value, value, value])
            }
        }
        knots.append(contentsOf: [1.0, 1.0, 1.0, 1.0])

        // Unit geometric weights are intentional. Pressure/tilt/rotation still
        // drive brush width independently. Non-unit rational geometry weights at
        // sharp turns amplify overshoot and are inappropriate for freehand fitting.
        let weights = [Double](repeating: 1.0, count: controls.count)
        return PenStrokeSplineFit(
            fitVertices: fitVertices,
            controlVertices: controls,
            degree: 3,
            knots: knots,
            weights: weights)
    }

    public static func simplify(
        vertices: [PenStrokeVertex],
        amount: Double
    ) -> [PenStrokeVertex] {
        guard vertices.count > 3 else { return vertices }
        let clampedAmount = max(0.0, min(1.0, amount))
        if clampedAmount <= 1e-9 { return vertices }

        var totalLength = 0.0
        var minX = vertices[0].position.x
        var minY = vertices[0].position.y
        var maxX = minX
        var maxY = minY
        for i in 1..<vertices.count {
            totalLength += vertices[i - 1].position.distance(to: vertices[i].position)
            minX = min(minX, vertices[i].position.x)
            minY = min(minY, vertices[i].position.y)
            maxX = max(maxX, vertices[i].position.x)
            maxY = max(maxY, vertices[i].position.y)
        }

        let averageSegment = totalLength / Double(max(1, vertices.count - 1))
        let diagonal = hypot(maxX - minX, maxY - minY)
        let simplification = pow(clampedAmount, 1.25)
        let averageTolerance = averageSegment * (0.05 + 2.50 * simplification)
        let diagonalTolerance = diagonal * (0.001 + 0.020 * pow(clampedAmount, 1.5))
        let tolerance = max(1e-9, min(diagonal * 0.05, max(averageTolerance, diagonalTolerance)))

        var keep = Set<Int>()
        keep.insert(0)
        keep.insert(vertices.count - 1)
        var stack: [(Int, Int)] = [(0, vertices.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end - start > 1 else { continue }
            let a = vertices[start].position
            let b = vertices[end].position
            var bestIndex = -1
            var bestDistance = 0.0
            for i in (start + 1)..<end {
                let distance = pointToSegmentDistance(vertices[i].position, a, b)
                if distance > bestDistance {
                    bestDistance = distance
                    bestIndex = i
                }
            }
            if bestIndex >= 0 && bestDistance > tolerance {
                keep.insert(bestIndex)
                stack.append((start, bestIndex))
                stack.append((bestIndex, end))
            }
        }

        let pressureThreshold = 0.05 + 0.25 * clampedAmount
        let tiltThreshold = 5.0 + 30.0 * clampedAmount
        let rotationThreshold = 10.0 + 50.0 * clampedAmount
        for i in 1..<(vertices.count - 1) {
            let previous = vertices[i - 1]
            let current = vertices[i]
            let next = vertices[i + 1]
            let pressureMid = (previous.pressure + next.pressure) * 0.5
            let tiltMidX = (previous.xtilt + next.xtilt) * 0.5
            let tiltMidY = (previous.ytilt + next.ytilt) * 0.5
            if abs(current.pressure - pressureMid) > pressureThreshold
                || hypot(current.xtilt - tiltMidX, current.ytilt - tiltMidY) > tiltThreshold
                || abs(shortestAngleDelta(current.rotation, (previous.rotation + next.rotation) * 0.5)) > rotationThreshold {
                keep.insert(i)
            }
        }

        // Stabilization is also a complexity budget. At 100% the final path is
        // intentionally very sparse (at most six fit points), instead of retaining
        // a percentage of an arbitrarily dense input stream.
        let minimumControls = min(vertices.count, 4)
        let relativeRetention = max(0.04, 1.0 - 0.96 * pow(clampedAmount, 0.72))
        let relativeCap = Int(ceil(Double(vertices.count) * relativeRetention))
        // Keep the interpolation solve bounded even for very high-rate tablets.
        // 20% (the default) lands at about 48 fit points; 50% ~27; 75% ~13;
        // 100% is capped at 6. Exactly 0% still returns the raw points above.
        let absoluteCap = Int(round(
            6.0 + 58.0 * pow(1.0 - clampedAmount, 1.5)))
        let targetMaximumControls = max(
            minimumControls,
            min(vertices.count, relativeCap, absoluteCap))

        if keep.count > targetMaximumControls {
            // Greedy global error insertion keeps the reduced controls distributed
            // over the whole path. Geometry dominates, while pressure/tilt/rotation
            // changes can still win a slot when they materially affect the brush.
            var selected = Set<Int>([0, vertices.count - 1])

            while selected.count < targetMaximumControls {
                let sortedSelected = selected.sorted()
                var bestIndex: Int?
                var bestScore = -Double.infinity

                for interval in 0..<(sortedSelected.count - 1) {
                    let start = sortedSelected[interval]
                    let end = sortedSelected[interval + 1]
                    guard end - start > 1 else { continue }
                    let a = vertices[start]
                    let b = vertices[end]
                    let span = Double(end - start)

                    for index in (start + 1)..<end {
                        let current = vertices[index]
                        let localT = Double(index - start) / span
                        let geometric = pointToSegmentDistance(
                            current.position, a.position, b.position) / max(tolerance, 1e-9)
                        let expectedPressure = a.pressure + (b.pressure - a.pressure) * localT
                        let pressure = abs(current.pressure - expectedPressure)
                            / max(pressureThreshold, 1e-9)
                        let expectedTiltX = a.xtilt + (b.xtilt - a.xtilt) * localT
                        let expectedTiltY = a.ytilt + (b.ytilt - a.ytilt) * localT
                        let tilt = hypot(
                            current.xtilt - expectedTiltX,
                            current.ytilt - expectedTiltY) / max(tiltThreshold, 1e-9)
                        let expectedRotation = a.rotation
                            + shortestAngleDelta(b.rotation, a.rotation) * localT
                        let rotation = abs(shortestAngleDelta(current.rotation, expectedRotation))
                            / max(rotationThreshold, 1e-9)
                        let score = geometric * 3.0 + pressure + tilt + rotation
                        if score > bestScore {
                            bestScore = score
                            bestIndex = index
                        }
                    }
                }

                guard let bestIndex else { break }
                selected.insert(bestIndex)
            }
            keep = selected
        }

        return keep.sorted().map { vertices[$0] }
    }

    public static func interpolatedVertices(
        source: [PenStrokeVertex],
        positions: [Vector3]
    ) -> [PenStrokeVertex] {
        guard !source.isEmpty, !positions.isEmpty else { return [] }
        guard source.count > 1, positions.count > 1 else {
            let v = source[0]
            return positions.map {
                PenStrokeVertex(
                    position: $0, pressure: v.pressure, xtilt: v.xtilt,
                    ytilt: v.ytilt, rotation: v.rotation)
            }
        }

        var sourceDistances = [Double](repeating: 0.0, count: source.count)
        for i in 1..<source.count {
            sourceDistances[i] = sourceDistances[i - 1]
                + source[i - 1].position.distance(to: source[i].position)
        }
        let sourceTotal = sourceDistances.last ?? 0.0
        if sourceTotal <= 1e-12 {
            let v = source[0]
            return positions.map {
                PenStrokeVertex(
                    position: $0, pressure: v.pressure, xtilt: v.xtilt,
                    ytilt: v.ytilt, rotation: v.rotation)
            }
        }

        var targetDistances = [Double](repeating: 0.0, count: positions.count)
        for i in 1..<positions.count {
            targetDistances[i] = targetDistances[i - 1] + positions[i - 1].distance(to: positions[i])
        }
        let targetTotal = max(targetDistances.last ?? 0.0, 1e-12)
        var sourceIndex = 0
        var result: [PenStrokeVertex] = []
        result.reserveCapacity(positions.count)

        for i in positions.indices {
            let sourceDistance = sourceTotal * (targetDistances[i] / targetTotal)
            while sourceIndex + 1 < sourceDistances.count - 1
                && sourceDistances[sourceIndex + 1] < sourceDistance {
                sourceIndex += 1
            }
            let nextIndex = min(sourceIndex + 1, source.count - 1)
            let d0 = sourceDistances[sourceIndex]
            let d1 = sourceDistances[nextIndex]
            let t = d1 > d0 ? max(0.0, min(1.0, (sourceDistance - d0) / (d1 - d0))) : 0.0
            let a = source[sourceIndex]
            let b = source[nextIndex]
            result.append(PenStrokeVertex(
                position: positions[i],
                pressure: lerp(a.pressure, b.pressure, t),
                xtilt: lerp(a.xtilt, b.xtilt, t),
                ytilt: lerp(a.ytilt, b.ytilt, t),
                rotation: a.rotation + shortestAngleDelta(b.rotation, a.rotation) * t))
        }
        return result
    }

    /// Remove only consecutive coincident points. Besides reducing redundant
    /// controls, this prevents zero Catmull-Rom parameter intervals after erasing
    /// or when the tablet reports the same position for several events.
    private static func removeConsecutiveDuplicates(
        _ vertices: [PenStrokeVertex]
    ) -> [PenStrokeVertex] {
        guard let first = vertices.first else { return [] }
        var result = [first]
        result.reserveCapacity(vertices.count)
        for vertex in vertices.dropFirst() {
            if vertex.position.distance(to: result[result.count - 1].position) > 1e-9 {
                result.append(vertex)
            } else {
                // Keep the newest tablet metadata even when geometry did not move.
                result[result.count - 1].pressure = vertex.pressure
                result[result.count - 1].xtilt = vertex.xtilt
                result[result.count - 1].ytilt = vertex.ytilt
                result[result.count - 1].rotation = vertex.rotation
            }
        }
        return result
    }

    /// Build the two interior Bezier controls for one fit-point interval.
    ///
    /// This starts from a centripetal Catmull-Rom tangent (alpha = 0.5), then
    /// applies two safety constraints:
    ///   - a handle may not point backward relative to this interval;
    ///   - a handle may not exceed 45% of the interval chord.
    ///
    /// With the Bezier control projections therefore ordered 0, <=0.45,
    /// >=0.55, 1 along the interval chord, a single span cannot fold back on
    /// itself and form the loops seen with the old global interpolation solve.
    private static func shapePreservingBezierControls(
        vertices: [PenStrokeVertex],
        segment: Int
    ) -> (Vector3, Vector3) {
        let p1 = vertices[segment].position
        let p2 = vertices[segment + 1].position
        let chord = p2 - p1
        let chordLength = chord.magnitude
        guard chordLength > 1e-12 else { return (p1, p2) }

        let p0 = segment > 0
            ? vertices[segment - 1].position
            : p1 * 2.0 - p2
        let p3 = segment + 2 < vertices.count
            ? vertices[segment + 2].position
            : p2 * 2.0 - p1

        let alpha = 0.5
        func nextParameter(_ value: Double, _ a: Vector3, _ b: Vector3) -> Double {
            value + pow(max(a.distance(to: b), 1e-9), alpha)
        }

        let t0 = 0.0
        let t1 = nextParameter(t0, p0, p1)
        let t2 = nextParameter(t1, p1, p2)
        let t3 = nextParameter(t2, p2, p3)
        let interval = max(t2 - t1, 1e-9)

        var tangent1 = interval * (
            (p1 - p0) / max(t1 - t0, 1e-9)
            - (p2 - p0) / max(t2 - t0, 1e-9)
            + (p2 - p1) / max(t2 - t1, 1e-9))
        var tangent2 = interval * (
            (p2 - p1) / max(t2 - t1, 1e-9)
            - (p3 - p1) / max(t3 - t1, 1e-9)
            + (p3 - p2) / max(t3 - t2, 1e-9))

        let chordDirection = chord / chordLength
        let maximumTangentMagnitude = chordLength * 1.35 // /3 = 45% Bezier handle

        func safeTangent(_ tangent: Vector3) -> Vector3 {
            // Backward handles are what allow a cubic span to double back.
            guard tangent.x * chordDirection.x
                    + tangent.y * chordDirection.y
                    + tangent.z * chordDirection.z > 0.0
            else { return .zero }

            let magnitude = tangent.magnitude
            guard magnitude > 1e-12 else { return .zero }
            if magnitude <= maximumTangentMagnitude { return tangent }
            return tangent * (maximumTangentMagnitude / magnitude)
        }

        tangent1 = safeTangent(tangent1)
        tangent2 = safeTangent(tangent2)
        return (
            p1 + tangent1 / 3.0,
            p2 - tangent2 / 3.0)
    }

    private static func interpolatedControlVertex(
        from first: PenStrokeVertex,
        to second: PenStrokeVertex,
        t: Double,
        position: Vector3
    ) -> PenStrokeVertex {
        PenStrokeVertex(
            position: position,
            pressure: lerp(first.pressure, second.pressure, t),
            xtilt: lerp(first.xtilt, second.xtilt, t),
            ytilt: lerp(first.ytilt, second.ytilt, t),
            rotation: first.rotation + shortestAngleDelta(second.rotation, first.rotation) * t)
    }

    private static func pointToSegmentDistance(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let ab = b - a
        let lengthSq = ab.magnitudeSquared
        guard lengthSq > 1e-18 else { return p.distance(to: a) }
        let ap = p - a
        let t = max(0.0, min(1.0, (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / lengthSq))
        let projection = a + ab * t
        return p.distance(to: projection)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func shortestAngleDelta(_ target: Double, _ source: Double) -> Double {
        var delta = (target - source).truncatingRemainder(dividingBy: 360.0)
        if delta > 180.0 { delta -= 360.0 }
        if delta < -180.0 { delta += 360.0 }
        return delta
    }
}
