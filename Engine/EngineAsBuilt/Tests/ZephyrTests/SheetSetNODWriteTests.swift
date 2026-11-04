import XCTest
import Foundation
@testable import ZephyrCore

/// NOD write-back: saving a member drawing stamps `AcSheetSetData`, and
/// a surviving preserved hint always wins over a requested one.
/// Read-back uses the same `SheetSetNODHint` lookup as SSLOCATE.
@MainActor
final class SheetSetNODWriteTests: XCTestCase {

    private func export(document: CADDocument = CADDocument(), hint: DXFSheetSetHint? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("plan.dxf")
        try DXFExporter.export(document: document, to: url, sheetSetHint: hint)
        return url
    }

    private func readHint(_ url: URL) throws -> SheetSetNODHint.Hint? {
        let reader = try DXFReader().readFile(at: url.path)
        return SheetSetNODHint.read(reader: reader)
    }

    private func countOccurrences(of token: String, in url: URL) throws -> Int {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.components(separatedBy: token).count - 1
    }

    func testWriteHintRoundTrips() throws {
        let hint = DXFSheetSetHint(
            dstPath: "C:\\job\\site.dst",
            dwgName: "plan.dxf",
            layoutHandle: "AB")
        let url = try export(hint: hint)
        let found = try readHint(url)
        XCTAssertEqual(found?.dstPath, "C:\\job\\site.dst")
        XCTAssertEqual(found?.dwgName, "plan.dxf")
        XCTAssertEqual(found?.layoutHandle, "AB")
        XCTAssertEqual(try countOccurrences(of: "AcSheetSetData", in: url), 1)
        XCTAssertEqual(try countOccurrences(of: "ShSetFileName", in: url), 1)
    }

    func testSaveActiveTabAsStampsHint() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sheet.dxf")
        manager.addTab(DocumentTab(
            document: CADDocument(), fileURL: url, displayName: "sheet",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: CADDocument()),
                DrawingView(name: "Layout1", kind: .sheet, document: CADDocument()),
            ]))
        XCTAssertTrue(manager.switchToView(at: 1))
        manager.sheetSetHintProvider = { _, _ in
            DXFSheetSetHint(dstPath: "C:\\job\\site.dst", dwgName: "sheet.dxf", layoutHandle: "AB")
        }
        try manager.saveActiveTabAs(url: url)
        let found = try readHint(url)
        XCTAssertEqual(found?.dstPath, "C:\\job\\site.dst")
        XCTAssertEqual(found?.dwgName, "sheet.dxf")
        XCTAssertEqual(found?.layoutHandle, "AB")
    }

    func testNoHintWritesNoDictionary() throws {
        let url = try export()
        XCTAssertNil(try readHint(url))
        XCTAssertEqual(try countOccurrences(of: "AcSheetSetData", in: url), 0)
    }

    func testMinimalHintOmitsOptionalRecords() throws {
        let url = try export(hint: DXFSheetSetHint(dstPath: "C:\\job\\site.dst"))
        let found = try readHint(url)
        XCTAssertEqual(found?.dstPath, "C:\\job\\site.dst")
        XCTAssertNil(found?.dwgName)
        XCTAssertNil(found?.layoutHandle)
        XCTAssertEqual(try countOccurrences(of: "SheetDwgName", in: url), 0)
        XCTAssertEqual(try countOccurrences(of: "LayoutHandle", in: url), 0)
    }

    func testPreservedHintWinsOverRequested() throws {
        func group(_ code: Int, _ value: String) -> DataTableRawDXFGroup {
            DataTableRawDXFGroup(code: code, value: value)
        }
        let root = DXFRawRecord(type: "DICTIONARY", groups: [
            group(5, "1"), group(330, "0"),
            group(100, "AcDbDictionary"), group(281, "1"),
            group(3, "AcSheetSetData"), group(350, "2"),
        ])
        let dict = DXFRawRecord(type: "DICTIONARY", groups: [
            group(5, "2"), group(330, "1"),
            group(100, "AcDbDictionary"), group(281, "1"),
            group(3, "ShSetFileName"), group(350, "3"),
        ])
        let xrec = DXFRawRecord(type: "XRECORD", groups: [
            group(5, "3"), group(330, "2"),
            group(100, "AcDbXRecord"), group(280, "1"),
            group(1, "C:\\orig\\kept.dst"),
        ])
        let writer = DXFWriter()
        writer.preservedObjects = [root, dict, xrec]
        writer.sheetSetHint = DXFSheetSetHint(dstPath: "C:\\job\\other.dst")
        let reader = try DXFReader().readString(writer.writeToString())
        let found = SheetSetNODHint.read(reader: reader)
        XCTAssertEqual(found?.dstPath, "C:\\orig\\kept.dst")
        let names = reader.objectDictionaryNameByHandle.values
            .filter { $0.caseInsensitiveCompare("AcSheetSetData") == .orderedSame }
        XCTAssertEqual(names.count, 1)
    }
}
