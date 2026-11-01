import Foundation

// =========================================================================
// MARK: - PlotDeviceCatalog
//
// Virtual output-device catalog (Phase 2, Decision 1: no OS print spooling
// in v1). Built-in devices carry fixed media tables with per-media
// unprintable margins plus a fixed referenceDPI driving the shaded-viewport
// DPI caps (Preview = 1/4, Normal = 1/2, Presentation = full; DWG To PDF =
// 200 DPI so Normal shows 100 DPI per the reference screenshot).
//
// Canonical media names use underscores
// (`ISO_full_bleed_A3_(420.00_x_297.00_MM)`); display names use spaces
// (`ISO full bleed A3 (420.00 x 297.00 MM)`). Unmatched Code-2 printer
// names from foreign DWGs are preserved as raw strings by callers
// (AutoCAD missing-plotter behavior).
// =========================================================================

/// One paper size in a device's media list. Dimensions and margins are in
/// millimeters (DXF 40–45 are always mm, regardless of Code 72).
public struct PlotPaperSize: Sendable, Equatable {
    public var canonicalName: String
    public var widthMM: Double
    public var heightMM: Double
    public var marginLM: Double
    public var marginBM: Double
    public var marginRM: Double
    public var marginTM: Double
    /// DXF 72 for this media: 0 = inches, 1 = millimeters.
    public var paperUnits: Int

    public init(canonicalName: String, widthMM: Double, heightMM: Double,
                marginLM: Double = 0, marginBM: Double = 0,
                marginRM: Double = 0, marginTM: Double = 0,
                paperUnits: Int = 1) {
        self.canonicalName = canonicalName
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.marginLM = marginLM
        self.marginBM = marginBM
        self.marginRM = marginRM
        self.marginTM = marginTM
        self.paperUnits = paperUnits
    }

    /// Localized display name: underscores → spaces.
    public var displayName: String {
        PlotDeviceCatalog.displayName(forCanonical: canonicalName)
    }
}

/// One virtual output device (a `.pc3` name in DXF Code 2 terms).
public struct PlotDevice: Sendable, Equatable {
    public var name: String
    public var plotterDescription: String
    public var whereText: String
    public var isPDF: Bool
    /// Fixed reference resolution driving shade-plot DPI caps.
    public var referenceDPI: Int
    public var media: [PlotPaperSize]
    public var defaultMediaCanonicalName: String

    public init(name: String, plotterDescription: String = "", whereText: String = "File",
                isPDF: Bool = false, referenceDPI: Int = 300,
                media: [PlotPaperSize] = [],
                defaultMediaCanonicalName: String = "") {
        self.name = name
        self.plotterDescription = plotterDescription
        self.whereText = whereText
        self.isPDF = isPDF
        self.referenceDPI = referenceDPI
        self.media = media
        self.defaultMediaCanonicalName = defaultMediaCanonicalName
    }

    public func medium(canonicalName: String) -> PlotPaperSize? {
        media.first { $0.canonicalName.caseInsensitiveCompare(canonicalName) == .orderedSame }
    }

    public var defaultMedium: PlotPaperSize? {
        medium(canonicalName: defaultMediaCanonicalName) ?? media.first
    }
}

public enum PlotDeviceCatalog {
    // MARK: - Canonical ↔ display names

    /// `ISO_full_bleed_A3_(420.00_x_297.00_MM)` → `ISO full bleed A3 (420.00 x 297.00 MM)`.
    public static func displayName(forCanonical canonical: String) -> String {
        canonical.replacingOccurrences(of: "_", with: " ")
    }

    /// `ISO full bleed A3 (420.00 x 297.00 MM)` → `ISO_full_bleed_A3_(420.00_x_297.00_MM)`.
    public static func canonicalName(forDisplay display: String) -> String {
        display.replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Media tables

    private static let inchMargin: Double = 6.35 // 0.25in in mm

    static func isoMedia(fullBleed: Bool) -> [PlotPaperSize] {
        let sheets: [(String, Double, Double)] = [
            ("A4", 297, 210), ("A3", 420, 297), ("A2", 594, 420),
            ("A1", 841, 594), ("A0", 1189, 841),
        ]
        return sheets.flatMap { name, w, h -> [PlotPaperSize] in
            let dims = String(format: "(%.2f_x_%.2f_MM)", w, h)
            var out: [PlotPaperSize] = []
            if fullBleed {
                out.append(PlotPaperSize(
                    canonicalName: "ISO_full_bleed_\(name)_\(dims)",
                    widthMM: w, heightMM: h, paperUnits: 1))
            } else {
                out.append(PlotPaperSize(
                    canonicalName: "ISO_\(name)_\(dims)",
                    widthMM: w, heightMM: h,
                    marginLM: 5, marginBM: 5, marginRM: 5, marginTM: 5,
                    paperUnits: 1))
            }
            return out
        }
    }

    static func ansiMedia() -> [PlotPaperSize] {
        let sheets: [(String, Double, Double)] = [
            ("A", 279.4, 215.9), ("B", 431.8, 279.4), ("C", 558.8, 431.8),
            ("D", 863.6, 558.8), ("E", 1117.6, 863.6),
        ]
        return sheets.map { name, wMM, hMM in
            let wIn = wMM / 25.4, hIn = hMM / 25.4
            let dims = String(format: "(%.2f_x_%.2f_Inches)", wIn, hIn)
            return PlotPaperSize(
                canonicalName: "ANSI_\(name)_\(dims)",
                widthMM: wMM, heightMM: hMM,
                marginLM: inchMargin, marginBM: inchMargin,
                marginRM: inchMargin, marginTM: inchMargin,
                paperUnits: 0)
        }
    }

    static func archMedia() -> [PlotPaperSize] {
        let sheets: [(String, Double, Double)] = [
            ("A", 228.6, 304.8), ("B", 304.8, 457.2), ("C", 457.2, 609.6),
            ("D", 609.6, 914.4), ("E", 914.4, 1219.2),
        ]
        return sheets.map { name, wMM, hMM in
            let wIn = wMM / 25.4, hIn = hMM / 25.4
            let dims = String(format: "(%.2f_x_%.2f_Inches)", wIn, hIn)
            return PlotPaperSize(
                canonicalName: "ARCH_\(name)_\(dims)",
                widthMM: wMM, heightMM: hMM,
                marginLM: inchMargin, marginBM: inchMargin,
                marginRM: inchMargin, marginTM: inchMargin,
                paperUnits: 0)
        }
    }

    static func usMedia() -> [PlotPaperSize] {
        [
            PlotPaperSize(canonicalName: "Letter_(8.50_x_11.00_Inches)",
                          widthMM: 215.9, heightMM: 279.4,
                          marginLM: inchMargin, marginBM: inchMargin,
                          marginRM: inchMargin, marginTM: inchMargin, paperUnits: 0),
            PlotPaperSize(canonicalName: "Legal_(8.50_x_14.00_Inches)",
                          widthMM: 215.9, heightMM: 355.6,
                          marginLM: inchMargin, marginBM: inchMargin,
                          marginRM: inchMargin, marginTM: inchMargin, paperUnits: 0),
            PlotPaperSize(canonicalName: "Tabloid_(11.00_x_17.00_Inches)",
                          widthMM: 279.4, heightMM: 431.8,
                          marginLM: inchMargin, marginBM: inchMargin,
                          marginRM: inchMargin, marginTM: inchMargin, paperUnits: 0),
        ]
    }

    static func pdfMedia() -> [PlotPaperSize] {
        isoMedia(fullBleed: true) + isoMedia(fullBleed: false)
            + ansiMedia() + archMedia() + usMedia()
    }

    static func rasterMedia() -> [PlotPaperSize] {
        isoMedia(fullBleed: true).filter {
            $0.canonicalName.contains("_A4_") || $0.canonicalName.contains("_A3_")
        } + usMedia()
    }

    // MARK: - Built-in devices

    /// `None`: no plotter; empty media list.
    public static let noneDevice = PlotDevice(
        name: "None",
        plotterDescription: "No plotter (display only)",
        whereText: "",
        isPDF: false,
        referenceDPI: 0,
        media: [],
        defaultMediaCanonicalName: "")

    /// Built-in PDF driver. Reference 200 DPI (Normal = 100 DPI).
    public static let dwgToPDF = PlotDevice(
        name: "DWG To PDF.pc3",
        plotterDescription: "DWG To PDF - PDF ePlot - by Autodesk (built-in)",
        whereText: "File",
        isPDF: true,
        referenceDPI: 200,
        media: pdfMedia(),
        defaultMediaCanonicalName: "ISO_A4_(297.00_x_210.00_MM)")

    public static let publishJPG = PlotDevice(
        name: "PublishToWeb JPG.pc3",
        plotterDescription: "PublishToWeb JPG (built-in raster)",
        whereText: "File",
        isPDF: false,
        referenceDPI: 96,
        media: rasterMedia(),
        defaultMediaCanonicalName: "Letter_(8.50_x_11.00_Inches)")

    public static let publishPNG = PlotDevice(
        name: "PublishToWeb PNG.pc3",
        plotterDescription: "PublishToWeb PNG (built-in raster)",
        whereText: "File",
        isPDF: false,
        referenceDPI: 96,
        media: rasterMedia(),
        defaultMediaCanonicalName: "Letter_(8.50_x_11.00_Inches)")

    /// All built-in devices, in dropdown order.
    public static let builtins: [PlotDevice] = [noneDevice, dwgToPDF, publishJPG, publishPNG]

    /// Case-insensitive lookup. Returns nil for unmatched foreign names;
    /// callers preserve those raw strings (missing-plotter behavior).
    public static func device(named name: String) -> PlotDevice? {
        builtins.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func isKnownDevice(_ name: String) -> Bool {
        device(named: name) != nil
    }
}
