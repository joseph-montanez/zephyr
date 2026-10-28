import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2a SELECTSIMILAR: wildcard matching, similarity bits, visibility
/// policy, and the SELECTSIMILARMODE sysvar binding. (Command adopt/pick
/// flow mirrors DIMREASSOCIATE; selection writes mirror selectAll.)
@MainActor
final class SelectSimilarTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func lineEntity(
        layerID: UUID,
        color: ColorRGBA? = nil,
        lineType: String? = nil,
        lineWeight: Double? = nil
    ) -> CADEntity {
        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0),
                color: color)],
            transform: .identity)
        if let lineType {
            entity.xdata["dxf.lineType"] = .string(lineType)
        }
        if let lineWeight {
            entity.xdata["dxf.lineWeight"] = .double(lineWeight)
        }
        return entity
    }

    private func textEntity(layerID: UUID, style: String?) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.text(
                position: Vector3(x: 0, y: 0, z: 0), text: "hi", height: 2.5,
                rotation: 0, style: style, alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)],
            transform: .identity)
    }

    // MARK: - wildcardMatch

    func testWildcardBasics() {
        XCTAssertTrue(EntityFilter.wildcardMatch("Walls-01", pattern: "WALLS-*"))
        XCTAssertTrue(EntityFilter.wildcardMatch("Walls-01", pattern: "walls-??"))
        XCTAssertFalse(EntityFilter.wildcardMatch("Walls-01", pattern: "walls-?"))
        XCTAssertTrue(EntityFilter.wildcardMatch("anything", pattern: "*"))
        XCTAssertFalse(EntityFilter.wildcardMatch("abc", pattern: "abd"))
        XCTAssertTrue(EntityFilter.wildcardMatch("", pattern: "*"))
        XCTAssertFalse(EntityFilter.wildcardMatch("", pattern: "?"))
    }

    // MARK: - similar

    func testTypeBitSeparatesPrimKinds() {
        let doc = makeDocument()
        let layer = doc.activeLayerID!
        let line = lineEntity(layerID: layer)
        let text = textEntity(layerID: layer, style: "Standard")
        XCTAssertFalse(EntityFilter.similar(
            to: line, candidate: text, mode: EntityFilter.matchType, in: doc))
        XCTAssertTrue(EntityFilter.similar(
            to: line, candidate: lineEntity(layerID: layer),
            mode: EntityFilter.matchType, in: doc))
    }

    func testDefaultModeIsLayerPlusName() {
        XCTAssertEqual(EntityFilter.defaultMode, 130)
        let doc = makeDocument()
        let layer = doc.activeLayerID!
        let a = textEntity(layerID: layer, style: "Standard")
        let b = textEntity(layerID: layer, style: "Notes")
        XCTAssertFalse(EntityFilter.similar(
            to: a, candidate: b, mode: EntityFilter.defaultMode, in: doc))
        XCTAssertTrue(EntityFilter.similar(
            to: a, candidate: textEntity(layerID: layer, style: "Standard"),
            mode: EntityFilter.defaultMode, in: doc))
    }

    func testColorBitUsesACI() {
        let doc = makeDocument()
        let layer = doc.activeLayerID!
        let white = lineEntity(layerID: layer, color: .white)
        let red = lineEntity(layerID: layer, color: ColorRGBA(r: 255, g: 0, b: 0))
        XCTAssertFalse(EntityFilter.similar(
            to: white, candidate: red, mode: EntityFilter.matchColor, in: doc))
        XCTAssertTrue(EntityFilter.similar(
            to: white, candidate: lineEntity(layerID: layer, color: .white),
            mode: EntityFilter.matchColor, in: doc))
    }

    func testLinetypeAndLineweightResolveBylayer() {
        let doc = makeDocument()
        let layer = doc.activeLayerID!
        let plain = lineEntity(layerID: layer)
        let dashed = lineEntity(layerID: layer, lineType: "DASHED")
        XCTAssertFalse(EntityFilter.similar(
            to: plain, candidate: dashed,
            mode: EntityFilter.matchLinetype, in: doc))
        let heavy = lineEntity(layerID: layer, lineWeight: 0.5)
        XCTAssertFalse(EntityFilter.similar(
            to: plain, candidate: heavy,
            mode: EntityFilter.matchLineweight, in: doc))
        XCTAssertTrue(EntityFilter.similar(
            to: heavy, candidate: lineEntity(layerID: layer, lineWeight: 0.5),
            mode: EntityFilter.matchLineweight, in: doc))
    }

    func testNamelessEntitiesMatchEachOther() {
        let doc = makeDocument()
        let layer = doc.activeLayerID!
        XCTAssertTrue(EntityFilter.similar(
            to: lineEntity(layerID: layer),
            candidate: lineEntity(layerID: layer),
            mode: EntityFilter.matchName, in: doc))
    }

    // MARK: - visibility

    func testInvisibleLayersNeverMatch() {
        let doc = makeDocument()
        doc.addLayer(Layer(name: "Hidden", isVisible: false))
        let hiddenID = try! XCTUnwrap(doc.findLayer(named: "Hidden")).handle
        let visible = lineEntity(layerID: doc.activeLayerID!)
        let hidden = lineEntity(layerID: hiddenID)
        XCTAssertTrue(EntityFilter.isVisibleForSelection(visible, in: doc))
        XCTAssertFalse(EntityFilter.isVisibleForSelection(hidden, in: doc))
    }

    // MARK: - mode helpers

    func testIgnoredBits() {
        XCTAssertEqual(EntityFilter.ignoredModeBits(130), [])
        XCTAssertEqual(
            EntityFilter.ignoredModeBits(130 | 32 | 64), ["plot style", "object style"])
    }

    func testModeDescription() {
        XCTAssertEqual(EntityFilter.modeDescription(130), "layer+name")
        XCTAssertEqual(EntityFilter.modeDescription(0), "nothing (empty mask)")
    }

    // MARK: - sysvar binding

    func testSelectSimilarModeDefaultAndValidation() {
        let processor = CADCommandProcessor()
        let document = makeDocument()
        XCTAssertEqual(
            processor.lispVars.get(
                "SELECTSIMILARMODE", document: document, activeCommand: nil),
            .int(130))
        XCTAssertNil(processor.lispVars.set(
            "SELECTSIMILARMODE", .int(1), document: document))
        XCTAssertEqual(document.selectSimilarMode, 1)
        XCTAssertEqual(
            processor.lispVars.get(
                "SELECTSIMILARMODE", document: document, activeCommand: nil),
            .int(1))
        XCTAssertNotNil(processor.lispVars.set(
            "SELECTSIMILARMODE", .int(256), document: document))
        XCTAssertNotNil(processor.lispVars.set(
            "SELECTSIMILARMODE", .int(-1), document: document))
        XCTAssertEqual(document.selectSimilarMode, 1)
    }
}
