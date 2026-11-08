import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Headless native-dimension tests: entmake DIMENSION for every
/// CADDimensionType, DIMSTYLE table read + creation, and the eight
/// scripted dimension commands. No engine, no window, no GPU.
@MainActor
final class LispDimensionTests: XCTestCase {

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

    private func assoc(_ code: Int, _ list: LispValue) -> LispValue? {
        guard let items = list.properList else { return nil }
        for item in items {
            if case let .cons(head, tail) = item,
               case let .int(c) = head, c == code
            {
                return tail
            }
        }
        return nil
    }

    private func dimensionMetas(_ host: LispCADHost) -> [CADDimensionMetadata] {
        host.document.allEntities.compactMap { $0.dimensionMetadata?.value }
    }

    // MARK: - entmake DIMENSION

    func testEntmakeLinearDimension() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let made = try await eval(
            #"(entmake '((0 . "DIMENSION") (8 . "0") (3 . "Standard") (70 . 0) (10 0 -1 0) (11 6 -1 0) (13 0 0 0) (14 12 0 0)))"#,
            host: host, env: &env)
        guard case .entityName = made else {
            return XCTFail("expected entity name, got \(made)")
        }
        XCTAssertEqual(host.document.allEntities.count, 1)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].type, .linearOrRotated)
        XCTAssertEqual(metas[0].measurement, 12, accuracy: 1e-9)
        XCTAssertEqual(metas[0].styleName, "Standard")
        // The baked block exists alongside the reference entity.
        XCTAssertEqual(host.document.allBlocks.count, 1)
    }

    func testEntmakeAllDimensionTypes() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        // Group-70 values mirror the importer's reading (file value 8 =
        // arcLength). Jogged has no group-70 code: radius groups plus a
        // group-12 jog point select it. Text mid (11) omitted throughout
        // to cover per-type defaults.
        let sources: [(String, CADDimensionType)] = [
            ("(entmake '((0 . \"DIMENSION\") (70 . 0) (10 0 -1 0) (13 0 0 0) (14 5 0 0)))",
             .linearOrRotated),
            ("(entmake '((0 . \"DIMENSION\") (70 . 1) (10 0 -1 0) (13 0 0 0) (14 3 4 0)))",
             .aligned),
            ("(entmake '((0 . \"DIMENSION\") (70 . 2) (10 5 5 0) (14 9 0 0) (16 0 9 0) (15 0 0 0)))",
             .angular),
            ("(entmake '((0 . \"DIMENSION\") (70 . 5) (10 5 5 0) (13 9 0 0) (14 0 9 0) (15 0 0 0)))",
             .angular3Point),
            ("(entmake '((0 . \"DIMENSION\") (70 . 3) (10 0 0 0) (15 4 0 0)))",
             .diameter),
            ("(entmake '((0 . \"DIMENSION\") (70 . 4) (10 3 0 0) (15 0 0 0)))",
             .radius),
            ("(entmake '((0 . \"DIMENSION\") (70 . 6) (10 7 8 0) (13 9 8 0)))",
             .ordinate),
            ("(entmake '((0 . \"DIMENSION\") (70 . 8) (10 0 5 0) (13 5 0 0) (14 0 5 0) (15 0 0 0)))",
             .arcLength),
            ("(entmake '((0 . \"DIMENSION\") (70 . 4) (10 3 0 0) (15 0 0 0) (12 2 1 0) (11 4 2 0)))",
             .jogged),
        ]
        for (index, (source, _)) in sources.enumerated() {
            let made = try await eval(source, host: host, env: &env)
            guard case .entityName = made else {
                return XCTFail("case \(index): expected entity name, got \(made)")
            }
        }
        // allEntities is registry-backed (unordered): compare type sets,
        // and look measurements up by type.
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, sources.count)
        XCTAssertEqual(
            Set(metas.map(\.type)),
            Set(sources.map(\.1)))
        func measurement(of type: CADDimensionType) -> Double? {
            metas.first { $0.type == type }?.measurement
        }
        XCTAssertEqual(measurement(of: .linearOrRotated) ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(measurement(of: .diameter) ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(measurement(of: .radius) ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(measurement(of: .ordinate) ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(measurement(of: .jogged) ?? -1, 3, accuracy: 1e-9)
    }

    func testEntmakeDimensionFailures() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        // Missing required groups name the group.
        do {
            _ = try await eval(
                #"(entmake '((0 . "DIMENSION") (70 . 0) (10 0 0 0)))"#,
                host: host, env: &env)
            XCTFail("missing groups should fail")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("13"), "names group: \(error)")
        }
        // Bad dimtype fails.
        do {
            _ = try await eval(
                #"(entmake '((0 . "DIMENSION") (70 . 9) (10 0 0 0)))"#,
                host: host, env: &env)
            XCTFail("bad dimtype should fail")
        } catch {
            // Any error is correct.
        }
        XCTAssertEqual(host.document.allEntities.count, 0)
    }

    func testEntmakeDimensionExtrusionOrientsText() async throws {
        // Extrusion (1,0,0): OCS x -> engine +Y, OCS y -> engine +Z.
        // Defpoints stay WCS (as-given); explicit group 11 is mapped.
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "DIMENSION") (70 . 0) (10 0 0 0) (13 0 0 0) (14 4 0 0) (11 2 3 0) (210 1 0 0) (42 . 4.0)))"#,
            host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].defPoint2.x, 0, accuracy: 1e-12)
        XCTAssertEqual(metas[0].defPoint2.y, 0, accuracy: 1e-12)
        let text = metas[0].textMidpoint
        XCTAssertEqual(text.x, 0, accuracy: 1e-9)
        XCTAssertEqual(text.y, 2, accuracy: 1e-9)
        XCTAssertEqual(text.z, 3, accuracy: 1e-9)
        XCTAssertEqual(metas[0].measurement, 4, accuracy: 1e-12)
    }

    func testEntmakeDimensionZeroExtrusionIsDefault() async throws {
        // Zero extrusion defaults to +Z (mirrors import leniency): text
        // stays as-given.
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "DIMENSION") (70 . 0) (10 0 0 0) (13 0 0 0) (14 4 0 0) (11 2 3 0) (210 0 0 0) (42 . 4.0)))"#,
            host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        let text = metas[0].textMidpoint
        XCTAssertEqual(text.x, 2, accuracy: 1e-12)
        XCTAssertEqual(text.y, 3, accuracy: 1e-12)
        XCTAssertEqual(text.z, 0, accuracy: 1e-12)
    }

    func testEntmakeDimensionTextOverrideAndMeasurement() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "DIMENSION") (70 . 0) (10 0 -1 0) (13 0 0 0) (14 5 0 0) (1 . "WALL") (42 . 5.0)))"#,
            host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].textOverride, "WALL")
        XCTAssertEqual(metas[0].measurement, 5.0, accuracy: 1e-12)
    }

    // MARK: - DIMSTYLE table

    func testTblsearchDimstyleStandard() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let found = try await eval(
            #"(tblsearch "DIMSTYLE" "Standard")"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, found), .string("DIMSTYLE"))
        if case let .string(styleName) = assoc(2, found) {
            XCTAssertEqual(styleName.uppercased(), "STANDARD")
        } else {
            XCTFail("missing group 2")
        }
        XCTAssertNotNil(assoc(40, found)?.asDouble) // overall scale
        XCTAssertNotNil(assoc(140, found)?.asDouble) // text height
        // Missing style is nil, not a throw.
        let missing = try await eval(
            #"(tblsearch "DIMSTYLE" "Nope")"#, host: host, env: &env)
        XCTAssertEqual(missing, .nilValue)
    }

    func testEntmakeDimstyleCreateAndFind() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let made = try await eval(
            #"(entmake '((0 . "DIMSTYLE") (2 . "Plan-1-50") (40 . 50.0) (140 . 2.5) (271 . 1)))"#,
            host: host, env: &env)
        XCTAssertEqual(made, .string("Plan-1-50"))
        let found = try await eval(
            #"(tblsearch "DIMSTYLE" "plan-1-50")"#, host: host, env: &env)
        XCTAssertEqual(assoc(40, found)?.asDouble, 50.0)
        XCTAssertEqual(assoc(140, found)?.asDouble, 2.5)
        XCTAssertEqual(assoc(271, found), .int(1))
        // Unknown groups fail closed.
        do {
            _ = try await eval(
                #"(entmake '((0 . "DIMSTYLE") (2 . "Bad") (999 . 1)))"#,
                host: host, env: &env)
            XCTFail("unknown groups should fail")
        } catch {
            // Any error is correct.
        }
    }

    // MARK: - Scripted dimension commands

    func testScriptedDimLinear() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "DIMLINEAR" '(0 0 0) '(12 0 0) '(6 -1 0))"#,
            host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].type, .linearOrRotated)
        XCTAssertEqual(metas[0].measurement, 12, accuracy: 1e-9)
        // Alias works too.
        _ = try await eval(
            #"(command "DLI" '(0 9 0) '(12 9 0))"#, host: host, env: &env)
        XCTAssertEqual(dimensionMetas(host).count, 2)
    }

    func testScriptedAllDimensionCommands() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval("(command \"DAL\" '(0 0 0) '(3 4 0))", host: host, env: &env)
        _ = try await eval(
            "(command \"DAN\" '(0 0 0) '(9 0 0) '(0 9 0))", host: host, env: &env)
        _ = try await eval(
            "(command \"DDI\" '(0 0 0) '(4 0 0))", host: host, env: &env)
        _ = try await eval(
            "(command \"DRA\" '(0 0 0) '(3 0 0))", host: host, env: &env)
        _ = try await eval(
            "(command \"DAR\" '(0 0 0) '(5 0 0) '(0 5 0))", host: host, env: &env)
        _ = try await eval("(command \"DOR\" '(7 8 0))", host: host, env: &env)
        _ = try await eval("(command \"DJO\" '(0 0 0) '(3 0 0))", host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 7)
        let types = Set(metas.map(\.type))
        XCTAssertEqual(types, [.aligned, .angular, .diameter, .radius,
                               .arcLength, .ordinate, .jogged])
    }

    func testScriptedDimOrdinateXType() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval("(command \"DIMORDINATE\" '(7 8 0) \"X\")",
                           host: host, env: &env)
        let metas = dimensionMetas(host)
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].measurement, 7, accuracy: 1e-9)
        XCTAssertNotEqual(metas[0].flags & 64, 0)
    }

    // MARK: - DXF export round-trip

    func testDimensionExportsAsDimensionRecords() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            "(entmake '((0 . \"DIMENSION\") (70 . 0) (10 0 -1 0) (13 0 0 0) (14 5 0 0)))",
            host: host, env: &env)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dim-\(UUID().uuidString).dxf")
        try DXFExporter.export(document: host.document, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.contains("DIMENSION"))
        XCTAssertTrue(text.contains("DIMSTYLE"))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDimensionExportImportRoundTrip() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            "(entmake '((0 . \"DIMENSION\") (70 . 0) (10 0 -1 0) (13 0 0 0) (14 5 0 0)))",
            host: host, env: &env)
        // Radius exercises the per-type group mapping (center on 15).
        _ = try await eval(
            "(entmake '((0 . \"DIMENSION\") (70 . 4) (10 3 0 0) (15 0 0 0)))",
            host: host, env: &env)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dim-rt-\(UUID().uuidString).dxf")
        try DXFExporter.export(document: host.document, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reimported = CADDocument()
        try reimported.importDXF(url: tmp)
        let metas = reimported.allEntities.compactMap {
            $0.dimensionMetadata?.value
        }
        XCTAssertEqual(metas.count, 2)
        let types = Set(metas.map(\.type))
        XCTAssertEqual(types, [.linearOrRotated, .radius])
        for meta in metas {
            switch meta.type {
            case .linearOrRotated:
                XCTAssertEqual(meta.measurement, 5, accuracy: 1e-9)
            case .radius:
                XCTAssertEqual(meta.measurement, 3, accuracy: 1e-9)
            default:
                XCTFail("unexpected re-imported type \(meta.type)")
            }
        }
    }
}
