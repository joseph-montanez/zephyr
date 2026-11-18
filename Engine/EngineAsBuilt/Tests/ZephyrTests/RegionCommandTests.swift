import XCTest
@testable import ZephyrCore

/// Step 1 REGION slice: closed-loop extraction, validation, mass math,
/// document atomicity, LIST/AREA reporting, and EXPLODE round-trip.
@MainActor
final class RegionCommandTests: XCTestCase {

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return (doc, layer.handle)
    }

    private func rectEntity(
        _ layer: UUID, origin: Vector3 = .init(x: 0, y: 0, z: 0),
        w: Double = 10, h: Double = 4
    ) -> CADEntity {
        let path = CADPolyline(
            points: [
                origin,
                Vector3(x: origin.x + w, y: origin.y, z: 0),
                Vector3(x: origin.x + w, y: origin.y + h, z: 0),
                Vector3(x: origin.x, y: origin.y + h, z: 0),
            ],
            isClosed: true)
        return CADEntity(
            layerID: layer, localGeometry: [.polyline(path: path)])
    }

    // MARK: - Builder: single closed entities

    func testClosedRectPolylineBecomesOneRegion() {
        let entity = rectEntity(UUID())
        let (loops, failures) = RegionBuilder.buildRegions(from: [entity])
        XCTAssertTrue(failures.isEmpty, "unexpected failures: \(failures)")
        XCTAssertEqual(loops.count, 1)
        let mass = RegionBuilder.massProperties(of: loops[0].polyline)
        XCTAssertEqual(mass.area, 40.0, accuracy: 1e-9)
        XCTAssertEqual(mass.perimeter, 28.0, accuracy: 1e-9)
        XCTAssertEqual(mass.centroid.x, 5.0, accuracy: 1e-9)
        XCTAssertEqual(mass.centroid.y, 2.0, accuracy: 1e-9)
    }

    func testCircleBecomesTwoBulgeRegion() {
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [
                .circle(
                    center: Vector3(x: 0, y: 0, z: 0), radius: 10, color: nil),
            ])
        let (loops, failures) = RegionBuilder.buildRegions(from: [entity])
        XCTAssertTrue(failures.isEmpty, "unexpected failures: \(failures)")
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops[0].polyline.vertices.count, 2)
        XCTAssertTrue(loops[0].polyline.isClosed)
        let mass = RegionBuilder.massProperties(of: loops[0].polyline)
        // Default tessellation (12 segs/radian, 76 spans) linearizes the
        // two bulge halves: measured rel err ~1.1e-3. Step 2 booleans use
        // their own chord budget; this pins current behavior, not the goal.
        XCTAssertEqual(
            mass.area, Double.pi * 100, accuracy: Double.pi * 100 * 2e-3)
        XCTAssertEqual(
            mass.perimeter, 2 * Double.pi * 10,
            accuracy: 2 * Double.pi * 10 * 1e-3)
    }

    // MARK: - Builder: rejection

    func testFigureEightIsRejected() {
        let path = CADPolyline(
            points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 2, y: 2, z: 0),
                Vector3(x: 2, y: 0, z: 0),
                Vector3(x: 0, y: 2, z: 0),
            ],
            isClosed: true)
        let entity = CADEntity(
            layerID: UUID(), localGeometry: [.polyline(path: path)])
        let (loops, failures) = RegionBuilder.buildRegions(from: [entity])
        XCTAssertEqual(loops.count, 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("Self-intersecting"))
    }

    func testSingleOpenLineIsRejected() {
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 5, y: 0, z: 0), color: nil),
            ])
        let (loops, failures) = RegionBuilder.buildRegions(from: [entity])
        XCTAssertEqual(loops.count, 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("open"))
    }

    func testUnsupportedEntityIsRejected() {
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [
                .text(
                    position: Vector3(x: 0, y: 0, z: 0), text: "hi", height: 1,
                    rotation: 0, style: nil, alignH: 0, alignV: 0,
                    mtextWidth: nil, color: nil),
            ])
        let (loops, failures) = RegionBuilder.buildRegions(from: [entity])
        XCTAssertEqual(loops.count, 0)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("TEXT"))
    }

    // MARK: - Builder: chains

    func testFourLinesChainIntoSquare() {
        let layer = UUID()
        func line(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double)
            -> CADEntity {
            CADEntity(
                layerID: layer,
                localGeometry: [
                    .line(
                        start: Vector3(x: ax, y: ay, z: 0),
                        end: Vector3(x: bx, y: by, z: 0), color: nil),
                ])
        }
        let entities = [
            line(0, 0, 10, 0), line(10, 0, 10, 10),
            line(10, 10, 0, 10), line(0, 10, 0, 0),
        ]
        let (loops, failures) = RegionBuilder.buildRegions(from: entities)
        XCTAssertTrue(failures.isEmpty, "unexpected failures: \(failures)")
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops[0].sourceHandles.count, 4)
        let mass = RegionBuilder.massProperties(of: loops[0].polyline)
        XCTAssertEqual(mass.area, 100.0, accuracy: 1e-6)
    }

    func testLinePlusArcChainPreservesBulge() {
        let layer = UUID()
        let bottom = CADEntity(
            layerID: layer,
            localGeometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 10, y: 0, z: 0), color: nil),
            ])
        let right = CADEntity(
            layerID: layer,
            localGeometry: [
                .line(
                    start: Vector3(x: 10, y: 0, z: 0),
                    end: Vector3(x: 10, y: 10, z: 0), color: nil),
            ])
        // Upper half-disk closing the loop via the top (sweep pi).
        let cap = CADEntity(
            layerID: layer,
            localGeometry: [
                .arc(
                    center: Vector3(x: 5, y: 10, z: 0), radius: 5,
                    startAngle: 0, endAngle: Double.pi, color: nil),
            ])
        let left = CADEntity(
            layerID: layer,
            localGeometry: [
                .line(
                    start: Vector3(x: 0, y: 10, z: 0),
                    end: Vector3(x: 0, y: 0, z: 0), color: nil),
            ])
        let (loops, failures) = RegionBuilder.buildRegions(
            from: [bottom, right, cap, left])
        XCTAssertTrue(failures.isEmpty, "unexpected failures: \(failures)")
        XCTAssertEqual(loops.count, 1)
        XCTAssertTrue(
            loops[0].polyline.vertices.contains { abs($0.bulge) > 1e-9 },
            "arc span must survive as a bulge")
        let mass = RegionBuilder.massProperties(of: loops[0].polyline)
        let expected = 100.0 + Double.pi * 25.0 / 2.0
        XCTAssertEqual(mass.area, expected, accuracy: 0.5)
        let expectedPerimeter = 10.0 + 10.0 + 10.0 + Double.pi * 5.0
        XCTAssertEqual(mass.perimeter, expectedPerimeter, accuracy: 0.05)
    }

    // MARK: - Document atomicity

    func testDocumentReplaceIsSingleUndo() {
        let (doc, layer) = makeDoc()
        let source = rectEntity(layer)
        doc.addEntity(source)
        XCTAssertEqual(doc.allEntities.count, 1)

        let (loops, failures) = RegionBuilder.buildRegions(from: [source])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(loops.count, 1)
        var region = CADEntity(
            layerID: loops[0].layerID,
            localGeometry: [.polyline(path: loops[0].polyline)],
            transform: .identity)
        region.xdata[CADRegion.markerKey] = .bool(true)
        doc.replaceEntities(remove: loops[0].sourceHandles, add: [region])

        XCTAssertEqual(doc.allEntities.count, 1)
        XCTAssertNil(doc.entity(for: source.handle))
        let stored = doc.entity(for: region.handle)
        XCTAssertNotNil(stored)
        XCTAssertTrue(CADRegion.isRegionEntity(stored!))

        doc.undo()
        XCTAssertNotNil(doc.entity(for: source.handle))
        XCTAssertNil(doc.entity(for: region.handle))

        doc.redo()
        XCTAssertNil(doc.entity(for: source.handle))
        XCTAssertNotNil(doc.entity(for: region.handle))
    }

    // MARK: - LIST / AREA reporting

    func testRegionTypeNameAndArea() {
        let (doc, layer) = makeDoc()
        var entity = rectEntity(layer)
        entity.xdata[CADRegion.markerKey] = .bool(true)
        XCTAssertEqual(InquiryMath.typeName(of: entity), "REGION")
        XCTAssertEqual(InquiryMath.entityArea(entity) ?? -1, 40.0, accuracy: 1e-9)
        let lines = ListCommand.describe(
            entity, document: doc, luprec: doc.lengthPrecision,
            auprec: doc.anglePrecision)
        XCTAssertTrue(lines.contains { $0.contains("REGION") })
        XCTAssertTrue(lines.contains { $0.contains("Region boundary") })
        XCTAssertTrue(lines.contains { $0.contains("Area = ") })
    }

    // MARK: - EXPLODE round-trip

    func testExplodeRegionYieldsLinesAndStripsMarker() {
        let (doc, layer) = makeDoc()
        var entity = rectEntity(layer)
        entity.xdata[CADRegion.markerKey] = .bool(true)
        doc.addEntity(entity)
        let handles = doc.explodeEntities(handles: [entity.handle])
        XCTAssertEqual(handles.count, 4)
        XCTAssertNil(doc.entity(for: entity.handle))
        for handle in handles {
            guard let exploded = doc.entity(for: handle) else {
                XCTFail("missing exploded entity")
                continue
            }
            XCTAssertFalse(CADRegion.isRegionEntity(exploded))
            guard case .line = exploded.localGeometry?.first else {
                XCTFail("expected line primitives from rect region")
                continue
            }
        }
        doc.undo()
        XCTAssertNotNil(doc.entity(for: entity.handle))
    }
}
