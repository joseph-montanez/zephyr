import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// =========================================================================
// MARK: - CADValueTypes
//
// Fundamental CAD geometry and attribute types used throughout the engine:
//   - Vector3: 3D double-precision vector with arithmetic and geometric ops
//   - Transform3D: Position + rotation (Euler) + scale
//   - BoundingBox3D: Axis-aligned 3D bounding box with union/intersection
//   - ColorRGBA: 8-bit per channel RGBA color
//   - SnapResult: Result of a snap query (world position + anchor type)
//   - CADStyle: Per-entity rendering style overrides

// =========================================================================
// MARK: - Vector3
// =========================================================================

/// A 3D vector with Double precision. Standard struct — `x`/`y`/`z` for CAD ergonomics.
@frozen
public struct Vector3: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3()

    // MARK: Arithmetic

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    public static func * (lhs: Double, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs * rhs.x, y: lhs * rhs.y, z: lhs * rhs.z)
    }

    public static func / (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
    }

    public static func += (lhs: inout Vector3, rhs: Vector3) {
        lhs.x += rhs.x; lhs.y += rhs.y; lhs.z += rhs.z
    }

    public static func -= (lhs: inout Vector3, rhs: Vector3) {
        lhs.x -= rhs.x; lhs.y -= rhs.y; lhs.z -= rhs.z
    }

    // MARK: Vector ops

    public func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    public var magnitude: Double { sqrt(x * x + y * y + z * z) }
    public var magnitudeSquared: Double { x * x + y * y + z * z }

    public var normalized: Vector3 {
        let mag = magnitude
        guard mag > 1e-12 else { return .zero }
        return self / mag
    }

    public func distance(to other: Vector3) -> Double {
        (self - other).magnitude
    }
}

// =========================================================================
// MARK: - ColorRGBA
// =========================================================================
@frozen
public struct ColorRGBA: Hashable, Sendable, Codable {
    public var r: UInt8; public var g: UInt8; public var b: UInt8; public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let val = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.r = UInt8((val >> 16) & 0xFF)
            self.g = UInt8((val >> 8) & 0xFF)
            self.b = UInt8(val & 0xFF)
            self.a = 255
        } else {
            self.r = UInt8((val >> 24) & 0xFF)
            self.g = UInt8((val >> 16) & 0xFF)
            self.b = UInt8((val >> 8) & 0xFF)
            self.a = UInt8(val & 0xFF)
        }
    }

    public static let white   = ColorRGBA(r: 255, g: 255, b: 255)
    public static let black   = ColorRGBA(r: 0,   g: 0,   b: 0)
    public static let red     = ColorRGBA(r: 255, g: 0,   b: 0)
    public static let green   = ColorRGBA(r: 0,   g: 255, b: 0)
    public static let blue    = ColorRGBA(r: 0,   g: 0,   b: 255)
    public static let yellow  = ColorRGBA(r: 255, g: 255, b: 0)
    public static let cyan    = ColorRGBA(r: 0,   g: 255, b: 255)
    public static let magenta = ColorRGBA(r: 255, g: 0,   b: 255)
    public static let gray    = ColorRGBA(r: 128, g: 128, b: 128)
    public static let transparent = ColorRGBA(r: 0, g: 0, b: 0, a: 0)

    public func displayAdjusted(forLightBackground isLightBackground: Bool) -> ColorRGBA {
        guard a > 0 else { return self }

        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let luminance = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf

        if isLightBackground {
            if r > 245 && g > 245 && b > 245 {
                return ColorRGBA(r: 24, g: 24, b: 24, a: a)
            }
            guard luminance > 0.62 else { return self }

            let target: Double = 0.42
            let scale = max(0.0, min(1.0, target / luminance))
            return ColorRGBA(
                r: UInt8(max(0, min(255, Int(round(rf * scale * 255.0))))),
                g: UInt8(max(0, min(255, Int(round(gf * scale * 255.0))))),
                b: UInt8(max(0, min(255, Int(round(bf * scale * 255.0))))),
                a: a)
        } else {
            guard luminance < 0.18 else { return self }

            let mix: Double = 0.45
            return ColorRGBA(
                r: UInt8(max(0, min(255, Int(round((rf + (1.0 - rf) * mix) * 255.0))))),
                g: UInt8(max(0, min(255, Int(round((gf + (1.0 - gf) * mix) * 255.0))))),
                b: UInt8(max(0, min(255, Int(round((bf + (1.0 - bf) * mix) * 255.0))))),
                a: a)
        }
    }
}

// =========================================================================
// MARK: - Transform3D
// =========================================================================

/// A 4×4 homogeneous transformation matrix using a flat 16-element inline tuple in row-major order.
/// Stack-allocated 4x4 transform matrix (16 Doubles as a tuple for zero heap overhead).
///
/// NOTE ON ACCESS: element access is done via direct tuple-member loads (`m.0` … `m.15`),
/// which the compiler lowers to plain register/stack field reads. The previous implementation
/// used `withUnsafeBytes(of: m)` per element, which materializes the entire 128-byte tuple to
/// memory and performs an opaque raw load on every single access — that defeated all the
/// "inline storage" benefit and dominated the hit-test profile. Constant-index member access
/// in `transformPoint` is fully register-allocated; the dynamic `at`/`set` switch is used only
/// on cold paths (matrix multiply / inverse / decomposition).
@frozen
public struct Transform3D: Hashable, Sendable {
    /// 16 elements, row-major:
    /// indices 0-3  = row 0 (x-axis basis + translation x)
    /// indices 4-7  = row 1 (y-axis basis + translation y)
    /// indices 8-11 = row 2 (z-axis basis + translation z)
    /// indices 12-15 = row 3 (homogeneous projection row: 0, 0, 0, 1)
    private var m: (
        Double, Double, Double, Double,
        Double, Double, Double, Double,
        Double, Double, Double, Double,
        Double, Double, Double, Double
    )

    /// Initializes an Identity Matrix.
    public init() {
        m = (1, 0, 0, 0,
             0, 1, 0, 0,
             0, 0, 1, 0,
             0, 0, 0, 1)
    }

    /// Initializes a matrix from a raw 16-element slice.
    public init(raw: [Double]) {
        precondition(raw.count == 16, "Transform3D requires exactly 16 elements.")
        m = (raw[0], raw[1], raw[2], raw[3],
             raw[4], raw[5], raw[6], raw[7],
             raw[8], raw[9], raw[10], raw[11],
             raw[12], raw[13], raw[14], raw[15])
    }

    // MARK: Element access (row, col)
    //
    // Dynamic-index access via a switch over tuple members. No memory materialization,
    // no unsafe pointer loads — the optimizer keeps everything in registers. Used by the
    // cold paths (multiply / inverse / scale & rotation decomposition). Hot paths
    // (`transformPoint`, bounding-box transform) use constant indices directly.

    @inline(__always)
    private func at(_ row: Int, _ col: Int) -> Double {
        switch row * 4 + col {
        case 0:  return m.0;  case 1:  return m.1;  case 2:  return m.2;  case 3:  return m.3
        case 4:  return m.4;  case 5:  return m.5;  case 6:  return m.6;  case 7:  return m.7
        case 8:  return m.8;  case 9:  return m.9;  case 10: return m.10; case 11: return m.11
        case 12: return m.12; case 13: return m.13; case 14: return m.14; default: return m.15
        }
    }

    @inline(__always)
    private mutating func set(_ row: Int, _ col: Int, _ val: Double) {
        switch row * 4 + col {
        case 0:  m.0  = val; case 1:  m.1  = val; case 2:  m.2  = val; case 3:  m.3  = val
        case 4:  m.4  = val; case 5:  m.5  = val; case 6:  m.6  = val; case 7:  m.7  = val
        case 8:  m.8  = val; case 9:  m.9  = val; case 10: m.10 = val; case 11: m.11 = val
        case 12: m.12 = val; case 13: m.13 = val; case 14: m.14 = val; default: m.15 = val
        }
    }

    // MARK: Raw element access (for lossless serialization)

    /// The 16 matrix elements in row-major order. Use this for lossless
    /// serialization — avoids the sign loss inherent in decomposing via
    /// `position` / `scale` / `rotation` when scales are negative.
    public var rawElements: [Double] {
        [m.0,  m.1,  m.2,  m.3,
         m.4,  m.5,  m.6,  m.7,
         m.8,  m.9,  m.10, m.11,
         m.12, m.13, m.14, m.15]
    }

    // MARK: Hashable / Equatable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(m.0);  hasher.combine(m.1);  hasher.combine(m.2);  hasher.combine(m.3)
        hasher.combine(m.4);  hasher.combine(m.5);  hasher.combine(m.6);  hasher.combine(m.7)
        hasher.combine(m.8);  hasher.combine(m.9);  hasher.combine(m.10); hasher.combine(m.11)
        hasher.combine(m.12); hasher.combine(m.13); hasher.combine(m.14); hasher.combine(m.15)
    }

    public static func == (lhs: Transform3D, rhs: Transform3D) -> Bool {
        lhs.m.0  == rhs.m.0  && lhs.m.1  == rhs.m.1  && lhs.m.2  == rhs.m.2  && lhs.m.3  == rhs.m.3  &&
        lhs.m.4  == rhs.m.4  && lhs.m.5  == rhs.m.5  && lhs.m.6  == rhs.m.6  && lhs.m.7  == rhs.m.7  &&
        lhs.m.8  == rhs.m.8  && lhs.m.9  == rhs.m.9  && lhs.m.10 == rhs.m.10 && lhs.m.11 == rhs.m.11 &&
        lhs.m.12 == rhs.m.12 && lhs.m.13 == rhs.m.13 && lhs.m.14 == rhs.m.14 && lhs.m.15 == rhs.m.15
    }

    // MARK: Identity

    public static let identity = Transform3D()

    // MARK: Ergonomic Accessors

    /// Position components mapped directly to Column 3 (Row-Major format).
    public var position: Vector3 {
        get { Vector3(x: at(0, 3), y: at(1, 3), z: at(2, 3)) }
        set {
            set(0, 3, newValue.x)
            set(1, 3, newValue.y)
            set(2, 3, newValue.z)
        }
    }

    /// Scale — derived from column vector magnitudes.
    public var scale: Vector3 {
        get {
            let sx = sqrt(at(0, 0) * at(0, 0) + at(1, 0) * at(1, 0) + at(2, 0) * at(2, 0))
            let sy = sqrt(at(0, 1) * at(0, 1) + at(1, 1) * at(1, 1) + at(2, 1) * at(2, 1))
            let sz = sqrt(at(0, 2) * at(0, 2) + at(1, 2) * at(1, 2) + at(2, 2) * at(2, 2))
            return Vector3(x: sx, y: sy, z: sz)
        }
        set {
            let old = scale
            guard old.x > 1e-9 && old.y > 1e-9 && old.z > 1e-9 else { return }
            let sx = newValue.x / old.x
            let sy = newValue.y / old.y
            let sz = newValue.z / old.z

            set(0, 0, at(0, 0) * sx); set(1, 0, at(1, 0) * sx); set(2, 0, at(2, 0) * sx)
            set(0, 1, at(0, 1) * sy); set(1, 1, at(1, 1) * sy); set(2, 1, at(2, 1) * sy)
            set(0, 2, at(0, 2) * sz); set(1, 2, at(1, 2) * sz); set(2, 2, at(2, 2) * sz)
        }
    }

    /// Z-Axis Planar Rotation (Radians).
    public var rotation: Double {
        get { atan2(at(1, 0), at(0, 0)) }
        set {
            let s = scale
            let c = cos(newValue)
            let sn = sin(newValue)

            set(0, 0, c * s.x);  set(0, 1, -sn * s.y)
            set(1, 0, sn * s.x); set(1, 1, c * s.y)
            set(2, 0, 0);        set(2, 1, 0);       set(2, 2, s.z)
        }
    }

    // MARK: Matrix Multiplication

    public func multiplying(by other: Transform3D) -> Transform3D {
        var result = Transform3D()
        for row in 0..<4 {
            for col in 0..<4 {
                var sum = 0.0
                for k in 0..<4 {
                    sum += self.at(row, k) * other.at(k, col)
                }
                result.set(row, col, sum)
            }
        }
        return result
    }

    // MARK: Point Transformation

    /// Transform a point by the affine matrix. Constant tuple indices → direct field loads,
    /// no `withUnsafeBytes`, no copies. This is the hot path for bounding-box transforms.
    @inline(__always)
    public func transformPoint(_ p: Vector3) -> Vector3 {
        Vector3(
            x: m.0 * p.x + m.1 * p.y + m.2  * p.z + m.3,
            y: m.4 * p.x + m.5 * p.y + m.6  * p.z + m.7,
            z: m.8 * p.x + m.9 * p.y + m.10 * p.z + m.11
        )
    }

    // MARK: Inverse (Affine Scaling Safe)

    public func inverse() -> Transform3D {
        let s = scale
        guard s.x > 1e-9 && s.y > 1e-9 && s.z > 1e-9 else { return Transform3D.identity }

        var inv = Transform3D()

        let sqrX = s.x * s.x
        let sqrY = s.y * s.y
        let sqrZ = s.z * s.z

        inv.set(0, 0, at(0, 0) / sqrX); inv.set(0, 1, at(1, 0) / sqrX); inv.set(0, 2, at(2, 0) / sqrX)
        inv.set(1, 0, at(0, 1) / sqrY); inv.set(1, 1, at(1, 1) / sqrY); inv.set(1, 2, at(2, 1) / sqrY)
        inv.set(2, 0, at(0, 2) / sqrZ); inv.set(2, 1, at(1, 2) / sqrZ); inv.set(2, 2, at(2, 2) / sqrZ)

        let tx = at(0, 3)
        let ty = at(1, 3)
        let tz = at(2, 3)

        inv.set(0, 3, -(inv.at(0, 0) * tx + inv.at(0, 1) * ty + inv.at(0, 2) * tz))
        inv.set(1, 3, -(inv.at(1, 0) * tx + inv.at(1, 1) * ty + inv.at(1, 2) * tz))
        inv.set(2, 3, -(inv.at(2, 0) * tx + inv.at(2, 1) * ty + inv.at(2, 2) * tz))

        return inv
    }

    // MARK: Factory Instantiations

    public static func translated(by v: Vector3) -> Transform3D {
        var t = Transform3D()
        t.set(0, 3, v.x); t.set(1, 3, v.y); t.set(2, 3, v.z)
        return t
    }

    public static func scaled(by v: Vector3) -> Transform3D {
        var t = Transform3D()
        t.set(0, 0, v.x); t.set(1, 1, v.y); t.set(2, 2, v.z)
        return t
    }

    public static func rotated(by radians: Double) -> Transform3D {
        var t = Transform3D()
        let c = cos(radians)
        let s = sin(radians)
        t.set(0, 0, c); t.set(0, 1, -s)
        t.set(1, 0, s); t.set(1, 1, c)
        return t
    }
}

// =========================================================================
// MARK: - BoundingBox3D
// =========================================================================
@frozen
public struct BoundingBox3D: Hashable, Sendable {
    public var min: Vector3
    public var max: Vector3

    public init(min: Vector3 = .zero, max: Vector3 = .zero) {
        self.min = min; self.max = max
    }

    public init(from points: [Vector3]) {
        guard !points.isEmpty else { self.min = .zero; self.max = .zero; return }
        var mn = points[0], mx = points[0]
        for p in points.dropFirst() {
            if p.x < mn.x { mn.x = p.x }; if p.x > mx.x { mx.x = p.x }
            if p.y < mn.y { mn.y = p.y }; if p.y > mx.y { mx.y = p.y }
            if p.z < mn.z { mn.z = p.z }; if p.z > mx.z { mx.z = p.z }
        }
        self.min = mn; self.max = mx
    }

    /// Transform all 8 corners of a local-space box — O(1), **zero heap allocation**.
    ///
    /// The previous implementation built `local.corners` (an `[Vector3]` of 8) and then
    /// `.map`'d it (a second `[Vector3]`), i.e. two heap allocations *per call*. At 153k
    /// entities × multiple accesses that was ~600k allocations before any math ran. This
    /// version threads a running min/max through a non-escaping, force-inlined helper, so
    /// nothing escapes to the heap.
    @inline(__always)
    public init(transforming local: BoundingBox3D, by transform: Transform3D) {
        let c0 = transform.transformPoint(Vector3(x: local.min.x, y: local.min.y, z: local.min.z))
        var mn = c0
        var mx = c0

        @inline(__always) func acc(_ x: Double, _ y: Double, _ z: Double) {
            let p = transform.transformPoint(Vector3(x: x, y: y, z: z))
            if p.x < mn.x { mn.x = p.x }; if p.x > mx.x { mx.x = p.x }
            if p.y < mn.y { mn.y = p.y }; if p.y > mx.y { mx.y = p.y }
            if p.z < mn.z { mn.z = p.z }; if p.z > mx.z { mx.z = p.z }
        }

        acc(local.max.x, local.min.y, local.min.z)
        acc(local.max.x, local.max.y, local.min.z)
        acc(local.min.x, local.max.y, local.min.z)
        acc(local.min.x, local.min.y, local.max.z)
        acc(local.max.x, local.min.y, local.max.z)
        acc(local.max.x, local.max.y, local.max.z)
        acc(local.min.x, local.max.y, local.max.z)

        self.min = mn
        self.max = mx
    }

    public var center: Vector3 {
        Vector3(x: (min.x+max.x)/2, y: (min.y+max.y)/2, z: (min.z+max.z)/2)
    }

    public var size: Vector3 {
        Vector3(x: max.x-min.x, y: max.y-min.y, z: max.z-min.z)
    }

    public var area: Double {
        let s = size
        return Swift.max(0, s.x) * Swift.max(0, s.y)
    }

    /// 8 corners as a plain array.
    public var corners: [Vector3] {
        [
            Vector3(x: min.x, y: min.y, z: min.z),
            Vector3(x: max.x, y: min.y, z: min.z),
            Vector3(x: max.x, y: max.y, z: min.z),
            Vector3(x: min.x, y: max.y, z: min.z),
            Vector3(x: min.x, y: min.y, z: max.z),
            Vector3(x: max.x, y: min.y, z: max.z),
            Vector3(x: max.x, y: max.y, z: max.z),
            Vector3(x: min.x, y: max.y, z: max.z),
        ]
    }

    public func contains(_ point: Vector3) -> Bool {
        point.x >= min.x && point.x <= max.x &&
        point.y >= min.y && point.y <= max.y &&
        point.z >= min.z && point.z <= max.z
    }

    public func intersects(_ other: BoundingBox3D) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y &&
        min.z <= other.max.z && max.z >= other.min.z
    }

    public func union(with other: BoundingBox3D) -> BoundingBox3D {
        BoundingBox3D(
            min: Vector3(x: Swift.min(min.x, other.min.x),
                         y: Swift.min(min.y, other.min.y),
                         z: Swift.min(min.z, other.min.z)),
            max: Vector3(x: Swift.max(max.x, other.max.x),
                         y: Swift.max(max.y, other.max.y),
                         z: Swift.max(max.z, other.max.z))
        )
    }

    public func expanded(by amount: Double) -> BoundingBox3D {
        BoundingBox3D(
            min: Vector3(x: min.x-amount, y: min.y-amount, z: min.z-amount),
            max: Vector3(x: max.x+amount, y: max.y+amount, z: max.z+amount)
        )
    }
}

// =========================================================================
// MARK: - CADUnit
// =========================================================================

/// Drawing base unit. Stored in the file header for cross-format fidelity.
@frozen
public enum CADUnit: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case millimeter = 0
    case centimeter = 1
    case meter      = 2
    case inch       = 3
    case foot       = 4
    case yard       = 5

    /// Scale factor to convert from this unit to millimeters.
    public var scaleToMM: Double {
        switch self {
        case .millimeter: return 1.0
        case .centimeter: return 10.0
        case .meter:      return 1000.0
        case .inch:       return 25.4
        case .foot:       return 304.8
        case .yard:       return 914.4
        }
    }

    /// Scale factor to convert from millimeters to this unit.
    public var scaleFromMM: Double { 1.0 / scaleToMM }

    /// DXF $INSUNITS code.
    public var dxfINSUNITS: Int {
        switch self {
        case .millimeter: return 4
        case .centimeter: return 5
        case .meter:      return 6
        case .inch:       return 1
        case .foot:       return 2
        case .yard:       return 3
        }
    }

    /// PDF points per CAD unit. 1 PDF point = 1/72 inch = 0.352778 mm.
    /// Used as the CTM scale factor when exporting to PDF.
    public var pointsPerUnit: Double {
        scaleToMM / 0.3527777777777778  // = scaleToMM * 72 / 25.4
    }

    public var description: String {
        switch self {
        case .millimeter: return "mm"
        case .centimeter: return "cm"
        case .meter:      return "m"
        case .inch:       return "in"
        case .foot:       return "ft"
        case .yard:       return "yd"
        }
    }
}

// =========================================================================
// MARK: - PVA (Packed Vertex Array) Vertex Format
// =========================================================================

/// A single interleaved vertex in the PVA format (56 bytes, 16-byte aligned).
/// Matches the on-disk layout exactly for zero-copy GPU upload.
@frozen
public struct PVAVertex: Hashable, Sendable {
    public var px: Float; public var py: Float; public var pz: Float  // position  (12 bytes)
    public var nx: Float; public var ny: Float; public var nz: Float  // normal    (12 bytes)
    public var u: Float;  public var v: Float                        // texCoord  (8 bytes)
    public var r: UInt8;  public var g: UInt8; public var b: UInt8; public var a: UInt8  // color (4 bytes)
    // implicit 20 bytes padding to reach 56 bytes (enforced by on-disk layout)

    public init(position: Vector3, normal: Vector3 = Vector3(x: 0, y: 0, z: 1),
                texCoord: (Float, Float) = (0, 0),
                color: ColorRGBA = .white) {
        self.px = Float(position.x); self.py = Float(position.y); self.pz = Float(position.z)
        self.nx = Float(normal.x);   self.ny = Float(normal.y);   self.nz = Float(normal.z)
        self.u = texCoord.0; self.v = texCoord.1
        self.r = color.r; self.g = color.g; self.b = color.b; self.a = color.a
    }

    /// Total byte size of one vertex on disk.
    public static var stride: Int { 56 }
}

// =========================================================================
// MARK: - CADImageAsset
// =========================================================================

/// An immutable, hashable image asset stored in the document's image store.
/// Multiple entities can reference the same asset (deduplicated by sha256 hash).
/// Snapshots only store asset names, not the raw data — the imageStore persists
/// across undo/redo boundaries.
public struct CADImageAsset: Hashable, Sendable {
    /// Unique stable key derived from the SHA-256 hex digest of `data`.
    public let name: String
    /// Original filename (for display purposes and file-type hints).
    public let originalFilename: String
    /// MIME type, e.g. "image/png", "image/jpeg".
    public let mimeType: String
    /// Pixel width of the decoded image.
    public let pixelWidth: Int
    /// Pixel height of the decoded image.
    public let pixelHeight: Int
    /// SHA-256 hex digest of `data`.
    public let sha256: String
    /// Original file bytes (preserved for PDF export, EAB save, and GPU texture reload).
    public let data: Data

    public init(
        name: String,
        originalFilename: String,
        mimeType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        sha256: String,
        data: Data
    ) {
        self.name = name
        self.originalFilename = originalFilename
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sha256 = sha256
        self.data = data
    }

    /// Compute the SHA-256 hex digest of `Data`. Uses CryptoKit on Apple
    /// platforms, with a fast non-crypto fallback for other platforms.
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // Simple FNV-1a style hash for non-crypto fallback (deterministic, fast)
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        var h2: UInt64 = 0x517cc1b727220a95
        for byte in data.reversed() {
            h2 ^= UInt64(byte)
            h2 &*= 0x100000001b3
        }
        let combined = h ^ (h2 << 32) | (h2 >> 32)
        return String(format: "%016llx", combined)
        #endif
    }

    /// MIME type guessed from a filename extension.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "bmp":  return "image/bmp"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "svg":  return "image/svg+xml"
        default:     return "application/octet-stream"
        }
    }

    /// True if the given filename extension is a supported raster image format.
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "bmp", "gif", "webp", "tiff", "tif"
    ]

    /// Maximum file size for an image asset in bytes (100 MB).
    public static let maxFileBytes: Int = 100 * 1024 * 1024

    /// Maximum decoded pixel count (100 million).
    public static let maxDecodedPixels: Int = 100_000_000
}
