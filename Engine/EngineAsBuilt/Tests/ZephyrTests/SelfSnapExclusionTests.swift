import XCTest
import Foundation
@testable import ZephyrCore

/// Self-snapping while dragging a polyline vertex/midpoint grip.
///
/// Dragging a grip used to drop the edited entity from every snap candidate
/// list, so Endpoint/Midpoint/Intersection/Nearest/Extension never saw the
/// polyline itself. The fix keeps the entity as a candidate with a surgical
/// exclusion: the dragged vertex, its incident segment midpoints, and any
/// nearest/extension/intersection solve on incident segments are skipped,
/// while sibling geometry stays snappable. These tests pin every tier at the
/// `SnapEngine` level plus the grip-to-exclusion resolver.
@MainActor
final class SelfSnapExclusionTests: XCTestCase {

    private let layer = UUID()

    /// Open L polyline: (0,0) -> (10,0) -> (10,10).
    private func lPolyline() -> CADEntity {
        CADEntity(layerID: layer, localGeometry: [
            .polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
                Vector3(x: 10, y: 10, z: 0),
            ]), color: nil),
        ])
    }

    /// Exclusion for dragging vertex 0 of the L polyline: the point itself
    /// plus its single incident segment 0.
    private func dragVertexZero(on entity: CADEntity) -> SnapSelfExclusion {
        SnapSelfExclusion(
            entityHandle: entity.handle,
            primitiveIndex: 0,
            excludedLocalVertices: [0],
            excludedLocalSegments: [0])
    }

    // MARK: - Tier 2 discrete anchors

    /// A sibling vertex of the dragged polyline stays snappable.
    func testSiblingVertexSnapsWhileDragging() throws {
        let pline = lPolyline()
        let snap = SnapEngine().nearestSnap(
            worldX: 10, worldY: 0.2,
            entities: [pline],
            threshold: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: dragVertexZero(on: pline))
        let hit = try XCTUnwrap(snap, "sibling vertex (10,0) should snap")
        XCTAssertEqual(hit.entityHandle, pline.handle)
        XCTAssertEqual(hit.worldPos.x, 10, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 0, accuracy: 1e-9)
        guard case .vertex = hit.anchor else {
            return XCTFail("expected .vertex anchor, got \(hit.anchor)")
        }
    }

    /// The dragged vertex itself never snaps, even with the cursor on it.
    func testDraggedVertexNeverSnaps() {
        let pline = lPolyline()
        let snap = SnapEngine().nearestSnap(
            worldX: 0.1, worldY: 0.1,
            entities: [pline],
            threshold: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: dragVertexZero(on: pline))
        XCTAssertNil(snap, "dragged vertex must not snap onto itself")
    }

    /// Incident-segment midpoints are excluded; non-incident ones snap.
    func testIncidentMidpointExcludedSiblingMidpointSnaps() throws {
        let pline = lPolyline()
        let exclusion = dragVertexZero(on: pline)
        // Midpoint of incident segment 0 is a moving target: no snap.
        let incident = SnapEngine().nearestSnap(
            worldX: 5, worldY: 0.1,
            entities: [pline],
            threshold: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: exclusion)
        XCTAssertNil(incident, "incident midpoint (5,0) must not snap")
        // Midpoint of non-incident segment 1 is static: snaps normally.
        let sibling = SnapEngine().nearestSnap(
            worldX: 10.1, worldY: 5,
            entities: [pline],
            threshold: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: exclusion)
        let hit = try XCTUnwrap(sibling, "sibling midpoint (10,5) should snap")
        XCTAssertEqual(hit.worldPos.x, 10, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 5, accuracy: 1e-9)
        guard case .midpoint = hit.anchor else {
            return XCTFail("expected .midpoint anchor, got \(hit.anchor)")
        }
    }

    // MARK: - Extension tier

    /// Extensions of non-incident segments snap (the reported case).
    ///
    /// Coordinates sit inside the Tier 1 broad-phase box (expanded by the
    /// 1.0 threshold) but outside every discrete anchor's range, isolating
    /// the extension tier: (10,10) is 1.27 away, yet the x=10 ray hits.
    func testNonIncidentExtensionSnaps() throws {
        let pline = lPolyline()
        let snap = SnapEngine().nearestSnap(
            worldX: 10.9, worldY: 10.9,
            entities: [pline],
            threshold: 1.0,
            extensionSnapEnabled: true,
            extensionThresholdPx: 24,
            pixelsPerWorldUnit: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: dragVertexZero(on: pline))
        let hit = try XCTUnwrap(snap, "extension of segment 1 past (10,10) should snap")
        XCTAssertEqual(hit.worldPos.x, 10, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 10.9, accuracy: 1e-9)
        guard case .nearest = hit.anchor else {
            return XCTFail("expected .nearest extension anchor, got \(hit.anchor)")
        }
    }

    /// Extensions of incident segments are moving targets: no snap.
    ///
    /// Both cursors are placed where the excluded segment 0's extension
    /// would hit (perpendicular distance 0.5 < 1.0) while every discrete
    /// anchor stays out of range, so nil proves the exclusion fired.
    func testIncidentExtensionSuppressed() {
        let pline = lPolyline()
        // Past the far end of incident segment 0: would snap without exclusion.
        let pastEnd = SnapEngine().nearestSnap(
            worldX: 10.9, worldY: 0.5,
            entities: [pline],
            threshold: 1.0,
            extensionSnapEnabled: true,
            extensionThresholdPx: 24,
            pixelsPerWorldUnit: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: dragVertexZero(on: pline))
        XCTAssertNil(pastEnd, "extension of dragged segment 0 must not snap")
        // Past the dragged vertex itself.
        let pastStart = SnapEngine().nearestSnap(
            worldX: -0.9, worldY: 0.5,
            entities: [pline],
            threshold: 1.0,
            extensionSnapEnabled: true,
            extensionThresholdPx: 24,
            pixelsPerWorldUnit: 1.0,
            nearestOnCurveOverride: false,
            selfExclusion: dragVertexZero(on: pline))
        XCTAssertNil(pastStart, "extension past the dragged vertex must not snap")
    }

    // MARK: - Nearest-on-curve tier

    /// On-curve points of incident segments are stale while dragging.
    func testIncidentOnCurveSuppressedNonIncidentSnaps() throws {
        let pline = lPolyline()
        let exclusion = dragVertexZero(on: pline)
        let incident = SnapEngine().nearestSnap(
            worldX: 5, worldY: 0.2,
            entities: [pline],
            threshold: 1.0,
            extensionSnapEnabled: false,
            nearestOnCurveOverride: true,
            selfExclusion: exclusion)
        XCTAssertNil(incident, "on-curve point of dragged segment 0 must not snap")
        // Away from every discrete anchor but near segment 1: Tier 3 snaps.
        let sibling = SnapEngine().nearestSnap(
            worldX: 10.2, worldY: 7,
            entities: [pline],
            threshold: 1.0,
            extensionSnapEnabled: false,
            nearestOnCurveOverride: true,
            selfExclusion: exclusion)
        let hit = try XCTUnwrap(sibling, "on-curve point of segment 1 should snap")
        XCTAssertEqual(hit.worldPos.x, 10, accuracy: 1e-9)
        XCTAssertEqual(hit.worldPos.y, 7, accuracy: 1e-9)
    }

    // MARK: - Intersection tier

    /// Five-vertex polyline whose segments 0 and 2 cross at (50/9, 50/9);
    /// segments 0/2 are the only crossing pair.
    private func crossingPolyline() -> CADEntity {
        CADEntity(layerID: layer, localGeometry: [
            .polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 10, z: 0),
                Vector3(x: 0, y: 10, z: 0),
                Vector3(x: 10, y: 2, z: 0),
                Vector3(x: 20, y: 2, z: 0),
            ]), color: nil),
        ])
    }

    /// A self-crossing of two non-incident segments stays snappable.
    func testNonIncidentSelfIntersectionSnaps() throws {
        let pline = crossingPolyline()
        // Dragging vertex 4 excludes only segment 3; the s0/s2 crossing stands.
        let exclusion = SnapSelfExclusion(
            entityHandle: pline.handle,
            primitiveIndex: 0,
            excludedLocalVertices: [4],
            excludedLocalSegments: [3])
        let snap = SnapEngine().nearestSnap(
            worldX: 50.0 / 9.0, worldY: 50.0 / 9.0,
            entities: [pline],
            threshold: 0.5,
            nearestOnCurveOverride: false,
            selfExclusion: exclusion)
        let hit = try XCTUnwrap(snap, "non-incident self-crossing should snap")
        XCTAssertEqual(hit.worldPos.x, 50.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(hit.worldPos.y, 50.0 / 9.0, accuracy: 1e-6)
        guard case .intersection = hit.anchor else {
            return XCTFail("expected .intersection anchor, got \(hit.anchor)")
        }
    }

    /// A crossing involving an incident segment moves with the cursor: no snap.
    func testIncidentSelfIntersectionSuppressed() {
        let pline = crossingPolyline()
        // Dragging vertex 0 excludes segment 0, one side of the crossing.
        let exclusion = SnapSelfExclusion(
            entityHandle: pline.handle,
            primitiveIndex: 0,
            excludedLocalVertices: [0],
            excludedLocalSegments: [0])
        let snap = SnapEngine().nearestSnap(
            worldX: 50.0 / 9.0, worldY: 50.0 / 9.0,
            entities: [pline],
            threshold: 0.5,
            nearestOnCurveOverride: false,
            selfExclusion: exclusion)
        XCTAssertNil(snap, "crossing on the dragged segment must not snap")
    }

    // MARK: - Resolver

    private func makeDoc() -> (CADDocument, UUID) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return (doc, doc.findLayer(named: "0")!.handle)
    }

    @discardableResult
    private func seedPolyline(
        _ doc: CADDocument, layer: UUID, points: [Vector3], isClosed: Bool = false
    ) -> CADEntity {
        let entity = CADEntity(
            layerID: layer,
            localGeometry: [.polyline(
                path: CADPolyline(points: points, isClosed: isClosed),
                color: nil)])
        doc.addEntity(entity)
        return entity
    }

    /// Open polyline endpoint drag excludes the point and its one segment.
    func testResolverOpenVertex() throws {
        let (doc, layer) = makeDoc()
        let entity = seedPolyline(doc, layer: layer, points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
        ])
        let grip = CADSelectionManager.GripType.vertex(entity: entity.handle, index: 0)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .surgical(let ex) = exclusion else {
            return XCTFail("open vertex drag should be surgical, got \(exclusion)")
        }
        XCTAssertEqual(ex.excludedLocalVertices, [0])
        XCTAssertEqual(ex.excludedLocalSegments, [0])
    }

    /// Closed polyline vertex drag wraps incidence around the closing segment.
    func testResolverClosedVertexWraps() throws {
        let (doc, layer) = makeDoc()
        let entity = seedPolyline(doc, layer: layer, points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
            Vector3(x: 0, y: 10, z: 0),
        ], isClosed: true)
        let grip = CADSelectionManager.GripType.vertex(entity: entity.handle, index: 0)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .surgical(let ex) = exclusion else {
            return XCTFail("closed vertex drag should be surgical, got \(exclusion)")
        }
        XCTAssertEqual(ex.excludedLocalVertices, [0])
        XCTAssertEqual(ex.excludedLocalSegments, [0, 3])
    }

    /// Midpoint drag excludes both endpoints plus all three incident segments.
    func testResolverMidpoint() throws {
        let (doc, layer) = makeDoc()
        let entity = seedPolyline(doc, layer: layer, points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
        ])
        let grip = CADSelectionManager.GripType.midpoint(
            entity: entity.handle, betweenA: 0, andB: 1)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .surgical(let ex) = exclusion else {
            return XCTFail("midpoint drag should be surgical, got \(exclusion)")
        }
        XCTAssertEqual(ex.excludedLocalVertices, [0, 1])
        XCTAssertEqual(ex.excludedLocalSegments, [0, 1])
    }

    /// Non-adjacent midpoint endpoints cannot be a dragged segment: whole entity.
    func testResolverMidpointNonAdjacentFallsBack() throws {
        let (doc, layer) = makeDoc()
        let entity = seedPolyline(doc, layer: layer, points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
        ])
        let grip = CADSelectionManager.GripType.midpoint(
            entity: entity.handle, betweenA: 0, andB: 2)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .wholeEntity = exclusion else {
            return XCTFail("non-adjacent midpoint should fall back, got \(exclusion)")
        }
    }

    /// Multi-primitive entities keep the legacy whole-entity exclusion.
    func testResolverMultiPrimitiveFallsBack() throws {
        let (doc, layer) = makeDoc()
        let entity = CADEntity(layerID: layer, localGeometry: [
            .polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ]), color: nil),
            .line(start: Vector3(x: 0, y: 5, z: 0),
                  end: Vector3(x: 10, y: 5, z: 0), color: nil),
        ])
        doc.addEntity(entity)
        let grip = CADSelectionManager.GripType.vertex(entity: entity.handle, index: 0)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .wholeEntity = exclusion else {
            return XCTFail("multi-primitive drag should fall back, got \(exclusion)")
        }
    }

    /// Block instances keep the legacy whole-entity exclusion.
    func testResolverBlockInstanceFallsBack() throws {
        let (doc, layer) = makeDoc()
        let block = CADBlock(name: "SELF_SNAP_BLK", geometry: [
            .polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ]), color: nil),
        ])
        doc.addBlock(block)
        let instance = CADEntity(
            layerID: layer, blockID: block.handle,
            localGeometry: [.polyline(path: CADPolyline(points: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ]), color: nil)])
        doc.addEntity(instance)
        let grip = CADSelectionManager.GripType.vertex(entity: instance.handle, index: 0)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: instance.handle, document: doc)
        guard case .wholeEntity = exclusion else {
            return XCTFail("block drag should fall back, got \(exclusion)")
        }
    }

    /// PEDIT-smoothed polylines keep the legacy whole-entity exclusion.
    func testResolverSmoothedPolylineFallsBack() throws {
        let (doc, layer) = makeDoc()
        var path = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0),
        ])
        path.curveType = .splineCubic
        let entity = CADEntity(
            layerID: layer, localGeometry: [.polyline(path: path, color: nil)])
        doc.addEntity(entity)
        let grip = CADSelectionManager.GripType.vertex(entity: entity.handle, index: 0)
        let exclusion = CADGripSystem.snapExclusion(
            for: grip, gripHandle: entity.handle, document: doc)
        guard case .wholeEntity = exclusion else {
            return XCTFail("smoothed polyline drag should fall back, got \(exclusion)")
        }
    }

    // MARK: - Lock validation

    /// Stale locks on excluded geometry must drop; sibling locks persist.
    func testIsExcludedSnap() throws {
        let pline = lPolyline()
        let exclusion = dragVertexZero(on: pline)
        let draggedVertex = SnapResult(
            entityHandle: pline.handle,
            anchor: .vertex(
                localPosition: Vector3(x: 0, y: 0, z: 0), index: 0),
            worldPos: Vector3(x: 0, y: 0, z: 0))
        XCTAssertTrue(SnapEngine.isExcludedSnap(draggedVertex, by: exclusion))
        let siblingVertex = SnapResult(
            entityHandle: pline.handle,
            anchor: .vertex(
                localPosition: Vector3(x: 10, y: 0, z: 0), index: 1),
            worldPos: Vector3(x: 10, y: 0, z: 0))
        XCTAssertFalse(SnapEngine.isExcludedSnap(siblingVertex, by: exclusion))
        let incidentMid = SnapResult(
            entityHandle: pline.handle,
            anchor: .midpoint(
                localPosition: Vector3(x: 5, y: 0, z: 0), segmentIndex: 0),
            worldPos: Vector3(x: 5, y: 0, z: 0))
        XCTAssertTrue(SnapEngine.isExcludedSnap(incidentMid, by: exclusion))
        let otherEntity = SnapResult(
            entityHandle: UUID(),
            anchor: .vertex(
                localPosition: Vector3(x: 0, y: 0, z: 0), index: 0),
            worldPos: Vector3(x: 0, y: 0, z: 0))
        XCTAssertFalse(SnapEngine.isExcludedSnap(otherEntity, by: exclusion))
    }
}
