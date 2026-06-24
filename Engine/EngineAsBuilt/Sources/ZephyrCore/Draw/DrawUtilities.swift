import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - DrawUtilities — Shared helpers for drawing command overlays
// =========================================================================

/// Compute an ImGui packed colour (0xAABBGGRR) from 0–255 components.
public func makeCol32(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
    return (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r)
}

/// Generate world-space points for an ellipse outline.
public func generateEllipsePoints(
    center: Vector3,
    majorAxis: Vector3,
    minorRatio: Double,
    segments: Int = 64
) -> [Vector3] {
    let majorLen = majorAxis.magnitude
    let minorLen = majorLen * minorRatio
    let rot = atan2(majorAxis.y, majorAxis.x)
    let cosRot = cos(rot)
    let sinRot = sin(rot)

    var points: [Vector3] = []
    for i in 0...segments {
        let t = Double(i) * 2.0 * .pi / Double(segments)
        let px = majorLen * cos(t)
        let py = minorLen * sin(t)
        let rx = px * cosRot - py * sinRot + center.x
        let ry = px * sinRot + py * cosRot + center.y
        points.append(Vector3(x: rx, y: ry, z: center.z))
    }
    return points
}

/// Compute the distance from a point to a line segment (world-space).
public func pointToSegmentDistance(_ point: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lenSq = dx * dx + dy * dy
    if lenSq < 1e-12 { return point.distance(to: a) }

    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
    t = max(0, min(1, t))
    let proj = Vector3(x: a.x + t * dx, y: a.y + t * dy, z: 0)
    return point.distance(to: proj)
}

/// Generate uniform clamped knot vector for a spline of given degree and control point count.
public func generateUniformKnots(controlPointCount: Int, degree: Int) -> [Double] {
    let n = controlPointCount - 1
    let knotCount = n + degree + 2
    var knots: [Double] = []
    for i in 0..<knotCount {
        if i <= degree {
            knots.append(0.0)
        } else if i >= knotCount - degree - 1 {
            knots.append(1.0)
        } else {
            let internalCount = knotCount - 2 * (degree + 1)
            if internalCount > 0 {
                knots.append(Double(i - degree) / Double(internalCount + 1))
            } else {
                knots.append(0.5)
            }
        }
    }
    return knots
}
