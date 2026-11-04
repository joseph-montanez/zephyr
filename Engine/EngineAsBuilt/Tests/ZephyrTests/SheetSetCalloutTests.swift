import XCTest
import Foundation
@testable import ZephyrCore

/// Callout/label blocks for placed sheet views: heuristic attribute fill
/// (view/sheet/scale/file tags, explicit TAG=value overrides, LT-assigned
/// view numbers left defaulted), PLACECALLOUT operand parsing, and the
/// TabManager paper-space placer. The engine-touching click flow is covered
/// by the manual interactive run (no live PhrostEngine in the harness).
@MainActor
final class SheetSetCalloutTests: XCTestCase {

    private func target() -> SheetViewCallouts.Target {
        SheetViewCallouts.Target(
            viewName: "Lobby", modelFileName: "m.dxf",
            sheetNumber: "A-101", sheetTitle: "First Floor")
    }

    // MARK: - Heuristic fill rules

    func testOverrideBeatsEveryHeuristic() {
        let got = SheetViewCallouts.value(
            forTag: "VIEW_NAME", target: target(),
            overrides: ["VIEW_NAME": "Explicit"])
        XCTAssertEqual(got, "Explicit")
    }

    func testSheetTags() {
        let full = target()
        XCTAssertEqual(SheetViewCallouts.value(forTag: "SHEET_NO", target: full, overrides: [:]), "A-101")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "sheet_title", target: full, overrides: [:]), "First Floor")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "SHEET", target: full, overrides: [:]), "A-101")
        var noNumber = full
        noNumber.sheetNumber = nil
        XCTAssertEqual(SheetViewCallouts.value(forTag: "SHEET", target: noNumber, overrides: [:]), "First Floor")
        XCTAssertNil(SheetViewCallouts.value(forTag: "SHEET_NO", target: noNumber, overrides: [:]))
        // "NOTES" is not a number word: no fill rather than a wrong fill.
        XCTAssertNil(SheetViewCallouts.value(forTag: "SHEET_NOTES", target: full, overrides: [:]))
    }

    func testViewAndDetailTags() {
        let full = target()
        XCTAssertEqual(SheetViewCallouts.value(forTag: "VIEW", target: full, overrides: [:]), "Lobby")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "View_Name", target: full, overrides: [:]), "Lobby")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "DETAIL", target: full, overrides: [:]), "Lobby")
        // View numbers are LT-assigned: defaulted unless overridden.
        XCTAssertNil(SheetViewCallouts.value(forTag: "VIEW_NO", target: full, overrides: [:]))
        XCTAssertNil(SheetViewCallouts.value(forTag: "VIEWNO", target: full, overrides: [:]))
        XCTAssertEqual(
            SheetViewCallouts.value(forTag: "VIEW_NO", target: full, overrides: ["VIEW_NO": "3"]), "3")
        // Whole-token match only: REVIEW is not a VIEW tag.
        XCTAssertNil(SheetViewCallouts.value(forTag: "REVIEW", target: full, overrides: [:]))
        XCTAssertNil(SheetViewCallouts.value(forTag: "NOTES", target: full, overrides: [:]))
    }

    func testScaleAndFileTags() {
        let full = target()
        XCTAssertEqual(SheetViewCallouts.value(forTag: "SCALE", target: full, overrides: [:]), "1:1")
        var scaled = full
        scaled.scaleDenominator = 50
        XCTAssertEqual(SheetViewCallouts.value(forTag: "VIEW_SCALE", target: scaled, overrides: [:]), "1:50")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "DWG_NAME", target: full, overrides: [:]), "m.dxf")
        XCTAssertEqual(SheetViewCallouts.value(forTag: "DRAWING", target: full, overrides: [:]), "m.dxf")
        var noFile = full
        noFile.modelFileName = ""
        XCTAssertNil(SheetViewCallouts.value(forTag: "DWG_NAME", target: noFile, overrides: [:]))
    }

    // MARK: - ATTSYNC merge

    func testResolveMergesWithDefaultsAndDropsOrphans() {
        let defs = [
            CADAttributeDefinition(tag: "VIEW_NAME", defaultValue: "dflt"),
            CADAttributeDefinition(tag: "SHEET_NO", defaultValue: "dflt"),
            CADAttributeDefinition(tag: "UNFILLED", defaultValue: "keep"),
        ]
        let got = SheetViewCallouts.resolve(
            definitions: defs, target: target(),
            overrides: ["UNFILLED": "set", "MISSING_TAG": "dropped", "view_name": "lower-wins"])
        XCTAssertEqual(got["VIEW_NAME"]?.value, "lower-wins")
        XCTAssertEqual(got["SHEET_NO"]?.value, "A-101")
        XCTAssertEqual(got["UNFILLED"]?.value, "set")
        XCTAssertNil(got["MISSING_TAG"], "orphan override drops")
        XCTAssertEqual(got.count, 3)
    }

    // MARK: - PLACECALLOUT parsing

    func testParseFullOperands() {
        let req = try! XCTUnwrap(PlaceCalloutCommand.parse("\"C:/m.dxf\" Lobby CALLOUT 5 7 VIEW_NO=3"))
        XCTAssertEqual(req.modelPath, "C:/m.dxf")
        XCTAssertEqual(req.viewName, "Lobby")
        XCTAssertEqual(req.blockName, "CALLOUT")
        XCTAssertEqual(req.paperX, 5)
        XCTAssertEqual(req.paperY, 7)
        XCTAssertEqual(req.overrides, ["VIEW_NO": "3"])
    }

    func testParseQuotedNamesAndOverrideOrder() {
        let req = try! XCTUnwrap(PlaceCalloutCommand.parse("\"m.dxf\" \"My View\" \"My Block\" TAG_X=1 2 3"))
        XCTAssertEqual(req.viewName, "My View")
        XCTAssertEqual(req.blockName, "My Block")
        XCTAssertEqual(req.paperX, 2)
        XCTAssertEqual(req.paperY, 3)
        XCTAssertEqual(req.overrides, ["TAG_X": "1"])
    }

    func testParseRejectsBadArity() {
        XCTAssertNil(PlaceCalloutCommand.parse(""))
        XCTAssertNil(PlaceCalloutCommand.parse("\"m.dxf\" V"))
        XCTAssertNil(PlaceCalloutCommand.parse("\"m.dxf\" V B 5"), "lone numeric")
        XCTAssertNil(PlaceCalloutCommand.parse("\"m.dxf\" V B 1 2 3"), "three numerics")
        XCTAssertNil(PlaceCalloutCommand.parse("\"m.dxf\" V B x y"), "non-numeric point")
        XCTAssertNil(PlaceCalloutCommand.parse("\"m.dxf\" V B =x"), "empty key")
    }

    func testParseAllowsEmptyOverrideValue() {
        let req = try! XCTUnwrap(PlaceCalloutCommand.parse("\"m.dxf\" V B FOO="))
        XCTAssertEqual(req.overrides, ["FOO": ""])
        XCTAssertNil(req.paperX)
    }

    // MARK: - Paper-space placer

    @MainActor
    private func managerWithSheet(
        modelDoc: CADDocument, sheetDoc: CADDocument, onSheet: Bool = true
    ) -> TabManager {
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc, displayName: "Callout",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        if onSheet { XCTAssertTrue(manager.switchToView(at: 1)) }
        return manager
    }

    @MainActor
    private func calloutBlock() -> CADBlock {
        CADBlock(
            name: "CALLOUT",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: nil)],
            attributeDefinitions: [
                CADAttributeDefinition(tag: "VIEW_NAME", defaultValue: "dflt"),
                CADAttributeDefinition(tag: "SHEET_NO", defaultValue: "dflt"),
            ])
    }

    @MainActor
    func testPlaceCalloutLandsAtPaperPointWithFilledAttributes() throws {
        let sheetDoc = CADDocument()
        sheetDoc.addLayer(Layer(name: "0"))
        let defs = calloutBlock().attributeDefinitions
        sheetDoc.importLayersBlocksEntities(layers: [], blocks: [calloutBlock()], entities: [])
        let manager = managerWithSheet(modelDoc: CADDocument(), sheetDoc: sheetDoc)
        let handle = try manager.placeSheetCallout(
            blockName: "callout", paperX: 5, paperY: 7
        ) { definitions in
            XCTAssertEqual(definitions.count, defs.count)
            return SheetViewCallouts.resolve(definitions: definitions, target: target())
        }
        let placed = try XCTUnwrap(sheetDoc.entity(for: handle))
        let block = try XCTUnwrap(sheetDoc.allBlocks.first(where: { $0.name == "CALLOUT" }))
        XCTAssertEqual(placed.blockID, block.handle)
        // Paper point lands un-negated (Y-up paper frame, like MVIEW SELECT).
        XCTAssertEqual(
            placed.transform,
            DrawingFileInsert.insertionTransform(
                point: Vector3(x: 5, y: 7, z: 0), scaleX: 1, scaleY: 1, rotationDegrees: 0))
        XCTAssertEqual(placed.attributeValues["VIEW_NAME"]?.value, "Lobby")
        XCTAssertEqual(placed.attributeValues["SHEET_NO"]?.value, "A-101")
    }

    @MainActor
    func testPlaceCalloutRejectsUnknownBlockAndModelSpace() throws {
        let sheetDoc = CADDocument()
        sheetDoc.addLayer(Layer(name: "0"))
        sheetDoc.importLayersBlocksEntities(layers: [], blocks: [calloutBlock()], entities: [])
        let manager = managerWithSheet(modelDoc: CADDocument(), sheetDoc: sheetDoc)
        do {
            _ = try manager.placeSheetCallout(blockName: "NOPE", paperX: 0, paperY: 0)
            XCTFail("want unknownBlock")
        } catch let err as TabManager.SheetViewPlaceError {
            guard case .unknownBlock(let name) = err else {
                return XCTFail("want unknownBlock, got \(err)")
            }
            XCTAssertEqual(name, "NOPE")
        }
        let modelSide = managerWithSheet(
            modelDoc: CADDocument(), sheetDoc: CADDocument(), onSheet: false)
        do {
            _ = try modelSide.placeSheetCallout(blockName: "CALLOUT", paperX: 0, paperY: 0)
            XCTFail("want noActiveTab")
        } catch let err as TabManager.SheetViewPlaceError {
            guard case .noActiveTab = err else {
                return XCTFail("want noActiveTab, got \(err)")
            }
        }
    }

}