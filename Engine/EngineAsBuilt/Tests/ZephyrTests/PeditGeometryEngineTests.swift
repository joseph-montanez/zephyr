import XCTest
@testable import ZephyrCore

/// PR2 (PEDIT plan): pure-geometry ops in `PeditGeometryEngine`.
@MainActor
final class PeditGeometryEngineTests: XCTestCase {

    private func openPath() -> CADPolyline {
        CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0),
                              bulge: 0.5, startWidth: 1, endWidth: 2),
            CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0),
                              startWidth: 3, endWidth: 4),
            CADPolylineVertex(position: Vector3(x: 10, y: 10, z: 0)),
        ])
    }

    func testCloseOpenLtGen() {
        let opened = PeditGeometryEngine.opened(PeditGeometryEngine.closed(openPath()))
        XCTAssertFalse(opened.isClosed)
        XCTAssertTrue(PeditGeometryEngine.closed(openPath()).isClosed)
        XCTAssertTrue(PeditGeometryEngine.withLineTypeGeneration(openPath(), enabled: true)
            .lineTypeGenerationEnabled)
        XCTAssertFalse(PeditGeometryEngine.withLineTypeGeneration(openPath(), enabled: false)
            .lineTypeGenerationEnabled)
    }

    func testGlobalWidth() {
        let widened = PeditGeometryEngine.withGlobalWidth(openPath(), width: 2.5)
        XCTAssertNotNil(widened)
        XCTAssertTrue(widened!.vertices.allSatisfy {
            $0.startWidth == 2.5 && $0.endWidth == 2.5
        })
        XCTAssertNil(PeditGeometryEngine.withGlobalWidth(openPath(), width: -1))
    }

    func testTaper() {
        let tapered = PeditGeometryEngine.tapered(openPath(), from: 0, to: 4)
        XCTAssertNotNil(tapered)
        let widths = tapered!.vertices.map(\.startWidth)
        XCTAssertEqual(widths, [0, 2, 4])
        XCTAssertNil(PeditGeometryEngine.tapered(openPath(), from: -1, to: 4))
        XCTAssertNil(PeditGeometryEngine.tapered(openPath(), from: 1, to: -4))
    }

    func testReverseOpen() {
        let path = openPath()
        let once = PeditGeometryEngine.reversed(path)
        XCTAssertEqual(once.points, Array(path.points.reversed()))
        // Bulges negate and shift: new vertex 0 takes old segment 1's negation.
        XCTAssertEqual(once.vertices[0].bulge, 0, accuracy: 1e-12)
        XCTAssertEqual(once.vertices[1].bulge, -0.5, accuracy: 1e-12)
        XCTAssertEqual(once.vertices[1].startWidth, 2)
        XCTAssertEqual(once.vertices[1].endWidth, 1)
        XCTAssertEqual(PeditGeometryEngine.reversed(once), path)
    }

    func testReverseClosedKeepsVertexZero() {
        var path = openPath()
        path = PeditGeometryEngine.closed(path)
        let once = PeditGeometryEngine.reversed(path)
        XCTAssertEqual(once.vertices[0].position, path.vertices[0].position)
        XCTAssertEqual(Array(once.points.dropFirst()),
                       Array(path.points.dropFirst().reversed()))
        XCTAssertEqual(PeditGeometryEngine.reversed(once), path)
    }

    func testReverseRotatesTangent() {
        var path = openPath()
        path.vertices[0].tangent = 0
        let once = PeditGeometryEngine.reversed(path)
        // Vertex 0's position moves to the tail; its tangent flips by π.
        XCTAssertEqual(abs(once.vertices[2].tangent ?? 0), .pi, accuracy: 1e-12)
        XCTAssertEqual(PeditGeometryEngine.reversed(once), path)
    }

    func testConvertLine() {
        let converted = PeditGeometryEngine.convertedFromLine(
            start: Vector3(x: 1, y: 2, z: 0), end: Vector3(x: 3, y: 4, z: 0))
        XCTAssertNotNil(converted)
        XCTAssertEqual(converted!.vertices.count, 2)
        XCTAssertNil(PeditGeometryEngine.convertedFromLine(
            start: Vector3(x: 1, y: 1, z: 0), end: Vector3(x: 1, y: 1, z: 0)))
    }

    func testConvertArc() {
        let converted = PeditGeometryEngine.convertedFromArc(
            center: Vector3(x: 0, y: 0, z: 0),
            radius: 10, startAngle: 0, endAngle: .pi / 2)
        XCTAssertNotNil(converted)
        XCTAssertEqual(converted!.vertices.count, 2)
        XCTAssertEqual(converted!.vertices[0].position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(converted!.vertices[1].position.y, 10, accuracy: 1e-9)
        XCTAssertEqual(converted!.vertices[0].bulge, tan(.pi / 8), accuracy: 1e-12)
        XCTAssertNil(PeditGeometryEngine.convertedFromArc(
            center: .zero, radius: 0, startAngle: 0, endAngle: 1))
    }

    func testMoveInsertDelete() {
        let path = openPath()
        let moved = PeditGeometryEngine.moved(path, index: 1, to: Vector3(x: 7, y: 7, z: 0))
        XCTAssertEqual(moved?.vertices[1].position.x, 7)
        XCTAssertEqual(moved?.vertices[1].position.y, 7)
        XCTAssertNil(PeditGeometryEngine.moved(path, index: 9, to: .zero))

        let inserted = PeditGeometryEngine.inserted(path, after: 0, position: Vector3(x: 5, y: 0, z: 0))
        XCTAssertNotNil(inserted)
        XCTAssertEqual(inserted?.index, 1)
        XCTAssertEqual(inserted?.path.vertices.count, 4)
        XCTAssertEqual(inserted?.path.vertices[1].position.x, 5)

        let deleted = PeditGeometryEngine.deleted(path, index: 1)
        XCTAssertEqual(deleted?.vertices.count, 2)
        // Open floor is 2: deleting from a 2-vertex path fails.
        XCTAssertNil(PeditGeometryEngine.deleted(deleted!, index: 0))
        // Closed floor is 3.
        let closed = PeditGeometryEngine.closed(path)
        XCTAssertNil(PeditGeometryEngine.deleted(closed, index: 0))
        let roomy = CADPolyline(points: [.zero, Vector3(x: 1, y: 0, z: 0),
                                         Vector3(x: 1, y: 1, z: 0), Vector3(x: 0, y: 1, z: 0)],
                                isClosed: true)
        XCTAssertEqual(PeditGeometryEngine.deleted(roomy, index: 0)?.vertices.count, 3)
    }

    func testBreak() {
        let path = openPath()
        let pieces = PeditGeometryEngine.breakAt(path, index: 1)
        XCTAssertEqual(pieces?.count, 2)
        XCTAssertEqual(pieces?[0].vertices.count, 2)
        XCTAssertEqual(pieces?[1].vertices.count, 2)
        XCTAssertEqual(pieces?[0].vertices[1].position, path.vertices[1].position)
        XCTAssertEqual(pieces?[1].vertices[0].position, path.vertices[1].position)
        // Endpoint break is a no-op.
        XCTAssertNil(PeditGeometryEngine.breakAt(path, index: 0))

        let closed = PeditGeometryEngine.closed(path)
        let opened = PeditGeometryEngine.breakAt(closed, index: 1)
        XCTAssertEqual(opened?.count, 1)
        XCTAssertFalse(opened?[0].isClosed ?? true)
        XCTAssertEqual(opened?[0].vertices.count, 3)
    }

    func testTangentAndSegmentWidth() {
        let path = openPath()
        let tangent = PeditGeometryEngine.withTangent(path, index: 2, angle: 1.2)
        XCTAssertEqual(tangent?.vertices[2].tangent ?? 0, 1.2, accuracy: 1e-12)
        XCTAssertNil(tangent?.vertices[0].tangent)
        XCTAssertNil(PeditGeometryEngine.withTangent(path, index: 9, angle: 0))

        let widened = PeditGeometryEngine.withSegmentWidth(path, index: 0, start: 1, end: 2)
        XCTAssertEqual(widened?.vertices[0].startWidth, 1)
        XCTAssertEqual(widened?.vertices[0].endWidth, 2)
        XCTAssertNil(PeditGeometryEngine.withSegmentWidth(path, index: 0, start: -1, end: 2))
    }

    func testStraighten() {
        let path = CADPolyline(points: [.zero, Vector3(x: 1, y: 0, z: 0), Vector3(x: 2, y: 0, z: 0),
                                        Vector3(x: 3, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0)])
        let straight = PeditGeometryEngine.straightened(path, from: 0, to: 3)
        XCTAssertEqual(straight?.vertices.count, 3)
        XCTAssertEqual(straight?.vertices.map(\.position.x), [0, 3, 4])
        // Adjacent indices: nothing to remove.
        XCTAssertNil(PeditGeometryEngine.straightened(path, from: 1, to: 2))
        // Same index is a no-op.
        XCTAssertNil(PeditGeometryEngine.straightened(path, from: 2, to: 2))
        // Closed-triangle minimum: removing 1 of 3 would leave 2 < 3.
        let triangle = CADPolyline(points: [.zero, Vector3(x: 1, y: 0, z: 0),
                                            Vector3(x: 0, y: 1, z: 0)], isClosed: true)
        XCTAssertNil(PeditGeometryEngine.straightened(triangle, from: 0, to: 2))

        let wrapped = PeditGeometryEngine.straightened(
            CADPolyline(points: [.zero, Vector3(x: 1, y: 0, z: 0),
                                 Vector3(x: 1, y: 1, z: 0), Vector3(x: 0, y: 1, z: 0)],
                        isClosed: true), from: 2, to: 0)
        // Removes vertex 3 (wraps through the closing edge).
        XCTAssertEqual(wrapped?.vertices.count, 3)
    }

    func testJoinAppendsAndPrepends() {
        let target = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)]))
        let tail = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: 10, y: 0, z: 0), Vector3(x: 20, y: 0, z: 0)]))
        let head = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: -10, y: 0, z: 0), Vector3(x: 0, y: 0, z: 0)]))
        let joined = PeditGeometryEngine.joinPolylines(target: target, sources: [tail, head])
        XCTAssertNotNil(joined)
        XCTAssertEqual(joined?.vertices.map(\.position.x), [-10, 0, 10, 20])
        XCTAssertFalse(joined?.isClosed ?? true)
    }

    func testJoinReversesBackwardSource() {
        let target = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)]))
        // Source's END touches the target end, so the engine reverses it
        // before appending; the joint segment keeps the arc with negated bulge.
        let backward = PeditGeometryEngine.JoinSource(path: CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 20, y: 0, z: 0), bulge: 0.5),
            CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0)),
        ]))
        let joined = PeditGeometryEngine.joinPolylines(target: target, sources: [backward])
        XCTAssertNotNil(joined)
        XCTAssertEqual(joined?.vertices.map(\.position.x), [0, 10, 20])
        // Reversed bulge negates onto the joint segment.
        XCTAssertEqual(joined?.vertices[1].bulge ?? 0, -0.5, accuracy: 1e-12)
    }

    func testJoinPreservesWidthsAndTangents() {
        let target = PeditGeometryEngine.JoinSource(path: CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0), startWidth: 1, endWidth: 1),
            CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0), startWidth: 1, endWidth: 1),
        ]))
        let source = PeditGeometryEngine.JoinSource(path: CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0),
                              startWidth: 2, endWidth: 3, tangent: 0.5),
            CADPolylineVertex(position: Vector3(x: 20, y: 0, z: 0),
                              startWidth: 3, endWidth: 3, tangent: -0.25),
        ]))
        let joined = PeditGeometryEngine.joinPolylines(target: target, sources: [source])
        XCTAssertEqual(joined?.vertices.count, 3)
        // The joint vertex keeps the chain-side position but carries the
        // outgoing (source-side) segment widths; its tangent stays the
        // chain-side tangent. The source's duplicate endpoint is dropped.
        XCTAssertEqual(joined?.vertices[1].position.x ?? -1, 10, accuracy: 1e-12)
        XCTAssertEqual(joined?.vertices[1].startWidth ?? -1, 2, accuracy: 1e-12)
        XCTAssertEqual(joined?.vertices[1].endWidth ?? -1, 3, accuracy: 1e-12)
        XCTAssertNil(joined?.vertices[1].tangent)
        XCTAssertEqual(joined?.vertices[2].tangent ?? -99, -0.25, accuracy: 1e-12)
        XCTAssertEqual(joined?.vertices[2].startWidth ?? -1, 3, accuracy: 1e-12)
    }

    func testJoinRejects() {
        let open = CADPolyline(points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)])
        let far = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: 50, y: 0, z: 0), Vector3(x: 60, y: 0, z: 0)]))
        // Nothing touches.
        XCTAssertNil(PeditGeometryEngine.joinPolylines(
            target: PeditGeometryEngine.JoinSource(path: open), sources: [far]))
        // Closed target.
        XCTAssertNil(PeditGeometryEngine.joinPolylines(
            target: PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)], isClosed: true)),
            sources: [far]))
        // Curved target.
        var curved = open
        curved.curveType = .fit
        XCTAssertNil(PeditGeometryEngine.joinPolylines(
            target: PeditGeometryEngine.JoinSource(path: curved), sources: [far]))
        // Generated-kind source.
        let gen = PeditGeometryEngine.JoinSource(path: CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0), kind: .curveFitGenerated),
            CADPolylineVertex(position: Vector3(x: 20, y: 0, z: 0), kind: .curveFitGenerated),
        ]))
        XCTAssertNil(PeditGeometryEngine.joinPolylines(
            target: PeditGeometryEngine.JoinSource(path: open), sources: [gen]))
    }

    func testJoinArcBulge() {
        let target = PeditGeometryEngine.JoinSource(path: CADPolyline(points: [
            Vector3(x: 10, y: 0, z: 0), Vector3(x: 20, y: 0, z: 0)]))
        // Quarter arc from (10,0) to (0,10): touches the target start.
        let arc = PeditGeometryEngine.convertedFromArc(
            center: .zero, radius: 10, startAngle: 0, endAngle: .pi / 2)!
        let joined = PeditGeometryEngine.joinPolylines(
            target: target,
            sources: [PeditGeometryEngine.JoinSource(path: arc)])
        XCTAssertNotNil(joined)
        XCTAssertEqual(joined?.vertices.count, 3)
        XCTAssertEqual(joined?.vertices[0].position.x ?? -1, 0, accuracy: 1e-9)
        // Prepended arc is traversed end-to-start, so its bulge negates;
        // it lives on the arc's own segment (vertex 0), while the joint
        // vertex carries the straight outgoing segment.
        XCTAssertEqual(joined?.vertices[0].bulge ?? 0, -tan(.pi / 8), accuracy: 1e-9)
        XCTAssertEqual(joined?.vertices[1].bulge ?? 9, 0, accuracy: 1e-9)
    }

    func testFitPassesThroughVertices() {
        let path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 5, z: 0),
            Vector3(x: 20, y: 0, z: 0), Vector3(x: 30, y: 5, z: 0)])
        let fitted = PeditGeometryEngine.fitCurve(path)
        XCTAssertNotNil(fitted)
        XCTAssertEqual(fitted?.curveType, .fit)
        // Every original vertex survives in order.
        let originals = fitted?.vertices.filter { $0.kind == .normal }.map(\.position)
        XCTAssertEqual(originals, path.points)
        XCTAssertTrue(fitted?.vertices.contains(where: { $0.kind == .curveFitGenerated }) ?? false)
        // Bit-exact round-trip.
        XCTAssertEqual(PeditGeometryEngine.decurved(fitted!), path)
    }

    func testFitHonorsUserTangent() {
        var path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0), Vector3(x: 20, y: 0, z: 0)])
        path.vertices[1].tangent = .pi / 2
        let fitted = PeditGeometryEngine.fitCurve(path, samplesPerSpan: 4)
        XCTAssertNotNil(fitted)
        // Layout is [F0, span0 x4, F1, span1 x4, F2]: the first sample
        // leaving the tangent vertex heads upward (Hermite may dip on the
        // arriving span when the tangent overshoots the chord).
        let leaving = fitted!.vertices[6].position
        XCTAssertGreaterThan(leaving.y, 0)
        XCTAssertGreaterThan(leaving.y, fitted!.vertices[5].position.y)
    }

    func testFitClosedAndRejects() {
        let loop = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0)], isClosed: true)
        let fitted = PeditGeometryEngine.fitCurve(loop)
        XCTAssertNotNil(fitted)
        XCTAssertTrue(fitted!.isClosed)
        XCTAssertEqual(PeditGeometryEngine.decurved(fitted!), loop)
        // Bulges rejected.
        var bulged = loop
        bulged.vertices[0].bulge = 0.5
        XCTAssertNil(PeditGeometryEngine.fitCurve(bulged))
        // Double-fit rejected.
        XCTAssertNil(PeditGeometryEngine.fitCurve(fitted!))
        // Spline on fitted rejected, decurve of plain is nil.
        XCTAssertNil(PeditGeometryEngine.splineCurve(fitted!, quadratic: false))
        XCTAssertNil(PeditGeometryEngine.decurved(loop))
    }

    func testSplineCubicFramesAndDecurve() {
        let path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 10, z: 0),
            Vector3(x: 20, y: 0, z: 0), Vector3(x: 30, y: 10, z: 0)])
        let splined = PeditGeometryEngine.splineCurve(path, quadratic: false)
        XCTAssertNotNil(splined)
        XCTAssertEqual(splined?.curveType, .splineCubic)
        let frames = splined?.vertices.filter { $0.kind == .splineFrame }.map(\.position)
        XCTAssertEqual(frames, path.points)
        XCTAssertTrue(splined?.vertices.contains(where: { $0.kind == .splineGenerated }) ?? false)
        // Open clamped spline touches both ends.
        let generated = splined?.vertices.filter { $0.kind == .splineGenerated }.map(\.position)
        XCTAssertEqual(generated?.first, path.points.first)
        XCTAssertEqual(generated?.last, path.points.last)
        // Frames ride first in storage; the visible curve skips them.
        XCTAssertEqual(splined?.vertices.first?.kind, .splineFrame)
        let display = splined?.displayPath.vertices
        XCTAssertTrue(display?.allSatisfy { $0.kind != .splineFrame } ?? false)
        // Tessellation follows the samples exactly (no frame spikes).
        XCTAssertEqual(splined?.tessellatedPoints(), generated ?? [])
        XCTAssertEqual(PeditGeometryEngine.decurved(splined!), path)
    }

    func testSplineQuadraticAndClosed() {
        let path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0), Vector3(x: 5, y: 8, z: 0)])
        let quad = PeditGeometryEngine.splineCurve(path, quadratic: true)
        XCTAssertNotNil(quad)
        XCTAssertEqual(quad?.curveType, .splineQuadratic)
        XCTAssertEqual(PeditGeometryEngine.decurved(quad!), path)
        // Cubic needs 4+.
        XCTAssertNil(PeditGeometryEngine.splineCurve(path, quadratic: false))

        let loop = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0)], isClosed: true)
        let closedSpline = PeditGeometryEngine.splineCurve(loop, quadratic: false)
        XCTAssertNotNil(closedSpline)
        XCTAssertTrue(closedSpline!.isClosed)
        // Display loop has no frames and closes onto itself.
        let display = closedSpline!.displayPath
        XCTAssertTrue(display.vertices.allSatisfy { $0.kind == .splineGenerated })
        let tess = closedSpline!.tessellatedPoints()
        XCTAssertEqual(tess.count, display.vertices.count + 1)
        XCTAssertEqual(tess.first, tess.last)
        XCTAssertEqual(PeditGeometryEngine.decurved(closedSpline!), loop)
    }

    func testSanitize() {
        let dupes = CADPolyline(vertices: [
            CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0)),
            CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0)),
            CADPolylineVertex(position: Vector3(x: 5, y: 0, z: 0)),
        ])
        XCTAssertEqual(PeditGeometryEngine.sanitized(dupes)?.vertices.count, 2)
        let allSame = CADPolyline(points: [.zero, .zero])
        XCTAssertNil(PeditGeometryEngine.sanitized(allSame))
    }
}
