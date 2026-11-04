import XCTest
import Foundation
@testable import ZephyrCore

/// Step 2 writer: AcSm XML shape, LT text rules, and .dst round-trips.
@MainActor
final class SheetSetXMLTests: XCTestCase {

    private func sampleSet() -> SheetSet {
        var set = SheetSet(
            name: "TI Set",
            description: "Tenant improvement",
            dstPath: "",
            customSetProps: ["ProjectNo": "P-42"])
        set.sheets = [
            SheetSetSheet(
                number: "A100", title: "Cover", absoluteFile: "C:/job/a.dwg",
                handle: "1A", layoutName: "Layout1",
                custom: ["Room": "Lobby"]),
        ]
        set.subsets = [
            SheetSetSubset(
                name: "Arch", description: "Architecture",
                sheets: [
                    SheetSetSheet(number: "A/B", title: "Plan/Elec", absoluteFile: "C:/job/b.dwg", handle: "2B", layoutName: "Layout1"),
                    SheetSetSheet(number: "A102", title: "RCP", absoluteFile: "C:/job/c.dwg", handle: "3C", includeForPlot: false),
                ]),
        ]
        return set
    }

    func testEmptySetSerializesVerifiableSkeleton() throws {
        let xml = try SheetSetXML.serialize(SheetSet(name: "Empty"))
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("clsid=\"g2162C6B6-0CE4-40E8-912B-46F59DFDF826\""))
        XCTAssertTrue(xml.contains("propname=\"SheetSet\""))
        XCTAssertTrue(xml.contains("<AcSmProp propname=\"Name\" vt=\"8\">Empty</AcSmProp>"))
        // Round-trips through the real byte cipher with zero sheets.
        let back = try SheetSetDST.decode(try SheetSetDST.encode(xml))
        XCTAssertEqual(SheetSetDST.listSheets(xml: back).count, 0)
        XCTAssertEqual(SheetSetDST.sheetSetName(xml: back), "Empty")
    }

    func testFullSetRoundTripsSheetsSubsetsAndFlags() throws {
        let xml = try SheetSetXML.serialize(sampleSet())
        let data = try SheetSetDST.encode(xml)
        let back = try SheetSetDST.decode(data)
        XCTAssertEqual(SheetSetDST.sheetSetName(xml: back), "TI Set")
        let refs = SheetSetDST.listSheets(xml: back)
        XCTAssertEqual(refs.map(\.number), ["A100", "A \u{0338} B", "A102"])
        XCTAssertEqual(refs.map(\.handle), ["1A", "2B", "3C"])
        XCTAssertEqual(refs.map(\.includeForPlot), [true, true, false])
        // Custom bags + flags survive as XML the reader preserves.
        XCTAssertTrue(back.contains("propname=\"ProjectNo\""))
        XCTAssertTrue(back.contains("<AcSmProp propname=\"Flags\" vt=\"3\">1</AcSmProp>"))
        XCTAssertTrue(back.contains("<AcSmProp propname=\"Flags\" vt=\"3\">2</AcSmProp>"))
        XCTAssertTrue(back.contains("propname=\"Room\""))
    }

    func testSlashBecomesLookalikeAndLongTitleThrows() throws {
        let xml = try SheetSetXML.serialize(sampleSet())
        XCTAssertFalse(xml.contains(">A/B<"))
        XCTAssertTrue(xml.contains("A \u{0338} B"))
        var bad = SheetSet(name: "Bad")
        bad.sheets = [SheetSetSheet(number: "A1", title: String(repeating: "x", count: 65))]
        XCTAssertThrowsError(try SheetSetXML.serialize(bad)) { error in
            XCTAssertEqual(error as? SheetSetXMLError, .titleTooLong(sheet: "A1"))
        }
        XCTAssertThrowsError(try SheetSetXML.serialize(SheetSet(name: "")))
    }

    func testFreshIDsMatchCOMShape() {
        let id = SheetSetModelID.fresh()
        XCTAssertTrue(id.hasPrefix("g"))
        XCTAssertTrue(id.contains("-"))
        XCTAssertEqual(id.count, 37)
    }
}
