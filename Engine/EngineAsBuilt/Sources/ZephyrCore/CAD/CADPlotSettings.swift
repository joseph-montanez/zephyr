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
        layoutFlags: Int = 0
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
