import Foundation

// =========================================================================
// MARK: - BlockPreview
//
// Lightweight vector thumbnail for one block definition, shared by the
// Blocks palette grid and the INSERT canvas ghost.
//
// Coordinates stay in **block-local space** (never normalized): the palette
// cell fits `bounds` uniformly (aspect preserved) while the canvas ghost
// multiplies segments directly by the live insertion transform, keeping the
// true insertion origin and world size for free.
//
// `segments` is decimated for ImGui draw-list budgets: at most
// `maxSegments` (default 400, so a 30-cell grid stays under ~12k lines)
// with sub-pixel detail dropped against a 96px reference.
// =========================================================================

public struct BlockPreview: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public var x0: Float
        public var y0: Float
        public var x1: Float
        public var y1: Float

        public init(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
            x0 = a.x; y0 = a.y; x1 = b.x; y1 = b.y
        }

        public var length: Float {
            hypot(x1 - x0, y1 - y0)
        }
    }

    /// Flat line segments in block-local XY.
    public var segments: [Segment]
    /// AABB of the source geometry in block-local XY.
    public var boundsMin: SIMD2<Float>
    public var boundsMax: SIMD2<Float>

    public var isEmpty: Bool { segments.isEmpty }
    public var width: Float { boundsMax.x - boundsMin.x }
    public var height: Float { boundsMax.y - boundsMin.y }

    public init(
        segments: [Segment] = [],
        boundsMin: SIMD2<Float> = SIMD2<Float>(0, 0),
        boundsMax: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) {
        self.segments = segments
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }

    // MARK: - Build

    /// Flattens block-local primitives to capped 2D segments (Z dropped).
    public static func build(
        geometry: [CADPrimitive],
        maxSegments: Int = 400,
        referencePixels: Double = 96
    ) -> BlockPreview {
        var segments: [Segment] = []
        segments.reserveCapacity(min(maxSegments, max(geometry.count * 2, 16)))
        var minX = Float.infinity
        var minY = Float.infinity
        var maxX = -Float.infinity
        var maxY = -Float.infinity

        func emit(_ a: Vector3, _ b: Vector3) {
            let s = Segment(SIMD2<Float>(Float(a.x), Float(a.y)),
                            SIMD2<Float>(Float(b.x), Float(b.y)))
            segments.append(s)
            minX = min(minX, min(s.x0, s.x1)); minY = min(minY, min(s.y0, s.y1))
            maxX = max(maxX, max(s.x0, s.x1)); maxY = max(maxY, max(s.y0, s.y1))
        }

        func emitPath(_ points: [Vector3], closed: Bool) {
            guard points.count >= 2 else { return }
            for i in 0..<(points.count - 1) { emit(points[i], points[i + 1]) }
            if closed { emit(points[points.count - 1], points[0]) }
        }

        func emitPolyline(_ path: CADPolyline) {
            let vs = path.vertices
            guard vs.count >= 2 else { return }
            let count = path.isClosed ? vs.count : vs.count - 1
            for i in 0..<count {
                let a = vs[i]
                let b = vs[(i + 1) % vs.count]
                if abs(a.bulge) > 1e-12 {
                    var prev = a.position
                    let subs = 8
                    for s in 1...subs {
                        let p = path.point(onSegment: i, t: Double(s) / Double(subs))
                        emit(prev, p)
                        prev = p
                    }
                } else {
                    emit(a.position, b.position)
                }
            }
        }

        for primitive in geometry {
            switch primitive {
            case .point(let position, _):
                emit(position, position)
            case .line(let start, let end, _):
                emit(start, end)
            case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
                emitPath([
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                ], closed: true)
            case .polygon(let points, _), .fillPolygon(let points, _):
                emitPath(points, closed: true)
            case .polyline(let path, _):
                emitPolyline(path)
            case .fillComplexPolygon(let outer, _, _):
                emitPath(outer, closed: true)
            case .gradient(let outer, _, _, _, _, _):
                emitPath(outer, closed: true)
            case .circle(let center, let radius, _):
                guard radius.isFinite, radius > 0 else { continue }
                let n = 48
                var pts: [Vector3] = []
                for i in 0..<n {
                    let a = 2.0 * Double.pi * Double(i) / Double(n)
                    pts.append(Vector3(
                        x: center.x + cos(a) * radius,
                        y: center.y + sin(a) * radius, z: center.z))
                }
                emitPath(pts, closed: true)
            case .arc(let center, let radius, let startAngle, let endAngle, _):
                guard radius.isFinite, radius > 0 else { continue }
                var span = endAngle - startAngle
                if span < 0 { span += 2.0 * Double.pi }
                guard span > 1e-12 else { continue }
                let n = min(48, max(2, Int((span / (Double.pi / 24.0)).rounded(.up))))
                var prev = Vector3(
                    x: center.x + cos(startAngle) * radius,
                    y: center.y + sin(startAngle) * radius, z: center.z)
                for i in 1...n {
                    let a = startAngle + span * Double(i) / Double(n)
                    let cur = Vector3(
                        x: center.x + cos(a) * radius,
                        y: center.y + sin(a) * radius, z: center.z)
                    emit(prev, cur)
                    prev = cur
                }
            case .spline(let controlPoints, let knots, let degree, let weights, _):
                var pts = NURBSEvaluator.evaluate(
                    degree: degree, knots: knots,
                    controlPoints: controlPoints, weights: weights, segments: 24)
                if pts.count < 2 { pts = controlPoints }
                emitPath(pts, closed: false)
            case .penStroke(let vertices, _, _):
                emitPath(vertices.map(\.position), closed: false)
            case .ellipse(let center, let majorAxis, let minorRatio, _):
                let mx = majorAxis.x, my = majorAxis.y
                let len = hypot(mx, my)
                guard len > 1e-12, minorRatio.isFinite else { continue }
                let px = -my / len, py = mx / len
                let n = 48
                var pts: [Vector3] = []
                for i in 0..<n {
                    let a = 2.0 * Double.pi * Double(i) / Double(n)
                    pts.append(Vector3(
                        x: center.x + cos(a) * mx + sin(a) * minorRatio * px,
                        y: center.y + cos(a) * my + sin(a) * minorRatio * py,
                        z: center.z))
                }
                emitPath(pts, closed: true)
            case .hatch(let boundary, _, _, _, _, _):
                emitPath(boundary, closed: true)
            case .hatchPath(let boundary, let holes, _, _, _, _, _):
                emitPolyline(boundary)
                for hole in holes { emitPolyline(hole) }
            case .image(let insertion, let uAxis, let vAxis, _, _, _):
                let p1 = insertion
                let p2 = Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z)
                let p3 = Vector3(x: p2.x + vAxis.x, y: p2.y + vAxis.y, z: p2.z)
                let p4 = Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z)
                emitPath([p1, p2, p3, p4], closed: true)
            case .text, .ray, .xline, .table:
                continue
            }
            if segments.count >= maxSegments * 4 { break }
        }

        guard !segments.isEmpty,
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite
        else { return BlockPreview() }

        // Drop sub-pixel detail against a 96px reference, then stride-cap.
        // Degenerate point markers are exempt from dropping.
        let span = max(maxX - minX, maxY - minY)
        if span > 0 {
            let threshold = Float(span / Float(referencePixels))
            if threshold > 0 {
                let kept = segments.filter { $0.length == 0 || $0.length >= threshold }
                if !kept.isEmpty { segments = kept }
            }
        }
        if segments.count > maxSegments {
            let stride = Double(segments.count) / Double(maxSegments)
            var capped: [Segment] = []
            capped.reserveCapacity(maxSegments)
            var next = 0.0
            for s in segments {
                if Double(capped.count) >= next {
                    capped.append(s)
                    next += stride
                }
            }
            segments = capped
        }

        return BlockPreview(
            segments: segments,
            boundsMin: SIMD2<Float>(minX, minY),
            boundsMax: SIMD2<Float>(maxX, maxY))
    }
}
