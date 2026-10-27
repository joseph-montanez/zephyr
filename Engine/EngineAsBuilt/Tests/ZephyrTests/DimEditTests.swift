import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 DIMEDIT/DIMTEDIT: pure text-placement edits over stored
/// definition points, the obliquing direction helper, and the DXF group 52
/// import mapping. (Command collect/option/value flow mirrors DDEDIT pick
/// plus ArrayCommand text handling; persistence mirrors PropertiesPanel.)
final class DimEditTests: XCTestCase {

    private func linearMetadata(
        textMidpoint: Vector3 = Vector3(x: 5, y: 5, z: 0)
    ) -> CADDimensionMetadata {
        CADDimensionMetadata(
            type: .linearOrRotated,
            measurement: 10,
            defPoint: Vector3(x: 0, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: textMidpoint,
            rotationAngle: 0)
    }

    private func angularMetadata() -> CADDimensionMetadata {
        CADDimensionMetadata(
            type: .angular,
            measurement: 1.2,
            defPoint: Vector3(x: 5, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            defPoint4: Vector3(x: 0, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 6, z: 0),
            rotationAngle: 0)
    }

    private func lineDirection(_ prim: CADPrimitive) -> Vector3? {
        guard case .line(let start, let end, _) = prim else { return nil }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return nil }
        return Vector3(x: dx / len, y: dy / len, z: 0)
    }

    // MARK: - extensionLines oblique

    func testNilObliqueStaysPerpendicular() {
        let style = CADDimensionStyle.default
        let prims = DimensionPrimitives.extensionLines(
            feature1: Vector3(x: 0, y: 0, z: 0),
            feature2: Vector3(x: 10, y: 0, z: 0),
            dimLineStart: Vector3(x: 0, y: 5, z: 0),
            dimLineEnd: Vector3(x: 10, y: 5, z: 0),
            style: style, color: .white, obliqueAngle: nil)
        XCTAssertEqual(prims.count, 2)
        for prim in prims {
            let dir = try! XCTUnwrap(lineDirection(prim))
            XCTAssertEqual(dir.x, 0, accuracy: 1e-9)
            XCTAssertEqual(dir.y, 1, accuracy: 1e-9)
        }
    }

    func testObliqueSlantsBothLinesInParallel() {
        let style = CADDimensionStyle.default
        let phi = Double.pi / 4
        let prims = DimensionPrimitives.extensionLines(
            feature1: Vector3(x: 0, y: 0, z: 0),
            feature2: Vector3(x: 10, y: 0, z: 0),
            dimLineStart: Vector3(x: 0, y: 5, z: 0),
            dimLineEnd: Vector3(x: 10, y: 5, z: 0),
            style: style, color: .white, obliqueAngle: phi)
        XCTAssertEqual(prims.count, 2)
        // The start->end segment is NOT parallel to the slant (offset and
        // extend differ), so assert exact endpoints along the slanted ray.
        let ex = cos(phi), ey = sin(phi)
        let expected = [
            (Vector3(x: ex * style.extensionLineOffset, y: ey * style.extensionLineOffset, z: 0),
             Vector3(x: ex * style.extensionLineExtend, y: 5 + ey * style.extensionLineExtend, z: 0)),
            (Vector3(x: 10 + ex * style.extensionLineOffset, y: ey * style.extensionLineOffset, z: 0),
             Vector3(x: 10 + ex * style.extensionLineExtend, y: 5 + ey * style.extensionLineExtend, z: 0)),
        ]
        for (prim, ends) in zip(prims, expected) {
            guard case .line(let start, let end, _) = prim else {
                XCTFail("expected lines")
                continue
            }
            XCTAssertEqual(start.x, ends.0.x, accuracy: 1e-9)
            XCTAssertEqual(start.y, ends.0.y, accuracy: 1e-9)
            XCTAssertEqual(end.x, ends.1.x, accuracy: 1e-9)
            XCTAssertEqual(end.y, ends.1.y, accuracy: 1e-9)
        }
    }

    func testRightAngleObliqueMatchesNil() {
        let style = CADDimensionStyle.default
        let args = (
            feature1: Vector3(x: 0, y: 0, z: 0),
            feature2: Vector3(x: 10, y: 0, z: 0),
            dimLineStart: Vector3(x: 0, y: 5, z: 0),
            dimLineEnd: Vector3(x: 10, y: 5, z: 0))
        let plain = DimensionPrimitives.extensionLines(
            feature1: args.feature1, feature2: args.feature2,
            dimLineStart: args.dimLineStart, dimLineEnd: args.dimLineEnd,
            style: style, color: .white, obliqueAngle: nil)
        let right = DimensionPrimitives.extensionLines(
            feature1: args.feature1, feature2: args.feature2,
            dimLineStart: args.dimLineStart, dimLineEnd: args.dimLineEnd,
            style: style, color: .white, obliqueAngle: .pi / 2)
        XCTAssertEqual(plain.count, right.count)
        for (a, b) in zip(plain, right) {
            guard case .line(let a0, let a1, _) = a,
                  case .line(let b0, let b1, _) = b else {
                XCTFail("expected lines")
                continue
            }
            XCTAssertEqual(a0.x, b0.x, accuracy: 1e-9)
            XCTAssertEqual(a0.y, b0.y, accuracy: 1e-9)
            XCTAssertEqual(a1.x, b1.x, accuracy: 1e-9)
            XCTAssertEqual(a1.y, b1.y, accuracy: 1e-9)
        }
    }

    // MARK: - Home / justification

    func testHomeRestoresMidpointAndReadableRotation() {
        var meta = linearMetadata(textMidpoint: Vector3(x: 9, y: 7, z: 0))
        meta.textRotationAngle = 0.5
        let home = try! XCTUnwrap(DimEditCommand.homed(meta))
        XCTAssertEqual(home.textMidpoint.x, 5, accuracy: 1e-9)
        XCTAssertEqual(home.textMidpoint.y, 5, accuracy: 1e-9)
        XCTAssertNil(home.textRotationAngle)
        XCTAssertEqual(home.measurement, 10, accuracy: 1e-9)
    }

    func testHomeRejectsAngular() {
        XCTAssertNil(DimEditCommand.homed(angularMetadata()))
    }

    func testJustifyLeftRightCenter() {
        let meta = linearMetadata()
        let left = try! XCTUnwrap(DimEditCommand.justified(meta, .left))
        XCTAssertEqual(left.textMidpoint.x, 0, accuracy: 1e-9)
        XCTAssertEqual(left.textMidpoint.y, 5, accuracy: 1e-9)
        let right = try! XCTUnwrap(DimEditCommand.justified(meta, .right))
        XCTAssertEqual(right.textMidpoint.x, 10, accuracy: 1e-9)
        XCTAssertEqual(right.textMidpoint.y, 5, accuracy: 1e-9)
        let center = try! XCTUnwrap(DimEditCommand.justified(meta, .center))
        XCTAssertEqual(center.textMidpoint.x, 5, accuracy: 1e-9)
        XCTAssertNil(DimEditCommand.justified(angularMetadata(), .left))
    }

    // MARK: - Text / rotation / oblique setters

    func testWithTextSetsOverride() {
        let next = DimEditCommand.withText(linearMetadata(), "HELLO")
        XCTAssertEqual(next.textOverride, "HELLO")
    }

    func testWithTextRotationSetsAngle() {
        let next = DimEditCommand.withTextRotation(linearMetadata(), radians: 0.25)
        XCTAssertEqual(next.textRotationAngle, 0.25)
    }

    func testWithObliqueStoresAndClears() {
        let slanted = try! XCTUnwrap(DimEditCommand.withOblique(linearMetadata(), radians: .pi / 4))
        XCTAssertEqual(slanted.obliqueAngle, .pi / 4)
        let cleared = try! XCTUnwrap(DimEditCommand.withOblique(slanted, radians: .pi / 2))
        XCTAssertNil(cleared.obliqueAngle)
        XCTAssertNil(DimEditCommand.withOblique(angularMetadata(), radians: .pi / 4))
    }

    func testParseAngleDegrees() {
        XCTAssertEqual(DimEditCommand.parseAngleDegrees("45"), 45)
        XCTAssertEqual(DimEditCommand.parseAngleDegrees(" -30.5 "), -30.5)
        XCTAssertNil(DimEditCommand.parseAngleDegrees(""))
        XCTAssertNil(DimEditCommand.parseAngleDegrees("abc"))
        XCTAssertNil(DimEditCommand.parseAngleDegrees("nan"))
    }

    // MARK: - DXF group 52 import mapping

    func testDimensionObliqueAngleMapping() {
        XCTAssertNil(DXFImporter.dimensionObliqueAngle(0))
        XCTAssertNil(DXFImporter.dimensionObliqueAngle(90))
        XCTAssertEqual(try! XCTUnwrap(DXFImporter.dimensionObliqueAngle(45)), -.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(try! XCTUnwrap(DXFImporter.dimensionObliqueAngle(135)), -3 * .pi / 4, accuracy: 1e-12)
    }
}
