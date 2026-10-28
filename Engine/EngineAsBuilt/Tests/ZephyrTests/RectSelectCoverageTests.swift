import XCTest
@testable import ZephyrCore

/// Box-selection coverage: window (left-to-right) selects fully enclosed
/// entities; crossing (right-to-left) also selects boundary-crossing ones.
/// Every entity drawn inside the box must be selected in both styles.
@MainActor
final class RectSelectCoverageTests: XCTestCase {

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADPrimitive {
        .line(start: Vector3(x: x1, y: y1, z: 0), end: Vector3(x: x2, y: y2, z: 0), color: nil)
    }

    private func fixture() -> (doc: CADDocument, handles: [String: UUID]) {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let block = CADBlock(
            name: "Box",
            geometry: [line(0, 0, 1, 1)])
        let entities = [
            ("insideLine", CADEntity(
                layerID: layer.handle,
                localGeometry: [line(2, 2, 4, 3)],
                transform: .identity)),
            ("crossingLine", CADEntity(
                layerID: layer.handle,
                localGeometry: [line(8, 8, 12, 9)],
                transform: .identity)),
            ("outsideLine", CADEntity(
                layerID: layer.handle,
                localGeometry: [line(20, 20, 21, 21)],
                transform: .identity)),
            ("insidePoly", CADEntity(
                layerID: layer.handle,
                localGeometry: [.polyline(
                    path: CADPolyline(
                        points: [Vector3(x: 2, y: 6, z: 0), Vector3(x: 4, y: 6, z: 0), Vector3(x: 3, y: 7.5, z: 0)],
                        isClosed: true),
                    color: nil)],
                transform: .identity)),
            ("insideText", CADEntity(
                layerID: layer.handle,
                localGeometry: [.text(
                    position: Vector3(x: 5, y: 5, z: 0), text: "AB", height: 1,
                    rotation: 0, style: nil, alignH: 0, alignV: 0,
                    mtextWidth: nil, color: nil)],
                transform: .identity)),
            ("insideImage", CADEntity(
                layerID: layer.handle,
                localGeometry: [.image(
                    insertion: Vector3(x: 5, y: 2, z: 0),
                    uAxis: Vector3(x: 1, y: 0, z: 0),
                    vAxis: Vector3(x: 0, y: 1, z: 0),
                    imageName: "box-test")],
                transform: .identity)),
            ("insideBlock", CADEntity(
                layerID: layer.handle, blockID: block.handle,
                transform: .translated(by: Vector3(x: 6, y: 6, z: 0)))),
            ("insideCircle", CADEntity(
                layerID: layer.handle,
                localGeometry: [.circle(center: Vector3(x: 3, y: 8, z: 0), radius: 0.5)],
                transform: .identity)),
        ]
        doc.importLayersBlocksEntities(
            layers: [layer], blocks: [block],
            entities: entities.map(\.1))
        var handles: [String: UUID] = [:]
        for (name, entity) in entities { handles[name] = entity.handle }
        return (doc, handles)
    }

    func testWindowSelectsEverythingFullyEnclosed() {
        let (doc, handles) = fixture()
        let selected = CADRectSelect.handlesInRect(
            worldX: 1, worldY: 1, worldW: 8, worldH: 8,
            document: doc, style: .window)
        for name in ["insideLine", "insidePoly", "insideText", "insideImage", "insideBlock", "insideCircle"] {
            XCTAssertTrue(selected.contains(handles[name]!), "\(name) fully inside the window must be selected")
        }
        XCTAssertFalse(selected.contains(handles["crossingLine"]!))
        XCTAssertFalse(selected.contains(handles["outsideLine"]!))
    }

    func testCommitRectDirectionAndNormalization() {
        // Left-to-right drags commit as window selection; right-to-left as
        // crossing. Coordinates normalize regardless of drag direction.
        let window = CADRectSelect.commitRect(
            startX: 1, startY: 2, currentX: 9, currentY: 8,
            screenStartX: 100, screenX: 500)
        XCTAssertEqual(window?.style, .window)
        XCTAssertEqual(window?.minX, 1)
        XCTAssertEqual(window?.minY, 2)
        XCTAssertEqual(window?.worldW, 8)
        XCTAssertEqual(window?.worldH, 6)

        let crossing = CADRectSelect.commitRect(
            startX: 9, startY: 8, currentX: 1, currentY: 2,
            screenStartX: 500, screenX: 100)
        XCTAssertEqual(crossing?.style, .crossing)
        XCTAssertEqual(crossing?.minX, 1)
        XCTAssertEqual(crossing?.minY, 2)
        XCTAssertEqual(crossing?.worldW, 8)
        XCTAssertEqual(crossing?.worldH, 6)

        // Zero-size commits are ignored so plain clicks and the two-click
        // rect flow keep working.
        XCTAssertNil(CADRectSelect.commitRect(
            startX: 5, startY: 5, currentX: 5, currentY: 5,
            screenStartX: 100, screenX: 100))
    }

    func testCrossingSelectsEnclosedAndBoundaryCrossing() {
        let (doc, handles) = fixture()
        let selected = CADRectSelect.handlesInRect(
            worldX: 1, worldY: 1, worldW: 8, worldH: 8,
            document: doc, style: .crossing)
        for name in ["insideLine", "insidePoly", "insideText", "insideImage", "insideBlock", "insideCircle", "crossingLine"] {
            XCTAssertTrue(selected.contains(handles[name]!), "\(name) must be selected by crossing")
        }
        XCTAssertFalse(selected.contains(handles["outsideLine"]!))
    }

    func testPreviewCacheReusesSameRectAndRevision() {
        // Per-frame preview during a drag must not re-walk the document
        // when neither the rect nor the document changed.
        let (doc, _) = fixture()
        let interaction = EngineInteractionManager()
        let rev = doc.renderRevision
        var computes = 0
        func query() -> Set<UUID> {
            interaction.rectPreviewHandles(
                minX: 1, minY: 1, maxX: 9, maxY: 9, revision: rev) {
                    computes += 1
                    return CADRectSelect.handlesInRect(
                        worldX: 1, worldY: 1, worldW: 8, worldH: 8,
                        document: doc, style: .window)
                }
        }
        let first = query()
        let second = query()
        XCTAssertEqual(computes, 1, "same rect+revision must compute once")
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testPreviewCacheInvalidatesOnRectOrRevisionChange() {
        let (doc, _) = fixture()
        let interaction = EngineInteractionManager()
        let rev = doc.renderRevision
        var computes = 0
        func query(minX: Double, maxX: Double, revision: UInt64) -> Set<UUID> {
            interaction.rectPreviewHandles(
                minX: minX, minY: 1, maxX: maxX, maxY: 9, revision: revision) {
                    computes += 1
                    return CADRectSelect.handlesInRect(
                        worldX: minX, worldY: 1, worldW: maxX - minX, worldH: 8,
                        document: doc, style: .window)
                }
        }
        let base = query(minX: 1, maxX: 9, revision: rev)
        XCTAssertEqual(computes, 1)
        // Moved cursor: rect changed, must recompute.
        let grown = query(minX: 0, maxX: 9, revision: rev)
        XCTAssertEqual(computes, 2)
        XCTAssertTrue(grown.isSuperset(of: base))
        // Same rect again: cached.
        _ = query(minX: 0, maxX: 9, revision: rev)
        XCTAssertEqual(computes, 2)
        // Document edited (revision bumped): must recompute even for
        // the same rect so new/deleted entities are reflected.
        _ = query(minX: 0, maxX: 9, revision: rev &+ 1)
        XCTAssertEqual(computes, 3)
    }
}
