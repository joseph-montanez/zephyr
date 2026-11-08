import Foundation

// MARK: - GalacticStarfield
//
// Deterministic viewport starfield for the Galactic Purple theme.
//
// Design notes:
// - Pure functions only (no ImGui, no SDL), so unit tests can verify the
//   panorama wrap, twinkle range, and time advancement without a GPU.
// - Star positions are derived from a SplitMix64-style hash of the star
//   index, so the field is stable across frames and machines.
// - "Panorama" means a continuous horizontal drift with wrap-around: every
//   star moves left at `speed * parallax`, where parallax encodes depth
//   (distant stars drift slower). Vertical position stays fixed so CAD
//   geometry stays easy to track against the background.
// - Twinkle is a per-star sine pulse in the 0.30...1.00 alpha range.

public enum GalacticStarfield: Sendable {
    /// Number of stars drawn per viewport.
    public static let starCount = 160
    /// Time wraps here to keep Float precision healthy (~1 hour).
    public static let wrapPeriodSec: Double = 3600.0
    /// Base drift speed in points/sec at parallax 1.
    public static let baseSpeed: Float = 3.0

    // MARK: - Hash

    @inline(__always)
    static func hash64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Deterministic pseudo-random value in 0..<1 for a star index + salt.
    public static func hash01(index: Int, salt: UInt64) -> Double {
        let mixed = UInt64(bitPattern: Int64(index)) &* 0x9E3779B97F4A7C15 &+ salt &+ 0x9E3779B97F4A7C15
        return Double(hash64(mixed)) / Double(UInt64.max)
    }

    // MARK: - Layout

    /// Depth factor: distant stars (small) drift slower than near ones.
    public static func parallax(index: Int) -> Float {
        0.25 + 0.75 * Float(hash01(index: index, salt: 0x33))
    }

    /// Stable home position inside a width x height viewport.
    public static func basePosition(index: Int, width: Float, height: Float) -> (x: Float, y: Float) {
        let x = Float(hash01(index: index, salt: 0x11)) * width
        let y = Float(hash01(index: index, salt: 0x22)) * height
        return (x, y)
    }

    /// Panorama position: drifts left over time, wraps around the width.
    public static func screenPosition(
        index: Int,
        timeSec: Double,
        width: Float,
        height: Float,
        speed: Float = baseSpeed
    ) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (0, 0) }
        let base = basePosition(index: index, width: width, height: height)
        let drift = Float(timeSec) * speed * parallax(index: index)
        var x = (base.x - drift).truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
        return (x, base.y)
    }

    // MARK: - Twinkle + Style

    /// Blinking brightness in 0.30...1.00. Each star has its own phase/speed.
    public static func twinkleAlpha(index: Int, timeSec: Double) -> Float {
        let phase = hash01(index: index, salt: 0x44) * 2.0 * Double.pi
        let speedHz = 1.2 + 2.3 * hash01(index: index, salt: 0x45)
        let wave = 0.5 + 0.5 * sin(timeSec * speedHz + phase)
        return Float(0.30 + 0.70 * wave)
    }

    /// Star radius in points (1.0...2.4, brightest ~3.3).
    public static func radius(index: Int) -> Float {
        var r = 1.0 + 1.4 * Float(hash01(index: index, salt: 0x55))
        if hash01(index: index, salt: 0x66) > 0.92 {
            r += 0.9
        }
        return r
    }

    /// Star tint: real stellar colors, from blue-white giants through Sun-like
    /// yellows to orange and red-orange dwarfs. Never green: no tint peaks
    /// in green, because green stars do not exist.
    public static func tint(index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let pick = hash01(index: index, salt: 0x77)
        switch pick {
        case ..<0.10:
            return (155, 176, 255) // blue giant
        case ..<0.30:
            return (198, 210, 255) // blue-white
        case ..<0.55:
            return (255, 255, 255) // white
        case ..<0.72:
            return (255, 244, 232) // warm white
        case ..<0.85:
            return (255, 224, 162) // Sun-like yellow
        case ..<0.95:
            return (255, 186, 112) // orange dwarf
        default:
            return (255, 150, 110) // red-orange dwarf
        }
    }

    // MARK: - Clock

    /// Advance the panorama clock, clamped and wrapped for precision.
    public static func advance(current: Double, by deltaSec: Double) -> Double {
        let clamped = min(max(deltaSec, 0.0), 0.25)
        guard clamped > 0 else { return current }
        let next = current + clamped
        if next >= wrapPeriodSec {
            return next.truncatingRemainder(dividingBy: wrapPeriodSec)
        }
        return next
    }
}

// MARK: - Zoom (fly-through)

extension GalacticStarfield {
    /// Zoom scale relative to the reference zoom, clamped to a sane range.
    public static func zoomScale(zoom: Double, referenceZoom: Double) -> Double {
        guard referenceZoom > 0 else { return 1 }
        return min(max(zoom / referenceZoom, 0.25), 6.0)
    }

    @inline(__always)
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Screenspace panorama position: stars always cover the full viewport.
    /// Zoom scales drift speed (zooming in flies faster through the field);
    /// size and fade respond separately via scaledRadius/zoomFade.
    public static func screenPosition(
        index: Int,
        timeSec: Double,
        width: Float,
        height: Float,
        speed: Float,
        zoom: Double,
        referenceZoom: Double
    ) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = zoomScale(zoom: zoom, referenceZoom: referenceZoom)
        let base = basePosition(index: index, width: width, height: height)
        let drift = Float(timeSec) * speed * parallax(index: index) * Float(scale)
        var x = (base.x - drift).truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
        return (x, base.y)
    }

    /// Zoom-scaled star radius, clamped so stars never vanish or dominate.
    public static func scaledRadius(index: Int, zoom: Double, referenceZoom: Double) -> Float {
        let r = radius(index: index) * Float(zoomScale(zoom: zoom, referenceZoom: referenceZoom))
        return min(max(r, 0.75), 7.0)
    }

    /// Fly-through fade in 0...1: big (near) stars dissolve as you zoom in
    /// past them; small (far) stars dissolve as you zoom far out.
    public static func zoomFade(index: Int, zoom: Double, referenceZoom: Double) -> Double {
        guard referenceZoom > 0 else { return 1 }
        let logZ = log2(max(zoom / referenceZoom, 1e-6))
        let sizeNorm = min(max((Double(radius(index: index)) - 1.0) / 2.3, 0), 1)
        let nearFade = 1.0 - 0.9 * sizeNorm * smoothstep(0.5, 2.5, logZ)
        let farFade = 1.0 - 0.7 * (1.0 - sizeNorm) * smoothstep(0.5, 2.5, -logZ)
        return min(max(nearFade * farFade, 0), 1)
    }
}

// MARK: - Mouse parallax

extension GalacticStarfield {
    /// Max star shift in points at the viewport edge for parallax 1.
    public static let mouseParallaxStrength: Float = 60.0
    /// Mouse-follow smoothing rate (1/sec).
    public static let mouseSmoothingRate: Double = 10.0

    /// Target shift for one axis, opposite the mouse: the mouse right of
    /// center pushes stars left. delta is center-minus-mouse in points.
    public static func mouseParallaxTarget(delta: Float, halfExtent: Float, parallax: Float) -> Float {
        guard halfExtent > 0 else { return 0 }
        let clamped = min(max(delta / halfExtent, -1), 1)
        return clamped * mouseParallaxStrength * parallax
    }

    /// Exponential smoothing step toward the target offset.
    public static func smoothOffset(current: Float, target: Float, deltaSec: Double, rate: Double = mouseSmoothingRate) -> Float {
        let clamped = min(max(deltaSec, 0.0), 0.25)
        guard clamped > 0 else { return current }
        let t = Float(1.0 - exp(-clamped * rate))
        return current + (target - current) * t
    }

    /// Applies the smoothed mouse offset (scaled by depth) with wrap-around.
    public static func applyMouseParallax(
        x: Float, y: Float,
        offsetX: Float, offsetY: Float,
        parallax: Float,
        width: Float, height: Float
    ) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (x, y) }
        var ox = (x + offsetX * parallax).truncatingRemainder(dividingBy: width)
        if ox < 0 { ox += width }
        var oy = (y + offsetY * parallax).truncatingRemainder(dividingBy: height)
        if oy < 0 { oy += height }
        return (ox, oy)
    }
}
