import XCTest
@testable import ZephyrCore

/// Step 2 Booleans: arrangement core identities, enforcement gates,
/// document atomicity, holed-region reporting, and a small flange E2E.
@MainActor
final class RegionBooleanTests: XCTestCase {

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
        _ outer: CADPolyline, holes: [CADPolyline] = []
    ) -> BooleanSolid {
        BooleanSolid(
            outer: outer, holes: holes, layerID: UUID(),
            sourceHandles: [UUID()])
    }

    private func totalArea(_ faces: [BooleanFace]) -> Double {
        faces.reduce(0.0) { acc, face in
            acc + RegionBoolean.tessellatedArea(of: face.outer)
                - face.holes.reduce(0.0) {
                    acc2, hole in acc2 + RegionBoolean.tessellatedArea(of: hole)
                }
        }
    }

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layer.handle)
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

    // MARK: - Arrangement convention

    func testArrangementKeepsInteriorOnLeft() {
        let ring = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 4, z: 0),
            Vector3(x: 0, y: 4, z: 0),
        ]
        let arrangement = RegionBoolean.Arrangement(rings: [ring])
        XCTAssertEqual(arrangement.faces.count, 2)
        let inside = arrangement.testPoints.filter {
            RegionBoolean.isPointInRing($0, ring)
        }
        // Exactly one face test point lands inside the square: the bounded
        // face. (The outer face's point lands outside.)
        XCTAssertEqual(inside.count, 1)
    }

    // MARK: - UNION

    func testUnionOverlappingRects() {
        let a = solid(rectLoop(0, 0, 10, 4))
        let b = solid(rectLoop(5, 0, 15, 4))
        let (faces, failures) = RegionBoolean.apply(.union, targets: [a, b])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 1)
        guard faces.count == 1 else { return }
        XCTAssertTrue(faces[0].holes.isEmpty)
        XCTAssertEqual(totalArea(faces), 60.0, accuracy: 1e-6)
    }

    func testUnionDisjointYieldsTwoFaces() {
        let a = solid(rectLoop(0, 0, 10, 4))
        let c = solid(rectLoop(20, 0, 24, 2))
        let (faces, failures) = RegionBoolean.apply(.union, targets: [a, c])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 2)
        XCTAssertEqual(totalArea(faces), 48.0, accuracy: 1e-6)
    }

    func testUnionSharedEdgeDissolvesInterior() {
        let a = solid(rectLoop(0, 0, 10, 4))
        let d = solid(rectLoop(10, 0, 20, 4))
        let (faces, failures) = RegionBoolean.apply(.union, targets: [a, d])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(totalArea(faces), 80.0, accuracy: 1e-6)
    }

    // MARK: - SUBTRACT

    func testSubtractContainedCutterBecomesHole() {
        let target = solid(rectLoop(0, 0, 10, 4))
        let cutter = solid(circleLoop(5, 2, 1))
        let (faces, failures) = RegionBoolean.apply(
            .subtract, targets: [target], cutters: [cutter])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 1)
        guard faces.count == 1 else { return }
        XCTAssertEqual(faces[0].holes.count, 1)
        XCTAssertEqual(totalArea(faces), 40.0 - Double.pi, accuracy: 0.05)
    }

    func testSubtractOverlappingCutterTrims() {
        let target = solid(rectLoop(0, 0, 10, 4))
        let cutter = solid(rectLoop(5, 0, 15, 4))
        let (faces, failures) = RegionBoolean.apply(
            .subtract, targets: [target], cutters: [cutter])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 1)
        guard faces.count == 1 else { return }
        XCTAssertTrue(faces[0].holes.isEmpty)
        XCTAssertEqual(totalArea(faces), 20.0, accuracy: 1e-6)
    }

    func testSubtractFullCoverLeavesNothing() {
        let target = solid(rectLoop(0, 0, 10, 4))
        let cutter = solid(rectLoop(-5, -5, 15, 9))
        let (faces, failures) = RegionBoolean.apply(
            .subtract, targets: [target], cutters: [cutter])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 0)
    }

    // MARK: - INTERSECT

    func testIntersectOverlappingRects() {
        let a = solid(rectLoop(0, 0, 10, 4))
        let b = solid(rectLoop(5, 0, 15, 4))
        let (faces, failures) = RegionBoolean.apply(.intersect, targets: [a, b])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(totalArea(faces), 20.0, accuracy: 1e-6)
    }

    func testIntersectDisjointIsEmpty() {
        let a = solid(rectLoop(0, 0, 10, 4))
        let c = solid(rectLoop(20, 0, 24, 2))
        let (faces, failures) = RegionBoolean.apply(
            .intersect, targets: [a, c])
        XCTAssertTrue(failures.isEmpty, "unexpected: \(failures)")
        XCTAssertEqual(faces.count, 0)
    }

    func testCircleOverlapIdentity() {
        let a = solid(circleLoop(0, 0, 10))
        let b = solid(circleLoop(10, 0, 10))
        let (unionFaces, unionFailures) = RegionBoolean.apply(
            .union, targets: [a, b])
        let (isectFaces, isectFailures) = RegionBoolean.apply(
            .intersect, targets: [a, b])
        XCTAssertTrue(unionFailures.isEmpty)
        XCTAssertTrue(isectFailures.isEmpty)
        // A union B = A + B - (A intersect B), within tessellation noise.
        let both = 2.0 * Double.pi * 100.0
        XCTAssertEqual(
            totalArea(unionFaces) + totalArea(isectFaces), both, accuracy: 0.5)
    }

    // MARK: - Full-size flange (Step 5)

    func testFlangeFullSize() {
        // Plate R=50 with 40x20 mounting ears, bore r=10 with a protruding
        // 8x28 keyway, and six r=3 bolt holes on R=35.
        let plate = solid(circleLoop(0, 0, 50))
        let earL = solid(rectLoop(-70, -10, -30, 10))
        let earR = solid(rectLoop(30, -10, 70, 10))
        let (bodyFaces, bodyFailures) = RegionBoolean.apply(
            .union, targets: [plate, earL, earR])
        XCTAssertTrue(bodyFailures.isEmpty, "unexpected: \(bodyFailures)")
        XCTAssertEqual(bodyFaces.count, 1)
        guard bodyFaces.count == 1 else { return }
        let bodyArea = totalArea(bodyFaces)
        XCTAssertGreaterThan(bodyArea, Double.pi * 2500.0)

        var cutters: [BooleanSolid] = [
            solid(circleLoop(0, 0, 10)),
            solid(rectLoop(-4, -14, 4, 14)),
        ]
        for k in 0..<6 {
            let a = Double(k) * Double.pi / 3.0
            cutters.append(solid(circleLoop(35 * cos(a), 35 * sin(a), 3)))
        }
        let (cutterFaces, cutterFailures) = RegionBoolean.apply(
            .union, targets: cutters)
        XCTAssertTrue(cutterFailures.isEmpty, "unexpected: \(cutterFailures)")
        let cutterArea = totalArea(cutterFaces)

        let (netFaces, netFailures) = RegionBoolean.apply(
            .subtract,
            targets: bodyFaces.map { solid($0.outer, holes: $0.holes) },
            cutters: cutterFaces.map { solid($0.outer, holes: $0.holes) })
        XCTAssertTrue(netFailures.isEmpty, "unexpected: \(netFailures)")
        XCTAssertEqual(netFaces.count, 1)
        guard netFaces.count == 1 else { return }
        // Bore+keyway merge into one hole; six bolts stay separate.
        XCTAssertEqual(netFaces[0].holes.count, 7)
        XCTAssertEqual(
            totalArea(netFaces), bodyArea - cutterArea, accuracy: 2.0)
    }

    // MARK: - Enforcement

    func testNonCoplanarAborts() {
        let a = solid(rectLoop(0, 0, 10, 4, z: 0))
        let b = solid(rectLoop(5, 0, 15, 4, z: 1))
        let (faces, failures) = RegionBoolean.apply(.union, targets: [a, b])
        XCTAssertEqual(faces.count, 0)
        XCTAssertFalse(failures.isEmpty)
        XCTAssertTrue(failures.joined().contains("coplanar"))
    }

    func testNonRegionEntityRejected() {
        let line = CADEntity(
            layerID: UUID(),
            localGeometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 5, y: 0, z: 0), color: nil),
            ])
        let (solids, failures) = RegionBoolean.extractSolids(from: [line])
        XCTAssertEqual(solids.count, 0)
        XCTAssertFalse(failures.isEmpty)
    }

    // MARK: - Document atomicity

    func testBooleanDocumentCommitIsSingleUndo() {
        let (doc, layer) = makeDoc()
        let first = regionEntity(layer, outer: rectLoop(0, 0, 10, 4))
        let second = regionEntity(layer, outer: rectLoop(5, 0, 15, 4))
        doc.addEntities([first, second])
        XCTAssertEqual(doc.allEntities.count, 2)

        let (solids, failures) = RegionBoolean.extractSolids(
            from: [first, second])
        XCTAssertTrue(failures.isEmpty)
        let (faces, applyFailures) = RegionBoolean.apply(.union, targets: solids)
        XCTAssertTrue(applyFailures.isEmpty)
        XCTAssertEqual(faces.count, 1)
        guard faces.count == 1 else { return }
        let merged = regionEntity(
            faces[0].layerID, outer: faces[0].outer, holes: faces[0].holes)
        doc.replaceEntities(
            remove: [first.handle, second.handle], add: [merged])

        XCTAssertEqual(doc.allEntities.count, 1)
        XCTAssertEqual(
            InquiryMath.entityArea(doc.entity(for: merged.handle)!) ?? -1,
            60.0, accuracy: 1e-6)

        doc.undo()
        XCTAssertEqual(doc.allEntities.count, 2)
        XCTAssertNotNil(doc.entity(for: first.handle))

        doc.redo()
        XCTAssertEqual(doc.allEntities.count, 1)
        XCTAssertNil(doc.entity(for: first.handle))
    }

    // MARK: - Holed-region reporting

    func testHoledRegionNetAreaAndList() {
        let (doc, layer) = makeDoc()
        let entity = regionEntity(
            layer, outer: rectLoop(0, 0, 10, 4),
            holes: [circleLoop(5, 2, 1)])
        XCTAssertEqual(InquiryMath.typeName(of: entity), "REGION")
        XCTAssertEqual(
            InquiryMath.entityArea(entity) ?? -1, 40.0 - Double.pi,
            accuracy: 0.05)
        let lines = ListCommand.describe(
            entity, document: doc, luprec: doc.lengthPrecision,
            auprec: doc.anglePrecision)
        XCTAssertTrue(lines.contains { $0.contains("1 hole(s)") })
        XCTAssertTrue(lines.contains { $0.contains("Area = ") })
        // Combined perimeter: outer plus hole circumference.
        XCTAssertEqual(
            InquiryMath.entityLength(entity) ?? -1,
            28.0 + 2.0 * Double.pi, accuracy: 0.05)
    }

    func testExplodeHoledRegionStripsMarker() {
        let (doc, layer) = makeDoc()
        let entity = regionEntity(
            layer, outer: rectLoop(0, 0, 10, 4),
            holes: [circleLoop(5, 2, 1)])
        doc.addEntity(entity)
        let handles = doc.explodeEntities(handles: [entity.handle])
        XCTAssertGreaterThan(handles.count, 4)
        XCTAssertNil(doc.entity(for: entity.handle))
        for handle in handles {
            guard let exploded = doc.entity(for: handle) else {
                XCTFail("missing exploded entity")
                continue
            }
            XCTAssertFalse(CADRegion.isRegionEntity(exploded))
        }
        doc.undo()
        XCTAssertNotNil(doc.entity(for: entity.handle))
    }

    // MARK: - Flange E2E (small)

    func testFlangeUnionThenSubtract() {
        // Plate plus two mounting ears.
        let plate = solid(circleLoop(0, 0, 10))
        let earL = solid(rectLoop(-14, -1.5, -6, 1.5))
        let earR = solid(rectLoop(6, -1.5, 14, 1.5))
        let (bodyFaces, bodyFailures) = RegionBoolean.apply(
            .union, targets: [plate, earL, earR])
        XCTAssertTrue(bodyFailures.isEmpty, "unexpected: \(bodyFailures)")
        XCTAssertEqual(bodyFaces.count, 1)
        guard bodyFaces.count == 1 else { return }
        XCTAssertTrue(bodyFaces[0].holes.isEmpty)
        let bodyArea = totalArea(bodyFaces)
        XCTAssertGreaterThan(bodyArea, Double.pi * 100.0)

        // Cutters: central bore, protruding keyway, two bolt holes.
        let bore = solid(circleLoop(0, 0, 2))
        let keyway = solid(rectLoop(-1, -4, 1, 4))
        let bolt1 = solid(circleLoop(5, 0, 0.5))
        let bolt2 = solid(circleLoop(-5, 0, 0.5))
        let (cutterFaces, cutterFailures) = RegionBoolean.apply(
            .union, targets: [bore, keyway, bolt1, bolt2])
        XCTAssertTrue(cutterFailures.isEmpty, "unexpected: \(cutterFailures)")
        let cutterArea = totalArea(cutterFaces)

        let (netFaces, netFailures) = RegionBoolean.apply(
            .subtract,
            targets: bodyFaces.map {
                solid($0.outer, holes: $0.holes)
            },
            cutters: cutterFaces.map {
                solid($0.outer, holes: $0.holes)
            })
        XCTAssertTrue(netFailures.isEmpty, "unexpected: \(netFailures)")
        XCTAssertEqual(netFaces.count, 1)
        guard netFaces.count == 1 else { return }
        // Bore+keyway merge into one hole; bolts are two more.
        XCTAssertEqual(netFaces[0].holes.count, 3)
        // All cutters sit strictly inside the body: net = body - cutters.
        XCTAssertEqual(
            totalArea(netFaces), bodyArea - cutterArea, accuracy: 0.5)
    }
}
