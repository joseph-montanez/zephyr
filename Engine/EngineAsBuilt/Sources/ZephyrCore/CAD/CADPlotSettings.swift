import Foundation

// =========================================================================
// MARK: - CADPlotSettings
//
// Full-fidelity AutoCAD plot settings for one layout (paper or model),
// covering the DXF `AcDbPlotSettings` subclass (group codes 1-149) that
// rides inside every LAYOUT object ahead of the `100 = AcDbLayout`
// marker. Codes 1, 70, and 76 appear twice in a LAYOUT record; the
// fields below are the PRE-marker (plot) half. The POST-marker layout
// half (tab name/order, limits, flags) stays on DXFLayoutEntry /
// DXFLayoutDefinition.
//
// `CADLayoutSettings` remains the lightweight paper-size view used by PDF
// export and unit selection; the importer keeps both in sync from the
// same entry. A nil `plotSettings` on a document means "defaults" and
// exports byte-identical output to the legacy synthetic writer.
// =========================================================================

/// Plot settings for one drawing view. Defaults reproduce the legacy
/// synthetic writer output, so documents without plot settings round-trip
/// byte-identically to before.
public struct CADPlotSettings: Sendable, Equatable {
    // MARK: Paper (mirrors CADLayoutSettings paper fields)

    public var paperName: String?
    public var paperWidthMM: Double
    public var paperHeightMM: Double
    public var marginLM: Double
    public var marginBM: Double
    public var marginRM: Double
    public var marginTM: Double
    /// DXF 72: 0 = inches, 1 = millimeters, 2 = pixels.
    public var plotPaperUnits: Int
    /// DXF 73: 0 = portrait, 1 = 90 CCW, 2 = upside-down, 3 = 90 CW.
    public var plotRotation: Int

    // MARK: Devices and styles (DXF 1,2,4,6,7 pre-marker)

    /// Assigned named page setup (`""` when `<None>`).
    public var pageSetupName: String
    /// System printer name or `.pc3` filename.
    public var plotConfigName: String
    /// Locale-independent media identifier.
    public var canonicalMediaName: String
    /// Saved view name when plot type is View.
    public var plotViewName: String
    /// Plot style table filename (`.ctb` / `.stb`).
    public var styleSheet: String

    // MARK: Geometry, all in millimeters (DXF 46-49, 140-149)

    /// Plot offset (origin) X/Y.
    public var plotOriginXMM: Double
    public var plotOriginYMM: Double
    /// Plot window area (only meaningful when plotType is Window).
    public var plotWindowMinX: Double
    public var plotWindowMinY: Double
    public var plotWindowMaxX: Double
    public var plotWindowMaxY: Double
    /// Custom print scale numerator/denominator (paper units per drawing unit).
    public var customScaleNumerator: Double
    public var customScaleDenominator: Double
    /// Effective scale factor.
    public var standardScaleFactor: Double
    /// Paper image origin.
    public var paperImageOriginX: Double
    public var paperImageOriginY: Double

    // MARK: Modes and flags

    /// DXF 70 bitmask (pre-marker). Bit 1024 (`ModelType`) is managed at
    /// read/write time from the view kind, never stored.
    public var plotFlags: Int
    /// DXF 74: 0 = Display, 1 = Extents, 2 = Limits, 3 = View, 4 = Window,
    /// 5 = Layout.
    public var plotType: Int
    /// DXF 75 standard scale type (0 = Scaled to Fit, 1-32 table).
    public var standardScaleType: Int
    /// DXF 76/77/78 shade-plot mode / resolution / custom DPI.
    public var shadePlotMode: Int
    public var shadePlotResolution: Int
    public var shadePlotCustomDPI: Int
    /// DXF post-marker layout flags (bit 0 = PSLTSCALE, bit 1 = LIMCHECK).
    public var layoutFlags: Int
    /// Plot transparency (no plain DXF 1–149 code; EAB v2 + DXF XDATA only).
    public var plotTransparency: Bool
    /// PDF export options (no plain DXF code; EAB v2 + DXF XDATA only).
    public var pdfOptions: PDFOptions

    public init(
        paperName: String? = nil,
        paperWidthMM: Double = 0,
        paperHeightMM: Double = 0,
        marginLM: Double = 0,
        marginBM: Double = 0,
        marginRM: Double = 0,
        marginTM: Double = 0,
        plotPaperUnits: Int = 0,
        plotRotation: Int = 0,
        pageSetupName: String = "",
        plotConfigName: String = "",
        canonicalMediaName: String = "",
        plotViewName: String = "",
        styleSheet: String = "",
        plotOriginXMM: Double = 0,
        plotOriginYMM: Double = 0,
        plotWindowMinX: Double = 0,
        plotWindowMinY: Double = 0,
        plotWindowMaxX: Double = 0,
        plotWindowMaxY: Double = 0,
        customScaleNumerator: Double = 1,
        customScaleDenominator: Double = 1,
        standardScaleFactor: Double = 1,
        paperImageOriginX: Double = 0,
        paperImageOriginY: Double = 0,
        plotFlags: Int = 0,
        plotType: Int = 5,
        standardScaleType: Int = 0,
        shadePlotMode: Int = 0,
        shadePlotResolution: Int = 2,
        shadePlotCustomDPI: Int = 300,
        layoutFlags: Int = 0,
        plotTransparency: Bool = false,
        pdfOptions: PDFOptions = PDFOptions()
    ) {
        self.paperName = paperName
        self.paperWidthMM = paperWidthMM
        self.paperHeightMM = paperHeightMM
        self.marginLM = marginLM
        self.marginBM = marginBM
        self.marginRM = marginRM
        self.marginTM = marginTM
        self.plotPaperUnits = plotPaperUnits
        self.plotRotation = plotRotation
        self.pageSetupName = pageSetupName
        self.plotConfigName = plotConfigName
        self.canonicalMediaName = canonicalMediaName
        self.plotViewName = plotViewName
        self.styleSheet = styleSheet
        self.plotOriginXMM = plotOriginXMM
        self.plotOriginYMM = plotOriginYMM
        self.plotWindowMinX = plotWindowMinX
        self.plotWindowMinY = plotWindowMinY
        self.plotWindowMaxX = plotWindowMaxX
        self.plotWindowMaxY = plotWindowMaxY
        self.customScaleNumerator = customScaleNumerator
        self.customScaleDenominator = customScaleDenominator
        self.standardScaleFactor = standardScaleFactor
        self.paperImageOriginX = paperImageOriginX
        self.paperImageOriginY = paperImageOriginY
        self.plotFlags = plotFlags & ~1024
        self.plotType = plotType
        self.standardScaleType = standardScaleType
        self.shadePlotMode = shadePlotMode
        self.shadePlotResolution = shadePlotResolution
        self.shadePlotCustomDPI = shadePlotCustomDPI
        self.layoutFlags = layoutFlags
        self.plotTransparency = plotTransparency
        self.pdfOptions = pdfOptions
    }

    // MARK: - UseStandardScale (Code 70 bit 16)

    /// DXF 70 bit 16. Cleared = Custom/Fit dialog state (Code 75 stays 16,
    /// ratio from 142/143). Never a synthetic Code-75 enum value.
    public var useStandardScale: Bool {
        get { plotFlags & 16 != 0 }
        set {
            if newValue { plotFlags |= 16 } else { plotFlags &= ~16 }
        }
    }

    /// True when the dialog shows "Custom" (bit 16 cleared, Code 75 == 16).
    public var isCustomScale: Bool { !useStandardScale && standardScaleType == 16 }
    /// True when the dialog shows "Scaled to Fit" (Code 75 == 0).
    public var isScaledToFit: Bool { standardScaleType == 0 }

    /// Effective paper-units-per-drawing-unit scale factor.
    public var effectiveScaleFactor: Double {
        if isScaledToFit { return .nan }
        if !useStandardScale {
            guard customScaleDenominator != 0 else { return 1 }
            return customScaleNumerator / customScaleDenominator
        }
        return Self.standardScaleFactor(for: standardScaleType) ?? standardScaleFactor
    }

    /// Canonical 0–32 StandardScaleType table → paper/drawing factor.
    /// Imperial factors are exact (N" = 1' → N/12); metric are 1/N.
    public static func standardScaleFactor(for type: Int) -> Double? {
        switch type {
        case 0: return nil // Scaled to Fit (computed from area)
        case 1: return 1.0 / 1536.0 // 1/128"=1'
        case 2: return 1.0 / 768.0 // 1/64"=1'
        case 3: return 1.0 / 384.0 // 1/32"=1'
        case 4: return 1.0 / 192.0 // 1/16"=1'
        case 5: return 1.0 / 128.0 // 3/32"=1'
        case 6: return 1.0 / 96.0 // 1/8"=1'
        case 7: return 1.0 / 64.0 // 3/16"=1'
        case 8: return 1.0 / 48.0 // 1/4"=1'
        case 9: return 1.0 / 32.0 // 3/8"=1'
        case 10: return 1.0 / 24.0 // 1/2"=1'
        case 11: return 1.0 / 16.0 // 3/4"=1'
        case 12: return 1.0 / 12.0 // 1"=1'
        case 13: return 1.0 / 4.0 // 3"=1'
        case 14: return 1.0 / 2.0 // 6"=1'
        case 15: return 1.0 // 1'=1'
        case 16: return 1.0 // 1:1
        case 17: return 1.0 / 2.0 // 1:2
        case 18: return 1.0 / 4.0 // 1:4
        case 19: return 1.0 / 8.0 // 1:8
        case 20: return 1.0 / 10.0 // 1:10
        case 21: return 1.0 / 16.0 // 1:16
        case 22: return 1.0 / 20.0 // 1:20
        case 23: return 1.0 / 30.0 // 1:30
        case 24: return 1.0 / 40.0 // 1:40
        case 25: return 1.0 / 50.0 // 1:50
        case 26: return 1.0 / 100.0 // 1:100
        case 27: return 2.0 // 2:1
        case 28: return 4.0 // 4:1
        case 29: return 8.0 // 8:1
        case 30: return 10.0 // 10:1
        case 31: return 100.0 // 100:1
        case 32: return 1000.0 // 1000:1
        default: return nil
        }
    }

    /// Reverse lookup: exact factor → canonical type (tolerates float noise).
    /// Four imperial/metric pairs share exact factors (1.0: 15/16, 0.5: 14/17,
    /// 0.25: 13/18, 0.0625: 11/21); duplicates resolve to the lowest type
    /// number (dialog order). Callers that need the metric half must
    /// disambiguate by context.
    public static func standardScaleType(forFactor factor: Double) -> Int? {
        guard factor.isFinite, factor > 0 else { return nil }
        for t in 1...32 {
            if let f = standardScaleFactor(for: t), abs(f - factor) <= max(1e-9, abs(f) * 1e-9) {
                return t
            }
        }
        return nil
    }

    // MARK: - Sheet size helpers (spec §4; full geometry in PaperSheetGeometry)

    /// S_unit divisor: 1.0 for mm (72=1), 25.4 for inches (72=0), pixels passthrough.
    public var paperUnitDivisor: Double { plotPaperUnits == 0 ? 25.4 : 1.0 }

    /// Scaled sheet size in paper-space units (44/45 / S_unit × 143/142).
    public var scaledSheetSize: (width: Double, height: Double) {
        let denom = customScaleDenominator != 0 ? customScaleDenominator : 1
        let num = customScaleNumerator != 0 ? customScaleNumerator : 1
        // 143/142 is denominator/numerator per spec (1.0 at default 1:1).
        let k = denom / num
        return (paperWidthMM / paperUnitDivisor * k, paperHeightMM / paperUnitDivisor * k)
    }

    /// LIMMIN/LIMMAX sync values: paper corners in scaled paper units
    /// relative to the plot origin (spec §4.3).
    public var syncedLimits: (min: (x: Double, y: Double), max: (x: Double, y: Double)) {
        let s = scaledSheetSize
        // Plot origin offset is in mm; convert like paper dims.
        let ox = plotOriginXMM / paperUnitDivisor
        let oy = plotOriginYMM / paperUnitDivisor
        return ((x: -ox, y: -oy), (x: s.width - ox, y: s.height - oy))
    }

    /// Paper-size view kept in sync by the importer for PDF export and
    /// unit selection.
    public var layoutSettings: CADLayoutSettings? {
        guard paperWidthMM > 0, paperHeightMM > 0 else { return nil }
        return CADLayoutSettings(
            paperName: paperName,
            paperWidthMM: paperWidthMM,
            paperHeightMM: paperHeightMM,
            marginLM: marginLM,
            marginBM: marginBM,
            marginRM: marginRM,
            marginTM: marginTM,
            plotPaperUnits: plotPaperUnits,
            plotRotation: plotRotation)
    }

    /// Default Letter landscape sheet (millimeters), matching
    /// `TabManager.defaultNewLayoutSettings`.
    public static let letterLandscape = CADPlotSettings(
        paperWidthMM: 279.4, paperHeightMM: 215.9,
        plotPaperUnits: 1)
}

// =========================================================================
// MARK: - PDFOptions (XDATA/EAB only, no plain DXF code)
// =========================================================================

/// Merge control for PDF export (revised spec §3).
public enum PDFMergeControl: Int, Sendable, Equatable, Codable {
    case overwriteLines = 0
    case mergeLines = 1
}

/// PDF Options dialog values (revised spec §3). No plain AcDbPlotSettings
/// group code; persisted in EAB v2 + DXF XDATA (`ZEPHYR_PLOT` appid).
public struct PDFOptions: Sendable, Equatable, Codable {
    public var vectorDPI: Int
    public var rasterDPI: Int
    public var mergeControl: PDFMergeControl
    public var includeLayerInfo: Bool
    public var includeHyperlinks: Bool
    public var captureFonts: Bool
    public var convertTextToGeometry: Bool

    public init(
        vectorDPI: Int = 300,
        rasterDPI: Int = 300,
        mergeControl: PDFMergeControl = .overwriteLines,
        includeLayerInfo: Bool = true,
        includeHyperlinks: Bool = false,
        captureFonts: Bool = true,
        convertTextToGeometry: Bool = false
    ) {
        self.vectorDPI = vectorDPI
        self.rasterDPI = rasterDPI
        self.mergeControl = mergeControl
        self.includeLayerInfo = includeLayerInfo
        self.includeHyperlinks = includeHyperlinks
        self.captureFonts = captureFonts
        self.convertTextToGeometry = convertTextToGeometry
    }
}

// =========================================================================
// MARK: - CADNamedPageSetup (ACAD_PLOTSETTINGS dictionary entries)
// =========================================================================

/// Reusable named page setup (standalone PLOTSETTINGS object).
/// `isModelType` mirrors DXF 70 bit 1024 scoping (stored per setup).
public struct CADNamedPageSetup: Sendable, Equatable {
    public var name: String
    public var settings: CADPlotSettings
    public var isModelType: Bool

    public init(name: String, settings: CADPlotSettings, isModelType: Bool = false) {
        self.name = name
        self.settings = settings
        self.isModelType = isModelType
    }
}
