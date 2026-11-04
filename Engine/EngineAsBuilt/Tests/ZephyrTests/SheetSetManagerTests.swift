import XCTest
import Foundation
@testable import ZephyrCore

/// Step 8: Sheet List rows + inspector details stay pinned here so the
/// ImGui palette (untestable headless) renders exactly this.
final class SheetSetManagerTests: XCTestCase {

    private func sampleSet() -> SheetSet {
        var set = SheetSet(name: "TI Set", dstPath: "C:/job/ti.dst")
        set.sheets = [
            SheetSetSheet(number: "A100", title: "Cover", absoluteFile: "C:/job/a.dwg", handle: "1A", layoutName: "Layout1"),
            SheetSetSheet(number: "A101", title: "", absoluteFile: "C:/job/a.dwg", handle: "1B", layoutName: "Layout2", includeForPlot: false),
        ]
        set.subsets = [
            SheetSetSubset(name: "Arch", subsets: [
                SheetSetSubset(name: "Plans", publishSheets: false, sheets: [
                    SheetSetSheet(number: "A201", title: "Plan", absoluteFile: "C:/job/b.dwg", handle: "2A", layoutName: "Plan"),
                ]),
            ]),
        ]
        return set
    }

    func testRowsFollowDisplayOrderWithDepth() {
        let rows = SheetSetManagerViewModel.rows(for: sampleSet())
        XCTAssertEqual(rows.map(\.title), [
            "A100 Cover",
            "A101 [no plot]",
            "[Arch]",
            "[Plans] [publish off]",
            "A201 Plan",
        ])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0, 1, 2])
        XCTAssertEqual(rows.map(\.kind), [.sheet, .sheet, .subset, .subset, .sheet])
        XCTAssertEqual(rows[4].subtitle, "b.dwg")
    }

    func testDetailsCoverSetAndSelectedSheet() {
        let set = sampleSet()
        let setLines = SheetSetManagerViewModel.details(for: set, sheetID: nil, locked: false)
        XCTAssertTrue(setLines.contains("Set: TI Set"))
        XCTAssertTrue(setLines.contains("Sheets: 3"))
        XCTAssertTrue(setLines.contains("Lock: available"))

        let sheetID = set.allSheetsInOrder[2].id
        let sheetLines = SheetSetManagerViewModel.details(for: set, sheetID: sheetID, locked: true)
        XCTAssertTrue(sheetLines.contains("Number: A201"))
        XCTAssertTrue(sheetLines.contains("Title: Plan"))
        XCTAssertTrue(sheetLines.contains("Drawing: C:/job/b.dwg"))
        XCTAssertTrue(sheetLines.contains("Lock: locked by another session"))
    }

    func testModelViewFoldersUnionConfiguredAndMemberDirs() {
        var set = SheetSet(name: "S", dstPath: "C:/job/s.dst", modelViewFolders: ["C:/lib", ""])
        set.sheets = [
            SheetSetSheet(number: "A1", absoluteFile: "C:/job/a.dwg"),
            SheetSetSheet(number: "A2", absoluteFile: "c:\\JOB\\b.dwg"),
            SheetSetSheet(number: "A3", absoluteFile: ""),
        ]
        XCTAssertEqual(
            SheetSetManagerViewModel.modelViewFolders(for: set),
            ["C:/job", "C:/lib"])
        XCTAssertEqual(
            SheetSetManagerViewModel.modelViewFolders(for: SheetSet(name: "Empty")),
            [])
    }

    func testModelViewFileRowsSortByDisplayName() {
        let rows = SheetSetManagerViewModel.modelViewFileRows(
            files: ["C:/d/b.dwg", "C:/d/A.dxf", "C:/d/c.dwt"])
        XCTAssertEqual(rows.map(\.title), ["A.dxf", "b.dwg", "c.dwt"])
        XCTAssertEqual(rows.first?.path, "C:/d/A.dxf")
    }

    func testLayoutImportBuildsLayoutOnlySheets() {
        let meta = PublishDrawingMetadata(
            sourcePath: "C:/job/b.dwg", displayName: "b",
            tabs: [
                PublishDrawingTabMetadata(name: "Model", space: .model),
                PublishDrawingTabMetadata(name: "Plan", space: .layout),
                PublishDrawingTabMetadata(name: "RCP", space: .layout),
            ])
        let sheets = SheetSetLayoutImport.sheets(from: meta, dstFolder: "C:/job")
        XCTAssertEqual(sheets.map(\.layoutName), ["Plan", "RCP"])
        XCTAssertTrue(sheets.allSatisfy { $0.handle.isEmpty && $0.number.isEmpty && $0.title.isEmpty })
        XCTAssertEqual(sheets.first?.absoluteFile, "C:/job/b.dwg")
        XCTAssertEqual(sheets.first?.relativeFile, ".\\b.dwg")
    }

    func testRelativePathFallsBackToAbsolute() {
        XCTAssertEqual(
            SheetSetLayoutImport.relativePath(from: "C:/job", to: "C:/job/sub/a.dwg"),
            ".\\sub\\a.dwg")
        XCTAssertEqual(
            SheetSetLayoutImport.relativePath(from: "C:/job", to: "D:/other/a.dwg"),
            "D:/other/a.dwg")
        XCTAssertEqual(
            SheetSetLayoutImport.relativePath(from: "", to: "C:/job/a.dwg"),
            "C:/job/a.dwg")
        XCTAssertEqual(
            SheetSetLayoutImport.relativePath(from: "C:/JOB/", to: "c:/job/a.dwg"),
            ".\\a.dwg")
    }

    func testBuildSetNestsSubsetsAndPrefixesTitles() {
        let files = [
            SheetSetLayoutImport.ImportFile(path: "C:/job/a.dwg", layouts: ["Plan", "RCP"]),
            SheetSetLayoutImport.ImportFile(path: "C:/job/arch/b.dwg", layouts: ["A101"]),
            SheetSetLayoutImport.ImportFile(path: "C:/job/arch/struct/c.dwg", layouts: ["S101"]),
            SheetSetLayoutImport.ImportFile(path: "C:/job/empty.dwg", layouts: []),
        ]
        let set = SheetSetLayoutImport.buildSet(
            name: "Wiz", description: "D", dstPath: "C:/job/wiz.dst",
            files: files, nestSubsets: true, prefixTitleWithFile: true)
        XCTAssertEqual(set.sheets.map(\.layoutName), ["Plan", "RCP"])
        XCTAssertEqual(set.sheets.first?.title, "a - Plan")
        XCTAssertEqual(set.sheets.first?.relativeFile, ".\\a.dwg")
        XCTAssertEqual(set.subsets.map(\.name), ["arch"])
        XCTAssertEqual(set.subsets.first?.sheets.map(\.layoutName), ["A101"])
        XCTAssertEqual(
            set.subsets.first?.subsets.first?.name, "struct")
        XCTAssertEqual(
            set.subsets.first?.subsets.first?.sheets.map(\.layoutName), ["S101"])
    }

    func testBuildSetFlatSkipsNesting() {
        let files = [
            SheetSetLayoutImport.ImportFile(path: "C:/job/a.dwg", layouts: ["Plan"]),
            SheetSetLayoutImport.ImportFile(path: "C:/job/arch/b.dwg", layouts: ["A101"]),
        ]
        let set = SheetSetLayoutImport.buildSet(
            name: "Wiz", description: "", dstPath: "C:/job/wiz.dst",
            files: files, nestSubsets: false, prefixTitleWithFile: false)
        XCTAssertTrue(set.subsets.isEmpty)
        XCTAssertEqual(set.sheets.map(\.title), ["Plan", "A101"])
    }

    func testCommonRootAndRelativeDir() {
        XCTAssertEqual(
            SheetSetLayoutImport.commonRoot(of: ["C:/job/a.dwg", "c:/JOB/arch/b.dwg"]),
            "C:/job")
        XCTAssertEqual(SheetSetLayoutImport.commonRoot(of: ["C:/a.dwg", "D:/b.dwg"]), "")
        XCTAssertEqual(SheetSetLayoutImport.commonRoot(of: []), "")
        XCTAssertEqual(
            SheetSetLayoutImport.relativeDir(of: "C:/job/a.dwg", under: "C:/job"),
            "")
        XCTAssertEqual(
            SheetSetLayoutImport.relativeDir(of: "C:/job/arch/b.dwg", under: "C:/job"),
            "arch")
        XCTAssertNil(SheetSetLayoutImport.relativeDir(of: "D:/x.dwg", under: "C:/job"))
    }

    func testSheetSetFlagPersistsInUserSettings() throws {
        var settings = UserSettings.default
        settings.sheetSetManagerActive = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertTrue(try JSONDecoder().decode(UserSettings.self, from: data).sheetSetManagerActive)
        XCTAssertFalse(UserSettings.default.sheetSetManagerActive)
    }
}
