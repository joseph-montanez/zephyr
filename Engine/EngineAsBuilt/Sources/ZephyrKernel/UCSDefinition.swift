import Foundation

// =========================================================================
// MARK: - UCSDefinition (planar)
//
// Minimal 3D support types plus a planar user coordinate system.
//
// The planar UCS is a translated + rotated copy of the WCS XY plane:
//   * `origin`  — WCS position of the UCS origin (its z is the elevation).
//   * `angle`   — canonical radians in [0, 2*pi): rotation of the UCS X
//     axis away from WCS +X about +Z (CCW positive, ANGBASE/ANGDIR-free).
//
// Derived frame (always right-handed, always unit length):
//   * xAxis = (cos a, sin a, 0)
//   * yAxis = (-sin a, cos a, 0)
//   * worldAxis = (0, 0, 1) — the WCS plane normal shared by every planar UCS.
//
// Out-of-plane ("tilted") WCS input is handled by orthogonal projection:
// toLocal drops the UCS-Z component and projectToPlane re-emits the point
// on the plane, so planarity is preserved and the round-trip
// toWorld(toLocal(p)) == projectToPlane(p) holds for every input.
// =========================================================================

@frozen
public struct Vec3d: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable
    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3d()
    public static let xAxis = Vec3d(x: 1, y: 0, z: 0)
    public static let yAxis = Vec3d(x: 0, y: 1, z: 0)
    public static let zAxis = Vec3d(x: 0, y: 0, z: 1)

    @inlinable
    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    @inlinable
    public var lengthSquared: Double { x * x + y * y + z * z }

    @inlinable
    public var normalized: Vec3d {
        let len = length
        guard len > KernelTolerance.linear else { return .zero }
        return Vec3d(x: x / len, y: y / len, z: z / len)
    }

    @inlinable
    public func dot(_ other: Vec3d) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    @inlinable
    public func cross(_ other: Vec3d) -> Vec3d {
        Vec3d(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    @inlinable
    public static func + (lhs: Vec3d, rhs: Vec3d) -> Vec3d {
        Vec3d(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    @inlinable
    public static func - (lhs: Vec3d, rhs: Vec3d) -> Vec3d {
        Vec3d(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    @inlinable
    public static func * (lhs: Vec3d, rhs: Double) -> Vec3d {
        Vec3d(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}

@frozen
public struct Point3d: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable
    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Point3d()

    @inlinable
    public func distance(to other: Point3d) -> Double {
        (other - self).length
    }

    @inlinable
    public static func + (lhs: Point3d, rhs: Vec3d) -> Point3d {
        Point3d(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    @inlinable
    public static func - (lhs: Point3d, rhs: Point3d) -> Vec3d {
        Vec3d(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    @inlinable
    public static func - (lhs: Point3d, rhs: Vec3d) -> Point3d {
        Point3d(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
}

@frozen
public struct UCSDefinition: Hashable, Sendable {
    /// WCS position of the UCS origin. `origin.z` is the plane elevation.
    public var origin: Point3d
    /// Canonical rotation of the UCS X axis from WCS +X about +Z,
    /// in radians normalized to [0, 2*pi). CCW positive.
    public var angle: Double

    @inlinable
    public init(origin: Point3d = .zero, angle: Double = 0) {
        self.origin = origin
        self.angle = AngleConvention.normalize(angle)
    }

    /// The identity (WCS-aligned) planar UCS.
    public static let identity = UCSDefinition()

    /// Unit UCS X axis in WCS: (cos a, sin a, 0).
    @inlinable
    public var xAxis: Vec3d {
        Vec3d(x: cos(angle), y: sin(angle), z: 0)
    }

    /// Unit UCS Y axis in WCS: (-sin a, cos a, 0), 90 deg CCW from xAxis.
    @inlinable
    public var yAxis: Vec3d {
        Vec3d(x: -sin(angle), y: cos(angle), z: 0)
    }

    /// The WCS plane normal shared by every planar UCS: (0, 0, 1).
    public static var worldAxis: Vec3d { .zAxis }

    /// Instance spelling of the shared plane normal.
    @inlinable
    public var planeNormal: Vec3d { Self.worldAxis }

    // MARK: Forward / inverse transforms

    /// UCS point -> WCS point. The result always lies on the UCS plane.
    @inlinable
    public func toWorld(_ p: Point2d) -> Point3d {
        let c = cos(angle), s = sin(angle)
        return Point3d(
            x: origin.x + c * p.x - s * p.y,
            y: origin.y + s * p.x + c * p.y,
            z: origin.z
        )
    }

    /// UCS direction -> WCS direction. Translation-free; result has z == 0.
    @inlinable
    public func toWorld(direction v: Vec2d) -> Vec3d {
        let c = cos(angle), s = sin(angle)
        return Vec3d(x: c * v.x - s * v.y, y: s * v.x + c * v.y, z: 0)
    }

    /// WCS point -> UCS point. Orthogonal projection: any out-of-plane
    /// ("tilted") component is dropped, so the result is always planar.
    @inlinable
    public func toLocal(_ p: Point3d) -> Point2d {
        let d = p - origin
        let xa = xAxis, ya = yAxis
        return Point2d(x: d.dot(xa), y: d.dot(ya))
    }

    /// WCS direction -> UCS direction. Translation-free; input z is dropped.
    @inlinable
    public func toLocal(direction v: Vec3d) -> Vec2d {
        let xa = xAxis, ya = yAxis
        return Vec2d(x: v.dot(xa), y: v.dot(ya))
    }

    /// Orthogonal projection of an arbitrary (possibly tilted) WCS point
    /// onto the UCS plane. Idempotent: projecting twice is a no-op, and
    /// toWorld(toLocal(p)) == projectToPlane(p) for every p.
    @inlinable
    public func projectToPlane(_ p: Point3d) -> Point3d {
        toWorld(toLocal(p))
    }

    // MARK: Rotation

    /// Returns the UCS rotated by a canonical delta (radians, CCW positive).
    @inlinable
    public func rotated(by canonicalDelta: Double) -> UCSDefinition {
        UCSDefinition(origin: origin, angle: angle + canonicalDelta)
    }

    /// Plan-view rotation driven by a user-entered delta (radians, user
    /// convention). The ANGBASE/ANGDIR mapping is injected via
    /// `convention`, keeping this type canonical internally.
    @inlinable
    public func planRotated(
        by userDelta: Double,
        convention: AngleConvention = .default
    ) -> UCSDefinition {
        rotated(by: convention.canonicalDelta(fromUserDelta: userDelta))
    }

    // MARK: Planar three-point construction

    /// Validates an origin / +X-point / +Y-side triple for a planar UCS.
    /// Only the planar (XY, relative to origin) components participate, so
    /// tilted inputs are judged by their projection — the same projection
    /// fromThreePoints applies. Fails when either direction is shorter
    /// than `tolerance` or the perpendicular distance of the Y-side point
    /// from the X axis line is below `tolerance` (collinear).
    public static func validateThreePoints(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d,
        tolerance: Double = KernelTolerance.linear
    ) -> Bool {
        let ex = Vec2d(x: xPoint.x - origin.x, y: xPoint.y - origin.y)
        let ey = Vec2d(x: yPoint.x - origin.x, y: yPoint.y - origin.y)
        let exLen = ex.length
        guard exLen >= tolerance, ey.length >= tolerance else { return false }
        // |cross| / |ex| is the perpendicular distance of yPoint from the
        // X axis line through origin — absolute, CAD-style.
        let distFromXAxis = abs(ex.cross(ey)) / exLen
        return distFromXAxis >= tolerance
    }

    /// Builds a planar UCS from an origin / +X-point / +Y-side triple.
    /// The angle comes from the planar projection of origin -> xPoint, so
    /// tilted inputs are projected (planarity-preserving); yPoint only
    /// disambiguates validity. Returns nil when validation fails.
    public static func fromThreePoints(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d,
        tolerance: Double = KernelTolerance.linear
    ) -> UCSDefinition? {
        guard validateThreePoints(
            origin: origin, xPoint: xPoint, yPoint: yPoint, tolerance: tolerance
        ) else { return nil }
        let a = atan2(xPoint.y - origin.y, xPoint.x - origin.x)
        return UCSDefinition(origin: origin, angle: a)
    }

    /// Non-failable three-point construction with degenerate fallbacks.
    /// A degenerate X direction (coincident with origin in-plane) falls
    /// back to `fallbackAngle`; a degenerate Y side (coincident or
    /// collinear) keeps the X-derived angle with Y at +90 deg CCW, which
    /// is already the planar default — so planarity is preserved.
    public static func fromThreePointsAllowingDegenerate(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d,
        tolerance: Double = KernelTolerance.linear,
        fallbackAngle: Double = 0
    ) -> UCSDefinition {
        let ex = Vec2d(x: xPoint.x - origin.x, y: xPoint.y - origin.y)
        guard ex.length >= tolerance else {
            return UCSDefinition(origin: origin, angle: fallbackAngle)
        }
        let a = atan2(xPoint.y - origin.y, xPoint.x - origin.x)
        return UCSDefinition(origin: origin, angle: a)
    }
}
