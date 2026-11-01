import XCTest
@testable import ZephyrCore

/// Verification drill (plan step 34): real repo DXF with layouts.
/// The legacy pirate export carries no LAYOUT objects, so generation 1
/// gains the writer-guaranteed synthetic `Layout1`; from generation 2 on
/// the file must be stable (names + every plot code identical).
final class PlotDrillTests: XCTestCase {
    private func viewDocs(from result: DXFImportResult) -> [DrawingView] {
        result.views.map { view in
            let doc = CADDocument()
            doc.importLayersBlocksEntities(
                layers: result.layers, blocks: result.blocks, entities: view.entities)
            doc.textStyles = result.textStyles
            doc.linetypePatterns = result.linetypePatterns
            doc.dimensionStyles = result.dimensionStyles
            doc.plotSettings = view.plotSettings
            doc.layoutSettings = view.layoutSettings
            return DrawingView(name: view.name, kind: view.kind, document: doc)
        }
    }

    private func layoutObjectCount(in text: String) -> Int {
        text.components(separatedBy: "  0\r\nLAYOUT\r\n").count - 1
    }

    @MainActor
    func testPirateShipLayoutsStabilize() throws {
        let url = URL(fileURLWithPath: "186-841 - KOMPAN, Inc. - Pirate Ship-export.dxf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Pirate Ship DXF not present")
        }
        // Generation 1: legacy file without LAYOUT objects.
        let first = try DXFImporter.importDXFViews(filePath: url.path)
        XCTAssertEqual(first.views.map(\.name), ["Model"])

        let gen1URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drill-gen1-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: gen1URL) }
        try DXFExporter.export(
            views: viewDocs(from: first), to: gen1URL,
            namedSetups: first.namedPageSetups)
        let gen1Text = try String(contentsOf: gen1URL, encoding: .utf8)
        XCTAssertEqual(layoutObjectCount(in: gen1Text), 2, "Model + writer-guaranteed Layout1")

        // Generation 2: must be stable now.
        let second = try DXFImporter.importDXFViews(filePath: gen1URL.path)
        XCTAssertEqual(second.views.map(\.name), ["Model", "Layout1"])

        let gen2URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drill-gen2-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: gen2URL) }
        try DXFExporter.export(
            views: viewDocs(from: second), to: gen2URL,
            namedSetups: second.namedPageSetups)
        let third = try DXFImporter.importDXFViews(filePath: gen2URL.path)
        XCTAssertEqual(third.views.map(\.name), ["Model", "Layout1"])
        for (a, b) in zip(second.views, third.views) {
            XCTAssertEqual(a.plotSettings?.paperWidthMM ?? -1, b.plotSettings?.paperWidthMM ?? -1, accuracy: 1e-9)
            XCTAssertEqual(a.plotSettings?.paperHeightMM ?? -1, b.plotSettings?.paperHeightMM ?? -1, accuracy: 1e-9)
            XCTAssertEqual(a.plotSettings?.plotRotation ?? -1, b.plotSettings?.plotRotation ?? -1)
            XCTAssertEqual(a.plotSettings?.plotFlags ?? -1, b.plotSettings?.plotFlags ?? -1)
            XCTAssertEqual(a.plotSettings?.plotType ?? -1, b.plotSettings?.plotType ?? -1)
            XCTAssertEqual(a.plotSettings?.standardScaleType ?? -1, b.plotSettings?.standardScaleType ?? -1)
            XCTAssertEqual(a.plotSettings?.pageSetupName ?? "", b.plotSettings?.pageSetupName ?? "")
            XCTAssertEqual(a.plotSettings?.plotConfigName ?? "", b.plotSettings?.plotConfigName ?? "")
            XCTAssertEqual(a.plotSettings?.canonicalMediaName ?? "", b.plotSettings?.canonicalMediaName ?? "")
            XCTAssertEqual(a.plotSettings?.styleSheet ?? "", b.plotSettings?.styleSheet ?? "")
        }
        XCTAssertEqual(third.namedPageSetups.count, second.namedPageSetups.count)
    }
}
