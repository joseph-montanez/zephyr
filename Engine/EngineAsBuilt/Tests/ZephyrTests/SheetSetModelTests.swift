import XCTest
import Foundation
@testable import ZephyrCore

/// Step 2: SheetSet ordering, rename, remove, and SSLOCATE MRU fallback.
final class SheetSetModelTests: XCTestCase {

    private func sample() -> SheetSet {
        var set = SheetSet(name: "TI Set", dstPath: "C:/job/ti.dst")
        set.sheets = [SheetSetSheet(number: "A100", title: "Cover", absoluteFile: "C:/job/a.dwg", handle: "1A")]
        set.subsets = [
            SheetSetSubset(name: "Arch", sheets: [
                SheetSetSheet(number: "A101", title: "Plan", absoluteFile: "C:/job/b.dwg", handle: "2B"),
                SheetSetSheet(number: "A102", title: "RCP", absoluteFile: "C:/job/c.dwg", handle: "3C", includeForPlot: false),
            ]),
        ]
        return set
    }

    func testDisplayOrderIsLooseFirstDepthFirst() {
        XCTAssertEqual(sample().allSheetsInOrder.map(\.number), ["A100", "A101", "A102"])
    }

    func testRenameAndRemove() {
        var set = sample()
        let id = set.allSheetsInOrder[1].id
        XCTAssertTrue(set.renameSheet(id: id, number: "A110", title: "Demo"))
        XCTAssertEqual(set.sheet(id: id)?.title, "Demo")
        XCTAssertTrue(set.removeSheet(id: id))
        XCTAssertNil(set.sheet(id: id))
        XCTAssertFalse(set.removeSheet(id: "gMISSING"))
    }

    func testAutoNumberingScopeSkipsExcluded() {
        let set = sample()
        XCTAssertEqual(set.autoNumberingScope.map(\.number), ["A100", "A101", "A102"])
        var excluded = set
        excluded.subsets[0].sheets[0].includeForAutoNumbering = false
        XCTAssertEqual(excluded.autoNumberingScope.map(\.number), ["A100", "A102"])
    }

    func testMRUFallbackIsCaseAndSlashInsensitive() {
        var mru = SheetSetMRU()
        mru.register(dstPath: "C:/job/ti.dst", dwgPaths: ["C:\\job\\B.dwg"])
        XCTAssertEqual(mru.locate(dwgPath: "c:/JOB/b.dwg"), "C:/job/ti.dst")
        XCTAssertNil(mru.locate(dwgPath: "c:/job/other.dwg"))
        mru.unregisterDST("C:/job/ti.dst")
        XCTAssertNil(mru.locate(dwgPath: "c:/job/b.dwg"))
    }

    func testDSTRefBridgesToModel() throws {
        let xml = "<AcSmDatabase><AcSmSheet ID=\"gABC\"><AcSmProp propname=\"Number\" vt=\"8\">A101</AcSmProp><AcSmProp propname=\"Title\" vt=\"8\">Plan</AcSmProp><AcSmAcDbLayoutReference><AcSmProp propname=\"FileName\" vt=\"8\">C:\\job\\b.dwg</AcSmProp><AcSmProp propname=\"AcDbHandle\" vt=\"8\">2B</AcSmProp></AcSmAcDbLayoutReference></AcSmSheet></AcSmDatabase>"
        let refs = SheetSetDST.listSheets(xml: xml)
        let sheet = SheetSetSheet(ref: refs[0])
        XCTAssertEqual(sheet.number, "A101")
        XCTAssertEqual(sheet.handle, "2B")
        var set = SheetSet(name: "Bridge")
        set.sheets = [sheet]
        XCTAssertEqual(set.allSheetsInOrder.count, 1)
    }
}

