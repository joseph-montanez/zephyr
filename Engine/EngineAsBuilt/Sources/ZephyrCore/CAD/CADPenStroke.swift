import Foundation

// =========================================================================
// MARK: - CADPenStroke
//
// PenStrokeVertex: A single vertex in a pen-drawn stroke, capturing both
// geometric position and tablet pen attributes (pressure, tilt, rotation)
// from SDL3's CategoryPen API.
//
// These vertices are stored in the `.penStroke` CADPrimitive case and are
// serialized to EAB format only (DXF export falls back to a lossy spline).
// =========================================================================

/// A vertex in a pen stroke, carrying full tablet digitizer state.
///
/// All values use the SDL3 Pen API conventions:
/// - `pressure`: 0.0 (hovering) … 1.0 (full pressure)
/// - `xtilt`: -90.0 … 90.0 degrees (horizontal tilt)
/// - `ytilt`: -90.0 … 90.0 degrees (vertical tilt)
/// - `rotation`: -180.0 … 179.9 degrees (barrel rotation)
public struct PenStrokeVertex: Hashable, Sendable {
    public var position: Vector3
    public var pressure: Double
    public var xtilt: Double
    public var ytilt: Double
    public var rotation: Double

    public init(
        position: Vector3,
        pressure: Double = 1.0,
        xtilt: Double = 0.0,
        ytilt: Double = 0.0,
        rotation: Double = 0.0
    ) {
        self.position = position
        self.pressure = pressure
        self.xtilt = xtilt
        self.ytilt = ytilt
        self.rotation = rotation
    }

    /// Fallback vertex used for mouse/trackpad input (no tablet data).
    public static func mouseFallback(at position: Vector3) -> PenStrokeVertex {
        PenStrokeVertex(position: position, pressure: 1.0, xtilt: 0.0, ytilt: 0.0, rotation: 0.0)
    }
}

public struct PenStrokeBrushSettings: Hashable, Sendable {
    public var minLineWeight: Double
    public var maxLineWeight: Double
    public var tiltInfluence: Double
    public var rotationInfluence: Double

    public init(
        minLineWeight: Double,
        maxLineWeight: Double,
        tiltInfluence: Double = 0.0,
        rotationInfluence: Double = 0.0
    ) {
        let minWeight = max(0.01, minLineWeight)
        self.minLineWeight = minWeight
        self.maxLineWeight = max(minWeight, maxLineWeight)
        self.tiltInfluence = max(0.0, min(1.0, tiltInfluence))
        self.rotationInfluence = max(0.0, min(1.0, rotationInfluence))
    }

    public static func defaults(baseLineWeight: Double) -> PenStrokeBrushSettings {
        let base = max(0.05, baseLineWeight)
        return PenStrokeBrushSettings(
            minLineWeight: max(0.05, base * 0.4),
            maxLineWeight: max(0.75, base * 6.0),
            tiltInfluence: 0.0,
            rotationInfluence: 0.0)
    }

    public static func from(
        xdata: [String: XDataValue],
        fallbackBaseLineWeight: Double
    ) -> PenStrokeBrushSettings {
        let defaults = defaults(baseLineWeight: fallbackBaseLineWeight)

        func double(_ key: String, fallback: Double) -> Double {
            switch xdata[key] {
            case .double(let value)?: return value
            case .int(let value)?: return Double(value)
            default: return fallback
            }
        }

        return PenStrokeBrushSettings(
            minLineWeight: double("zephyr.penMinLineWeight", fallback: defaults.minLineWeight),
            maxLineWeight: double("zephyr.penMaxLineWeight", fallback: defaults.maxLineWeight),
            tiltInfluence: double("zephyr.penTiltInfluence", fallback: defaults.tiltInfluence),
            rotationInfluence: double("zephyr.penRotationInfluence", fallback: defaults.rotationInfluence))
    }

    public func apply(to entity: inout CADEntity) {
        entity.xdata["zephyr.penMinLineWeight"] = .double(minLineWeight)
        entity.xdata["zephyr.penMaxLineWeight"] = .double(maxLineWeight)
        entity.xdata["zephyr.penTiltInfluence"] = .double(tiltInfluence)
        entity.xdata["zephyr.penRotationInfluence"] = .double(rotationInfluence)
    }

    public func lineWeight(
        from first: PenStrokeVertex,
        to second: PenStrokeVertex,
        segmentAngle: Double
    ) -> Double {
        let pressure = clamp01((first.pressure + second.pressure) * 0.5)
        let tilt0 = min(1.0, hypot(first.xtilt, first.ytilt) / 90.0)
        let tilt1 = min(1.0, hypot(second.xtilt, second.ytilt) / 90.0)
        let tilt = (tilt0 + tilt1) * 0.5

        var normalizedWidth = pressure
        normalizedWidth += tiltInfluence * tilt * (1.0 - normalizedWidth)

        if rotationInfluence > 0.0 {
            let a0 = first.rotation * .pi / 180.0
            let a1 = second.rotation * .pi / 180.0
            let sx = sin(a0) + sin(a1)
            let cx = cos(a0) + cos(a1)
            let nibAngle = abs(sx) + abs(cx) > 1e-9 ? atan2(sx, cx) : a0
            let crossNib = abs(sin(segmentAngle - nibAngle))
            let directionalScale = 0.25 + 0.75 * crossNib
            normalizedWidth *= (1.0 - rotationInfluence) + rotationInfluence * directionalScale
        }

        let t = clamp01(normalizedWidth)
        return minLineWeight + (maxLineWeight - minLineWeight) * t
    }

    public func pixelWidth(
        from first: PenStrokeVertex,
        to second: PenStrokeVertex,
        segmentAngle: Double
    ) -> Float {
        max(1.0, Float(lineWeight(from: first, to: second, segmentAngle: segmentAngle) * (96.0 / 25.4)))
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
