import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 smart DIM: selection/context analysis, result lines, and
/// transfer targets. (The command shell itself only prints and hands off
/// via executeCommand, like the ALIGN/PAN handoffs.)
@MainActor
final class DimSmartTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func lineEntity(
        _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double
    ) -> CADEntity {
        CADEntity(
            layerID: UUID(),
            localGeometry: [.line(
                start: Vector3(x: x1, y: y1, z: 0),
                end: Vector3(x: x2, y: y2, z: 0), color: nil)])
    }

    func testCircleChoosesDiameter() {
        let doc = makeDocument()
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [.circle(
                center: Vector3(x: 1, y: 2, z: 0), radius: 5, color: nil)])
        let choice = try! XCTUnwrap(DimSmartChoice.resolve(entities: [entity], in: doc))
        XCTAssertEqual(choice.kind, .diameter)
        XCTAssertEqual(choice.targetCommand, "DIMDIAMETER")
        XCTAssertTrue(choice.resultLine().contains("Diameter"))
        XCTAssertTrue(choice.resultLine().contains("5"))
    }

    func testArcChoosesRadius() {
        let doc = makeDocument()
        let entity = CADEntity(
            layerID: UUID(),
            localGeometry: [.arc(
                center: Vector3(x: 0, y: 0, z: 0), radius: 4,
                startAngle: 0, endAngle: 1, color: nil)])
        let choice = try! XCTUnwrap(DimSmartChoice.resolve(entities: [entity], in: doc))
        XCTAssertEqual(choice.kind, .radius)
        XCTAssertEqual(choice.targetCommand, "DIMRADIUS")
        XCTAssertTrue(choice.resultLine().contains("Radius"))
    }

    func testAxisLineChoosesLinearAndAngledChoosesAligned() {
        let doc = makeDocument()
        let horizontal = try! XCTUnwrap(DimSmartChoice.resolve(
            entities: [lineEntity(0, 0, 10, 0)], in: doc))
        XCTAssertEqual(horizontal.kind, .linear)
        XCTAssertEqual(horizontal.targetCommand, "DIMLINEAR")
        XCTAssertTrue(horizontal.resultLine().contains("Linear"))

        let vertical = try! XCTUnwrap(DimSmartChoice.resolve(
            entities: [lineEntity(0, 0, 0, 7)], in: doc))
        XCTAssertEqual(vertical.kind, .linear)

        let diagonal = try! XCTUnwrap(DimSmartChoice.resolve(
            entities: [lineEntity(0, 0, 3, 4)], in: doc))
        XCTAssertEqual(diagonal.kind, .aligned)
        XCTAssertEqual(diagonal.targetCommand, "DIMALIGNED")
        XCTAssertTrue(diagonal.resultLine().contains("Aligned"))
        XCTAssertTrue(diagonal.resultLine().contains("5"))
    }

    func testTwoLinesChooseAngular() {
        let doc = makeDocument()
        let choice = try! XCTUnwrap(DimSmartChoice.resolve(
            entities: [lineEntity(0, 0, 10, 0), lineEntity(0, 0, 0, 10)],
            in: doc))
        XCTAssertEqual(choice.kind, .angular)
        XCTAssertEqual(choice.targetCommand, "DIMANGULAR")
        XCTAssertTrue(choice.resultLine().contains("Angular"))
    }

    func testDimensionEntityChoosesContinue() {
        let doc = makeDocument()
        var entity = CADEntity(layerID: UUID())
        entity.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
            type: .linearOrRotated,
            measurement: 10,
            defPoint: Vector3(x: 0, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 5, z: 0)))
        let choice = try! XCTUnwrap(DimSmartChoice.resolve(entities: [entity], in: doc))
        XCTAssertEqual(choice.kind, .cont)
        XCTAssertEqual(choice.targetCommand, "DIMCONTINUE")
        XCTAssertTrue(choice.resultLine().contains("Continue"))
    }

    func testAmbiguousSelectionResolvesNil() {
        let doc = makeDocument()
        XCTAssertNil(DimSmartChoice.resolve(entities: [], in: doc))
        // Two circles: ambiguous.
        let two = [
            CADEntity(layerID: UUID(), localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 1, color: nil)]),
            CADEntity(layerID: UUID(), localGeometry: [.circle(
                center: Vector3(x: 5, y: 5, z: 0), radius: 2, color: nil)]),
        ]
        XCTAssertNil(DimSmartChoice.resolve(entities: two, in: doc))
        // Mixed circle + line: ambiguous.
        let mixed = [
            CADEntity(layerID: UUID(), localGeometry: [.circle(
                center: Vector3(x: 0, y: 0, z: 0), radius: 1, color: nil)]),
            lineEntity(0, 0, 1, 1),
        ]
        XCTAssertNil(DimSmartChoice.resolve(entities: mixed, in: doc))
        // Block references never count as raw geometry.
        var ref = lineEntity(0, 0, 10, 0)
        ref.blockID = UUID()
        XCTAssertNil(DimSmartChoice.resolve(entities: [ref], in: doc))
    }
}
