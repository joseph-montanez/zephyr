import Foundation

#if canImport(PDFKit)
import PDFKit
#endif

// =========================================================================
// MARK: - PDFPageRenderer
//
// Cross-platform PDF page-to-PNG renderer. Picks the best available backend:
//
//   Apple platforms  → PDFKit (native, no extra dependencies)
//   Windows / Linux  → PDFium (loaded dynamically from pdfium.dll)
//
// Both backends render at a configurable DPI with a white paper background
// so linework remains visible on dark-theme canvases.
// =========================================================================

/// Information about a PDF file's page structure.
public struct PDFInfo {
    /// Total number of pages.
    public let pageCount: Int
    /// File URL (for re-opening after the initial probe).
    public let url: URL

    public init(pageCount: Int, url: URL) {
        self.pageCount = pageCount
        self.url = url
    }
}

/// The result of rendering a single PDF page.
public struct PDFRenderResult {
    /// PNG-encoded bitmap data.
    public let pngData: Data
    /// Pixel width of the rendered image.
    public let pixelWidth: Int
    /// Pixel height of the rendered image.
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// =========================================================================
// MARK: - PDFPageRenderer
// =========================================================================

public enum PDFPageRenderer {

    /// Default rendering DPI. 150 gives crisp lines when zooming in on a
    /// CAD underlay without producing unreasonably large bitmaps.
    public static let defaultDPI: CGFloat = 150.0

    /// Maximum pixel dimension for a rendered page. Pages larger than this
    /// are downscaled proportionally.
    public static let maxPixelDimension: Int = 20_000

    // ---------------------------------------------------------------------
    // MARK: Public API
    // ---------------------------------------------------------------------

    /// Open a PDF file and return page count information.
    /// - Parameter url: Local file URL for the PDF.
    /// - Returns: `PDFInfo` with page count, or nil if the file can't be read.
    public static func openPDF(at url: URL) -> PDFInfo? {
#if canImport(PDFKit)
        guard let pdfDoc = PDFDocument(url: url) else { return nil }
        let count = pdfDoc.pageCount
        guard count > 0 else { return nil }
        return PDFInfo(pageCount: count, url: url)
#else
        guard let count = PDFiumBridge.pageCount(path: url.path) else { return nil }
        guard count > 0 else { return nil }
        return PDFInfo(pageCount: count, url: url)
#endif
    }

    /// Render a single page to a PNG bitmap at the given DPI.
    public static func renderPage(
        at url: URL,
        pageIndex: Int,
        dpi: CGFloat = defaultDPI
    ) -> PDFRenderResult? {
#if canImport(PDFKit)
        return renderWithPDFKit(url: url, pageIndex: pageIndex, dpi: dpi)
#else
        return renderWithPdfium(url: url, pageIndex: pageIndex, dpi: Float(dpi))
#endif
    }

    /// Check whether any PDF rendering backend is available.
    public static var isAvailable: Bool {
#if canImport(PDFKit)
        return true
#else
        return PDFiumBridge.isAvailable
#endif
    }

    // ---------------------------------------------------------------------
    // MARK: Apple backend: PDFKit
    // ---------------------------------------------------------------------

#if canImport(PDFKit)
    private static func renderWithPDFKit(
        url: URL, pageIndex: Int, dpi: CGFloat
    ) -> PDFRenderResult? {
        guard let pdfDoc = PDFDocument(url: url),
              let page = pdfDoc.page(at: pageIndex)
        else { return nil }

        let mediaBox = page.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let scale = dpi / 72.0
        var pixelWidth = Int((mediaBox.width * scale).rounded())
        var pixelHeight = Int((mediaBox.height * scale).rounded())

        // Cap oversized pages
        if pixelWidth > maxPixelDimension || pixelHeight > maxPixelDimension {
            let limit = CGFloat(maxPixelDimension)
            let fitScale = min(limit / mediaBox.width, limit / mediaBox.height)
            pixelWidth = Int((mediaBox.width * fitScale).rounded())
            pixelHeight = Int((mediaBox.height * fitScale).rounded())
            return renderPDFKitPage(page, mediaBox: mediaBox,
                                    pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                    scale: fitScale)
        }

        return renderPDFKitPage(page, mediaBox: mediaBox,
                                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                scale: scale)
    }

    private static func renderPDFKitPage(
        _ page: PDFPage,
        mediaBox: CGRect,
        pixelWidth: Int, pixelHeight: Int,
        scale: CGFloat
    ) -> PDFRenderResult? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        // White paper background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        // Scale and render
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else { return nil }

        let pngData: Data?
#if os(macOS)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
        pngData = nsImage.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .png, properties: [:]) }
#else
        let uiImage = UIImage(cgImage: cgImage)
        pngData = uiImage.pngData()
#endif

        guard let data = pngData else { return nil }
        return PDFRenderResult(pngData: data, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
#endif // canImport(PDFKit)

    // ---------------------------------------------------------------------
    // MARK: Windows/Linux backend: PDFium (dynamic)
    // ---------------------------------------------------------------------

#if !canImport(PDFKit)
    private static func renderWithPdfium(
        url: URL, pageIndex: Int, dpi: Float
    ) -> PDFRenderResult? {
        guard let pngData = PDFiumBridge.renderPageToPNG(
            path: url.path, pageIndex: pageIndex, dpi: dpi
        ) else { return nil }

        // Width/height are embedded in the PNG; we read them back
        let (pw, ph) = readPNGDimensions(pngData) ?? (0, 0)
        return PDFRenderResult(pngData: pngData, pixelWidth: pw, pixelHeight: ph)
    }

    /// Quick PNG IHDR parser to extract dimensions from a PNG data blob.
    private static func readPNGDimensions(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24 else { return nil }
        // PNG signature is 8 bytes; IHDR starts at offset 8 (4B length + 4B type)
        // Width at offset 16, height at offset 20
        let w = (UInt32(data[16]) << 24) | (UInt32(data[17]) << 16) | (UInt32(data[18]) << 8) | UInt32(data[19])
        let h = (UInt32(data[20]) << 24) | (UInt32(data[21]) << 16) | (UInt32(data[22]) << 8) | UInt32(data[23])
        return (Int(w), Int(h))
    }
#endif
}
