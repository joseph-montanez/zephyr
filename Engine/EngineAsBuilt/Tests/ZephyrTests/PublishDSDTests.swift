import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 5: `.dsd` (Drawing Set Description) persistence for the PUBLISH
/// sheet list. Covers option + row round-trips (all three assignment
/// provenances), parse errors, lenient unknown values, section ordering,
/// and value cleaning.
final class PublishDSDTests: XCTestCase {

    private func modelSettings(named name: String) -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1, plotRotation: 1,
            pageSetupName: name,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)",
            plotType: 1, standardScaleType: 0)
        ps.useStandardScale = false
        return ps
    }

    private func jobSpec() -> PublishJobSpec {
        let master = PublishSheetEntry(
            sheetName: "Master-Model",
            drawingID: UUID(),
            sourceDwgPath: "/master/Master.dwg",
            tabName: "Model",
            space: .model,
            defaultSetupName: "PDF A4 - Model",
            defaultSetup: modelSettings(named: "PDF A4 - Model"))
        var borrowed = PublishSheetEntry(
            sheetName: "1-Model",
            drawingID: UUID(),
            sourceDwgPath: "/jobs/1.dwg",
            tabName: "Model",
            space: .model)
        var snapshot = modelSettings(named: "PDF A4 - Model")
        snapshot.pageSetupName = "PDF A4 - Model"
        borrowed.assignment = PublishSetupAssignment(
            mode: .importedMaster, setupName: "PDF A4 - Model",
            masterDwgPath: "/master/Master.dwg", resolvedSetup: snapshot)
        var local = PublishSheetEntry(
            sheetName: "1-Layout1",
            drawingID: borrowed.drawingID,
            sourceDwgPath: "/jobs/1.dwg",
            tabName: "Layout1",
            space: .layout,
            defaultSetupName: "",
            defaultSetup: nil)
        local.assignment = PublishSetupAssignment(
            mode: .namedLocal, setupName: "PDF A3 - Layout",
            resolvedSetup: modelSettings(named: "PDF A3 - Layout"))
        return PublishJobSpec(
            publishTo: .plotterNamedInPageSetup,
            outputDirectory: "/jobs/out",
            fileType: .multiSheetFile,
            namingPolicy: .promptForName,
            targetFileName: "Batch.pdf",
            includeLayerInfo: true,
            mergeControl: .overwriteLines,
            numberOfCopies: 1,
            includePlotStamp: false,
            publishInBackground: false,
            openInViewerWhenDone: true,
            sheets: [master, borrowed, local])
    }

    func testRoundTripPreservesOptionsAndRows() throws {
        let spec = jobSpec()
        let text = PublishDSD.serialize(spec: spec)
        XCTAssertTrue(text.contains("[Job]"))
        XCTAssertTrue(text.contains("[Sheet1]"))
        XCTAssertTrue(text.contains("[Sheet3]"))
        let parsed = try PublishDSD.parse(text)
        XCTAssertEqual(parsed, PublishDSDJob(spec: spec))
    }

    func testRoundTripPDFSingleAuto() throws {
        var spec = jobSpec()
        spec.publishTo = .pdf
        spec.fileType = .singleSheetFiles
        spec.namingPolicy = .autoName
        spec.targetFileName = nil
        spec.mergeControl = .mergeLines
        spec.numberOfCopies = 3
        let parsed = try PublishDSD.parse(PublishDSD.serialize(spec: spec))
        XCTAssertEqual(parsed, PublishDSDJob(spec: spec))
    }

    func testSheetProjectionIsNameOnly() {
        let spec = jobSpec()
        let rows = PublishDSDJob(spec: spec).sheets
        XCTAssertEqual(rows.count, 3)
        // Default provenance keeps the native name, no snapshot.
        XCTAssertEqual(rows[0].assignMode, .default)
        XCTAssertEqual(rows[0].setupName, "")
        XCTAssertEqual(rows[0].defaultSetupName, "PDF A4 - Model")
        // Borrowed provenance keeps names + master path.
        XCTAssertEqual(rows[1].assignMode, .importedMaster)
        XCTAssertEqual(rows[1].setupName, "PDF A4 - Model")
        XCTAssertEqual(rows[1].masterPath, "/master/Master.dwg")
        // Named-local provenance keeps the setup name.
        XCTAssertEqual(rows[2].assignMode, .namedLocal)
        XCTAssertEqual(rows[2].setupName, "PDF A3 - Layout")
        XCTAssertEqual(rows[2].masterPath, "")
    }

    func testEmptyDocumentThrows() {
        XCTAssertThrowsError(try PublishDSD.parse("")) { error in
            XCTAssertEqual(error as? PublishDSDError, .emptyDocument)
        }
        XCTAssertThrowsError(
            try PublishDSD.parse("; just a comment\n[Unknown]\nA=B\n")) { error in
            XCTAssertEqual(error as? PublishDSDError, .emptyDocument)
        }
    }

    func testSheetMissingTabThrows() {
        let text = "[Job]\nPublishTo=PDF\n[Sheet1]\nSource=/jobs/1.dwg\n"
        XCTAssertThrowsError(try PublishDSD.parse(text)) { error in
            guard let dsdError = error as? PublishDSDError,
                  case .malformedSheet(let section, _) = dsdError
            else {
                return XCTFail("expected malformedSheet, got \(error)")
            }
            XCTAssertEqual(section, "Sheet1")
        }
    }

    func testUnknownValuesFallBackToDefaults() throws {
        let text = """
            [Job]
            PublishTo=StoneTablet
            FileType=Scroll
            Naming=Whenever
            MergeControl=Fold
            Copies=abc
            [Sheet1]
            Source=/jobs/1.dwg
            Tab=Model
            Space=Deck
            AssignMode=Whatever
            """
        let parsed = try PublishDSD.parse(text)
        XCTAssertEqual(parsed.publishTo, .plotterNamedInPageSetup)
        XCTAssertEqual(parsed.fileType, .multiSheetFile)
        XCTAssertEqual(parsed.namingPolicy, .promptForName)
        XCTAssertEqual(parsed.mergeControl, .overwriteLines)
        XCTAssertEqual(parsed.numberOfCopies, 1)
        XCTAssertEqual(parsed.sheets.count, 1)
        XCTAssertEqual(parsed.sheets[0].space, .layout)
        XCTAssertEqual(parsed.sheets[0].assignMode, .default)
    }

    func testSheetSectionsOrderNumerically() throws {
        var lines = ["[Job]"]
        for n in [1, 2, 9, 10, 11] {
            lines += ["[Sheet\(n)]", "Source=/jobs/\(n).dwg", "Tab=Model", "Name=S\(n)"]
        }
        let parsed = try PublishDSD.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(
            parsed.sheets.map(\.sheetName),
            ["S1", "S2", "S9", "S10", "S11"])
    }

    func testValuesWithEqualsAndNewlines() throws {
        var spec = jobSpec()
        spec.sheets[0].sheetName = "A=B\nC"
        let parsed = try PublishDSD.parse(PublishDSD.serialize(spec: spec))
        // Newlines are cleaned (single-line INI values); `=` survives
        // because parsing splits on the first `=` only.
        XCTAssertEqual(parsed.sheets[0].sheetName, "A=B C")
    }

    func testFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-\(UUID().uuidString).dsd")
        defer { try? FileManager.default.removeItem(at: url) }
        try PublishDSD.serialize(spec: jobSpec()).write(
            to: url, atomically: true, encoding: .utf8)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try PublishDSD.parse(text), PublishDSDJob(spec: jobSpec()))
    }
}
