import XCTest
@testable import ZephyrCore

/// PR1 (PEDIT plan): Fit/Spline curve state on the polyline model and its
/// preservation through every IO path.
///
/// Covers: `legacyCurveType` flag mapping, legacy-POLYLINE import (smoothing
/// flags, vertex-kind flags, tangent group 50, LtGen bit 0x80), DXF text
/// export round-trip (legacy POLYLINE for curved paths, LWPOLYLINE otherwise),
/// EAB v25 round-trip, `simplifyIfNeeded` immunity for fitted paths, and
/// tangent rotation under `transformed(by:)`.
@MainActor
final class PeditCurveStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return (doc, doc.findLayer(named: "0")!.handle)
    }

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedit_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    private func firstPolyline(in doc: CADDocument) throws -> CADPolyline {
        let entity = try XCTUnwrap(doc.allEntities.first)
        guard case .polyline(let path, _) = try XCTUnwrap(entity.localGeometry).first else {
            throw XCTSkip("expected polyline geometry")
        }
        return path
    }

    /// Minimal legacy POLYLINE DXF with caller-chosen header flags, group 75,
    /// and per-vertex (bulge, flags, tangentDegrees) triples.
    private func legacyPolylineDXF(
        headerFlags: Int, group75: Int,
        vertices: [(bulge: Double, flags: Int, tangentDegrees: Double?)]
    ) -> String {
        var dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        POLYLINE
          8
        0
         66
        1
         10
        0.0
         20
        0.0
         30
        0.0
         70
        \(headerFlags)
         75
        \(group75)
        """
        for (index, vertex) in vertices.enumerated() {
            dxf += """
            
              0
            VERTEX
              8
            0
             10
            \(Double(index) * 10.0)
             20
            0.0
             30
            0.0
             42
            \(vertex.bulge)
             70
            \(vertex.flags)
            """
            if let tangent = vertex.tangentDegrees {
                dxf += """
                
                 50
                \(tangent)
                """
            }
        }
        dxf += """
        
          0
        SEQEND
          0
        ENDSEC
          0
        EOF
        """
        return dxf
    }

    // MARK: - Flag mapping

    func testLegacyCurveTypeMapping() {
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 0, group75: 0), .none)
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 1, group75: 0), .none)
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 3, group75: 0), .fit)
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 5, group75: 6), .splineCubic)
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 5, group75: 5), .splineQuadratic)
        // Spline-fit flag with no group 75 defaults to cubic.
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 4, group75: 0), .splineCubic)
        // LtGen bit never affects the curve type.
        XCTAssertEqual(DXFEntityConverter.legacyCurveType(flags: 128 | 2, group75: 0), .fit)
    }

    // MARK: - Import

    func testImportCurveFitPolylinePreservesState() throws {
        // flags 1|2|128: closed + curve-fit + LtGen.
        let doc = try importDXFString(legacyPolylineDXF(
            headerFlags: 131, group75: 0,
            vertices: [
                (bulge: 0.0, flags: 2, tangentDegrees: 45.0),
                (bulge: 0.5, flags: 0, tangentDegrees: nil),
                (bulge: 0.0, flags: 1, tangentDegrees: nil),
            ]))
        let path = try firstPolyline(in: doc)
        XCTAssertTrue(path.isClosed)
        XCTAssertTrue(path.lineTypeGenerationEnabled)
        XCTAssertEqual(path.curveType, .fit)
        XCTAssertEqual(path.vertices.count, 3)
        XCTAssertNil(path.vertices[1].tangent)
        XCTAssertEqual(path.vertices[1].bulge, -0.5, accuracy: 1e-12)
        // File orientation is y-up degrees; internal matches arc angles.
        XCTAssertEqual(path.vertices[0].tangent ?? 0, -.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(path.vertices[2].kind, .curveFitGenerated)
    }

    func testImportSplineFitPolylineQuadraticAndCubic() throws {
        // flags 1|4|128: closed + spline-fit + LtGen, group 75 = 5.
        let quad = try importDXFString(legacyPolylineDXF(
            headerFlags: 133, group75: 5,
            vertices: [
                (bulge: 0.0, flags: 16, tangentDegrees: nil),
                (bulge: 0.0, flags: 8, tangentDegrees: nil),
            ]))
        let quadPath = try firstPolyline(in: quad)
        XCTAssertEqual(quadPath.curveType, .splineQuadratic)
        XCTAssertTrue(quadPath.lineTypeGenerationEnabled)
        XCTAssertEqual(quadPath.vertices[0].kind, .splineFrame)
        XCTAssertEqual(quadPath.vertices[1].kind, .splineGenerated)

        let cubic = try importDXFString(legacyPolylineDXF(
            headerFlags: 5, group75: 6,
            vertices: [
                (bulge: 0.0, flags: 16, tangentDegrees: nil),
                // 8 (spline-generated) + 2 (tangent defined).
                (bulge: 0.0, flags: 10, tangentDegrees: 30.0),
            ]))
        let cubicPath = try firstPolyline(in: cubic)
        XCTAssertEqual(cubicPath.curveType, .splineCubic)
        XCTAssertEqual(cubicPath.vertices[1].tangent ?? 0, -.pi / 6, accuracy: 1e-12)
    }

    func testImportPlainPolylineStaysPlain() throws {
        let doc = try importDXFString(legacyPolylineDXF(
            headerFlags: 1, group75: 0,
            vertices: [
                (bulge: 0.0, flags: 0, tangentDegrees: nil),
                (bulge: 0.0, flags: 0, tangentDegrees: nil),
            ]))
        let path = try firstPolyline(in: doc)
        XCTAssertEqual(path.curveType, .none)
        XCTAssertFalse(path.lineTypeGenerationEnabled)
        XCTAssertTrue(path.vertices.allSatisfy { $0.kind == .normal && $0.tangent == nil })
    }

    func testSimplifyLeavesFittedPathsAlone() throws {
        // 201+ vertices would trigger simplifyPolylines; the fit flag must win.
        let many = (0..<210).map { _ in (bulge: 0.0, flags: 0, tangentDegrees: nil as Double?) }
        let doc = try importDXFString(legacyPolylineDXF(
            headerFlags: 2, group75: 0, vertices: many))
        let path = try firstPolyline(in: doc)
        XCTAssertEqual(path.curveType, .fit)
        XCTAssertEqual(path.vertices.count, 210)
    }

    // MARK: - DXF text export round-trip

    func testFittedPathExportsAsLegacyPolylineAndRoundTrips() throws {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0),
                                                  tangent: .pi / 4),
                CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0),
                                                  bulge: 0.5),
                CADPolylineVertex(position: Vector3(x: 10, y: 10, z: 0),
                                                  kind: .curveFitGenerated),
            ],
            isClosed: true,
            lineTypeGenerationEnabled: true,
            curveType: .fit)
        doc.addEntity(CADEntity(layerID: layer, localGeometry: [.polyline(path: path, color: nil)]))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedit_fit_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains("  0\r\nPOLYLINE\r\n"))
        XCTAssertTrue(text.contains(" 75\r\n0\r\n"))

        let reimported = CADDocument()
        try reimported.importDXF(url: outURL)
        let roundTripped = try firstPolyline(in: reimported)
        XCTAssertEqual(roundTripped.curveType, .fit)
        XCTAssertTrue(roundTripped.isClosed)
        XCTAssertTrue(roundTripped.lineTypeGenerationEnabled)
        XCTAssertEqual(roundTripped.vertices.count, 3)
        XCTAssertEqual(roundTripped.vertices[0].tangent ?? 0, .pi / 4, accuracy: 1e-9)
        XCTAssertEqual(roundTripped.vertices[1].bulge, 0.5, accuracy: 1e-9)
        XCTAssertEqual(roundTripped.vertices[2].kind, .curveFitGenerated)
    }

    func testSplineQuadraticExportsGroup75Five() throws {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0), kind: .splineFrame),
                CADPolylineVertex(position: Vector3(x: 10, y: 0, z: 0), kind: .splineGenerated),
            ],
            curveType: .splineQuadratic)
        doc.addEntity(CADEntity(layerID: layer, localGeometry: [.polyline(path: path, color: nil)]))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedit_spl_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains(" 75\r\n5\r\n"))

        let reimported = CADDocument()
        try reimported.importDXF(url: outURL)
        let roundTripped = try firstPolyline(in: reimported)
        XCTAssertEqual(roundTripped.curveType, .splineQuadratic)
        XCTAssertEqual(roundTripped.vertices[0].kind, .splineFrame)
        XCTAssertEqual(roundTripped.vertices[1].kind, .splineGenerated)
    }

    func testPlainPathStillExportsAsLwPolyline() throws {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 5, y: 5, z: 0)])
        doc.addEntity(CADEntity(layerID: layer, localGeometry: [.polyline(path: path, color: nil)]))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedit_plain_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)
        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains("LWPOLYLINE"))
        XCTAssertFalse(text.contains("  0\r\nPOLYLINE\r\n"))
    }

    // MARK: - EAB round-trip

    func testEABRoundTripsCurveState() throws {
        let (doc, layer) = makeDoc()
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(position: Vector3(x: 1, y: 2, z: 0),
                                                  bulge: 0.25, tangent: -.pi / 3),
                CADPolylineVertex(position: Vector3(x: 4, y: 2, z: 0),
                                                  kind: .splineGenerated),
            ],
            isClosed: false,
            lineTypeGenerationEnabled: true,
            curveType: .splineCubic)
        doc.addEntity(CADEntity(layerID: layer, localGeometry: [.polyline(path: path, color: nil)]))

        let eabURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pedit_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: eabURL) }
        try EABWriter.write(document: doc, to: eabURL)
        let readDoc = try XCTUnwrap(EABReader.readViews(from: eabURL).first).document
        let roundTripped = try firstPolyline(in: readDoc)
        XCTAssertEqual(roundTripped.curveType, .splineCubic)
        XCTAssertTrue(roundTripped.lineTypeGenerationEnabled)
        XCTAssertEqual(roundTripped.vertices[0].bulge, 0.25, accuracy: 1e-12)
        XCTAssertEqual(roundTripped.vertices[0].tangent ?? 0, -.pi / 3, accuracy: 1e-12)
        XCTAssertEqual(roundTripped.vertices[1].kind, .splineGenerated)
    }

    // MARK: - Tangent transforms

    func testTangentRotatesWithTransform() {
        let path = CADPolyline(
            vertices: [CADPolylineVertex(position: Vector3(x: 1, y: 0, z: 0), tangent: 0)])
        var rotation = Transform3D.identity
        rotation.rotation = .pi / 2
        let rotated = path.transformed(by: rotation)
        XCTAssertEqual(rotated.vertices[0].tangent ?? 0, .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(rotated.curveType, .none)

        var mirror = Transform3D.identity
        mirror.scale = Vector3(x: -1, y: 1, z: 1)
        let mirrored = path.transformed(by: mirror)
        XCTAssertEqual(abs(mirrored.vertices[0].tangent ?? 0), .pi, accuracy: 1e-12)
    }
}
