import XCTest
import Foundation
@testable import ZephyrCore

/// Tests for PDF export of paper-space layouts, color contrast adjustment,
/// point-entity sizing, and active-view routing.
@MainActor
final class PDFExportPaperLayoutTests: XCTestCase {

    // MARK: - Layout paper dimensions

    func testLayoutSettingsPreservesPaperDimensions() throws {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .black)
        doc.addLayer(layer)
        doc.layoutSettings = CADLayoutSettings(
            paperName: "Letter",
            paperWidthMM: 215.9,
            paperHeightMM: 279.4,
            plotPaperUnits: 0,
            plotRotation: 0
        )
        // Add a line across the sheet
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(start: .zero, end: Vector3(x: 8.5, y: 11.0, z: 0), color: .black)]
        )
        doc.addEntity(entity)

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(decoding: pdfData, as: UTF8.self)

        // MediaBox should be exact US Letter: 612 x 792 points
        XCTAssertTrue(pdfString.contains("/MediaBox [0 0 612 792]"),
                     "PDF must use the layout's defined paper size: 612x792 pt for Letter")
    }

    func testLayoutSettingsSupportsRotation() throws {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .black)
        doc.addLayer(layer)
        doc.layoutSettings = CADLayoutSettings(
            paperName: "Letter Landscape",
            paperWidthMM: 215.9,
            paperHeightMM: 279.4,
            plotPaperUnits: 0,
            plotRotation: 1 // 90 degrees CCW
        )
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(start: .zero, end: Vector3(x: 11.0, y: 8.5, z: 0), color: .black)]
        )
        doc.addEntity(entity)

        let pdfData = try PDFExporter.generatePDF(document: doc, backgroundColor: .white)
        let pdfString = String(decoding: pdfData, as: UTF8.self)

        // Rotated 90 deg: width and height swapped -> 792 x 612 points
        XCTAssertTrue(pdfString.contains("/MediaBox [0 0 792 612]"),
                     "PDF must swap width and height for 90-degree rotated layouts")
    }

    // MARK: - Color contrast adjustment on light backgrounds

    func testWhiteEntitiesDisplayAdjustedOnLightBackground() throws {
        let doc = CADDocument()
        let layer = Layer(name: "0", color: .white)
        doc.addLayer(layer)
        // Add pure white line entity (ACI color 7 / RGB 255,255,255)
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(start: .zero, end: Vector3(x: 10, y: 10, z: 0), color: .white)]
        )
        doc.addEntity(entity)

        // Collect items for light background
        let items = PDFExporter.collectItems(document: doc, isLightBackground: true)
        XCTAssertFalse(items.isEmpty)

        var foundAdjustedDarkColor = false
        for item in items {
            let color: ColorRGBA
            switch item {
            case .geometry(_, let c, _): color = c
            case .textStrokes(_, let c, _): color = c
            case .embeddedText(let e, _): color = e.color
            case .hiddenText: continue
            case .textFallback(_, _, _, _, let c, _): color = c
            }
            // displayAdjusted converts pure white (255,255,255) to (24,24,24)
            if color.r == 24 && color.g == 24 && color.b == 24 {
                foundAdjustedDarkColor = true
            }
        }
        XCTAssertTrue(foundAdjustedDarkColor,
                     "White entities must be display-adjusted to dark charcoal on light backgrounds so they are visible")
    }

    // MARK: - Point entity device-scale sizing

    func testPointEntityExportsAsCompactDot() {
        let cb = PDFContentBuilder()
        // Point primitive at (5.0, 5.0)
        let pointPrim = CADPrimitive.point(position: Vector3(x: 5.0, y: 5.0, z: 0), color: .black)

        // At pageScale = 72 (1 world unit = 72 pt = 1 inch), effectiveScale = 72
        PDFPrimitives.writePrimitive(pointPrim, effectiveScale: 72.0, to: cb)
        let output = String(decoding: cb.build(), as: UTF8.self)

        // Radius should be 1.5 / 72 = ~0.0208 world units, diameter = 0.0417 units = 3 device points
        XCTAssertTrue(output.contains("re f"), "Point should be emitted as a small filled rectangle")
        XCTAssertFalse(output.contains("4 4 re"), "Point must NOT be emitted as a giant 4x4 world unit block")
    }

    // MARK: - Active view routing in TabManager

    func testTabManagerExportsActiveLayoutView() async throws {
        let m = TabManager()
        let modelDoc = CADDocument()
        let modelLayer = Layer(name: "0", color: .black)
        modelDoc.addLayer(modelLayer)
        modelDoc.addEntity(CADEntity(
            layerID: modelLayer.handle,
            localGeometry: [.line(start: .zero, end: Vector3(x: 100, y: 100, z: 0), color: .black)]
        ))

        let layoutDoc = CADDocument()
        let layoutLayer = Layer(name: "0", color: .black)
        layoutDoc.addLayer(layoutLayer)
        layoutDoc.layoutSettings = CADLayoutSettings(
            paperName: "Letter",
            paperWidthMM: 215.9,
            paperHeightMM: 279.4,
            plotPaperUnits: 0,
            plotRotation: 0
        )
        layoutDoc.addEntity(CADEntity(
            layerID: layoutLayer.handle,
            localGeometry: [.line(start: .zero, end: Vector3(x: 8.5, y: 11.0, z: 0), color: .black)]
        ))

        let views = [
            DrawingView(name: "Model", kind: .model, document: modelDoc),
            DrawingView(name: "PDF Layout", kind: .sheet, document: layoutDoc, backgroundColor: .white)
        ]

        let tab = DocumentTab(
            document: modelDoc,
            fileURL: nil,
            displayName: "TestDrawing",
            drawingViews: views
        )
        m.addTab(tab)

        // Switch to the PDF layout view
        XCTAssertTrue(m.switchToView(at: 1))
        XCTAssertEqual(m.activeTab?.activeViewIndex, 1)

        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestLayoutExport-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: targetURL) }

        m.startSaveActiveTabAs(url: targetURL)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            _ = m.applyPendingSaveUpdates()
            if FileManager.default.fileExists(atPath: targetURL.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), "Exported PDF must exist")
        let pdfData = try Data(contentsOf: targetURL)
        let pdfStr = String(decoding: pdfData, as: UTF8.self)

        // The exported PDF must be the active layout (612x792), not the model view
        XCTAssertTrue(pdfStr.contains("/MediaBox [0 0 612 792]"),
                     "Exporting when layout tab is active must export the layout's defined paper size")
    }
}
