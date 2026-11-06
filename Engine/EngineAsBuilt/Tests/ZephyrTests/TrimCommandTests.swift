import XCTest
@testable import ZephyrCore

@MainActor
final class TrimCommandTests: XCTestCase {

    // MARK: - Line Trimming Tests

    func testTrimLineSingleClickEndpoint() {
        // Horizontal line from (0, 0) to (10, 0)
        let ls = Vector3(x: 0, y: 0, z: 0)
        let le = Vector3(x: 10, y: 0, z: 0)

        // Vertical cutting edge at x = 5 from (5, -5) to (5, 5)
        let cuttingEdge = (Vector3(x: 5, y: -5, z: 0), Vector3(x: 5, y: 5, z: 0))

        // Click at (8, 0) -> should trim the right side [5..10], keeping [0..5]
        let click = Vector3(x: 8, y: 0, z: 0)
        let (res, modified, err) = TrimGeometryEngine.trimPrimitive(
            primitive: .line(start: ls, end: le, color: nil),
            transform: .identity,
            criterion: .click(point: click),
            cuttingSegments: [cuttingEdge],
            exactLines: [cuttingEdge]
        )

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(res?.count, 1)

        if case .line(let start, let end, _) = res?.first {
            XCTAssertEqual(start.x, 0.0, accuracy: 1e-6)
            XCTAssertEqual(end.x, 5.0, accuracy: 1e-6)
        } else {
            XCTFail("Expected .line primitive")
        }
    }

    func testTrimLineMiddleSegmentBetweenTwoCuttingEdges() {
        // Horizontal line from (0, 0) to (10, 0)
        let ls = Vector3(x: 0, y: 0, z: 0)
        let le = Vector3(x: 10, y: 0, z: 0)

        // Two vertical cutting edges at x = 3 and x = 7
        let edge1 = (Vector3(x: 3, y: -5, z: 0), Vector3(x: 3, y: 5, z: 0))
        let edge2 = (Vector3(x: 7, y: -5, z: 0), Vector3(x: 7, y: 5, z: 0))

        // Click at (5, 0) -> trims middle [3..7], keeping [0..3] and [7..10]
        let click = Vector3(x: 5, y: 0, z: 0)
        let (res, modified, err) = TrimGeometryEngine.trimPrimitive(
            primitive: .line(start: ls, end: le, color: nil),
            transform: .identity,
            criterion: .click(point: click),
            cuttingSegments: [edge1, edge2],
            exactLines: [edge1, edge2]
        )

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(res?.count, 2)

        if let line1 = res?.first, case .line(let s1, let e1, _) = line1 {
            XCTAssertEqual(s1.x, 0.0, accuracy: 1e-6)
            XCTAssertEqual(e1.x, 3.0, accuracy: 1e-6)
        } else {
            XCTFail("Expected first line")
        }

        if let line2 = res?.last, case .line(let s2, let e2, _) = line2 {
            XCTAssertEqual(s2.x, 7.0, accuracy: 1e-6)
            XCTAssertEqual(e2.x, 10.0, accuracy: 1e-6)
        } else {
            XCTFail("Expected second line")
        }
    }

    func testTrimLineCrossingBoxSelection() {
        // Horizontal line from (0, 0) to (10, 0)
        let ls = Vector3(x: 0, y: 0, z: 0)
        let le = Vector3(x: 10, y: 0, z: 0)

        // Vertical cutting edge at x = 4
        let edge = (Vector3(x: 4, y: -5, z: 0), Vector3(x: 4, y: 5, z: 0))

        // Crossing box enclosing (6, -2) to (8, 2) -> crosses the [4..10] portion
        let boxMin = Vector3(x: 6, y: -2, z: 0)
        let boxMax = Vector3(x: 8, y: 2, z: 0)

        let (res, modified, err) = TrimGeometryEngine.trimPrimitive(
            primitive: .line(start: ls, end: le, color: nil),
            transform: .identity,
            criterion: .rect(min: boxMin, max: boxMax, isCrossing: true),
            cuttingSegments: [edge],
            exactLines: [edge]
        )

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(res?.count, 1)

        if case .line(let start, let end, _) = res?.first {
            XCTAssertEqual(start.x, 0.0, accuracy: 1e-6)
            XCTAssertEqual(end.x, 4.0, accuracy: 1e-6)
        } else {
            XCTFail("Expected .line primitive")
        }
    }

    func testTrimLineFenceSelection() {
        // Horizontal line from (0, 0) to (10, 0)
        let ls = Vector3(x: 0, y: 0, z: 0)
        let le = Vector3(x: 10, y: 0, z: 0)

        // Vertical cutting edge at x = 5
        let edge = (Vector3(x: 5, y: -5, z: 0), Vector3(x: 5, y: 5, z: 0))

        // Fence segment from (7, -3) to (7, 3) crosses the [5..10] portion
        let fenceP1 = Vector3(x: 7, y: -3, z: 0)
        let fenceP2 = Vector3(x: 7, y: 3, z: 0)

        let (res, modified, err) = TrimGeometryEngine.trimPrimitive(
            primitive: .line(start: ls, end: le, color: nil),
            transform: .identity,
            criterion: .fence(p1: fenceP1, p2: fenceP2),
            cuttingSegments: [edge],
            exactLines: [edge]
        )

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(res?.count, 1)

        if case .line(let start, let end, _) = res?.first {
            XCTAssertEqual(start.x, 0.0, accuracy: 1e-6)
            XCTAssertEqual(end.x, 5.0, accuracy: 1e-6)
        } else {
            XCTFail("Expected .line primitive")
        }
    }

    // MARK: - Circle Trimming Tests

    func testTrimCircleWithTwoCuttingEdgesBecomesArc() {
        // Circle at origin with radius 5
        let center = Vector3(x: 0, y: 0, z: 0)
        let radius = 5.0

        // Horizontal cutting edge along x-axis (intersects at angles 0 and pi)
        let edge = (Vector3(x: -10, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0))

        // Click top half at (0, 5) -> removes top half [0..pi], keeping bottom half [pi..2pi]
        let click = Vector3(x: 0, y: 5, z: 0)
        let (res, modified, err) = TrimGeometryEngine.trimPrimitive(
            primitive: .circle(center: center, radius: radius, color: nil),
            transform: .identity,
            criterion: .click(point: click),
            cuttingSegments: [edge],
            exactLines: [edge]
        )

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(res?.count, 1)

        if case .arc(let c, let r, let sa, let ea, _) = res?.first {
            XCTAssertEqual(c.x, 0.0, accuracy: 1e-6)
            XCTAssertEqual(r, 5.0, accuracy: 1e-6)
            // Kept arc starts at pi and ends at 2pi (or 0)
            XCTAssertEqual(sa, .pi, accuracy: 1e-4)
            XCTAssertEqual(TrimGeometryEngine.normAngle(ea), 0.0, accuracy: 1e-4)
        } else {
            XCTFail("Expected .arc primitive after circle trim")
        }
    }

    // MARK: - Command Options & Metadata Tests

    func testTrimCommandTextOptions() {
        let cmd = TrimCommand()
        // Target selection options should include Fence, Crossing, Cutting edges, Mode, eRase, Undo
        let options = cmd.commandTextOptions(for: "")
        // Initial state is selectCuttingEdges
        XCTAssertTrue(options.contains { $0.value == "ALL" })
        XCTAssertTrue(options.contains { $0.value == "M" })
    }

    func testTrimModeDefaultIsQuick() {
        let savedMode = TrimCommand.preferredMode
        defer { TrimCommand.preferredMode = savedMode }
        // Fresh-launch initial value (current AutoCAD default).
        TrimSettings.trimExtendMode = 1
        XCTAssertEqual(TrimCommand.preferredMode, .quick)
        XCTAssertEqual(TrimSettings.trimExtendMode, 1)
    }

    /// Noun/verb × mode start matrix shared by TRIM and EXTEND (PICKFIRST):
    /// pre-selection is adopted as the only edges when PICKFIRST is on
    /// (even in Quick mode) and ignored when off.
    func testTrimStartDecisionMatrix() {
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 1, mode: .quick, hasPreselection: true),
            .adoptPreselected)
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 1, mode: .standard, hasPreselection: true),
            .adoptPreselected)
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 0, mode: .quick, hasPreselection: true),
            .allEdges)
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 0, mode: .standard, hasPreselection: true),
            .promptForEdges)
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 1, mode: .quick, hasPreselection: false),
            .allEdges)
        XCTAssertEqual(
            TrimCommand.startDecision(pickFirst: 1, mode: .standard, hasPreselection: false),
            .promptForEdges)
    }

    // MARK: - Quick/select-all spline trim (regression: trim-after-1.eab)
    //
    // Geometry captured from the user repro: a cubic spline crossed by a
    // line whose start point already lies on the spline (first trim done).
    // Kernel crossings at u = 0.205285 and u = 0.770767.

    private static let reproSplineCPs = [
        Vector3(x: -214, y: -91, z: 0),
        Vector3(x: 53, y: -332, z: 0),
        Vector3(x: 442, y: -214, z: 0),
        Vector3(x: 501, y: 131, z: 0),
    ]
    private static let reproKnots = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]

    private func makeReproDoc(lineStart: Vector3) -> (CADDocument, CADEntity, CADEntity) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let layerID = doc.findLayer(named: "0")!.handle
        let spline = CADEntity(
            layerID: layerID,
            localGeometry: [.spline(controlPoints: Self.reproSplineCPs, knots: Self.reproKnots,
                                    degree: 3, weights: nil, color: nil)])
        let line = CADEntity(
            layerID: layerID,
            localGeometry: [.line(start: lineStart, end: Vector3(x: 646, y: -4, z: 0), color: nil)])
        doc.addEntity(spline)
        doc.addEntity(line)
        return (doc, spline, line)
    }

    /// Select-all (quick) mode compiles every entity as a cutter, including
    /// the trim target. Trimming the spline's left piece must remove only
    /// [0, first crossing]; before the self-exclusion fix the spline's own
    /// exploded chords/exact curve cut it into slivers around the click.
    func testTrimSplineSelectAllExcludesSelfCutters() {
        let shortenedStart = Vector3(x: -38.05263988729399, y: -195.17628363662365, z: 0)
        let (doc, spline, _) = makeReproDoc(lineStart: shortenedStart)

        let edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
        // The spline contributes an exact curve only (no chord segments);
        // the line contributes the single cutting segment.
        XCTAssertEqual(edges.segments.count, 1)
        XCTAssertEqual(edges.exactCurves.count, 1)

        let excluded = edges.excluding(spline.handle)
        XCTAssertEqual(excluded.segments.count, 1)
        XCTAssertTrue(excluded.exactCurves.isEmpty)

        let w = Array(repeating: 1.0, count: Self.reproSplineCPs.count)
        let click = NURBSEvaluator.evaluateAt(
            degree: 3, knots: Self.reproKnots, controlPoints: Self.reproSplineCPs,
            weights: w, at: 0.1)!
        let (newGeom, modified, err) = TrimGeometryEngine.trimEntity(
            entity: spline, document: doc,
            criterion: .click(point: click),
            cuttingSegments: excluded.segments,
            exactLines: excluded.exactLines,
            exactCurves: excluded.exactCurves)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(newGeom?.count, 1)
        guard case let .spline(_, knots, _, _, _) = newGeom?.first else {
            XCTFail("Expected kept spline span")
            return
        }
        XCTAssertEqual(knots.first ?? -1, 0.205285, accuracy: 1e-3)
        XCTAssertEqual(knots.last ?? -1, 1.0, accuracy: 1e-9)
    }

    /// Trimming the line against the spline cutter must land the kept
    /// endpoint exactly on the spline (analytical hit), not at chord
    /// distance (~0.03 in the repro) from exploded spline chords.
    func testTrimLineAgainstSplineCutterLandsOnCurve() {
        // Full line extended past the first crossing (pre-first-trim state).
        let fullStart = Vector3(x: -209.06, y: -242.97, z: 0)
        let (doc, _, line) = makeReproDoc(lineStart: fullStart)

        let edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
            .excluding(line.handle)
        XCTAssertTrue(edges.segments.isEmpty, "spline cutter must be exact-only, no chords")

        let click = Vector3(
            x: fullStart.x + 0.1 * (646 - fullStart.x),
            y: fullStart.y + 0.1 * (-4 - fullStart.y), z: 0)
        let (newGeom, modified, err) = TrimGeometryEngine.trimEntity(
            entity: line, document: doc,
            criterion: .click(point: click),
            cuttingSegments: edges.segments,
            exactLines: edges.exactLines,
            exactCurves: edges.exactCurves)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(newGeom?.count, 1)
        guard case let .line(keptStart, _, _) = newGeom?.first else {
            XCTFail("Expected kept line")
            return
        }
        // Independent distance oracle: dense minimization over the legacy
        // evaluator. (findClosestParameter's sampled search stalls ~7e-6
        // in u on this curve, which reads as ~0.0065 world error.)
        let w = Array(repeating: 1.0, count: Self.reproSplineCPs.count)
        func distAt(_ u: Double) -> Double {
            let p = NURBSEvaluator.evaluateAt(
                degree: 3, knots: Self.reproKnots, controlPoints: Self.reproSplineCPs,
                weights: w, at: u)!
            return hypot(p.x - keptStart.x, p.y - keptStart.y)
        }
        var lo = 0.0
        var hi = 1.0
        var dist = Double.infinity
        for _ in 0..<5 {
            let steps = 512
            var bestU = lo
            dist = .infinity
            for i in 0...steps {
                let u = lo + (hi - lo) * Double(i) / Double(steps)
                let d = distAt(u)
                if d < dist { dist = d; bestU = u }
            }
            let half = (hi - lo) / Double(steps)
            lo = max(0.0, bestU - half)
            hi = min(1.0, bestU + half)
        }
        XCTAssertLessThan(dist, 1e-6, "trim endpoint must lie on the spline, got dist \(dist)")
    }

    /// End to end: the stored trim result is analytic, and screen-space
    /// tessellation of that stored result keeps the exact trim endpoint at
    /// deep zoom instead of reintroducing chord overshoot.
    func testReproTrimEndpointSurvivesScreenSpaceTessellation() {
        let shortenedStart = Vector3(x: -38.05263988729399, y: -195.17628363662365, z: 0)
        let (doc, spline, _) = makeReproDoc(lineStart: shortenedStart)
        let edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
            .excluding(spline.handle)
        let weights = Array(repeating: 1.0, count: Self.reproSplineCPs.count)
        let click = NURBSEvaluator.evaluateAt(
            degree: 3, knots: Self.reproKnots, controlPoints: Self.reproSplineCPs,
            weights: weights, at: 0.1)!
        let (newGeom, modified, err) = TrimGeometryEngine.trimEntity(
            entity: spline, document: doc,
            criterion: .click(point: click),
            cuttingSegments: edges.segments,
            exactLines: edges.exactLines,
            exactCurves: edges.exactCurves)
        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case let .spline(controls, knots, degree, keptWeights, _) = newGeom?.first else {
            XCTFail("Expected kept spline span")
            return
        }
        let keptW = keptWeights ?? Array(repeating: 1.0, count: controls.count)
        let start = NURBSEvaluator.evaluateAt(
            degree: degree, knots: knots, controlPoints: controls,
            weights: keptW, at: knots[degree])!
        let end = NURBSEvaluator.evaluateAt(
            degree: degree, knots: knots, controlPoints: controls,
            weights: keptW, at: knots[controls.count])!
        let viewport = ScreenTessellationViewport(
            minX: 100, minY: -170, maxX: 145, maxY: -125)
        let band = CurveScreenTessellation.zoomBand(for: 1000)
        let context = CurveScreenTessellationContext(
            pixelsPerUnit: 1000,
            band: band,
            designZoom: CurveScreenTessellation.designZoom(for: band),
            viewport: viewport)
        let tessellation = CurveScreenTessellation.tessellateSpline(
            degree: degree,
            knots: knots,
            controlPoints: controls,
            weights: keptW,
            context: context)
        XCTAssertFalse(tessellation.didHitMaximumSegments)
        XCTAssertGreaterThan(tessellation.points.count, 2)
        XCTAssertEqual(tessellation.points.first?.x ?? 0, start.x, accuracy: 1e-9)
        XCTAssertEqual(tessellation.points.first?.y ?? 0, start.y, accuracy: 1e-9)
        XCTAssertEqual(tessellation.points.last?.x ?? 0, end.x, accuracy: 1e-9)
        XCTAssertEqual(tessellation.points.last?.y ?? 0, end.y, accuracy: 1e-9)
    }
}
