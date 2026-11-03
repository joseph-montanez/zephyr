import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 7 hardening: Windows filename edge cases (reserved device stems)
/// and large-job behavior (40-sheet multi/single runs, single-write and
/// per-sheet-write guarantees at scale).
@MainActor
final class PublishHardeningTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshotDoc() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            handle: UUID(), name: "0", isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        let layerID = doc.allLayers.first!.handle
        doc.addEntity(CADEntity(
            layerID: layerID,
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 100, y: 50, z: 0))],
            transform: .identity))
        return doc
    }

    private func setup(named name: String) -> CADPlotSettings {
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

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pubharden-\(UUID().uuidString)", isDirectory: true)
    }

    private func pdfText(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Windows reserved device names

    func testReservedDeviceNamesAreDeflected() {
        for reserved in ["CON", "con", "PRN", "AUX", "NUL", "COM1", "com9", "LPT1", "lpt9"] {
            let out = PublishRunner.sanitizedFileName(reserved)
            XCTAssertEqual(out, "_\(reserved.trimmingCharacters(in: .whitespaces))",
                           "\(reserved) must be deflected")
            XCTAssertFalse(
                PublishRunner.windowsReservedStems.contains(
                    out.split(separator: ".").first.map(String.init)?.uppercased() ?? out),
                "\(out) must not itself be reserved")
        }
        // Reserved stem with an extension is still reserved on Windows.
        XCTAssertEqual(PublishRunner.sanitizedFileName("CON.txt"), "_CON.txt")
        XCTAssertEqual(
            PublishRunner.ensuringPDFExtension(PublishRunner.sanitizedFileName("CON")),
            "_CON.pdf")
        // Near-misses are untouched.
        XCTAssertEqual(PublishRunner.sanitizedFileName("CONSOLE"), "CONSOLE")
        XCTAssertEqual(PublishRunner.sanitizedFileName("COM10"), "COM10")
        XCTAssertEqual(PublishRunner.sanitizedFileName("LPT0"), "LPT0")
        XCTAssertEqual(PublishRunner.sanitizedFileName("myCON"), "myCON")
    }

    func testSanitizerTrimsDotsSpacesAndCapsLength() {
        XCTAssertEqual(PublishRunner.sanitizedFileName("name. "), "name")
        XCTAssertEqual(PublishRunner.sanitizedFileName("   "), "Sheet")
        XCTAssertEqual(PublishRunner.sanitizedFileName(""), "Sheet")
        let long = String(repeating: "a", count: 200)
        XCTAssertLessThanOrEqual(PublishRunner.sanitizedFileName(long).count, 120)
    }

    func testReservedSheetNameWritesToDisk() async throws {
        let id = UUID()
        let snaps = ["Model": snapshotDoc().snapshot()]
        let entry = PublishSheetEntry(
            sheetName: "CON", drawingID: id, sourceDwgPath: "",
            tabName: "Model", space: .model,
            defaultSetupName: "S", defaultSetup: setup(named: "S"))
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: [entry])
        let report = try await PublishRunner.run(
            spec: spec, openDrawings: [id: snaps])
        XCTAssertEqual(report.outputURLs.map(\.lastPathComponent), ["_CON.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.outputURLs[0].path))
    }

    // MARK: - Large-job behavior

    private func largeEntries(count: Int, space: PublishSpace) -> (
        [PublishSheetEntry], [UUID: [String: CADDocumentSnapshot]]
    ) {
        var entries: [PublishSheetEntry] = []
        var open: [UUID: [String: CADDocumentSnapshot]] = [:]
        for i in 0..<count {
            let id = UUID()
            let tab = space == .model ? "Model" : "Layout1"
            open[id] = [tab: snapshotDoc().snapshot()]
            entries.append(PublishSheetEntry(
                sheetName: "Sheet\(i)-\(tab)", drawingID: id, sourceDwgPath: "",
                tabName: tab, space: space,
                defaultSetupName: "S", defaultSetup: setup(named: "S")))
        }
        return (entries, open)
    }

    func testLargeMultiSheetJobWritesOneFile() async throws {
        let (entries, open) = largeEntries(count: 40, space: .model)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            sheets: entries)
        let report = try await PublishRunner.run(spec: spec, openDrawings: open)
        // One file, every sheet ready: the whole job renders in memory and
        // lands with a single write (no partial output on this path).
        XCTAssertEqual(report.outputURLs.count, 1)
        XCTAssertTrue(report.sheets.allSatisfy { $0.status == .ready })
        XCTAssertEqual(report.sheets.count, 40)
        let text = pdfText(try Data(contentsOf: report.outputURLs[0]))
        XCTAssertTrue(text.contains("/Count 40"), "all 40 pages land in one file")
    }

    func testLargeSingleSheetJobWritesOneFilePerSheet() async throws {
        let (entries, open) = largeEntries(count: 40, space: .model)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = PublishJobSpec(
            publishTo: .pdf,
            outputDirectory: dir.path,
            fileType: .singleSheetFiles,
            namingPolicy: .autoName,
            sheets: entries)
        let report = try await PublishRunner.run(spec: spec, openDrawings: open)
        XCTAssertEqual(report.outputURLs.count, 40)
        XCTAssertEqual(Set(report.outputURLs.map(\.lastPathComponent)).count, 40)
        XCTAssertTrue(report.sheets.allSatisfy { $0.status == .ready })
    }
}
