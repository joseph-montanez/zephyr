import XCTest
import Foundation
@testable import ZephyrCore

/// Snapping during a base-point pick must see array items where they are
/// rendered (per-instance), not the source block at the entity transform.
/// Regression: ARRAYBASEPOINT could not snap to a point on the first item;
/// the path spline (a plain entity) stole the pick, so the rebase resolved
/// a spline point instead of the object point and the array jumped by more
/// than the old-base -> new-base delta.
@MainActor
final class ArraySnapTests: XCTestCase {
    /// Source line (0,0)-(4,0) in block space, creation base (0,10), path
    /// (0,0)-(20,0) in world space: item 0 renders at (0,0)-(4,0) while the
    /// un-instanced ("ghost") source sits at (0,10)-(4,10).
    private func makeArrayFixture() throws -> (CADDocument, CADEntity, CADEntity) {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        let layer = try XCTUnwrap(document.findLayer(named: "0")).handle
        let block = CADBlock(
            name: "*UARR_SNAP",
            geometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 4, y: 0, z: 0),
                    color: nil),
            ])
        document.addBlock(block)
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: -10, z: 0),
                Vector3(x: 20, y: -10, z: 0),
            ])
        var arrayEntity = CADEntity(
            layerID: layer,
            blockID: block.handle,
            arrayData: array,
            transform: .translated(by: Vector3(x: 0, y: 10, z: 0)),
            drawOrder: 0)
        arrayEntity.updateArrayCache(
            sourceBoundingBox: block.localBoundingBox,
            pathPoints: array.cachedPath)
        document.addEntity(arrayEntity)
        let pathEntity = CADEntity(
            layerID: layer,
            localGeometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 20, y: 0, z: 0),
                    color: nil),
            ])
        document.addEntity(pathEntity)
        return (
            document,
            try XCTUnwrap(document.entity(for: arrayEntity.handle)),
            try XCTUnwrap(document.entity(for: pathEntity.handle)))
    }

    func testSnapFindsRenderedFirstItemEndpointNotPath() throws {
        let (document, arrayEntity, pathEntity) = try makeArrayFixture()
        let snap = SnapEngine().nearestSnap(
            worldX: 4, worldY: 0.2,
            entities: [arrayEntity, pathEntity],
            threshold: 1.0,
            resolveGeometry: { document.resolvedGeometry(for: $0) },
            primitiveVisibility: { document.primitiveVisibility(for: $0) },
            spatialGrid: { document.spatialGrid(for: $0) })
        let hit = try XCTUnwrap(snap, "no snap near rendered item 0 endpoint")
        XCTAssertEqual(hit.entityHandle, arrayEntity.handle,
                       "snap must land on the object, not the path spline")
        XCTAssertEqual(hit.worldPos.x, 4, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 0, accuracy: 1e-9)
    }

    func testSnapNearestOnRenderedItemBetweenAnchors() throws {
        let (document, arrayEntity, pathEntity) = try makeArrayFixture()
        let snap = SnapEngine().nearestSnap(
            worldX: 2.7, worldY: 0.2,
            entities: [arrayEntity, pathEntity],
            threshold: 0.5,
            resolveGeometry: { document.resolvedGeometry(for: $0) },
            primitiveVisibility: { document.primitiveVisibility(for: $0) },
            spatialGrid: { document.spatialGrid(for: $0) })
        let hit = try XCTUnwrap(snap, "no on-curve snap on rendered item 0")
        XCTAssertEqual(hit.entityHandle, arrayEntity.handle)
        XCTAssertEqual(hit.worldPos.x, 2.7, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 0, accuracy: 1e-9)
    }
}

/// Creation default base point (Enter at the base-point step): AutoCAD uses
/// the endpoint of the path curve closest to the path pick and starts the
/// array there, so the first item keeps its original place and offset.
final class ArrayCreationDefaultTests: XCTestCase {
    private let worldPath = [
        Vector3(x: 0, y: 0, z: 0),
        Vector3(x: 20, y: 0, z: 0),
    ]

    func testDefaultBaseNearStartUsesStart() throws {
        let dflt = try XCTUnwrap(CADArrayPathResolver.defaultBase(
            pick: Vector3(x: 1, y: 3, z: 0), worldPoints: worldPath))
        XCTAssertEqual(dflt.base, Vector3(x: 0, y: 0, z: 0))
        XCTAssertFalse(dflt.reversed)
    }

    func testDefaultBaseNearEndUsesEndAndReverses() throws {
        let dflt = try XCTUnwrap(CADArrayPathResolver.defaultBase(
            pick: Vector3(x: 19, y: -2, z: 0), worldPoints: worldPath))
        XCTAssertEqual(dflt.base, Vector3(x: 20, y: 0, z: 0))
        XCTAssertTrue(dflt.reversed)
    }

    /// With the default base, item 0 must render exactly where the source
    /// object was drawn: source point 10 above the path endpoint stays 10
    /// above the path start instead of jumping onto the path.
    func testDefaultBaseKeepsFirstItemInOriginalPlace() throws {
        for pick in [Vector3(x: 1, y: 0, z: 0), Vector3(x: 19, y: 0, z: 0)] {
            let dflt = try XCTUnwrap(CADArrayPathResolver.defaultBase(
                pick: pick, worldPoints: worldPath))
            // Mirror ArrayCommand.createArray: path cached base-relative,
            // entity transform carries the base.
            let cached = worldPath.map {
                Vector3(x: $0.x - dflt.base.x, y: $0.y - dflt.base.y, z: 0)
            }
            var array = CADArrayData.path(itemCount: 3, cachedPath: cached)
            array.reversePath = dflt.reversed
            let entity = Transform3D.translated(by: dflt.base)
            let anchor = try XCTUnwrap(CADArrayData.anchorWorld(
                entityTransform: entity,
                array: array,
                pathPoints: cached))
            XCTAssertEqual(anchor.x, dflt.base.x, accuracy: 1e-9)
            XCTAssertEqual(anchor.y, dflt.base.y, accuracy: 1e-9)
            // A source point drawn at (base.x, 10) is block-local (0, 10);
            // item 0 must render it at its original world position.
            let instances = array.evaluatedInstances()
            let first = try XCTUnwrap(
                instances.first(where: { $0.index.item == 0 }))
            let rendered = entity.transformPoint(
                first.transform.transformPoint(Vector3(x: 0, y: 10, z: 0)))
            XCTAssertEqual(rendered.x, dflt.base.x, accuracy: 1e-9)
            XCTAssertEqual(rendered.y, 10, accuracy: 1e-9)
        }
    }
}
