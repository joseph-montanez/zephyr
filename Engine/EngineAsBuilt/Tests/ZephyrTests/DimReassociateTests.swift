import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 DIMREASSOCIATE: pure re-point + re-measure over stored
/// definition points via the shared DimChainMath.continueNext path.
/// (Command pick flow mirrors DDEDIT; persistence mirrors PropertiesPanel.)
final class DimReassociateTests: XCTestCase {

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

    // MARK: - isReassociable

    func testLinearAndAlignedAreReassociable() {
        XCTAssertTrue(DimReassociateCommand.isReassociable(linearMetadata()))
        let aligned = CADDimensionMetadata(
            type: .aligned,
            measurement: 10,
            defPoint: Vector3(x: 0, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 5, z: 0),
            rotationAngle: 0)
        XCTAssertTrue(DimReassociateCommand.isReassociable(aligned))
    }

    func testAngularIsNotReassociable() {
        let angular = CADDimensionMetadata(
            type: .angular,
            measurement: 1.2,
            defPoint: Vector3(x: 5, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 6, z: 0),
            rotationAngle: 0)
        XCTAssertFalse(DimReassociateCommand.isReassociable(angular))
        XCTAssertNil(DimReassociateCommand.reassociated(
            angular,
            firstOrigin: Vector3(x: 0, y: 0, z: 0),
            secondOrigin: Vector3(x: 20, y: 0, z: 0)))
    }

    // MARK: - reassociated

    func testLinearRemeasuresFromNewOrigins() {
        let next = try! XCTUnwrap(DimReassociateCommand.reassociated(
            linearMetadata(),
            firstOrigin: Vector3(x: 0, y: 0, z: 0),
            secondOrigin: Vector3(x: 25, y: 0, z: 0)))
        XCTAssertEqual(next.measurement, 25, accuracy: 1e-9)
        XCTAssertEqual(next.defPoint2.x, 0)
        XCTAssertEqual(try! XCTUnwrap(next.defPoint3).x, 25)
        // Dimline position and angle are kept; the text follows the new span.
        XCTAssertEqual(next.defPoint.y, 5)
        XCTAssertEqual(next.rotationAngle, 0)
        XCTAssertEqual(next.textMidpoint.x, 12.5, accuracy: 1e-9)
    }

    func testLinearProjectedMeasurement() {
        // A slanted second pick still measures along the dimline direction.
        let next = try! XCTUnwrap(DimReassociateCommand.reassociated(
            linearMetadata(),
            firstOrigin: Vector3(x: 0, y: 0, z: 0),
            secondOrigin: Vector3(x: 10, y: 7, z: 0)))
        XCTAssertEqual(next.measurement, 10, accuracy: 1e-9)
    }

    func testAlignedUsesFullDistance() {
        let aligned = CADDimensionMetadata(
            type: .aligned,
            measurement: 10,
            defPoint: Vector3(x: 0, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 5, z: 0),
            rotationAngle: 0)
        let next = try! XCTUnwrap(DimReassociateCommand.reassociated(
            aligned,
            firstOrigin: Vector3(x: 0, y: 0, z: 0),
            secondOrigin: Vector3(x: 10, y: 7, z: 0)))
        XCTAssertEqual(next.measurement, hypot(10, 7), accuracy: 1e-9)
    }

    func testCoincidentOriginsReturnNil() {
        XCTAssertNil(DimReassociateCommand.reassociated(
            linearMetadata(),
            firstOrigin: Vector3(x: 4, y: 1, z: 0),
            secondOrigin: Vector3(x: 4, y: 1, z: 0)))
    }

    func testTextOverrideAndStyleSurvive() {
        var meta = linearMetadata()
        meta.textOverride = "KEEP"
        let next = try! XCTUnwrap(DimReassociateCommand.reassociated(
            meta,
            firstOrigin: Vector3(x: 0, y: 0, z: 0),
            secondOrigin: Vector3(x: 30, y: 0, z: 0)))
        XCTAssertEqual(next.textOverride, "KEEP")
        XCTAssertEqual(next.styleName, meta.styleName)
    }
}
