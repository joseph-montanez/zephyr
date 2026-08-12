import Foundation

/// Vector eraser used by `PenStrokeCommand`.
///
/// The eraser is a world-space circle derived from a fixed screen-space diameter.
/// It destructively removes only the portions of supported outline geometry that
/// fall inside the circle. Native splines are split with exact NURBS subdivision;
/// pen strokes retain pressure/tilt/rotation metadata on the surviving fragments.
@MainActor
public enum PenVectorEraser {

    @discardableResult
    public static func erase(
        center: Vector3,
        radius: Double,
        document: CADDocument
    ) -> Bool {
        eraseSweep(from: center, to: center, radius: radius, document: document)
    }

    /// Erase one cursor movement as a single batched edit. The previous version
    /// called `erase(center:)` repeatedly along the sweep, which re-ran the spatial
    /// query, NURBS fitting, subdivision and document update for every tiny circle.
    @discardableResult
    public static func eraseSweep(
        from start: Vector3,
        to end: Vector3,
        radius: Double,
        document: CADDocument
    ) -> Bool {
        guard radius > 1e-9 else { return false }

        let distance = start.distance(to: end)
        let spacing = max(radius * 0.9, 1e-8)
        let stepCount = min(24, max(1, Int(ceil(distance / spacing))))
        var centers: [Vector3] = []
        centers.reserveCapacity(stepCount)
        for step in 1...stepCount {
            let t = Double(step) / Double(stepCount)
            centers.append(Vector3(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
                z: start.z + (end.z - start.z) * t))
        }

        let handles = document.entityHandlesInWorldRect(
            minX: min(start.x, end.x) - radius,
            minY: min(start.y, end.y) - radius,
            maxX: max(start.x, end.x) + radius,
            maxY: max(start.y, end.y) + radius)
            ?? document.entitiesView.map(\.handle)

        var modifiedAny = false
        var removedHandles = Set<UUID>()
        var updatedEntities: [CADEntity] = []
        updatedEntities.reserveCapacity(handles.count)

        for handle in handles {
            guard var entity = document.entity(for: handle),
                  entity.blockID == nil,
                  entity.dimensionMetadata == nil,
                  entity.leaderData == nil,
                  entity.arrayData == nil,
                  let layer = document.layer(for: entity.layerID), layer.isVisible,
                  let originalGeometry = entity.localGeometry, !originalGeometry.isEmpty
            else { continue }

            var geometry = originalGeometry
            var modifiedEntity = false

            // Apply all overlapping eraser-circle samples in memory, then publish
            // the entity once. This is especially important for splines because
            // updateEntityLive() triggers a render regeneration.
            for center in centers {
                var nextGeometry: [CADPrimitive] = []
                nextGeometry.reserveCapacity(geometry.count + 2)
                var modifiedThisCenter = false

                for primitive in geometry {
                    switch erasePrimitive(
                        primitive,
                        entityXData: entity.xdata,
                        transform: entity.transform,
                        center: center,
                        radius: radius) {
                    case .unchanged:
                        nextGeometry.append(primitive)
                    case .replaced(let replacements):
                        nextGeometry.append(contentsOf: replacements)
                        modifiedThisCenter = true
                    }
                }

                if modifiedThisCenter {
                    geometry = nextGeometry
                    modifiedEntity = true
                    if geometry.isEmpty { break }
                }
            }

            guard modifiedEntity else { continue }
            modifiedAny = true

            if geometry.isEmpty {
                removedHandles.insert(handle)
            } else {
                entity.localGeometry = geometry
                if geometry.contains(where: {
                    if case .penStroke = $0 { return true }
                    return false
                }) {
                    var stabilization = PenStrokeStabilizationSettings.from(xdata: entity.xdata)
                    if stabilization.useSpline {
                        stabilization.fitPointsStored = true
                        stabilization.apply(to: &entity)
                    }
                }
                updatedEntities.append(entity)
            }
        }

        if modifiedAny {
            document.applyLiveEntityEdits(
                removing: removedHandles,
                updating: updatedEntities)
        }
        return modifiedAny
    }

    // MARK: - Primitive dispatch

    private enum PrimitiveResult {
        case unchanged
        case replaced([CADPrimitive])
    }

    private static func erasePrimitive(
        _ primitive: CADPrimitive,
        entityXData: [String: XDataValue],
        transform: Transform3D,
        center: Vector3,
        radius: Double
    ) -> PrimitiveResult {
        switch primitive {
        case .line(let start, let end, let color):
            let worldStart = transform.transformPoint(start)
            let worldEnd = transform.transformPoint(end)
            let clipped = outsidePieces(
                from: worldStart, to: worldEnd, center: center, radius: radius)
            guard clipped.changed else { return .unchanged }
            let inverse = transform.inverse()
            return .replaced(clipped.pieces.map {
                .line(
                    start: inverse.transformPoint($0.0),
                    end: inverse.transformPoint($0.1),
                    color: color)
            })

        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            return eraseSpline(
                controlPoints: controlPoints,
                knots: knots,
                degree: degree,
                weights: weights,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .penStroke(let vertices, let baseLineWeight, let color):
            return erasePenStroke(
                vertices: vertices,
                baseLineWeight: baseLineWeight,
                color: color,
                xdata: entityXData,
                transform: transform,
                center: center,
                radius: radius)

        case .polyline(let path, let color):
            return eraseTessellatedPath(
                localPoints: path.tessellatedPoints(segmentsPerRadian: 18.0),
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .polygon(let points, let color):
            guard points.count >= 2 else { return .unchanged }
            var closed = points
            if let first = closed.first, let last = closed.last,
               first.distance(to: last) > 1e-9 {
                closed.append(first)
            }
            return eraseTessellatedPath(
                localPoints: closed,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .rect(let origin, let size, let color):
            let points = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                origin,
            ]
            return eraseTessellatedPath(
                localPoints: points,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .circle(let circleCenter, let circleRadius, let color):
            guard circleRadius > 1e-12 else { return .unchanged }
            let points = (0...128).map { index -> Vector3 in
                let angle = Double(index) * 2.0 * .pi / 128.0
                return Vector3(
                    x: circleCenter.x + cos(angle) * circleRadius,
                    y: circleCenter.y + sin(angle) * circleRadius,
                    z: circleCenter.z)
            }
            return eraseTessellatedPath(
                localPoints: points,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .arc(let arcCenter, let arcRadius, let startAngle, let endAngle, let color):
            guard arcRadius > 1e-12 else { return .unchanged }
            var sweep = endAngle - startAngle
            if sweep < 0 { sweep += 2.0 * .pi }
            let divisions = max(16, Int(ceil(abs(sweep) * 32.0)))
            let points = (0...divisions).map { index -> Vector3 in
                let t = Double(index) / Double(divisions)
                let angle = startAngle + sweep * t
                return Vector3(
                    x: arcCenter.x + cos(angle) * arcRadius,
                    y: arcCenter.y + sin(angle) * arcRadius,
                    z: arcCenter.z)
            }
            return eraseTessellatedPath(
                localPoints: points,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        case .ellipse(let ellipseCenter, let majorAxis, let minorRatio, let color):
            let majorLength = majorAxis.magnitude
            guard majorLength > 1e-12, abs(minorRatio) > 1e-12 else { return .unchanged }
            let minorAxis = Vector3(
                x: -majorAxis.y * minorRatio,
                y: majorAxis.x * minorRatio,
                z: 0)
            let points = (0...128).map { index -> Vector3 in
                let angle = Double(index) * 2.0 * .pi / 128.0
                return ellipseCenter + majorAxis * cos(angle) + minorAxis * sin(angle)
            }
            return eraseTessellatedPath(
                localPoints: points,
                color: color,
                transform: transform,
                center: center,
                radius: radius)

        // Filled primitives, annotation, images, rays, hatches and tables are not
        // vector-eraser targets. TRIM-style editing of these remains separate.
        case .point, .fillRect, .fillPolygon, .fillComplexPolygon, .gradient,
             .text, .hatch, .hatchPath, .ray, .image, .table:
            return .unchanged
        }
    }

    // MARK: - Exact spline erasing

    private static func eraseSpline(
        controlPoints: [Vector3],
        knots: [Double],
        degree: Int,
        weights: [Double]?,
        color: ColorRGBA?,
        transform: Transform3D,
        center: Vector3,
        radius: Double
    ) -> PrimitiveResult {
        guard degree >= 1,
              controlPoints.count > degree,
              knots.count == controlPoints.count + degree + 1
        else { return .unchanged }

        let worldControlPoints = controlPoints.map { transform.transformPoint($0) }
        let splineWeights = weights ?? Array(repeating: 1.0, count: controlPoints.count)
        guard splineWeights.count == controlPoints.count else { return .unchanged }

        let tMin = knots[degree]
        let tMax = knots[controlPoints.count]
        guard tMax > tMin else { return .unchanged }

        let crossings = circleCrossings(
            degree: degree,
            knots: knots,
            controlPoints: worldControlPoints,
            weights: splineWeights,
            center: center,
            radius: radius)

        guard crossings.touched else { return .unchanged }

        var boundaries = [tMin]
        boundaries.append(contentsOf: crossings.parameters)
        boundaries.append(tMax)
        boundaries = deduplicatedParameters(boundaries, range: tMax - tMin)

        let inverse = transform.inverse()
        var kept: [CADPrimitive] = []
        for index in 0..<(boundaries.count - 1) {
            let a = boundaries[index]
            let b = boundaries[index + 1]
            guard b - a > max(1e-10, (tMax - tMin) * 1e-9) else { continue }
            let mid = (a + b) * 0.5
            guard let midpoint = NURBSEvaluator.evaluateAt(
                degree: degree,
                knots: knots,
                controlPoints: worldControlPoints,
                weights: splineWeights,
                at: mid)
            else { continue }

            if distanceXY(midpoint, center) < radius { continue }
            guard let component = splineInterval(
                degree: degree,
                knots: knots,
                controlPoints: worldControlPoints,
                weights: splineWeights,
                from: a,
                to: b)
            else { continue }

            let localControlPoints = component.controlPoints.map { inverse.transformPoint($0) }
            let outputWeights: [Double]? = weights == nil ? nil : component.weights
            kept.append(.spline(
                controlPoints: localControlPoints,
                knots: component.knots,
                degree: degree,
                weights: outputWeights,
                color: color))
        }

        return .replaced(kept)
    }

    private struct CircleCrossings {
        var parameters: [Double]
        var touched: Bool
    }

    private static func circleCrossings(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double],
        center: Vector3,
        radius: Double
    ) -> CircleCrossings {
        let tMin = knots[degree]
        let tMax = knots[controlPoints.count]
        // Coarse-to-fine search: the eraser is an interactive tool, so avoid
        // hundreds/thousands of De Boor evaluations for every pen-motion event.
        let sampleCount = min(384, max(48, controlPoints.count * 12))
        var roots: [Double] = []
        var touched = false

        func signedDistance(_ point: Vector3) -> Double {
            distanceXY(point, center) - radius
        }

        guard var previousPoint = NURBSEvaluator.evaluateAt(
            degree: degree, knots: knots, controlPoints: controlPoints,
            weights: weights, at: tMin)
        else { return CircleCrossings(parameters: [], touched: false) }
        var previousT = tMin
        var previousValue = signedDistance(previousPoint)
        if previousValue <= 0 { touched = true }

        for sample in 1...sampleCount {
            let t = tMin + (tMax - tMin) * Double(sample) / Double(sampleCount)
            guard let point = NURBSEvaluator.evaluateAt(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: weights, at: t)
            else { continue }
            let value = signedDistance(point)
            if value <= 0 { touched = true }

            if (previousValue < 0 && value >= 0) || (previousValue >= 0 && value < 0) {
                var lowT = previousT
                var highT = t
                var lowValue = previousValue
                for _ in 0..<14 {
                    let midT = (lowT + highT) * 0.5
                    guard let midPoint = NURBSEvaluator.evaluateAt(
                        degree: degree, knots: knots, controlPoints: controlPoints,
                        weights: weights, at: midT)
                    else { break }
                    let midValue = signedDistance(midPoint)
                    if (lowValue < 0) == (midValue < 0) {
                        lowT = midT
                        lowValue = midValue
                    } else {
                        highT = midT
                    }
                }
                roots.append((lowT + highT) * 0.5)
            }

            previousPoint = point
            previousT = t
            previousValue = value
        }

        _ = previousPoint
        return CircleCrossings(
            parameters: deduplicatedParameters(roots, range: tMax - tMin),
            touched: touched)
    }

    private static func splineInterval(
        degree: Int,
        knots: [Double],
        controlPoints: [Vector3],
        weights: [Double],
        from start: Double,
        to end: Double
    ) -> SplineComponents? {
        let domainMin = knots[degree]
        let domainMax = knots[controlPoints.count]
        let epsilon = max(1e-10, (domainMax - domainMin) * 1e-9)
        guard end > start + epsilon else { return nil }

        var component = SplineComponents(
            controlPoints: controlPoints,
            knots: knots,
            weights: weights)

        if start > domainMin + epsilon {
            guard let split = NURBSEvaluator.subdivide(
                degree: degree,
                knots: component.knots,
                controlPoints: component.controlPoints,
                weights: component.weights,
                at: start)
            else { return nil }
            component = split.right
        }

        let currentMax = component.knots[component.controlPoints.count]
        if end < currentMax - epsilon {
            guard let split = NURBSEvaluator.subdivide(
                degree: degree,
                knots: component.knots,
                controlPoints: component.controlPoints,
                weights: component.weights,
                at: end)
            else { return nil }
            component = split.left
        }

        return component
    }

    // MARK: - Pen-stroke erasing

    private static func erasePenStroke(
        vertices: [PenStrokeVertex],
        baseLineWeight: Double,
        color: ColorRGBA?,
        xdata: [String: XDataValue],
        transform: Transform3D,
        center: Vector3,
        radius: Double
    ) -> PrimitiveResult {
        guard vertices.count >= 2 else { return .unchanged }
        let stabilization = PenStrokeStabilizationSettings.from(xdata: xdata)

        let localVertices: [PenStrokeVertex]
        if stabilization.useSpline,
           let fit = PenStrokeSplineFitter.fit(vertices: vertices, settings: stabilization) {
            let controlPoints = fit.controlVertices.map(\.position)
            var minPoint = controlPoints[0]
            var maxPoint = controlPoints[0]
            for point in controlPoints.dropFirst() {
                minPoint.x = min(minPoint.x, point.x)
                minPoint.y = min(minPoint.y, point.y)
                maxPoint.x = max(maxPoint.x, point.x)
                maxPoint.y = max(maxPoint.y, point.y)
            }
            let diagonal = max((maxPoint - minPoint).magnitude, 1.0)
            var positions = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: fit.degree,
                knots: fit.knots,
                controlPoints: controlPoints,
                weights: fit.weights,
                chordTolerance: max(0.002, diagonal / 1500.0),
                maxDepth: 8,
                maxSegments: 512)
            if positions.count < 2 {
                positions = NURBSEvaluator.evaluateByKnotSpans(
                    degree: fit.degree,
                    knots: fit.knots,
                    controlPoints: controlPoints,
                    weights: fit.weights,
                    segmentsPerSpan: 8)
            }
            localVertices = PenStrokeSplineFitter.interpolatedVertices(
                source: vertices,
                positions: positions)
        } else {
            localVertices = vertices
        }

        let worldVertices = localVertices.map { vertex -> PenStrokeVertex in
            var transformed = vertex
            transformed.position = transform.transformPoint(vertex.position)
            return transformed
        }
        let clipped = clipPenVerticesOutsideCircle(
            worldVertices, center: center, radius: radius)
        guard clipped.changed else { return .unchanged }

        let inverse = transform.inverse()
        let primitives = clipped.fragments.compactMap { fragment -> CADPrimitive? in
            guard fragment.count >= 2 else { return nil }
            let localFragment = fragment.map { vertex -> PenStrokeVertex in
                var local = vertex
                local.position = inverse.transformPoint(vertex.position)
                return local
            }
            let storedFragment: [PenStrokeVertex]
            if stabilization.useSpline,
               let refit = PenStrokeSplineFitter.fit(
                vertices: localFragment,
                settings: stabilization,
                simplifyInput: true) {
                storedFragment = refit.fitVertices
            } else {
                storedFragment = localFragment
            }
            guard storedFragment.count >= 2 else { return nil }
            return .penStroke(
                vertices: storedFragment,
                baseLineWeight: baseLineWeight,
                color: color)
        }
        return .replaced(primitives)
    }

    private struct PenClipResult {
        var fragments: [[PenStrokeVertex]]
        var changed: Bool
    }

    private static func clipPenVerticesOutsideCircle(
        _ vertices: [PenStrokeVertex],
        center: Vector3,
        radius: Double
    ) -> PenClipResult {
        guard vertices.count >= 2 else { return PenClipResult(fragments: [], changed: false) }
        var fragments: [[PenStrokeVertex]] = []
        var current: [PenStrokeVertex] = []
        var changed = false

        func flush() {
            if current.count >= 2 { fragments.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        for index in 0..<(vertices.count - 1) {
            let first = vertices[index]
            let second = vertices[index + 1]
            let clipped = outsideParameterRanges(
                from: first.position, to: second.position,
                center: center, radius: radius)
            changed = changed || clipped.changed

            if clipped.ranges.isEmpty {
                flush()
                continue
            }

            for rangeIndex in clipped.ranges.indices {
                let range = clipped.ranges[rangeIndex]
                let a = interpolate(first, second, t: range.0)
                let b = interpolate(first, second, t: range.1)

                if let last = current.last, last.position.distance(to: a.position) <= 1e-8 {
                    if last.position.distance(to: b.position) > 1e-10 { current.append(b) }
                } else {
                    flush()
                    current = [a]
                    if a.position.distance(to: b.position) > 1e-10 { current.append(b) }
                }

                if rangeIndex + 1 < clipped.ranges.count { flush() }
            }
        }
        flush()
        return PenClipResult(fragments: fragments, changed: changed)
    }

    private static func interpolate(
        _ first: PenStrokeVertex,
        _ second: PenStrokeVertex,
        t: Double
    ) -> PenStrokeVertex {
        let clamped = max(0.0, min(1.0, t))
        let rotationDelta = shortestAngleDelta(second.rotation, first.rotation)
        return PenStrokeVertex(
            position: Vector3(
                x: first.position.x + (second.position.x - first.position.x) * clamped,
                y: first.position.y + (second.position.y - first.position.y) * clamped,
                z: first.position.z + (second.position.z - first.position.z) * clamped),
            pressure: first.pressure + (second.pressure - first.pressure) * clamped,
            xtilt: first.xtilt + (second.xtilt - first.xtilt) * clamped,
            ytilt: first.ytilt + (second.ytilt - first.ytilt) * clamped,
            rotation: first.rotation + rotationDelta * clamped)
    }

    // MARK: - Generic tessellated outlines

    private static func eraseTessellatedPath(
        localPoints: [Vector3],
        color: ColorRGBA?,
        transform: Transform3D,
        center: Vector3,
        radius: Double
    ) -> PrimitiveResult {
        guard localPoints.count >= 2 else { return .unchanged }
        let worldPoints = localPoints.map { transform.transformPoint($0) }
        let clipped = clipPolylineOutsideCircle(worldPoints, center: center, radius: radius)
        guard clipped.changed else { return .unchanged }

        let inverse = transform.inverse()
        let replacements = clipped.fragments.compactMap { fragment -> CADPrimitive? in
            let local = fragment.map { inverse.transformPoint($0) }
            guard local.count >= 2 else { return nil }
            if local.count == 2 {
                return .line(start: local[0], end: local[1], color: color)
            }
            return .polyline(path: CADPolyline(points: local), color: color)
        }
        return .replaced(replacements)
    }

    private struct PolylineClipResult {
        var fragments: [[Vector3]]
        var changed: Bool
    }

    private static func clipPolylineOutsideCircle(
        _ points: [Vector3],
        center: Vector3,
        radius: Double
    ) -> PolylineClipResult {
        guard points.count >= 2 else { return PolylineClipResult(fragments: [], changed: false) }
        var fragments: [[Vector3]] = []
        var current: [Vector3] = []
        var changed = false

        func flush() {
            if current.count >= 2 { fragments.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        for index in 0..<(points.count - 1) {
            let clipped = outsidePieces(
                from: points[index], to: points[index + 1],
                center: center, radius: radius)
            changed = changed || clipped.changed

            if clipped.pieces.isEmpty {
                flush()
                continue
            }

            for pieceIndex in clipped.pieces.indices {
                let piece = clipped.pieces[pieceIndex]
                if let last = current.last, last.distance(to: piece.0) <= 1e-8 {
                    if last.distance(to: piece.1) > 1e-10 { current.append(piece.1) }
                } else {
                    flush()
                    current = [piece.0]
                    if piece.0.distance(to: piece.1) > 1e-10 { current.append(piece.1) }
                }
                if pieceIndex + 1 < clipped.pieces.count { flush() }
            }
        }
        flush()
        return PolylineClipResult(fragments: fragments, changed: changed)
    }

    // MARK: - Segment / circle clipping

    private struct SegmentPieces {
        var pieces: [(Vector3, Vector3)]
        var changed: Bool
    }

    private struct ParameterRanges {
        var ranges: [(Double, Double)]
        var changed: Bool
    }

    private static func outsidePieces(
        from start: Vector3,
        to end: Vector3,
        center: Vector3,
        radius: Double
    ) -> SegmentPieces {
        let ranges = outsideParameterRanges(from: start, to: end, center: center, radius: radius)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let pieces = ranges.ranges.map { range in
            (
                Vector3(x: start.x + dx * range.0, y: start.y + dy * range.0, z: start.z + dz * range.0),
                Vector3(x: start.x + dx * range.1, y: start.y + dy * range.1, z: start.z + dz * range.1)
            )
        }
        return SegmentPieces(pieces: pieces, changed: ranges.changed)
    }

    private static func outsideParameterRanges(
        from start: Vector3,
        to end: Vector3,
        center: Vector3,
        radius: Double
    ) -> ParameterRanges {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let fx = start.x - center.x
        let fy = start.y - center.y
        let a = dx * dx + dy * dy
        guard a > 1e-18 else {
            let inside = distanceXY(start, center) < radius
            return ParameterRanges(ranges: inside ? [] : [(0, 1)], changed: inside)
        }

        let b = 2.0 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4.0 * a * c

        var cuts: [Double] = [0, 1]
        if discriminant > 1e-14 {
            let root = sqrt(discriminant)
            let t0 = (-b - root) / (2.0 * a)
            let t1 = (-b + root) / (2.0 * a)
            if t0 > 1e-10 && t0 < 1.0 - 1e-10 { cuts.append(t0) }
            if t1 > 1e-10 && t1 < 1.0 - 1e-10 { cuts.append(t1) }
        } else if abs(discriminant) <= 1e-14 {
            let t = -b / (2.0 * a)
            if t > 1e-10 && t < 1.0 - 1e-10 { cuts.append(t) }
        }
        cuts.sort()

        var ranges: [(Double, Double)] = []
        var changed = false
        for index in 0..<(cuts.count - 1) {
            let t0 = cuts[index]
            let t1 = cuts[index + 1]
            guard t1 - t0 > 1e-12 else { continue }
            let mid = (t0 + t1) * 0.5
            let point = Vector3(
                x: start.x + dx * mid,
                y: start.y + dy * mid,
                z: start.z + (end.z - start.z) * mid)
            if distanceXY(point, center) < radius {
                changed = true
            } else {
                ranges.append((t0, t1))
            }
        }

        // A tangent contact has zero erased length and should not fragment geometry.
        if !changed { return ParameterRanges(ranges: [(0, 1)], changed: false) }
        return ParameterRanges(ranges: ranges, changed: true)
    }

    private static func deduplicatedParameters(_ values: [Double], range: Double) -> [Double] {
        let tolerance = max(1e-10, abs(range) * 1e-8)
        let sorted = values.sorted()
        var result: [Double] = []
        for value in sorted {
            if let last = result.last, abs(last - value) <= tolerance { continue }
            result.append(value)
        }
        return result
    }

    @inline(__always)
    private static func distanceXY(_ first: Vector3, _ second: Vector3) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private static func shortestAngleDelta(_ target: Double, _ source: Double) -> Double {
        var delta = target - source
        while delta > 180.0 { delta -= 360.0 }
        while delta < -180.0 { delta += 360.0 }
        return delta
    }
}
