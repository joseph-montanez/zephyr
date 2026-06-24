import Foundation

// =========================================================================
// MARK: - CADPolarTracking
//
// Pure math for polar-angle-aligned cursor snapping. Given a reference point
// (e.g. the last pick point in a draw command) and the cursor position,
// finds the nearest position on a ray at a polar angle from the reference
// point. The angular tolerance is viewport-scaled so that the snap "zone"
// feels consistent regardless of zoom level.
//
// Polar angle increments are user-configurable (e.g. 45° = 0, 45, 90, 135…).
// =========================================================================

/// Result of a polar tracking computation.
public struct PolarTrackingResult: Hashable, Sendable {
    /// World-space position snapped to the nearest polar ray from the reference point.
    public let worldPos: Vector3
    /// The polar angle in degrees (0–360, where 0° = +X, 90° = +Y).
    public let angleDeg: Double
    /// Straight-line distance from the reference point to the snapped position.
    public let distance: Double
    /// The reference point this snap is relative to.
    public let reference: Vector3

    public init(worldPos: Vector3, angleDeg: Double, distance: Double, reference: Vector3) {
        self.worldPos = worldPos
        self.angleDeg = angleDeg
        self.distance = distance
        self.reference = reference
    }
}

// =========================================================================
// MARK: - PolarTracking
// =========================================================================

/// Stateless polar tracking math.
public enum PolarTracking {

    /// Find the nearest polar-aligned position from `reference` toward `cursor`.
    ///
    /// - Parameters:
    ///   - reference: The origin point (last draw point, tracking point, etc.).
    ///   - cursor: Current cursor position in world space.
    ///   - incrementDeg: Angular step size in degrees (e.g. 15, 30, 45, 90).
    ///   - thresholdPx: Screen-space snap-zone width in pixels. The actual
    ///     world-space angular tolerance is derived from this so the zone
    ///     scales properly with zoom.
    ///   - pixelsPerWorldUnit: `cameraZoom` — converts screen pixels to
    ///     world units for threshold computation.
    /// - Returns: A `PolarTrackingResult` if the cursor is within the angular
    ///   tolerance of a polar ray, or `nil` if it is too far off-axis.
    public static func nearestPolar(
        reference: Vector3,
        cursor: Vector3,
        incrementDeg: Double,
        thresholdPx: Double = 12.0,
        pixelsPerWorldUnit: Double = 1.0
    ) -> PolarTrackingResult? {
        let dx = cursor.x - reference.x
        let dy = cursor.y - reference.y
        let dist = sqrt(dx * dx + dy * dy)

        // When cursor is very close to reference, polar is ill-defined.
        // Require a minimum distance so the angle is meaningful.
        let minDistWorld = thresholdPx / max(pixelsPerWorldUnit, 0.001)
        guard dist > minDistWorld else { return nil }

        // Raw cursor angle in degrees (0° = +X axis, CCW).
        let rawAngleRad = atan2(dy, dx)
        let rawAngleDeg = rawAngleRad * 180.0 / .pi
        // Normalize to [0, 360)
        let cursorDeg = rawAngleDeg < 0 ? rawAngleDeg + 360.0 : rawAngleDeg

        // Snap to nearest polar increment.
        let inc = max(incrementDeg, 0.1) // guard against zero division
        let snappedDeg = (cursorDeg / inc).rounded() * inc
        // Normalize snapped angle to [0, 360)
        let polarAngle = snappedDeg.truncatingRemainder(dividingBy: 360.0)

        // Angular deviation in degrees.
        var deviation = abs(cursorDeg - polarAngle)
        if deviation > 180.0 { deviation = 360.0 - deviation }

        // Convert screen-pixel threshold to an angular tolerance.
        // At distance `dist`, a lateral offset of `thresholdPx` world units
        // subtends an angle of approx atan2(offset, dist) in radians.
        let worldThreshold = thresholdPx / max(pixelsPerWorldUnit, 0.001)
        let angularThresholdRad = atan2(worldThreshold, dist)
        let angularThresholdDeg = angularThresholdRad * 180.0 / .pi

        guard deviation <= angularThresholdDeg else { return nil }

        // Project cursor onto the polar ray.
        let polarRad = polarAngle * .pi / 180.0
        let projX = reference.x + cos(polarRad) * dist
        let projY = reference.y + sin(polarRad) * dist

        return PolarTrackingResult(
            worldPos: Vector3(x: projX, y: projY, z: reference.z),
            angleDeg: polarAngle,
            distance: dist,
            reference: reference
        )
    }

    /// Convenience: all polar angles for a given increment, returned as radians.
    /// e.g. increment=45 → [0, π/4, π/2, 3π/4, π, 5π/4, 3π/2, 7π/4]
    public static func polarAnglesRad(incrementDeg: Double) -> [Double] {
        let inc = max(incrementDeg, 0.1)
        let count = Int((360.0 / inc).rounded())
        return (0..<count).map { Double($0) * inc * .pi / 180.0 }
    }
}
