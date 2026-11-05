import XCTest
@testable import ZephyrKernel

// =========================================================================
// MARK: - ZephyrKernel precision + regression tests
//
// Absolute-precision gates (PLAN-kernel-perf.md Step 1/2):
//   * bulge round-trip |arc.bulge - bulge| <= 1e-12, agreement with the
//     CADPolyline closed form (same formula, duplicated here as reference)
//   * analytic intersections at state-plane magnitudes (2.4e6) — zero misses
//   * circle-wrap split, width interpolation, tangent/flip cases

final class ZephyrKernelTests: XCTestCase {

    // MARK: - Bulge math

    func testBulgeRoundTrip() {
        let cases: [(Point2d, Point2d, Double)] = [
            (.init(x: 0, y: 0), .init(x: 10, y: 0), 0.25),
            (.init(x: 0, y: 0), .init(x: 10, y: 0), -0.5),
            (.init(x: 1, y: 2), .init(x: -3, y: 7), 1.0),
            (.init(x: 0, y: 0), .init(x: 10, y: 0), 0.03073176818630792), // 7-degree arc
            // State-plane magnitude coords.
            (.init(x: 2_450_192.8475, y: 1_948_271.1250), .init(x: 2_450_292.8475, y: 1_948_371.1250), 0.17632698070846498),
        ]
        for (s, e, b) in cases {
            guard let arc = Arc2d.fromBulge(start: s, end: e, bulge: b) else {
                XCTFail("fromBulge returned nil for bulge \(b)")
                continue
            }
            XCTAssertEqual(arc.bulge, b, accuracy: 1e-12, "bulge round-trip failed for \(b)")
            XCTAssertEqual(arc.startPoint.x, s.x, accuracy: 1e-9)
            XCTAssertEqual(arc.startPoint.y, s.y, accuracy: 1e-9)
            XCTAssertEqual(arc.endPoint.x, e.x, accuracy: 1e-9)
            XCTAssertEqual(arc.endPoint.y, e.y, accuracy: 1e-9)
        }
    }

    func testBulgeZeroThresholdMatchesCADPolyline() {
        // CADPolyline uses 1e-12; kernel must agree exactly.
        XCTAssertEqual(KernelTolerance.bulgeZero, 1e-12)
        XCTAssertNil(Arc2d.fromBulge(start: .zero, end: Point2d(x: 10, y: 0), bulge: 1e-13))
        XCTAssertNotNil(Arc2d.fromBulge(start: .zero, end: Point2d(x: 10, y: 0), bulge: 1e-9))
    }

    func testBulgeSweepIdentity() {
        // b = tan(sweep/4) <=> sweep = 4*atan(b), including CW (negative).
        for b in [0.05, -0.2, 0.999, -2.0] {
            let arc = Arc2d(center: .zero, radius: 5, startAngle: 0.3, sweep: 4.0 * atan(b))
            XCTAssertEqual(arc.bulge, b, accuracy: 1e-15)
        }
    }

    // MARK: - Line-line at state-plane coords (local-frame shifting)

    func testLineLineStatePlane() {
        let ox = 2_450_192.8475, oy = 1_948_271.1250
        let a = LineSeg2d(start: Point2d(x: ox, y: oy), end: Point2d(x: ox + 100, y: oy + 100))
        let b = LineSeg2d(start: Point2d(x: ox, y: oy + 100), end: Point2d(x: ox + 100, y: oy))
        let hits = Intersector2D.intersectLineLine(a, b, extendA: false, extendB: false)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].point.x, ox + 50, accuracy: 1e-6)
        XCTAssertEqual(hits[0].point.y, oy + 50, accuracy: 1e-6)
        XCTAssertEqual(hits[0].paramA, 0.5, accuracy: 1e-9)
    }

    func testLineLineParallelMiss() {
        let a = LineSeg2d(start: .zero, end: Point2d(x: 10, y: 0))
        let b = LineSeg2d(start: Point2d(x: 0, y: 1), end: Point2d(x: 10, y: 1))
        XCTAssertTrue(Intersector2D.intersectLineLine(a, b, extendA: false, extendB: false).isEmpty)
    }

    // MARK: - Line-arc (secant / tangent / miss)

    func testLineArcSecantStatePlane() {
        let ox = 2_450_192.8475, oy = 1_948_271.1250
        let arc = Arc2d(center: Point2d(x: ox, y: oy), radius: 100, startAngle: 0, sweep: 2.0 * .pi)
        let line = LineSeg2d(start: Point2d(x: ox - 150, y: oy), end: Point2d(x: ox + 150, y: oy))
        let hits = Intersector2D.intersectLineArc(line, arc, extendLine: false, extendArc: false)
        XCTAssertEqual(hits.count, 2)
        let xs = hits.map { $0.point.x }.sorted()
        XCTAssertEqual(xs[0], ox - 100, accuracy: 1e-6)
        XCTAssertEqual(xs[1], ox + 100, accuracy: 1e-6)
    }

    func testLineArcTangent() {
        let arc = Arc2d(center: .zero, radius: 5, startAngle: 0, sweep: 2.0 * .pi)
        let line = LineSeg2d(start: Point2d(x: -10, y: 5), end: Point2d(x: 10, y: 5))
        let hits = Intersector2D.intersectLineArc(line, arc, extendLine: false, extendArc: false)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].point.x, 0, accuracy: 1e-9)
        XCTAssertEqual(hits[0].point.y, 5, accuracy: 1e-9)
    }

    func testLineArcMiss() {
        let arc = Arc2d(center: .zero, radius: 5, startAngle: 0, sweep: .pi / 2)
        let line = LineSeg2d(start: Point2d(x: -10, y: -10), end: Point2d(x: -5, y: -10))
        XCTAssertTrue(Intersector2D.intersectLineArc(line, arc, extendLine: false, extendArc: false).isEmpty)
    }

    // MARK: - Arc-arc

    func testArcArcTwoHits() {
        let a = Arc2d(center: .zero, radius: 5, startAngle: 0, sweep: 2.0 * .pi)
        let b = Arc2d(center: Point2d(x: 6, y: 0), radius: 5, startAngle: 0, sweep: 2.0 * .pi)
        let hits = Intersector2D.intersectArcArc(a, b, extendA: false, extendB: false)
        XCTAssertEqual(hits.count, 2)
        for h in hits {
            XCTAssertEqual(h.point.x, 3, accuracy: 1e-9)
            XCTAssertEqual(abs(h.point.y), 4, accuracy: 1e-9)
        }
    }

    func testArcArcStatePlane() {
        let ox = 2_450_192.8475, oy = 1_948_271.1250
        let a = Arc2d(center: Point2d(x: ox, y: oy), radius: 50, startAngle: 0, sweep: 2.0 * .pi)
        let b = Arc2d(center: Point2d(x: ox + 60, y: oy), radius: 50, startAngle: 0, sweep: 2.0 * .pi)
        let hits = Intersector2D.intersectArcArc(a, b, extendA: false, extendB: false)
        XCTAssertEqual(hits.count, 2)
        for h in hits { XCTAssertEqual(h.point.x, ox + 30, accuracy: 1e-6) }
    }

    // MARK: - Split semantics (R10: circle wrap)

    func testCircleSplitNoNegativeSweep() {
        let c = Circle2d(center: .zero, radius: 10)
        // Wrap interval (tB < tA) is rejected: caller must emit two arcs.
        XCTAssertNil(CurveEval.splitAt(.circle(c), t1: 0.75, t2: 0.25))
        guard case .arc(let a)? = CurveEval.splitAt(.circle(c), t1: 0.1, t2: 0.4) else {
            return XCTFail("expected arc")
        }
        XCTAssertGreaterThan(a.sweep, 0)
        XCTAssertEqual(a.sweep, 2.0 * .pi * 0.3, accuracy: 1e-12)
    }

    func testPolySegmentWidthInterpolation() {
        let seg = PolySegment2d(index: 3, start: .zero, end: Point2d(x: 10, y: 0),
                                bulge: 0, startWidth: 1.0, endWidth: 3.0)
        guard case .polySegment(let sub)? = CurveEval.splitAt(.polySegment(seg), t1: 0.25, t2: 0.75) else {
            return XCTFail("expected polySegment")
        }
        XCTAssertEqual(sub.startWidth, 1.5, accuracy: 1e-12)
        XCTAssertEqual(sub.endWidth, 2.5, accuracy: 1e-12)
        XCTAssertEqual(sub.index, 3)
    }

    // MARK: - Ellipse

    func testLineEllipseSecant() {
        let e = Ellipse2d(center: .zero, majorAxis: Vec2d(x: 10, y: 0), minorRatio: 0.5)
        let line = LineSeg2d(start: Point2d(x: -15, y: 0), end: Point2d(x: 15, y: 0))
        let hits = Intersector2D.intersect(.line(line), .ellipse(e))
        XCTAssertEqual(hits.count, 2)
        let xs = hits.map { $0.point.x }.sorted()
        XCTAssertEqual(xs[0], -10, accuracy: 1e-9)
        XCTAssertEqual(xs[1], 10, accuracy: 1e-9)
    }

    // MARK: - Spline

    func testSplineStraightLine() {
        // Clamped degree-1 spline is exactly the control segment.
        let s = Spline2d(controlPoints: [.zero, Point2d(x: 10, y: 0)],
                         knots: [0, 0, 1, 1], degree: 1)
        for t in [0.0, 0.25, 0.5, 1.0] {
            let p = CurveEval.pointAt(.spline(s), t: t)
            XCTAssertEqual(p.x, 10 * t, accuracy: 1e-12)
            XCTAssertEqual(p.y, 0, accuracy: 1e-12)
        }
    }

    func testSplineQuadraticMidpoint() {
        // Quadratic Bezier midpoint = 0.25*P0 + 0.5*P1 + 0.25*P2.
        let s = Spline2d(controlPoints: [.zero, Point2d(x: 5, y: 10), Point2d(x: 10, y: 0)],
                         knots: [0, 0, 0, 1, 1, 1], degree: 2)
        let mid = CurveEval.pointAt(.spline(s), t: 0.5)
        XCTAssertEqual(mid.x, 5, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 5, accuracy: 1e-9)
    }

    func testLineSplineHit() {
        let s = Spline2d(controlPoints: [.zero, Point2d(x: 5, y: 10), Point2d(x: 10, y: 0)],
                         knots: [0, 0, 0, 1, 1, 1], degree: 2)
        let line = LineSeg2d(start: Point2d(x: -5, y: 5), end: Point2d(x: 15, y: 5))
        let hits = Intersector2D.intersect(.line(line), .spline(s))
        XCTAssertFalse(hits.isEmpty)
        for h in hits {
            XCTAssertEqual(h.point.y, 5, accuracy: 1e-6)
        }
    }

    func testSplineSplineHitPolishesToCurve() {
        // Golden crossing from Tools/oracles/spline_exact.py: the cubic crosses
        // y = -148 on its right branch at this x.
        let cubic = Spline2d(
            controlPoints: [
                Point2d(x: -593, y: 77),
                Point2d(x: -485, y: -422),
                Point2d(x: 74.03219943040847, y: -422),
                Point2d(x: 256, y: 78),
            ],
            knots: [0, 0, 0, 0, 1, 1, 1, 1],
            degree: 3)
        let horizontal = Spline2d(
            controlPoints: [
                Point2d(x: -657, y: -148),
                Point2d(x: 306.02544099312354, y: -148),
            ],
            knots: [0, 0, 1, 1],
            degree: 1)
        let hits = Intersector2D.intersect(.spline(cubic), .spline(horizontal))
        XCTAssertEqual(hits.count, 2)
        guard let right = hits.filter({ $0.point.x > 0 }).max(by: { $0.point.x < $1.point.x }) else {
            return XCTFail("missing the right-branch spline-spline hit")
        }
        XCTAssertEqual(right.point.x, 121.69301292060802, accuracy: 1e-9)
        XCTAssertEqual(right.point.y, -148, accuracy: 1e-9)
    }

    // MARK: - Projection / fillet / offset

    func testClosestPointArc() {
        let arc = Arc2d(center: .zero, radius: 5, startAngle: 0, sweep: .pi / 2)
        let proj = Projector2D.closestPointOnCurve(.arc(arc), to: Point2d(x: 10, y: 0))
        XCTAssertEqual(proj.point.x, 5, accuracy: 1e-9)
        XCTAssertEqual(proj.point.y, 0, accuracy: 1e-9)
    }

    func testClosestPointSplineConverges() {
        // Query near a known on-curve point: projection must recover it to
        // 1e-9 (hill-climb alone stalled ~1e-4 on long splines).
        let s = Spline2d(controlPoints: [.zero, Point2d(x: 5, y: 10), Point2d(x: 10, y: 0)],
                         knots: [0, 0, 0, 1, 1, 1], degree: 2)
        let onCurve = CurveEval.pointAt(.spline(s), t: 0.37)
        let tan = CurveEval.tangentAt(.spline(s), t: 0.37)
        let n = tan.perpCCW.normalized
        let query = onCurve + (n * 0.5)
        let proj = Projector2D.closestPointOnCurve(.spline(s), to: query)
        XCTAssertEqual(proj.point.x, onCurve.x, accuracy: 1e-9)
        XCTAssertEqual(proj.point.y, onCurve.y, accuracy: 1e-9)
        XCTAssertEqual(proj.param, 0.37, accuracy: 1e-9)
    }

    func testFilletLineLine() {
        let a = Curve2d.line(LineSeg2d(start: .zero, end: Point2d(x: 10, y: 0)))
        let b = Curve2d.line(LineSeg2d(start: Point2d(x: 10, y: 0), end: Point2d(x: 10, y: 10)))
        guard let sol = Projector2D.filletCurves(a, pickA: Point2d(x: 2, y: 0),
                                                 b, pickB: Point2d(x: 10, y: 2), radius: 2) else {
            return XCTFail("fillet failed")
        }
        XCTAssertNotNil(sol.filletArc)
        XCTAssertEqual(sol.filletArc?.radius ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(sol.filletArc?.center.x ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(sol.filletArc?.center.y ?? -1, 2, accuracy: 1e-9)
    }

    func testOffsetPolylineRectangle() {
        let pts = [Point2d(x: 0, y: 0), Point2d(x: 10, y: 0), Point2d(x: 10, y: 5), Point2d(x: 0, y: 5)]
        var segs: [PolySegment2d] = []
        for i in 0..<4 {
            segs.append(PolySegment2d(index: i, start: pts[i], end: pts[(i + 1) % 4], bulge: 0))
        }
        // CCW rectangle; outward (right of travel) = positive... travel is CCW,
        // left of travel is inward. Offset outward by 1 => signedDistance -1.
        guard let out = Offset2D.offsetPolylineSegments(segs, isClosed: true, signedDistance: -1.0) else {
            return XCTFail("offset failed")
        }
        XCTAssertEqual(out.count, 4)
        var box: BoundingBox2d? = nil
        for s in out {
            for p in [s.startPoint, s.endPoint] {
                if box == nil { box = BoundingBox2d(point: p) } else { box!.include(p) }
            }
        }
        XCTAssertEqual(box?.min.x ?? 999, -1, accuracy: 1e-9)
        XCTAssertEqual(box?.max.x ?? -999, 11, accuracy: 1e-9)
        XCTAssertEqual(box?.min.y ?? 999, -1, accuracy: 1e-9)
        XCTAssertEqual(box?.max.y ?? -999, 6, accuracy: 1e-9)
    }
}
