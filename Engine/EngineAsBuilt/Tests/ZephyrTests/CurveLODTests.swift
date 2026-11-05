import XCTest
@testable import ZephyrCore

@MainActor
final class CurveLODTests: XCTestCase {

    private func lodContext(
        pixelsPerUnit: Double = 1000,
        viewport: ScreenTessellationViewport? = nil,
        maximumSegments: Int = 4096
    ) -> CurveScreenTessellationContext {
        let band = CurveScreenTessellation.zoomBand(for: pixelsPerUnit)
        return CurveScreenTessellationContext(
            pixelsPerUnit: pixelsPerUnit,
            band: band,
            designZoom: CurveScreenTessellation.designZoom(for: band),
            viewport: viewport,
            maximumSegments: maximumSegments)
    }

    private func finiteSegmentDeviation(
        _ point: Vector3, _ start: Vector3, _ end: Vector3
    ) -> Double {
        let chord = Vector3(
            x: end.x - start.x, y: end.y - start.y, z: (end.z - start.z))
        let lengthSquared = chord.x * chord.x + chord.y * chord.y
        guard lengthSquared > 1e-24 else {
            let dx = point.x - start.x
            let dy = point.y - start.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var projection = ((point.x - start.x) * chord.x + (point.y - start.y) * chord.y)
            / lengthSquared
        projection = min(1.0, max(0.0, projection))
        let dx = point.x - (start.x + chord.x * projection)
        let dy = point.y - (start.y + chord.y * projection)
        return (dx * dx + dy * dy).squareRoot()
    }

    func testLODContextWorldToleranceUsesBandPromotionZoom() {
        let context = lodContext(pixelsPerUnit: 1000)
        XCTAssertEqual(context.band, 9)
        XCTAssertEqual(context.designZoom, 1024, accuracy: 1e-9)
        XCTAssertEqual(
            context.worldTolerance(), 0.25 / 1024, accuracy: 1e-12)
    }

    func testLODContextHysteresisPreventsBandThrashing() {
        let staying = CurveScreenTessellationContext.forPixelsPerUnit(
            1023.0, currentBand: 9)
        XCTAssertEqual(staying?.band, 9)
        let promoting = CurveScreenTessellationContext.forPixelsPerUnit(
            2000.0, currentBand: 9)
        XCTAssertEqual(promoting?.band, 10)
        XCTAssertEqual(promoting?.designZoom ?? -1, 2048, accuracy: 1e-9)
    }

    func testLODContextBudgetSharesTotalAcrossCurves() {
        let context = lodContext()
        XCTAssertEqual(context.budgetedMaximumSegments(curveCount: 1), 4096)
        XCTAssertEqual(
            context.budgetedMaximumSegments(curveCount: 1_000_000), 64)
        let defaultContext = CurveScreenTessellationContext(
            pixelsPerUnit: 1000, band: 10, designZoom: 1024)
        XCTAssertEqual(
            defaultContext.budgetedMaximumSegments(curveCount: 4),
            CurveScreenTessellation.defaultTotalMaximumSegments / 4)
    }

    func testDiagnosticsMerge() {
        var combined = CurveTessellationDiagnostics()
        var first = CurveTessellationDiagnostics()
        first.recordCurve(
            requestedSegments: 100, emittedSegments: 90,
            didHitMaximumSegments: false)
        var second = CurveTessellationDiagnostics()
        second.recordCurve(
            requestedSegments: 200, emittedSegments: 50,
            didHitMaximumSegments: true)
        combined.merge(first)
        combined.merge(second)
        XCTAssertEqual(combined.curves, 2)
        XCTAssertEqual(combined.requestedSegments, 300)
        XCTAssertEqual(combined.emittedSegments, 140)
        XCTAssertEqual(combined.clampedCurves, 1)
    }

    func testMaximumPlanarScaleMatchesSingularValues() {
        XCTAssertEqual(
            CurveScreenTessellation.maximumPlanarScale(.identity),
            1.0, accuracy: 1e-12)
        XCTAssertEqual(
            CurveScreenTessellation.maximumPlanarScale(
                .scaled(by: Vector3(x: 2, y: 3, z: 1))),
            3.0, accuracy: 1e-9)
        XCTAssertEqual(
            CurveScreenTessellation.maximumPlanarScale(
                .rotated(by: .pi / 5).multiplying(by: .scaled(
                    by: Vector3(x: 2, y: 2, z: 1)))),
            2.0, accuracy: 1e-9)
    }

    func testArcSectorBoundsIncludeSweptQuadrantExtremum() {
        let bounds = CurveScreenTessellation.arcSectorBounds(
            center: Vector3(x: 0, y: 0, z: 0),
            radius: 10,
            startAngle: 80.0 * .pi / 180.0,
            sweep: 20.0 * .pi / 180.0)
        guard let value = try? XCTUnwrap(bounds) else {
            XCTFail("Expected arc sector bounds")
            return
        }
        XCTAssertEqual(value.maxY, 10.0, accuracy: 1e-9)
        XCTAssertLessThan(value.minY, 9.9)
    }

    func testCircleScreenTessellationMeetsPixelTolerance() {
        let center = Vector3(x: 5, y: -3, z: 0)
        let tessellation = CurveScreenTessellation.tessellateCircularArc(
            center: center,
            radius: 10,
            startAngle: 0,
            sweep: 2.0 * .pi,
            context: lodContext())
        XCTAssertFalse(tessellation.didHitMaximumSegments)
        XCTAssertFalse(tessellation.usedCoarseTolerance)
        XCTAssertGreaterThan(tessellation.points.count, 65)
        let tolerance = 0.25 / 1024.0
        XCTAssertEqual(
            tessellation.points.first?.x ?? -1, center.x + 10,
            accuracy: 1e-9)
        XCTAssertEqual(
            tessellation.points.last?.x ?? -1, center.x + 10,
            accuracy: 1e-9)
        for index in 0..<(tessellation.points.count - 1) {
            let start = tessellation.points[index]
            let end = tessellation.points[index + 1]
            let midAngle = atan2(
                (start.y - center.y) + (end.y - center.y),
                (start.x - center.x) + (end.x - center.x))
            let mid = Vector3(
                x: center.x + cos(midAngle) * 10,
                y: center.y + sin(midAngle) * 10,
                z: 0)
            XCTAssertLessThanOrEqual(
                finiteSegmentDeviation(mid, start, end),
                tolerance * 1.001)
        }
    }

    func testOffScreenArcUsesCoarseTolerance() {
        let far = ScreenTessellationViewport(
            minX: 10_000, minY: 10_000, maxX: 10_010, maxY: 10_010)
        let near = ScreenTessellationViewport(
            minX: -20, minY: -20, maxX: 20, maxY: 20)
        let offScreen = CurveScreenTessellation.tessellateCircularArc(
            center: Vector3(x: 0, y: 0, z: 0),
            radius: 10,
            startAngle: 0,
            sweep: .pi / 2,
            context: lodContext(viewport: far))
        let onScreen = CurveScreenTessellation.tessellateCircularArc(
            center: Vector3(x: 0, y: 0, z: 0),
            radius: 10,
            startAngle: 0,
            sweep: .pi / 2,
            context: lodContext(viewport: near))
        XCTAssertTrue(offScreen.usedCoarseTolerance)
        XCTAssertFalse(offScreen.didHitMaximumSegments)
        XCTAssertFalse(onScreen.usedCoarseTolerance)
        XCTAssertGreaterThan(
            onScreen.points.count, offScreen.points.count)
        XCTAssertEqual(
            offScreen.points.first?.x ?? -1, 10.0, accuracy: 1e-9)
        XCTAssertEqual(
            offScreen.points.last?.y ?? -1, 10.0, accuracy: 1e-9)
    }

    func testEllipseScreenTessellationMeetsPixelTolerance() {
        let center = Vector3(x: 0, y: 0, z: 0)
        let major = Vector3(x: 10, y: 0, z: 0)
        let tessellation = CurveScreenTessellation.tessellateEllipse(
            center: center,
            majorAxis: major,
            minorRatio: 0.5,
            context: lodContext())
        XCTAssertFalse(tessellation.didHitMaximumSegments)
        XCTAssertGreaterThanOrEqual(tessellation.points.count, 9)
        let tolerance = 0.25 / 1024.0
        for index in 0..<(tessellation.points.count - 1) {
            let start = tessellation.points[index]
            let end = tessellation.points[index + 1]
            let startAngle = atan2(start.y / 0.5, start.x)
            let endAngle = atan2(end.y / 0.5, end.x)
            var midAngle = 0.5 * (startAngle + endAngle)
            if endAngle - startAngle > .pi { midAngle += .pi }
            if startAngle - endAngle > .pi { midAngle -= .pi }
            let mid = Vector3(
                x: 10 * cos(midAngle), y: 5 * sin(midAngle), z: 0)
            XCTAssertLessThanOrEqual(
                finiteSegmentDeviation(mid, start, end),
                tolerance * 1.002)
        }
    }

    func testBulgedPolylineScreenTessellation() throws {
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0)),
                CADPolylineVertex(
                    position: Vector3(x: 10, y: 0, z: 0), bulge: 1.0),
                CADPolylineVertex(position: Vector3(x: 10, y: 10, z: 0)),
            ],
            isClosed: false)
        let tessellation = CurveScreenTessellation.tessellatePolyline(
            path: path, context: lodContext())
        XCTAssertFalse(tessellation.curve.didHitMaximumSegments)
        XCTAssertGreaterThan(tessellation.samples.count, 8)
        XCTAssertEqual(tessellation.segments.count, 2)
        let tolerance = 0.25 / 1024.0
        for segmentSamples in tessellation.segments {
            for index in 0..<(segmentSamples.count - 1) {
                let lower = segmentSamples[index]
                let upper = segmentSamples[index + 1]
                let midLocalT = 0.5 * (lower.localT + upper.localT)
                let mid = path.point(
                    onSegment: lower.segment, t: midLocalT)
                XCTAssertLessThanOrEqual(
                    finiteSegmentDeviation(mid, lower.point, upper.point),
                    tolerance * 1.002)
            }
        }
        XCTAssertEqual(
            tessellation.samples.first?.point.x ?? -1, 0.0,
            accuracy: 1e-9)
        XCTAssertEqual(
            tessellation.samples.last?.point.y ?? -1, 10.0,
            accuracy: 1e-9)
    }

    func testIsCurveBearingSeparatesStaticGeometry() {
        XCTAssertTrue(CADPrimitiveGenerator.isCurveBearing(
            .circle(center: Vector3(x: 0, y: 0, z: 0), radius: 1, color: nil)))
        XCTAssertTrue(CADPrimitiveGenerator.isCurveBearing(
            .ellipse(
                center: Vector3(x: 0, y: 0, z: 0),
                majorAxis: Vector3(x: 1, y: 0, z: 0),
                minorRatio: 0.5, color: nil)))
        XCTAssertFalse(CADPrimitiveGenerator.isCurveBearing(
            .line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 0, z: 0), color: nil)))
        XCTAssertFalse(CADPrimitiveGenerator.isCurveBearing(
            .polyline(
                path: CADPolyline(
                    vertices: [
                        CADPolylineVertex(
                            position: Vector3(x: 0, y: 0, z: 0)),
                        CADPolylineVertex(
                            position: Vector3(x: 1, y: 0, z: 0)),
                    ],
                    isClosed: false),
                color: nil)))
        XCTAssertTrue(CADPrimitiveGenerator.isCurveBearing(
            .polyline(
                path: CADPolyline(
                    vertices: [
                        CADPolylineVertex(
                            position: Vector3(x: 0, y: 0, z: 0)),
                        CADPolylineVertex(
                            position: Vector3(x: 1, y: 0, z: 0),
                            bulge: 0.5),
                        CADPolylineVertex(
                            position: Vector3(x: 1, y: 1, z: 0)),
                    ],
                    isClosed: false),
                color: nil)))
    }

    func testCircleGeneratorUsesScreenToleranceAndReportsBudget() {
        let primitive = CADPrimitive.circle(
            center: Vector3(x: 5, y: -3, z: 0), radius: 10, color: nil)
        let color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        var diagnostics = CurveTessellationDiagnostics()
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: primitive,
            transform: .identity,
            color: color,
            z: 1_000_100.0,
            curveTessellation: lodContext(),
            diagnostics: &diagnostics,
            isTrueColor: false)
        XCTAssertEqual(diagnostics.curves, 1)
        XCTAssertFalse(specs.isEmpty)
        let pointCount = specs.reduce(0) { $0 + $1.points.count }
        XCTAssertGreaterThan(pointCount, 65)
        for spec in specs {
            XCTAssertEqual(spec.z, 1_000_100.0, accuracy: 1e-9)
        }
    }

    func testCurveLODReplacementPreservesZAndEntityIndex() async {
        let handle = UUID()
        let color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
        let primitive = CADPrimitive.circle(
            center: Vector3(x: 5, y: -3, z: 0), radius: 10, color: nil)
        let plan = CADRendererBridge.CurveLODEntityPlan(
            handle: handle,
            orderIndex: 7,
            transform: .identity,
            renderOrigin: .zero,
            textStyleFonts: [:],
            linetypePatterns: [:],
            unitScaleFromMM: 1.0,
            baseZ: 700.0,
            color: ColorRGBA(r: 255, g: 255, b: 255, a: 255),
            clipPolygonWorld: nil,
            clipInverted: false,
            showClipFrame: false,
            primitives: [CADRendererBridge.CurveLODPrimitive(
                primitive: primitive,
                color: color,
                lineType: "CONTINUOUS",
                lineWeight: 0.25,
                lineTypeScale: 1.0,
                geomWidth: 0.0,
                textWidthFactor: 1.0,
                textObliqueAngle: 0.0,
                opacityMultiplier: 1.0,
                isTrueColor: false,
                brush: nil,
                stabilization: nil,
                z: 1_000_700.0)])

        let geometry = GeometryManager()
        let legacy = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: primitive,
            transform: .identity,
            color: color,
            z: 1_000_700.0)
        var legacyIDs: [SpriteID] = []
        for spec in legacy {
            let id = spec.addTo(
                geometry, viewportBackground: (0, 0, 0, 255))
            if let prim = geometry.getPrimitive(id: id) {
                prim.entityIndex = 7
            }
            legacyIDs.append(id)
        }
        XCTAssertFalse(legacyIDs.isEmpty)

        let updates = await CADRendererBridge.computeCurveLODUpdates(
            plans: [plan], context: lodContext())
        XCTAssertEqual(updates.count, 1)
        XCTAssertFalse(updates[0].specs.isEmpty)
        XCTAssertGreaterThan(
            updates[0].specs.reduce(0) { $0 + $1.points.count },
            legacy.reduce(0) { $0 + $1.points.count })

        var slots = [CADRendererBridge.CurveLODSlot(
            plan: plan, ids: legacyIDs, entityIndex: 7)]
        var map = [handle: legacyIDs]
        let applied = CADRendererBridge.applyCurveLODUpdates(
            updates,
            slots: &slots,
            into: geometry,
            entityPrimitiveMap: &map,
            viewportBackground: (0, 0, 0, 255))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(map[handle], slots[0].ids)
        XCTAssertEqual(slots[0].entityIndex, 7)
        for id in slots[0].ids {
            guard let value = try? XCTUnwrap(geometry.getPrimitive(id: id)) else {
                XCTFail("Expected replaced primitive")
                return
            }
            XCTAssertEqual(value.z, 1_000_700.0, accuracy: 1e-9)
            XCTAssertEqual(value.entityIndex, 7)
        }
        for id in legacyIDs {
            XCTAssertNil(geometry.getPrimitive(id: id))
        }
    }
}
