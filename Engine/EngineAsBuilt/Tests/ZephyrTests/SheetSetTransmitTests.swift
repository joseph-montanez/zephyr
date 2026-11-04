import XCTest
import Foundation
@testable import ZephyrCore

/// eTransmit-style archive: scope parsing, selsets opaque preservation,
/// lock preflight, transmit planning, and package execution. The command
/// surface (`-TRANSMITSET` arg parsing) is covered here; printing itself
/// is covered by the manual interactive run.
@MainActor
final class SheetSetTransmitTests: XCTestCase {

    private func makeSet(
        dstPath: String,
        sheets: [SheetSetSheet] = [],
        subsets: [SheetSetSubset] = [],
        selections: [SheetSetSelection] = []
    ) -> SheetSet {
        SheetSet(name: "T", dstPath: dstPath, sheets: sheets, subsets: subsets, selections: selections)
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transmit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(at url: URL, text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Scope parsing

    func testParseScopeForms() {
        XCTAssertEqual(SheetSetTransmit.parseScope(""), .all)
        XCTAssertEqual(SheetSetTransmit.parseScope("*"), .all)
        XCTAssertEqual(SheetSetTransmit.parseScope("SUBSET:Demo Set"), .subset(name: "Demo Set"))
        XCTAssertEqual(SheetSetTransmit.parseScope("sheets:A-101,a-102"), .sheets(numbers: ["A-101", "a-102"]))
        XCTAssertEqual(SheetSetTransmit.parseScope("Selection:Pkg"), .selection(name: "Pkg"))
        XCTAssertNil(SheetSetTransmit.parseScope("Demo"), "bare names are rejected, never guessed")
        XCTAssertNil(SheetSetTransmit.parseScope("subset:"), "empty subset name")
        XCTAssertNil(SheetSetTransmit.parseScope("sheets: ,"), "empty sheet list")
        XCTAssertNil(SheetSetTransmit.parseScope("bogus:x"), "unknown prefix")
    }

    func testParseTransmitSetArgs() {
        let full = CADCommandProcessor.parseTransmitSetArgs("\"C:/s/a.dst\" \"C:/pkg\" subset:\"Demo Set\"")
        XCTAssertNil(full.error)
        XCTAssertEqual(full.dstPath, "C:/s/a.dst")
        XCTAssertEqual(full.folder, "C:/pkg")
        XCTAssertEqual(full.scope, .subset(name: "Demo Set"))
        let minimal = CADCommandProcessor.parseTransmitSetArgs("\"C:/s/a.dst\" \"C:/pkg\"")
        XCTAssertNil(minimal.error)
        XCTAssertEqual(minimal.scope, .all)
        XCTAssertNotNil(CADCommandProcessor.parseTransmitSetArgs("\"C:/s/a.dst\"").error, "folder required")
        XCTAssertNotNil(CADCommandProcessor.parseTransmitSetArgs("").error)
        let badScope = CADCommandProcessor.parseTransmitSetArgs("\"C:/s/a.dst\" \"C:/pkg\" Demo")
        XCTAssertTrue(badScope.error?.contains("Unknown scope") ?? false)
    }

    // MARK: - SelSets opaque preservation

    private func selSetFixture(selSets: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <AcSmDatabase clsid="gdb" ID="g1">
        <AcSmSheetSet clsid="g2" ID="g3" propname="SheetSet" vt="13">
        <AcSmProp propname="Name" vt="8">SetName</AcSmProp>
        <AcSmSheet clsid="g4" ID="s1">
        <AcSmProp propname="Number" vt="8">A-101</AcSmProp>
        <AcSmProp propname="Title" vt="8">Plan</AcSmProp>
        <AcSmAcDbLayoutReference propname="Layout">
        <AcSmProp propname="FileName" vt="8">C:/drawings/a.dwg</AcSmProp>
        <AcSmProp propname="Name" vt="8">Layout1</AcSmProp>
        </AcSmAcDbLayoutReference>
        </AcSmSheet>
        \(selSets)
        </AcSmSheetSet>
        </AcSmDatabase>
        """
    }

    func testSelSetsBlockExtraction() {
        let paired = "<AcSmSheetSelSets clsid=\"gx\" ID=\"g9\" propname=\"SheetSelSets\" vt=\"13\">\n<AcSmSheetSelSet ID=\"s1\" />\n</AcSmSheetSelSets>"
        XCTAssertEqual(SheetSetDST.selSetsBlock(xml: selSetFixture(selSets: paired)), paired)
        let selfClosed = "<AcSmSheetSelSets clsid=\"gx\" ID=\"g9\" propname=\"SheetSelSets\" vt=\"13\" />"
        XCTAssertEqual(SheetSetDST.selSetsBlock(xml: selSetFixture(selSets: selfClosed)), selfClosed)
        XCTAssertNil(SheetSetDST.selSetsBlock(xml: selSetFixture(selSets: "")))
        XCTAssertNil(
            SheetSetDST.selSetsBlock(xml: "<AcSmSheetSelSetsFoo ID=\"g1\" />"),
            "look-alike tag must not match")
    }

    func testPreservationRoundTrip() throws {
        let block = "<AcSmSheetSelSets clsid=\"gx\" ID=\"g9\" propname=\"SheetSelSets\" vt=\"13\">\n<AcSmSheetSelSet ID=\"s1\"><AcSmProp propname=\"Name\" vt=\"8\">Demo</AcSmProp></AcSmSheetSelSet>\n</AcSmSheetSelSets>"
        var store = SheetSetStore()
        let set = store.open(dstPath: "C:/s/a.dst", xml: selSetFixture(selSets: block))
        XCTAssertEqual(set.preservedSelSetsXML, block)
        let xml = try SheetSetXML.serialize(set)
        XCTAssertTrue(xml.contains(block), "verbatim block survives save")
        XCTAssertEqual(set.sheets.count, 1, "sheets still parse around the block")
        // No selsets at all: writer emits the empty status-quo element.
        var bare = SheetSetStore()
        let bareSet = bare.open(dstPath: "C:/s/b.dst", xml: selSetFixture(selSets: ""))
        XCTAssertNil(bareSet.preservedSelSetsXML)
        let bareXML = try SheetSetXML.serialize(bareSet)
        XCTAssertTrue(bareXML.contains("<AcSmSheetSelSets "))
    }

    // MARK: - Lock preflight

    func testMemberLockStates() throws {
        let dir = try scratchDir()
        let drawing = dir.appendingPathComponent("a.dwg")
        try writeFile(at: drawing, text: "x")
        XCTAssertEqual(SheetSetLocks.memberLock(drawingPath: drawing.path), .available)
        XCTAssertEqual(SheetSetLocks.memberLock(drawingPath: dir.appendingPathComponent("gone.dwg").path), .missing)
        XCTAssertEqual(SheetSetLocks.memberLock(drawingPath: ""), .missing)
        XCTAssertEqual(SheetSetLocks.memberLock(drawingPath: dir.path), .missing, "directories are not drawings")
        // Editor sidecar with an owner line.
        try writeFile(at: dir.appendingPathComponent("a.dwl"), text: "jdoe on WS-7\nsecond line")
        let locked = SheetSetLocks.memberLock(drawingPath: drawing.path)
        XCTAssertEqual(locked, .locked(detail: "jdoe on WS-7"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.dwl"))
        // XML sidecar: presence only, no owner decode.
        try writeFile(at: dir.appendingPathComponent("a.dwl2"), text: "<whohas/>")
        XCTAssertEqual(
            SheetSetLocks.memberLock(drawingPath: drawing.path),
            .locked(detail: "editor lock file present (.dwl2)"))
    }

    func testSetLockFollowsDblPresence() {
        let store = SheetSetStore()
        XCTAssertFalse(store.lockStatus(dstPath: "/s/a.dst").locked)
        XCTAssertFalse(store.lockStatus(dstPath: "").locked)
    }

    func testSetLockDetectsDbl() throws {
        let dir = try scratchDir()
        let dst = dir.appendingPathComponent("a.dst")
        try writeFile(at: dst, text: "dst")
        let store = SheetSetStore()
        XCTAssertFalse(store.lockStatus(dstPath: dst.path).locked)
        try writeFile(at: dir.appendingPathComponent("a.dbl"), text: "lock")
        let status = store.lockStatus(dstPath: dst.path)
        XCTAssertTrue(status.locked)
        XCTAssertTrue(status.detail?.contains("a.dbl") ?? false)
    }

    // MARK: - Plan

    func testPlanAllDedupesAndMapsTree() throws {
        let dir = try scratchDir()
        let sub = dir.appendingPathComponent("plans")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = sub.appendingPathComponent("a.dwg")
        try writeFile(at: a, text: "A")
        let set = makeSet(dstPath: dir.appendingPathComponent("pkg.dst").path, sheets: [
            SheetSetSheet(number: "A-101", title: "Plan", absoluteFile: a.path),
            SheetSetSheet(number: "A-102", title: "Same file", absoluteFile: a.path),
            SheetSetSheet(number: "A-103", title: "Gone", absoluteFile: dir.appendingPathComponent("gone.dwg").path),
            SheetSetSheet(number: "", title: "", absoluteFile: ""),
        ])
        let plan = SheetSetTransmit.plan(set: set, scope: .all, dstLocked: false)
        XCTAssertNil(plan.scopeError)
        XCTAssertEqual(plan.files.count, 3, "dst + a.dwg + gone.dwg (same file once)")
        XCTAssertNil(plan.files[0].sheetLabel, "first file is the .dst")
        XCTAssertEqual(plan.files[1].relativePath, "plans/a.dwg", "tree under the dst folder preserved")
        XCTAssertEqual(plan.files[1].lock, .available)
        XCTAssertEqual(plan.files[2].lock, .missing)
        XCTAssertEqual(plan.unresolved, ["(untitled sheet)"])
    }

    func testPlanOutsideTreeUsesBasenameWithCollisionSuffix() {
        let set = makeSet(dstPath: "/pkg/a.dst", sheets: [
            SheetSetSheet(number: "A-1", absoluteFile: "/x1/same.dwg"),
            SheetSetSheet(number: "A-2", absoluteFile: "/x2/same.dwg"),
        ])
        let plan = SheetSetTransmit.plan(set: set, scope: .all, dstLocked: true)
        XCTAssertTrue(plan.dstLocked)
        XCTAssertEqual(plan.files[1].relativePath, "same.dwg")
        XCTAssertEqual(plan.files[2].relativePath, "same (2).dwg")
    }

    func testPlanScopes() {
        let inner = SheetSetSubset(name: "Inner", sheets: [SheetSetSheet(number: "A-2", title: "Two")])
        let demo = SheetSetSubset(name: "Demo Set", sheets: [SheetSetSheet(number: "A-1", title: "One")], subsets: [inner])
        let other = SheetSetSubset(name: "Other", sheets: [SheetSetSheet(number: "A-9", title: "Nine")])
        let set = makeSet(
            dstPath: "/pkg/a.dst",
            sheets: [SheetSetSheet(number: "A-0", title: "Loose")],
            subsets: [demo, other],
            selections: [SheetSetSelection(name: "Pkg", sheetIDs: ["nope"])])
        let (subSheets, _, subError) = SheetSetTransmit.scopeSheets(set: set, scope: .subset(name: "demo set"))
        XCTAssertNil(subError)
        XCTAssertEqual(subSheets.map(\.number), ["A-1", "A-2"], "case-insensitive, depth-first")
        let (_, _, unknownSub) = SheetSetTransmit.scopeSheets(set: set, scope: .subset(name: "Nope"))
        XCTAssertTrue(unknownSub?.contains("Nope") ?? false)
        let (numSheets, _, numError) = SheetSetTransmit.scopeSheets(
            set: set, scope: .sheets(numbers: ["a-0", "A-9"]))
        XCTAssertNil(numError)
        XCTAssertEqual(numSheets.map(\.number), ["A-0", "A-9"])
        let (_, _, unknownNum) = SheetSetTransmit.scopeSheets(set: set, scope: .sheets(numbers: ["A-0", "ZZ"]))
        XCTAssertTrue(unknownNum?.contains("ZZ") ?? false)
        let (_, dangling, selError) = SheetSetTransmit.scopeSheets(set: set, scope: .selection(name: "pkg"))
        XCTAssertNil(selError)
        XCTAssertEqual(dangling.count, 1, "dangling IDs surface instead of vanishing")
        XCTAssertTrue(dangling[0].contains("nope"))
        let (_, _, unknownSel) = SheetSetTransmit.scopeSheets(set: set, scope: .selection(name: "Nope"))
        XCTAssertTrue(unknownSel?.contains("Pkg") ?? false, "error lists known selections")
    }

    // MARK: - Execute

    func testExecuteCopiesTreeAndSkipsMissing() throws {
        let src = try scratchDir()
        let sub = src.appendingPathComponent("plans")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(at: src.appendingPathComponent("pkg.dst"), text: "DST")
        try writeFile(at: sub.appendingPathComponent("a.dwg"), text: "A")
        let set = makeSet(dstPath: src.appendingPathComponent("pkg.dst").path, sheets: [
            SheetSetSheet(number: "A-101", title: "Plan", absoluteFile: sub.appendingPathComponent("a.dwg").path),
            SheetSetSheet(number: "A-103", title: "Gone", absoluteFile: src.appendingPathComponent("gone.dwg").path),
        ])
        let plan = SheetSetTransmit.plan(set: set, scope: .all, dstLocked: false)
        let dest = try scratchDir()
        let report = try SheetSetTransmit.execute(plan: plan, to: dest)
        XCTAssertEqual(report.copiedCount, 2)
        XCTAssertEqual(report.results.count, 3)
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("pkg.dst"), encoding: .utf8), "DST",
            ".dst copied byte-identical")
        XCTAssertEqual(
            try String(contentsOf: dest.appendingPathComponent("plans/a.dwg"), encoding: .utf8), "A")
        let missing = try XCTUnwrap(report.results.first(where: { $0.file.lock == .missing }))
        XCTAssertEqual(missing.outcome, .skippedMissing)
    }

    func testExecuteFlagsLockedSource() throws {
        let src = try scratchDir()
        try writeFile(at: src.appendingPathComponent("pkg.dst"), text: "DST")
        let drawing = src.appendingPathComponent("a.dwg")
        try writeFile(at: drawing, text: "A")
        try writeFile(at: src.appendingPathComponent("a.dwl"), text: "jdoe")
        let set = makeSet(dstPath: src.appendingPathComponent("pkg.dst").path, sheets: [
            SheetSetSheet(number: "A-101", title: "Plan", absoluteFile: drawing.path),
        ])
        let plan = SheetSetTransmit.plan(set: set, scope: .all, dstLocked: false)
        XCTAssertEqual(plan.files[1].lock, .locked(detail: "jdoe"))
        let report = try SheetSetTransmit.execute(plan: plan, to: try scratchDir())
        XCTAssertEqual(report.copiedCount, 2, "locked sources still copy, flagged")
        let flagged = try XCTUnwrap(report.results.first(where: { $0.file.sheetLabel != nil }))
        XCTAssertEqual(flagged.outcome, .copied(fromLocked: true))
    }
}
