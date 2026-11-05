import XCTest
import Foundation
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

    func testPlotFrameCenteredExtentsPlacesEngineDownContentOnPage() throws {
        // Engine content is Y-down (import negates DXF Y) while the
        // printable rect is Y-up: Extents must compose the Y offset against
        // the area bottom, or ty overshoots by a full area height (Assembly
        // sheet exported entirely above the page).
        var ps = a3Settings(plotType: 1) // Extents
        ps.plotFlags |= 4 // Center the plot
        ps.useStandardScale = true
        // 100x100 area, engine-down (top y=-100, bottom y=0), into the same
        // 400x277 printable as testPlotFrameCenteredOffset.
        let frame = try XCTUnwrap(PDFExporter.plotFrame(
            settings: ps, worldBounds: (0, -100, 100, 0)))
        let s = 72.0 / 25.4
        XCTAssertEqual(frame.tx, 150 * s, accuracy: 1e-6)
        // Old composition gave 188.5 * s here (full area height too high).
        XCTAssertEqual(frame.ty, 88.5 * s, accuracy: 1e-4)
        // Sheet corners must land inside the A3 page (1191 x 842 pt).
        let topDevY = -s * -100 + frame.ty
        let bottomDevY = -s * 0 + frame.ty
        XCTAssertGreaterThan(topDevY, 0)
        XCTAssertLessThan(topDevY, 842)
        XCTAssertGreaterThan(bottomDevY, 0)
        XCTAssertLessThan(bottomDevY, 842)
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

    func testPlotFrameCustomScaleKeepsPhysicalPageSize() throws {
        var ps = a3Settings()
        ps.paperWidthMM = 296.926
        ps.paperHeightMM = 420.116
        ps.plotRotation = 1 // Landscape
        ps.customScaleNumerator = 1.0
        ps.customScaleDenominator = 5.0 // 1:5 custom scale
        ps.useStandardScale = false
        let frame = try XCTUnwrap(PDFExporter.plotFrame(settings: ps, worldBounds: (-17.52, -1390, 1890, 0)))
        // Must stay physical A3 Landscape (420.12 x 296.93 mm in points), NOT 5x larger
        XCTAssertEqual(frame.pageW, 420.116 * 72.0 / 25.4, accuracy: 1.0)
        XCTAssertEqual(frame.pageH, 296.926 * 72.0 / 25.4, accuracy: 1.0)
    }

    func testMechanicalSampleAssemblyTitleExtractsOnPage() throws {
        // The Assembly layout plots Extents + centered over engine-down
        // content: the title block used to land a full sheet height above
        // the page (only its bottom strip survived at the top edge).
        let dxfPath = "C:/dev/dxf/Mechanical Sample.dxf"
        guard FileManager.default.fileExists(atPath: dxfPath) else { return }
        let imported = try DXFImporter.importDXFViews(filePath: dxfPath)
        let sheet = try XCTUnwrap(imported.views.first(where: { $0.name == "Assembly" }))
        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: imported.layers, blocks: imported.blocks, entities: sheet.entities)
        for (name, style) in imported.textStyles {
            doc.textStyles[name] = style
        }
        doc.plotSettings = sheet.plotSettings
        doc.layoutSettings = sheet.layoutSettings
        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(
            pdfString.contains("/MediaBox [0 0 2592 1728]"),
            "Assembly must keep the ARCH D 36x24in page")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try pdfData.write(to: tmpURL)
        guard let page = PDFiumBridge.extractVectorPage(path: tmpURL.path, pageIndex: 0) else {
            throw XCTSkip("pdfium unavailable in this environment")
        }
        var title: (text: String, y: Double)? = nil
        for prim in page.textEntities.flatMap({ $0 }) {
            if case .text(let pos, let text, _, _, _, _, _, _, _) = prim,
               text.contains("MANUFACTURED") {
                title = (text, pos.y)
                break
            }
        }
        let run = try XCTUnwrap(title, "Assembly title block text must extract")
        XCTAssertGreaterThan(run.y, 0, "title must sit above the page bottom")
        XCTAssertLessThan(run.y, 1728, "title must sit below the page top")
    }

    func testStandaloneTextRespectsTransformScaleInPDFExport() throws {
        let doc = makeSheetDoc()
        let layerID = doc.allLayers.first!.handle
        var xdata: [String: XDataValue] = [:]
        xdata["dxf.text"] = .string("TEST LABEL")
        xdata["dxf.textHeight"] = .double(17.5)
        let scale = 0.0056618
        let transform = Transform3D.scaled(by: Vector3(x: scale, y: scale, z: 1.0))
        let textEntity = CADEntity(
            layerID: layerID,
            localGeometry: [],
            transform: transform,
            xdata: xdata
        )
        doc.addEntity(textEntity)
        let items = PDFExporter.collectItems(document: doc)
        // Default options include hidden searchable text over SHX strokes
        // (EPDFSHX = 1 equivalent): strokes + one hidden-text item.
        XCTAssertEqual(items.count, 2)
        switch items[0] {
        case .textStrokes(let prims, _, _):
            guard let bounds = PDFExporter.primsBounds(prims) else {
                XCTFail("Missing text strokes bounds")
                return
            }
            let height = bounds.maxY - bounds.minY
            // Text height should be ~17.5 * 0.0056618 = 0.099, NOT raw 17.5
            XCTAssertLessThan(height, 0.5, "Text height must be scaled by transform")
        case .textFallback(_, _, _, let h, _, _):
            XCTAssertLessThan(h, 0.5, "Fallback text height must be scaled by transform")
        default:
            XCTFail("Expected text strokes or fallback")
        }
        // Second item carries the same text invisibly for search/select.
        switch items[1] {
        case .hiddenText(let text, _, _, let h):
            XCTAssertEqual(text, "TEST LABEL")
            XCTAssertLessThan(h, 0.5, "Hidden text height must be scaled by transform")
        default:
            XCTFail("Expected hidden searchable text over SHX strokes")
        }
    }

    func testA000217DXFExportProducesA3LandscapePDF() throws {
        let dxfPath = "C:/dev/dxf/A_000217.dxf"
        guard FileManager.default.fileExists(atPath: dxfPath) else { return }
        let imported = try DXFImporter.importDXFViews(filePath: dxfPath)
        XCTAssertGreaterThanOrEqual(imported.views.count, 2)
        // Model view should have plotSettings from Model LAYOUT
        let modelView = try XCTUnwrap(imported.views.first(where: { $0.kind == .model }))
        XCTAssertNotNil(modelView.plotSettings)
        XCTAssertEqual(modelView.plotSettings?.canonicalMediaName, "A3")

        // Layout1 should inherit fallback A3 landscape page setup
        let layoutView = try XCTUnwrap(imported.views.first(where: { $0.kind == .sheet }))
        XCTAssertNotNil(layoutView.plotSettings)
        XCTAssertEqual(layoutView.plotSettings?.canonicalMediaName, "A3")
        XCTAssertEqual(layoutView.plotSettings?.plotRotation, 1)

        // Build document and export to PDF
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: imported.layers, blocks: imported.blocks, entities: layoutView.entities)
        doc.plotSettings = layoutView.plotSettings
        doc.layoutSettings = layoutView.layoutSettings
        doc.unit = (layoutView.layoutSettings?.plotPaperUnits == 0) ? .inch : .millimeter

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(data: pdfData, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(pdfString.contains("/MediaBox [0 0 1191 842]"), "Must be A3 Landscape 1191x842 pt")
    }

    func testPirateShipDXFLayoutsImportAndScaleCorrectly() throws {
        let dxfPath = "C:/dev/dxf/186-841 - KOMPAN, Inc. - Pirate Ship.dxf"
        guard FileManager.default.fileExists(atPath: dxfPath) else { return }
        let imported = try DXFImporter.importDXFViews(filePath: dxfPath)

        // CADdetails layout has configured paper (2450x3150 Pixels at 1:0.45 scale)
        let cadDetails = try XCTUnwrap(imported.views.first(where: { $0.name == "CADdetails" }))
        XCTAssertEqual(cadDetails.kind, .sheet)
        let cadPs = try XCTUnwrap(cadDetails.plotSettings)
        XCTAssertEqual(cadPs.paperWidthMM, 2450.0)
        XCTAssertEqual(cadPs.paperHeightMM, 3150.0)
        XCTAssertEqual(cadPs.customScaleDenominator, 0.45)
        let cadRects = try XCTUnwrap(PaperSheetGeometry.overlayRects(for: cadPs))
        XCTAssertEqual(cadRects.paper.maxX - cadRects.paper.minX, 1102.5, accuracy: 1e-4)
        XCTAssertEqual(cadRects.paper.maxY - cadRects.paper.minY, 1417.5, accuracy: 1e-4)
        XCTAssertGreaterThan(cadDetails.entities.count, 1000, "CADdetails should have projected CAD geometry")

        // Layout2 layout was unconfigured, should inherit normalized Letter 1:1 setup
        let layout2 = try XCTUnwrap(imported.views.first(where: { $0.name == "Layout2" }))
        XCTAssertEqual(layout2.kind, .sheet)
        let l2Ps = try XCTUnwrap(layout2.plotSettings)
        XCTAssertEqual(l2Ps.plotType, 5, "Unconfigured layout should normalize to Layout plotType")
        XCTAssertEqual(l2Ps.customScaleDenominator, 1.0, "Unconfigured layout must not inherit model 27.58x scale")
        XCTAssertEqual(l2Ps.plotOriginXMM, 0.0)
        XCTAssertEqual(l2Ps.plotOriginYMM, 0.0)
        let l2Rects = try XCTUnwrap(PaperSheetGeometry.overlayRects(for: l2Ps))
        XCTAssertEqual(l2Rects.paper.maxX - l2Rects.paper.minX, 215.9 / 25.4, accuracy: 1e-3)
        XCTAssertEqual(l2Rects.paper.maxY - l2Rects.paper.minY, 279.4 / 25.4, accuracy: 1e-3)

        // Verify CADdetails PDF export places geometry onto the 2450x3150 page
        let doc = CADDocument()
        doc.importLayersBlocksEntities(layers: imported.layers, blocks: imported.blocks, entities: cadDetails.entities)
        doc.plotSettings = cadPs
        doc.layoutSettings = cadDetails.layoutSettings

        let frame = try XCTUnwrap(PDFExporter.plotFrame(settings: cadPs, worldBounds: nil))
        XCTAssertEqual(frame.pageW, 2450.0, accuracy: 1e-3)
        XCTAssertEqual(frame.pageH, 3150.0, accuracy: 1e-3)
        XCTAssertEqual(frame.scale, 1.0 / 0.45, accuracy: 1e-4)
        XCTAssertEqual(frame.tx, 0.0, accuracy: 1e-3)
        XCTAssertEqual(frame.ty, -25.0, accuracy: 1e-3)

        // Verify transformed entities land inside [0, 2450] x [0, 3150]
        var devMinX = Double.infinity, devMinY = Double.infinity
        var devMaxX = -Double.infinity, devMaxY = -Double.infinity
        for entity in cadDetails.entities {
            guard let bb = entity.worldBoundingBox else { continue }
            // Under PDF CTM: device.x = scale * worldX + tx; device.y = -scale * worldY + ty
            let x0 = frame.scale * bb.min.x + frame.tx
            let x1 = frame.scale * bb.max.x + frame.tx
            let y0 = -frame.scale * bb.max.y + frame.ty
            let y1 = -frame.scale * bb.min.y + frame.ty
            devMinX = min(devMinX, min(x0, x1))
            devMaxX = max(devMaxX, max(x0, x1))
            devMinY = min(devMinY, min(y0, y1))
            devMaxY = max(devMaxY, max(y0, y1))
        }
        XCTAssertGreaterThan(devMinX, 0.0, "Drawing content should be inside page left edge")
        XCTAssertLessThan(devMaxX, frame.pageW, "Drawing content should be inside page right edge")
        XCTAssertGreaterThan(devMinY, 0.0, "Drawing content should be inside page bottom edge")
        XCTAssertLessThan(devMaxY, frame.pageH, "Drawing content should be inside page top edge")

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        XCTAssertGreaterThan(pdfData.count, 1000)
    }
}
