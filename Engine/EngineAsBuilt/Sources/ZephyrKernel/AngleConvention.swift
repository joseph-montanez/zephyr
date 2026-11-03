import Foundation

// =========================================================================
// MARK: - AngleConvention
//
// Canonical-vs-user angle decoupling for the Zephyr geometry kernel.
//
// Internal kernel math always uses the *canonical* convention:
//   * zero points along +X (East),
//   * positive rotation is counter-clockwise (viewed from +Z),
//   * radians, normalized to [0, 2*pi).
//
// User-facing angle entry honors the AutoCAD system variables:
//   * ANGBASE — direction of the user zero angle, stored here as
//     `baseAngle` in canonical radians.
//   * ANGDIR  — 0 = counter-clockwise positive, 1 = clockwise positive,
//     stored here as `isClockwise`.
//
// The parser (UserPointParser) and plan-rotation entry points never read
// ANGBASE/ANGDIR directly; the caller injects the conversion, so kernel
// geometry stays canonical under any non-default setting.
// =========================================================================

@frozen
public struct AngleConvention: Hashable, Sendable {
    /// ANGBASE in canonical radians, normalized to [0, 2*pi).
    public var baseAngle: Double
    /// True when ANGDIR == 1 (clockwise positive).
    public var isClockwise: Bool

    @inlinable
    public init(baseAngle: Double = 0, clockwise: Bool = false) {
        self.baseAngle = Self.normalize(baseAngle)
        self.isClockwise = clockwise
    }

    /// The default AutoCAD convention: zero East, CCW positive.
    public static let `default` = AngleConvention()

    /// Wraps an orientation into [0, 2*pi).
    @inlinable
    public static func normalize(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
        if a < 0 { a += 2.0 * .pi }
        // Collapse signed zero so hashed/compared values are stable.
        return a == 0 ? 0 : a
    }

    /// Wraps a signed delta into (-pi, pi].
    @inlinable
    public static func normalizeDelta(_ delta: Double) -> Double {
        var d = delta.truncatingRemainder(dividingBy: 2.0 * .pi)
        if d <= -.pi { d += 2.0 * .pi }
        if d > .pi { d -= 2.0 * .pi }
        return d == 0 ? 0 : d
    }

    // MARK: Orientations (base-shifted, direction-aware)

    /// Maps a user-entered orientation (radians, user convention) to canonical.
    @inlinable
    public func canonicalOrientation(fromUser userAngle: Double) -> Double {
        let s = isClockwise ? -1.0 : 1.0
        return Self.normalize(baseAngle + s * userAngle)
    }

    /// Maps a canonical orientation (radians) to the user convention.
    @inlinable
    public func userOrientation(fromCanonical canonicalAngle: Double) -> Double {
        let s = isClockwise ? -1.0 : 1.0
        return Self.normalize(s * (canonicalAngle - baseAngle))
    }

    // MARK: Deltas (direction-aware only; ANGBASE cancels out)

    /// Maps a user-entered rotation amount to a canonical delta.
    /// No wrapping: sign and magnitude are preserved exactly.
    @inlinable
    public func canonicalDelta(fromUserDelta userDelta: Double) -> Double {
        isClockwise ? -userDelta : userDelta
    }

    /// Maps a canonical rotation amount to a user-convention delta.
    /// No wrapping: sign and magnitude are preserved exactly.
    @inlinable
    public func userDelta(fromCanonicalDelta canonicalDelta: Double) -> Double {
        isClockwise ? -canonicalDelta : canonicalDelta
    }
}
