import XCTest
@testable import ZephyrCore

@MainActor
final class OffsetCommandTests: XCTestCase {

    private func v(_ x: Double, _ y: Double) -> Vector3 { Vector3(x: x, y: y, z: 0) }

    private func offset(
        _ primitive: CADPrimitive, mode: OffsetMode, gapType: OffsetGapType = .extend
    ) -> CADPrimitive? {
        OffsetGeometryEngine.offset(
            primitive: primitive, transform: .identity, mode: mode, gapType: gapType)
    }

    private func assertPoint(
        _ point: Vector3, _ x: Double, _ y: Double,
        accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(point.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Line / Ray

    func testOffsetLineBothSides() {
        let line: CADPrimitive = .line(start: v(0, 0), end: v(10, 0), color: nil)

        let above = offset(line, mode: .distance(2, sidePoint: v(5, 5)))
        guard case .line(let s1, let e1, _) = above else { return XCTFail("expected line") }
        assertPoint(s1, 0, 2); assertPoint(e1, 10, 2)

        let below = offset(line, mode: .distance(2, sidePoint: v(5, -5)))
        guard case .line(let s2, let e2, _) = below else { return XCTFail("expected line") }
        assertPoint(s2, 0, -2); assertPoint(e2, 10, -2)
    }

    func testOffsetLineThrough() {
        let line: CADPrimitive = .line(start: v(0, 0), end: v(10, 0), color: nil)
        let result = offset(line, mode: .through(v(3, 4)))
        guard case .line(let s, let e, _) = result else { return XCTFail("expected line") }
        assertPoint(s, 0, 4); assertPoint(e, 10, 4)

        XCTAssertNil(offset(line, mode: .through(v(5, 0))), "through point on the line")
        XCTAssertNil(offset(line, mode: .distance(0, sidePoint: v(5, 5))))
        XCTAssertNil(offset(line, mode: .distance(-3, sidePoint: v(5, 5))))
    }

    func testOffsetRay() {
        let ray: CADPrimitive = .ray(start: v(0, 0), direction: v(1, 0), color: nil)
        let result = offset(ray, mode: .distance(3, sidePoint: v(5, -1)))
        guard case .ray(let start, let direction, _) = result else {
            return XCTFail("expected ray")
        }
        assertPoint(start, 0, -3)
        assertPoint(direction, 1, 0)
    }

    // MARK: - Circle / Arc

    func testOffsetCircle() {
        let circle: CADPrimitive = .circle(center: v(0, 0), radius: 5, color: nil)

        let outside = offset(circle, mode: .distance(2, sidePoint: v(10, 0)))
        guard case .circle(let c1, let r1, _) = outside else { return XCTFail("expected circle") }
        assertPoint(c1, 0, 0); XCTAssertEqual(r1, 7, accuracy: 1e-9)

        let inside = offset(circle, mode: .distance(2, sidePoint: v(1, 0)))
        guard case .circle(_, let r2, _) = inside else { return XCTFail("expected circle") }
        XCTAssertEqual(r2, 3, accuracy: 1e-9)

        XCTAssertNil(offset(circle, mode: .distance(5, sidePoint: v(1, 0))))
        XCTAssertNil(offset(circle, mode: .distance(6, sidePoint: v(1, 0))))

        let through = offset(circle, mode: .through(v(8, 0)))
        guard case .circle(_, let r3, _) = through else { return XCTFail("expected circle") }
        XCTAssertEqual(r3, 8, accuracy: 1e-9)
    }

    func testOffsetArc() {
        let arc: CADPrimitive = .arc(
            center: v(0, 0), radius: 5, startAngle: 0, endAngle: .pi / 2, color: nil)
        let diag = 10.0 / sqrt(2.0)

        let outside = offset(arc, mode: .distance(1, sidePoint: v(diag, diag)))
        guard case .arc(_, let r1, let s1, let e1, _) = outside else {
            return XCTFail("expected arc")
        }
        XCTAssertEqual(r1, 6, accuracy: 1e-9)
        XCTAssertEqual(s1, 0, accuracy: 1e-9)
        XCTAssertEqual(e1, .pi / 2, accuracy: 1e-9)

        let inside = offset(arc, mode: .distance(1, sidePoint: v(1, 1)))
        guard case .arc(_, let r2, _, _, _) = inside else { return XCTFail("expected arc") }
        XCTAssertEqual(r2, 4, accuracy: 1e-9)
    }

    // MARK: - Polylines

    private var closedRect: CADPolyline {
        CADPolyline(points: [v(0, 0), v(10, 0), v(10, 6), v(0, 6)], isClosed: true)
    }

    func testOffsetClosedRectExtend() {
        let prim: CADPrimitive = .polyline(path: closedRect, color: nil)

        let outward = offset(prim, mode: .distance(1, sidePoint: v(-5, 3)))
        guard case .polyline(let outPath, _) = outward else { return XCTFail("expected polyline") }
        XCTAssertTrue(outPath.isClosed)
        XCTAssertEqual(outPath.points.count, 4)
        assertPoint(outPath.points[0], -1, -1)
        assertPoint(outPath.points[1], 11, -1)
        assertPoint(outPath.points[2], 11, 7)
        assertPoint(outPath.points[3], -1, 7)
        XCTAssertFalse(outPath.hasBulges)

        let inward = offset(prim, mode: .distance(1, sidePoint: v(5, 3)))
        guard case .polyline(let inPath, _) = inward else { return XCTFail("expected polyline") }
        assertPoint(inPath.points[0], 1, 1)
        assertPoint(inPath.points[1], 9, 1)
        assertPoint(inPath.points[2], 9, 5)
        assertPoint(inPath.points[3], 1, 5)

        // Inward past half the height collapses.
        XCTAssertNil(offset(prim, mode: .distance(4, sidePoint: v(5, 3))))
    }

    func testOffsetClosedRectThrough() {
        let prim: CADPrimitive = .polyline(path: closedRect, color: nil)
        let result = offset(prim, mode: .through(v(-2, 3)))
        guard case .polyline(let path, _) = result else { return XCTFail("expected polyline") }
        assertPoint(path.points[0], -2, -2)
        assertPoint(path.points[2], 12, 8)
    }

    func testOffsetClosedRectFilletedCorners() {
        let prim: CADPrimitive = .polyline(path: closedRect, color: nil)
        let result = offset(prim, mode: .distance(1, sidePoint: v(-5, 3)), gapType: .filleted)
        guard case .polyline(let path, _) = result else { return XCTFail("expected polyline") }
        XCTAssertEqual(path.points.count, 8, "4 sides + 4 corner arcs")
        XCTAssertTrue(path.hasBulges)
        var arcCount = 0
        for segment in 0..<path.segmentCount {
            if let arc = path.arcParameters(forSegment: segment) {
                arcCount += 1
                XCTAssertEqual(arc.radius, 1, accuracy: 1e-6, "join arc radius = offset distance")
            }
        }
        XCTAssertEqual(arcCount, 4)
    }

    func testOffsetOpenPolylineGapTypes() {
        let prim: CADPrimitive = .polyline(
            path: CADPolyline(points: [v(0, 0), v(10, 0), v(10, 10)]), color: nil)
        // Outside of the bend is the lower-right side.
        let side = v(15, -5)

        let extend = offset(prim, mode: .distance(2, sidePoint: side), gapType: .extend)
        guard case .polyline(let ext, _) = extend else { return XCTFail("expected polyline") }
        XCTAssertEqual(ext.points.count, 3)
        assertPoint(ext.points[0], 0, -2)
        assertPoint(ext.points[1], 12, -2, accuracy: 1e-6)
        assertPoint(ext.points[2], 12, 10)

        let chamfer = offset(prim, mode: .distance(2, sidePoint: side), gapType: .chamfered)
        guard case .polyline(let cha, _) = chamfer else { return XCTFail("expected polyline") }
        XCTAssertEqual(cha.points.count, 4)
        assertPoint(cha.points[1], 10, -2)
        assertPoint(cha.points[2], 12, 0)
        XCTAssertFalse(cha.hasBulges)

        let fillet = offset(prim, mode: .distance(2, sidePoint: side), gapType: .filleted)
        guard case .polyline(let fil, _) = fillet else { return XCTFail("expected polyline") }
        XCTAssertEqual(fil.points.count, 4)
        let joinArc = fil.arcParameters(forSegment: 1)
        XCTAssertNotNil(joinArc)
        XCTAssertEqual(joinArc?.radius ?? 0, 2, accuracy: 1e-6)
        assertPoint(joinArc?.center ?? .zero, 10, 0)
    }

    func testOffsetOpenPolylineInsideBendAlwaysTrims() {
        let prim: CADPrimitive = .polyline(
            path: CADPolyline(points: [v(0, 0), v(10, 0), v(10, 10)]), color: nil)
        // Inside of the bend: gap type must not add an arc/chamfer.
        for gapType in OffsetGapType.allCases {
            let result = offset(prim, mode: .distance(2, sidePoint: v(5, 5)), gapType: gapType)
            guard case .polyline(let path, _) = result else {
                return XCTFail("expected polyline for gapType \(gapType)")
            }
            XCTAssertEqual(path.points.count, 3, "gapType \(gapType)")
            assertPoint(path.points[0], 0, 2)
            assertPoint(path.points[1], 8, 2)
            assertPoint(path.points[2], 8, 10)
            XCTAssertFalse(path.hasBulges)
        }
    }

    func testOffsetPolylineBulgeArc() {
        // Semicircle below the chord (0,0)->(10,0): center (5,0), r = 5.
        let path = CADPolyline(vertices: [
            CADPolylineVertex(position: v(0, 0), bulge: 1),
            CADPolylineVertex(position: v(10, 0)),
        ])
        let prim: CADPrimitive = .polyline(path: path, color: nil)

        let outward = offset(prim, mode: .distance(1, sidePoint: v(5, -10)))
        guard case .polyline(let out, _) = outward else { return XCTFail("expected polyline") }
        assertPoint(out.points[0], -1, 0)
        assertPoint(out.points[1], 11, 0)
        XCTAssertEqual(out.arcParameters(forSegment: 0)?.radius ?? 0, 6, accuracy: 1e-6)

        let inward = offset(prim, mode: .distance(1, sidePoint: v(5, -2)))
        guard case .polyline(let inn, _) = inward else { return XCTFail("expected polyline") }
        XCTAssertEqual(inn.arcParameters(forSegment: 0)?.radius ?? 0, 4, accuracy: 1e-6)
    }

    func testOffsetClosedRectClockwiseWinding() {
        // CW winding must offset the same as CCW.
        let cw = CADPolyline(points: [v(0, 0), v(0, 6), v(10, 6), v(10, 0)], isClosed: true)
        let prim: CADPrimitive = .polyline(path: cw, color: nil)
        let outward = offset(prim, mode: .distance(1, sidePoint: v(-5, 3)))
        guard case .polyline(let path, _) = outward else { return XCTFail("expected polyline") }
        XCTAssertEqual(path.points.count, 4)
        assertPoint(path.points[0], -1, -1)
        assertPoint(path.points[1], -1, 7)
        assertPoint(path.points[2], 11, 7)
        assertPoint(path.points[3], 11, -1)

        XCTAssertNil(offset(prim, mode: .distance(4, sidePoint: v(5, 3))),
                     "CW inward over-offset must fail too")
    }

    func testOffsetLineArcNonTangentJoinExtends() {
        // Line east, then a semicircle dipping below the chord (10,0)->(20,0).
        // The arc meets the line at 90 degrees, so the offset join needs a
        // line-circle intersection (extend mode).
        let path = CADPolyline(vertices: [
            CADPolylineVertex(position: v(0, 0)),
            CADPolylineVertex(position: v(10, 0), bulge: 1),
            CADPolylineVertex(position: v(20, 0)),
        ])
        let prim: CADPrimitive = .polyline(path: path, color: nil)
        let result = offset(prim, mode: .distance(1, sidePoint: v(5, 5)), gapType: .extend)
        guard case .polyline(let out, _) = result else { return XCTFail("expected polyline") }
        XCTAssertEqual(out.points.count, 3)
        assertPoint(out.points[0], 0, 1)
        // Join: line y=1 meets offset circle (center (15,0), r=4) at x = 15 - sqrt(15).
        assertPoint(out.points[1], 15 - sqrt(15.0), 1, accuracy: 1e-6)
        assertPoint(out.points[2], 19, 0)
        XCTAssertEqual(out.arcParameters(forSegment: 1)?.radius ?? 0, 4, accuracy: 1e-6)
    }

    func testOffsetRectPrimitive() {
        let rect: CADPrimitive = .rect(origin: v(0, 0), size: v(10, 6), color: nil)
        let result = offset(rect, mode: .distance(1, sidePoint: v(-5, 3)))
        guard case .polyline(let path, _) = result else { return XCTFail("expected polyline") }
        XCTAssertTrue(path.isClosed)
        assertPoint(path.points[0], -1, -1)
        assertPoint(path.points[2], 11, 7)
    }

    // MARK: - Ellipse / Spline

    private func minDistanceToEllipse(_ point: Vector3, a: Double, b: Double) -> Double {
        var best = Double.infinity
        for i in 0..<720 {
            let t = 2.0 * Double.pi * Double(i) / 720.0
            let q = Vector3(x: a * cos(t), y: b * sin(t), z: 0)
            best = min(best, point.distance(to: q))
        }
        return best
    }

    func testOffsetEllipse() {
        let ellipse: CADPrimitive = .ellipse(
            center: v(0, 0), majorAxis: v(10, 0), minorRatio: 0.5, color: nil)

        let outward = offset(ellipse, mode: .distance(2, sidePoint: v(20, 0)))
        guard case .spline(let cps, let knots, let degree, let weights, _) = outward else {
            return XCTFail("ellipse offset should be a spline")
        }
        let samples = NURBSEvaluator.evaluateByKnotSpans(
            degree: degree, knots: knots, controlPoints: cps,
            weights: weights, segmentsPerSpan: 4)
        XCTAssertGreaterThan(samples.count, 32)
        for sample in samples {
            let d = minDistanceToEllipse(sample, a: 10, b: 5)
            XCTAssertEqual(d, 2, accuracy: 0.08, "sample \(sample)")
            XCTAssertGreaterThan((sample.x / 10) * (sample.x / 10) + (sample.y / 5) * (sample.y / 5), 1)
        }

        // Min radius of curvature is b^2/a = 2.5: inward 3 must fail.
        XCTAssertNil(offset(ellipse, mode: .distance(3, sidePoint: v(0, 0))))
        XCTAssertNotNil(offset(ellipse, mode: .distance(2, sidePoint: v(0, 0))))

        // Through mode: the offset copy passes (near) the picked point.
        let through = offset(ellipse, mode: .through(v(12, 0)))
        guard case .spline(let tcps, let tknots, let tdegree, let tweights, _) = through else {
            return XCTFail("expected spline")
        }
        let throughSamples = NURBSEvaluator.evaluateByKnotSpans(
            degree: tdegree, knots: tknots, controlPoints: tcps,
            weights: tweights, segmentsPerSpan: 8)
        let closest = throughSamples.map { $0.distance(to: v(12, 0)) }.min() ?? .infinity
        XCTAssertLessThan(closest, 0.05, "through copy should pass through (12,0)")
    }

    func testOffsetSpline() {
        let cps = [v(0, 0), v(5, 5), v(10, 5), v(15, 0)]
        let knots = generateUniformKnots(controlPointCount: cps.count, degree: 3)
        let spline: CADPrimitive = .spline(
            controlPoints: cps, knots: knots, degree: 3, weights: nil, color: nil)

        let result = offset(spline, mode: .distance(1, sidePoint: v(7, 10)))
        guard case .spline(let ocps, let oknots, let odegree, let oweights, _) = result else {
            return XCTFail("spline offset should be a spline")
        }
        let sourceSamples = NURBSEvaluator.evaluateByKnotSpans(
            degree: 3, knots: knots, controlPoints: cps, segmentsPerSpan: 64)
        let resultSamples = NURBSEvaluator.evaluateByKnotSpans(
            degree: odegree, knots: oknots, controlPoints: ocps,
            weights: oweights, segmentsPerSpan: 16)
        XCTAssertGreaterThan(resultSamples.count, 8)
        for sample in resultSamples {
            guard let nearest = CADGeometryMath.nearestPointOnPolyline(
                to: sample, points: sourceSamples) else { continue }
            let d = sample.distance(to: nearest)
            XCTAssertEqual(d, 1, accuracy: 0.15, "sample \(sample)")
        }
    }

    // MARK: - Entities / validity

    func testOffsetTransformedEntity() {
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [.line(start: v(0, 0), end: v(10, 0), color: nil)],
            transform: Transform3D.translated(by: v(100, 50))
                .multiplying(by: Transform3D.rotated(by: .pi / 2)))
        let result = OffsetGeometryEngine.offset(
            entity: entity, mode: .distance(2, sidePoint: v(105, 55)), gapType: .extend)
        guard case .line(let s, let e, _) = result else { return XCTFail("expected line") }
        assertPoint(s, 102, 50)
        assertPoint(e, 102, 60)
    }

    func testInvalidObjectsCannotOffset() {
        let side = OffsetMode.distance(1, sidePoint: v(5, 5))
        XCTAssertNil(offset(.point(position: v(0, 0), color: nil), mode: side))
        XCTAssertNil(offset(
            .text(position: v(0, 0), text: "A", height: 2, rotation: 0,
                  style: nil, alignH: 0, alignV: 0, mtextWidth: nil, color: nil),
            mode: side))
        XCTAssertNil(offset(
            .hatch(boundary: [v(0, 0), v(1, 0), v(1, 1)], pattern: "ANSI31",
                   scale: 1, angle: 0, color: nil, backgroundColor: nil),
            mode: side))

        let blockEntity = CADEntity(layerID: UUID(), blockID: UUID())
        XCTAssertFalse(OffsetGeometryEngine.isOffsettable(entity: blockEntity))

        let multiPrim = CADEntity(
            layerID: UUID(),
            localGeometry: [
                .line(start: v(0, 0), end: v(1, 0), color: nil),
                .line(start: v(0, 1), end: v(1, 1), color: nil),
            ])
        XCTAssertFalse(OffsetGeometryEngine.isOffsettable(entity: multiPrim))
    }

    // MARK: - Command surface

    func testOffsetCommandTextOptions() {
        let cmd = OffsetCommand()
        let options = cmd.commandTextOptions(for: "")
        XCTAssertTrue(options.contains { $0.value == "T" }, "Through option")
        XCTAssertTrue(options.contains { $0.value == "E" }, "Erase option")
        XCTAssertTrue(options.contains { $0.value == "L" }, "Layer option")

        let gapCmd = OffsetGapTypeCommand()
        let gapOptions = gapCmd.commandTextOptions(for: "")
        XCTAssertEqual(Set(gapOptions.map(\.value)), ["0", "1", "2"])
    }

    func testOffsetSettingsRoundTrip() {
        let oldGap = OffsetSettings.gapType
        let oldDistance = OffsetSettings.lastDistance
        defer {
            OffsetSettings.gapType = oldGap
            OffsetSettings.lastDistance = oldDistance
        }
        OffsetSettings.gapType = .chamfered
        XCTAssertEqual(OffsetSettings.gapType, .chamfered)
        OffsetSettings.lastDistance = 7.5
        XCTAssertEqual(OffsetSettings.lastDistance ?? 0, 7.5, accuracy: 1e-12)
        OffsetSettings.lastDistance = nil
        XCTAssertNil(OffsetSettings.lastDistance)
    }

    func testOffsetDescriptorRegistered() {
        let descriptor = CommandDescriptor.allCommands.first {
            $0.canonicalName == "OFFSET"
        }
        XCTAssertNotNil(descriptor)
        XCTAssertTrue(descriptor?.aliases.contains("O") ?? false)
        XCTAssertNotNil(CommandDescriptor.allCommands.first {
            $0.canonicalName == "OFFSETGAPTYPE"
        })
    }
}
