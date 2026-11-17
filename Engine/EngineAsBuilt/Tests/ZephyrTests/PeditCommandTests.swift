import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Scripted `(command "PEDIT" ...)` runners (PR6) plus registration
/// surfaces: descriptor parity for PEDIT/PE, no reserved stub, alias-table
/// entry. Interactive shell states are exercised through the engine (see
/// PeditGeometryEngineTests); these tests pin the scripted contract.
@MainActor
final class PeditCommandTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return (doc, doc.findLayer(named: "0")!.handle)
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

    @discardableResult
    private func seedPolyline(
        _ host: LispCADHost, points: [Vector3], isClosed: Bool = false
    ) -> CADEntity {
        let layer = host.document.findLayer(named: "0")!.handle
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(
                path: CADPolyline(points: points, isClosed: isClosed),
                color: nil)])
        host.document.addEntity(entity)
        // Direct adds bypass command creation tracking; pin lastCreated so
        // entlast resolves deterministically (UUID-sorted fallback otherwise).
        host.lastCreated = entity.handle
        return entity
    }

    @discardableResult
    private func seedLine(
        _ host: LispCADHost, from: Vector3, to: Vector3
    ) -> CADEntity {
        let layer = host.document.findLayer(named: "0")!.handle
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.line(start: from, end: to, color: nil)])
        host.document.addEntity(entity)
        host.lastCreated = entity.handle
        return entity
    }

    private func polylinePath(of entity: CADEntity) -> CADPolyline? {
        guard case .polyline(let path, _)? = entity.localGeometry?.first else { return nil }
        return path
    }

    // MARK: - Scripted options

    func testScriptedCloseOpen() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0)])
        let depth = host.document.undoManager.undoDepth

        _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"C\" \"\")", host: host, env: &env)
        XCTAssertTrue(polylinePath(of: host.document.allEntities[0])?.isClosed ?? false)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)

        _ = try await eval("(command \"PEDIT\" E \"O\" \"\")", host: host, env: &env)
        XCTAssertFalse(polylinePath(of: host.document.allEntities[0])?.isClosed ?? true)
    }

    func testScriptedWidthTaperReverse() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0), Vector3(x: 10, y: 10, z: 0)])

        _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"W\" 2.5 \"\")", host: host, env: &env)
        let widened = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertTrue(widened.vertices.allSatisfy { $0.startWidth == 2.5 && $0.endWidth == 2.5 })

        _ = try await eval("(command \"PEDIT\" E \"T\" 0 4 \"\")", host: host, env: &env)
        let tapered = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(tapered.vertices.map(\.startWidth), [0, 2, 4])

        _ = try await eval("(command \"PEDIT\" E \"R\" \"\")", host: host, env: &env)
        let reversed = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(reversed.points, [Vector3(x: 10, y: 10, z: 0), Vector3(x: 10, y: 0, z: 0), .zero])
    }

    func testScriptedFitSplineDecurveRoundTrip() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [
            .zero, Vector3(x: 10, y: 5, z: 0),
            Vector3(x: 20, y: 0, z: 0), Vector3(x: 30, y: 5, z: 0)])

        _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"F\" \"\")", host: host, env: &env)
        let fitted = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(fitted.curveType, .fit)
        XCTAssertGreaterThan(fitted.vertices.count, 4)

        _ = try await eval("(command \"PEDIT\" E \"D\" \"\")", host: host, env: &env)
        let decurved = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(decurved.curveType, .none)
        XCTAssertEqual(decurved.vertices.count, 4)

        _ = try await eval("(command \"PEDIT\" E \"S\" \"\")", host: host, env: &env)
        XCTAssertEqual(polylinePath(of: host.document.allEntities[0])?.curveType, .splineCubic)

        _ = try await eval("(command \"PEDIT\" E \"D\" \"\")", host: host, env: &env)
        _ = try await eval("(setvar \"SPLINETYPE\" 5)", host: host, env: &env)
        _ = try await eval("(command \"PEDIT\" E \"S\" \"\")", host: host, env: &env)
        XCTAssertEqual(polylinePath(of: host.document.allEntities[0])?.curveType, .splineQuadratic)

        _ = try await eval("(command \"PEDIT\" E \"D\" \"\")", host: host, env: &env)
        XCTAssertEqual(try XCTUnwrap(polylinePath(of: host.document.allEntities[0])).curveType, .none)
    }

    func testScriptedLineConversionNeedsPeditAccept() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedLine(host, from: .zero, to: Vector3(x: 10, y: 0, z: 0))

        do {
            _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"C\" \"\")", host: host, env: &env)
            XCTFail("expected a PEDITACCEPT throw")
        } catch {
            XCTAssertTrue("\(error)".contains("PEDITACCEPT"), "error names PEDITACCEPT: \(error)")
        }
        XCTAssertEqual(host.document.entityCount, 1)

        _ = try await eval("(setvar \"PEDITACCEPT\" 1)", host: host, env: &env)
        _ = try await eval("(command \"PEDIT\" E \"C\" \"\")", host: host, env: &env)
        let converted = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertTrue(converted.isClosed)
        XCTAssertEqual(converted.vertices.count, 2)
    }

    func testScriptedLinetypeToggle() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0)])

        _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"LT\" \"ON\" \"\")", host: host, env: &env)
        XCTAssertTrue(polylinePath(of: host.document.allEntities[0])?.lineTypeGenerationEnabled ?? false)
        _ = try await eval("(command \"PEDIT\" E \"LT\" \"\")", host: host, env: &env)
        XCTAssertFalse(polylinePath(of: host.document.allEntities[0])?.lineTypeGenerationEnabled ?? true)
    }

    func testScriptedJoinChain() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedLine(host, from: Vector3(x: 10, y: 0, z: 0), to: Vector3(x: 20, y: 0, z: 0))
        _ = try await eval("(setq L (entlast)) (setvar \"PEDITACCEPT\" 1)", host: host, env: &env)
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0)])
        let depth = host.document.undoManager.undoDepth

        _ = try await eval("(setq E (entlast)) (command \"PEDIT\" E \"J\" L \"\")", host: host, env: &env)
        XCTAssertEqual(host.document.entityCount, 1)
        XCTAssertEqual(host.document.undoManager.undoDepth, depth + 1)
        let joined = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(joined.vertices.map(\.position.x), [0, 10, 20])
    }

    func testScriptedJoinTwoPolylines() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0)])
        _ = try await eval("(setq E (entlast))", host: host, env: &env)
        seedPolyline(host, points: [Vector3(x: 10, y: 0, z: 0), Vector3(x: 20, y: 0, z: 0)])
        _ = try await eval("(setq L (entlast))", host: host, env: &env)

        _ = try await eval("(command \"PEDIT\" E \"J\" L \"\")", host: host, env: &env)
        XCTAssertEqual(host.document.entityCount, 1)
        let joined = try XCTUnwrap(polylinePath(of: host.document.allEntities[0]))
        XCTAssertEqual(joined.vertices.map(\.position.x), [0, 10, 20])
    }

    func testScriptedJoinMissThrows() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        seedPolyline(host, points: [.zero, Vector3(x: 10, y: 0, z: 0)])
        _ = try await eval("(setq E (entlast))", host: host, env: &env)
        seedLine(host, from: Vector3(x: 50, y: 0, z: 0), to: Vector3(x: 60, y: 0, z: 0))
        _ = try await eval("(setq L (entlast)) (setvar \"PEDITACCEPT\" 1)", host: host, env: &env)

        do {
            _ = try await eval("(command \"PEDIT\" E \"J\" L \"\")", host: host, env: &env)
            XCTFail("expected a no-chain throw")
        } catch {
            XCTAssertTrue("\(error)".contains("continuous chain"), "error names the miss: \(error)")
        }
        XCTAssertEqual(host.document.entityCount, 2)
    }

    // MARK: - Registration

    func testPeditRegistrationSurfaces() {
        XCTAssertNotNil(CADCommandAliasTable.entry(canonicalName: "PEDIT"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "PEDIT"))
        XCTAssertNil(CADCommandAliasTable.stubMessage(for: "PE"))
        XCTAssertTrue(CommandDescriptor.allCommands.contains {
            $0.canonicalName == "PEDIT" && $0.aliases.contains("PE")
        })
    }
}
