import XCTest
@testable import ZephyrCore

/// Regression tests for the endpoint-snap arbitration in computeSnap.
///
/// The discrete anchor/intersection pass runs once per mouse-motion; these
/// tests pin how that result combines with the extension/on-curve fallbacks
/// and the active command's in-progress drawing points, so a performance
/// refactor can never again silently drop endpoint/midpoint/center/
/// intersection snaps (fresh LINE chaining off an old endpoint).
@MainActor
final class SnapArbitrationTests: XCTestCase {

    private func snap(_ x: Double, _ y: Double, anchor: ZephyrCore.AnchorPoint) -> SnapResult {
        SnapResult(
            entityHandle: UUID(),
            anchor: anchor,
            worldPos: Vector3(x: x, y: y, z: 0))
    }

    private func vertex(_ x: Double, _ y: Double) -> SnapResult {
        snap(x, y, anchor: .vertex(localPosition: Vector3(x: x, y: y, z: 0), index: 0))
    }

    // MARK: - seedDiscrete

    /// The reported bug: a fresh LINE aimed at an old line's endpoint must
    /// keep the discrete vertex the first pass found.
    func testSeedsDiscreteVertexWhenNothingSet() {
        let end = vertex(10, 0)
        let seeded = SnapArbitration.seedDiscrete(current: nil, discrete: end)
        XCTAssertEqual(seeded, end)
    }

    /// Intersection snaps are discrete targets too, not transient points.
    func testSeedsIntersectionAnchor() {
        let cross = snap(5, 5, anchor: .intersection(
            localPosition: Vector3(x: 5, y: 5, z: 0)))
        XCTAssertEqual(SnapArbitration.seedDiscrete(current: nil, discrete: cross), cross)
    }

    func testSeedsMidpointCenterQuadrant() {
        let mid = snap(5, 0, anchor: .midpoint(
            localPosition: Vector3(x: 5, y: 0, z: 0), segmentIndex: 0))
        let center = snap(0, 0, anchor: .center(localPosition: Vector3(x: 0, y: 0, z: 0)))
        let quad = snap(2, 0, anchor: .quadrant(localPosition: Vector3(x: 2, y: 0, z: 0), index: 0))
        XCTAssertEqual(SnapArbitration.seedDiscrete(current: nil, discrete: mid), mid)
        XCTAssertEqual(SnapArbitration.seedDiscrete(current: nil, discrete: center), center)
        XCTAssertEqual(SnapArbitration.seedDiscrete(current: nil, discrete: quad), quad)
    }

    /// A tracking/polar winner must never be overwritten by the seed.
    func testKeepsExistingSnapOverSeed() {
        let tracking = vertex(3, 4)
        let end = vertex(10, 0)
        XCTAssertEqual(SnapArbitration.seedDiscrete(current: tracking, discrete: end), tracking)
    }

    /// A transient narrow-extension/on-curve `.nearest` is not seeded: the
    /// wide fallback re-evaluates those stages.
    func testIgnoresTransientNearestDiscrete() {
        let near = snap(10.9, 0, anchor: .nearest(
            localPosition: Vector3(x: 10.9, y: 0, z: 0)))
        XCTAssertNil(SnapArbitration.seedDiscrete(current: nil, discrete: near))
    }

    func testNilDiscreteStaysNil() {
        XCTAssertNil(SnapArbitration.seedDiscrete(current: nil, discrete: nil))
    }

    // MARK: - competeDrawingPoints

    /// A chained in-progress vertex closer than the seed wins (second point
    /// of a LINE being drawn), reproducing computeSnap's priority.
    func testCloserDrawingVertexBeatsSeed() {
        let seed = vertex(10, 0)
        let drawing = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 4, y: 0.2, z: 0)]
        // Cursor at (4.1, 0.2): drawing vertex is ~0.1 away, seed ~5.9 away.
        let winner = SnapArbitration.competeDrawingPoints(
            drawing, best: seed, bestDist: 5.9, cursorX: 4.1, cursorY: 0.2)
        XCTAssertEqual(winner?.worldPos, Vector3(x: 4, y: 0.2, z: 0))
        guard let got = winner else {
            XCTFail("expected the drawing vertex to win")
            return
        }
        guard case let .vertex(_, index) = got.anchor else {
            XCTFail("expected the drawing vertex to win")
            return
        }
        XCTAssertEqual(index, 1)
    }

    /// Ties keep the entity snap: a drawing point exactly on the endpoint
    /// must not steal it.
    func testTieKeepsSeed() {
        let seed = vertex(10, 0)
        let drawing = [Vector3(x: 10, y: 0, z: 0)]
        let winner = SnapArbitration.competeDrawingPoints(
            drawing, best: seed, bestDist: 0.0, cursorX: 10, cursorY: 0)
        XCTAssertEqual(winner, seed)
    }

    /// A closer in-progress midpoint wins over a farther seed.
    func testCloserDrawingMidpointBeatsSeed() {
        let seed = vertex(10, 0)
        let drawing = [Vector3(x: 0, y: 4, z: 0), Vector3(x: 4, y: 4, z: 0)]
        // Cursor at (2, 4.1): midpoint (2,4) is 0.1 away, seed ~8.9 away.
        let winner = SnapArbitration.competeDrawingPoints(
            drawing, best: seed, bestDist: 8.9, cursorX: 2, cursorY: 4.1)
        XCTAssertEqual(winner?.worldPos, Vector3(x: 2, y: 4, z: 0))
        guard let got = winner else {
            XCTFail("expected the drawing midpoint to win")
            return
        }
        guard case let .midpoint(_, segmentIndex) = got.anchor else {
            XCTFail("expected the drawing midpoint to win")
            return
        }
        XCTAssertEqual(segmentIndex, 0)
    }

    /// No drawing points: the seed stands (fresh LINE, first click).
    func testEmptyDrawingPointsKeepsSeed() {
        let seed = vertex(10, 0)
        let winner = SnapArbitration.competeDrawingPoints(
            [], best: seed, bestDist: 0.5, cursorX: 10.1, cursorY: 0.1)
        XCTAssertEqual(winner, seed)
    }
}
