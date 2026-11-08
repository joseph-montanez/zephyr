import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Fixture sweep: hand-authored DXF DIMENSION records (file convention,
/// Y-up, under Fixtures/) vs Lisp entmake (engine convention, Y-down) vs
/// re-export. Every fixture carries group 42 with the true measurement:
/// the importer honors it, Lisp takes it as authoritative, and the test
/// asserts both equal the hand-computed value plus full defpoint/type/
/// flags agreement — and that both directions survive export + re-import
/// (which exercises the Y-flip with non-zero Y throughout).
@MainActor
final class DimFixtureSweepTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
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

    private func metas(of doc: CADDocument) -> [CADDimensionMetadata] {
        doc.allEntities.compactMap { $0.dimensionMetadata?.value }
    }

    private func assertPoint(
        _ got: Vector3, _ want: Vector3, _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got.x, want.x, accuracy: 1e-9, "\(context).x", file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-9, "\(context).y", file: file, line: line)
        XCTAssertEqual(got.z, want.z, accuracy: 1e-9, "\(context).z", file: file, line: line)
    }

    private func assertOptionalPoint(
        _ got: Vector3?, _ want: Vector3?, _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got == nil, want == nil, "\(context) nilness", file: file, line: line)
        if let got, let want { assertPoint(got, want, context, file: file, line: line) }
    }

    /// - `strictTextRotation`: import-vs-entmake agreement demands nil on
    ///   both sides. Re-imports go through preservingCachedDimensionText,
    ///   which re-derives text rotation from the baked block text by
    ///   design, so round-trips exclude that one field.
    private func assertMetaEqual(
        _ got: CADDimensionMetadata, _ want: CADDimensionMetadata,
        strictTextRotation: Bool = true, strictTextMidpoint: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got.type, want.type, file: file, line: line)
        XCTAssertEqual(got.flags, want.flags, file: file, line: line)
        XCTAssertEqual(got.styleName, want.styleName, file: file, line: line)
        XCTAssertEqual(got.textOverride, want.textOverride, file: file, line: line)
        XCTAssertEqual(got.measurement, want.measurement, accuracy: 1e-9, file: file, line: line)
        assertPoint(got.defPoint, want.defPoint, "defPoint", file: file, line: line)
        assertPoint(got.defPoint2, want.defPoint2, "defPoint2", file: file, line: line)
        assertOptionalPoint(got.defPoint3, want.defPoint3, "defPoint3", file: file, line: line)
        assertOptionalPoint(got.defPoint4, want.defPoint4, "defPoint4", file: file, line: line)
        assertOptionalPoint(got.defPoint5, want.defPoint5, "defPoint5", file: file, line: line)
        // Radial regen moves the text outside the circle, so re-imports
        // re-derive the midpoint from baked geometry (same mechanism as
        // text rotation above); import-vs-entmake still demands exact 11.
        if strictTextMidpoint {
            assertPoint(got.textMidpoint, want.textMidpoint, "textMidpoint", file: file, line: line)
        }
        XCTAssertEqual(got.rotationAngle, want.rotationAngle, accuracy: 1e-9, file: file, line: line)
        if strictTextRotation {
            XCTAssertNil(got.textRotationAngle, file: file, line: line)
            XCTAssertNil(want.textRotationAngle, file: file, line: line)
        }
        XCTAssertNil(got.obliqueAngle, file: file, line: line)
        XCTAssertNil(want.obliqueAngle, file: file, line: line)
    }

    private func assertRoundTrip(
        doc: CADDocument, want: CADDimensionMetadata,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString).dxf")
        try DXFExporter.export(document: doc, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reimported = CADDocument()
        try reimported.importDXF(url: tmp)
        let found = metas(of: reimported)
        XCTAssertEqual(found.count, 1, file: file, line: line)
        assertMetaEqual(
            found[0], want,
            strictTextRotation: false, strictTextMidpoint: false,
            file: file, line: line)
    }

    /// One fixture end to end: import agrees with entmake(flipped), both
    /// equal the hand-computed measurement, both survive re-export.
    private func sweep(
        fixture: String, lisp: String,
        type: CADDimensionType, measurement: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let docA = CADDocument()
        try docA.importDXF(url: fixtureURL(fixture))
        let imported = metas(of: docA)
        XCTAssertEqual(imported.count, 1, fixture, file: file, line: line)
        let a = imported[0]
        XCTAssertEqual(a.type, type, fixture, file: file, line: line)
        XCTAssertEqual(a.measurement, measurement, accuracy: 1e-12, fixture, file: file, line: line)

        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(lisp, host: host, env: &env)
        let made = metas(of: host.document)
        XCTAssertEqual(made.count, 1, fixture, file: file, line: line)
        let b = made[0]
        XCTAssertEqual(b.measurement, measurement, accuracy: 1e-9, fixture, file: file, line: line)
        assertMetaEqual(b, a, file: file, line: line)

        try assertRoundTrip(doc: host.document, want: b, file: file, line: line)
        try assertRoundTrip(doc: docA, want: a, file: file, line: line)
    }

    // MARK: - Fixtures (Lisp coords are the Y-flip of the file coords)

    func testSweepLinear() async throws {
        try await sweep(
            fixture: "dim-linear.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 0) (10 1 -0.5 0) (11 3.5 -0.5 0) (13 1 -2 0) (14 6 -2 0) (42 . 5.0)))"#,
            type: .linearOrRotated, measurement: 5)
    }

    func testSweepLinearRotated() async throws {
        try await sweep(
            fixture: "dim-linear-rotated.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 0) (10 0 1 0) (11 2 1 0) (13 0 0 0) (14 4 0 0) (42 . 3.4641016151377544) (50 . -30)))"#,
            type: .linearOrRotated, measurement: 3.4641016151377544)
    }

    func testSweepAligned() async throws {
        try await sweep(
            fixture: "dim-aligned.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 1) (10 1 0 0) (11 2.5 -2.5 0) (13 1 -1 0) (14 4 -5 0) (42 . 5.0)))"#,
            type: .aligned, measurement: 5)
    }

    func testSweepAngular() async throws {
        try await sweep(
            fixture: "dim-angular.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 2) (10 4.5 -3.5 0) (11 4 -4 0) (13 4 -2 0) (14 6 -2 0) (15 2 -2 0) (16 2 -5 0) (42 . 1.5707963267948966)))"#,
            type: .angular, measurement: 1.5707963267948966)
    }

    func testSweepAngular3Point() async throws {
        try await sweep(
            fixture: "dim-angular3point.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 5) (10 3.5 -3.5 0) (11 4 -4 0) (13 5 0 0) (14 0 -5 0) (15 0 0 0) (42 . 1.5707963267948966)))"#,
            type: .angular3Point, measurement: 1.5707963267948966)
    }

    func testSweepDiameter() async throws {
        try await sweep(
            fixture: "dim-diameter.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 3) (10 1 -1 0) (11 3 -2.5 0) (15 5 -4 0) (42 . 5.0)))"#,
            type: .diameter, measurement: 5)
    }

    func testSweepRadius() async throws {
        try await sweep(
            fixture: "dim-radius.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 4) (10 1 -4 0) (11 1 -2.5 0) (15 1 -1 0) (42 . 3.0)))"#,
            type: .radius, measurement: 3)
    }

    func testSweepOrdinateY() async throws {
        try await sweep(
            fixture: "dim-ordinate-y.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 6) (10 3 -8 0) (11 5 -9 0) (13 5 -9 0) (14 6 -9 0) (42 . 8.0)))"#,
            type: .ordinate, measurement: 8)
    }

    func testSweepOrdinateX() async throws {
        try await sweep(
            fixture: "dim-ordinate-x.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 70) (10 7 -2 0) (11 9 -4 0) (13 9 -4 0) (14 10 -4 0) (42 . 7.0)))"#,
            type: .ordinate, measurement: 7)
    }

    func testSweepArcLength() async throws {
        try await sweep(
            fixture: "dim-arclength.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 8) (10 3 -3 0) (11 3.5 -3.5 0) (13 4 0 0) (14 0 -4 0) (15 0 0 0) (16 4.5 -4.5 0) (42 . 6.283185307179586)))"#,
            type: .arcLength, measurement: 6.283185307179586)
    }

    func testSweepLinearTextOverride() async throws {
        try await sweep(
            fixture: "dim-linear-text.dxf",
            lisp: #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 0) (1 . "W-102") (10 11 -0.5 0) (11 13.5 -0.5 0) (13 11 -2 0) (14 16 -2 0) (42 . 5.0)))"#,
            type: .linearOrRotated, measurement: 5)
    }

    // MARK: - Jogged (no file encoding: degrade path only)

    func testSweepJoggedDegradesToRadius() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "DIMENSION") (3 . "Standard") (70 . 4) (10 5 -4 0) (15 1 -1 0) (12 3 -2 0)))"#,
            host: host, env: &env)
        let made = metas(of: host.document)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].type, .jogged)
        XCTAssertEqual(made[0].measurement, 5, accuracy: 1e-9)
        assertPoint(made[0].defPoint, Vector3(x: 1, y: -1, z: 0), "jog center")
        assertPoint(made[0].defPoint2, Vector3(x: 5, y: -4, z: 0), "jog arc")
        // Export degrades to radius; re-import restores an equivalent radius.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-jog-\(UUID().uuidString).dxf")
        try DXFExporter.export(document: host.document, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reimported = CADDocument()
        try reimported.importDXF(url: tmp)
        let found = metas(of: reimported)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].type, .radius)
        XCTAssertEqual(found[0].measurement, 5, accuracy: 1e-9)
        assertPoint(found[0].defPoint, Vector3(x: 1, y: -1, z: 0), "center")
        assertPoint(found[0].defPoint2, Vector3(x: 5, y: -4, z: 0), "arc")
    }
}
