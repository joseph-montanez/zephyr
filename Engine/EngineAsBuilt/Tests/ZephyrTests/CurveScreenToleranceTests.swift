import XCTest
@testable import ZephyrCore

// Independent golden geometry comes from Tools/oracles/spline_exact.py and
// Tools/oracles/render_cross.py. The oracle crossing is y = -148 at
// x = 121.69301292060802241 for the right branch of this diagnostic spline.
final class CurveScreenToleranceTests: XCTestCase {
    private static let controlPoints = [
        Vector3(x: -593, y: 77, z: 0),
        Vector3(x: -485, y: -422, z: 0),
        Vector3(x: 74.03219943040847, y: -422, z: 0),
        Vector3(x: 256, y: 78, z: 0),
    ]
    private static let knots = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]

    private static func segmentDeviation(_ point: Vector3, _ start: Vector3, _ end: Vector3) -> Double {
        let chord = end - start
        let lengthSquared = chord.magnitudeSquared
        guard lengthSquared > 1e-24 else { return point.distance(to: start) }
        let projection = max(0, min(1, (point - start).dot(chord) / lengthSquared))
        return point.distance(to: start + chord * projection)
    }

    func testHighZoomSplineChordsRespectQuarterPixelSagitta() {
        let zoom = 1_000.0
        let allowedWorldError = 0.25 / zoom
        let weights = Array(repeating: 1.0, count: Self.controlPoints.count)
        let tessellation = CurveScreenTessellation.tessellateSpline(
            degree: 3,
            knots: Self.knots,
            controlPoints: Self.controlPoints,
            weights: weights,
            pixelsPerUnit: zoom)
        XCTAssertFalse(tessellation.didHitMaximumSegments)
        XCTAssertGreaterThanOrEqual(tessellation.points.count, 3)

        var worstDeviation = 0.0
        for index in 0..<(tessellation.points.count - 1) {
            let startParameter = Double(index) / Double(tessellation.points.count - 1)
            let endParameter = Double(index + 1) / Double(tessellation.points.count - 1)
            for sample in 1..<100 {
                let parameter = startParameter + (endParameter - startParameter) * Double(sample) / 100.0
                let point = NURBSEvaluator.evaluateAt(
                    degree: 3,
                    knots: Self.knots,
                    controlPoints: Self.controlPoints,
                    weights: weights,
                    at: parameter)!
                worstDeviation = max(
                    worstDeviation,
                    Self.segmentDeviation(point, tessellation.points[index], tessellation.points[index + 1]))
            }
        }

        XCTAssertLessThanOrEqual(
            worstDeviation,
            allowedWorldError,
            "Screen-space tessellation exceeds the quarter-pixel limit at this zoom.")
    }

    func testScreenToleranceZoomBandsAndSegmentCounts() {
        XCTAssertEqual(CurveScreenTessellation.zoomBand(for: 1_000.0), 9)
        XCTAssertEqual(
            CurveScreenTessellation.designZoom(for: 9),
            1_024.0,
            accuracy: 1e-9)
        XCTAssertEqual(
            CurveScreenTessellation.worldTolerance(pixelsPerUnit: 1_000.0),
            0.25 / 1_024.0,
            accuracy: 1e-12)
        XCTAssertEqual(
            CurveScreenTessellation.zoomBand(for: 1.99, currentBand: 0),
            0)
        XCTAssertEqual(
            CurveScreenTessellation.zoomBand(for: 2.05, currentBand: 0),
            1)
        XCTAssertEqual(
            CurveScreenTessellation.zoomBand(for: 1.9, currentBand: 1),
            1)
        XCTAssertEqual(
            CurveScreenTessellation.zoomBand(for: 1.7, currentBand: 1),
            0)
        XCTAssertEqual(
            CurveScreenTessellation.circleSegmentCount(radius: 500.0, tolerance: 0.00025),
            3_142)
        XCTAssertEqual(
            CurveScreenTessellation.circularSegmentCount(radius: 1.0, sweep: .pi / 2.0, tolerance: 0.125),
            2)
    }
}
