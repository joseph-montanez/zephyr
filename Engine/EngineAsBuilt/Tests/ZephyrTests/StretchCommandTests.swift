import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// PR2 STRETCH (alias S): partial stretch across a captured crossing
/// region, whole-move for fully enclosed / individually picked objects.
///
/// Covers the crossing-window and crossing-polygon region capture, per-type
/// rules (lines, polylines with bulges/widths, splines, arc re-solve,
/// whole-only circles/blocks/text/points/rays/xlines/images/hatches),
/// world-space testing through the inverse transform, zero-displacement
/// no-undo, locked-layer and viewport-projected guards, one undo entry for
/// the whole set with in-session undo, last-displacement memory, typed
/// parsing (absolute/@/polar + relative displacement), the scripted
/// `(command "STRETCH" ...)` runner, and registration surfaces.
@MainActor
final class StretchCommandTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return (doc, doc.findLayer(named: "0")!.handle)
    }

    @discardableResult
    private func addLine(
        _ doc: CADDocument, layer: UUID,
        from: Vector3, to: Vector3,
        transform: Transform3D = .identity
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.line(start: from, end: to, color: nil)],
            transform: transform)
        doc.addEntity(entity)
        return entity
    }

    private func rect(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> StretchRegion {
        .rect(
            min: Vector3(x: min(x1, x2), y: min(y1, y2), z: 0),
            max: Vector3(x: max(x1, x2), y: max(y1, y2), z: 0))
    }

    private func lineEndpoints(
        _ entity: CADEntity
    ) -> (Vector3, Vector3)? {
        guard case .line(let start, let end, _) =
                entity.localGeometry?.first else { return nil }
        return (start, end)
    }

    // MARK: - Lines: partial vs whole

    func testLinePartialStretchMovesEnclosedEndpoint() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(4, -1, 12, 1)],
            moveWhole: [], by: Vector3(x: 2, y: 3, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        XCTAssertEqual(outcome.movedWhole, 0)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "one undo entry")
        let (start, end) = lineEndpoints(doc.entity(for: entity.handle)!)!
        XCTAssertEqual(start.x, 0, accuracy: 1e-12)
        XCTAssertEqual(start.y, 0, accuracy: 1e-12)
        XCTAssertEqual(end.x, 12, accuracy: 1e-12)
        XCTAssertEqual(end.y, 3, accuracy: 1e-12)

        doc.undo()
        let (restoredStart, restoredEnd) =
            lineEndpoints(doc.entity(for: entity.handle)!)!
        XCTAssertEqual(restoredStart.x, 0, accuracy: 1e-12)
        XCTAssertEqual(restoredEnd.x, 10, accuracy: 1e-12)
    }

    func testLineFullyEnclosedMovesWhole() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 1, z: 0), to: Vector3(x: 3, y: 1, z: 0))

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 5, 5)],
            moveWhole: [], by: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 1)
        XCTAssertEqual(outcome.stretched, 0)
        let stored = doc.entity(for: entity.handle)!
        XCTAssertEqual(stored.transform.position.x, 2, accuracy: 1e-12)
        // Local geometry untouched by a whole move.
        let (start, end) = lineEndpoints(stored)!
        XCTAssertEqual(start.x, 1, accuracy: 1e-12)
        XCTAssertEqual(end.x, 3, accuracy: 1e-12)
    }

    func testIndividuallyPickedMovesWholeOutsideRegion() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 50, y: 50, z: 0), to: Vector3(x: 60, y: 50, z: 0))

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 5, 5)],
            moveWhole: [entity.handle], by: Vector3(x: -5, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 1)
        XCTAssertEqual(
            doc.entity(for: entity.handle)!.transform.position.x, -5, accuracy: 1e-12)
    }

    func testLineOutsideRegionUnchanged() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 50, y: 50, z: 0), to: Vector3(x: 60, y: 50, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 5, 5)],
            moveWhole: [], by: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.unchanged, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "no undo pushed")
    }

    // MARK: - Polylines / splines / arcs

    func testPolylinePreservesBulgesWidthsAndClosed() {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(
                    position: Vector3(x: 0, y: 0, z: 0),
                    bulge: 0, startWidth: 1, endWidth: 1),
                CADPolylineVertex(
                    position: Vector3(x: 10, y: 0, z: 0),
                    bulge: 1.0, startWidth: 2, endWidth: 3),
                CADPolylineVertex(
                    position: Vector3(x: 10, y: 10, z: 0),
                    bulge: 0, startWidth: 4, endWidth: 4),
            ],
            isClosed: true)
        let entity = CADEntity(
            layerID: layer, localGeometry: [.polyline(path: path, color: nil)])
        doc.addEntity(entity)

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(9, -1, 11, 1)],
            moveWhole: [], by: Vector3(x: 5, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        guard case .polyline(let moved, _) =
                doc.entity(for: entity.handle)!.localGeometry?.first else {
            return XCTFail("expected a polyline")
        }
        XCTAssertTrue(moved.isClosed, "closed stays closed")
        XCTAssertEqual(moved.vertices.count, 3)
        XCTAssertEqual(moved.vertices[0].position.x, 0, accuracy: 1e-12)
        XCTAssertEqual(moved.vertices[1].position.x, 15, accuracy: 1e-12)
        XCTAssertEqual(moved.vertices[2].position.y, 10, accuracy: 1e-12)
        XCTAssertEqual(moved.vertices[1].bulge, 1.0, accuracy: 1e-12)
        XCTAssertEqual(moved.vertices[1].startWidth, 2, accuracy: 1e-12)
        XCTAssertEqual(moved.vertices[1].endWidth, 3, accuracy: 1e-12)
    }

    func testSplineMovesEnclosedControlPoints() {
        let (doc, layer) = makeDoc()
        let cps = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 5, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0), Vector3(x: 15, y: 0, z: 0),
        ]
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.spline(
                controlPoints: cps, knots: [0, 0, 0, 0, 1, 1, 1, 1],
                degree: 3, weights: nil, color: nil)])
        doc.addEntity(entity)

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(4, -1, 6, 1)],
            moveWhole: [], by: Vector3(x: 0, y: 4, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        guard case .spline(let moved, let knots, let degree, _, _) =
                doc.entity(for: entity.handle)!.localGeometry?.first else {
            return XCTFail("expected a spline")
        }
        XCTAssertEqual(moved[0].x, 0, accuracy: 1e-12)
        XCTAssertEqual(moved[1].y, 4, accuracy: 1e-12)
        XCTAssertEqual(moved[2].x, 10, accuracy: 1e-12)
        XCTAssertEqual(moved[3].x, 15, accuracy: 1e-12)
        XCTAssertEqual(knots, [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(degree, 3)
    }

    func testArcResolvesFromMovedEndpointsAndCenter() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.arc(
                center: Vector3(x: 0, y: 0, z: 0), radius: 5,
                startAngle: 0, endAngle: Double.pi / 2, color: nil)])
        doc.addEntity(entity)

        // Start point (5,0) enclosed; center and end point are not.
        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(4, -1, 6, 1)],
            moveWhole: [], by: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        guard case .arc(let center, let radius, let startAngle, let endAngle, _) =
                doc.entity(for: entity.handle)!.localGeometry?.first else {
            return XCTFail("expected an arc")
        }
        XCTAssertEqual(center.x, 0, accuracy: 1e-12)
        XCTAssertEqual(radius, 7, accuracy: 1e-12)
        XCTAssertEqual(startAngle, 0, accuracy: 1e-12)
        XCTAssertEqual(endAngle, Double.pi / 2, accuracy: 1e-9)
    }

    // MARK: - Whole-only types

    func testCirclePartiallyCoveredIsUnchanged() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.circle(
                center: Vector3(x: 5, y: 5, z: 0), radius: 2, color: nil)])
        doc.addEntity(entity)
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 1, 1)],
            moveWhole: [], by: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.unchanged, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "no undo pushed")
    }

    func testCircleFullyEnclosedMovesWhole() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.circle(
                center: Vector3(x: 5, y: 5, z: 0), radius: 2, color: nil)])
        doc.addEntity(entity)

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 10, 10)],
            moveWhole: [], by: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 1)
        let stored = doc.entity(for: entity.handle)!
        XCTAssertEqual(stored.transform.position.x, 2, accuracy: 1e-12)
        guard case .circle(let center, let radius, _) =
                stored.localGeometry?.first else {
            return XCTFail("expected a circle")
        }
        XCTAssertEqual(center.x, 5, accuracy: 1e-12)
        XCTAssertEqual(radius, 2, accuracy: 1e-12)
    }

    func testBlockInsertMovesByInsertionPointOnly() {
        let (doc, layer) = makeDoc()
        let geometry: [CADPrimitive] = [.line(
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 3, y: 1, z: 0), color: nil)]
        let block = CADBlock(handle: UUID(), name: "STBLK", geometry: geometry)
        doc.addBlock(block)
        var placement = Transform3D()
        placement.position = Vector3(x: 2, y: 3, z: 0)
        let insert = CADEntity(
            layerID: layer, blockID: block.handle, transform: placement)
        doc.addEntity(insert)

        // Insertion (2,3) enclosed: the whole insert moves, shared geometry kept.
        let outcome = doc.stretchEntities(
            handles: [insert.handle], regions: [rect(0, 0, 5, 5)],
            moveWhole: [], by: Vector3(x: 10, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 1)
        let stored = doc.entity(for: insert.handle)!
        XCTAssertEqual(stored.transform.position.x, 12, accuracy: 1e-12)
        XCTAssertEqual(stored.transform.position.y, 3, accuracy: 1e-12)
        XCTAssertEqual(doc.block(for: block.handle)?.geometry, geometry)

        // Insertion outside the region: untouched, no undo.
        let depth = doc.undoManager.undoDepth
        let missed = doc.stretchEntities(
            handles: [insert.handle], regions: [rect(50, 50, 60, 60)],
            moveWhole: [], by: Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(missed.unchanged, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        XCTAssertEqual(
            doc.entity(for: insert.handle)!.transform.position.x, 12, accuracy: 1e-12)
    }

    func testTextPointRayXlineMoveByBasePoint() {
        let (doc, layer) = makeDoc()
        let text = CADEntity(
            layerID: layer,
            localGeometry: [.text(
                position: Vector3(x: 5, y: 5, z: 0), text: "Hi",
                height: 2.5, rotation: 0.5, style: nil,
                alignH: 0, alignV: 0, mtextWidth: nil, color: nil)])
        doc.addEntity(text)
        let point = CADEntity(
            layerID: layer,
            localGeometry: [.point(position: Vector3(x: 6, y: 6, z: 0), color: nil)])
        doc.addEntity(point)
        let ray = CADEntity(
            layerID: layer,
            localGeometry: [.ray(
                start: Vector3(x: 7, y: 7, z: 0),
                direction: Vector3(x: 1, y: 0, z: 0), color: nil)])
        doc.addEntity(ray)
        let xline = CADEntity(
            layerID: layer,
            localGeometry: [.xline(
                point: Vector3(x: 8, y: 8, z: 0),
                direction: Vector3(x: 0, y: 1, z: 0), color: nil)])
        doc.addEntity(xline)
        let far = addLine(
            doc, layer: layer,
            from: Vector3(x: 100, y: 100, z: 0), to: Vector3(x: 101, y: 100, z: 0))

        let outcome = doc.stretchEntities(
            handles: [text.handle, point.handle, ray.handle, xline.handle, far.handle],
            regions: [rect(4, 4, 9, 9)],
            moveWhole: [], by: Vector3(x: 1, y: 0, z: 0))

        // Single-base-point types fully enclosed in the region move whole.
        XCTAssertEqual(outcome.movedWhole, 4)
        XCTAssertEqual(outcome.stretched, 0)
        XCTAssertEqual(outcome.unchanged, 1)
        let movedText = doc.entity(for: text.handle)!
        XCTAssertEqual(movedText.transform.position.x, 1, accuracy: 1e-12)
        guard case .text(let textPos, _, _, let rotation, _, _, _, _, _) =
                movedText.localGeometry?.first else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(textPos.x, 5, accuracy: 1e-12, "local insertion untouched")
        XCTAssertEqual(rotation, 0.5, accuracy: 1e-12, "rotation preserved")
        let movedRay = doc.entity(for: ray.handle)!
        XCTAssertEqual(movedRay.transform.position.x, 1, accuracy: 1e-12)
        guard case .ray(let rayStart, let rayDir, _) =
                movedRay.localGeometry?.first else {
            return XCTFail("expected ray")
        }
        XCTAssertEqual(rayStart.x, 7, accuracy: 1e-12, "local start untouched")
        XCTAssertEqual(rayDir.x, 1, accuracy: 1e-12, "direction preserved")
        let movedXline = doc.entity(for: xline.handle)!
        XCTAssertEqual(movedXline.transform.position.x, 1, accuracy: 1e-12)
        guard case .xline(let xlinePoint, _, _) =
                movedXline.localGeometry?.first else {
            return XCTFail("expected xline")
        }
        XCTAssertEqual(xlinePoint.x, 8, accuracy: 1e-12, "local base point untouched")
    }

    func testHatchBoundaryMovesLikePolyline() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.hatch(
                boundary: [
                    Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
                    Vector3(x: 10, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0),
                ],
                pattern: "ANSI31", scale: 1, angle: 0,
                color: nil, backgroundColor: nil)])
        doc.addEntity(entity)

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(9, -1, 11, 11)],
            moveWhole: [], by: Vector3(x: 5, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        guard case .hatch(let boundary, let pattern, _, _, _, _) =
                doc.entity(for: entity.handle)!.localGeometry?.first else {
            return XCTFail("expected a hatch")
        }
        XCTAssertEqual(pattern, "ANSI31")
        XCTAssertEqual(boundary[0].x, 0, accuracy: 1e-12)
        XCTAssertEqual(boundary[1].x, 15, accuracy: 1e-12)
        XCTAssertEqual(boundary[2].x, 15, accuracy: 1e-12)
        XCTAssertEqual(boundary[3].x, 0, accuracy: 1e-12)
    }

    // MARK: - World space through transforms

    func testStretchMapsThroughInverseTransform() {
        let (doc, layer) = makeDoc()
        // Local (0,0)-(10,0) rotated 90° CCW then translated: world (100,0)-(100,10).
        let transform = Transform3D.translated(by: Vector3(x: 100, y: 0, z: 0))
            .multiplying(by: Transform3D.rotated(by: Double.pi / 2))
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0),
            transform: transform)

        // Crossing covers only the world end (100,10).
        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(99, 5, 101, 15)],
            moveWhole: [], by: Vector3(x: 5, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        let (start, end) = lineEndpoints(doc.entity(for: entity.handle)!)!
        XCTAssertEqual(start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(start.y, 0, accuracy: 1e-9)
        // World (105,10) mapped back: translate off, rotate back = (10,-5).
        XCTAssertEqual(end.x, 10, accuracy: 1e-9)
        XCTAssertEqual(end.y, -5, accuracy: 1e-9)
    }

    func testPolygonRegionContainment() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        let triangle = StretchRegion.polygon([
            Vector3(x: 4, y: -5, z: 0), Vector3(x: 14, y: 0, z: 0),
            Vector3(x: 4, y: 5, z: 0),
        ])

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [triangle],
            moveWhole: [], by: Vector3(x: 0, y: 2, z: 0))

        XCTAssertEqual(outcome.stretched, 1)
        let (start, end) = lineEndpoints(doc.entity(for: entity.handle)!)!
        XCTAssertEqual(start.y, 0, accuracy: 1e-12, "start outside the triangle")
        XCTAssertEqual(end.y, 2, accuracy: 1e-12, "end inside the triangle")
    }

    // MARK: - Guards: zero delta, locked layers, viewport copies

    func testZeroDisplacementExitsWithNoUndo() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [entity.handle], regions: [rect(0, 0, 20, 20)],
            moveWhole: [], by: Vector3(x: 0, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 0)
        XCTAssertEqual(outcome.movedWhole, 0)
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
    }

    func testLockedLayersRefusedWithCount() {
        let (doc, zero) = makeDoc()
        doc.addLayer(Layer(name: "LOCKED"))
        let lockedID = doc.findLayer(named: "LOCKED")!.handle
        doc.setLayerLocked(lockedID, locked: true)
        let locked = addLine(
            doc, layer: lockedID,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 2, y: 0, z: 0))
        let free = addLine(
            doc, layer: zero,
            from: Vector3(x: 3, y: 0, z: 0), to: Vector3(x: 4, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [locked.handle, free.handle], regions: [rect(0, -1, 5, 1)],
            moveWhole: [], by: Vector3(x: 1, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 1, "free line fully enclosed")
        XCTAssertEqual(outcome.lockedSkipped, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "one undo entry")
        let (lockedStart, _) = lineEndpoints(doc.entity(for: locked.handle)!)!
        XCTAssertEqual(lockedStart.x, 1, accuracy: 1e-12, "locked line untouched")
    }

    func testViewportProjectedSkipped() {
        let (doc, layer) = makeDoc()
        var projected = CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 1, y: 0, z: 0),
                end: Vector3(x: 2, y: 0, z: 0), color: nil)])
        projected.xdata["dxf.viewport.projected"] = .bool(true)
        doc.addEntity(projected)
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [projected.handle], regions: [rect(0, -1, 5, 1)],
            moveWhole: [], by: Vector3(x: 1, y: 0, z: 0))

        XCTAssertEqual(outcome.movedWhole, 0)
        XCTAssertEqual(outcome.projectedSkipped, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "no undo pushed")
    }

    func testOneUndoEntryForWholeSet() {
        let (doc, layer) = makeDoc()
        let first = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 10, y: 0, z: 0))
        let second = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 5, z: 0), to: Vector3(x: 10, y: 5, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.stretchEntities(
            handles: [first.handle, second.handle], regions: [rect(9, -1, 11, 6)],
            moveWhole: [], by: Vector3(x: 3, y: 0, z: 0))

        XCTAssertEqual(outcome.stretched, 2)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "one undo entry")
        doc.undo()
        XCTAssertEqual(
            lineEndpoints(doc.entity(for: first.handle)!)!.1.x, 10, accuracy: 1e-12)
        XCTAssertEqual(
            lineEndpoints(doc.entity(for: second.handle)!)!.1.x, 10, accuracy: 1e-12)
    }

    // MARK: - Typed points and displacements

    func testParseTypedPointForms() {
        XCTAssertEqual(
            StretchCommand.parseTypedPoint("10,20", base: .zero),
            Vector3(x: 10, y: 20, z: 0))
        XCTAssertEqual(
            StretchCommand.parseTypedPoint("@3,4", base: Vector3(x: 1, y: 1, z: 0)),
            Vector3(x: 4, y: 5, z: 0))
        let polar = StretchCommand.parseTypedPoint(
            "5<0", base: Vector3(x: 1, y: 1, z: 0))!
        XCTAssertEqual(polar.x, 6, accuracy: 1e-9)
        XCTAssertEqual(polar.y, 1, accuracy: 1e-9)
        XCTAssertNil(StretchCommand.parseTypedPoint("abc", base: .zero))
    }

    func testParseDisplacementBareIsRelative() {
        // A bare x,y is the displacement itself (not an absolute point).
        XCTAssertEqual(
            StretchCommand.parseDisplacement("3,4"),
            Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(
            StretchCommand.parseDisplacement("@3,4"),
            Vector3(x: 3, y: 4, z: 0))
        let polar = StretchCommand.parseDisplacement("5<90")!
        XCTAssertEqual(polar.x, 0, accuracy: 1e-9)
        XCTAssertEqual(polar.y, 5, accuracy: 1e-9)
        XCTAssertNil(StretchCommand.parseDisplacement("abc"))
    }

    // MARK: - Scripted (command "STRETCH" ...)

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.activeLayerID = doc.findLayer(named: "0")?.handle
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        return host
    }

    private func eval(
        _ source: String, host: LispCADHost, env: inout LispEnvironment
    ) async throws -> LispValue {
        let forms = try LispReader().readAll(source)
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    private func seedStretchLine(_ host: LispCADHost) {
        let layer = host.document.findLayer(named: "0")!.handle
        host.document.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 1, y: 0, z: 0),
                end: Vector3(x: 3, y: 0, z: 0), color: nil)]))
    }

    func testScriptedStretchCrossingWindow() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" '(0 0 0) '(1 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        guard case .line(let start, let end, _) =
                host.document.allEntities.first!.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 1, accuracy: 1e-12, "start outside the window")
        XCTAssertEqual(end.x, 4, accuracy: 1e-12, "end stretched by (1,0)")
        XCTAssertEqual(StretchSettings.lastDisplacement?.x ?? -999, 1, accuracy: 1e-12)
    }

    func testScriptedStretchCrossingPolygon() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)

        _ = try await eval(
            "(command \"STRETCH\" \"_CP\" '(2 -1 0) '(4 -1 0) '(2 1 0) \"\" '(0 0 0) '(0 5 0))",
            host: host, env: &env)

        guard case .line(let start, let end, _) =
                host.document.allEntities.first!.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 1, accuracy: 1e-12)
        XCTAssertEqual(end.y, 5, accuracy: 1e-12)
    }

    func testScriptedStretchWholeMoveWhenFullyEnclosed() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)

        _ = try await eval(
            "(command \"STRETCH\" \"_C\" '(0 -5 0) '(5 5 0) \"\" '(0 0 0) '(10 0 0))",
            host: host, env: &env)

        let stored = host.document.allEntities.first!
        XCTAssertEqual(stored.transform.position.x, 10, accuracy: 1e-12)
        guard case .line(let start, _, _) = stored.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 1, accuracy: 1e-12, "local geometry untouched")
    }

    func testScriptedStretchDisplacementBranch() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)

        _ = try await eval(
            "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" \"_D\" '(7 8 0))",
            host: host, env: &env)

        guard case .line(let start, let end, _) =
                host.document.allEntities.first!.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 1, accuracy: 1e-12)
        XCTAssertEqual(end.x, 10, accuracy: 1e-12)
        XCTAssertEqual(end.y, 8, accuracy: 1e-12)
        XCTAssertEqual(StretchSettings.lastDisplacement?.x ?? -999, 7, accuracy: 1e-12)
    }

    func testScriptedStretchUseBaseAsDisplacement() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)

        _ = try await eval(
            "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" '(2 0 0) \"\")",
            host: host, env: &env)

        guard case .line(_, let end, _) =
                host.document.allEntities.first!.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(end.x, 5, accuracy: 1e-12, "end moved by the base point (2,0)")
    }

    func testScriptedStretchZeroDisplacementNoUndo() async throws {
        StretchSettings.resetForTesting()
        let host = makeHost()
        var env = LispEnvironment()
        seedStretchLine(host)
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" '(1 1 0) '(1 1 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.undoManager.undoDepth, depth)
        guard case .line(_, let end, _) =
                host.document.allEntities.first!.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(end.x, 3, accuracy: 1e-12)
    }

    func testScriptedStretchRejectsBareSetByName() async throws {
        for source in [
            "(command \"STRETCH\" \"ALL\" \"\" '(0 0 0) '(1 0 0))",
            "(command \"STRETCH\" \"_W\" '(0 0 0) '(1 1 0) \"\" '(0 0 0) '(1 0 0))",
        ] {
            do {
                let host = makeHost()
                var env = LispEnvironment()
                seedStretchLine(host)
                _ = try await eval(source, host: host, env: &env)
                XCTFail("bare set must reject: \(source)")
            } catch let error as LispError {
                XCTAssertTrue(
                    "\(error)".contains("STRETCH"),
                    "error names the command: \(error)")
            }
        }
    }

    func testScriptedStretchFailClosed() async throws {
        // Missing Enter after the crossing window.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedStretchLine(host)
            _ = try await eval(
                "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) '(0 0 0) '(1 0 0))",
                host: host, env: &env)
            XCTFail("missing Enter must reject")
        } catch { }
        // Polygon with fewer than 3 points.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedStretchLine(host)
            _ = try await eval(
                "(command \"STRETCH\" \"_CP\" '(2 -1 0) '(4 1 0) \"\" '(0 0 0) '(1 0 0))",
                host: host, env: &env)
            XCTFail("short polygon must reject")
        } catch { }
        // Trailing garbage.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedStretchLine(host)
            _ = try await eval(
                "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" '(0 0 0) '(1 0 0) \"EXTRA\")",
                host: host, env: &env)
            XCTFail("trailing input must reject")
        } catch { }
        // Missing second point.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedStretchLine(host)
            _ = try await eval(
                "(command \"STRETCH\" \"_C\" '(2 -1 0) '(4 1 0) \"\" '(0 0 0))",
                host: host, env: &env)
            XCTFail("missing second point must reject")
        } catch { }
    }

    // MARK: - Registration surfaces

    func testStretchRegistrationSurfaces() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains {
                $0.canonicalName == "STRETCH" && $0.aliases.contains("S")
            },
            "STRETCH descriptor with S alias missing")
        XCTAssertTrue(
            CADCommandAliasTable.entries.contains {
                $0.canonicalName == "STRETCH" && $0.aliases.contains("S")
                    && !$0.isReservedStub
            },
            "STRETCH alias-table row missing or still a stub")
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "STRETCH"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "S"))
        XCTAssertNotNil(CADCommandAliasTable.entry(canonicalName: "STRETCH"))
        XCTAssertTrue(
            LispScriptedCommands.scripted.contains("STRETCH"),
            "STRETCH missing from the scripted set")
    }
}
