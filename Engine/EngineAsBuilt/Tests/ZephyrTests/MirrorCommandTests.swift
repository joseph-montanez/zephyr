import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// PR1 MIRROR (alias MI): reflection across a user mirror line.
///
/// Covers the reflection matrix (axis variants + coincident rejection), the
/// erase Yes/No paths (single undo entry, reselect semantics), MIRRTEXT 0/1
/// (readable text/attributes vs true mirror), block copy sharing/cloning,
/// locked-layer refusal, viewport-projected skips, typed-point parsing, the
/// scripted `(command "MIRROR" ...)` runner, registration surfaces, and a
/// DXF export/reimport round-trip of a mirrored block + text + bulged
/// polyline.
@MainActor
final class MirrorCommandTests: XCTestCase {

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

    @discardableResult
    private func addText(
        _ doc: CADDocument, layer: UUID,
        position: Vector3, rotation: Double,
        transform: Transform3D = .identity
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.text(
                position: position, text: "Hi", height: 2.5, rotation: rotation,
                style: nil, alignH: 0, alignV: 0, mtextWidth: nil, color: nil)],
            transform: transform)
        doc.addEntity(entity)
        return entity
    }

    /// Mirror across the Y axis (x -> -x).
    private func mirrorY() -> Transform3D {
        CADGeometryMath.mirrorTransform(
            p1: Vector3(x: 0, y: -5, z: 0),
            p2: Vector3(x: 0, y: 5, z: 0))!
    }

    private func worldDirection(
        of entity: CADEntity, rotation: Double, at point: Vector3
    ) -> Vector3 {
        CADGeometryMath.worldDirection(
            ofLocalAngle: rotation, at: point, under: entity.transform)
    }

    // MARK: - Reflection matrix

    func testMirrorTransformAxisVariants() {
        let acrossY = CADGeometryMath.mirrorTransform(
            p1: Vector3(x: 0, y: -5, z: 0), p2: Vector3(x: 0, y: 5, z: 0))!
        XCTAssertTrue(acrossY.reversesOrientation2D)
        var mapped = acrossY.transformPoint(Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(mapped.x, -3, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 4, accuracy: 1e-12)

        let acrossX = CADGeometryMath.mirrorTransform(
            p1: Vector3(x: -5, y: 0, z: 0), p2: Vector3(x: 5, y: 0, z: 0))!
        XCTAssertTrue(acrossX.reversesOrientation2D)
        mapped = acrossX.transformPoint(Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(mapped.x, 3, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, -4, accuracy: 1e-12)

        let diagonal = CADGeometryMath.mirrorTransform(
            p1: Vector3(x: 0, y: 0, z: 0), p2: Vector3(x: 1, y: 1, z: 0))!
        XCTAssertTrue(diagonal.reversesOrientation2D)
        mapped = diagonal.transformPoint(Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(mapped.x, 4, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 3, accuracy: 1e-12)

        // Offset mirror line x = 5.
        let offset = CADGeometryMath.mirrorTransform(
            p1: Vector3(x: 5, y: -5, z: 0), p2: Vector3(x: 5, y: 5, z: 0))!
        mapped = offset.transformPoint(Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(mapped.x, 7, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 4, accuracy: 1e-12)
    }

    func testMirrorTransformCoincidentReturnsNil() {
        XCTAssertNil(CADGeometryMath.mirrorTransform(
            p1: Vector3(x: 1, y: 1, z: 0), p2: Vector3(x: 1, y: 1, z: 0)))
        XCTAssertNil(CADGeometryMath.mirrorTransform(
            p1: .zero, p2: Vector3(x: 1e-12, y: 0, z: 0)))
    }

    // MARK: - Erase Yes / No

    func testMirrorEraseYesMirrorsInPlace() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 2, z: 0), to: Vector3(x: 5, y: 6, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.mirrorEntities(
            handles: [entity.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        XCTAssertTrue(outcome.newHandles.isEmpty)
        XCTAssertEqual(doc.entityCount, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        let stored = doc.entity(for: entity.handle)!
        var mapped = stored.transform.transformPoint(Vector3(x: 1, y: 2, z: 0))
        XCTAssertEqual(mapped.x, -1, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 2, accuracy: 1e-12)
        mapped = stored.transform.transformPoint(Vector3(x: 5, y: 6, z: 0))
        XCTAssertEqual(mapped.x, -5, accuracy: 1e-12)

        doc.undo()
        XCTAssertEqual(
            doc.entity(for: entity.handle)?.transform, Transform3D.identity)
    }

    func testMirrorEraseNoKeepsSources() {
        let (doc, layer) = makeDoc()
        let entity = addLine(
            doc, layer: layer,
            from: Vector3(x: 1, y: 2, z: 0), to: Vector3(x: 5, y: 6, z: 0))
        let depth = doc.undoManager.undoDepth

        let outcome = doc.mirrorEntities(
            handles: [entity.handle], mirror: mirrorY(),
            eraseSource: false, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        XCTAssertEqual(outcome.newHandles.count, 1)
        XCTAssertEqual(doc.entityCount, 2)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "one undo entry")
        // Source untouched.
        XCTAssertEqual(
            doc.entity(for: entity.handle)?.transform, Transform3D.identity)
        // Copy reflected.
        let copy = doc.entity(for: outcome.newHandles[0])!
        XCTAssertEqual(copy.localGeometry, entity.localGeometry)
        let mapped = copy.transform.transformPoint(Vector3(x: 1, y: 2, z: 0))
        XCTAssertEqual(mapped.x, -1, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 2, accuracy: 1e-12)

        doc.undo()
        XCTAssertEqual(doc.entityCount, 1)
        XCTAssertNil(doc.entity(for: outcome.newHandles[0]))
    }

    // MARK: - Readable text and attributes (MIRRTEXT)

    func testMirrTextZeroKeepsTextReadable() {
        let (doc, layer) = makeDoc()
        let entity = addText(
            doc, layer: layer,
            position: Vector3(x: 5, y: 5, z: 0), rotation: 0.5)

        let outcome = doc.mirrorEntities(
            handles: [entity.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 0)

        XCTAssertEqual(outcome.mirrored, 1)
        let stored = doc.entity(for: entity.handle)!
        guard case .text(let pos, _, _, let rotation, _, _, _, _, _) =
                stored.localGeometry?.first else {
            return XCTFail("expected a text primitive")
        }
        // Insertion mirrors through the transform ...
        let worldPos = stored.transform.transformPoint(pos)
        XCTAssertEqual(worldPos.x, -5, accuracy: 1e-12)
        XCTAssertEqual(worldPos.y, 5, accuracy: 1e-12)
        // ... while the world direction is preserved (readable).
        let world = worldDirection(of: stored, rotation: rotation, at: pos)
        XCTAssertEqual(world.x, cos(0.5), accuracy: 1e-9)
        XCTAssertEqual(world.y, sin(0.5), accuracy: 1e-9)
        // Across the Y axis that means a negated local rotation.
        XCTAssertEqual(rotation, .pi - 0.5, accuracy: 1e-9)
    }

    func testMirrTextOneMirrorsText() {
        let (doc, layer) = makeDoc()
        let entity = addText(
            doc, layer: layer,
            position: Vector3(x: 5, y: 5, z: 0), rotation: 0.5)

        let outcome = doc.mirrorEntities(
            handles: [entity.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        let stored = doc.entity(for: entity.handle)!
        guard case .text(let pos, _, _, let rotation, _, _, _, _, _) =
                stored.localGeometry?.first else {
            return XCTFail("expected a text primitive")
        }
        // True mirror: local rotation untouched, world direction reflected.
        XCTAssertEqual(rotation, 0.5, accuracy: 1e-12)
        let world = worldDirection(of: stored, rotation: rotation, at: pos)
        XCTAssertEqual(world.x, -cos(0.5), accuracy: 1e-9)
        XCTAssertEqual(world.y, sin(0.5), accuracy: 1e-9)
    }

    func testMirrTextZeroKeepsAttributesReadable() {
        let (doc, layer) = makeDoc()
        let block = CADBlock(
            handle: UUID(), name: "TAGBLK",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 2, y: 0, z: 0), color: nil)],
            attributeDefinitions: [CADAttributeDefinition(
                tag: "NOTE", position: Vector3(x: 1, y: 0, z: 0),
                height: 1, rotation: 0.25)])
        doc.addBlock(block)
        var insert = CADEntity(
            layerID: layer, blockID: block.handle, transform: .identity)
        insert.attributeValues = ["NOTE": CADAttributeValue(value: "A")]
        doc.addEntity(insert)

        let outcome = doc.mirrorEntities(
            handles: [insert.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 0)

        XCTAssertEqual(outcome.mirrored, 1)
        let stored = doc.entity(for: insert.handle)!
        XCTAssertEqual(stored.attributeValues["NOTE"]?.value, "A")
        let readable = stored.attributeValues["NOTE"]?.rotation ?? -999
        XCTAssertEqual(readable, .pi - 0.25, accuracy: 1e-9)
    }

    func testMirrTextOneMirrorsAttributes() {
        let (doc, layer) = makeDoc()
        let block = CADBlock(
            handle: UUID(), name: "TAGBLK1",
            geometry: [],
            attributeDefinitions: [CADAttributeDefinition(
                tag: "NOTE", position: Vector3(x: 1, y: 0, z: 0),
                height: 1, rotation: 0.25)])
        doc.addBlock(block)
        var insert = CADEntity(
            layerID: layer, blockID: block.handle, transform: .identity)
        insert.attributeValues = [
            "NOTE": CADAttributeValue(value: "A", rotation: 0.25)]
        doc.addEntity(insert)

        let outcome = doc.mirrorEntities(
            handles: [insert.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        let stored = doc.entity(for: insert.handle)!
        // True mirror: the explicit override is left alone ...
        XCTAssertEqual(
            stored.attributeValues["NOTE"]?.rotation ?? -999, 0.25,
            accuracy: 1e-12)
        // ... so the world direction reflects.
        let world = CADGeometryMath.worldDirection(
            ofLocalAngle: 0.25, at: Vector3(x: 1, y: 0, z: 0),
            under: stored.transform)
        XCTAssertEqual(world.x, -cos(0.25), accuracy: 1e-9)
        XCTAssertEqual(world.y, sin(0.25), accuracy: 1e-9)
    }

    // MARK: - Block copies

    func testMirrorCopySharesNamedBlock() {
        let (doc, layer) = makeDoc()
        let block = CADBlock(
            handle: UUID(), name: "CHAIR",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 3, y: 1, z: 0), color: nil)])
        doc.addBlock(block)
        var transform = Transform3D()
        transform.position = Vector3(x: 2, y: 3, z: 0)
        let insert = CADEntity(
            layerID: layer, blockID: block.handle, transform: transform)
        doc.addEntity(insert)
        let blockCount = doc.allBlocks.count

        let outcome = doc.mirrorEntities(
            handles: [insert.handle], mirror: mirrorY(),
            eraseSource: false, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        XCTAssertEqual(doc.allBlocks.count, blockCount, "named block shared")
        let copy = doc.entity(for: outcome.newHandles[0])!
        XCTAssertEqual(copy.blockID, block.handle)
        let mapped = copy.transform.transformPoint(.zero)
        XCTAssertEqual(mapped.x, -2, accuracy: 1e-12)
        XCTAssertEqual(mapped.y, 3, accuracy: 1e-12)
        XCTAssertTrue(copy.transform.reversesOrientation2D)
        XCTAssertEqual(
            doc.entity(for: insert.handle)?.transform.transformPoint(.zero),
            Vector3(x: 2, y: 3, z: 0))
    }

    func testMirrorCopyClonesAnonymousBlock() {
        let (doc, layer) = makeDoc()
        let anon = CADBlock(
            handle: UUID(), name: "*D1",
            geometry: [.circle(
                center: Vector3(x: 1, y: 1, z: 0), radius: 2, color: nil)])
        doc.addBlock(anon)
        let insert = CADEntity(
            layerID: layer, blockID: anon.handle, transform: .identity)
        doc.addEntity(insert)

        let outcome = doc.mirrorEntities(
            handles: [insert.handle], mirror: mirrorY(),
            eraseSource: false, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        let copy = doc.entity(for: outcome.newHandles[0])!
        XCTAssertNotEqual(copy.blockID, anon.handle)
        let clone = doc.block(for: copy.blockID!)!
        XCTAssertEqual(clone.name, "*D1")
        XCTAssertEqual(clone.geometry, anon.geometry)
    }

    // MARK: - Guards: locked layers and viewport copies

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

        let outcome = doc.mirrorEntities(
            handles: [locked.handle, free.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 1)
        XCTAssertEqual(outcome.lockedSkipped, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1, "one undo entry")
        XCTAssertEqual(
            doc.entity(for: locked.handle)?.transform, Transform3D.identity)
        let mapped = doc.entity(for: free.handle)!.transform
            .transformPoint(Vector3(x: 3, y: 0, z: 0))
        XCTAssertEqual(mapped.x, -3, accuracy: 1e-12)
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

        let outcome = doc.mirrorEntities(
            handles: [projected.handle], mirror: mirrorY(),
            eraseSource: true, mirrText: 1)

        XCTAssertEqual(outcome.mirrored, 0)
        XCTAssertEqual(outcome.projectedSkipped, 1)
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "no undo pushed")
        XCTAssertEqual(
            doc.entity(for: projected.handle)?.transform, Transform3D.identity)
    }

    // MARK: - Typed points

    func testParseTypedPointForms() {
        XCTAssertEqual(
            MirrorCommand.parseTypedPoint("10,20", base: .zero),
            Vector3(x: 10, y: 20, z: 0))
        XCTAssertEqual(
            MirrorCommand.parseTypedPoint("10,20,5", base: .zero),
            Vector3(x: 10, y: 20, z: 0))
        XCTAssertEqual(
            MirrorCommand.parseTypedPoint(
                "@3,4", base: Vector3(x: 1, y: 1, z: 0)),
            Vector3(x: 4, y: 5, z: 0))
        let polar = MirrorCommand.parseTypedPoint(
            "5<0", base: Vector3(x: 1, y: 1, z: 0))!
        XCTAssertEqual(polar.x, 6, accuracy: 1e-9)
        XCTAssertEqual(polar.y, 1, accuracy: 1e-9)
        XCTAssertNil(MirrorCommand.parseTypedPoint("abc", base: .zero))
        XCTAssertNil(MirrorCommand.parseTypedPoint("", base: .zero))
    }


    // MARK: - Scripted (command "MIRROR" ...)

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

    private func seedScriptLine(_ host: LispCADHost) {
        let layer = host.document.findLayer(named: "0")!.handle
        host.document.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: 1, y: 0, z: 0),
                end: Vector3(x: 3, y: 0, z: 0), color: nil)]))
    }

    func testScriptedMirrorCopyDefaultNo() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedScriptLine(host)
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"_N\")",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        let xs = host.document.allEntities.map {
            $0.transform.transformPoint(Vector3(x: 1, y: 0, z: 0)).x
        }
        XCTAssertTrue(xs.contains { abs($0 - 1) < 1e-9 }, "source kept")
        XCTAssertTrue(xs.contains { abs($0 + 1) < 1e-9 }, "copy mirrored")
    }

    func testScriptedMirrorBareEnterDefaultsNo() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedScriptLine(host)

        _ = try await eval(
            "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"\")",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 2, "bare Enter keeps sources")
    }

    func testScriptedMirrorEraseYes() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedScriptLine(host)
        let depth = host.document.undoManager.undoDepth

        _ = try await eval(
            "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"_Y\")",
            host: host, env: &env)

        XCTAssertEqual(host.document.entityCount, 1)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        let only = host.document.allEntities.first!
        let mapped = only.transform.transformPoint(Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(mapped.x, -1, accuracy: 1e-12)
    }

    func testScriptedMirrorReadsMirrText() async throws {
        for (setting, expectReadable) in [(0, true), (1, false)] {
            let host = makeHost()
            var env = LispEnvironment()
            let layer = host.document.findLayer(named: "0")!.handle
            host.document.addEntity(CADEntity(
                layerID: layer,
                localGeometry: [.text(
                    position: Vector3(x: 5, y: 5, z: 0), text: "Hi",
                    height: 2.5, rotation: 0.5, style: nil,
                    alignH: 0, alignV: 0, mtextWidth: nil, color: nil)]))
            _ = try await eval("(setvar \"MIRRTEXT\" \(setting))", host: host, env: &env)
            _ = try await eval(
                "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"_Y\")",
                host: host, env: &env)

            let stored = host.document.allEntities.first!
            guard case .text(_, _, _, let rotation, _, _, _, _, _) =
                    stored.localGeometry?.first else {
                XCTFail("expected text")
                continue
            }
            if expectReadable {
                XCTAssertEqual(rotation, .pi - 0.5, accuracy: 1e-9)
            } else {
                XCTAssertEqual(rotation, 0.5, accuracy: 1e-12)
            }
        }
    }

    func testScriptedMirrorFailClosed() async throws {
        // Unknown erase keyword.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedScriptLine(host)
            _ = try await eval(
                "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"_Q\")",
                host: host, env: &env)
            XCTFail("unknown keyword must reject")
        } catch { }
        // Coincident mirror points.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedScriptLine(host)
            _ = try await eval(
                "(command \"MIRROR\" \"ALL\" \"\" '(1 1 0) '(1 1 0) \"_N\")",
                host: host, env: &env)
            XCTFail("coincident points must reject")
        } catch { }
        // Missing erase answer.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedScriptLine(host)
            _ = try await eval(
                "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0))",
                host: host, env: &env)
            XCTFail("missing erase answer must reject")
        } catch { }
        // Trailing garbage.
        do {
            let host = makeHost()
            var env = LispEnvironment()
            seedScriptLine(host)
            _ = try await eval(
                "(command \"MIRROR\" \"ALL\" \"\" '(0 -5 0) '(0 5 0) \"_N\" \"EXTRA\")",
                host: host, env: &env)
            XCTFail("trailing input must reject")
        } catch { }
    }

    // MARK: - Registration surfaces

    func testMirrorRegistrationSurfaces() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains {
                $0.canonicalName == "MIRROR" && $0.aliases.contains("MI")
            },
            "MIRROR descriptor with MI alias missing")
        XCTAssertTrue(
            CADCommandAliasTable.entries.contains {
                $0.canonicalName == "MIRROR" && $0.aliases.contains("MI")
            },
            "MIRROR alias-table row missing")
        XCTAssertNotNil(
            CADCommandAliasTable.entry(canonicalName: "MIRROR"))
    }

    // MARK: - DXF export/reimport round-trip

    func testDXFRoundTripMirroredBlockTextPolyline() throws {
        let (doc, layer) = makeDoc()
        // Named block with asymmetric content, inserted off-axis.
        let block = CADBlock(
            handle: UUID(), name: "MIRBLK",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 3, y: 1, z: 0), color: nil)])
        doc.addBlock(block)
        var placement = Transform3D()
        placement.position = Vector3(x: 2, y: 3, z: 0)
        doc.addEntity(CADEntity(
            layerID: layer, blockID: block.handle, transform: placement))
        // Text with a non-axis rotation, true-mirrored.
        doc.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.text(
                position: Vector3(x: 5, y: 5, z: 0), text: "Hi",
                height: 2.5, rotation: 0.3, style: nil,
                alignH: 0, alignV: 0, mtextWidth: nil, color: nil)]))
        // Bulged polyline.
        doc.addEntity(CADEntity(
            layerID: layer,
            localGeometry: [.polyline(path: CADPolyline(vertices: [
                CADPolylineVertex(
                    position: Vector3(x: 0, y: 0, z: 0),
                    bulge: 1.0, startWidth: 0, endWidth: 0),
                CADPolylineVertex(
                    position: Vector3(x: 4, y: 0, z: 0),
                    bulge: 0.0, startWidth: 0, endWidth: 0),
            ]), color: nil)]))

        let outcome = doc.mirrorEntities(
            handles: Set(doc.allEntities.map(\.handle)),
            mirror: mirrorY(), eraseSource: true, mirrText: 1)
        XCTAssertEqual(outcome.mirrored, 3)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirror-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFWriterBridge.export(document: doc, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let restored = CADDocument()
        restored.importLayersBlocksEntities(
            layers: reimported.layers, blocks: reimported.blocks,
            entities: reimported.entities)

        XCTAssertEqual(restored.entityCount, 3)
        XCTAssertTrue(restored.allBlocks.contains { $0.name == "MIRBLK" })

        // The mirrored insert keeps its mirror across the round-trip.
        let inserts = restored.allEntities.filter { $0.blockID != nil }
        XCTAssertEqual(inserts.count, 1)
        let insert = inserts[0]
        XCTAssertEqual(restored.block(for: insert.blockID!)?.name, "MIRBLK")
        XCTAssertTrue(
            insert.transform.reversesOrientation2D,
            "mirrored insert must stay orientation-reversing")
        let origin = insert.transform.transformPoint(.zero)
        XCTAssertEqual(origin.x, -2, accuracy: 1e-6)
        XCTAssertEqual(origin.y, 3, accuracy: 1e-6)

        // Text: world position and world direction survive.
        let texts = restored.allEntities.compactMap { entity -> (Vector3, Double)? in
            guard case .text(let pos, _, _, let rotation, _, _, _, _, _) =
                    entity.localGeometry?.first else { return nil }
            let worldPos = entity.transform.transformPoint(pos)
            let dir = CADGeometryMath.worldDirection(
                ofLocalAngle: rotation, at: pos, under: entity.transform)
            return (worldPos, atan2(dir.y, dir.x))
        }
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts[0].0.x, -5, accuracy: 1e-6)
        XCTAssertEqual(texts[0].0.y, 5, accuracy: 1e-6)
        XCTAssertEqual(texts[0].1, .pi - 0.3, accuracy: 1e-6)

        // Bulged polyline: mirrored world points and flipped bulge survive.
        let paths = restored.allEntities.compactMap { entity -> CADPolyline? in
            guard case .polyline(let path, _) =
                    entity.localGeometry?.first else { return nil }
            var moved = path
            moved.vertices = path.vertices.map { vertex in
                var vertex = vertex
                vertex.position = entity.transform.transformPoint(vertex.position)
                return vertex
            }
            return moved
        }
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0].vertices.count, 2)
        XCTAssertEqual(paths[0].vertices[0].position.x, 0, accuracy: 1e-6)
        XCTAssertEqual(paths[0].vertices[0].position.y, 0, accuracy: 1e-6)
        XCTAssertEqual(paths[0].vertices[1].position.x, -4, accuracy: 1e-6)
        XCTAssertEqual(paths[0].vertices[1].position.y, 0, accuracy: 1e-6)
        XCTAssertEqual(paths[0].vertices[0].bulge, -1.0, accuracy: 1e-9)
    }
}
