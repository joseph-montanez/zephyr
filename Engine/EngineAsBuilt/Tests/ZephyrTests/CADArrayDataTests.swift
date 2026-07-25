import XCTest
@testable import ZephyrCore

final class CADArrayDataTests: XCTestCase {
    func testRectangularTransforms() {
        let array = CADArrayData.rectangular(
            columns: 3,
            rows: 2,
            columnSpacing: 5,
            rowSpacing: 7)
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 6)
        XCTAssertEqual(instances[2].transform.position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(instances[3].transform.position.y, 7, accuracy: 1e-9)
    }

    func testFullCirclePolarDoesNotDuplicateEndpoint() {
        let array = CADArrayData.polar(
            itemCount: 4,
            centerPoint: Vector3(x: -10, y: 0, z: 0))
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 4)
        let first = instances[0].transform.transformPoint(.zero)
        let second = instances[1].transform.transformPoint(.zero)
        XCTAssertEqual(first.x, 0, accuracy: 1e-9)
        XCTAssertEqual(first.y, 0, accuracy: 1e-9)
        XCTAssertEqual(second.x, -10, accuracy: 1e-9)
        XCTAssertEqual(second.y, 10, accuracy: 1e-9)
    }

    func testPathDivideTransforms() {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let instances = array.evaluatedInstances()
        XCTAssertEqual(instances.count, 3)
        XCTAssertEqual(instances[1].transform.position.x, 5, accuracy: 1e-9)
    }

    func testDXFPayloadRoundTrip() throws {
        let array = CADArrayData.path(
            itemCount: 3,
            cachedPath: [
                Vector3(x: 0, y: 0, z: 0),
                Vector3(x: 10, y: 0, z: 0),
            ])
        let payload = CADArrayDXFPayload(
            groupID: UUID(),
            containerTransform: .translated(by: Vector3(x: 2, y: 3, z: 0)),
            data: array)
        let decoded = try XCTUnwrap(CADArrayDXFCodec.decode(CADArrayDXFCodec.encode(payload)))
        XCTAssertEqual(decoded.data, array)
        XCTAssertEqual(try XCTUnwrap(decoded.transform).position.x, 2, accuracy: 1e-9)
    }
}
