import Foundation
import SwiftSDL

public enum CADRenderClipper {
    public struct TexturedVertex: Sendable {
        public var point: SDL_FPoint
        public var uv: SDL_FPoint
    }

    public struct TexturedTriangle: Sendable {
        public var a: TexturedVertex
        public var b: TexturedVertex
        public var c: TexturedVertex
    }

    public static func clip(
        specs: [PrimitiveSpec],
        polygon: [SDL_FPoint],
        inverted: Bool
    ) -> [PrimitiveSpec] {
        guard polygon.count >= 3 else { return specs }
        var output: [PrimitiveSpec] = []
        for spec in specs {
            switch spec.type {
            case .point:
                if let point = spec.points.first, inverted != contains(point, polygon: polygon) {
                    output.append(spec)
                }
            case .points:
                for point in spec.points where inverted != contains(point, polygon: polygon) {
                    output.append(copy(spec, type: .point, points: [point]))
                }
            case .line:
                if spec.isHatchLine {
                    var index = 0
                    while index + 1 < spec.points.count {
                        for pair in clippedSegment(
                            spec.points[index], spec.points[index + 1],
                            polygon: polygon, inverted: inverted
                        ) {
                            output.append(copy(spec, points: [pair.0, pair.1]))
                        }
                        index += 2
                    }
                } else if spec.points.count >= 2 {
                    for pair in clippedSegment(spec.points[0], spec.points[1], polygon: polygon, inverted: inverted) {
                        output.append(copy(spec, points: [pair.0, pair.1]))
                    }
                }
            case .lines:
                guard spec.points.count >= 2 else { continue }
                for i in 0..<(spec.points.count - 1) {
                    for pair in clippedSegment(spec.points[i], spec.points[i + 1], polygon: polygon, inverted: inverted) {
                        output.append(copy(spec, type: .line, points: [pair.0, pair.1], corners: []))
                    }
                }
            case .rect:
                if spec.corners.count >= 3 {
                    let path = spec.corners + [spec.corners[0]]
                    for i in 0..<(path.count - 1) {
                        for pair in clippedSegment(path[i], path[i + 1], polygon: polygon, inverted: inverted) {
                            output.append(copy(spec, type: .line, points: [pair.0, pair.1], corners: []))
                        }
                    }
                } else {
                    for rect in spec.rects {
                        let path = [
                            SDL_FPoint(x: rect.x, y: rect.y),
                            SDL_FPoint(x: rect.x + rect.w, y: rect.y),
                            SDL_FPoint(x: rect.x + rect.w, y: rect.y + rect.h),
                            SDL_FPoint(x: rect.x, y: rect.y + rect.h),
                            SDL_FPoint(x: rect.x, y: rect.y)
                        ]
                        for i in 0..<(path.count - 1) {
                            for pair in clippedSegment(path[i], path[i + 1], polygon: polygon, inverted: inverted) {
                                output.append(copy(spec, type: .line, points: [pair.0, pair.1], rects: [], corners: []))
                            }
                        }
                    }
                }
            case .fillRect, .fillRects:
                for triangle in sourceTriangles(spec) {
                    let clipped = clipTriangle(triangle, polygon: polygon, inverted: inverted)
                    for poly in clipped where poly.count >= 3 {
                        output.append(copy(spec, type: .fillRect, points: [], rects: [], corners: triangulateFan(poly)))
                    }
                }
            case .rects:
                for rect in spec.rects {
                    let p = [
                        SDL_FPoint(x: rect.x, y: rect.y),
                        SDL_FPoint(x: rect.x + rect.w, y: rect.y),
                        SDL_FPoint(x: rect.x + rect.w, y: rect.y + rect.h),
                        SDL_FPoint(x: rect.x, y: rect.y + rect.h),
                        SDL_FPoint(x: rect.x, y: rect.y)
                    ]
                    for i in 0..<(p.count - 1) {
                        for pair in clippedSegment(p[i], p[i + 1], polygon: polygon, inverted: inverted) {
                            output.append(copy(spec, type: .line, points: [pair.0, pair.1], rects: [], corners: []))
                        }
                    }
                }
            }
        }
        return output
    }

    public static func texturedTriangles(
        quad: [SDL_FPoint],
        polygon: [SDL_FPoint],
        inverted: Bool
    ) -> [TexturedTriangle] {
        guard quad.count == 4 else { return [] }
        let source = [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]]
        var result: [TexturedTriangle] = []
        for triangle in source {
            for poly in clipTriangle(triangle, polygon: polygon, inverted: inverted) where poly.count >= 3 {
                for i in 1..<(poly.count - 1) {
                    let points = [poly[0], poly[i], poly[i + 1]]
                    result.append(TexturedTriangle(
                        a: TexturedVertex(point: points[0], uv: uv(for: points[0], quad: quad)),
                        b: TexturedVertex(point: points[1], uv: uv(for: points[1], quad: quad)),
                        c: TexturedVertex(point: points[2], uv: uv(for: points[2], quad: quad))))
                }
            }
        }
        return result
    }

    private static func copy(
        _ spec: PrimitiveSpec,
        type: PrimitiveType? = nil,
        points: [SDL_FPoint]? = nil,
        rects: [SDL_FRect]? = nil,
        corners: [SDL_FPoint]? = nil
    ) -> PrimitiveSpec {
        PrimitiveSpec(
            type: type ?? spec.type,
            points: points ?? spec.points,
            rects: rects ?? spec.rects,
            corners: corners ?? spec.corners,
            z: spec.z,
            color: spec.color,
            lineWeight: spec.lineWeight,
            geomWidth: spec.geomWidth,
            isHatchLine: spec.isHatchLine,
            hatchSpacing: spec.hatchSpacing,
            gradientData: spec.gradientData,
            usesViewportBackground: spec.usesViewportBackground)
    }

    private static func sourceTriangles(_ spec: PrimitiveSpec) -> [[SDL_FPoint]] {
        if spec.corners.count >= 3 {
            if spec.corners.count % 3 == 0 {
                return stride(from: 0, to: spec.corners.count, by: 3).map {
                    [spec.corners[$0], spec.corners[$0 + 1], spec.corners[$0 + 2]]
                }
            }
            return stride(from: 1, to: spec.corners.count - 1, by: 1).map {
                [spec.corners[0], spec.corners[$0], spec.corners[$0 + 1]]
            }
        }
        return spec.rects.flatMap { rect -> [[SDL_FPoint]] in
            let a = SDL_FPoint(x: rect.x, y: rect.y)
            let b = SDL_FPoint(x: rect.x + rect.w, y: rect.y)
            let c = SDL_FPoint(x: rect.x + rect.w, y: rect.y + rect.h)
            let d = SDL_FPoint(x: rect.x, y: rect.y + rect.h)
            return [[a, b, c], [a, c, d]]
        }
    }

    private static func triangulateFan(_ polygon: [SDL_FPoint]) -> [SDL_FPoint] {
        guard polygon.count >= 3 else { return [] }
        var result: [SDL_FPoint] = []
        for i in 1..<(polygon.count - 1) {
            result.append(polygon[0])
            result.append(polygon[i])
            result.append(polygon[i + 1])
        }
        return result
    }

    private static func clipTriangle(
        _ triangle: [SDL_FPoint],
        polygon: [SDL_FPoint],
        inverted: Bool
    ) -> [[SDL_FPoint]] {
        let clipTriangles = triangulate(polygon)
        if inverted {
            var pieces = [triangle]
            for clipTriangle in clipTriangles {
                pieces = pieces.flatMap { subtractConvex($0, clip: clipTriangle) }
                if pieces.isEmpty { break }
            }
            return pieces
        }
        return clipTriangles.compactMap {
            let value = intersectConvex(triangle, clip: $0)
            return value.count >= 3 ? value : nil
        }
    }

    private static func triangulate(_ polygon: [SDL_FPoint]) -> [[SDL_FPoint]] {
        var data: [Float] = []
        for p in polygon { data.append(p.x); data.append(p.y) }
        let indices = earcut(data: data, holeIndices: [], dim: 2)
        if indices.count >= 3 {
            return stride(from: 0, to: indices.count, by: 3).map {
                [polygon[indices[$0]], polygon[indices[$0 + 1]], polygon[indices[$0 + 2]]]
            }
        }
        return stride(from: 1, to: polygon.count - 1, by: 1).map {
            [polygon[0], polygon[$0], polygon[$0 + 1]]
        }
    }

    private static func intersectConvex(_ subject: [SDL_FPoint], clip: [SDL_FPoint]) -> [SDL_FPoint] {
        var output = subject
        let orientation = signedArea(clip) >= 0 ? Float(1) : Float(-1)
        for i in clip.indices {
            let a = clip[i]
            let b = clip[(i + 1) % clip.count]
            let input = output
            output = []
            guard !input.isEmpty else { break }
            var previous = input.last!
            var previousInside = side(previous, a, b) * orientation >= -1e-5
            for current in input {
                let currentInside = side(current, a, b) * orientation >= -1e-5
                if currentInside != previousInside, let p = lineIntersection(previous, current, a, b) {
                    output.append(p)
                }
                if currentInside { output.append(current) }
                previous = current
                previousInside = currentInside
            }
        }
        return deduplicated(output)
    }

    private static func subtractConvex(_ subject: [SDL_FPoint], clip: [SDL_FPoint]) -> [[SDL_FPoint]] {
        var insidePieces = [subject]
        var outsidePieces: [[SDL_FPoint]] = []
        let orientation = signedArea(clip) >= 0 ? Float(1) : Float(-1)
        for i in clip.indices {
            let a = clip[i]
            let b = clip[(i + 1) % clip.count]
            var nextInside: [[SDL_FPoint]] = []
            for piece in insidePieces {
                let split = splitPolygon(piece, a: a, b: b, orientation: orientation)
                if split.inside.count >= 3 { nextInside.append(split.inside) }
                if split.outside.count >= 3 { outsidePieces.append(split.outside) }
            }
            insidePieces = nextInside
            if insidePieces.isEmpty { break }
        }
        return outsidePieces
    }

    private static func splitPolygon(
        _ polygon: [SDL_FPoint],
        a: SDL_FPoint,
        b: SDL_FPoint,
        orientation: Float
    ) -> (inside: [SDL_FPoint], outside: [SDL_FPoint]) {
        var inside: [SDL_FPoint] = []
        var outside: [SDL_FPoint] = []
        guard let last = polygon.last else { return ([], []) }
        var previous = last
        var previousInside = side(previous, a, b) * orientation >= -1e-5
        for current in polygon {
            let currentInside = side(current, a, b) * orientation >= -1e-5
            if currentInside != previousInside, let p = lineIntersection(previous, current, a, b) {
                inside.append(p)
                outside.append(p)
            }
            if currentInside { inside.append(current) } else { outside.append(current) }
            previous = current
            previousInside = currentInside
        }
        return (deduplicated(inside), deduplicated(outside))
    }

    private static func clippedSegment(
        _ a: SDL_FPoint,
        _ b: SDL_FPoint,
        polygon: [SDL_FPoint],
        inverted: Bool
    ) -> [(SDL_FPoint, SDL_FPoint)] {
        var values: [Float] = [0, 1]
        for i in polygon.indices {
            if let t = segmentIntersectionParameter(a, b, polygon[i], polygon[(i + 1) % polygon.count]) {
                values.append(t)
            }
        }
        values.sort()
        var unique: [Float] = []
        for value in values where unique.last.map({ abs($0 - value) > 1e-5 }) ?? true { unique.append(value) }
        var result: [(SDL_FPoint, SDL_FPoint)] = []
        for i in 0..<(unique.count - 1) {
            let t0 = unique[i]
            let t1 = unique[i + 1]
            guard t1 - t0 > 1e-6 else { continue }
            let mid = lerp(a, b, (t0 + t1) * 0.5)
            if inverted != contains(mid, polygon: polygon) {
                result.append((lerp(a, b, t0), lerp(a, b, t1)))
            }
        }
        return result
    }

    private static func contains(_ point: SDL_FPoint, polygon: [SDL_FPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) == 0 ? 1e-20 : (b.y - a.y)) + a.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func uv(for p: SDL_FPoint, quad: [SDL_FPoint]) -> SDL_FPoint {
        let o = quad[0]
        let u = SDL_FPoint(x: quad[1].x - o.x, y: quad[1].y - o.y)
        let v = SDL_FPoint(x: quad[3].x - o.x, y: quad[3].y - o.y)
        let d = u.x * v.y - u.y * v.x
        guard abs(d) > 1e-8 else { return SDL_FPoint(x: 0, y: 0) }
        let q = SDL_FPoint(x: p.x - o.x, y: p.y - o.y)
        return SDL_FPoint(x: (q.x * v.y - q.y * v.x) / d, y: (u.x * q.y - u.y * q.x) / d)
    }

    private static func signedArea(_ p: [SDL_FPoint]) -> Float {
        guard p.count >= 3 else { return 0 }
        var area: Float = 0
        for i in p.indices {
            let a = p[i]
            let b = p[(i + 1) % p.count]
            area += a.x * b.y - b.x * a.y
        }
        return area * 0.5
    }

    private static func side(_ p: SDL_FPoint, _ a: SDL_FPoint, _ b: SDL_FPoint) -> Float {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    private static func lineIntersection(_ p0: SDL_FPoint, _ p1: SDL_FPoint, _ a: SDL_FPoint, _ b: SDL_FPoint) -> SDL_FPoint? {
        let r = SDL_FPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let s = SDL_FPoint(x: b.x - a.x, y: b.y - a.y)
        let d = r.x * s.y - r.y * s.x
        guard abs(d) > 1e-8 else { return nil }
        let q = SDL_FPoint(x: a.x - p0.x, y: a.y - p0.y)
        let t = (q.x * s.y - q.y * s.x) / d
        return lerp(p0, p1, t)
    }

    private static func segmentIntersectionParameter(_ p0: SDL_FPoint, _ p1: SDL_FPoint, _ a: SDL_FPoint, _ b: SDL_FPoint) -> Float? {
        let r = SDL_FPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let s = SDL_FPoint(x: b.x - a.x, y: b.y - a.y)
        let d = r.x * s.y - r.y * s.x
        guard abs(d) > 1e-8 else { return nil }
        let q = SDL_FPoint(x: a.x - p0.x, y: a.y - p0.y)
        let t = (q.x * s.y - q.y * s.x) / d
        let u = (q.x * r.y - q.y * r.x) / d
        guard t > 1e-6, t < 1 - 1e-6, u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        return t
    }

    private static func lerp(_ a: SDL_FPoint, _ b: SDL_FPoint, _ t: Float) -> SDL_FPoint {
        SDL_FPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func deduplicated(_ points: [SDL_FPoint]) -> [SDL_FPoint] {
        var result: [SDL_FPoint] = []
        for point in points {
            if let last = result.last, hypotf(last.x - point.x, last.y - point.y) < 1e-5 { continue }
            result.append(point)
        }
        if result.count > 1, let first = result.first, let last = result.last,
           hypotf(first.x - last.x, first.y - last.y) < 1e-5 { result.removeLast() }
        return result
    }
}
