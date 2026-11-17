import XCTest
import Foundation
@testable import ZephyrCore

/// OVERKILL (Delete Duplicate Objects): engine behavior coverage.
///
/// Mirrors the AuditRecoverTests harness: build a `CADDocument` directly,
/// run `OverkillEngine.plan`, apply through one `replaceEntities` batch,
/// and assert counts, survivors, and undo restoration.
@MainActor
final class OverkillEngineTests: XCTestCase {

    // MARK: - Harness

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func line(
        _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
        layer: UUID, color: ColorRGBA? = nil, z: Double = 0
    ) -> CADEntity {
        CADEntity(
            layerID: layer,
            localGeometry: [.line(
                start: Vector3(x: ax, y: ay, z: z),
                end: Vector3(x: bx, y: by, z: z),
                color: color)],
            transform: .identity)
    }

    private func circle(
        _ cx: Double, _ cy: Double, _ r: Double, layer: UUID
    ) -> CADEntity {
        CADEntity(
            layerID: layer,
            localGeometry: [.circle(
                center: Vector3(x: cx, y: cy, z: 0), radius: r)],
            transform: .identity)
    }

    private func arc(
        _ cx: Double, _ cy: Double, _ r: Double,
        _ start: Double, _ end: Double, layer: UUID
    ) -> CADEntity {
        CADEntity(
            layerID: layer,
            localGeometry: [.arc(
                center: Vector3(x: cx, y: cy, z: 0), radius: r,
                startAngle: start, endAngle: end)],
            transform: .identity)
    }

    @discardableResult
    private func applyPlan(
        _ document: CADDocument, options: OverkillOptions = OverkillOptions()
    ) -> OverkillReport {
        let plan = OverkillEngine.plan(document: document, handles: nil, options: options)
        document.replaceEntities(remove: plan.remove, add: plan.add)
        return plan.report
    }

    private func liveLines(_ document: CADDocument) -> [(Vector3, Vector3)] {
        var out: [(Vector3, Vector3)] = []
        for entity in document.allEntities {
            for prim in entity.localGeometry ?? [] {
                if case .line(let a, let b, _) = prim { out.append((a, b)) }
            }
        }
        return out
    }

    // MARK: - Exact duplicates

    func testExactDuplicateLinesRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        XCTAssertEqual(document.allEntities.count, 2)
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testReversedDuplicatesRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(10, 0, 0, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testToleranceBoundary() {
        let document = makeDocument()
        let zid = zeroID(document)
        // Within tolerance: duplicate.
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(0, 0, 10, 5e-7, layer: zid))
        // Outside tolerance: distinct (far away so nothing merges).
        document.addEntity(line(100, 0, 110, 0, layer: zid))
        document.addEntity(line(100, 0, 110, 1e-3, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 3)
    }

    func testDifferentLayerKeptUnlessIgnored() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addLayer(Layer(name: "OTHER"))
        let other = try! XCTUnwrap(document.findLayer(named: "OTHER")).handle
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(0, 0, 10, 0, layer: other))
        var report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(document.allEntities.count, 2)

        var options = OverkillOptions()
        options.ignoredProperties = [.layer]
        report = applyPlan(document, options: options)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testDifferentColorKeptUnlessIgnored() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid, color: .red))
        document.addEntity(line(0, 0, 10, 0, layer: zid, color: .blue))
        var report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 0)

        var options = OverkillOptions()
        options.ignoredProperties = [.color]
        report = applyPlan(document, options: options)
        XCTAssertEqual(report.deletedDuplicates, 1)
    }

    func testDuplicateCirclesRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(circle(5, 5, 3, layer: zid))
        document.addEntity(circle(5, 5, 3, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testDuplicateTextRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        func text(_ s: String) -> CADEntity {
            CADEntity(
                layerID: zid,
                localGeometry: [.text(
                    position: Vector3(x: 1, y: 2, z: 0), text: s, height: 2.5,
                    rotation: 0, style: "Standard", alignH: 0, alignV: 0,
                    mtextWidth: nil, color: nil)],
                transform: .identity)
        }
        document.addEntity(text("hello"))
        document.addEntity(text("hello"))
        document.addEntity(text("world"))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    // MARK: - Collinear merging

    func testOverlappingLinesMerged() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(5, 0, 15, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 2)
        XCTAssertEqual(report.unifiedCreated, 1)
        let lines = liveLines(document)
        XCTAssertEqual(lines.count, 1)
        let (a, b) = lines[0]
        XCTAssertEqual(min(a.x, b.x), 0, accuracy: 1e-9)
        XCTAssertEqual(max(a.x, b.x), 15, accuracy: 1e-9)
    }

    func testEndToEndLinesJoined() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 5, 0, layer: zid))
        document.addEntity(line(5, 0, 10, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 2)
        XCTAssertEqual(report.unifiedCreated, 1)
        XCTAssertEqual(liveLines(document).count, 1)
    }

    func testDisjointLinesKept() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 5, 0, layer: zid))
        document.addEntity(line(10, 0, 15, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testOffsetParallelLinesNeverMerged() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(0, 1, 10, 1, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testDifferentZNeverMerged() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid, z: 0))
        document.addEntity(line(0, 0, 10, 0, layer: zid, z: 5))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testMergeFlagsDisabled() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 5, 0, layer: zid))
        document.addEntity(line(5, 0, 10, 0, layer: zid))
        document.addEntity(line(20, 0, 30, 0, layer: zid))
        document.addEntity(line(25, 0, 35, 0, layer: zid))
        var options = OverkillOptions()
        options.mergeEndToEnd = false
        options.mergePartialOverlap = false
        let report = applyPlan(document, options: options)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(document.allEntities.count, 4)
    }

    func testOverlapOnlyWithoutEndToEnd() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 5, 0, layer: zid))
        document.addEntity(line(5, 0, 10, 0, layer: zid))
        var options = OverkillOptions()
        options.mergeEndToEnd = false
        let report = applyPlan(document, options: options)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testContiguousArcsMerged() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(arc(0, 0, 5, 0, Double.pi / 2, layer: zid))
        document.addEntity(arc(0, 0, 5, Double.pi / 2, Double.pi, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.mergedSources, 2)
        XCTAssertEqual(report.unifiedCreated, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    // MARK: - Cleanup

    func testZeroLengthLineRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(1, 1, 1, 1, layer: zid))
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.cleanedUp, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testArcOverCircleRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(circle(0, 0, 5, layer: zid))
        document.addEntity(arc(0, 0, 5, 0, Double.pi / 2, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.cleanedUp, 1)
        XCTAssertEqual(document.allEntities.count, 1)
        // The survivor is the circle.
        let survivor = try! XCTUnwrap(document.allEntities.first)
        if case .circle = survivor.localGeometry?.first {
        } else {
            XCTFail("expected the circle to survive")
        }
    }

    func testFullSweepArcBecomesCircle() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(arc(0, 0, 5, 0, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.unifiedCreated, 1)
        XCTAssertEqual(document.allEntities.count, 1)
        let survivor = try! XCTUnwrap(document.allEntities.first)
        if case .circle = survivor.localGeometry?.first {
        } else {
            XCTFail("expected a circle")
        }
    }

    // MARK: - Polylines

    private func polyline(
        _ points: [Vector3], layer: UUID, closed: Bool = false
    ) -> CADEntity {
        CADEntity(
            layerID: layer,
            localGeometry: [.polyline(points: points)],
            transform: .identity)
    }

    private func closedPolyline(
        _ points: [Vector3], layer: UUID
    ) -> CADEntity {
        var path = CADPolyline(points: points)
        path.isClosed = true
        return CADEntity(
            layerID: layer,
            localGeometry: [.polyline(path: path)],
            transform: .identity)
    }

    func testReversedPolylineDuplicatesRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        let pts = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 5, y: 0, z: 0), Vector3(x: 5, y: 5, z: 0)]
        document.addEntity(polyline(pts, layer: zid))
        document.addEntity(polyline(pts.reversed(), layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testPolylineDuplicateVertexCollapsed() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(polyline(
            [Vector3(x: 0, y: 0, z: 0), Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.optimizedPolylines, 1)
        XCTAssertEqual(document.allEntities.count, 1)
        let survivor = try! XCTUnwrap(document.allEntities.first)
        if case .polyline(let path, _) = survivor.localGeometry?.first {
            XCTAssertEqual(path.vertices.count, 2)
        } else {
            XCTFail("expected a polyline survivor")
        }
    }

    func testKeepPolylinesIntactSkipsOptimization() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(polyline(
            [Vector3(x: 0, y: 0, z: 0), Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            layer: zid))
        var options = OverkillOptions()
        options.keepPolylinesIntact = true
        let report = applyPlan(document, options: options)
        XCTAssertEqual(report.optimizedPolylines, 0)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testStandaloneCoveredByPolylineRemoved() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(polyline(
            [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            layer: zid))
        document.addEntity(line(2, 0, 8, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.cleanedUp, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testPartialCoverageKeptAndCounted() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(polyline(
            [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)],
            layer: zid))
        document.addEntity(line(5, 0, 20, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.cleanedUp, 0)
        XCTAssertEqual(report.skippedPartial, 1)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    // MARK: - Protection

    func testLockedLayerSkipped() {
        let document = makeDocument()
        document.addLayer(Layer(name: "LOCKED", isLocked: true))
        let locked = try! XCTUnwrap(document.findLayer(named: "LOCKED")).handle
        document.addEntity(line(0, 0, 10, 0, layer: locked))
        document.addEntity(line(0, 0, 10, 0, layer: locked))
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(report.skippedLockedFrozen, 2)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testFrozenLayerSkipped() {
        let document = makeDocument()
        document.addLayer(Layer(name: "FROZEN", isFrozen: true))
        let frozen = try! XCTUnwrap(document.findLayer(named: "FROZEN")).handle
        document.addEntity(line(0, 0, 10, 0, layer: frozen))
        let report = applyPlan(document)
        XCTAssertEqual(report.skippedLockedFrozen, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testHiddenLayerSkipped() {
        let document = makeDocument()
        document.addLayer(Layer(name: "HIDDEN", isVisible: false))
        let hidden = try! XCTUnwrap(document.findLayer(named: "HIDDEN")).handle
        document.addEntity(line(0, 0, 10, 0, layer: hidden))
        let report = applyPlan(document)
        XCTAssertEqual(report.skippedHidden, 1)
        XCTAssertEqual(document.allEntities.count, 1)
    }

    func testBlockReferenceSkipped() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(CADEntity(
            layerID: zid, blockID: UUID(),
            localGeometry: nil, transform: .identity))
        let report = applyPlan(document)
        XCTAssertEqual(report.skippedBlock, 1)
    }

    func testAssociativeEntitySkipped() {
        let document = makeDocument()
        let zid = zeroID(document)
        var associative = line(0, 0, 10, 0, layer: zid)
        associative.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
            styleName: "Standard", type: .linearOrRotated, measurement: 10,
            defPoint: Vector3(x: 0, y: 0, z: 0),
            defPoint2: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 2, z: 0)))
        document.addEntity(associative)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        let report = applyPlan(document)
        XCTAssertEqual(report.skippedAssociative, 1)
        // The plain line has no duplicate partner left; nothing removed.
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(document.allEntities.count, 2)
    }

    func testGroupMemberSurvivesAsDuplicate() {
        let document = makeDocument()
        let zid = zeroID(document)
        let first = line(0, 0, 10, 0, layer: zid)
        let second = line(0, 0, 10, 0, layer: zid)
        document.addEntity(first)
        document.addEntity(second)
        document.groups["G"] = CADGroup(name: "G", members: [first.handle])
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 1)
        XCTAssertNotNil(document.entity(for: first.handle), "group member must survive")
        XCTAssertNil(document.entity(for: second.handle))
    }

    // MARK: - Undo

    func testOneUndoRestoresEverything() {
        let document = makeDocument()
        let zid = zeroID(document)
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(0, 0, 10, 0, layer: zid))
        document.addEntity(line(20, 0, 30, 0, layer: zid))
        document.addEntity(line(25, 0, 35, 0, layer: zid))
        XCTAssertEqual(document.allEntities.count, 4)
        let report = applyPlan(document)
        XCTAssertTrue(report.didChange)
        XCTAssertEqual(document.allEntities.count, 2)
        document.undo()
        XCTAssertEqual(document.allEntities.count, 4)
    }

    // MARK: - Scale sanity

    func testTenThousandSeparatedLinesStayUntouched() {
        let document = makeDocument()
        let zid = zeroID(document)
        // Batch insert: single undo snapshot (per-entity addEntity is O(n²)
        // here from snapshotting, which would measure the harness).
        var entities: [CADEntity] = []
        entities.reserveCapacity(10_000)
        for row in 0..<100 {
            for col in 0..<100 {
                let x = Double(col) * 10.0
                let y = Double(row) * 10.0
                entities.append(line(x, y, x + 1, y, layer: zid))
            }
        }
        document.addEntities(entities)
        let report = applyPlan(document)
        XCTAssertEqual(report.deletedDuplicates, 0)
        XCTAssertEqual(report.mergedSources, 0)
        XCTAssertEqual(document.allEntities.count, 10_000)
    }
}
