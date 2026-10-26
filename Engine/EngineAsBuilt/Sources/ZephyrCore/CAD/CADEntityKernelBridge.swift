import Foundation
import ZephyrKernel

// =========================================================================
// MARK: - CADEntityKernelBridge
//
// Zero-tessellation conversions between ZephyrCore geometry (Vector3,
// CADPolyline, CADPrimitive) and the ZephyrKernel analytical curves.
// All conversions are local-space; callers apply `entity.transform`
// before/after kernel solves (kernel math that needs world space
// transforms the lightweight Point2d values, never entity storage).
//
// Precision: bulge convention shared with CADPolyline (b = tan(sweep/4),
// zero threshold 1e-12 = KernelTolerance.bulgeZero).

// MARK: - Vector3 <-> Point2d

public extension Vector3 {
    @inlinable
    var point2d: Point2d {
        Point2d(x: x, y: y)
    }

    @inlinable
    init(_ pt: Point2d, z: Double = 0.0) {
        self.init(x: pt.x, y: pt.y, z: z)
    }
}

public extension Transform3D {
    /// True when the XY mapping is rotation/translation + uniform scale
    /// (mirror allowed). Only similarities map circular arcs to circular
    /// arcs, so only they may use the exact kernel trim/offset paths.
    var isSimilarity2D: Bool {
        let sx = scale.x, sy = scale.y
        guard sx > 1e-12, sy > 1e-12 else { return false }
        // Uniform XY scale (mirror = sign flip, still similar).
        guard abs(abs(sx) - abs(sy)) <= 1e-9 * max(abs(sx), abs(sy)) else { return false }
        // No XY/Z shear: columns 0,1 of rows 0,1 must be a scaled rotation,
        // and z must not leak into x/y.
        let axx = at(0, 0), axy = at(0, 1)
        let ayx = at(1, 0), ayy = at(1, 1)
        let dot = axx * axy + ayx * ayy
        let n0 = hypot(axx, ayx), n1 = hypot(axy, ayy)
        guard n0 > 1e-12, n1 > 1e-12 else { return false }
        guard abs(dot) <= 1e-9 * n0 * n1 else { return false }
        guard abs(at(0, 2)) <= 1e-12 && abs(at(1, 2)) <= 1e-12 else { return false }
        return true
    }

    /// Mirror (orientation-reversing) similarities negate bulge handedness.
    var reversesOrientation2D: Bool {
        // Determinant sign of the XY 2x2 block.
        (at(0, 0) * at(1, 1) - at(0, 1) * at(1, 0)) < 0
    }
}

// MARK: - CADPolyline <-> [PolySegment2d]

public extension CADPolyline {
    /// Exact kernel segments for every edge. Unlike
    /// TrimGeometryEngine.explode, this NEVER tessellates arcs: bulged
    /// edges become analytical Arc2d values.
    func toKernelSegments() -> [PolySegment2d] {
        guard vertices.count >= 2 else { return [] }
        let edgeCount = isClosed ? vertices.count : (vertices.count - 1)
        var segments: [PolySegment2d] = []
        segments.reserveCapacity(edgeCount)
        for i in 0..<edgeCount {
            let v0 = vertices[i]
            let v1 = vertices[(i + 1) % vertices.count]
            segments.append(PolySegment2d(
                index: i,
                start: v0.position.point2d,
                end: v1.position.point2d,
                bulge: v0.bulge,
                startWidth: v0.startWidth,
                endWidth: v0.endWidth
            ))
        }
        return segments
    }

    /// Rebuild a polyline from kernel segments, preserving bulges, widths,
    /// and every non-geometric field of `template` (hatch edges, linetype
    /// flags, handles...). `isClosed` is taken from the caller: when the
    /// kernel drops the closing edge (open trim result), pass false.
    static func fromKernelSegments(
        _ segments: [PolySegment2d],
        isClosed: Bool,
        template: CADPolyline
    ) -> CADPolyline {
        guard !segments.isEmpty else {
            var empty = template
            empty.vertices = []
            empty.isClosed = false
            return empty
        }
        // Segments are expected in chain order; vertices are the union of
        // segment starts plus the final end (open) — or starts only (closed).
        var verts: [CADPolylineVertex] = []
        verts.reserveCapacity(segments.count + (isClosed ? 0 : 1))
        for seg in segments.sorted(by: { $0.index < $1.index }) {
            verts.append(CADPolylineVertex(
                position: Vector3(seg.startPoint),
                bulge: seg.bulge,
                startWidth: seg.startWidth,
                endWidth: seg.endWidth
            ))
        }
        if !isClosed, let last = segments.max(by: { $0.index < $1.index }) {
            verts.append(CADPolylineVertex(
                position: Vector3(last.endPoint),
                bulge: 0.0,
                startWidth: last.endWidth,
                endWidth: last.endWidth
            ))
        }
        var poly = template
        poly.vertices = verts
        poly.isClosed = isClosed
        return poly
    }
}

// MARK: - CADPrimitive <-> Curve2d

public extension CADPrimitive {
    /// Local-space analytical curves for this primitive. Arcs, circles,
    /// ellipses, rays, xlines, and bulged polyline edges map exactly;
    /// polygon-like and text/hatch/pen types return [] so callers keep
    /// existing paths.
    func toKernelCurves() -> [Curve2d] {
        switch self {
        case .line(let start, let end, _):
            return [.line(LineSeg2d(start: start.point2d, end: end.point2d))]
        case .ray(let start, let direction, _):
            return [.ray(Ray2d(origin: start.point2d,
                               direction: Vec2d(x: direction.x, y: direction.y)))]
        case .xline(let point, let direction, _):
            return [.xline(XLine2d(origin: point.point2d,
                                   direction: Vec2d(x: direction.x, y: direction.y)))]
        case .circle(let center, let radius, _):
            return [.circle(Circle2d(center: center.point2d, radius: radius))]
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            return [.arc(Arc2d.fromDXFAngles(center: center.point2d, radius: radius,
                                             startAngle: startAngle, endAngle: endAngle))]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            return [.ellipse(Ellipse2d(center: center.point2d,
                                       majorAxis: Vec2d(x: majorAxis.x, y: majorAxis.y),
                                       minorRatio: minorRatio))]
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            return [.spline(Spline2d(controlPoints: controlPoints.map { $0.point2d },
                                     knots: knots, degree: degree, weights: weights))]
        case .polyline(let path, _):
            return path.toKernelSegments().map { .polySegment($0) }
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            let p0 = origin.point2d
            let p1 = Point2d(x: origin.x + size.x, y: origin.y)
            let p2 = Point2d(x: origin.x + size.x, y: origin.y + size.y)
            let p3 = Point2d(x: origin.x, y: origin.y + size.y)
            return [
                .line(LineSeg2d(start: p0, end: p1)),
                .line(LineSeg2d(start: p1, end: p2)),
                .line(LineSeg2d(start: p2, end: p3)),
                .line(LineSeg2d(start: p3, end: p0)),
            ]
        default:
            return []
        }
    }

    /// Rebuild a primitive from one kernel curve in the same space,
    /// preserving `source`'s color. Partial ellipses/splines return nil
    /// (not representable in-kind) so callers keep existing paths.
    static func fromKernelCurve(_ curve: Curve2d, preservingColorFrom source: CADPrimitive) -> CADPrimitive? {
        let color = kernelColor(of: source)
        switch curve {
        case .line(let seg):
            let z = lineZ(of: source)
            return .line(start: Vector3(seg.start, z: z), end: Vector3(seg.end, z: z), color: color)
        case .ray(let r):
            return .ray(start: Vector3(r.origin),
                        direction: Vector3(x: r.direction.x, y: r.direction.y, z: 0), color: color)
        case .arc(let arc):
            // DXF arcs are CCW: emit normalized positive sweep.
            var sweep = arc.sweep.truncatingRemainder(dividingBy: 2.0 * .pi)
            var start = arc.startAngle
            if sweep < 0 { sweep += 2.0 * .pi; start = arc.endAngle }
            let z = lineZ(of: source)
            return .arc(center: Vector3(arc.center, z: z), radius: arc.radius,
                        startAngle: start, endAngle: start + sweep, color: color)
        case .circle(let circle):
            let z = lineZ(of: source)
            return .circle(center: Vector3(circle.center, z: z), radius: circle.radius, color: color)
        case .polySegment(let seg):
            if case .polyline(let path, _) = source {
                let poly = CADPolyline.fromKernelSegments([seg], isClosed: false, template: path)
                return .polyline(path: poly, color: color)
            }
            switch seg.geometry {
            case .line(let l):
                let z = lineZ(of: source)
                return .line(start: Vector3(l.start, z: z), end: Vector3(l.end, z: z), color: color)
            case .arc(let a):
                var sweep = a.sweep.truncatingRemainder(dividingBy: 2.0 * .pi)
                var start = a.startAngle
                if sweep < 0 { sweep += 2.0 * .pi; start = a.endAngle }
                let z = lineZ(of: source)
                return .arc(center: Vector3(a.center, z: z), radius: a.radius,
                            startAngle: start, endAngle: start + sweep, color: color)
            }
        case .xline, .ellipse, .spline:
            return nil
        }
    }

    /// Color override carried on most primitive cases (mirrors
    /// TrimGeometryEngine.colorForPrimitive without MainActor isolation).
    private static func kernelColor(of primitive: CADPrimitive) -> ColorRGBA? {
        switch primitive {
        case .line(_, _, let c): return c
        case .arc(_, _, _, _, let c): return c
        case .circle(_, _, let c): return c
        case .ellipse(_, _, _, let c): return c
        case .spline(_, _, _, _, let c): return c
        case .penStroke(_, _, let c): return c
        case .polygon(_, let c): return c
        case .polyline(_, let c): return c
        case .rect(_, _, let c): return c
        case .fillPolygon(_, let c): return c
        case .fillRect(_, _, let c): return c
        case .ray(_, _, let c): return c
        default: return nil
        }
    }

    /// Best-effort z for rebuilt curves (kernel is planar).
    private static func lineZ(of primitive: CADPrimitive) -> Double {
        switch primitive {
        case .line(let s, _, _): return s.z
        case .arc(let c, _, _, _, _): return c.z
        case .circle(let c, _, _): return c.z
        case .ray(let s, _, _): return s.z
        case .polyline(let p, _): return p.vertices.first?.position.z ?? 0
        default: return 0
        }
    }
}
