import XCTest
import Foundation
@testable import ZephyrCore

/// Step 3: command-line flows for NEWSHEETSET / OPENSHEETSET / SHEETSET /
/// SHEETSETHIDE, plus .dbl lock detection. Headless: engine == nil, so the
/// NativeFileDialog branch is not exercised here.
@MainActor
final class SheetSetCommandTests: XCTestCase {

    private func sampleXML() -> String {
        """
        <AcSmDatabase><AcSmSheetSet><AcSmProp propname="Name" vt="8">TI Set</AcSmProp><AcSmSheet ID="g1"><AcSmProp propname="Number" vt="8">A101</AcSmProp><AcSmProp propname="Title" vt="8\">Plan</AcSmProp><AcSmAcDbLayoutReference><AcSmProp propname="Relative_FileName" vt="8\">.\\A.dwg</AcSmProp><AcSmProp propname="FileName" vt="8\">C:\\job\\A.dwg</AcSmProp><AcSmProp propname="AcDbHandle" vt="8\">1F2</AcSmProp><AcSmProp propname="Name" vt="8\">Layout1</AcSmProp></AcSmAcDbLayoutReference></AcSmSheet></AcSmSheetSet></AcSmDatabase>
        """
    }

    private func writeSampleDST() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetCmdTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ti.dst")
        try SheetSetDST.encode(sampleXML()).write(to: url)
        return url
    }

    override func tearDown() {
        SheetSetSysvars.managerOpen = false
        SheetSetSysvars.lastFoundPath = ""
        super.tearDown()
    }

    func testVerbAndArgParsing() {
        XCTAssertEqual(CADCommandProcessor.sheetSetVerbAndArg(text: "SHEETSET", upper: "SHEETSET").verb, "SHEETSET")
        let parsed = CADCommandProcessor.sheetSetVerbAndArg(text: "OPENSHEETSET \"C:/a b.dst\"", upper: "OPENSHEETSET \"C:/A B.DST\"")
        XCTAssertEqual(parsed.verb, "OPENSHEETSET")
        XCTAssertEqual(CADCommandProcessor.splitSheetSetArgs(parsed.arg), ["C:/a b.dst"])
        XCTAssertEqual(CADCommandProcessor.splitSheetSetArgs("\"TI Set\" C:/job/ti.dst"), ["TI Set", "C:/job/ti.dst"])
    }

    func testNewSheetSetCreatesCurrentInMemorySet() {
        let processor = CADCommandProcessor()
        processor.executeCommand("NEWSHEETSET \"TI Set\"")
        XCTAssertEqual(processor.sheetSetStore.current?.name, "TI Set")
        XCTAssertEqual(processor.sheetSetStore.current?.allSheetsInOrder.count, 0)
    }

    func testOpenSheetSetLoadsZeroDWGSheets() throws {
        let url = try writeSampleDST()
        let processor = CADCommandProcessor()
        processor.executeCommand("OPENSHEETSET \"\(url.path)\"")
        let current = processor.sheetSetStore.current
        XCTAssertEqual(current?.name, "TI Set")
        XCTAssertEqual(current?.allSheetsInOrder.count, 1)
        XCTAssertEqual(current?.allSheetsInOrder.first?.handle, "1F2")
        XCTAssertEqual(SheetSetSysvars.lastFoundPath, url.path)
        // MRU backs SSLOCATE for member drawings.
        XCTAssertEqual(processor.sheetSetStore.locate(dwgPath: "c:/JOB/a.dwg"), url.path)
    }

    func testNewSheetSetWithPathWritesReadableDST() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetCmdWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("new set.dst").path
        let writer = CADCommandProcessor()
        writer.executeCommand("NEWSHEETSET \"TI Set\" \"\(dst)\"")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst))
        let reader = CADCommandProcessor()
        reader.executeCommand("OPENSHEETSET \"\(dst)\"")
        XCTAssertEqual(reader.sheetSetStore.current?.name, "TI Set")
        XCTAssertEqual(reader.sheetSetStore.current?.allSheetsInOrder.count, 0)
    }

    func testNotifySeamFiresWithPath() {
        let manager = TabManager()
        var seen: [String] = []
        manager.onDrawingOpened = { seen.append($0) }
        manager.notifyDrawingOpened(path: "C:/job/a.dwg")
        XCTAssertEqual(seen, ["C:/job/a.dwg"])
    }

    func testAutoOpenSheetSetViaMRU() throws {
        let savedLocate = SheetSetSysvars.sslocate
        let savedAutoOpen = SheetSetSysvars.ssmAutoOpen
        defer {
            SheetSetSysvars.sslocate = savedLocate
            SheetSetSysvars.ssmAutoOpen = savedAutoOpen
        }
        let url = try writeSampleDST()
        let processor = CADCommandProcessor()
        processor.sheetSetStore.mru.register(dstPath: url.path, dwgPaths: ["C:/job/A.dwg"])
        SheetSetSysvars.sslocate = 1
        SheetSetSysvars.ssmAutoOpen = 1
        processor.autoOpenSheetSet(for: "c:/JOB/a.dwg")
        XCTAssertEqual(processor.sheetSetStore.current?.name, "TI Set")
        XCTAssertTrue(SheetSetSysvars.managerOpen)
        XCTAssertEqual(SheetSetSysvars.lastFoundPath, url.path)
    }

    func testAutoOpenRespectsSysvars() throws {
        let savedLocate = SheetSetSysvars.sslocate
        let savedAutoOpen = SheetSetSysvars.ssmAutoOpen
        defer {
            SheetSetSysvars.sslocate = savedLocate
            SheetSetSysvars.ssmAutoOpen = savedAutoOpen
        }
        let url = try writeSampleDST()
        // SSLOCATE off: no-op even with an MRU hit.
        let dormant = CADCommandProcessor()
        dormant.sheetSetStore.mru.register(dstPath: url.path, dwgPaths: ["C:/job/A.dwg"])
        SheetSetSysvars.sslocate = 0
        dormant.autoOpenSheetSet(for: "C:/job/A.dwg")
        XCTAssertNil(dormant.sheetSetStore.current)
        // SSMAUTOOPEN off: set opens and becomes current, manager stays shut.
        let quiet = CADCommandProcessor()
        quiet.sheetSetStore.mru.register(dstPath: url.path, dwgPaths: ["C:/job/A.dwg"])
        SheetSetSysvars.sslocate = 1
        SheetSetSysvars.ssmAutoOpen = 0
        SheetSetSysvars.managerOpen = false
        quiet.autoOpenSheetSet(for: "C:/job/A.dwg")
        XCTAssertEqual(quiet.sheetSetStore.current?.name, "TI Set")
        XCTAssertFalse(SheetSetSysvars.managerOpen)
        // Unknown drawing: no-op, never throws.
        quiet.autoOpenSheetSet(for: "C:/job/unknown.dwg")
        XCTAssertEqual(quiet.sheetSetStore.openSets.count, 1)
    }

    func testPublishSetRejectsMissingOverrideFile() throws {
        let url = try writeSampleDST()
        let processor = CADCommandProcessor()
        processor.executeCommand("-PUBLISHSET \"\(url.path)\" \"ANSI A\" \"C:/nope/border.dwt\"")
        XCTAssertTrue(processor.sheetSetStore.openSets.isEmpty)
    }

    private func writePublishSetScratch() throws -> (dir: URL, dst: URL, master: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SheetSetParseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let master = dir.appendingPathComponent("border.dwt")
        try "0\nSECTION\n2\nOBJECTS\n0\nENDSEC\n0\nEOF\n".write(to: master, atomically: true, encoding: .utf8)
        return (dir, dir.appendingPathComponent("site.dst"), master)
    }

    func testPublishSetArgsParseSetupAndFile() throws {
        let scratch = try writePublishSetScratch()
        let parsed = CADCommandProcessor.parsePublishSetArgs(
            "\"\(scratch.dst.path)\" \"ANSI A\" \"\(scratch.master.path)\"")
        XCTAssertNil(parsed.error)
        XCTAssertEqual(parsed.dstPath, scratch.dst.path)
        XCTAssertEqual(parsed.setup, "ANSI A")
        XCTAssertEqual(parsed.overrideFile, scratch.master.path)
    }

    func testPublishSetArgsRejectLoneExistingFile() throws {
        let scratch = try writePublishSetScratch()
        let parsed = CADCommandProcessor.parsePublishSetArgs(
            "\"\(scratch.dst.path)\" \"\(scratch.master.path)\"")
        XCTAssertNotNil(parsed.error)
        XCTAssertTrue(parsed.error?.contains("needs a setup name") ?? false)
        XCTAssertNil(parsed.overrideFile)
    }

    func testPublishSetArgsResolveRelativeFileBesideDST() throws {
        let scratch = try writePublishSetScratch()
        let parsed = CADCommandProcessor.parsePublishSetArgs(
            "\"\(scratch.dst.path)\" \"ANSI A\" border.dwt")
        XCTAssertNil(parsed.error)
        XCTAssertEqual(parsed.overrideFile, scratch.master.path)
    }

    func testPublishSetArgsMissingFile() throws {
        let scratch = try writePublishSetScratch()
        let parsed = CADCommandProcessor.parsePublishSetArgs(
            "\"\(scratch.dst.path)\" \"ANSI A\" \"C:/nope/border.dwt\"")
        XCTAssertTrue(parsed.error?.contains("not found") ?? false)
        XCTAssertNil(parsed.overrideFile)
    }

    func testPublishSetArgsBareDSTAndEmpty() throws {
        let scratch = try writePublishSetScratch()
        let bare = CADCommandProcessor.parsePublishSetArgs("\"\(scratch.dst.path)\"")
        XCTAssertNil(bare.error)
        XCTAssertNil(bare.setup)
        XCTAssertNil(bare.overrideFile)
        let empty = CADCommandProcessor.parsePublishSetArgs("")
        XCTAssertNotNil(empty.error)
    }

    func testSaveCurrentRoundTripsMutations() throws {
        let url = try writeSampleDST()
        let processor = CADCommandProcessor()
        processor.executeCommand("OPENSHEETSET \"\(url.path)\"")
        let id = try XCTUnwrap(processor.sheetSetStore.current?.allSheetsInOrder.first?.id)
        XCTAssertTrue(processor.sheetSetStore.updateCurrent {
            $0.renameSheet(id: id, number: "A900", title: "Renamed")
            $0.subsets.append(SheetSetSubset(name: "Added"))
        })
        XCTAssertEqual(try processor.sheetSetStore.saveCurrent(), url.path)
        let reader = CADCommandProcessor()
        reader.executeCommand("OPENSHEETSET \"\(url.path)\"")
        XCTAssertEqual(reader.sheetSetStore.current?.sheet(id: id)?.title, "Renamed")
        XCTAssertEqual(reader.sheetSetStore.current?.sheet(id: id)?.number, "A900")
        XCTAssertTrue(reader.sheetSetStore.current?.subsets.map(\.name).contains("Added") ?? false)
        var empty = SheetSetStore()
        empty.register(SheetSet(name: "NoPath"))
        XCTAssertThrowsError(try empty.saveCurrent())
        XCTAssertThrowsError(try SheetSetStore().saveCurrent())
        var bare = SheetSetStore()
        XCTAssertFalse(bare.updateCurrent { _ in })
    }

    func testShowAndHideManager() {
        let processor = CADCommandProcessor()
        processor.executeCommand("NEWSHEETSET Demo")
        processor.executeCommand("SHEETSET")
        XCTAssertTrue(SheetSetSysvars.managerOpen)
        XCTAssertEqual(processor.sheetSetStore.current?.name, "Demo")
        processor.executeCommand("SHEETSETHIDE")
        XCTAssertFalse(SheetSetSysvars.managerOpen)
    }

    func testDblBesideDstMeansLocked() throws {
        let url = try writeSampleDST()
        let processor = CADCommandProcessor()
        processor.executeCommand("OPENSHEETSET \"\(url.path)\"")
        XCTAssertFalse(processor.sheetSetStore.lockStatus(dstPath: url.path).locked)
        let dbl = url.deletingPathExtension().appendingPathExtension("dbl")
        try "locked".write(to: dbl, atomically: true, encoding: .utf8)
        let status = processor.sheetSetStore.lockStatus(dstPath: url.path)
        XCTAssertTrue(status.locked)
        XCTAssertNotNil(status.detail)
    }

    func testSheetSysvarDefaultsAndValidation() {
        let saved = (SheetSetSysvars.sslocate, SheetSetSysvars.ssmAutoOpen, SheetSetSysvars.ssmPollTime, SheetSetSysvars.ssmSheetStatus, SheetSetSysvars.updateThumbnail)
        defer {
            SheetSetSysvars.sslocate = saved.0
            SheetSetSysvars.ssmAutoOpen = saved.1
            SheetSetSysvars.ssmPollTime = saved.2
            SheetSetSysvars.ssmSheetStatus = saved.3
            SheetSetSysvars.updateThumbnail = saved.4
        }
        let doc = CADDocument()
        let vars = LispVarStore()
        XCTAssertEqual(vars.get("SSLOCATE", document: doc, activeCommand: nil), .int(1))
        XCTAssertEqual(vars.get("SSFOUND", document: doc, activeCommand: nil), .string(""))
        XCTAssertEqual(vars.get("SSMSTATE", document: doc, activeCommand: nil), .int(0))
        XCTAssertNil(vars.set("SSLOCATE", .int(0), document: doc))
        XCTAssertEqual(vars.get("SSLOCATE", document: doc, activeCommand: nil), .int(0))
        XCTAssertNotNil(vars.set("SSLOCATE", .int(2), document: doc))
        XCTAssertNotNil(vars.set("SSFOUND", .string("x"), document: doc))
        XCTAssertNotNil(vars.set("SSMSTATE", .int(1), document: doc))
    }
}
