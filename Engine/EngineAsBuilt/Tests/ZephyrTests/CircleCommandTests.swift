import XCTest
@testable import ZephyrCore

@MainActor
final class CircleCommandTests: XCTestCase {

    func v(_ x: Double, _ y: Double) -> Vector3 { Vector3(x: x, y: y, z: 0) }

    // MARK: - CircleMath

    func testCircleMathTwoPoints() {
        let solved = CircleMath.circleFromTwoPoints(v(0, 0), v(4, 0))
        XCTAssertEqual(solved.center.x, 2, accuracy: 1e-9)
        XCTAssertEqual(solved.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(solved.radius, 2, accuracy: 1e-9)
    }

    func testCircleMathRadiusFromDiameter() {
        XCTAssertEqual(CircleMath.radiusFromDiameter(10), 5, accuracy: 1e-9)
    }

    func testCircleMathRadiusFromPickIsCircumference() {
        let r = CircleMath.radiusFromPick(center: v(0,0), pick: v(3,4))
        XCTAssertEqual(r, 5, accuracy: 1e-9)
    }

    // MARK: - CircleSettings / CIRCLERAD

    func testCircleSettingsRoundTrip() {
        let old = CircleSettings.lastRadius
        defer { CircleSettings.lastRadius = old }
        CircleSettings.lastRadius = 7.5
        XCTAssertEqual(CircleSettings.lastRadius ?? 0, 7.5, accuracy: 1e-12)
        CircleSettings.lastRadius = nil
        XCTAssertNil(CircleSettings.lastRadius)
        CircleSettings.lastRadius = 0
        XCTAssertNil(CircleSettings.lastRadius)
        CircleSettings.lastRadius = -5
        XCTAssertNil(CircleSettings.lastRadius)
    }

    // MARK: - Numeric expression evaluator

    func testNumericExpressionEvaluator() {
        XCTAssertEqual(NumericExpressionEvaluator.evaluate("2*3+1") ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(NumericExpressionEvaluator.evaluate("(10+2)/2") ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(NumericExpressionEvaluator.evaluate(" 5 ") ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(NumericExpressionEvaluator.evaluate("-3") ?? 0, -3, accuracy: 1e-9)
        XCTAssertNil(NumericExpressionEvaluator.evaluate("foo"))
        XCTAssertNil(NumericExpressionEvaluator.evaluate(""))
        XCTAssertNil(NumericExpressionEvaluator.evaluate("2**3"))
    }

    // MARK: - TangentCircleSolver TTR

    func testTTRCrossingLines() {
        let l1 = TangentSupport2.line(origin: v(0, 0), directionUnit: v(1, 0))
        let l2 = TangentSupport2.line(origin: v(5, 0), directionUnit: v(0, 1))
        let c = TangentCircleSolver.circlesTangentTo(radius: 2, first: l1, second: l2, nearPicks: [v(5,2)])
        XCTAssertFalse(c.isEmpty)
        // candidate center should be 2 units away from both lines (infinite)
        for center in c {
            let d1 = abs(center.y - 0)
            XCTAssertEqual(d1, 2, accuracy: 1e-6)
            let d2 = abs(center.x - 5)
            XCTAssertEqual(d2, 2, accuracy: 1e-6)
        }
    }

    func testTTRParallelLines() {
        let l1 = TangentSupport2.line(origin: v(0, 0), directionUnit: v(1, 0))
        let l2 = TangentSupport2.line(origin: v(0, 4), directionUnit: v(1, 0))
        // r = 2 fits between them (distance 4)
        let c = TangentCircleSolver.circlesTangentTo(radius: 2, first: l1, second: l2, nearPicks: [v(3,2)])
        XCTAssertFalse(c.isEmpty)
        XCTAssertEqual(c[0].y, 2, accuracy: 1e-6)
        // r = 1 does not fit
        let none = TangentCircleSolver.circlesTangentTo(radius: 1, first: l1, second: l2)
        XCTAssertTrue(none.isEmpty)
    }

    func testTTRLineCircle() {
        let line = TangentSupport2.line(origin: v(0, 0), directionUnit: v(1, 0))
        let circle = TangentSupport2.circle(center: v(5, 3), radius: 2)
        let cands = TangentCircleSolver.circlesTangentTo(radius: 1, first: line, second: circle, nearPicks: [v(5,1)])
        XCTAssertFalse(cands.isEmpty, "Line y=0 and circle r=2 at (5,3) should have r=1 tangent candidates")
        // distance from candidate center to line = 1 and to circle = 1 +/- 2
        for c in cands {
            let dLine = abs(c.y)
            XCTAssertEqual(dLine, 1, accuracy: 1e-6)
            let dCirc = hypot(c.x - 5, c.y - 3)
            XCTAssertTrue(abs(dCirc - (2+1)) < 1e-6 || abs(dCirc - abs(2-1)) < 1e-6, "dCirc \(dCirc)")
        }
    }

    func testTTRCircleCircle() {
        let c1 = TangentSupport2.circle(center: v(0,0), radius: 2)
        let c2 = TangentSupport2.circle(center: v(6,0), radius: 2)
        let cands = TangentCircleSolver.circlesTangentTo(radius: 1, first: c1, second: c2)
        XCTAssertFalse(cands.isEmpty)
    }

    // MARK: - Finite validation

    func testFiniteSegmentValidation() {
        let finite = FiniteTangentSupport(
            infinite: .line(origin: v(0,0), directionUnit: v(1,0)),
            shape: .segment(start: v(0,0), end: v(10,0))
        )
        XCTAssertTrue(finite.containsTangentPoint(v(5,0)))
        XCTAssertFalse(finite.containsTangentPoint(v(15,0)))
        XCTAssertFalse(finite.containsTangentPoint(v(-1,0)))
    }

    func testFiniteCircleValidation() {
        let finite = FiniteTangentSupport(
            infinite: .circle(center: v(5,5), radius: 2),
            shape: .fullCircle
        )
        XCTAssertTrue(finite.containsTangentPoint(v(5,7)))
    }

    // MARK: - Tan Tan Tan

    func testTTTThreeLines() {
        let l1 = TangentSupport2.line(origin: v(0,0), directionUnit: v(1,0)) // y=0
        let l2 = TangentSupport2.line(origin: v(10,0), directionUnit: v(0,1)) // x=10
        let l3 = TangentSupport2.line(origin: v(0,20), directionUnit: v(1,-1)) // x+y=20
        // Normalize direction for diagonal
        let norm = hypot(1.0, -1.0)
        let l3n = TangentSupport2.line(origin: v(0,20), directionUnit: v(1/norm, -1/norm))
        guard let solved = TangentCircleSolver.circleTangentToThree(l1, l2, l3n, nearPicks: [v(7,3)]) else {
            return XCTFail("TTT three lines should solve")
        }
        // Radius should be tangent to all three (infinite)
        let dLine = abs(solved.center.y)
        XCTAssertEqual(dLine, solved.radius, accuracy: 1e-5)
        let dLine2 = abs(solved.center.x - 10)
        XCTAssertEqual(dLine2, solved.radius, accuracy: 1e-5)
        // diagonal x+y=20 distance |x+y-20|/sqrt2
        let d3 = abs(solved.center.x + solved.center.y - 20) / hypot(1,1)
        XCTAssertEqual(d3, solved.radius, accuracy: 1e-5)
        XCTAssertGreaterThan(solved.radius, 0)
    }
}
