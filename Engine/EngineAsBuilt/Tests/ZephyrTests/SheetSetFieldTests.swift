import XCTest
import Foundation
@testable import ZephyrCore

/// Step 7: `%<\AcSm …>%` evaluation against open sets. Unresolvable
/// expressions return nil so callers keep the cached text.
final class SheetSetFieldTests: XCTestCase {

    private func makeStore() -> SheetSetStore {
        var store = SheetSetStore()
        var set = SheetSet(
            name: "TI Set",
            description: "Tenant improvement",
            dstPath: "C:/job/ti.dst",
            customSetProps: ["Client": "Acme"])
        set.sheets = [
            SheetSetSheet(
                number: "A100", title: "Cover", description: "Cover sheet",
                absoluteFile: "C:/job/a.dwg", handle: "1A", layoutName: "Layout1",
                custom: ["Room": "Lobby"]),
        ]
        store.register(set)
        return store
    }

    private func makeDoc() -> CADDocument {
        let doc = CADDocument()
        _ = doc.finalizeOpen(sourceFileName: "C:/JOB/A.DWG", layoutName: "layout1")
        return doc
    }

    func testSheetAndSetFieldsResolveCaseInsensitively() {
        let store = makeStore()
        let doc = makeDoc()
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm Sheet.Number>%", in: doc, store: store), "A100")
        XCTAssertEqual(FieldEval.evaluate("%<\\acsm sheet.title>%", in: doc, store: store), "Cover")
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm Sheet.Description>%", in: doc, store: store), "Cover sheet")
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm SheetSet.Name>%", in: doc, store: store), "TI Set")
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm SheetSet.Description>%", in: doc, store: store), "Tenant improvement")
    }

    func testCustomPropsAndFormatSuffix() {
        let store = makeStore()
        let doc = makeDoc()
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm Sheet.Room>%", in: doc, store: store), "Lobby")
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm Sheet.room>%", in: doc, store: store), "Lobby")
        XCTAssertEqual(FieldEval.evaluate("%<\\AcSm SheetSet.Client>%", in: doc, store: store), "Acme")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Number \\f \"%tc1\">%", in: doc, store: store),
            "A100")
    }

    func testFormatCodesConvertCase() {
        var store = SheetSetStore()
        var set = SheetSet(name: "ti set", dstPath: "C:/job/ti.dst")
        set.sheets = [SheetSetSheet(
            number: "a100", title: "cover SHEET",
            absoluteFile: "C:/job/a.dwg", handle: "1A", layoutName: "Layout1")]
        store.register(set)
        let doc = makeDoc()
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Number \\f \"%tc1\">%", in: doc, store: store), "A100")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Title \\f \"%tc2\">%", in: doc, store: store), "cover sheet")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Title \\f \"%tc3\">%", in: doc, store: store), "Cover SHEET")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Title \\f \"%tc4\">%", in: doc, store: store), "Cover SHEET")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm SheetSet.Name \\f \"%tc4\">%", in: doc, store: store), "Ti Set")
        // Unknown codes and missing suffix leave the value unchanged.
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Number \\f \"%ct9\">%", in: doc, store: store), "a100")
        XCTAssertEqual(
            FieldEval.evaluate("%<\\AcSm Sheet.Number>%", in: doc, store: store), "a100")
    }

    func testUnresolvableKeepsNil() {
        let store = makeStore()
        let doc = makeDoc()
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm Sheet.Missing>%", in: doc, store: store))
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm SheetSet.Missing>%", in: doc, store: store))
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm Database.Foo>%", in: doc, store: store))
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm Sheet>%", in: doc, store: store))
        XCTAssertNil(FieldEval.evaluate("Sheet.Number", in: doc, store: store))
        // No open set behind the document.
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm Sheet.Number>%", in: doc, store: SheetSetStore()))
        // Right file, wrong layout.
        let other = CADDocument()
        _ = other.finalizeOpen(sourceFileName: "C:/job/a.dwg", layoutName: "Model")
        XCTAssertNil(FieldEval.evaluate("%<\\AcSm Sheet.Number>%", in: other, store: store))
        // `$` codes still route through the same entry point.
        XCTAssertEqual(FieldEval.evaluate("$FILENAME", in: doc, store: store), "C:/JOB/A.DWG")
    }
}
