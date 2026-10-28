import XCTest
@testable import ZephyrCore

/// P6 (selection cursor lag): live drag transforms run per mouse-move event,
/// so they skip full storage prep (pen spline fitting, anchor rebuilds).
/// Local-space caches are invariant under pure transforms and `transform`'s
/// didSet already refreshes the world box, so live results must match the
/// committed path exactly.
@MainActor
final class LiveTransformPrepTests: XCTestCase {

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADPrimitive {
        .line(start: Vector3(x: x1, y: y1, z: 0), end: Vector3(x: x2, y: y2, z: 0), color: nil)
    }

    private func fixture() -> (doc: CADDocument, handles: [UUID]) {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let block = CADBlock(name: "Box", geometry: [line(0, 0, 1, 1)])
        let loose = CADEntity(
            layerID: layer.handle,
            localGeometry: [line(2, 2, 4, 3)],
            transform: .identity)
        let inst = CADEntity(
            layerID: layer.handle, blockID: block.handle,
            transform: .translated(by: Vector3(x: 6, y: 6, z: 0)))
        doc.importLayersBlocksEntities(
            layers: [layer], blocks: [block], entities: [loose, inst])
        return (doc, [loose.handle, inst.handle])
    }

    private func snapshot(of doc: CADDocument, handle: UUID) -> (world: BoundingBox3D, local: BoundingBox3D, anchors: Int) {
        let e = doc.entity(for: handle)
        return (
            e?.worldBoundingBox ?? BoundingBox3D(),
            e?.localBoundingBox ?? BoundingBox3D(),
            e?.anchorPoints.count ?? -1)
    }

    private func assertSameBox(_ lhs: BoundingBox3D, _ rhs: BoundingBox3D, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(lhs.min.x, rhs.min.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(lhs.max.x, rhs.max.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(lhs.min.y, rhs.min.y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(lhs.max.y, rhs.max.y, accuracy: 1e-9, file: file, line: line)
    }

    func testLiveMoveMatchesCommittedMove() {
        let (liveDoc, liveHandles) = fixture()
        let (refDoc, refHandles) = fixture()
        let delta = Vector3(x: 10, y: -3, z: 0)
        liveDoc.moveEntitiesLive(handles: Set(liveHandles), by: delta)
        refDoc.moveEntities(handles: Set(refHandles), by: delta)
        XCTAssertEqual(liveHandles.count, 2)
        for (live, ref) in zip(liveHandles, refHandles) {
            let l = snapshot(of: liveDoc, handle: live)
            let r = snapshot(of: refDoc, handle: ref)
            assertSameBox(l.world, r.world)
            assertSameBox(l.local, r.local)
            XCTAssertEqual(l.anchors, r.anchors, "anchor cache must agree")
        }
    }

    func testLiveRotateMatchesCommittedRotate() {
        let (liveDoc, liveHandles) = fixture()
        let (refDoc, refHandles) = fixture()
        let center = Vector3(x: 5, y: 5, z: 0)
        liveDoc.rotateEntitiesLive(handles: Set(liveHandles), around: center, angleDeltaRadians: 0.3)
        refDoc.rotateEntities(handles: Set(refHandles), around: center, angleDeltaRadians: 0.3)
        for (live, ref) in zip(liveHandles, refHandles) {
            let l = snapshot(of: liveDoc, handle: live)
            let r = snapshot(of: refDoc, handle: ref)
            assertSameBox(l.world, r.world)
            XCTAssertEqual(l.anchors, r.anchors, "anchor cache must agree")
        }
    }

    func testLiveScaleMatchesCommittedScale() {
        let (liveDoc, liveHandles) = fixture()
        let (refDoc, refHandles) = fixture()
        let center = Vector3(x: 5, y: 5, z: 0)
        liveDoc.scaleEntitiesLive(handles: Set(liveHandles), around: center, factor: 2.0)
        refDoc.scaleEntities(handles: Set(refHandles), around: center, factor: 2.0)
        for (live, ref) in zip(liveHandles, refHandles) {
            let l = snapshot(of: liveDoc, handle: live)
            let r = snapshot(of: refDoc, handle: ref)
            assertSameBox(l.world, r.world)
            XCTAssertEqual(l.anchors, r.anchors, "anchor cache must agree")
        }
    }
}
