import XCTest
@testable import ZephyrCore

/// Lasso (press-and-drag) selection: left-to-right selects only fully
/// enclosed entities; right-to-left also selects boundary-crossing ones.
/// Mirrors `RectSelectCoverageTests` for the freeform polygon path.
@MainActor
final class LassoSelectTests: XCTestCase {

    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CADPrimitive {
        .line(start: Vector3(x: x1, y: y1, z: 0), end: Vector3(x: x2, y: y2, z: 0), color: nil)
    }

    private func vec(_ x: Double, _ y: Double) -> Vector3 { Vector3(x: x, y: y, z: 0) }

    private func fixture() -> (doc: CADDocument, handles: [String: UUID]) {
        let doc = CADDocument()
        let layer = Layer(name: "0")
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
            ("insideCircle", CADEntity(
                layerID: layer.handle,
                localGeometry: [.circle(center: Vector3(x: 3, y: 8, z: 0), radius: 0.5)],
                transform: .identity)),
        ]
        doc.importLayersBlocksEntities(
            layers: [layer], blocks: [],
            entities: entities.map(\.1))
        var handles: [String: UUID] = [:]
        for (name, entity) in entities { handles[name] = entity.handle }
        return (doc, handles)
    }

    /// Square lasso covering (1,1)-(10,10).
    private var squareLasso: [Vector3] { [vec(1, 1), vec(10, 1), vec(10, 10), vec(1, 10)] }

    func testDragDirectionStyle() {
        XCTAssertEqual(CADSelectionManager.styleForDrag(startScreenX: 10, currentScreenX: 50), .window)
        XCTAssertEqual(CADSelectionManager.styleForDrag(startScreenX: 10, currentScreenX: 10), .window)
        XCTAssertEqual(CADSelectionManager.styleForDrag(startScreenX: 50, currentScreenX: 10), .crossing)
    }

    func testLassoWindowSelectsOnlyEnclosed() {
        let (doc, handles) = fixture()
        let hits = CADLassoSelect.handlesInPolygon(
            worldPoints: squareLasso, document: doc, style: .window)
        XCTAssertTrue(hits.contains(handles["insideLine"]!))
        XCTAssertTrue(hits.contains(handles["insideCircle"]!))
        XCTAssertFalse(hits.contains(handles["crossingLine"]!))
        XCTAssertFalse(hits.contains(handles["outsideLine"]!))
    }

    func testLassoCrossingSelectsTouched() {
        let (doc, handles) = fixture()
        let hits = CADLassoSelect.handlesInPolygon(
            worldPoints: squareLasso, document: doc, style: .crossing)
        XCTAssertTrue(hits.contains(handles["insideLine"]!))
        XCTAssertTrue(hits.contains(handles["crossingLine"]!))
        XCTAssertFalse(hits.contains(handles["outsideLine"]!))
    }

    func testLassoFollowsFreeformPath() {
        let (doc, handles) = fixture()
        // Right-pointing triangle: insideLine (y≈2..3, x 2..4) is inside;
        // insideCircle at (3,8) is outside the path but inside its bbox.
        let triangle = [vec(1, 1), vec(10, 5), vec(1, 5.5)]
        let windowHits = CADLassoSelect.handlesInPolygon(
            worldPoints: triangle, document: doc, style: .window)
        XCTAssertTrue(windowHits.contains(handles["insideLine"]!))
        XCTAssertFalse(windowHits.contains(handles["insideCircle"]!))
    }

    func testDegenerateLassoSelectsNothing() {
        let (doc, _) = fixture()
        XCTAssertTrue(CADLassoSelect.handlesInPolygon(
            worldPoints: [vec(1, 1), vec(2, 2)], document: doc, style: .crossing).isEmpty)
        var selection: Set<UUID> = []
        CADLassoSelect.selectInPolygon(
            worldPoints: [], document: doc, mode: .add, style: .crossing, into: &selection)
        XCTAssertTrue(selection.isEmpty)
    }

    func testRubberBandColorsMatchAutoCAD() {
        func check(_ mode: CADSelectionManager.RectSelectMode,
                   _ style: CADSelectionManager.RectSelectStyle,
                   _ expected: [UInt8]) {
            let c = CADSelectionManager.rubberBandColor(mode: mode, style: style)
            XCTAssertEqual([c.0, c.1, c.2, c.3], expected)
        }
        check(.add, .window, [0, 128, 255, 255])
        check(.replace, .window, [0, 128, 255, 255])
        check(.add, .crossing, [0, 190, 90, 255])
        check(.subtract, .window, [255, 80, 80, 255])
        check(.subtract, .crossing, [255, 80, 80, 255])
    }
}
