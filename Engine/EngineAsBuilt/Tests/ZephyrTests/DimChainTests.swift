import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 DCO/DBA: pure chaining math over stored dimension definition
/// points. (Command pick/preview/commit flow mirrors DimLinearCommand and
/// ArrayCommand; the geometry assembly reuses DimensionPrimitives.)
final class DimChainTests: XCTestCase {

    private func linearMetadata(
        dimLine: Vector3 = Vector3(x: 0, y: 5, z: 0),
        p1: Vector3 = Vector3(x: 0, y: 0, z: 0),
        p2: Vector3 = Vector3(x: 10, y: 0, z: 0),
        angle: Double = 0
    ) -> CADDimensionMetadata {
        CADDimensionMetadata(
            type: .linearOrRotated,
            measurement: 10,
            defPoint: dimLine,
            defPoint2: p1,
            defPoint3: p2,
            textMidpoint: Vector3(x: 5, y: 5, z: 0),
            rotationAngle: angle)
    }

    // MARK: - resolveSource

    func testResolveLinearSource() {
        let source = try! XCTUnwrap(DimChainMath.resolveSource(
            from: linearMetadata()))
        XCTAssertEqual(source.baseOrigin.x, 0)
        XCTAssertEqual(source.prevOrigin.x, 10)
        XCTAssertEqual(source.dimLinePos.y, 5)
        XCTAssertEqual(source.angle, 0)
        XCTAssertTrue(source.isLinear)
    }

    func testResolveRejectsNonLinearAndDegenerate() {
        var angular = linearMetadata()
        angular = CADDimensionMetadata(
            type: .angular, measurement: 1,
            defPoint: Vector3(x: 0, y: 0, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 1, y: 0, z: 0),
            textMidpoint: Vector3(x: 0, y: 0, z: 0))
        XCTAssertNil(DimChainMath.resolveSource(from: angular))

        let coincident = linearMetadata(p1: Vector3(x: 4, y: 0, z: 0), p2: Vector3(x: 4, y: 0, z: 0))
        XCTAssertNil(DimChainMath.resolveSource(from: coincident))
    }

    // MARK: - continueNext

    func testContinueChainsFromPreviousOrigin() {
        let source = try! XCTUnwrap(DimChainMath.resolveSource(
            from: linearMetadata()))
        let next = try! XCTUnwrap(DimChainMath.continueNext(
            from: source, picked: Vector3(x: 15, y: 7, z: 0)))
        XCTAssertEqual(next.p1.x, 10)
        XCTAssertEqual(next.p2.x, 15)
        // Projected horizontal distance, dimline shared with the source.
        XCTAssertEqual(next.measurement, 5)
        XCTAssertEqual(next.dimLinePos.y, 5)
        XCTAssertEqual(next.dimStart.x, 10)
        XCTAssertEqual(next.dimStart.y, 5)
        XCTAssertEqual(next.dimEnd.x, 15)
        XCTAssertEqual(next.type, .linearOrRotated)
    }

    func testContinueRejectsCoincidentPick() {
        let source = try! XCTUnwrap(DimChainMath.resolveSource(
            from: linearMetadata()))
        XCTAssertNil(DimChainMath.continueNext(
            from: source, picked: Vector3(x: 10, y: 0, z: 0)))
    }

    // MARK: - baselineNext

    func testBaselineMeasuresFromBaseWithStackedDimline() {
        let source = try! XCTUnwrap(DimChainMath.resolveSource(
            from: linearMetadata()))
        let next = try! XCTUnwrap(DimChainMath.baselineNext(
            from: source, picked: Vector3(x: 20, y: 1, z: 0),
            stackIndex: 1, spacing: 3.75))
        XCTAssertEqual(next.p1.x, 0)
        XCTAssertEqual(next.p2.x, 20)
        XCTAssertEqual(next.measurement, 20)
        // Dimline was above the feature, so the stack grows upward.
        XCTAssertEqual(next.dimLinePos.y, 8.75, accuracy: 1e-9)
    }

    func testBaselineStacksAwayFromFeature() {
        let source = try! XCTUnwrap(DimChainMath.resolveSource(from: linearMetadata(
            dimLine: Vector3(x: 0, y: -5, z: 0))))
        let first = try! XCTUnwrap(DimChainMath.baselineNext(
            from: source, picked: Vector3(x: 20, y: 0, z: 0),
            stackIndex: 1, spacing: 3.75))
        XCTAssertEqual(first.dimLinePos.y, -8.75, accuracy: 1e-9)
        let second = try! XCTUnwrap(DimChainMath.baselineNext(
            from: source, picked: Vector3(x: 30, y: 0, z: 0),
            stackIndex: 2, spacing: 3.75))
        XCTAssertEqual(second.dimLinePos.y, -12.5, accuracy: 1e-9)
    }

    // MARK: - aligned

    func testAlignedChainsUseFullDistance() {
        let metadata = CADDimensionMetadata(
            type: .aligned, measurement: 0,
            defPoint: Vector3(x: 0, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 3, y: 4, z: 0),
            textMidpoint: Vector3(x: 0, y: 0, z: 0),
            rotationAngle: atan2(4, 3))
        let source = try! XCTUnwrap(DimChainMath.resolveSource(from: metadata))
        XCTAssertFalse(source.isLinear)
        let next = try! XCTUnwrap(DimChainMath.continueNext(
            from: source, picked: Vector3(x: 6, y: 8, z: 0)))
        XCTAssertEqual(next.measurement, 5)
        XCTAssertEqual(next.type, .aligned)
        XCTAssertEqual(next.angle, atan2(4, 3))
    }
}
