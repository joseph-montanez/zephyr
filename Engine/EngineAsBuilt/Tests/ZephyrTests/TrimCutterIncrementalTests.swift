import XCTest
@testable import ZephyrCore
@testable import ZephyrKernel

/// Incremental cutter refresh (`updateCuttingEdges` / `removeCuttingEdges`)
/// and cutter broad-phase filtering must produce exactly the same cutters
/// and trim outcomes as a full `collectCuttingEdges` recompile.
///
/// Regression: every TRIM/EXTEND click recompiled every cutter
/// drawing-wide (exploding all curves per click) and every trim solver
/// tested every cutter, so single clicks scaled with drawing size.
@MainActor
final class TrimCutterIncrementalTests: XCTestCase {

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let layer = doc.findLayer(named: "0")!.handle
        return (doc, layer)
    }

    private func line(_ layer: UUID, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADEntity {
        CADEntity(layerID: layer, localGeometry: [
            .line(start: Vector3(x: x1, y: y1, z: 0),
                  end: Vector3(x: x2, y: y2, z: 0), color: nil),
        ])
    }

    private func circle(_ layer: UUID, _ cx: Double, _ cy: Double, _ r: Double) -> CADEntity {
        CADEntity(layerID: layer, localGeometry: [
            .circle(center: Vector3(x: cx, y: cy, z: 0), radius: r, color: nil),
        ])
    }

    private func assertSameEdges(
        _ incremental: TrimGeometryEngine.TrimCuttingEdges,
        _ fresh: TrimGeometryEngine.TrimCuttingEdges,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(incremental.segments.count, fresh.segments.count, file: file, line: line)
        XCTAssertEqual(incremental.exactLines.count, fresh.exactLines.count, file: file, line: line)
        XCTAssertEqual(incremental.exactCurves.count, fresh.exactCurves.count, file: file, line: line)
        XCTAssertEqual(
            Set(incremental.rangesByHandle.keys), Set(fresh.rangesByHandle.keys),
            file: file, line: line)
        for (a, b) in zip(incremental.segments, fresh.segments) {
            XCTAssertEqual(a.0, b.0, file: file, line: line)
            XCTAssertEqual(a.1, b.1, file: file, line: line)
        }
        for (a, b) in zip(incremental.exactLines, fresh.exactLines) {
            XCTAssertEqual(a.0, b.0, file: file, line: line)
            XCTAssertEqual(a.1, b.1, file: file, line: line)
        }
        XCTAssertEqual(incremental.exactCurves, fresh.exactCurves, file: file, line: line)
        for handle in fresh.rangesByHandle.keys {
            let got = incremental.rangesByHandle[handle]
            let want = fresh.rangesByHandle[handle]
            XCTAssertEqual(got?.segments.lowerBound, want?.segments.lowerBound, file: file, line: line)
            XCTAssertEqual(got?.segments.upperBound, want?.segments.upperBound, file: file, line: line)
            XCTAssertEqual(got?.exactLines.lowerBound, want?.exactLines.lowerBound, file: file, line: line)
            XCTAssertEqual(got?.exactLines.upperBound, want?.exactLines.upperBound, file: file, line: line)
            XCTAssertEqual(got?.exactCurves.lowerBound, want?.exactCurves.lowerBound, file: file, line: line)
            XCTAssertEqual(got?.exactCurves.upperBound, want?.exactCurves.upperBound, file: file, line: line)
        }
    }

    /// Splicing one entity's rewritten geometry must match a full recompile,
    /// including provenance ranges of the untouched contributors.
    func testUpdateMatchesFullRecompile() {
        let (doc, layer) = makeDoc()
        let target = line(layer, 0, 0, 10, 0)
        let cutter = line(layer, 5, -5, 5, 5)
        let arc = circle(layer, 8, 0, 2)
        doc.addEntity(target)
        doc.addEntity(cutter)
        doc.addEntity(arc)

        var edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)

        // Simulate a trim that shortens the target to (0,0)-(6,0).
        doc.updateEntityGeometryLive(
            for: target.handle,
            geometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                             end: Vector3(x: 6, y: 0, z: 0), color: nil)])
        TrimGeometryEngine.updateCuttingEdges(&edges, for: target.handle, document: doc)

        let fresh = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
        assertSameEdges(edges, fresh)
    }

    /// Deleting an entity then removing its contribution must match a full
    /// recompile, with later contributors' ranges shifted correctly.
    func testRemoveMatchesFullRecompile() {
        let (doc, layer) = makeDoc()
        let first = line(layer, 0, 0, 10, 0)
        let middle = line(layer, 5, -5, 5, 5)
        let last = circle(layer, 8, 0, 2)
        doc.addEntity(first)
        doc.addEntity(middle)
        doc.addEntity(last)

        var edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
        XCTAssertEqual(edges.rangesByHandle.count, 3)

        doc.removeEntities(handles: [middle.handle])
        TrimGeometryEngine.removeCuttingEdges(&edges, for: middle.handle)

        let fresh = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
        assertSameEdges(edges, fresh)
    }

    /// Provenance must survive the splice: excluding the trimmed target
    /// still drops exactly its own edges so a curve can never cut itself.
    func testExcludingAfterUpdateStillPreventsSelfCut() {
        let (doc, layer) = makeDoc()
        let target = line(layer, 0, 0, 10, 0)
        let cutter = line(layer, 5, -5, 5, 5)
        doc.addEntity(target)
        doc.addEntity(cutter)

        var edges = TrimGeometryEngine.collectCuttingEdges(document: doc, cuttingHandles: nil)
        doc.updateEntityGeometryLive(
            for: target.handle,
            geometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                             end: Vector3(x: 6, y: 0, z: 0), color: nil)])
        TrimGeometryEngine.updateCuttingEdges(&edges, for: target.handle, document: doc)

        let excluded = edges.excluding(target.handle)
        XCTAssertNil(excluded.rangesByHandle[target.handle])
        // Only the cutter's segment remains.
        XCTAssertEqual(excluded.segments.count, 1)
        XCTAssertEqual(excluded.segments.first?.0, Vector3(x: 5, y: -5, z: 0))
        XCTAssertEqual(excluded.segments.first?.1, Vector3(x: 5, y: 5, z: 0))
    }

    /// Far-away cutters must not change a trim outcome: the broad phase may
    /// only drop cutters that cannot intersect the target.
    func testBroadPhasePreservesTrimOutcome() {
        let target = CADPrimitive.line(
            start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 10, y: 0, z: 0), color: nil)
        let near = (Vector3(x: 5, y: -5, z: 0), Vector3(x: 5, y: 5, z: 0))
        var far: [(Vector3, Vector3)] = []
        for i in 0..<200 {
            let x = 10_000.0 + Double(i) * 10.0
            far.append((Vector3(x: x, y: -5, z: 0), Vector3(x: x, y: 5, z: 0)))
        }
        let click = Vector3(x: 8, y: 0, z: 0)

        let (resNear, modNear, errNear) = TrimGeometryEngine.trimPrimitive(
            primitive: target, transform: .identity,
            criterion: .click(point: click),
            cuttingSegments: [near], exactLines: [near])
        let (resFar, modFar, errFar) = TrimGeometryEngine.trimPrimitive(
            primitive: target, transform: .identity,
            criterion: .click(point: click),
            cuttingSegments: [near] + far, exactLines: [near] + far)

        XCTAssertNil(errNear)
        XCTAssertNil(errFar)
        XCTAssertTrue(modNear)
        XCTAssertTrue(modFar)
        XCTAssertEqual(resNear?.count, resFar?.count)
        if case let .line(s1, e1, _) = resNear?.first,
           case let .line(s2, e2, _) = resFar?.first {
            XCTAssertEqual(s1, s2)
            XCTAssertEqual(e1, e2)
        } else {
            XCTFail("Expected kept line in both trims")
        }
    }

    /// The segment broad phase keeps touching cutters (including exact
    /// endpoint touches) and drops disjoint ones.
    func testBroadPhaseSegmentFilter() {
        let target = BoundingBox2d(
            min: Point2d(x: 0, y: 0), max: Point2d(x: 10, y: 0))
        let crossing = (Vector3(x: 5, y: -5, z: 0), Vector3(x: 5, y: 5, z: 0))
        let touching = (Vector3(x: 10, y: 0, z: 0), Vector3(x: 15, y: 0, z: 0))
        let far = (Vector3(x: 10_000, y: -5, z: 0), Vector3(x: 10_000, y: 5, z: 0))
        let kept = TrimGeometryEngine.broadPhaseSegments([crossing, touching, far], intersecting: target)
        XCTAssertEqual(kept.count, 2)
    }

    /// Unbounded cutters are always kept; bounded misses are dropped.
    func testBroadPhaseCurveFilter() {
        let target = BoundingBox2d(
            min: Point2d(x: 0, y: 0), max: Point2d(x: 10, y: 10))
        let nearCircle = Curve2d.circle(Circle2d(center: Point2d(x: 5, y: 5), radius: 2))
        let farCircle = Curve2d.circle(Circle2d(center: Point2d(x: 500, y: 500), radius: 2))
        let ray = Curve2d.ray(Ray2d(origin: Point2d(x: 999, y: 999), direction: Vec2d(x: 1, y: 0)))
        let kept = TrimGeometryEngine.broadPhaseCurves([nearCircle, farCircle, ray], intersecting: target)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(kept.contains(nearCircle))
        XCTAssertTrue(kept.contains(ray))
    }

    /// Fallback-only snap passes must agree with the full call: skipping the
    /// discrete stage only removes repeated work, never the result.
    func testSkipDiscreteFallbackMatchesFullSnap() throws {
        let layer = UUID()
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADEntity {
            CADEntity(layerID: layer, localGeometry: [
                .line(start: Vector3(x: x1, y: y1, z: 0),
                      end: Vector3(x: x2, y: y2, z: 0), color: nil),
            ])
        }
        let entities = [line(0, 0, 10, 0)]
        // Past the (10,0) endpoint along the line: the endpoint is ~1.08
        // away (outside the 1.0 discrete aperture) while the bbox still
        // contains the cursor, so the extension ray applies.
        let full = SnapEngine().nearestSnap(
            worldX: 10.9, worldY: 0.6,
            entities: entities,
            threshold: 1.0,
            extensionSnapEnabled: true,
            extensionThresholdPx: 12.0,
            pixelsPerWorldUnit: 1.0,
            nearestOnCurveOverride: false)
        let fallback = SnapEngine().nearestSnap(
            worldX: 10.9, worldY: 0.6,
            entities: entities,
            threshold: 1.0,
            extensionSnapEnabled: true,
            extensionThresholdPx: 12.0,
            pixelsPerWorldUnit: 1.0,
            nearestOnCurveOverride: false,
            skipDiscreteTargets: true)
        let fullHit = try XCTUnwrap(full, "expected an extension snap from the full call")
        let fallbackHit = try XCTUnwrap(fallback, "fallback-only pass must find the same snap")
        XCTAssertEqual(fullHit.worldPos, fallbackHit.worldPos)
        XCTAssertEqual(fullHit.anchor, fallbackHit.anchor)
    }
}
