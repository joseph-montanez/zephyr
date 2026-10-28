import XCTest
import Foundation
@testable import ZephyrCore

final class CADArrayDataTests: XCTestCase {
    func testRectangularTransforms() {
        let array = CADArrayData.rectangular(
            columns: 3,
            rows: 2,
            columnSpacing: 5,
            rowSpacing: 7)
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 6)
        XCTAssertEqual(instances[2].transform.position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(instances[3].transform.position.y, 7, accuracy: 1e-9)
    }

    func testFullCirclePolarDoesNotDuplicateEndpoint() {
        let array = CADArrayData.polar(
            itemCount: 4,
            centerPoint: Vector3(x: -10, y: 0, z: 0))
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 4)
        let first = instances[0].transform.transformPoint(.zero)
        let second = instances[1].transform.transformPoint(.zero)
        XCTAssertEqual(first.x, 0, accuracy: 1e-9)
        XCTAssertEqual(first.y, 0, accuracy: 1e-9)
        XCTAssertEqual(second.x, -10, accuracy: 1e-9)
        XCTAssertEqual(second.y, 10, accuracy: 1e-9)
    }

    func testPathDivideTransforms() {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 3)
        XCTAssertEqual(instances[1].transform.position.x, 5, accuracy: 1e-9)
    }

    func testPathAlignmentModes() {
        let points = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
        ]
        func objectAngle(item: Int, mode: CADArrayPathAlignment) -> Double {
            var array = CADArrayData.path(itemCount: 3, cachedPath: points)
            array.pathAlignment = mode
            let instances = array.evaluatedInstances()
            let origin = instances[item].transform.transformPoint(
                Vector3(x: 0, y: 0, z: 0))
            let rotated = instances[item].transform.transformPoint(
                Vector3(x: 1, y: 0, z: 0))
            return atan2(rotated.y - origin.y, rotated.x - origin.x)
        }
        // Item 2 rides the vertical leg (tangent 90 degrees).
        XCTAssertEqual(
            objectAngle(item: 2, mode: .relativeToStart), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(
            objectAngle(item: 2, mode: .tangent), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(
            objectAngle(item: 2, mode: .normal), .pi, accuracy: 1e-9)
        // Item 0 rides the horizontal leg (tangent 0 degrees).
        XCTAssertEqual(
            objectAngle(item: 0, mode: .relativeToStart), 0, accuracy: 1e-9)
        XCTAssertEqual(
            objectAngle(item: 0, mode: .tangent), 0, accuracy: 1e-9)
        XCTAssertEqual(
            objectAngle(item: 0, mode: .normal), .pi / 2, accuracy: 1e-9)
    }

    func testOldPayloadWithoutAlignmentDecodes() throws {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let data = try JSONEncoder().encode(array)
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "pathAlignment")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(CADArrayData.self, from: legacy)
        XCTAssertEqual(decoded.pathAlignment, .relativeToStart)
        XCTAssertEqual(decoded.itemCount, 3)
        XCTAssertEqual(decoded.alignItems, true)
    }

    func testRebasedAnchorPutsPickedPointOnPath() throws {
        // World path (0,0)-(20,0), creation base (5,0): cached path is
        // base-relative, entity transform carries the base.
        var array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: -5, y: 0, z: 0),
                Vector3(x: 15, y: 0, z: 0),
            ])
        let base = Transform3D.translated(
            by: Vector3(x: 5, y: 0, z: 0))
        // Pick near the first item (anchor world (0,0)): the anchor is the
        // block-local point under the cursor, resolved in item 0's frame.
        let anchor = CADArrayData.rebasedAnchor(
            worldPoint: Vector3(x: 1, y: 2, z: 0),
            entityTransform: base,
            array: array,
            pathPoints: array.cachedPath)
        XCTAssertEqual(anchor, Vector3(x: 1, y: 2, z: 0))
        array.baseAnchor = try XCTUnwrap(anchor)
        let instances = array.evaluatedInstances()
        let first = try XCTUnwrap(
            instances.first(where: { $0.index.item == 0 }))
        // The picked source point now renders on the path start ...
        let onPath = base.transformPoint(
            first.transform.transformPoint(Vector3(x: 1, y: 2, z: 0)))
        XCTAssertEqual(onPath.x, 0, accuracy: 1e-9)
        XCTAssertEqual(onPath.y, 0, accuracy: 1e-9)
        // ... and the old anchor shifted by the same (-1,-2).
        let shifted = base.transformPoint(
            first.transform.transformPoint(Vector3(x: 0, y: 0, z: 0)))
        XCTAssertEqual(shifted.x, -1, accuracy: 1e-9)
        XCTAssertEqual(shifted.y, -2, accuracy: 1e-9)
    }

    func testRebasedAnchorOnRotatedItem() throws {
        // Normal alignment rotates item 0 by 90°: the anchor absorbs that
        // rotation so the picked source point still lands on the path start.
        var array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: -5, y: 0, z: 0),
                Vector3(x: 5, y: 0, z: 0),
                Vector3(x: 5, y: 10, z: 0),
            ])
        array.pathAlignment = .normal
        let entity = Transform3D.translated(
            by: Vector3(x: 0, y: 0, z: 0))
        // Item 0's anchor is at world (-5,0); pick 1 above it.
        let anchor = CADArrayData.rebasedAnchor(
            worldPoint: Vector3(x: -5, y: 1, z: 0),
            entityTransform: entity,
            array: array,
            pathPoints: array.cachedPath)
        XCTAssertEqual(anchor?.x ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(anchor?.y ?? .nan, 0, accuracy: 1e-9)
        array.baseAnchor = try XCTUnwrap(anchor)
        let instances = array.evaluatedInstances()
        let first = try XCTUnwrap(
            instances.first(where: { $0.index.item == 0 }))
        let onPath = first.transform.transformPoint(
            Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(onPath.x, -5, accuracy: 1e-9)
        XCTAssertEqual(onPath.y, 0, accuracy: 1e-9)
    }

    func testOldPayloadWithoutBaseAnchorDecodes() throws {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let data = try JSONEncoder().encode(array)
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "baseAnchor")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(CADArrayData.self, from: legacy)
        XCTAssertEqual(decoded.baseAnchor, Vector3(x: 0, y: 0, z: 0))
        XCTAssertEqual(decoded.itemCount, 3)
    }

    func testDXFPayloadRoundTrip() throws {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let payload = CADArrayDXFPayload(
            groupID: UUID(),
            containerTransform: .translated(by: Vector3(x: 2, y: 3, z: 0)),
            data: array)
        let decoded = try XCTUnwrap(CADArrayDXFCodec.decode(CADArrayDXFCodec.encode(payload)))
        XCTAssertEqual(decoded.data, array)
        XCTAssertEqual(try XCTUnwrap(decoded.transform).position.x, 2, accuracy: 1e-9)
    }
}

/// End-to-end creation → rebase through the real document pipeline
/// (`replaceWithAssociativeArray` / `updateEntity`): re-picking the base
/// must shift the source under the path, never move item stations.
@MainActor
final class ArrayBasePointIntegrationTests: XCTestCase {
    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func lineEntity(
        layer: UUID, start: Vector3, end: Vector3
    ) -> CADEntity {
        CADEntity(
            layerID: layer,
            localGeometry: [
                .line(start: start, end: end, color: nil),
            ])
    }

    /// Mirror `ArrayCommand.createArray` for a path array: bake `-base` into
    /// the source block, carry `base` in the entity transform, cache the
    /// base-relative path.
    private func createPathArray(
        document: CADDocument,
        layer: UUID,
        sourceHandle: UUID,
        pathHandle: UUID,
        base: Vector3,
        itemCount: Int
    ) throws -> UUID {
        guard let source = document.entity(for: sourceHandle),
              let sourceGeometry = document.resolvedGeometry(for: source),
              let pathEntity = document.entity(for: pathHandle),
              let pathGeometry = document.resolvedGeometry(for: pathEntity),
              let cached = CADArrayPathResolver.localPoints(
                geometry: pathGeometry,
                pathTransform: pathEntity.transform,
                containerTransform: .translated(by: base))
        else { throw XCTSkip("missing fixture geometry") }
        let baked = CADGeometryMath.transformPrimitives(
            sourceGeometry,
            by: .translated(by: Vector3(x: -base.x, y: -base.y, z: -base.z)))
        let block = CADBlock(name: "*UARR_TEST", geometry: baked)
        let array = CADArrayData.path(
            method: .divide,
            itemCount: itemCount,
            pathEntityHandle: pathHandle,
            cachedPath: cached)
        var arrayEntity = CADEntity(
            layerID: layer,
            blockID: block.handle,
            arrayData: array,
            transform: .translated(by: base),
            drawOrder: 0)
        arrayEntity.updateArrayCache(
            sourceBoundingBox: block.localBoundingBox,
            pathPoints: cached)
        document.replaceWithAssociativeArray(
            sourceBlock: block,
            removing: [sourceHandle],
            arrayEntity: arrayEntity)
        return arrayEntity.handle
    }

    private func stationWorld(
        entity: CADEntity, indexItem: Int, anchor: Vector3
    ) throws -> Vector3 {
        let array = try XCTUnwrap(entity.arrayData)
        let instance = try XCTUnwrap(array.evaluatedInstances().first(
            where: { $0.index.item == indexItem }))
        return entity.transform.transformPoint(
            instance.transform.transformPoint(anchor))
    }

    func testRebaseKeepsItemZeroAtSplineStart() throws {
        let document = makeDocument()
        let layer = try XCTUnwrap(document.findLayer(named: "0")).handle
        let source = lineEntity(
            layer: layer,
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 10, y: 0, z: 0))
        document.addEntity(source)
        let path = lineEntity(
            layer: layer,
            start: Vector3(x: 0, y: 0, z: 0),
            end: Vector3(x: 40, y: 0, z: 0))
        document.addEntity(path)
        // Creation base picked off-center exercises the baked offset.
        let base = Vector3(x: 2, y: 0, z: 0)
        let handle = try createPathArray(
            document: document,
            layer: layer,
            sourceHandle: source.handle,
            pathHandle: path.handle,
            base: base,
            itemCount: 3)
        var entity = try XCTUnwrap(document.entity(for: handle))
        // Creation parks item 0's anchor on the spline start.
        let created = try stationWorld(
            entity: entity, indexItem: 0,
            anchor: Vector3(x: 0, y: 0, z: 0))
        XCTAssertEqual(created.x, 0, accuracy: 1e-9)
        XCTAssertEqual(created.y, 0, accuracy: 1e-9)
        let before = try XCTUnwrap(entity.arrayData).evaluatedInstances().map {
            $0.transform.transformPoint(Vector3(x: 0, y: 0, z: 0))
        }

        // Rebase onto the end of the first item (world (10,0)), mirroring
        // `ArrayBasePointCommand.applyBase`.
        var array = try XCTUnwrap(entity.arrayData)
        let resolved = CADArrayPathResolver.points(
            for: array,
            containerTransform: entity.transform,
            document: document)
        let anchor = try XCTUnwrap(CADArrayData.rebasedAnchor(
            worldPoint: Vector3(x: 10, y: 0, z: 0),
            entityTransform: entity.transform,
            array: array,
            pathPoints: resolved))
        XCTAssertEqual(anchor.x, 10, accuracy: 1e-9)
        array.baseAnchor = anchor
        entity.arrayData = array
        document.updateEntity(entity)
        entity = try XCTUnwrap(document.entity(for: handle))
        XCTAssertEqual(
            try XCTUnwrap(entity.arrayData).baseAnchor.x, 10, accuracy: 1e-9)

        // The picked source point rides the spline start, and every station
        // is exactly where creation parked it.
        let picked = try stationWorld(
            entity: entity, indexItem: 0, anchor: anchor)
        XCTAssertEqual(picked.x, 0, accuracy: 1e-9)
        XCTAssertEqual(picked.y, 0, accuracy: 1e-9)
        let after = try XCTUnwrap(entity.arrayData).evaluatedInstances().map {
            $0.transform.transformPoint(anchor)
        }
        XCTAssertEqual(before.count, after.count)
        for (oldStation, newStation) in zip(before, after) {
            XCTAssertEqual(newStation.x, oldStation.x, accuracy: 1e-9)
            XCTAssertEqual(newStation.y, oldStation.y, accuracy: 1e-9)
        }
    }
}
