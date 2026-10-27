import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2b QSELECT/FILTER: predicate evaluation, combinators, and prompt
/// parsing over the shared EntityFilter core. (Command stepped-prompt flow
/// mirrors FIND; selection writes mirror selectAll.)
@MainActor
final class QSelectFilterTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.addLayer(Layer(name: "Walls"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func lineEntity(
        layerID: UUID,
        color: ColorRGBA? = nil,
        lineWeight: Double? = nil
    ) -> CADEntity {
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0),
                color: color)],
            transform: .identity)
        if let lineWeight {
            entity.xdata["dxf.lineWeight"] = .double(lineWeight)
        }
        return entity
    }

    private func crit(
        _ property: EntityFilter.FilterProperty,
        _ op: EntityFilter.FilterOperator,
        _ value: String
    ) -> EntityFilter.FilterCriterion {
        EntityFilter.FilterCriterion(property: property, op: op, value: value)
    }

    // MARK: - evaluate: strings

    func testTypeEqualsAndWildcard() {
        let doc = makeDocument()
        let line = lineEntity(layerID: doc.activeLayerID!)
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.objectType, .equals, "LINE"), on: line, in: doc))
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.objectType, .equals, "L*"), on: line, in: doc))
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.objectType, .equals, "TEXT"), on: line, in: doc))
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.objectType, .notEquals, "L*"), on: line, in: doc))
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.objectType, .notEquals, "TEXT"), on: line, in: doc))
    }

    func testLayerWildcard() {
        let doc = makeDocument()
        let wallsID = try! XCTUnwrap(doc.findLayer(named: "Walls")).handle
        let onWalls = lineEntity(layerID: wallsID)
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.layer, .equals, "W*"), on: onWalls, in: doc))
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.layer, .equals, "walls"), on: onWalls, in: doc))
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.layer, .equals, "0"), on: onWalls, in: doc))
    }

    func testStringComparisonsAreFalse() {
        let doc = makeDocument()
        let line = lineEntity(layerID: doc.activeLayerID!)
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.layer, .greaterThan, "A"), on: line, in: doc))
    }

    // MARK: - evaluate: numerics

    func testColorComparisons() {
        let doc = makeDocument()
        let white = lineEntity(layerID: doc.activeLayerID!, color: .white)
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.color, .equals, "7"), on: white, in: doc))
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.color, .greaterThan, "1"), on: white, in: doc))
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.color, .lessThanOrEqual, "7"), on: white, in: doc))
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.color, .equals, "1"), on: white, in: doc))
        // Unparseable numbers never match.
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.color, .equals, "red"), on: white, in: doc))
    }

    func testLineweightComparisons() {
        let doc = makeDocument()
        let heavy = lineEntity(layerID: doc.activeLayerID!, lineWeight: 0.5)
        XCTAssertTrue(EntityFilter.evaluate(
            crit(.lineweight, .greaterThanOrEqual, "0.5"), on: heavy, in: doc))
        XCTAssertFalse(EntityFilter.evaluate(
            crit(.lineweight, .lessThan, "0.5"), on: heavy, in: doc))
    }

    // MARK: - combine + filter

    func testCombineSemantics() {
        XCTAssertTrue(EntityFilter.combine([true, true], with: .and))
        XCTAssertFalse(EntityFilter.combine([true, false], with: .and))
        XCTAssertTrue(EntityFilter.combine([true, false], with: .or))
        XCTAssertFalse(EntityFilter.combine([false, false], with: .or))
        XCTAssertTrue(EntityFilter.combine([false], with: .not))
        XCTAssertFalse(EntityFilter.combine([true], with: .not))
        XCTAssertTrue(EntityFilter.combine([], with: .and))
        XCTAssertFalse(EntityFilter.combine([], with: .or))
        XCTAssertTrue(EntityFilter.combine([], with: .not))
    }

    func testFilterRespectsVisibilityAndCombinator() {
        let doc = makeDocument()
        doc.addLayer(Layer(name: "Hidden", isVisible: false))
        let hiddenID = try! XCTUnwrap(doc.findLayer(named: "Hidden")).handle
        let visible = lineEntity(layerID: doc.activeLayerID!)
        let hidden = lineEntity(layerID: hiddenID)
        let red = lineEntity(
            layerID: doc.activeLayerID!,
            color: ColorRGBA(r: 255, g: 0, b: 0))
        let and = EntityFilter.filter(
            [visible, hidden, red],
            criteria: [
                crit(.objectType, .equals, "LINE"),
                crit(.color, .notEquals, "1"),
            ],
            using: .and, in: doc)
        XCTAssertEqual(and.count, 1)
        let or = EntityFilter.filter(
            [visible, hidden, red],
            criteria: [crit(.color, .equals, "1")],
            using: .or, in: doc)
        XCTAssertEqual(or.count, 1)
        XCTAssertEqual(or[0].handle, red.handle)
        let not = EntityFilter.filter(
            [visible, hidden, red],
            criteria: [crit(.objectType, .equals, "LINE")],
            using: .not, in: doc)
        XCTAssertTrue(not.isEmpty)
    }

    // MARK: - prompt parsing

    func testParseProperty() {
        XCTAssertEqual(
            SelectFilterCommand.parseProperty("layer", allowType: false), .layer)
        XCTAssertEqual(
            SelectFilterCommand.parseProperty("COL", allowType: false), .color)
        XCTAssertEqual(
            SelectFilterCommand.parseProperty("type", allowType: true), .objectType)
        XCTAssertNil(SelectFilterCommand.parseProperty("type", allowType: false))
        // Ambiguous prefixes reject.
        XCTAssertNil(SelectFilterCommand.parseProperty("l", allowType: false))
        XCTAssertNil(SelectFilterCommand.parseProperty("", allowType: false))
        XCTAssertEqual(
            SelectFilterCommand.parseProperty("linet", allowType: false), .linetype)
        XCTAssertEqual(
            SelectFilterCommand.parseProperty("linew", allowType: false), .lineweight)
    }

    func testParseOperator() {
        XCTAssertEqual(
            SelectFilterCommand.parseOperator("=", for: .layer), .equals)
        XCTAssertEqual(
            SelectFilterCommand.parseOperator("<>", for: .layer), .notEquals)
        XCTAssertNil(SelectFilterCommand.parseOperator("<", for: .layer))
        XCTAssertEqual(
            SelectFilterCommand.parseOperator("<=", for: .lineweight),
            .lessThanOrEqual)
        XCTAssertEqual(
            SelectFilterCommand.parseOperator("GT", for: .color), .greaterThan)
    }

    func testParseValue() {
        XCTAssertEqual(
            SelectFilterCommand.parseValue("W*", for: .layer), "W*")
        XCTAssertEqual(
            SelectFilterCommand.parseValue("line", for: .objectType), "LINE")
        XCTAssertNil(SelectFilterCommand.parseValue("BEAM", for: .objectType))
        XCTAssertEqual(
            SelectFilterCommand.parseValue("7", for: .color), "7")
        XCTAssertNil(SelectFilterCommand.parseValue("300", for: .color))
        XCTAssertNil(SelectFilterCommand.parseValue("red", for: .color))
        XCTAssertEqual(
            SelectFilterCommand.parseValue("0.5", for: .lineweight), "0.5")
        XCTAssertNil(SelectFilterCommand.parseValue("", for: .layer))
    }

    func testParseCombine() {
        XCTAssertEqual(SelectFilterCommand.parseCombine("and"), .and)
        XCTAssertEqual(SelectFilterCommand.parseCombine("OR"), .or)
        XCTAssertEqual(SelectFilterCommand.parseCombine("not"), .not)
        XCTAssertNil(SelectFilterCommand.parseCombine("xor"))
    }
}
