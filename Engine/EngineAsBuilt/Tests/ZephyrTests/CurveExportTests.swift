import XCTest
@testable import ZephyrCore

@MainActor
final class CurveExportTests: XCTestCase {

    private func analyticSpline() -> (
        controls: [Vector3], knots: [Double], weights: [Double]
    ) {
        (
            controls: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
                Vector3(x: 10, y: 10, z: 0),
                Vector3(x: 0, y: 10, z: 0),
            ],
            knots: [0, 0, 0, 0, 1, 1, 1, 1],
            weights: [1, 1, 1, 1])
    }

    private func splineDocument() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            name: "Curves",
            color: ColorRGBA(r: 255, g: 255, b: 255, a: 255))
        doc.importLayersBlocksEntities(
            layers: [layer], blocks: [], entities: [])
        let spline = analyticSpline()
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [CADPrimitive.spline(
                controlPoints: spline.controls,
                knots: spline.knots,
                degree: 3,
                weights: spline.weights,
                color: nil)],
            transform: .identity)
        doc.importLayersBlocksEntities(
            layers: [], blocks: [], entities: [entity])
        return doc
    }

    /// EAB is an analytic archive: the packed vertex array is a lossy
    /// preview cache, and the reader must restore control points, knots,
    /// and weights exactly rather than consuming tessellated vertices.
    func testEABSplineRoundtripPreservesAnalyticDefinition() throws {
        let doc = splineDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("curve_export_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: doc, to: url)

        let views = try EABReader.readViews(from: url)
        let readDoc = try XCTUnwrap(views.first).document
        let entities = readDoc.allEntities
        XCTAssertEqual(entities.count, 1)
        guard case let .spline(
            controls, knots, degree, weights, _
        ) = try XCTUnwrap(entities.first?.localGeometry?.first) else {
            XCTFail("Expected analytic spline after EAB round-trip")
            return
        }
        let expected = analyticSpline()
        XCTAssertEqual(degree, 3)
        XCTAssertEqual(knots, expected.knots)
        XCTAssertEqual(weights ?? [], expected.weights)
        XCTAssertEqual(controls.count, expected.controls.count)
        for (actual, want) in zip(controls, expected.controls) {
            XCTAssertEqual(actual.x, want.x)
            XCTAssertEqual(actual.y, want.y)
            XCTAssertEqual(actual.z, want.z)
        }
    }

    /// DXF export must emit the analytic SPLINE entity (control points,
    /// knots, weights), never a tessellated chord polyline.
    func testDXFSplineExportEmitsAnalyticSpline() throws {
        let doc = splineDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("curve_export_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: doc, to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("SPLINE"))
        XCTAssertTrue(content.contains("AcDbSpline"))
        XCTAssertTrue(content.contains(" 73\r\n4\r\n"))
        XCTAssertTrue(content.contains(" 72\r\n8\r\n"))
        // DXFWriter formats integral doubles with a ".0" suffix ("10.0").
        XCTAssertTrue(content.contains(" 10\r\n10.0\r\n"))
        // Scope the weight count to the SPLINE entity body: group 41
        // also appears in DXF tables/object sections elsewhere in the file.
        guard let splineStart = content.range(of: "100\r\nAcDbSpline\r\n") else {
            XCTFail("Missing AcDbSpline marker")
            return
        }
        let splineTail = content[splineStart.upperBound...]
        let splineBlock: Substring
        if let blockEnd = splineTail.range(of: "\r\n  0\r\n") {
            splineBlock = splineTail[..<blockEnd.lowerBound]
        } else {
            splineBlock = splineTail[...]
        }
        XCTAssertEqual(splineBlock.components(separatedBy: " 41\r\n1.0\r\n").count - 1, 4)
    }

    /// PDF export consumes tessellated bounds, but the tessellation must
    /// still span the exact analytic endpoints.
    func testPDFSplineBoundsSpanAnalyticEndpoints() throws {
        let spline = analyticSpline()
        let primitive = CADPrimitive.spline(
            controlPoints: spline.controls,
            knots: spline.knots,
            degree: 3,
            weights: spline.weights,
            color: nil)
        let bounds = try XCTUnwrap(PDFExporter.primsBounds([primitive]))
        let start = NURBSEvaluator.evaluateAt(
            degree: 3,
            knots: spline.knots,
            controlPoints: spline.controls,
            weights: spline.weights,
            at: spline.knots[3])
        let end = NURBSEvaluator.evaluateAt(
            degree: 3,
            knots: spline.knots,
            controlPoints: spline.controls,
            weights: spline.weights,
            at: spline.knots[spline.knots.count - 4])
        let first = try XCTUnwrap(start)
        let last = try XCTUnwrap(end)
        XCTAssertLessThanOrEqual(bounds.minX, min(first.x, last.x))
        XCTAssertGreaterThanOrEqual(bounds.maxX, max(first.x, last.x))
        XCTAssertLessThanOrEqual(bounds.minY, min(first.y, last.y))
        XCTAssertGreaterThanOrEqual(bounds.maxY, max(first.y, last.y))
    }
}
