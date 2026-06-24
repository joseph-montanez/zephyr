import Foundation

// =========================================================================
// MARK: - CADGeometryMath
//
// Pure math utilities for CAD geometry: transforms primitives by a
// Transform3D, decomposes transforms to matrices, and provides common
// geometric computations (distance, angle, intersection) used throughout
// the CAD rendering and editing pipeline.
import SwiftSDL

public enum CADGeometryMath {

    public static func circleThroughThreePoints(
        _ a: Vector3,
        _ b: Vector3,
        _ c: Vector3
    ) -> (center: Vector3, radius: Double)? {
        let ax = a.x
        let ay = a.y
        let bx = b.x
        let by = b.y
        let cx = c.x
        let cy = c.y

        let d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        if abs(d) < 1e-9 { return nil }

        let a2 = ax * ax + ay * ay
        let b2 = bx * bx + by * by
        let c2 = cx * cx + cy * cy

        let ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
        let uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
        let center = Vector3(x: ux, y: uy, z: a.z)
        return (center, hypot(ax - ux, ay - uy))
    }



    public static func arcAnglesIncludingMid(
        center: Vector3,
        start: Vector3,
        mid: Vector3,
        end: Vector3
    ) -> (start: Double, end: Double) {
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        let midAngle = atan2(mid.y - center.y, mid.x - center.x)
        let endAngle = atan2(end.y - center.y, end.x - center.x)

        if angleIsOnCCWSweep(angle: midAngle, start: startAngle, end: endAngle) {
            return (startAngle, endAngle)
        }
        return (endAngle, startAngle)
    }



    public static func angleIsOnCCWSweep(angle: Double, start: Double, end: Double) -> Bool {
        let twoPi = 2.0 * Double.pi
        func norm(_ v: Double) -> Double {
            var r = v.truncatingRemainder(dividingBy: twoPi)
            if r < 0 { r += twoPi }
            return r
        }
        let a = norm(angle - start)
        let e = norm(end - start)
        return a >= -1e-9 && a <= e + 1e-9
    }

    // =====================================================================
    // MARK: - Nearest Point On Curve (Nearest snap)
    // =====================================================================

    /// Nearest point ON the arc to `p`, or nil if the cursor's polar angle
    /// falls outside the sweep (the endpoints there are already covered by
    /// vertex anchors, which take priority over nearest snaps anyway) or the
    /// cursor sits at the center (direction undefined).
    public static func nearestPointOnArc(
        to p: Vector3, center: Vector3, radius: Double,
        startAngle: Double, endAngle: Double
    ) -> Vector3? {
        let dx = p.x - center.x
        let dy = p.y - center.y
        guard dx * dx + dy * dy > 1e-18 else { return nil }
        var span = endAngle - startAngle
        if span < 0 { span += 2.0 * .pi }
        let angle = atan2(dy, dx)
        guard angleIsOnCCWSweep(angle: angle, start: startAngle, end: startAngle + span) else {
            return nil
        }
        return Vector3(x: center.x + cos(angle) * radius,
                       y: center.y + sin(angle) * radius,
                       z: center.z)
    }

    /// Nearest point ON the circle to `p` (radial projection), or nil if the
    /// cursor sits exactly at the center.
    public static func nearestPointOnCircle(
        to p: Vector3, center: Vector3, radius: Double
    ) -> Vector3? {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let d = sqrt(dx * dx + dy * dy)
        guard d > 1e-12 else { return nil }
        return Vector3(x: center.x + dx / d * radius,
                       y: center.y + dy / d * radius,
                       z: center.z)
    }

    /// Nearest point ON the ellipse to `p`. There is no closed form for
    /// point-to-ellipse distance, so this samples the parametric angle to
    /// isolate the global minimum's basin, then refines with golden-section
    /// search. 64 samples + 48 refinement steps converge well below any
    /// drafting tolerance at trivial cost.
    public static func nearestPointOnEllipse(
        to p: Vector3, center: Vector3, majorAxis: Vector3, minorRatio: Double
    ) -> Vector3? {
        let halfMajor = majorAxis.magnitude
        guard halfMajor > 1e-12 else { return nil }
        let dirX = majorAxis.x / halfMajor
        let dirY = majorAxis.y / halfMajor
        let halfMinor = halfMajor * minorRatio

        func point(at t: Double) -> Vector3 {
            let ct = cos(t) * halfMajor
            let st = sin(t) * halfMinor
            return Vector3(
                x: center.x + dirX * ct - dirY * st,
                y: center.y + dirY * ct + dirX * st,
                z: center.z)
        }
        func distSq(at t: Double) -> Double {
            let q = point(at: t)
            let dx = q.x - p.x
            let dy = q.y - p.y
            return dx * dx + dy * dy
        }

        let samples = 64
        let step = 2.0 * Double.pi / Double(samples)
        var bestI = 0
        var bestD = Double.greatestFiniteMagnitude
        for i in 0..<samples {
            let d = distSq(at: Double(i) * step)
            if d < bestD {
                bestD = d
                bestI = i
            }
        }

        var lo = Double(bestI - 1) * step
        var hi = Double(bestI + 1) * step
        let phi = (sqrt(5.0) - 1.0) / 2.0
        var c = hi - phi * (hi - lo)
        var d = lo + phi * (hi - lo)
        var fc = distSq(at: c)
        var fd = distSq(at: d)
        for _ in 0..<48 {
            if fc < fd {
                hi = d
                d = c
                fd = fc
                c = hi - phi * (hi - lo)
                fc = distSq(at: c)
            } else {
                lo = c
                c = d
                fc = fd
                d = lo + phi * (hi - lo)
                fd = distSq(at: d)
            }
        }
        return point(at: (lo + hi) / 2)
    }

    /// Nearest point on a polyline (used for snapping to tessellated splines).
    /// Projects `p` onto each segment, clamped to the segment, and returns the
    /// closest projection.
    public static func nearestPointOnPolyline(
        to p: Vector3, points: [Vector3], closed: Bool = false
    ) -> Vector3? {
        guard points.count >= 2 else { return points.first }
        var best: Vector3? = nil
        var bestDistSq = Double.greatestFiniteMagnitude

        func consider(_ a: Vector3, _ b: Vector3) {
            let abx = b.x - a.x
            let aby = b.y - a.y
            let lenSq = abx * abx + aby * aby
            var t = 0.0
            if lenSq > 1e-18 {
                t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq
                t = min(1.0, max(0.0, t))
            }
            let q = Vector3(x: a.x + abx * t, y: a.y + aby * t, z: a.z)
            let dx = q.x - p.x
            let dy = q.y - p.y
            let dsq = dx * dx + dy * dy
            if dsq < bestDistSq {
                bestDistSq = dsq
                best = q
            }
        }

        for i in 0..<(points.count - 1) {
            consider(points[i], points[i + 1])
        }
        if closed, points.count >= 3 {
            consider(points[points.count - 1], points[0])
        }
        return best
    }

    // =====================================================================
    // MARK: - Ray Intersection (Measure Geometry Tool)
    // =====================================================================

    /// Squared distance from point `p` to the finite segment [a, b].
    @inlinable
    public static func pointToSegmentDistSq(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let ls = dx * dx + dy * dy
        if ls == 0 { return (p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / ls
        t = max(0, min(1, t))
        let qx = a.x + t * dx
        let qy = a.y + t * dy
        return (p.x - qx) * (p.x - qx) + (p.y - qy) * (p.y - qy)
    }

    /// Squared perpendicular distance from a point to an **infinite line**.
    ///
    /// Unlike `pointToSegmentDistSq` which clamps to [0,1] (finite segment),
    /// this computes the true perpendicular distance to the unbounded line.
    /// Uses the 2D cross-product trick: because `dir` is normalized,
    /// `|cross(v, dir)|` directly gives the perpendicular distance.
    ///
    /// - Parameters:
    ///   - p: The point to test (e.g., cursor world position).
    ///   - origin: Any point on the infinite line.
    ///   - dir: The **normalized** direction vector of the line.
    /// - Returns: Squared perpendicular distance.
    @inlinable
    public static func pointToInfiniteLineDistSq(_ p: Vector3, origin: Vector3, normalizedDir dir: Vector3) -> Double {
        // 2D cross product: (v × dir) = v.x*dir.y - v.y*dir.x
        // Since |dir| = 1, this equals the signed perpendicular distance.
        let perpDist = (p.x - origin.x) * dir.y - (p.y - origin.y) * dir.x
        return perpDist * perpDist
    }

    /// Perpendicular distance from a point to an **infinite line**.
    /// See `pointToInfiniteLineDistSq` for details.
    @inlinable
    public static func pointToInfiniteLineDist(_ p: Vector3, origin: Vector3, normalizedDir dir: Vector3) -> Double {
        abs((p.x - origin.x) * dir.y - (p.y - origin.y) * dir.x)
    }

    /// Intersection of an infinite ray with a finite line segment.
    /// - Parameters:
    ///   - rayOrigin: Starting point of the ray.
    ///   - rayDir: Direction vector of the ray (does not need to be normalized).
    ///   - lineP1, lineP2: Endpoints of the finite segment.
    /// - Returns: The intersection point, or nil if parallel or not on the segment.
    @inlinable
    public static func intersectRayLine(
        rayOrigin: Vector3, rayDir: Vector3,
        lineP1: Vector3, lineP2: Vector3
    ) -> Vector3? {
        let rdx = rayDir.x
        let rdy = rayDir.y
        let sx = lineP2.x - lineP1.x
        let sy = lineP2.y - lineP1.y

        let cross = rdx * sy - rdy * sx
        if abs(cross) < 1e-12 { return nil }  // parallel or coincident

        let dx = lineP1.x - rayOrigin.x
        let dy = lineP1.y - rayOrigin.y

        // u = ray parameter, t = segment parameter
        let u = (dx * sy - dy * sx) / cross
        if u < 0 { return nil }  // behind the ray

        let t = (dx * rdy - dy * rdx) / cross
        if t < 0 || t > 1 { return nil }  // outside the segment

        return Vector3(x: rayOrigin.x + u * rdx,
                       y: rayOrigin.y + u * rdy,
                       z: rayOrigin.z)
    }

    /// Intersection of two finite 2D line segments.
    ///
    /// Solves the parametric system:
    ///   a + t·(b - a) = c + u·(d - c)
    ///
    /// - Parameters:
    ///   - a, b: Endpoints of the first segment.
    ///   - c, d: Endpoints of the second segment.
    /// - Returns: The intersection point and parameters `(t, u)` where
    ///   `t ∈ [0,1]` runs along a→b and `u ∈ [0,1]` runs along c→d.
    ///   Returns `nil` if the segments are parallel or the intersection
    ///   lies outside either segment's parameter range.
    @inlinable
    public static func segmentSegmentIntersection(
        a: Vector3, b: Vector3,
        c: Vector3, d: Vector3
    ) -> (point: Vector3, t: Double, u: Double)? {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let cdx = d.x - c.x
        let cdy = d.y - c.y

        let cross = abx * cdy - aby * cdx
        if abs(cross) < 1e-12 { return nil }  // parallel or coincident

        let acx = c.x - a.x
        let acy = c.y - a.y

        // t = parameter on segment a→b, u = parameter on segment c→d
        let t = (acx * cdy - acy * cdx) / cross
        if t < -1e-6 || t > 1.0 + 1e-6 { return nil }  // outside a→b

        let u = (acx * aby - acy * abx) / cross
        if u < -1e-6 || u > 1.0 + 1e-6 { return nil }  // outside c→d

        return (Vector3(x: a.x + t * abx, y: a.y + t * aby, z: a.z), t, u)
    }

    /// Intersection of an infinite ray with a full circle.
    /// Solves quadratic `at² + bt + c = 0` where `t` is the ray parameter.
    /// Only returns points where `t >= 0` (in front of the ray).
    /// - Returns: 0, 1, or 2 intersection points sorted by distance from ray origin.
    @inlinable
    public static func intersectRayCircle(
        rayOrigin: Vector3, rayDir: Vector3,
        circleCenter: Vector3, radius: Double
    ) -> [Vector3] {
        let dx = rayDir.x
        let dy = rayDir.y
        let fx = rayOrigin.x - circleCenter.x
        let fy = rayOrigin.y - circleCenter.y

        let a = dx * dx + dy * dy
        let b = 2.0 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius

        let discriminant = b * b - 4.0 * a * c
        if discriminant < 0 { return [] }

        let sqrtD = sqrt(discriminant)
        let t1 = (-b - sqrtD) / (2.0 * a)
        let t2 = (-b + sqrtD) / (2.0 * a)

        var result: [Vector3] = []
        if t1 >= 0 {
            result.append(Vector3(x: rayOrigin.x + t1 * dx,
                                  y: rayOrigin.y + t1 * dy,
                                  z: rayOrigin.z))
        }
        if t2 >= 0 && abs(t2 - t1) > 1e-12 {
            result.append(Vector3(x: rayOrigin.x + t2 * dx,
                                  y: rayOrigin.y + t2 * dy,
                                  z: rayOrigin.z))
        }
        // Already sorted by t (t1 < t2), which corresponds to distance.
        return result
    }

    /// Intersection of an infinite ray with a finite arc.
    /// First finds intersections with the full circle, then filters to points
    /// whose polar angle falls within the arc's CCW sweep.
    /// - Returns: All valid intersection points sorted by distance from ray origin.
    @inlinable
    public static func intersectRayArc(
        rayOrigin: Vector3, rayDir: Vector3,
        arcCenter: Vector3, radius: Double,
        startAngle: Double, endAngle: Double
    ) -> [Vector3] {
        let circleHits = intersectRayCircle(
            rayOrigin: rayOrigin, rayDir: rayDir,
            circleCenter: arcCenter, radius: radius)
        guard !circleHits.isEmpty else { return [] }

        var span = endAngle - startAngle
        if span < 0 { span += 2.0 * .pi }

        var result: [Vector3] = []
        result.reserveCapacity(2)
        for pt in circleHits {
            let angle = atan2(pt.y - arcCenter.y, pt.x - arcCenter.x)
            if angleIsOnCCWSweep(angle: angle, start: startAngle, end: startAngle + span) {
                result.append(pt)
            }
        }
        return result
    }



    /// Regenerate tessellated circle points from local parameters + world transform.
    public static func regenCirclePoints(
        rp: RenderPrimitive, center: Vector3, radius: Double, transform: Transform3D
    ) {
        let segments = 32
        var pts: [SDL_FPoint] = []
        pts.reserveCapacity(segments + 1)
        for i in 0...segments {
            let angle = Double(i) * 2.0 * .pi / Double(segments)
            let local = Vector3(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius, z: center.z)
            let wp = transform.transformPoint(local)
            pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
        }
        rp.points = pts
    }



    /// Regenerate tessellated ellipse points from local parameters + world transform.
    public static func regenEllipseRP(
        _ rp: RenderPrimitive, center: Vector3, majorAxis: Vector3,
        minorRatio: Double, transform: Transform3D
    ) {
        let segments = 64
        let majorLen = majorAxis.magnitude
        let minorLen = majorLen * minorRatio
        let rot = atan2(majorAxis.y, majorAxis.x)
        let cosRot = cos(rot)
        let sinRot = sin(rot)
        var pts: [SDL_FPoint] = []
        pts.reserveCapacity(segments + 1)
        for i in 0...segments {
            let t = Double(i) * 2.0 * .pi / Double(segments)
            let px = majorLen * cos(t)
            let py = minorLen * sin(t)
            let rx = px * cosRot - py * sinRot + center.x
            let ry = px * sinRot + py * cosRot + center.y
            let local = Vector3(x: rx, y: ry, z: center.z)
            let wp = transform.transformPoint(local)
            pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
        }
        rp.points = pts
    }

    /// Regenerate tessellated arc points from local parameters + world transform.
    public static func regenArcPoints(
        rp: RenderPrimitive, center: Vector3, radius: Double,
        startAngle: Double, endAngle: Double, transform: Transform3D
    ) {
        let segments = 16
        var span = endAngle - startAngle
        if span < 0 { span += 2.0 * .pi }
        var pts: [SDL_FPoint] = []
        pts.reserveCapacity(segments + 1)
        for i in 0...segments {
            let t = Double(i) / Double(segments)
            let angle = startAngle + span * t
            let local = Vector3(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius, z: center.z)
            let wp = transform.transformPoint(local)
            pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
        }
        rp.points = pts
    }


    /// Compute 4 world-space corners of a rect after applying the full transform (including rotation).
    public static func getRotatedCorners(origin: Vector3, size: Vector3, transform: Transform3D)
        -> [SDL_FPoint]
    {
        let c1 = transform.transformPoint(origin)
        let c2 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
        let c3 = transform.transformPoint(
            Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
        let c4 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
        return [
            SDL_FPoint(x: Float(c1.x), y: Float(c1.y)),
            SDL_FPoint(x: Float(c2.x), y: Float(c2.y)),
            SDL_FPoint(x: Float(c3.x), y: Float(c3.y)),
            SDL_FPoint(x: Float(c4.x), y: Float(c4.y)),
        ]
    }



    /// World-space points for a CADPrimitive (used for vertex index mapping).
    public static func worldPointsForPrimitive(_ prim: CADPrimitive, transform: Transform3D) -> [Vector3] {
        switch prim {
        case .point(let pos, _):
            return [transform.transformPoint(pos)]
        case .line(let start, let end, _):
            return [transform.transformPoint(start), transform.transformPoint(end)]
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            return [
                transform.transformPoint(origin),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: 0)),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: 0)),
                transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: 0)),
            ]
        case .polygon(let pts, _), .polyline(let pts, _), .fillPolygon(let pts, _), .fillComplexPolygon(let pts, _, _), .gradient(let pts, _, _, _, _, _):
            return pts.map { transform.transformPoint($0) }
        case .circle(let center, let radius, _):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let wr = radius * max(abs(s.x), abs(s.y))
            return [
                wc,
                Vector3(x: wc.x + wr, y: wc.y, z: wc.z),
                Vector3(x: wc.x, y: wc.y + wr, z: wc.z),
                Vector3(x: wc.x - wr, y: wc.y, z: wc.z),
                Vector3(x: wc.x, y: wc.y - wr, z: wc.z),
            ]
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * .pi }
            let midAngle = startAngle + span / 2.0
            return [
                transform.transformPoint(center),
                transform.transformPoint(Vector3(
                    x: center.x + cos(startAngle) * radius,
                    y: center.y + sin(startAngle) * radius,
                    z: center.z)),
                transform.transformPoint(Vector3(
                    x: center.x + cos(endAngle) * radius,
                    y: center.y + sin(endAngle) * radius,
                    z: center.z)),
                transform.transformPoint(Vector3(
                    x: center.x + cos(midAngle) * radius,
                    y: center.y + sin(midAngle) * radius,
                    z: center.z)),
            ]
        case .spline(let controlPoints, _, _, _, _):
            return controlPoints.map { transform.transformPoint($0) }
        case .text(let pos, _, _, _, _, _, _, _, _):
            return [transform.transformPoint(pos)]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let wc = transform.transformPoint(center)
            let s = transform.scale
            let ws = max(abs(s.x), abs(s.y))
            let halfMajor = majorAxis.magnitude * ws
            let halfMinor = halfMajor * minorRatio
            let rot = atan2(majorAxis.y, majorAxis.x) + transform.rotation
            return [
                wc,
                Vector3(x: wc.x + cos(rot) * halfMajor, y: wc.y + sin(rot) * halfMajor, z: wc.z),
                Vector3(x: wc.x - cos(rot) * halfMajor, y: wc.y - sin(rot) * halfMajor, z: wc.z),
                Vector3(x: wc.x - sin(rot) * halfMinor, y: wc.y + cos(rot) * halfMinor, z: wc.z),
                Vector3(x: wc.x + sin(rot) * halfMinor, y: wc.y - cos(rot) * halfMinor, z: wc.z),
            ]
        case .hatch(let boundary, _, _, _, _):
            return boundary.map { transform.transformPoint($0) }
        case .ray(let start, let direction, _):
            let ws = transform.transformPoint(start)
            let wd = transform.transformPoint(Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            return [ws, wd]
        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let c0 = transform.transformPoint(insertion)
            let c1 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
            let c2 = transform.transformPoint(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
            let c3 = transform.transformPoint(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            return [c0, c1, c2, c3]
        }
    }


    /// Apply a Transform3D to a list of primitives, returning a transformed copy. 
    /// Arcs and circles are tessellated to line segments first so the result is correct 
    /// under any rotation, scale, or reflection without needing to re-derive arc parameters.
    public static func transformPrimitives(
        _ prims: [CADPrimitive], by t: Transform3D
    ) -> [CADPrimitive] {
        func tp(_ v: Vector3) -> Vector3 { t.transformPoint(v) }
        func corners(_ o: Vector3, _ s: Vector3) -> [Vector3] {
            [o,
             Vector3(x: o.x + s.x, y: o.y, z: o.z),
             Vector3(x: o.x + s.x, y: o.y + s.y, z: o.z),
             Vector3(x: o.x, y: o.y + s.y, z: o.z)]
        }
        let scaleMag = abs(t.scale.x)
        let rot = t.rotation
        var out: [CADPrimitive] = []
        for p in prims {
            switch p {
            case let .point(position, color):
                out.append(.point(position: tp(position), color: color))
            case let .line(start, end, color):
                out.append(.line(start: tp(start), end: tp(end), color: color))
            case let .rect(origin, size, color):
                out.append(.polygon(points: corners(origin, size).map(tp), color: color))
            case let .fillRect(origin, size, color):
                out.append(.fillPolygon(points: corners(origin, size).map(tp), color: color))
            case let .polygon(points, color):
                out.append(.polygon(points: points.map(tp), color: color))
            case let .polyline(points, color):
                out.append(.polyline(points: points.map(tp), color: color))
            case let .fillPolygon(points, color):
                out.append(.fillPolygon(points: points.map(tp), color: color))
            case let .fillComplexPolygon(outer, holes, color):
                out.append(.fillComplexPolygon(outer: outer.map(tp),
                                               holes: holes.map { $0.map(tp) }, color: color))
            case let .gradient(outer, holes, name, angle, c1, c2):
                out.append(.gradient(outer: outer.map(tp),
                                     holes: holes.map { $0.map(tp) },
                                     gradientName: name,
                                     angle: angle + rot,
                                     color1: c1, color2: c2))
            case let .circle(center, radius, color):
                let seg = 48
                var pts: [Vector3] = []
                for i in 0..<seg {
                    let a = 2.0 * Double.pi * Double(i) / Double(seg)
                    pts.append(tp(Vector3(x: center.x + cos(a) * radius,
                                          y: center.y + sin(a) * radius, z: center.z)))
                }
                out.append(.polygon(points: pts, color: color))
            case let .arc(center, radius, startAngle, endAngle, color):
                var span = endAngle - startAngle
                if span < 0 { span += 2.0 * Double.pi }
                let seg = max(2, Int((span / (Double.pi / 24.0)).rounded(.up)))
                var prev = tp(Vector3(x: center.x + cos(startAngle) * radius,
                                      y: center.y + sin(startAngle) * radius, z: center.z))
                for i in 1...seg {
                    let a = startAngle + span * Double(i) / Double(seg)
                    let cur = tp(Vector3(x: center.x + cos(a) * radius,
                                         y: center.y + sin(a) * radius, z: center.z))
                    out.append(.line(start: prev, end: cur, color: color))
                    prev = cur
                }
            case let .text(position, text, height, rotation, style, alignH, alignV, mtextWidth, color):
                out.append(.text(position: tp(position), text: text,
                                 height: height * scaleMag, rotation: rotation + rot,
                                 style: style, alignH: alignH, alignV: alignV,
                                 mtextWidth: mtextWidth, color: color))
            case let .spline(controlPoints, knots, degree, weights, color):
                let newCPs = controlPoints.map(tp)
                out.append(.spline(controlPoints: newCPs, knots: knots,
                                   degree: degree, weights: weights, color: color))
            case let .ellipse(center, majorAxis, minorRatio, color):
                out.append(.ellipse(center: tp(center), majorAxis: tp(majorAxis), minorRatio: minorRatio, color: color))
            case let .hatch(boundary, pattern, scale, angle, color):
                out.append(.hatch(boundary: boundary.map(tp), pattern: pattern, scale: scale, angle: angle + rot, color: color))
            case let .ray(start, direction, color):
                out.append(.ray(start: tp(start), direction: tp(direction), color: color))
            case let .image(insertion, uAxis, vAxis, imageName, clipBoundary, tint):
                out.append(.image(insertion: tp(insertion), uAxis: tp(uAxis), vAxis: tp(vAxis),
                                  imageName: imageName, clipBoundary: clipBoundary, tint: tint))
            }
        }
        return out
    }
}