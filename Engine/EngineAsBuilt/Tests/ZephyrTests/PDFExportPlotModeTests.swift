import XCTest
@testable import ZephyrCore

/// Phase 3 step 20/24: PDF plot-mode geometry — exact paper size,
/// 1:1 scale, offsets, and printable clipping.
final class PDFExportPlotModeTests: XCTestCase {

    private func makeSheetDoc() -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(handle: UUID(), name: "0", isVisible: true,
                          lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return doc
    }

    private func a3Settings(plotType: Int = 5) -> CADPlotSettings {
        CADPlotSettings(
            paperName: "ISO_A3_(420.00_x_297.00_MM)",
            paperWidthMM: 420, paperHeightMM: 297,
            marginLM: 10, marginBM: 10, marginRM: 10, marginTM: 10,
            plotPaperUnits: 1, plotRotation: 0,
            plotConfigName: "DWG To PDF.pc3",
            canonicalMediaName: "ISO_A3_(420.00_x_297.00_MM)",
            plotType: plotType, standardScaleType: 16)
    }

    // MARK: - plotFrame math

    func testPlotFrameA3OneToOneLayout() throws {
        var ps = a3Settings()
        ps.useStandardScale = true // 1:1
        let frame = try XCTUnwrap(PDFExporter.plotFrame(
            settings: ps, worldBounds: (0, 0, 100, 100)))
        XCTAssertEqual(frame.pageW, 420 * 72.0 / 25.4, accuracy: 1e-6)
        XCTAssertEqual(frame.pageH, 297 * 72.0 / 25.4, accuracy: 1e-6)
        XCTAssertEqual(frame.scale, 72.0 / 25.4, accuracy: 1e-9)
        // Printable clip: 10mm margins → 400 x 277 in paper units.
        XCTAssertEqual(frame.clipMaxX - frame.clipMinX, 400, accuracy: 1e-9)
        XCTAssertEqual(frame.clipMaxY - frame.clipMinY, 277, accuracy: 1e-9)
    }

    func testPlotFrameLandscapeSwapsPage() throws {
        var ps = a3Settings()
        ps.plotRotation = 1
        ps.useStandardScale = true
        let frame = try XCTUnwrap(PDFExporter.plotFrame(settings: ps, worldBounds: nil))
        XCTAssertEqual(frame.pageW, 297 * 72.0 / 25.4, accuracy: 1e-6)
        XCTAssertEqual(frame.pageH, 420 * 72.0 / 25.4, accuracy: 1e-6)
    }

    func testPlotFrameWindowFitsIntoPrintable() throws {
        var ps = a3Settings(plotType: 4)
        ps.plotWindowMinX = 0; ps.plotWindowMinY = 0
        ps.plotWindowMaxX = 800; ps.plotWindowMaxY = 277
        ps.standardScaleType = 0 // fit
        let frame = try XCTUnwrap(PDFExporter.plotFrame(settings: ps, worldBounds: nil))
        // 800x277 window into 400x277 printable → 0.5 scale × unit factor.
        XCTAssertEqual(frame.scale, 0.5 * 72.0 / 25.4, accuracy: 1e-9)
        XCTAssertEqual(frame.pageW, 420 * 72.0 / 25.4, accuracy: 1e-6)
    }

    func testPlotFrameCenteredOffset() throws {
        var ps = a3Settings(plotType: 1) // Extents
        ps.plotFlags |= 4 // Center the plot
        ps.useStandardScale = true
        // 100x100 area into 400x277 printable at 1:1 → (150, 88.5) offset.
        let frame = try XCTUnwrap(PDFExporter.plotFrame(
            settings: ps, worldBounds: (0, 0, 100, 100)))
        XCTAssertEqual(frame.scale, 72.0 / 25.4, accuracy: 1e-9)
        let s = 72.0 / 25.4
        XCTAssertEqual(frame.tx, 150 * s, accuracy: 1e-6)
        XCTAssertEqual(frame.ty, 88.5 * s + 100 * s, accuracy: 1e-4)
    }

    func testPlotFrameNilWithoutPaper() {
        XCTAssertNil(PDFExporter.plotFrame(
            settings: CADPlotSettings(), worldBounds: (0, 0, 10, 10)))
    }

    // MARK: - End to end: exact MediaBox + clip operator

    func testGeneratePDFUsesExactPaperSize() throws {
        let doc = makeSheetDoc()
        var ps = a3Settings()
        ps.useStandardScale = true
        doc.plotSettings = ps
        doc.layoutSettings = ps.layoutSettings
        let data = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(text.contains("/MediaBox [0 0 1191 842]"), "A3 must map to exact points")
    }

    func testDrawViewportsFirstOrdering() {
        let doc = makeSheetDoc()
        let layerID = doc.allLayers.first!.handle
        let paper = CADEntity(layerID: layerID,
                              localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                                    end: Vector3(x: 1, y: 1, z: 0), color: .white)],
                              transform: .identity)
        var xdata = paper.xdata
        xdata["dxf.viewport.projected"] = .bool(true)
        let projected = CADEntity(layerID: layerID,
                                  localGeometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                                                        end: Vector3(x: 2, y: 2, z: 0), color: .white)],
                                  transform: .identity, xdata: xdata)
        doc.addEntity(paper)
        doc.addEntity(projected)
        let items = PDFExporter.collectItems(document: doc)
        XCTAssertEqual(items.count, 2)
        let ordered = PDFExporter.orderForDrawViewportsFirst(items, enabled: true)
        if case .geometry(let first, _, _) = ordered[0] {
            XCTAssertTrue(first.isViewportProjected)
        } else {
            XCTFail("projected item should plot first")
        }
        let legacy = PDFExporter.orderForDrawViewportsFirst(items, enabled: false)
        XCTAssertEqual(legacy.count, 2)
    }
}
