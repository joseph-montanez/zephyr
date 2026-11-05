import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// PR3 BREAK (alias BR) and BREAKATPOINT: erase the span between two
/// break points (or split at one point with no gap).
///
/// Covers the geometry engine (open line/arc/polyline/spline two-piece
/// splits, second-point-beyond-end, equal-point no-gap splits, circle
/// CCW-span removal, closed-polyline opening with width/bulge
/// interpolation), the reject list (text/points/blocks/xrefs/hatches/
/// images/tables/ellipses/rays/xlines), one-undo-entry semantics with
/// handle/layer/transform/xdata preservation, locked-layer and
/// viewport-projected guards, the scripted `(command "BREAK" ...)` /
/// `(command "BREAKATPOINT" ...)` runners (entity, entsel-pair,
/// point-pick, and `_F` forms), a Fonts door-routine acceptance test
/// running the `break4` BREAK core from `Fonts/DF12.LSP` verbatim, and
/// registration surfaces.
@MainActor
final class BreakCommandTests: XCTestCase {

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

    private func lineEndpoints(_ entity: CADEntity) -> (Vector3, Vector3)? {
        guard case .line(let start, let end, _) =
                entity.localGeometry?.first else { return nil }
        return (start, end)
    }

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

    private func seedWall(_ host: LispCADHost, from: Vector3 = .zero, to: Vector3) {
        let layer = host.document.findLayer(named: "0")!.handle
        host.document.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.line(start: from, end: to, color: nil)]))
    }

    // MARK: - Engine: open line

    func testBreakLineTwoPieces() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1.5, y: 0, z: 0),
            secondWorld: Vector3(x: 2.5, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        guard let (headStart, headEnd) = lineEndpoints(
            doc.entity(for: entity.handle)!) else {
            return XCTFail("head piece should stay a line")
        }
        XCTAssertEqual(headStart.x, 1, accuracy: 1e-12)
        XCTAssertEqual(headEnd.x, 1.5, accuracy: 1e-12)
        XCTAssertEqual(outcome.newHandles.count, 1)
        guard let (tailStart, tailEnd) = lineEndpoints(
            doc.entity(for: outcome.newHandles[0])!) else {
            return XCTFail("tail piece should be a line")
        }
        XCTAssertEqual(tailStart.x, 2.5, accuracy: 1e-12)
        XCTAssertEqual(tailEnd.x, 3, accuracy: 1e-12)
    }

    func testBreakLineEqualPointsSplitNoGap() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 2, y: 0, z: 0),
            secondWorld: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        let xs = doc.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertEqual(xs.count, 2)
        // Shared split point, no gap: one piece ends at 2, one starts at 2.
        XCTAssertTrue(xs.contains {
            abs($0.1.x - 2) < 1e-9 && abs($0.0.x - 1) < 1e-9
        })
        XCTAssertTrue(xs.contains {
            abs($0.0.x - 2) < 1e-9 && abs($0.1.x - 3) < 1e-9
        })
    }

    func testBreakSecondPointBeyondEndRemovesThatEnd() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1.5, y: 0, z: 0),
            secondWorld: Vector3(x: 9, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 1, "removing one end leaves one piece")
        XCTAssertTrue(outcome.newHandles.isEmpty)
        guard let (start, end) = lineEndpoints(
            doc.entity(for: entity.handle)!) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(start.x, 1, accuracy: 1e-12)
        XCTAssertEqual(end.x, 1.5, accuracy: 1e-12)
    }

    func testBreakWholeSpanRemovesObject() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1, y: 0, z: 0),
            secondWorld: Vector3(x: 3, y: 0, z: 0))

        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(doc.entityCount, 0)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        doc.undo()
        XCTAssertEqual(doc.entityCount, 1, "one undo entry restores the object")
    }

    func testBreakReversedPointsSameSpan() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 2.5, y: 0, z: 0),
            secondWorld: Vector3(x: 1.5, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        guard let (headStart, headEnd) = lineEndpoints(
            doc.entity(for: entity.handle)!) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(headStart.x, 1, accuracy: 1e-12)
        XCTAssertEqual(headEnd.x, 1.5, accuracy: 1e-12)
    }

    func testBreakProjectsFirstPointOntoObject() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 1, y: 0, z: 0),
                end: Vector3(x: 3, y: 0, z: 0), color: nil)])
        doc.addEntity(entity)

        // Pick beside the line: the projection (not the raw pick) anchors
        // the kept head, matching the interactive pick flow.
        let projected = BreakGeometryEngine.projectedPoint(
            entity: entity, worldPick: Vector3(x: 1.5, y: 2, z: 0))
        XCTAssertNotNil(projected)
        XCTAssertEqual(projected?.x ?? -1, 1.5, accuracy: 1e-12)
        XCTAssertEqual(projected?.y ?? -1, 0, accuracy: 1e-12)
    }

    // MARK: - Engine: arc and circle

    func testBreakArcTwoPieces() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.arc(
                center: Vector3(x: 0, y: 0, z: 0), radius: 1,
                startAngle: 0, endAngle: .pi, color: nil)])
        doc.addEntity(entity)

        let p1 = Vector3(x: cos(.pi / 4), y: sin(.pi / 4), z: 0)
        let p2 = Vector3(x: cos(3 * .pi / 4), y: sin(3 * .pi / 4), z: 0)
        let outcome = doc.breakEntity(
            handle: entity.handle, firstWorld: p1, secondWorld: p2)

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        guard case .arc(_, _, let headStart, let headEnd, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first else {
            return XCTFail("head should stay an arc")
        }
        XCTAssertEqual(headStart, 0, accuracy: 1e-12)
        XCTAssertEqual(headEnd, .pi / 4, accuracy: 1e-12)
        guard case .arc(_, _, let tailStart, let tailEnd, _) =
                doc.entity(for: outcome.newHandles[0])?.localGeometry?.first else {
            return XCTFail("tail should be an arc")
        }
        XCTAssertEqual(tailStart, 3 * .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(tailEnd, .pi, accuracy: 1e-12)
    }

    func testBreakCircleRemovesCCWSpan() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 2, color: nil)])
        doc.addEntity(entity)

        // First at angle 0, second at angle pi/2: the CCW quarter-span is
        // removed, leaving the arc from pi/2 around through 2pi.
        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 2, y: 0, z: 0),
            secondWorld: Vector3(x: 0, y: 2, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 1, "circle breaks to one arc")
        guard case .arc(let center, let radius, let start, let end, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first else {
            return XCTFail("circle should become an arc")
        }
        XCTAssertEqual(center.x, 0, accuracy: 1e-12)
        XCTAssertEqual(radius, 2, accuracy: 1e-12)
        XCTAssertEqual(start, .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(end, .pi / 2 + 3 * .pi / 2, accuracy: 1e-12)
    }

    func testBreakCircleEqualPointsNoGap() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 2, color: nil)])
        doc.addEntity(entity)
        let depth = doc.undoManager.undoDepth

        // A no-gap split of a closed curve is the curve itself: the
        // circle is kept as-is (no 360-degree arc is invented).
        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 2, y: 0, z: 0),
            secondWorld: Vector3(x: 2, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 0)
        XCTAssertEqual(doc.entityCount, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        guard case .circle(let center, let radius, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first else {
            return XCTFail("circle should be kept as a circle")
        }
        XCTAssertEqual(center.x, 0, accuracy: 1e-12)
        XCTAssertEqual(radius, 2, accuracy: 1e-12)
    }

    // MARK: - Engine: polylines

    private func addPolyline(
        _ doc: CADDocument, layer: UUID,
        points: [Vector3], isClosed: Bool = false
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(
                path: CADPolyline(points: points, isClosed: isClosed),
                color: nil)])
        doc.addEntity(entity)
        return entity
    }

    private func polyPoints(_ entity: CADEntity) -> [Vector3]? {
        guard case .polyline(let path, _) =
                entity.localGeometry?.first else { return nil }
        return path.vertices.map(\.position)
    }

    func testBreakOpenPolylineTwoPieces() {
        let (doc, layer) = makeDoc()
        let entity = addPolyline(
            doc, layer: layer,
            points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                     Vector3(x: 4, y: 4, z: 0)])

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1, y: 0, z: 0),
            secondWorld: Vector3(x: 4, y: 1, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        XCTAssertEqual(
            polyPoints(doc.entity(for: entity.handle)!)?.map(\.x),
            [0, 1])
        XCTAssertEqual(
            polyPoints(doc.entity(for: entity.handle)!)?.map(\.y),
            [0, 0])
        let tail = polyPoints(doc.entity(for: outcome.newHandles[0])!)!
        XCTAssertEqual(tail.map(\.x), [4, 4])
        XCTAssertEqual(tail.map(\.y), [1, 4])
    }

    func testBreakOpenPolylineAtCornerNoGap() {
        let (doc, layer) = makeDoc()
        let entity = addPolyline(
            doc, layer: layer,
            points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                     Vector3(x: 4, y: 4, z: 0)])

        // BREAKATPOINT-style single point at the corner vertex.
        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 4, y: 0, z: 0),
            secondWorld: Vector3(x: 4, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        let pieces = doc.allEntities.compactMap { polyPoints($0) }
        XCTAssertEqual(pieces.count, 2)
        // The corner is shared: no gap.
        XCTAssertTrue(pieces.contains {
            $0.last?.x == 4 && $0.last?.y == 0
        })
        XCTAssertTrue(pieces.contains {
            $0.first?.x == 4 && $0.first?.y == 0
        })
    }

    func testBreakClosedPolylineOpensWithSpanRemoved() {
        let (doc, layer) = makeDoc()
        let entity = addPolyline(
            doc, layer: layer,
            points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0, z: 0),
                     Vector3(x: 4, y: 3, z: 0), Vector3(x: 0, y: 3, z: 0)],
            isClosed: true)

        // Bottom edge (1,0) to top edge (1,3): the span along path order
        // (bottom partial, right, top partial) is removed; the complement
        // stays as ONE open polyline from (1,3) around to (1,0).
        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1, y: 0, z: 0),
            secondWorld: Vector3(x: 1, y: 3, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 1)
        guard case .polyline(let path, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first else {
            return XCTFail("expected a polyline")
        }
        XCTAssertFalse(path.isClosed)
        let pts = path.vertices.map(\.position)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts.first?.x ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(pts.first?.y ?? -1, 3, accuracy: 1e-12)
        XCTAssertEqual(pts.last?.x ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(pts.last?.y ?? -1, 0, accuracy: 1e-12)
    }

    func testBreakPolylineInterpolatesWidths() {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(vertices: [
            CADPolylineVertex(
                position: Vector3(x: 0, y: 0, z: 0),
                startWidth: 0, endWidth: 0),
            CADPolylineVertex(
                position: Vector3(x: 4, y: 0, z: 0),
                startWidth: 2, endWidth: 4),
            CADPolylineVertex(
                position: Vector3(x: 8, y: 0, z: 0),
                startWidth: 4, endWidth: 4),
        ])
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(path: path, color: nil)])
        doc.addEntity(entity)

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 5, y: 0, z: 0),
            secondWorld: Vector3(x: 7, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        guard case .polyline(let head, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first,
              case .polyline(let tail, _) =
                doc.entity(for: outcome.newHandles[0])?.localGeometry?.first else {
            return XCTFail("expected polylines")
        }
        // Cuts at t=0.25/0.75 of the middle segment interpolate
        // startWidth 2 -> endWidth 4: 2.5 at the head's new end,
        // 3.5 at the tail's new start.
        XCTAssertEqual(head.vertices.last?.startWidth ?? -1, 2.5, accuracy: 1e-12)
        XCTAssertEqual(tail.vertices.first?.startWidth ?? -1, 3.5, accuracy: 1e-12)
    }

    func testBreakPolylineKeepsBulge() {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(vertices: [
            CADPolylineVertex(
                position: Vector3(x: 0, y: 0, z: 0), bulge: 1.0),
            CADPolylineVertex(position: Vector3(x: 4, y: 0, z: 0)),
        ])
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(path: path, color: nil)])
        doc.addEntity(entity)

        // Positive bulge arcs run below the chord here, so the break
        // points sit under the arc and project up onto it.
        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 0.5, y: -1, z: 0),
            secondWorld: Vector3(x: 3.5, y: -1, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        guard case .polyline(let head, _) =
                doc.entity(for: entity.handle)?.localGeometry?.first else {
            return XCTFail("expected a polyline")
        }
        // The surviving bulged edges keep a nonzero bulge (sub-arc).
        XCTAssertTrue(head.vertices.contains { abs($0.bulge) > 1e-12 })
    }

    // MARK: - Engine: spline

    func testBreakSplineTwoPieces() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.spline(
                controlPoints: [Vector3(x: 0, y: 0, z: 0),
                                Vector3(x: 5, y: 0, z: 0),
                                Vector3(x: 10, y: 0, z: 0)],
                knots: [0, 0, 0.5, 1, 1], degree: 1,
                weights: nil, color: nil)])
        doc.addEntity(entity)

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 2.5, y: 0, z: 0),
            secondWorld: Vector3(x: 7.5, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        XCTAssertEqual(doc.entityCount, 2)
        for handle in [entity.handle, outcome.newHandles[0]] {
            guard case .spline = doc.entity(for: handle)?.localGeometry?.first else {
                return XCTFail("spline pieces stay splines")
            }
        }
    }

    // MARK: - Engine: rejects, guards, props

    func testBreakRejectsUnsupportedKinds() {
        let cases: [(String, CADPrimitive)] = [
            ("text", .text(
                position: Vector3(x: 0, y: 0, z: 0), text: "Hi", height: 1,
                rotation: 0, style: nil, alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)),
            ("point", .point(position: Vector3(x: 0, y: 0, z: 0))),
            ("ellipse", .ellipse(
                center: Vector3(x: 0, y: 0, z: 0),
                majorAxis: Vector3(x: 2, y: 0, z: 0), minorRatio: 0.5)),
            ("ray", .ray(
                start: Vector3(x: 0, y: 0, z: 0),
                direction: Vector3(x: 1, y: 0, z: 0))),
            ("xline", .xline(
                point: Vector3(x: 0, y: 0, z: 0),
                direction: Vector3(x: 1, y: 0, z: 0))),
            ("hatch", .hatch(
                boundary: [Vector3(x: 0, y: 0, z: 0)], pattern: "ANSI31",
                scale: 1, angle: 0)),
            ("image", .image(
                insertion: Vector3(x: 0, y: 0, z: 0),
                uAxis: Vector3(x: 1, y: 0, z: 0),
                vAxis: Vector3(x: 0, y: 1, z: 0), imageName: "a.png")),
            ("table", .table(
                data: DataTableData(), origin: Vector3(x: 0, y: 0, z: 0))),
        ]
        for (kind, prim) in cases {
            let (doc, layer) = makeDoc()
            let entity = CADEntity(layerID: layer, localGeometry: [prim])
            doc.addEntity(entity)
            let depth = doc.undoManager.undoDepth
            let outcome = doc.breakEntity(
                handle: entity.handle,
                firstWorld: Vector3(x: 0, y: 0, z: 0),
                secondWorld: Vector3(x: 1, y: 0, z: 0))
            XCTAssertTrue(outcome.rejected, "\(kind) must reject")
            XCTAssertTrue(
                (outcome.message ?? "").contains(kind == "xline" ? "xline" : kind)
                    || (outcome.message ?? "").contains("BREAK"),
                "\(kind): message names the kind: \(outcome.message ?? "")")
            XCTAssertEqual(doc.entityCount, 1)
            XCTAssertEqual(doc.undoManager.undoDepth, depth, "\(kind): no undo entry")
        }
    }

    func testBreakRejectsBlockReference() {
        let (doc, layer) = makeDoc()
        let block = CADBlock(
            handle: UUID(), name: "BLK",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 0, z: 0), color: nil)])
        doc.addBlock(block)
        let entity = CADEntity(layerID: layer, blockID: block.handle)
        doc.addEntity(entity)

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 0, y: 0, z: 0),
            secondWorld: Vector3(x: 1, y: 0, z: 0))

        XCTAssertTrue(outcome.rejected)
        XCTAssertTrue((outcome.message ?? "").contains("block"))
        XCTAssertEqual(doc.entityCount, 1)
    }

    func testBreakLockedLayerRefused() {
        let (doc, _) = makeDoc()
        var locked = Layer(name: "LOCKED")
        locked.isLocked = true
        doc.addLayer(locked)
        let layerID = doc.findLayer(named: "LOCKED")!.handle
        let entity = addLine(
            doc, layer: layerID,
            from: Vector3(x: 1, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 1.5, y: 0, z: 0),
            secondWorld: Vector3(x: 2.5, y: 0, z: 0))

        XCTAssertEqual(outcome.lockedSkipped, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth)
        XCTAssertEqual(
            lineEndpoints(doc.entity(for: entity.handle)!)?.0.x ?? -1, 1,
            accuracy: 1e-12)
    }

    func testBreakSecondPieceCopiesProps() {
        let (doc, _) = makeDoc()
        var walled = Layer(name: "WALLS")
        doc.addLayer(walled)
        walled = doc.findLayer(named: "WALLS")!
        let layerID = walled.handle
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 1, y: 0, z: 0),
                end: Vector3(x: 3, y: 0, z: 0),
                color: ColorRGBA(r: 1, g: 0, b: 0, a: 1))],
            transform: {
                var t = Transform3D()
                t.position = Vector3(x: 10, y: 0, z: 0)
                return t
            }(),
            xdata: ["dxf.lineType": .string("DASHED")],
            drawOrder: 7)
        doc.addEntity(entity)
        entity = doc.entity(for: entity.handle)!

        let outcome = doc.breakEntity(
            handle: entity.handle,
            firstWorld: Vector3(x: 11.5, y: 0, z: 0),
            secondWorld: Vector3(x: 12.5, y: 0, z: 0))

        XCTAssertEqual(outcome.broken, 1)
        let second = doc.entity(for: outcome.newHandles[0])!
        XCTAssertEqual(second.layerID, layerID)
        XCTAssertEqual(second.transform.position.x, 10, accuracy: 1e-12)
        XCTAssertEqual(second.xdata["dxf.lineType"], .string("DASHED"))
        XCTAssertEqual(second.drawOrder, 7)
        guard case .line(_, _, let color) = second.localGeometry?.first else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(color, ColorRGBA(r: 1, g: 0, b: 0, a: 1))
        // The head keeps the original handle and props.
        XCTAssertEqual(doc.entity(for: entity.handle)?.layerID, layerID)
        XCTAssertEqual(
            doc.entity(for: entity.handle)?.xdata["dxf.lineType"],
            .string("DASHED"))
    }

    // MARK: - Scripted (command "BREAK" ...)

    func testScriptedBreakEntPointNoGap() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(setq E (entlast)) (command \"BREAK\" E '(5 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertEqual(xs.count, 2)
        XCTAssertTrue(xs.contains {
            abs($0.1.x - 5) < 1e-9 && abs($0.0.x) < 1e-9
        })
        XCTAssertTrue(xs.contains {
            abs($0.0.x - 5) < 1e-9 && abs($0.1.x - 10) < 1e-9
        })
    }

    func testScriptedBreakEntTwoPointsSpan() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))

        _ = try await eval(
            "(setq E (entlast)) (command \"BREAK\" E '(2 0 0) '(7 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
            .map { ($0.0.x, $0.1.x) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(xs.count, 2)
        XCTAssertEqual(xs[0].0, 0, accuracy: 1e-9)
        XCTAssertEqual(xs[0].1, 2, accuracy: 1e-9)
        XCTAssertEqual(xs[1].0, 7, accuracy: 1e-9)
        XCTAssertEqual(xs[1].1, 10, accuracy: 1e-9)
    }

    func testScriptedBreakExplicitFirstForm() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))

        _ = try await eval(
            "(setq E (entlast)) (command \"BREAK\" E \"_F\" '(2 0 0) '(7 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        let starts = host.document.allEntities.compactMap { lineEndpoints($0)?.0.x }
            .sorted()
        XCTAssertEqual(starts, [0, 7])
    }

    func testScriptedBreakPointPickForm() async throws {
        // The Fonts door-routine idiom: two bare points, no entity operand.
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))

        _ = try await eval(
            "(command \"BREAK\" '(1.5 0.06 0) '(2.5 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
            .map { ($0.0.x, $0.1.x) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(xs[0].0, 0, accuracy: 1e-9)
        XCTAssertEqual(xs[0].1, 1.5, accuracy: 1e-6)
        XCTAssertEqual(xs[1].0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(xs[1].1, 10, accuracy: 1e-9)
    }

    func testScriptedBreakEntselPairForm() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))

        _ = try await eval(
            "(setq E (entlast)) (command \"BREAK\" (list E '(1.5 0 0)) '(2.5 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
            .map { ($0.0.x, $0.1.x) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(xs[0].1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(xs[1].0, 2.5, accuracy: 1e-9)
    }

    func testScriptedBreakAtPoint() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(setq E (entlast)) (command \"BREAKATPOINT\" E '(5 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertTrue(xs.contains {
            abs($0.1.x - 5) < 1e-9 && abs($0.0.x) < 1e-9
        })
        XCTAssertTrue(xs.contains {
            abs($0.0.x - 5) < 1e-9 && abs($0.1.x - 10) < 1e-9
        })
    }

    func testScriptedBreakFailClosed() async throws {
        // Unknown keyword where the second point goes.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
            _ = try await eval(
                "(setq E (entlast)) (command \"BREAK\" E \"_Q\")",
                host: host, env: &env)
            XCTFail("unknown keyword must reject")
        } catch { }
        // Missing second point in _F form.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
            _ = try await eval(
                "(setq E (entlast)) (command \"BREAK\" E \"_F\" '(1 0 0))",
                host: host, env: &env)
            XCTFail("missing second point must reject")
        } catch { }
        // Trailing garbage.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
            _ = try await eval(
                "(setq E (entlast)) (command \"BREAK\" E '(2 0 0) '(7 0 0) \"EXTRA\")",
                host: host, env: &env)
            XCTFail("trailing input must reject")
        } catch { }
        // Selection instead of a single object.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedWall(host, to: Vector3(x: 10, y: 0, z: 0))
            _ = try await eval(
                "(command \"BREAK\" \"ALL\" '(2 0 0))",
                host: host, env: &env)
            XCTFail("bare set must reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("BREAK"), "error names the command: \(error)")
        }
        // Unsupported kind throws (fail closed).
        do {
            let host = makeHost()
            var env = LispEnvironment()
            let layer = host.document.findLayer(named: "0")!.handle
            host.document.addEntity(CADEntity(
                layerID: layer,
                localGeometry: [.text(
                    position: Vector3(x: 5, y: 0, z: 0), text: "Hi",
                    height: 1, rotation: 0, style: nil,
                    alignH: 0, alignV: 0, mtextWidth: nil, color: nil)]))
            _ = try await eval(
                "(setq E (entlast)) (command \"BREAK\" E '(5 0 0))",
                host: host, env: &env)
            XCTFail("text must reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("text"), "error names text: \(error)")
        }
    }

    // MARK: - Fonts corpus acceptance (DF12 door routine)

    private func repoFile(_ name: String) -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return name
    }

    /// Runs the `break4` BREAK core from `Fonts/DF12.LSP` verbatim (lines
    /// 35-44 minus the interactive-only `(command "LAYER" ...)` step, which
    /// the audited scripted set rejects by design; the test pre-creates and
    /// activates the WALL layer to mirror that step's intent). The file
    /// header notes the routine needs a door opening [Point3, Point4) cut
    /// out of a longer wall, then jamb lines X5-X8 and X6-X7.
    func testFontsDF12BreakRoutine() async throws {
        let path = repoFile("Fonts/DF12.LSP")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(
            source.contains("(defun break4()"),
            "DF12.LSP must still define the break4 routine")

        let host = makeHost()
        var env = LispEnvironment()
        host.document.addLayer(Layer(name: "WALL"))
        host.document.activeLayerID = host.document.findLayer(named: "WALL")?.handle
        seedWall(host, to: Vector3(x: 20, y: 0, z: 0))
        _ = try await eval(source, host: host, env: &env)

        // Door opening [5, 9) in the wall, exactly as Get4 would produce.
        _ = try await eval("(setq Point3 '(5 0 0) Angle2 0.0 Point4 '(9 0 0))",
                           host: host, env: &env)
        // Verbatim DF12.LSP break4 X5..X8 computation (lines 36-39).
        _ = try await eval(
            """
            (SETQ X5 (POLAR Point3 (+ Angle2 (/ PI 2)) 0.06)
                   X6 (POLAR Point4 (+ Angle2 (/ PI 2)) 0.06)
                   X7 (POLAR Point4 (+ Angle2 (* PI 1.5)) 0.06)
                   X8 (POLAR Point3 (+ Angle2 (* PI 1.5)) 0.06))
            """,
            host: host, env: &env)
        // Verbatim DF12.LSP break/line tail (lines 41-44).
        _ = try await eval("(command \"BREAK\" X5 X6)", host: host, env: &env)
        _ = try await eval("(command \"BREAK\" X8 X7)", host: host, env: &env)
        _ = try await eval("(command \"LINE\" X5 X8 \"\")", host: host, env: &env)
        _ = try await eval("(command \"LINE\" X6 X7 \"\")", host: host, env: &env)

        // Wall [0,20] lost [5,9); the second BREAK re-splits the head at
        // its end (no gap); two jamb lines close the opening.
        let lines = host.document.allEntities.compactMap { entity -> (Vector3, Vector3)? in
            guard case .line(let s, let e, _) = entity.localGeometry?.first else {
                return nil
            }
            return (s, e)
        }
        XCTAssertEqual(lines.count, 4)
        let walls = lines.filter {
            abs($0.0.y) < 1e-9 && abs($0.1.y) < 1e-9
        }.map { (min($0.0.x, $0.1.x), max($0.0.x, $0.1.x)) }
            .sorted { $0.0 < $1.0 }
        XCTAssertEqual(walls.count, 2)
        XCTAssertEqual(walls[0].0, 0, accuracy: 1e-9)
        XCTAssertEqual(walls[0].1, 5, accuracy: 1e-9)
        XCTAssertEqual(walls[1].0, 9, accuracy: 1e-9)
        XCTAssertEqual(walls[1].1, 20, accuracy: 1e-9)
        let jambs = lines.filter {
            abs($0.0.y) > 1e-9 || abs($0.1.y) > 1e-9
        }
        XCTAssertEqual(jambs.count, 2)
    }

    // MARK: - Registration surfaces

    func testBreakRegistrationSurfaces() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains {
                $0.canonicalName == "BREAK" && $0.aliases.contains("BR")
            },
            "BREAK descriptor with BR alias missing")
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains {
                $0.canonicalName == "BREAKATPOINT"
            },
            "BREAKATPOINT descriptor missing")
        XCTAssertTrue(
            CADCommandAliasTable.entries.contains {
                $0.canonicalName == "BREAK" && $0.aliases.contains("BR")
                    && !$0.isReservedStub
            },
            "BREAK alias-table row missing or still a stub")
        XCTAssertTrue(
            CADCommandAliasTable.entries.contains {
                $0.canonicalName == "BREAKATPOINT" && !$0.isReservedStub
            },
            "BREAKATPOINT alias-table row missing or still a stub")
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "BREAK"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "BR"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "BREAKATPOINT"))
        XCTAssertNotNil(CADCommandAliasTable.entry(canonicalName: "BREAK"))
        XCTAssertNotNil(CADCommandAliasTable.entry(canonicalName: "BREAKATPOINT"))
        XCTAssertTrue(
            LispScriptedCommands.scripted.contains("BREAK"),
            "BREAK missing from the scripted set")
        XCTAssertTrue(
            LispScriptedCommands.scripted.contains("BREAKATPOINT"),
            "BREAKATPOINT missing from the scripted set")
    }
}
