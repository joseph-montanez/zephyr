import Foundation
import ZephyrKernel

// =========================================================================
// MARK: - OffsetGeometryEngine
//
// Pure geometry for the AutoCAD-style OFFSET command. All math runs in
// world space: the caller bakes the result into a new entity with an
// identity transform (same convention as the FILLET connector arc).
//
// Supported primitives: line, ray (incl. imported XLINEs, which arrive as
// lines), circle, arc, ellipse, spline, polyline (straight + bulge arc
// segments), polygon, and rect outlines. Ellipse offsets are returned as
// splines fitted through densely sampled offset points — an exact offset
// is not representable in its own type, which matches AutoCAD (ellipse
// offsets become splines there too). Spline offsets instead translate
// the control points along control-polygon normals, so control count,
// degree, knots, and weights survive untouched; the price is accuracy on
// tight curves (see limitations).
//
// Limitations (documented, deliberate):
//   * Spline offsets are not loop-trimmed when the distance exceeds the
//     local radius of curvature; AutoCAD trims the loops.
//   * A polyline arc segment whose offset radius would reach zero fails
//     the whole offset instead of dropping the segment.
//   * Closed-polyline over-offset is detected by segment reversal /
//     signed-area flip and reported as failure, like AutoCAD's
//     "Cannot offset that object."
// =========================================================================

/// Polyline corner treatment outside a bend (`OFFSETGAPTYPE`).
public enum OffsetGapType: Int, Sendable, CaseIterable {
    /// 0 — extend/trim segments to a sharp corner (AutoCAD default).
    case extend = 0
    /// 1 — round the corner with an arc of radius = offset distance.
    case filleted = 1
    /// 2 — flatten the corner with a straight bevel.
    case chamfered = 2
}

/// Persistent OFFSET settings (UserDefaults-backed, thread-safe so the
/// Lisp sysvar store can share them).
public enum OffsetSettings {
    private static let gapTypeKey = "Zephyr.Offset.GapType"
    private static let distanceKey = "Zephyr.Offset.Distance"

    public static var gapType: OffsetGapType {
        get {
            let raw = UserDefaults.standard.integer(forKey: gapTypeKey)
            return OffsetGapType(rawValue: raw) ?? .extend
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: gapTypeKey) }
    }

    /// Last distance used, offered as the next prompt default. `nil`
    /// means Through is the default (AutoCAD encodes this as
    /// OFFSETDIST = -1).
    public static var lastDistance: Double? {
        get {
            guard UserDefaults.standard.object(forKey: distanceKey) != nil else { return nil }
            let value = UserDefaults.standard.double(forKey: distanceKey)
            return value > 0 && value.isFinite ? value : nil
        }
        set {
            if let newValue, newValue > 0, newValue.isFinite {
                UserDefaults.standard.set(newValue, forKey: distanceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: distanceKey)
            }
        }
    }
}

/// How the offset displacement is specified.
public enum OffsetMode: Sendable {
    /// Fixed positive distance; `sidePoint` picks the side.
    case distance(Double, sidePoint: Vector3)
    /// The offset copy passes through this world point.
    case through(Vector3)
}

public enum OffsetGeometryEngine {

    private static let eps = 1e-9

    // MARK: - Validity

    public static func isOffsettable(entity: CADEntity) -> Bool {
        guard entity.blockID == nil,
              entity.dimensionMetadata == nil,
              entity.leaderData == nil,
              entity.arrayData == nil,
              let geometry = entity.localGeometry,
              geometry.count == 1,
              let primitive = geometry.first
        else { return false }
        return isOffsettable(primitive: primitive)
    }

    public static func isOffsettable(primitive: CADPrimitive) -> Bool {
        switch primitive {
        case .line, .ray, .xline, .circle, .arc, .ellipse, .spline, .rect, .polygon:
            return true
        case .polyline(let path, _):
            return path.hatchEdges.isEmpty && !path.isHatchBoundaryCarrier
        default:
            return false
        }
    }

    // MARK: - Entry points

    /// Offset copy of an entity's single primitive, in world space.
    /// Returns nil when the entity cannot be offset at the requested
    /// distance/side.
    public static func offset(
        entity: CADEntity, mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPrimitive? {
        guard isOffsettable(entity: entity),
              let primitive = entity.localGeometry?.first
        else { return nil }
        return offset(
            primitive: primitive, transform: entity.transform,
            mode: mode, gapType: gapType)
    }

    public static func offset(
        primitive: CADPrimitive, transform: Transform3D,
        mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPrimitive? {
        switch primitive {
        case .line(let start, let end, let color):
            return offsetLine(start: start, end: end, color: color,
                              transform: transform, mode: mode)
        case .ray(let start, let direction, let color):
            return offsetRay(start: start, direction: direction, color: color,
                             transform: transform, mode: mode)
        case .xline(let point, let direction, let color):
            return offsetXLine(point: point, direction: direction, color: color,
                               transform: transform, mode: mode)
        case .circle(let center, let radius, let color):
            return offsetCircle(center: center, radius: radius, color: color,
                                transform: transform, mode: mode, gapType: gapType)
        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            return offsetArc(center: center, radius: radius,
                             startAngle: startAngle, endAngle: endAngle, color: color,
                             transform: transform, mode: mode, gapType: gapType)
        case .ellipse(let center, let majorAxis, let minorRatio, let color):
            return offsetEllipse(center: center, majorAxis: majorAxis,
                                 minorRatio: minorRatio, color: color,
                                 transform: transform, mode: mode)
        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            return offsetSpline(controlPoints: controlPoints, knots: knots,
                                degree: degree, weights: weights, color: color,
                                transform: transform, mode: mode)
        case .polyline(let path, let color):
            guard let result = offsetPolyline(
                path: path, transform: transform, mode: mode, gapType: gapType)
            else { return nil }
            return .polyline(path: result, color: color)
        case .polygon(let points, let color):
            let world = points.map { transform.transformPoint($0) }
            guard let result = offsetPointPath(
                points: world, isClosed: true, mode: mode, gapType: gapType)
            else { return nil }
            if result.hasBulges { return .polyline(path: result, color: color) }
            return .polygon(points: result.points, color: color)
        case .rect(let origin, let size, let color):
            let corners = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ].map { transform.transformPoint($0) }
            guard let result = offsetPointPath(
                points: corners, isClosed: true, mode: mode, gapType: gapType)
            else { return nil }
            return .polyline(path: result, color: color)
        default:
            return nil
        }
    }

    // MARK: - Small 2D helpers

    private static func cross2(_ a: Vector3, _ b: Vector3) -> Double {
        a.x * b.y - a.y * b.x
    }

    private static func unit2(_ v: Vector3) -> Vector3? {
        let length = hypot(v.x, v.y)
        guard length > eps else { return nil }
        return Vector3(x: v.x / length, y: v.y / length, z: 0)
    }

    /// Counter-clockwise (left-hand) normal of a unit 2D direction.
    private static func leftNormal(_ dir: Vector3) -> Vector3 {
        Vector3(x: -dir.y, y: dir.x, z: 0)
    }

    private static func normalizeAngle(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 2.0 * Double.pi)
        if result < 0 { result += 2.0 * Double.pi }
        return result
    }

    /// Signed shift along `normal` (unit) from reference point `origin`
    /// for line-like geometry. Nil means "no offset" (zero distance or
    /// side point on the line).
    private static func lineShift(
        origin: Vector3, normal: Vector3, mode: OffsetMode
    ) -> Double? {
        switch mode {
        case .distance(let distance, let sidePoint):
            guard distance > eps, distance.isFinite else { return nil }
            let side = (sidePoint - origin).dot(normal)
            guard abs(side) > eps else { return nil }
            return side > 0 ? distance : -distance
        case .through(let point):
            let shift = (point - origin).dot(normal)
            guard abs(shift) > eps else { return nil }
            return shift
        }
    }

    // MARK: - Line / Ray

    private static func offsetLine(
        start: Vector3, end: Vector3, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode
    ) -> CADPrimitive? {
        let a = transform.transformPoint(start)
        let b = transform.transformPoint(end)
        guard let dir = unit2(b - a) else { return nil }
        let normal = leftNormal(dir)
        guard let shift = lineShift(origin: a, normal: normal, mode: mode)
        else { return nil }
        let delta = Vector3(x: normal.x * shift, y: normal.y * shift, z: 0)
        return .line(start: a + delta, end: b + delta, color: color)
    }

    private static func offsetRay(
        start: Vector3, direction: Vector3, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode
    ) -> CADPrimitive? {
        let a = transform.transformPoint(start)
        let worldDirection = transform.transformPoint(start + direction) - a
        guard let dir = unit2(worldDirection) else { return nil }
        let normal = leftNormal(dir)
        guard let shift = lineShift(origin: a, normal: normal, mode: mode)
        else { return nil }
        let delta = Vector3(x: normal.x * shift, y: normal.y * shift, z: 0)
        return .ray(start: a + delta, direction: worldDirection, color: color)
    }

    private static func offsetXLine(
        point: Vector3, direction: Vector3, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode
    ) -> CADPrimitive? {
        let a = transform.transformPoint(point)
        let worldDirection = transform.transformPoint(point + direction) - a
        guard let dir = unit2(worldDirection) else { return nil }
        let normal = leftNormal(dir)
        guard let shift = lineShift(origin: a, normal: normal, mode: mode)
        else { return nil }
        let delta = Vector3(x: normal.x * shift, y: normal.y * shift, z: 0)
        return .xline(point: a + delta, direction: worldDirection, color: color)
    }

    // MARK: - Circle / Arc

    /// World-space circular parameters, or nil when the transform makes
    /// the shape non-circular (non-uniform scale / shear).
    private static func circularWorld(
        center: Vector3, radius: Double, transform: Transform3D
    ) -> (center: Vector3, radius: Double, orientation: Double)? {
        guard radius > eps else { return nil }
        let worldCenter = transform.transformPoint(center)
        let axisX = transform.transformPoint(
            Vector3(x: center.x + radius, y: center.y, z: center.z)) - worldCenter
        let axisY = transform.transformPoint(
            Vector3(x: center.x, y: center.y + radius, z: center.z)) - worldCenter
        let radiusX = hypot(axisX.x, axisX.y)
        let radiusY = hypot(axisY.x, axisY.y)
        guard radiusX > eps, radiusY > eps,
              abs(radiusX - radiusY) <= max(radiusX, radiusY) * 1e-6,
              abs(axisX.x * axisY.x + axisX.y * axisY.y) <= radiusX * radiusY * 1e-6
        else { return nil }
        let orientation = cross2(axisX, axisY) >= 0 ? 1.0 : -1.0
        return (worldCenter, (radiusX + radiusY) * 0.5, orientation)
    }

    /// New radius for a concentric offset, or nil if it collapses.
    /// `nearest` is the closest point on the source curve to the
    /// side/through point and drives Through mode.
    private static func offsetRadius(
        center: Vector3, radius: Double, nearest: Vector3, mode: OffsetMode
    ) -> Double? {
        switch mode {
        case .distance(let distance, let sidePoint):
            guard distance > eps, distance.isFinite else { return nil }
            let radial = hypot(sidePoint.x - center.x, sidePoint.y - center.y)
            let newRadius = radial >= radius ? radius + distance : radius - distance
            return newRadius > eps ? newRadius : nil
        case .through(let point):
            let distance = point.distance(to: nearest)
            guard distance > eps else { return nil }
            let radial = hypot(point.x - center.x, point.y - center.y)
            let newRadius = radial >= radius ? radius + distance : radius - distance
            return newRadius > eps ? newRadius : nil
        }
    }

    private static func offsetCircle(
        center: Vector3, radius: Double, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPrimitive? {
        guard let world = circularWorld(center: center, radius: radius, transform: transform)
        else {
            // Non-circular in world space: offset a sampled closed path.
            let points = (0..<128).map { index -> Vector3 in
                let angle = 2.0 * Double.pi * Double(index) / 128.0
                return transform.transformPoint(Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z))
            }
            guard let path = offsetPointPath(
                points: points, isClosed: true, mode: mode, gapType: gapType)
            else { return nil }
            return .polyline(path: path, color: color)
        }
        let reference: Vector3
        switch mode {
        case .distance(_, let sidePoint): reference = sidePoint
        case .through(let point): reference = point
        }
        let nearest = CADGeometryMath.nearestPointOnCircle(
            to: reference, center: world.center, radius: world.radius) ?? world.center
        guard let newRadius = offsetRadius(
            center: world.center, radius: world.radius, nearest: nearest, mode: mode)
        else { return nil }
        return .circle(center: world.center, radius: newRadius, color: color)
    }

    private static func offsetArc(
        center: Vector3, radius: Double,
        startAngle: Double, endAngle: Double, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPrimitive? {
        var span = endAngle - startAngle
        if span < 0 { span += 2.0 * Double.pi }
        guard span > eps else { return nil }

        guard let world = circularWorld(center: center, radius: radius, transform: transform)
        else {
            let divisions = max(16, Int(ceil(span * 32.0 / Double.pi)))
            let points = (0...divisions).map { index -> Vector3 in
                let angle = startAngle + span * Double(index) / Double(divisions)
                return transform.transformPoint(Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z))
            }
            guard let path = offsetPointPath(
                points: points, isClosed: false, mode: mode, gapType: gapType)
            else { return nil }
            return .polyline(path: path, color: color)
        }

        let localStart = Vector3(
            x: center.x + cos(startAngle) * radius,
            y: center.y + sin(startAngle) * radius, z: center.z)
        let worldStartPoint = transform.transformPoint(localStart)
        let worldStart = atan2(worldStartPoint.y - world.center.y,
                               worldStartPoint.x - world.center.x)
        let sweep = span * world.orientation

        let reference: Vector3
        switch mode {
        case .distance(_, let sidePoint): reference = sidePoint
        case .through(let point): reference = point
        }
        let nearest = nearestPointOnSignedArc(
            reference, center: world.center, radius: world.radius,
            start: worldStart, sweep: sweep)
        guard let newRadius = offsetRadius(
            center: world.center, radius: world.radius, nearest: nearest, mode: mode)
        else { return nil }

        // Express as a CCW arc (start ≤ end in CCW sweep terms).
        let outStart = sweep >= 0 ? worldStart : worldStart + sweep
        let outEnd = sweep >= 0 ? worldStart + sweep : worldStart
        return .arc(center: world.center, radius: newRadius,
                    startAngle: outStart, endAngle: outEnd, color: color)
    }

    private static func nearestPointOnSignedArc(
        _ point: Vector3, center: Vector3, radius: Double,
        start: Double, sweep: Double
    ) -> Vector3 {
        func onArc(_ angle: Double) -> Vector3 {
            Vector3(x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z)
        }
        let angle = atan2(point.y - center.y, point.x - center.x)
        let progress = sweep >= 0
            ? normalizeAngle(angle - start)
            : normalizeAngle(start - angle)
        if progress <= abs(sweep) + 1e-12 { return onArc(angle) }
        let startPoint = onArc(start)
        let endPoint = onArc(start + sweep)
        return point.distance(to: startPoint) <= point.distance(to: endPoint)
            ? startPoint : endPoint
    }

    // MARK: - Ellipse

    private static func offsetEllipse(
        center: Vector3, majorAxis: Vector3, minorRatio: Double, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode
    ) -> CADPrimitive? {
        guard hypot(majorAxis.x, majorAxis.y) > eps, abs(minorRatio) > eps
        else { return nil }
        let worldCenter = transform.transformPoint(center)
        let origin = transform.transformPoint(.zero)
        func worldVector(_ v: Vector3) -> Vector3 { transform.transformPoint(v) - origin }
        let axisU = worldVector(majorAxis)
        let axisV = worldVector(Vector3(
            x: -majorAxis.y * minorRatio, y: majorAxis.x * minorRatio, z: 0))
        guard hypot(axisU.x, axisU.y) > eps, hypot(axisV.x, axisV.y) > eps
        else { return nil }

        func point(at t: Double) -> Vector3 {
            Vector3(
                x: worldCenter.x + axisU.x * cos(t) + axisV.x * sin(t),
                y: worldCenter.y + axisU.y * cos(t) + axisV.y * sin(t),
                z: worldCenter.z)
        }
        /// Outward unit normal at parameter `t`.
        func normal(at t: Double) -> Vector3? {
            let tangent = Vector3(
                x: -axisU.x * sin(t) + axisV.x * cos(t),
                y: -axisU.y * sin(t) + axisV.y * cos(t), z: 0)
            guard var n = unit2(Vector3(x: tangent.y, y: -tangent.x, z: 0))
            else { return nil }
            // Flip so the normal points away from the interior (center).
            if (point(at: t) - worldCenter).dot(n) < 0 { n = n * -1.0 }
            return n
        }

        // Nearest sample drives side / Through distance.
        let reference: Vector3
        switch mode {
        case .distance(_, let sidePoint): reference = sidePoint
        case .through(let point): reference = point
        }
        var nearestT = 0.0
        var nearestDistSq = Double.infinity
        for index in 0..<720 {
            let t = 2.0 * Double.pi * Double(index) / 720.0
            let p = point(at: t)
            let dSq = (reference - p).magnitudeSquared
            if dSq < nearestDistSq { nearestDistSq = dSq; nearestT = t }
        }
        guard let nearestNormal = normal(at: nearestT) else { return nil }
        let nearestPoint = point(at: nearestT)

        let signedDistance: Double
        switch mode {
        case .distance(let distance, _):
            guard distance > eps, distance.isFinite else { return nil }
            let side = (reference - nearestPoint).dot(nearestNormal)
            guard abs(side) > eps else { return nil }
            signedDistance = side > 0 ? distance : -distance
        case .through:
            signedDistance = (reference - nearestPoint).dot(nearestNormal)
            guard abs(signedDistance) > eps else { return nil }
        }

        // Inward offset past the minimum radius of curvature self-intersects.
        if signedDistance < 0 {
            let a = hypot(axisU.x, axisU.y)
            let b = hypot(axisV.x, axisV.y)
            let minRadius = min(a, b) * min(a, b) / max(a, b)
            guard abs(signedDistance) < minRadius - eps else { return nil }
        }

        let count = 96
        var offsetPoints: [Vector3] = []
        offsetPoints.reserveCapacity(count)
        for index in 0..<count {
            let t = 2.0 * Double.pi * Double(index) / Double(count)
            guard let n = normal(at: t) else { return nil }
            offsetPoints.append(point(at: t) + n * signedDistance)
        }
        return makeClosedSpline(points: offsetPoints, color: color)
    }

    // MARK: - Spline

    private static func offsetSpline(
        controlPoints: [Vector3], knots: [Double], degree: Int,
        weights: [Double]?, color: ColorRGBA?,
        transform: Transform3D, mode: OffsetMode
    ) -> CADPrimitive? {
        // Control-count-preserving offset: the CONTROL POINTS translate
        // along control-polygon normals. Samples below drive side
        // selection and closed detection only — they never become
        // control points, so count/degree/knots/weights survive.
        guard controlPoints.count >= 2 else { return nil }
        let worldCPs = controlPoints.map { transform.transformPoint($0) }
        let samples = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
            degree: degree, knots: knots, controlPoints: worldCPs,
            weights: weights, chordTolerance: 0.005, maxDepth: 10, maxSegments: 4096)
        guard samples.count >= 4 else { return nil }

        let closed = samples.count > 2
            && (samples.first?.distance(to: samples.last ?? .zero) ?? .infinity) <= 1e-7
        var work = samples
        if closed { work.removeLast() }
        guard work.count >= 4 else { return nil }

        /// Left-hand unit normal from central-difference tangent.
        func leftNormalAt(_ index: Int) -> Vector3? {
            let count = work.count
            let prev = closed ? work[(index - 1 + count) % count] : work[max(0, index - 1)]
            let next = closed ? work[(index + 1) % count] : work[min(count - 1, index + 1)]
            guard let tangent = unit2(next - prev) else { return nil }
            return leftNormal(tangent)
        }

        /// Bisected left normal of the control-polygon legs meeting at a
        /// control point (wrapped when closed). Nil when no leg has
        /// length — the offset side is undefined there.
        func controlNormalAt(_ index: Int) -> Vector3? {
            let count = worldCPs.count
            var nx = 0.0, ny = 0.0, legs = 0
            func leg(_ a: Vector3, _ b: Vector3) {
                guard let tangent = unit2(b - a) else { return }
                let n = leftNormal(tangent)
                nx += n.x; ny += n.y; legs += 1
            }
            if index > 0 { leg(worldCPs[index - 1], worldCPs[index]) }
            else if closed { leg(worldCPs[count - 1], worldCPs[index]) }
            if index + 1 < count { leg(worldCPs[index], worldCPs[index + 1]) }
            else if closed { leg(worldCPs[index], worldCPs[0]) }
            guard legs > 0 else { return nil }
            let length = (nx * nx + ny * ny).squareRoot()
            guard length > 1e-12 else { return nil }
            return Vector3(x: nx / length, y: ny / length, z: 0)
        }

        let reference: Vector3
        switch mode {
        case .distance(_, let sidePoint): reference = sidePoint
        case .through(let point): reference = point
        }
        var nearestIndex = 0
        var nearestDistSq = Double.infinity
        for (index, p) in work.enumerated() {
            let dSq = (reference - p).magnitudeSquared
            if dSq < nearestDistSq { nearestDistSq = dSq; nearestIndex = index }
        }
        guard let nearestNormal = leftNormalAt(nearestIndex) else { return nil }

        let signedDistance: Double
        switch mode {
        case .distance(let distance, _):
            guard distance > eps, distance.isFinite else { return nil }
            let side = (reference - work[nearestIndex]).dot(nearestNormal)
            guard abs(side) > eps else { return nil }
            signedDistance = side > 0 ? distance : -distance
        case .through:
            signedDistance = (reference - work[nearestIndex]).dot(nearestNormal)
            guard abs(signedDistance) > eps else { return nil }
        }

        var offsetCPs: [Vector3] = []
        offsetCPs.reserveCapacity(worldCPs.count)
        for index in worldCPs.indices {
            guard let n = controlNormalAt(index) else { return nil }
            offsetCPs.append(worldCPs[index] + n * signedDistance)
        }
        return .spline(controlPoints: offsetCPs, knots: knots,
                       degree: degree, weights: weights, color: color)
    }

    /// Periodic cubic B-spline whose control polygon wraps the given loop.
    private static func makeClosedSpline(
        points: [Vector3], color: ColorRGBA?
    ) -> CADPrimitive? {
        let degree = 3
        guard points.count > degree else { return nil }
        var controlPoints = points
        for i in 0..<degree { controlPoints.append(points[i]) }
        let knotCount = controlPoints.count + degree + 1
        let knots = (0..<knotCount).map { Double($0) }
        return .spline(controlPoints: controlPoints, knots: knots,
                       degree: degree, weights: nil, color: color)
    }

    // MARK: - Polyline core

    /// One world-space segment (straight, or circular arc when `arc` set).
    private struct OffsetSeg {
        var start: Vector3
        var end: Vector3
        var arc: (center: Vector3, radius: Double, sweep: Double)?
        var startWidth: Double = 0
        var endWidth: Double = 0

        func tangent(atStart: Bool) -> Vector3? {
            if let arc {
                let p = atStart ? start : end
                let radial = Vector3(
                    x: (p.x - arc.center.x) / arc.radius,
                    y: (p.y - arc.center.y) / arc.radius, z: 0)
                let ccw = Vector3(x: -radial.y, y: radial.x, z: 0)
                return arc.sweep >= 0 ? ccw : ccw * -1.0
            }
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 1e-12 else { return nil }
            return Vector3(
                x: (end.x - start.x) / length, y: (end.y - start.y) / length, z: 0)
        }

        func tessellated(includeEnd: Bool) -> [Vector3] {
            guard let arc else { return includeEnd ? [start, end] : [start] }
            let startAngle = atan2(start.y - arc.center.y, start.x - arc.center.x)
            let divisions = max(2, Int(ceil(abs(arc.sweep) * 16.0 / Double.pi)))
            let last = includeEnd ? divisions : divisions - 1
            return (0...last).map { step in
                let angle = startAngle + arc.sweep * Double(step) / Double(divisions)
                let t = Double(step) / Double(divisions)
                return Vector3(
                    x: arc.center.x + cos(angle) * arc.radius,
                    y: arc.center.y + sin(angle) * arc.radius,
                    z: start.z + (end.z - start.z) * t)
            }
        }
    }

    private static func sourceSegments(from path: CADPolyline) -> [OffsetSeg] {
        var segs: [OffsetSeg] = []
        for index in 0..<path.segmentCount {
            let startVertex = path.vertices[index]
            let endVertex = path.vertices[path.endVertexIndex(forSegment: index)]
            var seg = OffsetSeg(
                start: startVertex.position, end: endVertex.position,
                startWidth: startVertex.startWidth, endWidth: startVertex.endWidth)
            if let arc = path.arcParameters(forSegment: index) {
                seg.arc = (arc.center, arc.radius, arc.sweep)
            } else if hypot(seg.end.x - seg.start.x, seg.end.y - seg.start.y) <= eps {
                continue // degenerate straight segment
            }
            segs.append(seg)
        }
        return segs
    }

    /// Signed offset distance along each segment's left-hand normal.
    private static func signedDistance(
        for segs: [OffsetSeg], mode: OffsetMode
    ) -> Double? {
        let reference: Vector3
        switch mode {
        case .distance(_, let sidePoint): reference = sidePoint
        case .through(let point): reference = point
        }

        var bestDistSq = Double.infinity
        var bestSide = 0.0
        for seg in segs {
            let nearest: Vector3
            if let arc = seg.arc {
                let startAngle = atan2(seg.start.y - arc.center.y, seg.start.x - arc.center.x)
                nearest = nearestPointOnSignedArc(
                    reference, center: arc.center, radius: arc.radius,
                    start: startAngle, sweep: arc.sweep)
            } else {
                let delta = seg.end - seg.start
                let lengthSq = delta.x * delta.x + delta.y * delta.y
                var t = 0.0
                if lengthSq > eps {
                    t = max(0, min(1, ((reference - seg.start).dot(delta)) / lengthSq))
                }
                nearest = seg.start + delta * t
            }
            let distSq = (reference - nearest).magnitudeSquared
            guard distSq < bestDistSq else { continue }

            // Tangent at the nearest point.
            let tangent: Vector3?
            if let arc = seg.arc {
                let radial = Vector3(
                    x: (nearest.x - arc.center.x) / arc.radius,
                    y: (nearest.y - arc.center.y) / arc.radius, z: 0)
                let ccw = Vector3(x: -radial.y, y: radial.x, z: 0)
                tangent = arc.sweep >= 0 ? ccw : ccw * -1.0
            } else {
                tangent = seg.tangent(atStart: true)
            }
            guard let tangent else { continue }
            bestDistSq = distSq
            bestSide = cross2(tangent, reference - nearest)
        }
        guard bestDistSq.isFinite, abs(bestSide) > eps else { return nil }

        switch mode {
        case .distance(let distance, _):
            guard distance > eps, distance.isFinite else { return nil }
            return bestSide > 0 ? distance : -distance
        case .through:
            return bestSide
        }
    }

    private static func offsetSegments(
        _ segs: [OffsetSeg], by signedDistance: Double
    ) -> [OffsetSeg]? {
        var result: [OffsetSeg] = []
        result.reserveCapacity(segs.count)
        for seg in segs {
            if let arc = seg.arc {
                let newRadius = arc.radius
                    - signedDistance * (arc.sweep >= 0 ? 1.0 : -1.0)
                guard newRadius > eps else { return nil }
                let scale = newRadius / arc.radius
                var shifted = seg
                shifted.start = arc.center + (seg.start - arc.center) * scale
                shifted.end = arc.center + (seg.end - arc.center) * scale
                shifted.start.z = seg.start.z
                shifted.end.z = seg.end.z
                shifted.arc = (arc.center, newRadius, arc.sweep)
                result.append(shifted)
            } else {
                guard let dir = seg.tangent(atStart: true) else { return nil }
                let normal = leftNormal(dir)
                let delta = Vector3(
                    x: normal.x * signedDistance, y: normal.y * signedDistance, z: 0)
                var shifted = seg
                shifted.start = seg.start + delta
                shifted.end = seg.end + delta
                result.append(shifted)
            }
        }
        return result
    }

    // MARK: - Polyline joins

    /// Intersections of the two segments' supporting curves, nearest first
    /// to the midpoint of the two facing endpoints.
    private static func supportIntersections(
        _ a: OffsetSeg, _ b: OffsetSeg
    ) -> [Vector3] {
        // Canonical kernel solver (local-frame shifted line/arc mixes).
        // Infinite-curve semantics preserved (extend both); z rebuilt per
        // the legacy rules: line interpolation when a line participates,
        // else a.end.z.
        let mid = (a.end + b.start) * 0.5
        func curve(of seg: OffsetSeg) -> Curve2d {
            if let arc = seg.arc {
                let startAngle = atan2(seg.start.y - arc.center.y, seg.start.x - arc.center.x)
                return .arc(Arc2d(center: arc.center.point2d, radius: arc.radius,
                                  startAngle: startAngle, sweep: arc.sweep))
            }
            return .line(LineSeg2d(start: seg.start.point2d, end: seg.end.point2d))
        }
        let ka = curve(of: a)
        let kb = curve(of: b)
        let hits = Intersector2D.intersect(ka, kb, extendA: true, extendB: true)
        let points: [Vector3] = hits.map { h in
            let z: Double
            switch (ka, kb) {
            case (.line, _):
                z = a.start.z + (a.end.z - a.start.z) * h.paramA
            case (_, .line):
                z = b.start.z + (b.end.z - b.start.z) * h.paramB
            default:
                z = a.end.z
            }
            return Vector3(x: h.point.x, y: h.point.y, z: z)
        }
        return points.sorted { $0.distance(to: mid) < $1.distance(to: mid) }
    }

    /// Move a segment endpoint to `point` (on its supporting curve).
    /// Returns false when an arc sweep would become invalid.
    private static func trimSegment(
        _ seg: inout OffsetSeg, atStart: Bool, to point: Vector3, extending: Bool
    ) -> Bool {
        guard let arc = seg.arc else {
            if atStart { seg.start = point } else { seg.end = point }
            return true
        }
        let startAngle = atan2(seg.start.y - arc.center.y, seg.start.x - arc.center.x)
        let endAngle = atan2(seg.end.y - arc.center.y, seg.end.x - arc.center.x)
        let pointAngle = atan2(point.y - arc.center.y, point.x - arc.center.x)
        let limit = abs(arc.sweep) + (extending ? Double.pi : 1e-6)
        if atStart {
            let magnitude = arc.sweep >= 0
                ? normalizeAngle(endAngle - pointAngle)
                : normalizeAngle(pointAngle - endAngle)
            guard magnitude <= limit, magnitude > eps else { return false }
            seg.start = point
            seg.arc = (arc.center, arc.radius, arc.sweep >= 0 ? magnitude : -magnitude)
        } else {
            let magnitude = arc.sweep >= 0
                ? normalizeAngle(pointAngle - startAngle)
                : normalizeAngle(startAngle - pointAngle)
            guard magnitude <= limit, magnitude > eps else { return false }
            seg.end = point
            seg.arc = (arc.center, arc.radius, arc.sweep >= 0 ? magnitude : -magnitude)
        }
        return true
    }

    /// Join consecutive offset segments. Returns connector segments keyed
    /// by the index of the segment they follow.
    private static func joinSegments(
        _ segs: inout [OffsetSeg], source: [OffsetSeg], isClosed: Bool,
        signedDistance: Double, gapType: OffsetGapType
    ) -> [Int: OffsetSeg] {
        var inserts: [Int: OffsetSeg] = [:]
        let count = segs.count
        guard count > 1 else { return inserts }
        let coincidenceTol = 1e-7 * max(1.0, abs(signedDistance))
        let joinCount = isClosed ? count : count - 1

        for k in 0..<joinCount {
            let i = k
            let j = (k + 1) % count
            var a = segs[i]
            var b = segs[j]
            if a.end.distance(to: b.start) <= coincidenceTol { continue }

            func connect() {
                inserts[i] = OffsetSeg(
                    start: a.end, end: b.start,
                    startWidth: a.endWidth, endWidth: b.startWidth)
            }
            func trimToIntersection(extending: Bool) -> Bool {
                guard let point = supportIntersections(a, b).first
                else { return false }
                var trimmedA = a
                var trimmedB = b
                guard trimSegment(&trimmedA, atStart: false, to: point, extending: extending),
                      trimSegment(&trimmedB, atStart: true, to: point, extending: extending)
                else { return false }
                a = trimmedA
                b = trimmedB
                segs[i] = a
                segs[j] = b
                return true
            }

            guard let t1 = a.tangent(atStart: false),
                  let t2 = b.tangent(atStart: true)
            else { connect(); continue }

            let turn = cross2(t1, t2)
            let spike = t1.dot(t2) < -0.999999
            let isGap = turn * signedDistance < 0 || spike

            if isGap {
                switch gapType {
                case .extend:
                    if !trimToIntersection(extending: true) { connect() }
                case .chamfered:
                    connect()
                case .filleted:
                    let vertex = source[i].end
                    let r1 = a.end - vertex
                    let r2 = b.start - vertex
                    var sweep = atan2(cross2(r1, r2), r1.x * r2.x + r1.y * r2.y)
                    if spike { sweep = (signedDistance > 0 ? -1.0 : 1.0) * Double.pi }
                    if abs(sweep) > eps {
                        inserts[i] = OffsetSeg(
                            start: a.end, end: b.start,
                            arc: (vertex, abs(signedDistance), sweep),
                            startWidth: a.endWidth, endWidth: b.startWidth)
                    } else {
                        connect()
                    }
                }
            } else {
                if !trimToIntersection(extending: false) { connect() }
            }
        }
        return inserts
    }

    private static func signedArea(of segs: [OffsetSeg]) -> Double {
        var points: [Vector3] = []
        for seg in segs { points.append(contentsOf: seg.tessellated(includeEnd: false)) }
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for i in points.indices {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            area += p.x * q.y - q.x * p.y
        }
        return area * 0.5
    }

    /// Shared segment-path pipeline: side → offset → join → validate → build.
    private static func offsetSegPath(
        source: [OffsetSeg], isClosed: Bool,
        mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPolyline? {
        guard !source.isEmpty,
              let distance = signedDistance(for: source, mode: mode),
              var segs = offsetSegments(source, by: distance)
        else { return nil }

        let inserts = joinSegments(
            &segs, source: source, isClosed: isClosed,
            signedDistance: distance, gapType: gapType)
        let tolerance = 1e-7 * max(1.0, abs(distance))

        // A straight segment trimmed past its far end means the offset
        // collapsed (e.g. closed shape offset inward too far).
        for (index, seg) in segs.enumerated() {
            if let arc = seg.arc {
                guard let sourceArc = source[index].arc,
                      (arc.sweep >= 0) == (sourceArc.sweep >= 0),
                      abs(arc.sweep) > eps
                else { return nil }
            } else {
                let sourceDelta = source[index].end - source[index].start
                let delta = seg.end - seg.start
                if delta.x * sourceDelta.x + delta.y * sourceDelta.y < -tolerance {
                    return nil
                }
            }
        }

        var ordered: [OffsetSeg] = []
        for (index, seg) in segs.enumerated() {
            ordered.append(seg)
            if let insert = inserts[index] { ordered.append(insert) }
        }

        if isClosed {
            let sourceArea = signedArea(of: source)
            let resultArea = signedArea(of: ordered)
            if abs(sourceArea) > eps, sourceArea * resultArea <= 0 { return nil }
        }

        var vertices: [CADPolylineVertex] = ordered.map { seg in
            CADPolylineVertex(
                position: seg.start,
                bulge: seg.arc.map { tan($0.sweep / 4.0) } ?? 0,
                startWidth: seg.startWidth, endWidth: seg.endWidth)
        }
        if !isClosed, let last = ordered.last {
            vertices.append(CADPolylineVertex(
                position: last.end, startWidth: last.endWidth, endWidth: last.endWidth))
        }

        // Drop degenerate straight segments left behind by trimming.
        var cleaned: [CADPolylineVertex] = []
        for vertex in vertices {
            if let prev = cleaned.last,
               abs(prev.bulge) <= 1e-12,
               prev.position.distance(to: vertex.position) <= tolerance {
                continue
            }
            cleaned.append(vertex)
        }
        if isClosed, cleaned.count > 2,
           let first = cleaned.first, let last = cleaned.last,
           abs(last.bulge) <= 1e-12,
           last.position.distance(to: first.position) <= tolerance {
            cleaned.removeLast()
        }
        guard cleaned.count >= 2 else { return nil }

        let path = CADPolyline(vertices: cleaned, isClosed: isClosed)
        guard path.length > tolerance else { return nil }
        return path
    }

    private static func offsetPointPath(
        points: [Vector3], isClosed: Bool,
        mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPolyline? {
        var unique: [Vector3] = []
        for point in points {
            if let last = unique.last, last.distance(to: point) <= eps { continue }
            unique.append(point)
        }
        if isClosed, unique.count > 1,
           let first = unique.first, let last = unique.last,
           first.distance(to: last) <= eps {
            unique.removeLast()
        }
        guard unique.count >= 2 else { return nil }

        let segmentCount = isClosed ? unique.count : unique.count - 1
        var segs: [OffsetSeg] = []
        for i in 0..<segmentCount {
            segs.append(OffsetSeg(
                start: unique[i], end: unique[(i + 1) % unique.count]))
        }
        return offsetSegPath(
            source: segs, isClosed: isClosed, mode: mode, gapType: gapType)
    }

    private static func offsetPolyline(
        path: CADPolyline, transform: Transform3D,
        mode: OffsetMode, gapType: OffsetGapType
    ) -> CADPolyline? {
        let nonUniformScale = abs(abs(transform.scale.x) - abs(transform.scale.y)) > 1e-9
        if path.hasBulges && nonUniformScale {
            // Bulge arcs cannot survive non-uniform scaling as circles;
            // offset the tessellation instead.
            var points = path.tessellatedPoints().map { transform.transformPoint($0) }
            if path.isClosed, points.count > 1 { points.removeLast() }
            guard var result = offsetPointPath(
                points: points, isClosed: path.isClosed, mode: mode, gapType: gapType)
            else { return nil }
            result.lineTypeGenerationEnabled = path.lineTypeGenerationEnabled
            return result
        }

        let worldPath = path.transformed(by: transform)
        let segs = sourceSegments(from: worldPath)
        guard var result = offsetSegPath(
            source: segs, isClosed: path.isClosed, mode: mode, gapType: gapType)
        else { return nil }
        result.lineTypeGenerationEnabled = path.lineTypeGenerationEnabled
        return result
    }
}
