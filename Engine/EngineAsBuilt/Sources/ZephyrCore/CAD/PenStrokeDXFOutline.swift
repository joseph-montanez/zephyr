import Foundation

// =========================================================================
// MARK: - PenStrokeDXFOutlineBuilder
//
// Converts Zephyr's pressure/tilt-aware pen centerline into a closed model-space
// boundary ring for DXF export. The ring is used as the internal polyline loop of
// a SOLID HATCH, so thickness is represented by filled geometry rather than lineweight.
// =========================================================================

public enum PenStrokeDXFOutlineBuilder {
    /// Build the world-space closed outline for a pen stroke.
    ///
    /// Widths are converted from the brush's millimeter units into the drawing's
    /// base unit, then scaled exactly like the on-screen geometric pen renderer.
    /// The returned ring does not repeat its first point; the HATCH polyline loop
    /// closes it implicitly.
    public static func outline(
        vertices: [PenStrokeVertex],
        baseLineWeight: Double,
        xdata: [String: XDataValue],
        transform: Transform3D,
        unitScaleFromMM: Double
    ) -> [Vector3]? {
        guard vertices.count >= 2 else { return nil }

        let brush = PenStrokeBrushSettings.from(
            xdata: xdata,
            fallbackBaseLineWeight: baseLineWeight)
        let stabilization = PenStrokeStabilizationSettings.from(xdata: xdata)

        let planarScale = (abs(transform.scale.x) + abs(transform.scale.y)) * 0.5
        let geometryScale = planarScale.isFinite && planarScale > 1e-12
            ? planarScale
            : 1.0
        let widthScale = max(1e-12, unitScaleFromMM) * geometryScale

        let sourceVertices = vertices.map { vertex in
            PenStrokeVertex(
                position: transform.transformPoint(vertex.position),
                pressure: vertex.pressure,
                xtilt: vertex.xtilt,
                ytilt: vertex.ytilt,
                rotation: vertex.rotation)
        }

        var pathVertices = sourceVertices
        if stabilization.useSpline,
           let fit = PenStrokeSplineFitter.fit(
                vertices: vertices,
                settings: stabilization),
           fit.controlVertices.count >= 2 {
            let worldControls = fit.controlVertices.map {
                transform.transformPoint($0.position)
            }
            let diagonal = boundingDiagonal(worldControls)
            let maximumWidth = max(brush.maxLineWeight * widthScale, 1e-9)
            // Export more accurately than the viewport needs, but keep pathological
            // tablet strokes bounded so the DXF does not explode in size.
            let chordTolerance = max(
                1e-7,
                min(maximumWidth * 0.025, max(diagonal / 3000.0, 1e-7)))
            var positions = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: fit.degree,
                knots: fit.knots,
                controlPoints: worldControls,
                weights: fit.weights,
                chordTolerance: chordTolerance,
                maxDepth: 10,
                maxSegments: 2048)
            if positions.count < 2 {
                positions = NURBSEvaluator.evaluateByKnotSpans(
                    degree: fit.degree,
                    knots: fit.knots,
                    controlPoints: worldControls,
                    weights: fit.weights,
                    segmentsPerSpan: 12)
            }
            if positions.count >= 2 {
                pathVertices = PenStrokeSplineFitter.interpolatedVertices(
                    source: sourceVertices,
                    positions: positions)
            }
        }

        pathVertices = removeConsecutiveDuplicates(pathVertices)
        guard pathVertices.count >= 2 else { return nil }

        let segmentCount = pathVertices.count - 1
        var normals = [Vector3](repeating: .zero, count: segmentCount)
        var halfWidths = [Double](repeating: 0.0, count: segmentCount)

        for index in 0..<segmentCount {
            let first = pathVertices[index]
            let second = pathVertices[index + 1]
            let dx = second.position.x - first.position.x
            let dy = second.position.y - first.position.y
            let length = hypot(dx, dy)
            guard length > 1e-12 else { continue }

            normals[index] = Vector3(x: -dy / length, y: dx / length, z: 0)
            let angle = atan2(dy, dx)
            halfWidths[index] = max(
                1e-9,
                brush.lineWeight(
                    from: first,
                    to: second,
                    segmentAngle: angle) * widthScale * 0.5)
        }

        // Any zero-length segment that survived numerical cleanup inherits the
        // nearest valid normal/width instead of punching a hole in the outline.
        repairDegenerateSegments(normals: &normals, halfWidths: &halfWidths)

        var left = [Vector3]()
        var right = [Vector3]()
        left.reserveCapacity(pathVertices.count)
        right.reserveCapacity(pathVertices.count)

        for index in pathVertices.indices {
            let center = pathVertices[index].position
            let width: Double
            let offsetDirection: Vector3

            if index == 0 {
                width = halfWidths[0]
                offsetDirection = normals[0]
            } else if index == pathVertices.count - 1 {
                width = halfWidths[segmentCount - 1]
                offsetDirection = normals[segmentCount - 1]
            } else {
                width = (halfWidths[index - 1] + halfWidths[index]) * 0.5
                offsetDirection = joinedNormal(
                    previous: normals[index - 1],
                    next: normals[index],
                    halfWidth: width)
            }

            // joinedNormal encodes miter length in its magnitude. End normals are
            // unit length and therefore use the ordinary half width.
            let offset: Vector3
            if index == 0 || index == pathVertices.count - 1 {
                offset = offsetDirection * width
            } else {
                offset = offsetDirection
            }

            left.append(center + offset)
            right.append(center - offset)
        }

        guard left.count >= 2, right.count == left.count else { return nil }

        // Use rounded end caps so the polygon matches the freehand brush rather
        // than ending in visibly square DXF caps.
        let capSegments = 8
        var outline = left
        outline.reserveCapacity(left.count + right.count + capSegments * 2)

        let endCenter = pathVertices[pathVertices.count - 1].position
        let endNormal = normals[segmentCount - 1]
        let endRadius = halfWidths[segmentCount - 1]
        appendCap(
            center: endCenter,
            radius: endRadius,
            startAngle: atan2(endNormal.y, endNormal.x),
            sweep: -.pi,
            segments: capSegments,
            includeFinal: true,
            to: &outline)

        if right.count > 1 {
            for index in stride(from: right.count - 2, through: 0, by: -1) {
                outline.append(right[index])
            }
        }

        let startCenter = pathVertices[0].position
        let startNormal = normals[0]
        let startRadius = halfWidths[0]
        // Start from the right edge and wrap around the back of the stroke. The
        // final left-edge point is omitted because the closed polyline supplies it.
        appendCap(
            center: startCenter,
            radius: startRadius,
            startAngle: atan2(-startNormal.y, -startNormal.x),
            sweep: -.pi,
            segments: capSegments,
            includeFinal: false,
            to: &outline)

        return cleanRing(outline)
    }

    private static func boundingDiagonal(_ points: [Vector3]) -> Double {
        guard var minimum = points.first else { return 1.0 }
        var maximum = minimum
        for point in points.dropFirst() {
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
        }
        return max(hypot(maximum.x - minimum.x, maximum.y - minimum.y), 1e-9)
    }

    private static func removeConsecutiveDuplicates(
        _ vertices: [PenStrokeVertex]
    ) -> [PenStrokeVertex] {
        guard !vertices.isEmpty else { return [] }
        let diagonal = boundingDiagonal(vertices.map(\.position))
        let epsilon = max(1e-10, diagonal * 1e-10)
        var result: [PenStrokeVertex] = []
        result.reserveCapacity(vertices.count)
        for vertex in vertices {
            if let last = result.last,
               last.position.distance(to: vertex.position) <= epsilon {
                result[result.count - 1] = vertex
            } else {
                result.append(vertex)
            }
        }
        return result
    }

    /// Return an offset vector for a mitered join. The magnitude is the actual
    /// miter distance; it is clamped to avoid spikes at sharp reversals.
    private static func joinedNormal(
        previous: Vector3,
        next: Vector3,
        halfWidth: Double
    ) -> Vector3 {
        let sum = previous + next
        let length = hypot(sum.x, sum.y)
        guard length > 1e-9 else { return next * halfWidth }

        let unit = Vector3(x: sum.x / length, y: sum.y / length, z: 0)
        let denominator = abs(unit.x * next.x + unit.y * next.y)
        let unclamped = denominator > 1e-6 ? halfWidth / denominator : halfWidth
        let distance = min(unclamped, halfWidth * 2.5)
        return unit * distance
    }

    private static func repairDegenerateSegments(
        normals: inout [Vector3],
        halfWidths: inout [Double]
    ) {
        guard !normals.isEmpty else { return }
        for index in normals.indices where normals[index].magnitude <= 1e-12 {
            var replacement: Int?
            if index > 0 {
                for candidate in stride(from: index - 1, through: 0, by: -1)
                    where normals[candidate].magnitude > 1e-12 {
                    replacement = candidate
                    break
                }
            }
            if replacement == nil, index + 1 < normals.count {
                for candidate in (index + 1)..<normals.count
                    where normals[candidate].magnitude > 1e-12 {
                    replacement = candidate
                    break
                }
            }
            if let replacement {
                normals[index] = normals[replacement]
                halfWidths[index] = halfWidths[replacement]
            } else {
                normals[index] = Vector3(x: 0, y: 1, z: 0)
                halfWidths[index] = max(halfWidths[index], 1e-9)
            }
        }
    }

    private static func appendCap(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        sweep: Double,
        segments: Int,
        includeFinal: Bool,
        to points: inout [Vector3]
    ) {
        guard segments > 0 else { return }
        let upper = includeFinal ? segments : max(0, segments - 1)
        guard upper >= 1 else { return }
        for step in 1...upper {
            let t = Double(step) / Double(segments)
            let angle = startAngle + sweep * t
            points.append(Vector3(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius,
                z: center.z))
        }
    }

    private static func cleanRing(_ points: [Vector3]) -> [Vector3]? {
        guard points.count >= 3 else { return nil }
        let diagonal = boundingDiagonal(points)
        let epsilon = max(1e-10, diagonal * 1e-10)
        var result: [Vector3] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, last.distance(to: point) <= epsilon { continue }
            result.append(point)
        }
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           first.distance(to: last) <= epsilon {
            result.removeLast()
        }
        return result.count >= 3 ? result : nil
    }
}
