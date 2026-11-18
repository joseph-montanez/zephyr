import XCTest
@testable import ZephyrCore
import ZephyrKernel

/// Steps 3-5: MASSPROP math (exact rect, circle, holes, UCS invariance,
/// coplanar partition), BOUNDARY Region output, HATCH loop acceptance,
/// DXF REGION skip + export round-trip.
@MainActor
final class RegionMassTests: XCTestCase {

    // MARK: - Helpers

    private func rectLoop(
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, z: Double = 0
    ) -> CADPolyline {
        CADPolyline(
            points: [
                Vector3(x: x0, y: y0, z: z),
                Vector3(x: x1, y: y0, z: z),
                Vector3(x: x1, y: y1, z: z),
                Vector3(x: x0, y: y1, z: z),
            ],
            isClosed: true)
    }

    private func circleLoop(_ cx: Double, _ cy: Double, _ r: Double) -> CADPolyline {
        CADPolyline(
            vertices: [
                CADPolylineVertex(
                    position: Vector3(x: cx + r, y: cy, z: 0), bulge: 1.0),
                CADPolylineVertex(
                    position: Vector3(x: cx - r, y: cy, z: 0), bulge: 1.0),
            ],
            isClosed: true)
    }

    private func solid(
        _ outer: CADPolyline, holes: [CADPolyline] = [],
        z: Double = 0
    ) -> BooleanSolid {
        let shift: (CADPolyline) -> CADPolyline = { path in
            guard z != 0 else { return path }
            var copy = path
            copy.vertices = path.vertices.map { v in
                var vertex = v
                vertex.position.z = z
                return vertex
            }
            return copy
        }
        return BooleanSolid(
            outer: shift(outer), holes: holes.map(shift),
            layerID: UUID(), sourceHandles: [UUID()])
    }

    private func regionEntity(
        _ layer: UUID, outer: CADPolyline, holes: [CADPolyline] = []
    ) -> CADEntity {
        var prims: [CADPrimitive] = [.polyline(path: outer, color: nil)]
        for hole in holes {
            prims.append(.polyline(path: hole, color: nil))
        }
        var entity = CADEntity(
            layerID: layer, localGeometry: prims, transform: .identity)
        entity.xdata[CADRegion.markerKey] = .bool(true)
        return entity
    }

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layer.handle)
    }

    // MARK: - Exact rect moments (10x4 at WCS origin)

    func testRectMomentsExactAboutOrigin() {
        // 10 wide (x) by 4 tall (y), corner at origin.
        let report = RegionMass.analyze(
            solids: [solid(rectLoop(0, 0, 10, 4))],
            ucs: .identity)
        XCTAssertEqual(report.area, 40.0, accuracy: 1e-9)
        XCTAssertEqual(report.perimeter, 28.0, accuracy: 1e-9)
        XCTAssertEqual(report.centroid.x, 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.centroid.y, 2.0, accuracy: 1e-9)
        // Ix = b*h^3/3 about the X axis through the origin edge.
        XCTAssertEqual(report.ixx, 10.0 * 64.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(report.iyy, 4.0 * 1000.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(report.ixy, 50.0 * 8.0, accuracy: 1e-6)
        // Centroidal: bh^3/12, hb^3/12, zero product.
        XCTAssertEqual(report.ixc, 10.0 * 64.0 / 12.0, accuracy: 1e-6)
        XCTAssertEqual(report.iyc, 4.0 * 1000.0 / 12.0, accuracy: 1e-6)
        XCTAssertEqual(report.pxyc, 0.0, accuracy: 1e-6)
        XCTAssertEqual(report.rxx, sqrt(report.ixx / 40.0), accuracy: 1e-9)
    }

    func testTallRectPrincipalAxes() {
        // 4 wide by 10 tall: stiffer about X, principal angle 0.
        let report = RegionMass.analyze(
            solids: [solid(rectLoop(0, 0, 4, 10))],
            ucs: .identity)
        XCTAssertEqual(report.area, 40.0, accuracy: 1e-9)
        XCTAssertEqual(report.ixc, 4.0 * 1000.0 / 12.0, accuracy: 1e-6)
        XCTAssertEqual(report.iyc, 10.0 * 64.0 / 12.0, accuracy: 1e-6)
        XCTAssertEqual(report.princI, report.ixc, accuracy: 1e-6)
        XCTAssertEqual(report.princJ, report.iyc, accuracy: 1e-6)
        XCTAssertEqual(report.princAngle, 0.0, accuracy: 1e-9)
    }

    // MARK: - Circle + holes

    func testCircleMomentsApproximate() {
        let report = RegionMass.analyze(
            solids: [solid(circleLoop(0, 0, 10))],
            ucs: .identity)
        let exact = Double.pi * pow(10.0, 4) / 4.0
        XCTAssertEqual(report.area, Double.pi * 100.0, accuracy: 0.5)
        XCTAssertEqual(report.ixx, exact, accuracy: 8.0)
        XCTAssertEqual(report.iyy, exact, accuracy: 8.0)
        XCTAssertEqual(report.ixy, 0.0, accuracy: 8.0)
        XCTAssertEqual(report.princI, report.princJ, accuracy: 8.0)
    }

    func testHoledRectNetValues() {
        let report = RegionMass.analyze(
            solids: [solid(rectLoop(0, 0, 10, 4), holes: [circleLoop(5, 2, 1)])],
            ucs: .identity)
        XCTAssertEqual(report.area, 40.0 - Double.pi, accuracy: 0.05)
        XCTAssertEqual(
            report.perimeter, 28.0 + 2.0 * Double.pi, accuracy: 0.05)
        XCTAssertEqual(report.centroid.x, 5.0, accuracy: 0.02)
        XCTAssertEqual(report.centroid.y, 2.0, accuracy: 0.02)
        XCTAssertLessThan(report.ixx, 10.0 * 64.0 / 3.0)
    }

    // MARK: - UCS invariance

    func testUCSRotationSwapsIxIy() {
        let rect = solid(rectLoop(0, 0, 10, 4))
        let plain = RegionMass.analyze(solids: [rect], ucs: .identity)
        let rotated = RegionMass.analyze(
            solids: [rect],
            ucs: UCSDefinition(origin: Point3d(x: 0, y: 0, z: 0), angle: .pi / 2))
        XCTAssertEqual(rotated.area, plain.area, accuracy: 1e-9)
        // x' = y, y' = -x: Ix' = Iy, Iy' = Ix.
        XCTAssertEqual(rotated.ixx, plain.iyy, accuracy: 1e-6)
        XCTAssertEqual(rotated.iyy, plain.ixx, accuracy: 1e-6)
        XCTAssertEqual(rotated.centroid.x, 2.0, accuracy: 1e-9)
        XCTAssertEqual(rotated.centroid.y, -5.0, accuracy: 1e-9)
    }

    func testUCSOriginAtCentroidGivesCentroidal() {
        let rect = solid(rectLoop(0, 0, 10, 4))
        let plain = RegionMass.analyze(solids: [rect], ucs: .identity)
        let atCentroid = RegionMass.analyze(
            solids: [rect],
            ucs: UCSDefinition(origin: Point3d(x: 5, y: 2, z: 0)))
        XCTAssertEqual(atCentroid.ixx, plain.ixc, accuracy: 1e-6)
        XCTAssertEqual(atCentroid.iyy, plain.iyc, accuracy: 1e-6)
        XCTAssertEqual(atCentroid.ixy, plain.pxyc, accuracy: 1e-6)
        XCTAssertEqual(atCentroid.centroid.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(atCentroid.centroid.y, 0.0, accuracy: 1e-9)
    }

    // MARK: - Coplanar partition (LT multi-region rule)

    func testPartitionCoplanarKeepsFirstPlane() {
        let (kept, skipped) = RegionMass.partitionCoplanar([
            solid(rectLoop(0, 0, 10, 4, z: 0)),
            solid(rectLoop(20, 0, 24, 2, z: 0)),
            solid(rectLoop(0, 0, 5, 5, z: 1)),
        ])
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(skipped, 1)
    }

    // MARK: - Step 4: BOUNDARY Region output

    func testBoundaryMakeEntityRegionAndPolyline() {
        let layer = UUID()
        let loop = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 4, z: 0), Vector3(x: 0, y: 4, z: 0),
        ]
        let region = BoundaryCommand.makeEntity(
            loop: loop, asRegion: true, layerID: layer)
        XCTAssertTrue(CADRegion.isRegionEntity(region))
        XCTAssertEqual(InquiryMath.typeName(of: region), "REGION")

        let plain = BoundaryCommand.makeEntity(
            loop: loop, asRegion: false, layerID: layer)
        XCTAssertFalse(CADRegion.isRegionEntity(plain))
        XCTAssertEqual(InquiryMath.typeName(of: plain), "LWPOLYLINE")
    }

    func testBoundaryMakeEntityRejectsFigureEight() {
        let loop = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 2, y: 2, z: 0),
            Vector3(x: 2, y: 0, z: 0), Vector3(x: 0, y: 2, z: 0),
        ]
        let entity = BoundaryCommand.makeEntity(
            loop: loop, asRegion: true, layerID: UUID())
        // Self-intersecting: falls back to a plain polyline, never a
        // silently invalid region.
        XCTAssertFalse(CADRegion.isRegionEntity(entity))
    }

    // MARK: - Step 4: HATCH accepts region loops

    func testHatchReadsRegionOuterLoop() {
        let (_, layer) = makeDoc()
        let entity = regionEntity(layer, outer: rectLoop(0, 0, 10, 4))
        guard let first = entity.localGeometry?.first else {
            return XCTFail("region entity has no geometry")
        }
        // This is the exact integration point HATCH's Select Boundary
        // mode uses: the region's outer polyline must yield its loop.
        let worldPts = CADGeometryMath.worldPointsForPrimitive(
            first, transform: entity.transform)
        XCTAssertEqual(worldPts.count, 4)
        XCTAssertEqual(
            CADBoundaryDetector.shoelaceArea(polygon: worldPts),
            40.0, accuracy: 1e-9)
    }

    // MARK: - Step 3b: MASSPROP file output

    func testMassPropReportFileRoundTrip() throws {
        let report = RegionMass.analyze(
            solids: [solid(rectLoop(0, 0, 10, 4))],
            ucs: .identity)
        let lines = MassPropCommand.reportLines(
            report: report, luprec: 4, coplanar: true, skipped: 0)
        XCTAssertTrue(lines.contains { $0.contains("Area: 40.0000") })
        XCTAssertTrue(lines.contains { $0.contains("Centroid:") })
        XCTAssertTrue(lines.contains { $0.contains("Moments of inertia:") })
        XCTAssertTrue(lines.contains { $0.contains("Principal moments") })

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("massprop_\(UUID().uuidString).mpr")
        defer { try? FileManager.default.removeItem(at: url) }
        try MassPropCommand.writeReport(lines, to: url)
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, lines.joined(separator: "\n") + "\n")
        XCTAssertTrue(readBack.contains("Principal moments"))
    }

    func testMassPropResolveMprURLRules() {
        let folder = URL(fileURLWithPath: "/drawings")
        // Absolute keeps path, adds the extension.
        XCTAssertEqual(
            MassPropCommand.resolveMprURL(
                pathTail: "/tmp/out", drawingFolder: folder,
                displayName: "plate")?.path,
            "/tmp/out.mpr")
        // Relative anchors at the drawing folder; existing extension kept.
        XCTAssertEqual(
            MassPropCommand.resolveMprURL(
                pathTail: "part", drawingFolder: folder,
                displayName: "plate")?.path,
            "/drawings/part.mpr")
        XCTAssertEqual(
            MassPropCommand.resolveMprURL(
                pathTail: "\"quoted name\"", drawingFolder: folder,
                displayName: "plate")?.path,
            "/drawings/quoted name.mpr")
        // Empty tail falls back to <drawing>.mpr for saved drawings...
        XCTAssertEqual(
            MassPropCommand.resolveMprURL(
                pathTail: "  ", drawingFolder: folder,
                displayName: "plate")?.path,
            "/drawings/plate.mpr")
        // ...and to nil when the drawing was never saved.
        XCTAssertNil(MassPropCommand.resolveMprURL(
            pathTail: "", drawingFolder: nil, displayName: nil))
    }

    // MARK: - Step 4b: PEDIT re-weld of exploded regions

    func testPeditReweldExplodedRegion() throws {
        let (doc, layer) = makeDoc()
        let entity = regionEntity(layer, outer: rectLoop(0, 0, 10, 4))
        doc.addEntity(entity)
        let handles = doc.explodeEntities(handles: [entity.handle])
        XCTAssertEqual(handles.count, 4)

        // Each exploded line becomes an open 2-point PEDIT join source.
        var sources: [PeditGeometryEngine.JoinSource] = []
        for handle in handles {
            guard let exploded = doc.entity(for: handle),
                  case let .line(start, end, _)? = exploded.localGeometry?.first
            else {
                return XCTFail("expected line primitives from exploded region")
            }
            sources.append(PeditGeometryEngine.JoinSource(
                path: CADPolyline(points: [start, end], isClosed: false)))
        }
        guard let target = sources.first else {
            return XCTFail("no exploded segments")
        }
        guard let joined = PeditGeometryEngine.joinPolylines(
            target: target, sources: Array(sources.dropFirst())) else {
            return XCTFail("PEDIT join of exploded region lines failed")
        }
        let closed = PeditGeometryEngine.closed(joined)
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(
            CADBoundaryDetector.shoelaceArea(
                polygon: closed.vertices.map(\.position)),
            40.0, accuracy: 1e-6)
    }

    // MARK: - Step 5b: export downgrade accounting

    func testExportDowngradeCount() {
        let layer = UUID()
        let region = regionEntity(layer, outer: rectLoop(0, 0, 10, 4))
        var plain = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(path: rectLoop(20, 0, 24, 2))],
            transform: .identity)
        XCTAssertEqual(
            DXFWriterBridge.regionDowngradeCount(entities: [region, plain]), 1)
        plain.xdata[CADRegion.markerKey] = .bool(true)
        XCTAssertEqual(
            DXFWriterBridge.regionDowngradeCount(entities: [region, plain]), 2)
        // A blob-carrying region exports as REGION, not a downgrade.
        var passthrough = CADEntity(
            layerID: layer, localGeometry: [], transform: .identity)
        CADRegion.markAcisBlob(
            &passthrough, version: 1, lines: [(1, "400 1 0 0 body-start")])
        XCTAssertEqual(
            DXFWriterBridge.regionDowngradeCount(
                entities: [region, plain, passthrough]), 2)
        XCTAssertEqual(DXFWriterBridge.regionDowngradeCount(entities: []), 0)
    }

    // MARK: - Step 5c: ACIS passthrough

    private func acisDXF() -> String {
        """
        0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        0
         10
        0.0
         20
        0.0
         11
        10.0
         21
        10.0
          0
        REGION
          5
        AB
          8
        0
        100
        AcDbEntity
        100
        AcDbModelerGeometry
         70
        1
          1
        400 1 0 0 body-start
          1
        -1 0 lump 7 facet-res-0.5
          3
        extra-record tail-part
          1
        999 end-mark
          0
        ENDSEC
          0
        EOF
        """
    }

    private func acisLines() -> [(code: Int, text: String)] {
        [
            (1, "400 1 0 0 body-start"),
            (1, "-1 0 lump 7 facet-res-0.5"),
            (3, "extra-record tail-part"),
            (1, "999 end-mark"),
        ]
    }

    private func importAcisDXF() throws -> DXFImportResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acis_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try acisDXF().write(to: url, atomically: true, encoding: .utf8)
        return try DXFImporter.importDXFViews(filePath: url.path)
    }

    func testAcisPassthroughRoundTrip() throws {
        let imported = try importAcisDXF()
        // LINE survives; the REGION becomes a marker entity carrying
        // the opaque body (no editable loops).
        XCTAssertEqual(imported.entities.count, 2)
        guard let region = imported.entities.first(where: {
            CADRegion.isRegionEntity($0)
        }) else {
            return XCTFail("expected a region-marked passthrough entity")
        }
        XCTAssertTrue(InquiryMath.regionLoops(of: region).isEmpty)
        guard let blob = CADRegion.acisBlob(of: region) else {
            return XCTFail("expected a retained ACIS blob")
        }
        XCTAssertEqual(blob.version, 1)
        XCTAssertEqual(blob.lines.count, acisLines().count)
        for (got, want) in zip(blob.lines, acisLines()) {
            XCTAssertEqual(got.code, want.code)
            XCTAssertEqual(got.text, want.text)
        }

        // Export writes a real REGION record with the identical payload.
        let (doc, _) = makeDoc()
        for e in imported.entities {
            var moved = e
            moved.layerID = doc.allLayers.first?.handle ?? moved.layerID
            doc.addEntity(moved)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acis_rt_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: doc, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("REGION"))
        XCTAssertTrue(text.contains("AcDbModelerGeometry"))
        // Payload lines survive in file order.
        var cursor = text.startIndex
        for want in acisLines() {
            guard let found = text.range(of: want.text, range: cursor..<text.endIndex) else {
                return XCTFail("lost ACIS line: \(want.text)")
            }
            cursor = found.upperBound
        }

        // Re-importing the export yields the identical blob: the round
        // trip ODA/DWG performs is byte-stable.
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        guard let again = reimported.entities.first(where: {
            CADRegion.isRegionEntity($0)
        }), let blob2 = CADRegion.acisBlob(of: again) else {
            return XCTFail("expected the blob after re-import")
        }
        XCTAssertEqual(blob2.version, blob.version)
        XCTAssertEqual(blob2.lines.count, blob.lines.count)
        for (got, want) in zip(blob2.lines, blob.lines) {
            XCTAssertEqual(got.code, want.code)
            XCTAssertEqual(got.text, want.text)
        }
    }

    func testAcisBlobSurvivesEABRoundTrip() throws {
        // The recommendation rests on xdata riding every persistence path:
        // pin the EAB leg with a real write/read cycle.
        let (doc, layer) = makeDoc()
        var entity = CADEntity(
            layerID: layer, localGeometry: [], transform: .identity)
        CADRegion.markAcisBlob(&entity, version: 1, lines: acisLines())
        doc.addEntity(entity)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acis_eab_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: doc, to: url)
        let views = try EABReader.readViews(from: url)
        let readDoc = try XCTUnwrap(views.first).document
        guard let again = readDoc.allEntities.first(where: {
            CADRegion.isRegionEntity($0)
        }), let blob = CADRegion.acisBlob(of: again) else {
            return XCTFail("expected the retained blob after EAB round-trip")
        }
        XCTAssertEqual(blob.version, 1)
        XCTAssertEqual(blob.lines.count, acisLines().count)
        for (got, want) in zip(blob.lines, acisLines()) {
            XCTAssertEqual(got.code, want.code)
            XCTAssertEqual(got.text, want.text)
        }
    }

    func testAcisRegionSurvivesAudit() {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        guard let layerID = doc.findLayer(named: "0")?.handle else {
            return XCTFail("missing layer 0")
        }
        var entity = CADEntity(
            layerID: layerID, localGeometry: [], transform: .identity)
        CADRegion.markAcisBlob(
            &entity, version: 1, lines: [(1, "400 1 0 0 body-start")])
        doc.addEntity(entity)
        let report = AuditEngine.validate(document: doc)
        XCTAssertEqual(report.errorCount, 0,
                       "retained ACIS body must not flag empty geometry: \(report.breakdown)")
    }

    func testBooleanRejectsOpaqueAcis() {
        var entity = CADEntity(
            layerID: UUID(), localGeometry: [], transform: .identity)
        CADRegion.markAcisBlob(
            &entity, version: 1, lines: [(1, "400 1 0 0 body-start")])
        let (solids, failures) = RegionBoolean.extractSolids(from: [entity])
        XCTAssertEqual(solids.count, 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("opaque"))
    }

    // MARK: - Step 5: DXF interop

    func testDXFRegionOnlyImportSkipsCleanly() throws {
        let dxf = """
        0
        SECTION
          2
        ENTITIES
          0
        LINE
          8
        0
         10
        0.0
         20
        0.0
         11
        10.0
         21
        10.0
          0
        REGION
          5
        AB
          8
        0
          0
        ENDSEC
          0
        EOF
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("region_skip_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        // Must not throw; the ACIS REGION is skipped with a warning while
        // the LINE imports intact.
        let imported = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(imported.entities.count, 1)
        guard case .line = imported.entities.first?.localGeometry?.first else {
            return XCTFail("expected the LINE entity to survive")
        }
    }

    func testDXFRegionExportRoundTripPreservesLoops() throws {
        let (doc, layer) = makeDoc()
        let entity = regionEntity(
            layer, outer: rectLoop(0, 0, 10, 4),
            holes: [circleLoop(5, 2, 1)])
        doc.addEntity(entity)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("region_rt_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: doc, to: url)

        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let loops = reimported.entities.compactMap { e -> CADPolyline? in
            guard let prims = e.localGeometry else { return nil }
            for prim in prims {
                if case let .polyline(path, _) = prim, path.isClosed {
                    return path
                }
            }
            return nil
        }
        // Outer plus hole survive as closed LWPOLYLINEs with net area intact.
        // (The zephyr.region marker is CAD-side metadata, not DXF data.
        // The hole keeps its analytic 2-bulge form, so areas are measured
        // tessellated, matching AREA semantics.)
        XCTAssertGreaterThanOrEqual(loops.count, 2)
        let gross = loops.map { RegionBoolean.tessellatedArea(of: $0) }
            .sorted(by: >)
        XCTAssertEqual(gross[0], 40.0, accuracy: 1e-6)
        XCTAssertEqual(gross[1], Double.pi, accuracy: 0.1)
    }
}
