import XCTest
import Foundation
@testable import ZephyrCore

/// Regression tests for the PDFEXPORT save-dialog file name.
///
/// SDL's save dialog does not append the selected filter's extension, so an
/// extensionless default name used to fall through to the DXF branch in
/// `TabManager` — writing DXF bytes to what the user believed was a PDF
/// (e.g. `SS-5-Manhole Ring Assemblies.pdf` containing a `SECTION`/`HEADER`
/// DXF payload and zero `%PDF` markers).
@MainActor
final class PDFExportFileNameTests: XCTestCase {

    // MARK: - Default dialog name

    func testDefaultNameStripsDrawingExtension() {
        XCTAssertEqual(
            CADCommandProcessor.pdfExportDefaultName(for: "SS-5-Manhole Ring Assemblies.dxf"),
            "SS-5-Manhole Ring Assemblies.pdf")
    }

    func testDefaultNameStripsOtherDrawingExtensionsCaseInsensitively() {
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "part.DWG"), "part.pdf")
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "plan.EAB"), "plan.pdf")
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "my.v2.dxf"), "my.v2.pdf")
    }

    func testDefaultNameFallsBackToUntitled() {
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: nil), "untitled.pdf")
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "   "), "untitled.pdf")
    }

    func testDefaultNameDoesNotDoublePdfExtension() {
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "sheet.pdf"), "sheet.pdf")
        XCTAssertEqual(CADCommandProcessor.pdfExportDefaultName(for: "SHEET.PDF"), "SHEET.pdf")
    }

    func testDefaultNameAddsPdfWhenBare() {
        XCTAssertEqual(
            CADCommandProcessor.pdfExportDefaultName(for: "SS-5-Manhole Ring Assemblies"),
            "SS-5-Manhole Ring Assemblies.pdf")
    }

    // MARK: - Dialog result normalization

    func testTargetURLAppendsMissingExtension() {
        let url = CADCommandProcessor.pdfExportTargetURL(
            from: URL(fileURLWithPath: "SS-5-Manhole Ring Assemblies"))
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(url.lastPathComponent, "SS-5-Manhole Ring Assemblies.pdf")
    }

    func testTargetURLKeepsExistingPdfExtension() {
        let lower = URL(fileURLWithPath: "sheet.pdf")
        XCTAssertEqual(CADCommandProcessor.pdfExportTargetURL(from: lower), lower)
        let upper = URL(fileURLWithPath: "SHEET.PDF")
        XCTAssertEqual(CADCommandProcessor.pdfExportTargetURL(from: upper), upper)
    }

    func testTargetURLAppendsWhenExtensionIsNotPdf() {
        // A PDF-only dialog result must still route to PDFExporter, never DXF.
        let url = CADCommandProcessor.pdfExportTargetURL(
            from: URL(fileURLWithPath: "drawing.dxf"))
        XCTAssertEqual(url.pathExtension, "pdf")
    }

    // MARK: - Headless -EXPORTPDF target resolution

    func testDashExportPDFCommandIsRegistered() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains { $0.canonicalName == "-EXPORTPDF" },
            "-EXPORTPDF must be a registered command")
    }

    func testDashExportPDFExplicitAbsolutePathWins() {
        let target = CADCommandProcessor.dashExportPDFTarget(
            pathTail: "C:/dev/out/sheet",
            displayName: "Pirate Ship.dxf",
            drawingFolder: URL(fileURLWithPath: "C:/dev/dxf"))
        XCTAssertEqual(target?.lastPathComponent, "sheet.pdf")
        XCTAssertEqual(target?.deletingLastPathComponent().path,
                       URL(fileURLWithPath: "C:/dev/out").path)
    }

    func testDashExportPDFStripsQuotesAndKeepsPdfExtension() {
        let target = CADCommandProcessor.dashExportPDFTarget(
            pathTail: "\"C:/dev/out/my sheet.pdf\"",
            displayName: "Pirate Ship.dxf",
            drawingFolder: nil)
        XCTAssertEqual(target?.lastPathComponent, "my sheet.pdf")
    }

    func testDashExportPDFRelativePathAnchorsAtDrawingFolder() {
        let target = CADCommandProcessor.dashExportPDFTarget(
            pathTail: "out/sheet",
            displayName: "Pirate Ship.dxf",
            drawingFolder: URL(fileURLWithPath: "C:/dev/dxf"))
        XCTAssertEqual(target?.lastPathComponent, "sheet.pdf")
        XCTAssertEqual(target?.deletingLastPathComponent().lastPathComponent, "out")
    }

    func testDashExportPDFDefaultsToDrawingFolderAndName() {
        let target = CADCommandProcessor.dashExportPDFTarget(
            pathTail: "",
            displayName: "Pirate Ship.dxf",
            drawingFolder: URL(fileURLWithPath: "C:/dev/dxf"))
        XCTAssertEqual(target?.lastPathComponent, "Pirate Ship.pdf")
        XCTAssertEqual(target?.deletingLastPathComponent().path,
                       URL(fileURLWithPath: "C:/dev/dxf").path)
    }

    func testDashExportPDFUnsavedDrawingWithoutPathReturnsNil() {
        XCTAssertNil(CADCommandProcessor.dashExportPDFTarget(
            pathTail: "  ", displayName: "Untitled", drawingFolder: nil))
    }
}
