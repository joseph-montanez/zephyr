import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// PR4 EXTEND (alias EX): extend open objects along their natural path to
/// the nearest boundary edge (nearest-boundary hit for the end nearest the
/// pick; EDGEMODE=0 uses boundaries as built, =1 lets them extend).
///
/// Covers the engine solvers (line end/start, nearest-wins, edge-mode
/// boundary extension, arc forward/backward along its circle, open-polyline
/// line and bulge end-segments, spline end-tangent success and clean-miss,
/// closed/invalid rejections, multi-primitive splice, transformed targets),
/// the scripted `(command "EXTEND" ...)` runners (pick, `_F` fence batches,
/// `_C` crossing, `_E`/`_P` values, fail-closed keywords), and the
/// registration surfaces.
@MainActor
final class ExtendCommandTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return (doc, doc.findLayer(named: "0")!.handle)
    }

    @discardableResult
    private func addLine(
        _ doc: CADDocument, layer: UUID,
        from: Vector3, to: Vector3
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.line(start: from, end: to, color: nil)])
        doc.addEntity(entity)
        return entity
    }

    private func lineEndpoints(_ entity: CADEntity) -> (Vector3, Vector3)? {
        guard case .line(let start, let end, _) =
                entity.localGeometry?.first else { return nil }
        return (start, end)
    }

    private func boundaries(
        _ doc: CADDocument, handles: [UUID]
    ) -> TrimGeometryEngine.TrimCuttingEdges {
        TrimGeometryEngine.collectCuttingEdges(
            document: doc, cuttingHandles: Set(handles), excludedHandle: nil)
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

    private func seedTargetAndBoundary(_ host: LispCADHost) {
        let layer = host.document.findLayer(named: "0")!.handle
        host.document.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 5, y: 0, z: 0), color: nil)]))
        host.document.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 8, y: -5, z: 0),
                end: Vector3(x: 8, y: 5, z: 0), color: nil)]))
    }

    // MARK: - Engine: line

    func testExtendLineEndToBoundary() {
        let (doc, layer) = makeDoc()
        let target = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 5, y: 0, z: 0))
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 8, y: -5, z: 0), to: Vector3(x: 8, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 4.5, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .line(_, let end, _) = geom?.first else {
            return XCTFail("Expected extended line")
        }
        XCTAssertEqual(end.x, 8, accuracy: 1e-9)
        XCTAssertEqual(end.y, 0, accuracy: 1e-9)
    }

    func testExtendLineStartToBoundary() {
        let (doc, layer) = makeDoc()
        let target = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 5, y: 0, z: 0))
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: -4, y: -5, z: 0), to: Vector3(x: -4, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 0.5, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .line(let start, _, _) = geom?.first else {
            return XCTFail("Expected extended line")
        }
        XCTAssertEqual(start.x, -4, accuracy: 1e-9)
    }

    func testExtendLineNoHitStaysUnmodified() {
        let (doc, layer) = makeDoc()
        let target = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 5, y: 0, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 4.5, y: 0, z: 0),
            boundaries: .empty, edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertFalse(modified)
        XCTAssertNil(geom)
    }

    func testExtendLineNearestBoundaryWins() {
        let (doc, layer) = makeDoc()
        let target = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 5, y: 0, z: 0))
        let near = addLine(
            doc, layer: layer,
            from: Vector3(x: 8, y: -5, z: 0), to: Vector3(x: 8, y: 5, z: 0))
        let far = addLine(
            doc, layer: layer,
            from: Vector3(x: 12, y: -5, z: 0), to: Vector3(x: 12, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 4.5, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [near.handle, far.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .line(_, let end, _) = geom?.first else {
            return XCTFail("Expected extended line")
        }
        XCTAssertEqual(end.x, 8, accuracy: 1e-9)
    }

    func testExtendEdgeModeExtendsBoundary() {
        // Short boundary segment the +x ray never touches as built.
        let (doc, layer) = makeDoc()
        let target = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 0, z: 0), to: Vector3(x: 3, y: 0, z: 0))
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 5, y: 2, z: 0), to: Vector3(x: 5, y: 4, z: 0))
        let compiled = boundaries(doc, handles: [edge.handle]).excluding(target.handle)

        let (_, missed, noErr) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 2.5, y: 0, z: 0),
            boundaries: compiled, edgeMode: 0)
        XCTAssertNil(noErr)
        XCTAssertFalse(missed, "EDGEMODE=0 must not reach the short segment")

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 2.5, y: 0, z: 0),
            boundaries: compiled, edgeMode: 1)
        XCTAssertNil(err)
        XCTAssertTrue(modified, "EDGEMODE=1 extends the boundary line to meet")
        guard case .line(_, let end, _) = geom?.first else {
            return XCTFail("Expected extended line")
        }
        XCTAssertEqual(end.x, 5, accuracy: 1e-9)
        XCTAssertEqual(end.y, 0, accuracy: 1e-9)
    }

    func testExtendLineUnderTransform() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 5, y: 0, z: 0), color: nil)],
            transform: Transform3D.translated(by: Vector3(x: 100, y: 0, z: 0)))
        doc.addEntity(entity)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 108, y: -5, z: 0), to: Vector3(x: 108, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: entity, pickWorld: Vector3(x: 104.5, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(entity.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .line(_, let end, _) = geom?.first else {
            return XCTFail("Expected extended line")
        }
        XCTAssertEqual(end.x, 8, accuracy: 1e-9, "world 108 maps back to local 8")
    }

    func testExtendEntitySplicesNearestPrimitive() {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 2, y: 0, z: 0), color: nil),
                .arc(center: Vector3(x: 50, y: 50, z: 0), radius: 5,
                     startAngle: 0, endAngle: Double.pi, color: nil),
            ])
        doc.addEntity(entity)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 8, y: -5, z: 0), to: Vector3(x: 8, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: entity, pickWorld: Vector3(x: 1.9, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(entity.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        XCTAssertEqual(geom?.count, 2)
        guard case .line(_, let end, _) = geom?.first else {
            return XCTFail("Expected the line (nearest prim) extended")
        }
        XCTAssertEqual(end.x, 8, accuracy: 1e-9)
        guard case .arc = geom?.last else {
            return XCTFail("Expected the arc untouched")
        }
    }

    // MARK: - Engine: arc

    private func addArc(
        _ doc: CADDocument, layer: UUID,
        center: Vector3, radius: Double, startAngle: Double, endAngle: Double
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.arc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle, color: nil)])
        doc.addEntity(entity)
        return entity
    }

    func testExtendArcEndAlongCircle() {
        let (doc, layer) = makeDoc()
        let target = addArc(
            doc, layer: layer, center: .zero, radius: 5,
            startAngle: 0, endAngle: Double.pi / 2)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: -5, y: -5, z: 0), to: Vector3(x: -5, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 0.2, y: 4.8, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .arc(_, _, let startAngle, let endAngle, _) = geom?.first else {
            return XCTFail("Expected extended arc")
        }
        XCTAssertEqual(startAngle, 0, accuracy: 1e-12)
        XCTAssertEqual(endAngle, Double.pi, accuracy: 1e-9)
    }

    func testExtendArcStartBackward() {
        let (doc, layer) = makeDoc()
        let target = addArc(
            doc, layer: layer, center: .zero, radius: 5,
            startAngle: 0, endAngle: Double.pi / 2)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: -5, y: -5, z: 0), to: Vector3(x: 5, y: -5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 4.8, y: 0.2, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .arc(_, _, let startAngle, let endAngle, _) = geom?.first else {
            return XCTFail("Expected extended arc")
        }
        XCTAssertEqual(startAngle, -Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(endAngle, Double.pi / 2, accuracy: 1e-12)
    }

    // MARK: - Engine: open polyline

    private func addPolyline(
        _ doc: CADDocument, layer: UUID, points: [Vector3], isClosed: Bool = false
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(points: points, color: nil)])
        if isClosed, case .polyline(var path, let color) = entity.localGeometry?.first {
            path.isClosed = true
            var updated = entity
            updated.localGeometry = [.polyline(path: path, color: color)]
            doc.addEntity(updated)
            return updated
        }
        doc.addEntity(entity)
        return entity
    }

    func testExtendOpenPolylineLineSegment() {
        let (doc, layer) = makeDoc()
        let target = addPolyline(
            doc, layer: layer,
            points: [Vector3(x: 0, y: 0, z: 0),
                     Vector3(x: 5, y: 0, z: 0),
                     Vector3(x: 5, y: 5, z: 0)])
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: -5, y: 9, z: 0), to: Vector3(x: 15, y: 9, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 5, y: 4.5, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .polyline(let path, _) = geom?.first else {
            return XCTFail("Expected extended polyline")
        }
        XCTAssertFalse(path.isClosed)
        XCTAssertEqual(path.vertices.count, 3)
        XCTAssertEqual(path.vertices[2].position.x, 5, accuracy: 1e-9)
        XCTAssertEqual(path.vertices[2].position.y, 9, accuracy: 1e-9)
        XCTAssertEqual(path.vertices[0].position.x, 0, accuracy: 1e-12)
    }

    func testExtendOpenPolylineBulgeSegment() {
        let (doc, layer) = makeDoc()
        var path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)])
        path.vertices[0].bulge = 1.0
        let target = CADEntity(layerID: layer, localGeometry: [.polyline(path: path, color: nil)])
        doc.addEntity(target)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 0, y: 5, z: 0), to: Vector3(x: 10, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 9.5, y: -0.5, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .polyline(let extended, _) = geom?.first else {
            return XCTFail("Expected extended polyline")
        }
        XCTAssertEqual(extended.vertices.count, 2)
        XCTAssertEqual(extended.vertices[1].position.x, 5, accuracy: 1e-9)
        XCTAssertEqual(extended.vertices[1].position.y, 5, accuracy: 1e-9)
        XCTAssertEqual(extended.vertices[1].bulge, 0, accuracy: 1e-12)
        // The kept start vertex stays put; the longer sweep recomputes its bulge.
        XCTAssertEqual(
            extended.vertices[0].position.x, 0, accuracy: 1e-12)
        let expectedSweep = 1.5 * Double.pi
        XCTAssertEqual(
            tan(expectedSweep / 4.0), extended.vertices[0].bulge,
            accuracy: 1e-9)
    }

    // MARK: - Engine: spline

    private func addSpline(
        _ doc: CADDocument, layer: UUID,
        controlPoints: [Vector3], knots: [Double], degree: Int
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.spline(
                controlPoints: controlPoints, knots: knots, degree: degree,
                weights: nil, color: nil)])
        doc.addEntity(entity)
        return entity
    }

    func testExtendSplineEndTangentClean() {
        let (doc, layer) = makeDoc()
        let target = addSpline(
            doc, layer: layer,
            controlPoints: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            knots: [0, 0, 1, 1], degree: 1)
        let edge = addLine(
            doc, layer: layer,
            from: Vector3(x: 15, y: -5, z: 0), to: Vector3(x: 15, y: 5, z: 0))

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 9.5, y: 0, z: 0),
            boundaries: boundaries(doc, handles: [edge.handle]).excluding(target.handle),
            edgeMode: 0)

        XCTAssertNil(err)
        XCTAssertTrue(modified)
        guard case .spline(let cps, _, _, _, _) = geom?.first else {
            return XCTFail("Expected extended spline")
        }
        XCTAssertEqual(cps.count, 2)
        XCTAssertEqual(cps[1].x, 15, accuracy: 1e-9)
        XCTAssertEqual(cps[0].x, 0, accuracy: 1e-12)
    }

    func testExtendSplineNoCleanHit() {
        let (doc, layer) = makeDoc()
        let target = addSpline(
            doc, layer: layer,
            controlPoints: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            knots: [0, 0, 1, 1], degree: 1)

        let (geom, modified, err) = TrimGeometryEngine.extendEntity(
            entity: target, pickWorld: Vector3(x: 9.5, y: 0, z: 0),
            boundaries: .empty, edgeMode: 0)

        XCTAssertFalse(modified)
        XCTAssertNil(geom)
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("no clean"), "clear cannot-extend message, got: \(err!)")
    }

    // MARK: - Engine: rejections

    func testExtendClosedTargetsReportNoEnd() {
        let (doc, layer) = makeDoc()
        let closed = addPolyline(
            doc, layer: layer,
            points: [Vector3(x: 0, y: 0, z: 0),
                     Vector3(x: 5, y: 0, z: 0),
                     Vector3(x: 5, y: 5, z: 0)],
            isClosed: true)
        let circle = CADEntity(
            layerID: layer,
            localGeometry: [.circle(center: .zero, radius: 3, color: nil)])
        doc.addEntity(circle)

        for entity in [closed, circle] {
            let (_, modified, err) = TrimGeometryEngine.extendEntity(
                entity: entity, pickWorld: Vector3(x: 5, y: 0, z: 0),
                boundaries: .empty, edgeMode: 0)
            XCTAssertFalse(modified)
            XCTAssertNotNil(err)
            XCTAssertTrue(err!.contains("no end"), "closed message, got: \(err!)")
        }
    }

    func testExtendInvalidTargets() {
        let (doc, layer) = makeDoc()
        let ray = CADEntity(
            layerID: layer,
            localGeometry: [.ray(
                start: Vector3(x: 0, y: 0, z: 0),
                direction: Vector3(x: 1, y: 0, z: 0), color: nil)])
        doc.addEntity(ray)
        let text = CADEntity(
            layerID: layer,
            localGeometry: [.text(
                position: Vector3(x: 5, y: 0, z: 0), text: "Hi",
                height: 1, rotation: 0, style: nil,
                alignH: 0, alignV: 0, mtextWidth: nil, color: nil)])
        doc.addEntity(text)

        let (_, rayModified, rayErr) = TrimGeometryEngine.extendEntity(
            entity: ray, pickWorld: Vector3(x: 1, y: 0, z: 0),
            boundaries: .empty, edgeMode: 0)
        XCTAssertFalse(rayModified)
        XCTAssertNotNil(rayErr)
        XCTAssertTrue(rayErr!.contains("Ray"), "got: \(rayErr!)")

        let (_, textModified, textErr) = TrimGeometryEngine.extendEntity(
            entity: text, pickWorld: Vector3(x: 5, y: 0, z: 0),
            boundaries: .empty, edgeMode: 0)
        XCTAssertFalse(textModified)
        XCTAssertNotNil(textErr)
        XCTAssertTrue(textErr!.contains("Text"), "got: \(textErr!)")
    }

    // MARK: - Scripted (command "EXTEND" ...)

    func testScriptedExtendPick() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedTargetAndBoundary(host)
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(command \"EXTEND\" \"ALL\" \"\" '(4.5 0 0))",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2, "extend never creates entities")
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1, "one undo entry")
        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertTrue(xs.contains {
            abs($0.0.x) < 1e-9 && abs($0.1.x - 8) < 1e-9
        }, "target line runs 0 -> 8, got: \(xs)")
    }

    func testScriptedExtendFenceBatch() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedTargetAndBoundary(host)

        _ = try await eval(
            "(command \"EXTEND\" \"ALL\" \"\" \"_F\" '(4.9 -1 0) '(4.9 1 0) \"\")",
            host: host, env: &env)

        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertTrue(xs.contains {
            abs($0.0.x) < 1e-9 && abs($0.1.x - 8) < 1e-9
        }, "fence extends the crossed target, got: \(xs)")
    }

    func testScriptedExtendCrossing() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedTargetAndBoundary(host)

        _ = try await eval(
            "(command \"EXTEND\" \"ALL\" \"\" \"_C\" '(4 4 0) '(6 -4 0))",
            host: host, env: &env)

        let xs = host.document.allEntities.compactMap { lineEndpoints($0) }
        XCTAssertTrue(xs.contains {
            abs($0.0.x) < 1e-9 && abs($0.1.x - 8) < 1e-9
        }, "crossing extends the target, got: \(xs)")
    }

    func testScriptedExtendEdgeProjectValues() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedTargetAndBoundary(host)

        _ = try await eval(
            "(command \"EXTEND\" \"ALL\" \"\" \"_E\" 1 \"_P\" 2)",
            host: host, env: &env)

        let edge = await host.getSystemVar("EDGEMODE")
        XCTAssertEqual(edge, .int(1))
        let proj = await host.getSystemVar("PROJMODE")
        XCTAssertEqual(proj, .int(2))
        // No picks, no extends: no undo entry.
        XCTAssertEqual(host.document.entityCount, 2)
    }

    func testScriptedExtendFailClosed() async throws {
        // Unknown keyword rejects.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedTargetAndBoundary(host)
            _ = try await eval(
                "(command \"EXTEND\" \"ALL\" \"\" \"_Q\")",
                host: host, env: &env)
            XCTFail("unknown keyword must reject")
        } catch { }
        // Trailing garbage rejects.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedTargetAndBoundary(host)
            _ = try await eval(
                "(command \"EXTEND\" \"ALL\" \"\" '(4.5 0 0) \"EXTRA\")",
                host: host, env: &env)
            XCTFail("trailing input must reject")
        } catch { }
        // Pick near nothing rejects.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedTargetAndBoundary(host)
            _ = try await eval(
                "(command \"EXTEND\" \"ALL\" \"\" '(50 50 0))",
                host: host, env: &env)
            XCTFail("empty pick must reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("EXTEND"), "error names the command: \(error)")
        }
        // Pick near text-only content rejects (no extendable object).
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
                "(command \"EXTEND\" \"ALL\" \"\" '(5 0.1 0))",
                host: host, env: &env)
            XCTFail("text pick must reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("EXTEND"), "error names the command: \(error)")
        }
        // Bad EDGEMODE value fails closed.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedTargetAndBoundary(host)
            _ = try await eval(
                "(command \"EXTEND\" \"ALL\" \"\" \"_E\" 5)",
                host: host, env: &env)
            XCTFail("out-of-range EDGEMODE must reject")
        } catch { }
    }

    // MARK: - Registration surfaces

    func testExtendRegistrationSurfaces() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains {
                $0.canonicalName == "EXTEND" && $0.aliases.contains("EX")
            },
            "EXTEND descriptor with EX alias missing")
        XCTAssertTrue(
            CADCommandAliasTable.entries.contains {
                $0.canonicalName == "EXTEND" && $0.aliases.contains("EX")
                    && !$0.isReservedStub
            },
            "EXTEND alias-table row missing or still a stub")
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "EXTEND"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "EX"))
        XCTAssertNotNil(CADCommandAliasTable.entry(canonicalName: "EXTEND"))
        XCTAssertTrue(
            LispScriptedCommands.scripted.contains("EXTEND"),
            "EXTEND missing from the scripted set")
    }
}
