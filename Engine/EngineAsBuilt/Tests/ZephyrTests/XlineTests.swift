import XCTest
@testable import ZephyrCore
import ZephyrKernel

/// Phase 1A-3 tests: the `.xline` vertical slice — infinite-both-ways
/// hit-testing, the native kernel curve mapping, DXF XLINE conversion,
/// EAB code-21 round trip, and LIST inquiry output.
@MainActor
final class XlineTests: XCTestCase {

    private func makeDoc(prims: [CADPrimitive]) -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let entity = CADEntity(layerID: layer.handle, localGeometry: prims)
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        doc.rebuildEntityGrid()
        return doc
    }

    func testDistanceReachesBackwardExtension() {
        // The entity grid culls by base-point bounds (same as rays), so the
        // both-directions math is covered at the distance unit below; the
        // public path is covered near the base point in the next test.
        let xline = CADPrimitive.xline(
            point: Vector3(x: 0, y: 0, z: 0),
            direction: Vector3(x: 1, y: 0, z: 0))
        let d = CADHitTesting.distanceSqToPrimitive(
            xline, point: Vector3(x: -50, y: 0, z: 0),
            transform: .identity, t2: 1.0)
        XCTAssertNotNil(d, "xline distance must reach behind its base point")
        let ray = CADPrimitive.ray(
            start: Vector3(x: 0, y: 0, z: 0),
            direction: Vector3(x: 1, y: 0, z: 0))
        XCTAssertNil(
            CADHitTesting.distanceSqToPrimitive(
                ray, point: Vector3(x: -50, y: 0, z: 0),
                transform: .identity, t2: 1.0),
            "ray control must miss behind its start point")
    }

    func testHitTestFindsXlineNearBase() {
        let doc = makeDoc(prims: [
            .xline(
                point: Vector3(x: 0, y: 0, z: 0),
                direction: Vector3(x: 1, y: 0, z: 0))
        ])
        let hit = CADHitTesting.hitTest(
            worldX: 0.5, worldY: 0.1, document: doc,
            threshold: 1.0, simplifyComplexBlocks: false)
        XCTAssertNotNil(hit, "xline must be hittable near its base point")
    }

    func testBridgeMapsToSingleNativeCurve() {
        let curves = CADPrimitive.xline(
            point: Vector3(x: 3, y: 4, z: 0),
            direction: Vector3(x: 2, y: 0, z: 0)
        ).toKernelCurves()
        XCTAssertEqual(curves.count, 1)
        guard case .xline(let xl) = curves.first else {
            return XCTFail("expected a native xline kernel curve, got \(curves)")
        }
        XCTAssertEqual(xl.origin.x, 3, accuracy: 1e-9)
        XCTAssertEqual(xl.origin.y, 4, accuracy: 1e-9)
        XCTAssertEqual(xl.direction.x, 1, accuracy: 1e-9)
        XCTAssertEqual(xl.direction.y, 0, accuracy: 1e-9)
    }

    func testConverterMapsXLineEntity() {
        let e = DXFXLineEntity()
        e.basePoint = Vector3(x: 10, y: -4, z: 0)
        e.secPoint = Vector3(x: 0, y: 2, z: 0)
        let prims = DXFEntityConverter.convertEntityToPrimitives(e)
        XCTAssertEqual(prims.count, 1)
        guard case .xline(let point, let direction, _) = prims.first else {
            return XCTFail("expected .xline, got \(prims)")
        }
        // Converter applies the DXF Y-flip to base point and direction.
        XCTAssertEqual(point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(point.y, 4, accuracy: 1e-9)
        XCTAssertEqual(direction.x, 0, accuracy: 1e-9)
        XCTAssertEqual(direction.y, -2, accuracy: 1e-9)
    }

    func testBisectorRightAngle() {
        let dir = XlineMath.bisector(
            vertex: Vector3(x: 0, y: 0, z: 0),
            start: Vector3(x: 1, y: 0, z: 0),
            end: Vector3(x: 0, y: 1, z: 0))
        let d = try? XCTUnwrap(dir)
        // Unnormalized leg sum (1,1): direction only, commit sites use it raw.
        XCTAssertEqual(d?.x ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(d?.y ?? 0, 1, accuracy: 1e-9)
    }

    func testBisectorOppositeRaysGoesPerpendicular() {
        let dir = XlineMath.bisector(
            vertex: Vector3(x: 0, y: 0, z: 0),
            start: Vector3(x: 1, y: 0, z: 0),
            end: Vector3(x: -1, y: 0, z: 0))
        let d = try? XCTUnwrap(dir)
        XCTAssertEqual(abs(d?.x ?? 1), 0, accuracy: 1e-9)
        XCTAssertEqual(abs(d?.y ?? 0), 1, accuracy: 1e-9)
    }

    func testBisectorCoincidentPointsReturnNil() {
        XCTAssertNil(XlineMath.bisector(
            vertex: Vector3(x: 0, y: 0, z: 0),
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 1, y: 0, z: 0)))
    }

    func testOffsetXlineRoundTripsThroughKernel() {
        let source = CADPrimitive.xline(
            point: Vector3(x: 0, y: 0, z: 0),
            direction: Vector3(x: 1, y: 0, z: 0))
        guard let curve = source.toKernelCurves().first else {
            return XCTFail("no kernel curve for xline")
        }
        guard let moved = Offset2D.offsetSingleCurve(
            curve, distance: 2, sidePoint: Point2d(x: 0, y: -1))
        else {
            return XCTFail("offset failed")
        }
        guard let rebuilt = CADPrimitive.fromKernelCurve(
            moved, preservingColorFrom: source),
            case .xline(let base, let dir, _) = rebuilt
        else {
            return XCTFail("offset did not rebuild an xline, got \(moved)")
        }
        XCTAssertEqual(base.x, 0, accuracy: 1e-9)
        XCTAssertEqual(base.y, -2, accuracy: 1e-9)
        XCTAssertEqual(dir.x, 1, accuracy: 1e-9)
        XCTAssertEqual(dir.y, 0, accuracy: 1e-9)
    }

    func testInquiryTypeNameLengthAndDescribe() {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.xline(
                point: Vector3(x: 1, y: 2, z: 0),
                direction: Vector3(x: 1, y: 1, z: 0))])
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        XCTAssertEqual(InquiryMath.typeName(of: entity), "XLINE")
        XCTAssertNil(InquiryMath.entityLength(entity))
        XCTAssertNil(InquiryMath.entityArea(entity))
        let text = ListCommand.describe(entity, document: doc, luprec: 4, auprec: 1)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("through point"), "describe must label the base point:\n\(text)")
        XCTAssertTrue(text.contains("direction"), "describe must show the angle:\n\(text)")
    }

    func testEABRoundTrip() throws {
        let doc = makeDoc(prims: [
            .xline(
                point: Vector3(x: 7, y: -2, z: 0),
                direction: Vector3(x: 0, y: 3, z: 0))
        ])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xline-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: doc, to: url)
        // write(document:) emits the archive format, so read back with the
        // matching readViews entry point (readDocument expects legacy magic).
        let views = try EABReader.readViews(from: url)
        let saved = try XCTUnwrap(views.first?.document)
        let prims = saved.allEntities.flatMap { $0.localGeometry ?? [] }
        guard case .xline(let point, let direction, _) = prims.first(where: {
            if case .xline = $0 { return true }
            return false
        }) else {
            return XCTFail("no xline survived the EAB round trip: \(prims)")
        }
        XCTAssertEqual(point.x, 7, accuracy: 1e-9)
        XCTAssertEqual(point.y, -2, accuracy: 1e-9)
        XCTAssertEqual(direction.x, 0, accuracy: 1e-9)
        XCTAssertEqual(direction.y, 3, accuracy: 1e-9)
    }
}
