import XCTest
import Foundation
@testable import ZephyrCore

/// NOD `AcSheetSetData` hint: SSLOCATE's first lookup before the MRU
/// index. Fixtures are hand-built DXF OBJECTS sections; group-code
/// layout follows the public AutoLISP pattern
/// `(dictsearch (namedobjdict) "AcSheetSetData")` → walk to the
/// `ShSetFileName` XRECORD.
@MainActor
final class SheetSetNODHintTests: XCTestCase {

    private func writeDXF(_ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("plan.dxf")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func hint(for content: String) throws -> SheetSetNODHint.Hint? {
        let reader = try DXFReader().readString(content)
        return SheetSetNODHint.read(reader: reader)
    }

    func testHintFoundWithDwgAndHandle() throws {
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        ShSetFileName
        350
        2C
        3
        SheetDwgName
        350
        2D
        3
        LayoutHandle
        350
        2E
        0
        XRECORD
        5
        2C
        1
        C:\\job\\site.dst
        0
        XRECORD
        5
        2D
        1
        plan.dxf
        0
        XRECORD
        5
        2E
        1
        AB
        0
        ENDSEC
        0
        EOF
        """
        let found = try hint(for: body)
        XCTAssertEqual(found?.dstPath, "C:\\job\\site.dst")
        XCTAssertEqual(found?.dwgName, "plan.dxf")
        XCTAssertEqual(found?.layoutHandle, "AB")
    }

    func testLayoutHandleSkipsOwnHandlePair() throws {
        // Handle stored as a second group-5 pair: the first 5 is the
        // XRECORD's own handle ("2E") and must not win over the value.
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        ShSetFileName
        350
        2C
        3
        LayoutHandle
        350
        2E
        0
        XRECORD
        5
        2C
        1
        C:\\job\\site.dst
        0
        XRECORD
        5
        2E
        5
        AB
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertEqual(try hint(for: body)?.layoutHandle, "AB")
    }

    func testMissingDictionaryReturnsNil() throws {
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        ACAD_PLOTSETTINGS
        350
        2B
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertNil(try hint(for: body))
    }

    func testMissingFileNameEntryReturnsNil() throws {
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        SheetDwgName
        350
        2D
        0
        XRECORD
        5
        2D
        1
        plan.dxf
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertNil(try hint(for: body))
    }

    func testEmptyFileNameReturnsNil() throws {
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        ShSetFileName
        350
        2C
        0
        XRECORD
        5
        2C
        1

        0
        ENDSEC
        0
        EOF
        """
        XCTAssertNil(try hint(for: body))
    }

    func testNamesMatchCaseInsensitively() throws {
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        ACSHEETSETDATA
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        shsetfilename
        350
        2C
        0
        XRECORD
        5
        2C
        1
        C:\\job\\site.dst
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertEqual(try hint(for: body)?.dstPath, "C:\\job\\site.dst")
    }

    func testReadFileRejectsNonDXF() {
        XCTAssertNil(SheetSetNODHint.readFile(atPath: "C:\\job\\plan.dwg"))
        XCTAssertNil(SheetSetNODHint.readFile(atPath: "/nonexistent/plan.dxf"))
    }

    func testReadFileFindsHintOnDisk() throws {
        let dstDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dstPath = dstDir.appendingPathComponent("site.dst").path
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        ShSetFileName
        350
        2C
        0
        XRECORD
        5
        2C
        1
        \(dstPath)
        0
        ENDSEC
        0
        EOF
        """
        let dxfURL = try writeDXF(body)
        XCTAssertEqual(SheetSetNODHint.readFile(atPath: dxfURL.path)?.dstPath, dstPath)
    }

    func testResolveKeepsAbsoluteAndJoinsRelative() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let drawing = dir.appendingPathComponent("plan.dxf").path
        let absolute = dir.appendingPathComponent("site.dst").path
        XCTAssertEqual(SheetSetNODHint.resolve(dstPath: absolute, relativeTo: drawing), absolute)
        XCTAssertEqual(
            SheetSetNODHint.resolve(dstPath: "site.dst", relativeTo: drawing),
            dir.appendingPathComponent("site.dst").path)
    }

    func testAutoOpenPrefersNODHintOverMRU() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetNODTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dstURL = dir.appendingPathComponent("site.dst")
        let xml = "<AcSmDatabase><AcSmSheetSet><AcSmProp propname=\"Name\" vt=\"8\">Site</AcSmProp></AcSmSheetSet></AcSmDatabase>"
        try SheetSetDST.encode(xml).write(to: dstURL)
        let body = """
        0
        SECTION
        2
        OBJECTS
        0
        DICTIONARY
        5
        1A
        3
        AcSheetSetData
        350
        2B
        0
        DICTIONARY
        5
        2B
        3
        ShSetFileName
        350
        2C
        0
        XRECORD
        5
        2C
        1
        \(dstURL.path)
        0
        ENDSEC
        0
        EOF
        """
        let dxfURL = dir.appendingPathComponent("plan.dxf")
        try body.write(to: dxfURL, atomically: true, encoding: .utf8)
        let processor = CADCommandProcessor()
        XCTAssertNil(processor.sheetSetStore.current)
        processor.autoOpenSheetSet(for: dxfURL.path)
        XCTAssertEqual(processor.sheetSetStore.current?.name, "Site")
        XCTAssertEqual(SheetSetSysvars.lastFoundPath, dstURL.path)
    }

    override func tearDown() {
        SheetSetSysvars.lastFoundPath = ""
        super.tearDown()
    }
}
