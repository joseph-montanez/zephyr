import XCTest
import Foundation
@testable import ZephyrCore

/// Step 6: set → DSD job bridge and the shared resolveSpec seam.
@MainActor
final class SheetSetPublishBridgeTests: XCTestCase {

    private func sampleSet() -> SheetSet {
        var set = SheetSet(name: "TI Set", dstPath: "C:/job/ti.dst")
        set.sheets = [
            SheetSetSheet(number: "A100", title: "Cover", absoluteFile: "C:/job/a.dwg", handle: "1A", layoutName: "Layout1"),
            SheetSetSheet(number: "A101", title: "Hidden", absoluteFile: "C:/job/a.dwg", handle: "1B", layoutName: "Layout2", includeForPlot: false),
        ]
        set.subsets = [
            SheetSetSubset(name: "Arch", sheets: [
                SheetSetSheet(number: "A201", title: "Plan", absoluteFile: "C:/job/b.dwg", handle: "2A", layoutName: "Plan"),
            ]),
            SheetSetSubset(name: "Old", publishSheets: false, sheets: [
                SheetSetSheet(number: "X1", title: "Stale", absoluteFile: "C:/job/c.dwg", handle: "3A", layoutName: "L1"),
            ]),
        ]
        return set
    }

    func testBridgeRowsHonorPlotFlagsAndOrder() {
        let job = SheetSetPublishBridge.dsdJob(for: sampleSet())
        XCTAssertEqual(job.sheets.map(\.sheetName), ["A100 Cover", "A201 Plan"])
        XCTAssertEqual(job.sheets.map(\.tabName), ["Layout1", "Plan"])
        XCTAssertEqual(job.sheets.map(\.sourcePath), ["C:/job/a.dwg", "C:/job/b.dwg"])
        XCTAssertTrue(job.sheets.allSatisfy { $0.space == .layout })
        XCTAssertTrue(job.sheets.allSatisfy { $0.assignMode == .default })
        XCTAssertEqual(job.publishTo, .pdf)
        XCTAssertEqual(job.outputDirectory, "C:/job")
        XCTAssertEqual(job.targetFileName, "TI Set.pdf")
    }

    func testBridgeOverrideAssignsByName() {
        let job = SheetSetPublishBridge.dsdJob(for: sampleSet(), setupOverride: "PDF A4")
        XCTAssertTrue(job.sheets.allSatisfy { $0.assignMode == .namedLocal && $0.setupName == "PDF A4" })
    }

    func testResolveSpecAgainstStubMetadata() {
        let set = sampleSet()
        let job = SheetSetPublishBridge.dsdJob(for: set)
        let metas: [String: PublishDrawingMetadata] = [
            "c:/job/a.dwg": PublishDrawingMetadata(
                sourcePath: "C:/job/a.dwg", displayName: "a",
                tabs: [PublishDrawingTabMetadata(name: "Layout1", space: .layout, defaultSetupName: "")]),
            "c:/job/b.dwg": PublishDrawingMetadata(
                sourcePath: "C:/job/b.dwg", displayName: "b",
                tabs: [PublishDrawingTabMetadata(name: "Plan", space: .layout, defaultSetupName: "")]),
        ]
        let resolved = PublishCLIRun.resolveSpec(job: job) { metas[$0.lowercased()] }
        XCTAssertEqual(resolved.spec.sheets.count, 2)
        XCTAssertEqual(resolved.unresolved, 0)
        // No native setups anywhere: PDF preset covers with a warning each.
        XCTAssertTrue(resolved.spec.sheets.allSatisfy { $0.status == .warning })
    }

    func testMissingDrawingListsHonestStubRow() {
        let job = SheetSetPublishBridge.dsdJob(for: sampleSet())
        let resolved = PublishCLIRun.resolveSpec(job: job) { _ in nil }
        XCTAssertEqual(resolved.spec.sheets.count, 2)
    }

    func testOverrideOnMissingSetupCountsUnresolved() {
        let job = SheetSetPublishBridge.dsdJob(for: sampleSet(), setupOverride: "Nope")
        let resolved = PublishCLIRun.resolveSpec(job: job) { _ in nil }
        XCTAssertEqual(resolved.unresolved, 2)
    }

    private func paperSetup(named name: String) -> CADPlotSettings {
        var ps = CADPlotSettings(
            paperWidthMM: 297, paperHeightMM: 210,
            marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
            plotPaperUnits: 1, plotRotation: 1,
            pageSetupName: name,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A4_(297.00_x_210.00_MM)",
            plotType: 1, standardScaleType: 0)
        ps.pageSetupName = name
        return ps
    }

    func testBridgeOverrideFileAssignsImportedMaster() {
        let job = SheetSetPublishBridge.dsdJob(
            for: sampleSet(), setupOverride: "ANSI A", overrideFile: "C:/std/border.dwt")
        XCTAssertTrue(job.sheets.allSatisfy { $0.assignMode == .importedMaster })
        XCTAssertTrue(job.sheets.allSatisfy { $0.setupName == "ANSI A" })
        XCTAssertTrue(job.sheets.allSatisfy { $0.masterPath == "C:/std/border.dwt" })
    }

    func testResolveSpecAgainstOverrideFile() {
        let set = sampleSet()
        let job = SheetSetPublishBridge.dsdJob(
            for: set, setupOverride: "ANSI A", overrideFile: "C:/std/border.dwt")
        let metas: [String: PublishDrawingMetadata] = [
            "c:/job/a.dwg": PublishDrawingMetadata(
                sourcePath: "C:/job/a.dwg", displayName: "a",
                tabs: [PublishDrawingTabMetadata(name: "Layout1", space: .layout)]),
            "c:/job/b.dwg": PublishDrawingMetadata(
                sourcePath: "C:/job/b.dwg", displayName: "b",
                tabs: [PublishDrawingTabMetadata(name: "Plan", space: .layout)]),
            "c:/std/border.dwt": PublishDrawingMetadata(
                sourcePath: "C:/std/border.dwt", displayName: "border",
                namedSetups: [CADNamedPageSetup(
                    name: "ANSI A", settings: paperSetup(named: "ANSI A"), isModelType: false)]),
        ]
        let resolved = PublishCLIRun.resolveSpec(job: job) { metas[$0.lowercased()] }
        XCTAssertEqual(resolved.unresolved, 0)
        XCTAssertEqual(resolved.spec.sheets.count, 2)
        for row in resolved.spec.sheets {
            XCTAssertEqual(row.assignment.mode, .importedMaster)
            XCTAssertEqual(row.assignment.masterDwgPath, "C:/std/border.dwt")
            XCTAssertEqual(row.resolvedSetup?.pageSetupName, "ANSI A")
        }
    }

    func testOverrideFileMissingSetupCountsUnresolved() {
        let set = sampleSet()
        let job = SheetSetPublishBridge.dsdJob(
            for: set, setupOverride: "ANSI A", overrideFile: "C:/std/border.dwt")
        let metas: [String: PublishDrawingMetadata] = [
            "c:/job/a.dwg": PublishDrawingMetadata(
                sourcePath: "C:/job/a.dwg", displayName: "a",
                tabs: [PublishDrawingTabMetadata(name: "Layout1", space: .layout)]),
            "c:/std/border.dwt": PublishDrawingMetadata(
                sourcePath: "C:/std/border.dwt", displayName: "border",
                namedSetups: [CADNamedPageSetup(
                    name: "Other", settings: paperSetup(named: "Other"), isModelType: false)]),
        ]
        let resolved = PublishCLIRun.resolveSpec(job: job) { metas[$0.lowercased()] }
        XCTAssertEqual(resolved.unresolved, 2)
    }
}
