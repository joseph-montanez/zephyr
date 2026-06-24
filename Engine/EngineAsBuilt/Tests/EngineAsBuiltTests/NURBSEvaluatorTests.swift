import XCTest
@testable import EngineAsBuiltCore

final class NURBSEvaluatorTests: XCTestCase {
    func testEvaluateIncludesClosedUpperEndpoint() {
        let controlPoints = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 2, z: 0),
            Vector3(x: 3, y: 2, z: 0),
            Vector3(x: 4, y: 0, z: 0),
        ]
        let knots = [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]

        let points = NURBSEvaluator.evaluate(
            degree: 3,
            knots: knots,
            controlPoints: controlPoints,
            segments: 48)

        XCTAssertEqual(points.count, 49)
        XCTAssertEqual(points.first!.x, 0, accuracy: 1e-12)
        XCTAssertEqual(points.first!.y, 0, accuracy: 1e-12)
        XCTAssertEqual(points.last!.x, 4, accuracy: 1e-12)
        XCTAssertEqual(points.last!.y, 0, accuracy: 1e-12)
    }

    func testEvaluateAtClosedUpperEndpoint() {
        let controlPoints = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 2, y: 3, z: 0),
            Vector3(x: 4, y: 0, z: 0),
        ]
        let knots = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]

        let endpoint = NURBSEvaluator.evaluateAt(
            degree: 2,
            knots: knots,
            controlPoints: controlPoints,
            at: 1)

        XCTAssertNotNil(endpoint)
        XCTAssertEqual(endpoint!.x, 4, accuracy: 1e-12)
        XCTAssertEqual(endpoint!.y, 0, accuracy: 1e-12)
    }

    func testMalformedKnotVectorIsRejected() {
        let controlPoints = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 1, z: 0),
            Vector3(x: 2, y: 0, z: 0),
        ]

        XCTAssertTrue(NURBSEvaluator.evaluate(
            degree: 2,
            knots: [0, 0, 0, 1, 1],
            controlPoints: controlPoints).isEmpty)
        XCTAssertNil(NURBSEvaluator.evaluateAt(
            degree: 2,
            knots: [0, 0, 0, 1, 1],
            controlPoints: controlPoints,
            at: 1))
    }
}
